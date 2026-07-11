from pathlib import Path
from typing import Any

from kubernetes import client, config
from kubernetes.client.exceptions import ApiException
from kubernetes.config.config_exception import ConfigException

from app.services.gitops.status_reader import (
    GitOpsStatusError,
    GitOpsStatusRequest,
    GitOpsStatusSnapshot,
    KUBERNETES_NAME_PATTERN,
    NamedWorkloadSnapshot,
    RootApplicationSnapshot,
    ServicePortSnapshot,
    WorkloadSnapshot,
)
from app.services.gitops.models import validate_app_name


ARGOCD_APPLICATION_GROUP = "argoproj.io"
ARGOCD_APPLICATION_VERSION = "v1alpha1"
ARGOCD_APPLICATION_PLURAL = "applications"
REQUEST_TIMEOUT = (3, 10)
EXPECTED_LABELS = {
    "app.kubernetes.io/managed-by": "devdeploy",
    "app.kubernetes.io/part-of": "devdeploy-workloads",
}
KNOWN_POD_PHASES = {"Pending", "Running", "Succeeded", "Failed", "Unknown"}
KNOWN_WAITING_REASONS = {
    "ContainerCreating",
    "CrashLoopBackOff",
    "CreateContainerConfigError",
    "ErrImagePull",
    "ImagePullBackOff",
    "PodInitializing",
}
POD_FAILURE_REASONS = {
    "CrashLoopBackOff",
    "CreateContainerConfigError",
    "ErrImagePull",
    "ImagePullBackOff",
}
ARGOCD_FAILURE_CONDITIONS = {"ComparisonError", "InvalidSpecError", "SyncError"}


class KubernetesGitOpsStatusReader:
    def __init__(
        self,
        *,
        management_custom_api: Any,
        workload_apps_api: Any,
        workload_core_api: Any,
        request_timeout: tuple[int, int] = REQUEST_TIMEOUT,
    ):
        self.management_custom_api = management_custom_api
        self.workload_apps_api = workload_apps_api
        self.workload_core_api = workload_core_api
        self.request_timeout = request_timeout

    @classmethod
    def from_server_config(
        cls,
        *,
        management_kubeconfig: str | None,
        management_kubeconfig_context: str | None,
        workload_kubeconfig: str | None,
        workload_kubeconfig_context: str | None,
        use_in_cluster_management: bool,
    ) -> "KubernetesGitOpsStatusReader":
        management_client = cls._build_api_client(
            kubeconfig_path=management_kubeconfig,
            kubeconfig_context=management_kubeconfig_context,
            allow_in_cluster=use_in_cluster_management,
        )
        workload_client = cls._build_api_client(
            kubeconfig_path=workload_kubeconfig,
            kubeconfig_context=workload_kubeconfig_context,
            allow_in_cluster=False,
        )
        return cls(
            management_custom_api=client.CustomObjectsApi(management_client),
            workload_apps_api=client.AppsV1Api(workload_client),
            workload_core_api=client.CoreV1Api(workload_client),
        )

    @classmethod
    def from_workload_server_config(
        cls,
        *,
        workload_kubeconfig: str | None,
        workload_kubeconfig_context: str | None,
    ) -> "KubernetesGitOpsStatusReader":
        workload_client = cls._build_api_client(
            kubeconfig_path=workload_kubeconfig,
            kubeconfig_context=workload_kubeconfig_context,
            allow_in_cluster=False,
        )
        return cls(
            management_custom_api=None,
            workload_apps_api=client.AppsV1Api(workload_client),
            workload_core_api=client.CoreV1Api(workload_client),
        )

    @classmethod
    def from_management_server_config(
        cls,
        *,
        management_kubeconfig: str | None,
        management_kubeconfig_context: str | None,
        use_in_cluster_management: bool,
    ) -> "KubernetesGitOpsStatusReader":
        management_client = cls._build_api_client(
            kubeconfig_path=management_kubeconfig,
            kubeconfig_context=management_kubeconfig_context,
            allow_in_cluster=use_in_cluster_management,
        )
        return cls(
            management_custom_api=client.CustomObjectsApi(management_client),
            workload_apps_api=None,
            workload_core_api=None,
        )

    def read(self, request: GitOpsStatusRequest) -> GitOpsStatusSnapshot:
        root_application = self.read_root_application(request)
        if not root_application.exists:
            return GitOpsStatusSnapshot(
                root_application=root_application,
                workload=WorkloadSnapshot(),
            )

        workload = self.read_workload(request.app_name, request.namespace)
        return GitOpsStatusSnapshot(
            root_application=root_application,
            workload=workload,
        )

    def read_root_application(self, request: GitOpsStatusRequest) -> RootApplicationSnapshot:
        return self._read_root_application(request)

    def read_workload(self, app_name: str, namespace: str) -> WorkloadSnapshot:
        try:
            validate_app_name(app_name)
        except ValueError:
            raise GitOpsStatusError("invalid_app_name", "The app name is invalid.") from None
        self._validate_namespace(namespace)

        selector = self._label_selector(app_name)
        deployments, services, pods = self._list_workload_resources(
            namespace=namespace,
            label_selector=selector,
        )

        deployment = self._named_resource(deployments, app_name)
        service = self._named_resource(services, app_name)
        return self._workload_snapshot(deployment, service, pods)

    def discover_workloads(self, namespace: str) -> tuple[NamedWorkloadSnapshot, ...]:
        self._validate_namespace(namespace)
        deployments, services, pods = self._list_workload_resources(namespace=namespace)
        names = sorted(
            {
                name
                for resource in (*deployments, *services)
                if (name := self._resource_name(resource)) is not None
            }
        )
        return tuple(
            NamedWorkloadSnapshot(
                name=name,
                workload=self._workload_snapshot(
                    self._named_resource(deployments, name),
                    self._named_resource(services, name),
                    [pod for pod in pods if self._pod_app_name(pod) == name],
                ),
            )
            for name in names
        )

    def _list_workload_resources(
        self,
        *,
        namespace: str,
        label_selector: str | None = None,
    ) -> tuple[list[Any], list[Any], list[Any]]:
        query = {
            "namespace": namespace,
            "_request_timeout": self.request_timeout,
        }
        if label_selector:
            query["label_selector"] = label_selector
        try:
            deployments = self.workload_apps_api.list_namespaced_deployment(
                **query,
            ).items or []
            services = self.workload_core_api.list_namespaced_service(
                **query,
            ).items or []
            pods = self.workload_core_api.list_namespaced_pod(
                **query,
            ).items or []
        except ApiException as error:
            self._raise_safe_api_error(error)
        except (OSError, TimeoutError):
            raise GitOpsStatusError(
                "status_reader_unavailable",
                "Deployment status is temporarily unavailable.",
            ) from None
        return deployments, services, pods

    def _read_root_application(self, request: GitOpsStatusRequest) -> RootApplicationSnapshot:
        try:
            application = self.management_custom_api.get_namespaced_custom_object(
                group=ARGOCD_APPLICATION_GROUP,
                version=ARGOCD_APPLICATION_VERSION,
                namespace=request.root_application_namespace,
                plural=ARGOCD_APPLICATION_PLURAL,
                name=request.root_application_name,
                _request_timeout=self.request_timeout,
            )
        except ApiException as error:
            if error.status == 404:
                return RootApplicationSnapshot(exists=False)
            self._raise_safe_api_error(error)
        except (OSError, TimeoutError):
            raise GitOpsStatusError(
                "status_reader_unavailable",
                "Deployment status is temporarily unavailable.",
            ) from None

        status = application.get("status") if isinstance(application, dict) else None
        status = status if isinstance(status, dict) else {}
        sync = status.get("sync") if isinstance(status.get("sync"), dict) else {}
        health = status.get("health") if isinstance(status.get("health"), dict) else {}
        operation_state = status.get("operationState") if isinstance(status.get("operationState"), dict) else {}
        operation_sync_result = (
            operation_state.get("syncResult")
            if isinstance(operation_state.get("syncResult"), dict)
            else {}
        )
        operation = operation_state.get("operation") if isinstance(operation_state.get("operation"), dict) else {}
        operation_sync = operation.get("sync") if isinstance(operation.get("sync"), dict) else {}
        conditions = status.get("conditions") if isinstance(status.get("conditions"), list) else []
        failure_detected = any(
            isinstance(condition, dict) and condition.get("type") in ARGOCD_FAILURE_CONDITIONS
            for condition in conditions
        )
        return RootApplicationSnapshot(
            exists=True,
            observed_revision=self._string_or_none(sync.get("revision")),
            sync_status=self._string_or_none(sync.get("status")),
            health_status=self._string_or_none(health.get("status")),
            failure_detected=failure_detected,
            operation_phase=self._string_or_none(operation_state.get("phase")),
            operation_revision=(
                self._string_or_none(operation_sync_result.get("revision"))
                or self._string_or_none(operation_sync.get("revision"))
            ),
        )

    @staticmethod
    def _workload_snapshot(deployment: Any, service: Any, pods: list[Any]) -> WorkloadSnapshot:
        deployment_image = None
        container_port = None
        desired_replicas = None
        ready_replicas = None
        available_replicas = None
        updated_replicas = None
        generation = None
        observed_generation = None
        deployment_failure = False
        if deployment is not None:
            deployment_name = KubernetesGitOpsStatusReader._resource_name(deployment)
            pod_template = getattr(getattr(deployment, "spec", None), "template", None)
            pod_spec = getattr(pod_template, "spec", None)
            containers = getattr(pod_spec, "containers", None) or []
            container = next(
                (
                    item
                    for item in containers
                    if getattr(item, "name", None) == deployment_name
                ),
                containers[0] if containers else None,
            )
            deployment_image = KubernetesGitOpsStatusReader._string_or_none(
                getattr(container, "image", None)
            )
            container_ports = getattr(container, "ports", None) or []
            named_port = next(
                (
                    port
                    for port in container_ports
                    if getattr(port, "name", None) == "http"
                ),
                container_ports[0] if container_ports else None,
            )
            port_value = getattr(named_port, "container_port", None)
            container_port = (
                port_value
                if KubernetesGitOpsStatusReader._valid_port(port_value)
                else None
            )
            desired_replicas = KubernetesGitOpsStatusReader._int_or_none(
                getattr(getattr(deployment, "spec", None), "replicas", None)
            )
            deployment_status = getattr(deployment, "status", None)
            ready_replicas = KubernetesGitOpsStatusReader._int_or_none(
                getattr(deployment_status, "ready_replicas", None)
            )
            available_replicas = KubernetesGitOpsStatusReader._int_or_none(
                getattr(deployment_status, "available_replicas", None)
            )
            updated_replicas = KubernetesGitOpsStatusReader._int_or_none(
                getattr(deployment_status, "updated_replicas", None)
            )
            generation = KubernetesGitOpsStatusReader._int_or_none(
                getattr(getattr(deployment, "metadata", None), "generation", None)
            )
            observed_generation = KubernetesGitOpsStatusReader._int_or_none(
                getattr(deployment_status, "observed_generation", None)
            )
            deployment_failure = KubernetesGitOpsStatusReader._deployment_failed(
                getattr(deployment_status, "conditions", None) or []
            )

        service_port_ready = KubernetesGitOpsStatusReader._service_ready(service)
        service_spec = getattr(service, "spec", None)
        service_type = KubernetesGitOpsStatusReader._string_or_none(getattr(service_spec, "type", None))
        service_cluster_ip = KubernetesGitOpsStatusReader._string_or_none(
            getattr(service_spec, "cluster_ip", None)
        )
        service_ports = KubernetesGitOpsStatusReader._service_ports(service_spec)
        pod_count = len(pods)
        running_pod_count = 0
        ready_pod_count = 0
        restart_count = 0
        waiting_reasons: set[str] = set()
        pod_phases: set[str] = set()
        pod_failure = False
        crashloop = False
        for pod in pods:
            pod_status = getattr(pod, "status", None)
            phase = getattr(pod_status, "phase", None)
            normalized_phase = phase if phase in KNOWN_POD_PHASES else "Unknown"
            pod_phases.add(normalized_phase)
            running_pod_count += int(normalized_phase == "Running")
            ready_pod_count += int(KubernetesGitOpsStatusReader._pod_ready(pod_status))
            if normalized_phase == "Failed":
                pod_failure = True
            for container_status in getattr(pod_status, "container_statuses", None) or []:
                restart_count += max(getattr(container_status, "restart_count", 0) or 0, 0)
                waiting = getattr(getattr(container_status, "state", None), "waiting", None)
                reason = getattr(waiting, "reason", None)
                if reason:
                    normalized_reason = reason if reason in KNOWN_WAITING_REASONS else "Unknown"
                    waiting_reasons.add(normalized_reason)
                    pod_failure = pod_failure or normalized_reason in POD_FAILURE_REASONS
                    crashloop = crashloop or normalized_reason == "CrashLoopBackOff"

        return WorkloadSnapshot(
            deployment_exists=deployment is not None,
            service_exists=service is not None,
            deployment_image=deployment_image,
            container_port=container_port,
            desired_replicas=desired_replicas,
            ready_replicas=ready_replicas,
            available_replicas=available_replicas,
            updated_replicas=updated_replicas,
            generation=generation,
            observed_generation=observed_generation,
            expected_service_port_exists=service_port_ready,
            pod_count=pod_count,
            running_pod_count=running_pod_count,
            ready_pod_count=ready_pod_count,
            restart_count=restart_count,
            waiting_reasons=tuple(sorted(waiting_reasons)),
            pod_phases=tuple(sorted(pod_phases)),
            failure_detected=deployment_failure or pod_failure,
            pod_crashloop_detected=crashloop,
            service_type=service_type,
            service_cluster_ip=service_cluster_ip,
            service_ports=service_ports,
        )

    @staticmethod
    def _service_ports(service_spec: Any) -> tuple[ServicePortSnapshot, ...]:
        ports: list[ServicePortSnapshot] = []
        for port in getattr(service_spec, "ports", None) or []:
            port_number = getattr(port, "port", None)
            if not KubernetesGitOpsStatusReader._valid_port(port_number):
                continue
            target_port = getattr(port, "target_port", None)
            if not isinstance(target_port, (int, str)) or isinstance(target_port, bool):
                target_port = None
            ports.append(
                ServicePortSnapshot(
                    name=KubernetesGitOpsStatusReader._string_or_none(getattr(port, "name", None)),
                    port=port_number,
                    target_port=target_port,
                    protocol=KubernetesGitOpsStatusReader._string_or_none(
                        getattr(port, "protocol", None)
                    ),
                )
            )
        return tuple(ports)

    @staticmethod
    def _deployment_failed(conditions: list[Any]) -> bool:
        return any(
            (
                getattr(condition, "type", None) == "Progressing"
                and getattr(condition, "status", None) == "False"
                and getattr(condition, "reason", None) == "ProgressDeadlineExceeded"
            )
            or (
                getattr(condition, "type", None) == "ReplicaFailure"
                and getattr(condition, "status", None) == "True"
            )
            for condition in conditions
        )

    @staticmethod
    def _service_ready(service: Any) -> bool:
        if service is None:
            return False
        spec = getattr(service, "spec", None)
        if getattr(spec, "type", None) != "ClusterIP":
            return False
        cluster_ip = getattr(spec, "cluster_ip", None)
        if not cluster_ip or cluster_ip == "None":
            return False
        return any(
            getattr(port, "name", None) == "http"
            and KubernetesGitOpsStatusReader._valid_port(getattr(port, "port", None))
            and getattr(port, "target_port", None) == "http"
            and getattr(port, "protocol", None) == "TCP"
            for port in (getattr(spec, "ports", None) or [])
        )

    @staticmethod
    def _pod_ready(pod_status: Any) -> bool:
        return any(
            getattr(condition, "type", None) == "Ready"
            and getattr(condition, "status", None) == "True"
            for condition in (getattr(pod_status, "conditions", None) or [])
        )

    @staticmethod
    def _named_resource(items: list[Any], name: str) -> Any | None:
        matches = [item for item in items if getattr(getattr(item, "metadata", None), "name", None) == name]
        return matches[0] if len(matches) == 1 else None

    @staticmethod
    def _resource_name(resource: Any) -> str | None:
        name = getattr(getattr(resource, "metadata", None), "name", None)
        if (
            not isinstance(name, str)
            or len(name) > 63
            or not KUBERNETES_NAME_PATTERN.fullmatch(name)
        ):
            return None
        return name

    @staticmethod
    def _pod_app_name(pod: Any) -> str | None:
        labels = getattr(getattr(pod, "metadata", None), "labels", None)
        if not isinstance(labels, dict):
            return None
        name = labels.get("app.kubernetes.io/name")
        return name if isinstance(name, str) else None

    @staticmethod
    def _validate_namespace(namespace: object) -> None:
        if (
            not isinstance(namespace, str)
            or len(namespace) > 63
            or not KUBERNETES_NAME_PATTERN.fullmatch(namespace)
        ):
            raise GitOpsStatusError(
                "status_configuration_invalid",
                "The server-side status reader configuration is invalid.",
            )

    @staticmethod
    def _label_selector(app_name: str) -> str:
        labels = {
            "app.kubernetes.io/name": app_name,
            **EXPECTED_LABELS,
        }
        return ",".join(f"{key}={value}" for key, value in labels.items())

    @staticmethod
    def _raise_safe_api_error(error: ApiException) -> None:
        if error.status == 403:
            raise GitOpsStatusError(
                "permission_denied",
                "Deployment status cannot be read with the configured permissions.",
            ) from None
        raise GitOpsStatusError(
            "status_reader_unavailable",
            "Deployment status is temporarily unavailable.",
        ) from None

    @staticmethod
    def _build_api_client(
        *,
        kubeconfig_path: str | None,
        kubeconfig_context: str | None,
        allow_in_cluster: bool,
    ) -> client.ApiClient:
        configuration = client.Configuration()
        try:
            if kubeconfig_path:
                load_options = {
                    "config_file": str(Path(kubeconfig_path).expanduser()),
                    "client_configuration": configuration,
                }
                normalized_context = kubeconfig_context.strip() if kubeconfig_context else ""
                if normalized_context:
                    load_options["context"] = normalized_context
                config.load_kube_config(**load_options)
            elif allow_in_cluster:
                config.load_incluster_config(client_configuration=configuration)
                KubernetesGitOpsStatusReader._normalize_authorization_header(configuration)
            else:
                raise GitOpsStatusError(
                    "status_reader_unavailable",
                    "Deployment status is temporarily unavailable.",
                )
        except GitOpsStatusError:
            raise
        except (ConfigException, OSError, ValueError):
            raise GitOpsStatusError(
                "status_reader_unavailable",
                "Deployment status is temporarily unavailable.",
            ) from None
        return client.ApiClient(configuration)

    @staticmethod
    def _normalize_authorization_header(configuration: client.Configuration) -> None:
        authorization = configuration.api_key.get("authorization") or configuration.api_key.get("BearerToken")
        if not authorization:
            raise ConfigException("In-cluster service account token was not loaded")
        token = authorization.strip()
        if token.lower().startswith("bearer "):
            token = token.split(None, 1)[1].strip()
        configuration.api_key["authorization"] = token
        configuration.api_key_prefix["authorization"] = "Bearer"
        configuration.api_key["BearerToken"] = token
        configuration.api_key_prefix["BearerToken"] = "Bearer"

    @staticmethod
    def _string_or_none(value: object) -> str | None:
        return value if isinstance(value, str) else None

    @staticmethod
    def _int_or_none(value: object) -> int | None:
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            return None
        return value

    @staticmethod
    def _valid_port(value: object) -> bool:
        return isinstance(value, int) and not isinstance(value, bool) and 1 <= value <= 65535
