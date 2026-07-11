from dataclasses import dataclass
from datetime import datetime, timezone
import logging
import re
import time
from typing import Any, Literal, Protocol

from kubernetes import client
from kubernetes.client.exceptions import ApiException

from app.models.deployment_record import DeploymentRecord
from app.services.gitops.kubernetes_status_reader import KubernetesGitOpsStatusReader
from app.services.gitops.models import validate_app_name, validate_namespace
from app.services.gitops.status_reader import (
    DEFAULT_ROOT_APPLICATION_NAME,
    DEFAULT_ROOT_APPLICATION_NAMESPACE,
    GitOpsStatusError,
    GitOpsStatusRequest,
    RootApplicationSnapshot,
)


logger = logging.getLogger(__name__)
DESTROY_REQUEST_TIMEOUT = (3, 10)
ARGO_OBSERVATION_TIMEOUT_SECONDS = 25.0
ARGO_OBSERVATION_INTERVAL_SECONDS = 1.0
STABILIZATION_RECHECKS = 2
STABILIZATION_INTERVAL_SECONDS = 1.0
MIN_SHORT_SHA_LENGTH = 7
REVISION_PATTERN = re.compile(r"^[0-9a-fA-F]{7,64}$")
EXPECTED_LABELS = {
    "app.kubernetes.io/managed-by": "devdeploy",
    "app.kubernetes.io/part-of": "devdeploy-workloads",
}
RuntimeCleanupStatus = Literal["completed", "pending", "not_required", "unavailable", "failed"]
ResourceState = Literal["absent", "present_owned", "ownership_mismatch", "unavailable"]


@dataclass(frozen=True, slots=True)
class DeploymentRuntimeCleanupResult:
    status: RuntimeCleanupStatus
    deployment_deleted: bool
    service_deleted: bool
    message: str
    checked_at: datetime


class WorkloadRuntimeCleanupClient(Protocol):
    def cleanup_workload(self, *, app_name: str, namespace: str) -> DeploymentRuntimeCleanupResult: ...


class RootApplicationObservationReader(Protocol):
    def read_root_application(self, request: GitOpsStatusRequest) -> RootApplicationSnapshot: ...


class KubernetesWorkloadRuntimeCleanupClient:
    def __init__(
        self,
        *,
        apps_api: Any,
        core_api: Any,
        request_timeout: tuple[int, int] = DESTROY_REQUEST_TIMEOUT,
        stabilization_rechecks: int = STABILIZATION_RECHECKS,
        stabilization_interval_seconds: float = STABILIZATION_INTERVAL_SECONDS,
        sleeper=time.sleep,
    ):
        self.apps_api = apps_api
        self.core_api = core_api
        self.request_timeout = request_timeout
        self.stabilization_rechecks = max(stabilization_rechecks, 0)
        self.stabilization_interval_seconds = max(stabilization_interval_seconds, 0.0)
        self.sleeper = sleeper

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
        initial = self._combined_result(deployment_result, service_result)
        if initial.status not in {"completed", "not_required"}:
            return initial
        return self._verify_stable_absence(
            app_name=app_name,
            namespace=namespace,
            deployment_deleted=deployment_result[1],
            service_deleted=service_result[1],
        )

    def _delete_deployment(self, *, app_name: str, namespace: str) -> tuple[ResourceState, bool]:
        state = self._deployment_state(app_name=app_name, namespace=namespace)
        if state != "present_owned":
            return state, False
        try:
            self.apps_api.delete_namespaced_deployment(
                name=app_name,
                namespace=namespace,
                _request_timeout=self.request_timeout,
            )
            return "absent", True
        except ApiException as error:
            if error.status == 404:
                return "absent", False
            logger.warning("Deployment destroy delete failed with Kubernetes status %s.", error.status)
            return "unavailable", False
        except Exception as error:
            logger.warning("Deployment destroy delete failed: %s.", error.__class__.__name__)
            return "unavailable", False

    def _delete_service(self, *, app_name: str, namespace: str) -> tuple[ResourceState, bool]:
        state = self._service_state(app_name=app_name, namespace=namespace)
        if state != "present_owned":
            return state, False
        try:
            self.core_api.delete_namespaced_service(
                name=app_name,
                namespace=namespace,
                _request_timeout=self.request_timeout,
            )
            return "absent", True
        except ApiException as error:
            if error.status == 404:
                return "absent", False
            logger.warning("Service destroy delete failed with Kubernetes status %s.", error.status)
            return "unavailable", False
        except Exception as error:
            logger.warning("Service destroy delete failed: %s.", error.__class__.__name__)
            return "unavailable", False

    def _deployment_state(self, *, app_name: str, namespace: str) -> ResourceState:
        try:
            deployment = self.apps_api.read_namespaced_deployment(
                name=app_name,
                namespace=namespace,
                _request_timeout=self.request_timeout,
            )
        except ApiException as error:
            if error.status == 404:
                return "absent"
            logger.warning("Deployment destroy read failed with Kubernetes status %s.", error.status)
            return "unavailable"
        except Exception as error:
            logger.warning("Deployment destroy read failed: %s.", error.__class__.__name__)
            return "unavailable"
        if not self._has_expected_labels(deployment, app_name):
            logger.warning("Deployment destroy skipped because ownership labels did not match.")
            return "ownership_mismatch"
        return "present_owned"

    def _service_state(self, *, app_name: str, namespace: str) -> ResourceState:
        try:
            service = self.core_api.read_namespaced_service(
                name=app_name,
                namespace=namespace,
                _request_timeout=self.request_timeout,
            )
        except ApiException as error:
            if error.status == 404:
                return "absent"
            logger.warning("Service destroy read failed with Kubernetes status %s.", error.status)
            return "unavailable"
        except Exception as error:
            logger.warning("Service destroy read failed: %s.", error.__class__.__name__)
            return "unavailable"
        if not self._has_expected_labels(service, app_name):
            logger.warning("Service destroy skipped because ownership labels did not match.")
            return "ownership_mismatch"
        return "present_owned"

    def _verify_stable_absence(
        self,
        *,
        app_name: str,
        namespace: str,
        deployment_deleted: bool,
        service_deleted: bool,
    ) -> DeploymentRuntimeCleanupResult:
        for index in range(self.stabilization_rechecks + 1):
            if index > 0 and self.stabilization_interval_seconds:
                self.sleeper(self.stabilization_interval_seconds)
            deployment_state = self._deployment_state(app_name=app_name, namespace=namespace)
            service_state = self._service_state(app_name=app_name, namespace=namespace)
            states = {deployment_state, service_state}
            if "unavailable" in states:
                return self._result(
                    status="unavailable",
                    deployment_deleted=deployment_deleted,
                    service_deleted=service_deleted,
                    message="Runtime cleanup could not be verified with the configured workload cluster access.",
                )
            if "ownership_mismatch" in states:
                return self._result(
                    status="pending",
                    deployment_deleted=deployment_deleted,
                    service_deleted=service_deleted,
                    message="Runtime cleanup could not verify existing resources as DevDeploy-owned.",
                )
            if "present_owned" in states:
                if index < self.stabilization_rechecks:
                    continue
                return self._result(
                    status="failed",
                    deployment_deleted=deployment_deleted,
                    service_deleted=service_deleted,
                    message="Runtime resources are still present after cleanup verification.",
                )
        status: RuntimeCleanupStatus = "completed" if (deployment_deleted or service_deleted) else "not_required"
        message = (
            "Matching runtime Deployment and Service cleanup completed and stable absence was verified."
            if status == "completed"
            else "No matching runtime Deployment or Service was found after stabilization."
        )
        return self._result(
            status=status,
            deployment_deleted=deployment_deleted,
            service_deleted=service_deleted,
            message=message,
        )

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
        deployment_result: tuple[ResourceState, bool],
        service_result: tuple[ResourceState, bool],
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
        else:
            status = "completed" if (deployment_deleted or service_deleted) else "not_required"
            message = "Runtime cleanup is ready for stabilization verification."
        return KubernetesWorkloadRuntimeCleanupClient._result(
            status=status,
            deployment_deleted=deployment_deleted,
            service_deleted=service_deleted,
            message=message,
        )

    @staticmethod
    def _result(
        *,
        status: RuntimeCleanupStatus,
        deployment_deleted: bool,
        service_deleted: bool,
        message: str,
    ) -> DeploymentRuntimeCleanupResult:
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
        root_reader: RootApplicationObservationReader | None = None,
        root_application_name: str = DEFAULT_ROOT_APPLICATION_NAME,
        root_application_namespace: str = DEFAULT_ROOT_APPLICATION_NAMESPACE,
        argo_observation_timeout_seconds: float = ARGO_OBSERVATION_TIMEOUT_SECONDS,
        argo_observation_interval_seconds: float = ARGO_OBSERVATION_INTERVAL_SECONDS,
        sleeper=time.sleep,
    ):
        self.client = client
        self.managed_namespace = managed_namespace
        self.root_reader = root_reader
        self.root_application_name = root_application_name
        self.root_application_namespace = root_application_namespace
        self.argo_observation_timeout_seconds = max(argo_observation_timeout_seconds, 0.0)
        self.argo_observation_interval_seconds = max(argo_observation_interval_seconds, 0.0)
        self.sleeper = sleeper

    def cleanup(
        self,
        deployment: DeploymentRecord,
        *,
        destroy_commit_sha: str | None,
    ) -> DeploymentRuntimeCleanupResult:
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
        barrier = self._wait_for_destroy_revision(deployment, destroy_commit_sha)
        if barrier is not None:
            return barrier
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
                checked_at=datetime.now(timezone.utc),
            )

    def _wait_for_destroy_revision(
        self,
        deployment: DeploymentRecord,
        destroy_commit_sha: str | None,
    ) -> DeploymentRuntimeCleanupResult | None:
        if not destroy_commit_sha:
            return self._pending_result(
                "Runtime cleanup is waiting for a recorded GitOps destroy revision."
            )
        if self.root_reader is None:
            return DeploymentRuntimeCleanupResult(
                status="unavailable",
                deployment_deleted=False,
                service_deleted=False,
                message="Runtime cleanup is unavailable because Argo CD root Application status cannot be read.",
                checked_at=datetime.now(timezone.utc),
            )
        try:
            request = GitOpsStatusRequest(
                app_name=deployment.app_name,
                commit_sha=destroy_commit_sha,
                namespace=self.managed_namespace,
                root_application_name=self.root_application_name,
                root_application_namespace=self.root_application_namespace,
            )
        except GitOpsStatusError:
            return self._pending_result(
                "Runtime cleanup is waiting because the destroy revision could not be validated."
            )

        deadline = time.monotonic() + self.argo_observation_timeout_seconds
        while True:
            try:
                root = self.root_reader.read_root_application(request)
            except GitOpsStatusError as error:
                logger.warning("Argo destroy observation failed: %s.", error.code)
                return DeploymentRuntimeCleanupResult(
                    status="unavailable",
                    deployment_deleted=False,
                    service_deleted=False,
                    message="Runtime cleanup is unavailable because Argo CD root Application status cannot be read.",
                    checked_at=datetime.now(timezone.utc),
                )
            except Exception as error:
                logger.warning("Argo destroy observation failed: %s.", error.__class__.__name__)
                return DeploymentRuntimeCleanupResult(
                    status="unavailable",
                    deployment_deleted=False,
                    service_deleted=False,
                    message="Runtime cleanup is unavailable because Argo CD root Application status cannot be read.",
                    checked_at=datetime.now(timezone.utc),
                )

            if self._root_observed_destroy_revision(root, destroy_commit_sha):
                return None
            if time.monotonic() >= deadline:
                return self._pending_result(
                    "Runtime cleanup is waiting for Argo CD to observe the GitOps destroy revision."
                )
            if self.argo_observation_interval_seconds:
                self.sleeper(self.argo_observation_interval_seconds)

    @staticmethod
    def _root_observed_destroy_revision(root: RootApplicationSnapshot, expected_revision: str) -> bool:
        if not root.exists or root.failure_detected:
            return False
        if root.sync_status != "Synced":
            return False
        return DeploymentDestroyRuntimeCleanupService._revisions_match(
            expected_revision,
            root.observed_revision,
        )

    @staticmethod
    def _revisions_match(expected_revision: str, observed_revision: str | None) -> bool:
        if not REVISION_PATTERN.fullmatch(expected_revision or ""):
            return False
        if not isinstance(observed_revision, str) or not REVISION_PATTERN.fullmatch(observed_revision):
            return False
        expected = expected_revision.lower()
        observed = observed_revision.lower()
        if expected == observed:
            return True
        shorter, longer = (expected, observed) if len(expected) < len(observed) else (observed, expected)
        return len(shorter) >= MIN_SHORT_SHA_LENGTH and longer.startswith(shorter)

    @staticmethod
    def _pending_result(message: str) -> DeploymentRuntimeCleanupResult:
        return DeploymentRuntimeCleanupResult(
            status="pending",
            deployment_deleted=False,
            service_deleted=False,
            message=message,
            checked_at=datetime.now(timezone.utc),
        )
