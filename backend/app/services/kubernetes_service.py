from functools import cached_property
from pathlib import Path
from typing import Any

from kubernetes import client, config
from kubernetes.config.config_exception import ConfigException

from app.core.config import settings
from app.services.kubernetes_client_auth import configure_bearer_token_refresh
from app.services.observability_errors import ObservabilityUnavailableError


class KubernetesService:
    def __init__(self) -> None:
        self._loaded = False
        self._current_context: str | None = None
        self._api_client: client.ApiClient | None = None

    def check_health(self) -> None:
        self._core_api.list_namespace(limit=1)

    def get_cluster_summary(self, namespace: str) -> dict[str, Any]:
        namespaces = self._core_api.list_namespace().items
        pods = self._core_api.list_namespaced_pod(namespace).items
        deployments = self._apps_api.list_namespaced_deployment(namespace).items
        services = self._core_api.list_namespaced_service(namespace).items
        nodes = self._core_api.list_node().items

        return {
            "current_context": self._current_context,
            "namespaces_count": len(namespaces),
            "pods_count": len(pods),
            "deployments_count": len(deployments),
            "services_count": len(services),
            "nodes_count": len(nodes),
            "ready_nodes_count": sum(1 for node in nodes if self._is_node_ready(node)),
        }

    def list_namespaces(self) -> list[dict[str, Any]]:
        namespaces = [
            {
                "name": item.metadata.name,
                "status": item.status.phase,
                "created_at": item.metadata.creation_timestamp,
                "labels": item.metadata.labels or {},
            }
            for item in self._core_api.list_namespace().items
        ]
        return sorted(
            namespaces,
            key=lambda item: (item["name"] != settings.workload_namespace, item["name"]),
        )

    def list_pods(self, namespace: str) -> list[dict[str, Any]]:
        pods = self._core_api.list_namespaced_pod(namespace).items
        return [self._serialize_pod(pod) for pod in pods]

    def list_deployments(self, namespace: str) -> list[dict[str, Any]]:
        deployments = self._apps_api.list_namespaced_deployment(namespace).items
        return [self._serialize_deployment(deployment) for deployment in deployments]

    def list_services(self, namespace: str) -> list[dict[str, Any]]:
        services = self._core_api.list_namespaced_service(namespace).items
        return [self._serialize_service(service) for service in services]

    def namespace_exists(self, name: str) -> bool:
        try:
            self._core_api.read_namespace(name)
        except client.ApiException as exc:
            if exc.status == 404:
                return False
            raise
        return True

    def argocd_application_exists(self, name: str, namespace: str = "argocd") -> bool:
        custom_api = client.CustomObjectsApi(self._get_api_client())
        try:
            custom_api.get_namespaced_custom_object(
                group="argoproj.io",
                version="v1alpha1",
                namespace=namespace,
                plural="applications",
                name=name,
            )
        except client.ApiException as exc:
            if exc.status == 404:
                return False
            raise
        return True

    @cached_property
    def _core_api(self) -> client.CoreV1Api:
        return client.CoreV1Api(self._get_api_client())

    @cached_property
    def _apps_api(self) -> client.AppsV1Api:
        return client.AppsV1Api(self._get_api_client())

    def _get_api_client(self) -> client.ApiClient:
        self._load_config()
        if self._api_client is None:
            raise ObservabilityUnavailableError("Kubernetes API client was not initialized")
        return self._api_client

    def _load_config(self) -> None:
        if self._loaded:
            return
        try:
            configuration = client.Configuration()
            workload_kubeconfig_path = settings.resolved_observability_workload_kubeconfig
            if (
                settings.observability_access_mode == "kubernetes_service_proxy"
                and workload_kubeconfig_path
            ):
                load_options: dict[str, Any] = {
                    "config_file": workload_kubeconfig_path,
                    "client_configuration": configuration,
                }
                if settings.observability_workload_kubeconfig_context:
                    load_options["context"] = settings.observability_workload_kubeconfig_context
                config.load_kube_config(**load_options)
                configure_bearer_token_refresh(configuration, required=True)
                self._current_context = (
                    settings.observability_workload_kubeconfig_context or "workload-runtime"
                )
            elif settings.kubernetes_in_cluster:
                config.load_incluster_config(client_configuration=configuration)
                configure_bearer_token_refresh(configuration, required=True)
                self._current_context = "in-cluster"
            else:
                kubeconfig_path = (
                    str(Path(settings.kubeconfig_path).expanduser()) if settings.kubeconfig_path else None
                )
                if kubeconfig_path:
                    config.load_kube_config(config_file=kubeconfig_path, client_configuration=configuration)
                else:
                    config.load_kube_config(client_configuration=configuration)
                self._current_context = self._get_current_kube_context(kubeconfig_path)
            self._api_client = client.ApiClient(configuration=configuration)
        except (ConfigException, OSError) as exc:
            raise ObservabilityUnavailableError(f"Kubernetes configuration unavailable: {exc}") from exc
        self._loaded = True

    @staticmethod
    def _get_current_kube_context(kubeconfig_path: str | None) -> str | None:
        try:
            _, active_context = config.list_kube_config_contexts(config_file=kubeconfig_path)
        except ConfigException:
            return None
        if not active_context:
            return None
        return active_context.get("name")

    @staticmethod
    def _is_node_ready(node: client.V1Node) -> bool:
        return any(
            condition.type == "Ready" and condition.status == "True"
            for condition in (node.status.conditions or [])
        )

    @staticmethod
    def _serialize_pod(pod: client.V1Pod) -> dict[str, Any]:
        statuses = pod.status.container_statuses or []
        ready_count = sum(1 for status in statuses if status.ready)
        restart_count = sum(status.restart_count or 0 for status in statuses)
        return {
            "namespace": pod.metadata.namespace,
            "name": pod.metadata.name,
            "phase": pod.status.phase,
            "node_name": pod.spec.node_name,
            "restart_count": restart_count,
            "containers_ready": f"{ready_count}/{len(statuses)}",
            "created_at": pod.metadata.creation_timestamp,
            "labels": pod.metadata.labels or {},
        }

    @staticmethod
    def _serialize_deployment(deployment: client.V1Deployment) -> dict[str, Any]:
        status = deployment.status
        desired_replicas = deployment.spec.replicas or status.replicas or 0
        image = KubernetesService._first_container_image(deployment)
        image_repository, image_tag = KubernetesService._split_image(image)
        return {
            "namespace": deployment.metadata.namespace,
            "name": deployment.metadata.name,
            "replicas": desired_replicas,
            "ready_replicas": status.ready_replicas or 0,
            "available_replicas": status.available_replicas or 0,
            "updated_replicas": status.updated_replicas or 0,
            "status": KubernetesService._deployment_status(deployment, desired_replicas),
            "image": image_repository,
            "tag": image_tag,
            "created_at": deployment.metadata.creation_timestamp,
            "updated_at": KubernetesService._deployment_updated_at(deployment),
            "labels": deployment.metadata.labels or {},
        }

    @staticmethod
    def _first_container_image(deployment: client.V1Deployment) -> str | None:
        containers = deployment.spec.template.spec.containers or []
        if not containers:
            return None
        return containers[0].image

    @staticmethod
    def _split_image(image: str | None) -> tuple[str | None, str | None]:
        if not image:
            return None, None
        if "@" in image:
            repository, digest = image.rsplit("@", 1)
            return repository, digest
        last_segment = image.rsplit("/", 1)[-1]
        if ":" not in last_segment:
            return image, None
        repository, tag = image.rsplit(":", 1)
        return repository, tag

    @staticmethod
    def _deployment_status(deployment: client.V1Deployment, desired_replicas: int) -> str:
        status = deployment.status
        conditions = status.conditions or []
        if any(
            condition.type == "Progressing"
            and condition.status == "False"
            and condition.reason == "ProgressDeadlineExceeded"
            for condition in conditions
        ):
            return "failed"

        available_replicas = status.available_replicas or 0
        updated_replicas = status.updated_replicas or 0
        if desired_replicas > 0 and available_replicas >= desired_replicas and updated_replicas >= desired_replicas:
            return "running"
        if desired_replicas > 0 and (available_replicas < desired_replicas or updated_replicas < desired_replicas):
            return "progressing"
        return "unknown"

    @staticmethod
    def _deployment_updated_at(deployment: client.V1Deployment) -> Any:
        conditions = deployment.status.conditions or []
        timestamps = [
            condition.last_update_time
            for condition in conditions
            if condition.last_update_time is not None
        ]
        return max(timestamps) if timestamps else None

    @staticmethod
    def _serialize_service(service: client.V1Service) -> dict[str, Any]:
        return {
            "namespace": service.metadata.namespace,
            "name": service.metadata.name,
            "type": service.spec.type,
            "cluster_ip": service.spec.cluster_ip,
            "ports": [
                {
                    "name": port.name,
                    "port": port.port,
                    "target_port": port.target_port,
                    "protocol": port.protocol,
                }
                for port in (service.spec.ports or [])
            ],
            "labels": service.metadata.labels or {},
        }
