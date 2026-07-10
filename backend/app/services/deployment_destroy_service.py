from dataclasses import dataclass
from datetime import datetime, timezone
import logging
from typing import Any, Literal, Protocol

from kubernetes import client
from kubernetes.client.exceptions import ApiException

from app.models.deployment_record import DeploymentRecord
from app.services.gitops.kubernetes_status_reader import KubernetesGitOpsStatusReader
from app.services.gitops.models import validate_app_name, validate_namespace


logger = logging.getLogger(__name__)
DESTROY_REQUEST_TIMEOUT = (3, 10)
EXPECTED_LABELS = {
    "app.kubernetes.io/managed-by": "devdeploy",
    "app.kubernetes.io/part-of": "devdeploy-workloads",
}
RuntimeCleanupStatus = Literal["completed", "pending", "not_required", "unavailable"]


@dataclass(frozen=True, slots=True)
class DeploymentRuntimeCleanupResult:
    status: RuntimeCleanupStatus
    deployment_deleted: bool
    service_deleted: bool
    message: str
    checked_at: datetime


class WorkloadRuntimeCleanupClient(Protocol):
    def cleanup_workload(self, *, app_name: str, namespace: str) -> DeploymentRuntimeCleanupResult: ...


class KubernetesWorkloadRuntimeCleanupClient:
    def __init__(
        self,
        *,
        apps_api: Any,
        core_api: Any,
        request_timeout: tuple[int, int] = DESTROY_REQUEST_TIMEOUT,
    ):
        self.apps_api = apps_api
        self.core_api = core_api
        self.request_timeout = request_timeout

    @classmethod
    def from_server_config(
        cls,
        *,
        workload_kubeconfig: str | None,
        workload_kubeconfig_context: str | None,
    ) -> "KubernetesWorkloadRuntimeCleanupClient":
        api_client = KubernetesGitOpsStatusReader._build_api_client(
            kubeconfig_path=workload_kubeconfig,
            kubeconfig_context=workload_kubeconfig_context,
            allow_in_cluster=False,
        )
        return cls(
            apps_api=client.AppsV1Api(api_client),
            core_api=client.CoreV1Api(api_client),
        )

    def cleanup_workload(self, *, app_name: str, namespace: str) -> DeploymentRuntimeCleanupResult:
        validate_app_name(app_name)
        validate_namespace(namespace)
        deployment_result = self._delete_deployment(app_name=app_name, namespace=namespace)
        service_result = self._delete_service(app_name=app_name, namespace=namespace)
        return self._combined_result(deployment_result, service_result)

    def _delete_deployment(self, *, app_name: str, namespace: str) -> tuple[str, bool]:
        try:
            deployment = self.apps_api.read_namespaced_deployment(
                name=app_name,
                namespace=namespace,
                _request_timeout=self.request_timeout,
            )
        except ApiException as error:
            if error.status == 404:
                return "absent", False
            logger.warning("Deployment destroy read failed with Kubernetes status %s.", error.status)
            return "unavailable", False
        except Exception as error:
            logger.warning("Deployment destroy read failed: %s.", error.__class__.__name__)
            return "unavailable", False

        if not self._has_expected_labels(deployment, app_name):
            logger.warning("Deployment destroy skipped because ownership labels did not match.")
            return "ownership_mismatch", False

        try:
            self.apps_api.delete_namespaced_deployment(
                name=app_name,
                namespace=namespace,
                _request_timeout=self.request_timeout,
            )
            return "deleted", True
        except ApiException as error:
            if error.status == 404:
                return "absent", False
            logger.warning("Deployment destroy delete failed with Kubernetes status %s.", error.status)
            return "unavailable", False
        except Exception as error:
            logger.warning("Deployment destroy delete failed: %s.", error.__class__.__name__)
            return "unavailable", False

    def _delete_service(self, *, app_name: str, namespace: str) -> tuple[str, bool]:
        try:
            service = self.core_api.read_namespaced_service(
                name=app_name,
                namespace=namespace,
                _request_timeout=self.request_timeout,
            )
        except ApiException as error:
            if error.status == 404:
                return "absent", False
            logger.warning("Service destroy read failed with Kubernetes status %s.", error.status)
            return "unavailable", False
        except Exception as error:
            logger.warning("Service destroy read failed: %s.", error.__class__.__name__)
            return "unavailable", False

        if not self._has_expected_labels(service, app_name):
            logger.warning("Service destroy skipped because ownership labels did not match.")
            return "ownership_mismatch", False

        try:
            self.core_api.delete_namespaced_service(
                name=app_name,
                namespace=namespace,
                _request_timeout=self.request_timeout,
            )
            return "deleted", True
        except ApiException as error:
            if error.status == 404:
                return "absent", False
            logger.warning("Service destroy delete failed with Kubernetes status %s.", error.status)
            return "unavailable", False
        except Exception as error:
            logger.warning("Service destroy delete failed: %s.", error.__class__.__name__)
            return "unavailable", False

    @staticmethod
    def _has_expected_labels(resource: Any, app_name: str) -> bool:
        labels = getattr(getattr(resource, "metadata", None), "labels", None)
        if not isinstance(labels, dict):
            return False
        return labels.get("app.kubernetes.io/name") == app_name and all(
            labels.get(key) == value for key, value in EXPECTED_LABELS.items()
        )

    @staticmethod
    def _combined_result(
        deployment_result: tuple[str, bool],
        service_result: tuple[str, bool],
    ) -> DeploymentRuntimeCleanupResult:
        states = {deployment_result[0], service_result[0]}
        deployment_deleted = deployment_result[1]
        service_deleted = service_result[1]
        if "unavailable" in states:
            status: RuntimeCleanupStatus = "unavailable"
            message = "Runtime cleanup could not be verified with the configured workload cluster access."
        elif "ownership_mismatch" in states:
            status = "pending"
            message = "Runtime cleanup was skipped because existing resources could not be verified as DevDeploy-owned."
        elif states == {"absent"}:
            status = "not_required"
            message = "No matching runtime Deployment or Service was found."
        else:
            status = "completed"
            message = "Matching runtime Deployment and Service cleanup completed or was not required."
        return DeploymentRuntimeCleanupResult(
            status=status,
            deployment_deleted=deployment_deleted,
            service_deleted=service_deleted,
            message=message,
            checked_at=datetime.now(timezone.utc),
        )


class DeploymentDestroyRuntimeCleanupService:
    def __init__(
        self,
        *,
        client: WorkloadRuntimeCleanupClient | None,
        managed_namespace: str,
    ):
        self.client = client
        self.managed_namespace = managed_namespace

    def cleanup(self, deployment: DeploymentRecord) -> DeploymentRuntimeCleanupResult:
        checked_at = datetime.now(timezone.utc)
        if deployment.namespace != self.managed_namespace:
            return DeploymentRuntimeCleanupResult(
                status="pending",
                deployment_deleted=False,
                service_deleted=False,
                message="Runtime cleanup was skipped because the deployment namespace is not managed.",
                checked_at=checked_at,
            )
        if self.client is None:
            return DeploymentRuntimeCleanupResult(
                status="unavailable",
                deployment_deleted=False,
                service_deleted=False,
                message="Runtime cleanup is unavailable because workload cluster access is not configured.",
                checked_at=checked_at,
            )
        try:
            return self.client.cleanup_workload(
                app_name=deployment.app_name,
                namespace=deployment.namespace,
            )
        except Exception as error:
            logger.warning("Deployment runtime cleanup failed: %s.", error.__class__.__name__)
            return DeploymentRuntimeCleanupResult(
                status="unavailable",
                deployment_deleted=False,
                service_deleted=False,
                message="Runtime cleanup could not be completed safely.",
                checked_at=checked_at,
            )
