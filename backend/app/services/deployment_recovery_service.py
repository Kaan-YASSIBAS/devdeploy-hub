from dataclasses import dataclass
from datetime import datetime, timezone
import logging
import time
from typing import Any, Literal, Protocol

from kubernetes import client
from kubernetes.client.exceptions import ApiException

from app.models.deployment_record import DeploymentRecord
from app.services.deployment_destroy_service import (
    ARGO_OBSERVATION_INTERVAL_SECONDS,
    ARGO_OBSERVATION_TIMEOUT_SECONDS,
    DESTROY_REQUEST_TIMEOUT,
    RootApplicationObservationReader,
)
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
RUNTIME_READINESS_TIMEOUT_SECONDS = 45.0
RUNTIME_READINESS_INTERVAL_SECONDS = 2.0
RecoveryVerificationStatus = Literal["ready", "pending", "conflict", "unavailable", "failed"]
EXPECTED_LABELS = {
    "app.kubernetes.io/managed-by": "devdeploy",
    "app.kubernetes.io/part-of": "devdeploy-workloads",
}


@dataclass(frozen=True, slots=True)
class DeploymentRecoveryVerificationResult:
    status: RecoveryVerificationStatus
    message: str
    checked_at: datetime


class RecoveredWorkloadReadinessClient(Protocol):
    def verify_ready(
        self,
        *,
        app_name: str,
        namespace: str,
        expected_replicas: int,
    ) -> DeploymentRecoveryVerificationResult: ...


class KubernetesRecoveredWorkloadReadinessClient:
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
    ) -> "KubernetesRecoveredWorkloadReadinessClient":
        api_client = KubernetesGitOpsStatusReader._build_api_client(
            kubeconfig_path=workload_kubeconfig,
            kubeconfig_context=workload_kubeconfig_context,
            allow_in_cluster=False,
        )
        return cls(
            apps_api=client.AppsV1Api(api_client),
            core_api=client.CoreV1Api(api_client),
        )

    def verify_ready(
        self,
        *,
        app_name: str,
        namespace: str,
        expected_replicas: int,
    ) -> DeploymentRecoveryVerificationResult:
        validate_app_name(app_name)
        validate_namespace(namespace)
        deployment_result = self._deployment_ready(
            app_name=app_name,
            namespace=namespace,
            expected_replicas=expected_replicas,
        )
        if deployment_result is not None:
            return deployment_result
        service_result = self._service_ready(app_name=app_name, namespace=namespace)
        if service_result is not None:
            return service_result
        return self._result(
            "ready",
            "Recovered Deployment and Service are ready and ownership was verified.",
        )

    def _deployment_ready(
        self,
        *,
        app_name: str,
        namespace: str,
        expected_replicas: int,
    ) -> DeploymentRecoveryVerificationResult | None:
        try:
            deployment = self.apps_api.read_namespaced_deployment(
                name=app_name,
                namespace=namespace,
                _request_timeout=self.request_timeout,
            )
        except ApiException as error:
            if error.status == 404:
                return self._result("pending", "Recovered Deployment has not appeared yet.")
            logger.warning("Recovered Deployment read failed with Kubernetes status %s.", error.status)
            return self._result("unavailable", "Recovered Deployment readiness could not be read safely.")
        except Exception as error:
            logger.warning("Recovered Deployment read failed: %s.", error.__class__.__name__)
            return self._result("unavailable", "Recovered Deployment readiness could not be read safely.")

        if not self._has_expected_labels(deployment, app_name):
            return self._result("conflict", "Recovered Deployment name is occupied by a resource without DevDeploy ownership.")
        status = getattr(deployment, "status", None)
        metadata = getattr(deployment, "metadata", None)
        generation = self._int_or_none(getattr(metadata, "generation", None))
        observed_generation = self._int_or_none(getattr(status, "observed_generation", None))
        available_replicas = self._int_or_none(getattr(status, "available_replicas", None)) or 0
        ready_replicas = self._int_or_none(getattr(status, "ready_replicas", None)) or 0
        updated_replicas = self._int_or_none(getattr(status, "updated_replicas", None)) or 0
        available_condition = self._condition_true(getattr(status, "conditions", None), "Available")
        if (
            generation is not None
            and observed_generation is not None
            and observed_generation >= generation
            and expected_replicas > 0
            and ready_replicas >= expected_replicas
            and available_replicas >= expected_replicas
            and updated_replicas >= expected_replicas
            and available_condition
        ):
            return None
        return self._result("pending", "Recovered Deployment is not Available yet.")

    def _service_ready(
        self,
        *,
        app_name: str,
        namespace: str,
    ) -> DeploymentRecoveryVerificationResult | None:
        try:
            service = self.core_api.read_namespaced_service(
                name=app_name,
                namespace=namespace,
                _request_timeout=self.request_timeout,
            )
        except ApiException as error:
            if error.status == 404:
                return self._result("pending", "Recovered Service has not appeared yet.")
            logger.warning("Recovered Service read failed with Kubernetes status %s.", error.status)
            return self._result("unavailable", "Recovered Service readiness could not be read safely.")
        except Exception as error:
            logger.warning("Recovered Service read failed: %s.", error.__class__.__name__)
            return self._result("unavailable", "Recovered Service readiness could not be read safely.")

        if not self._has_expected_labels(service, app_name):
            return self._result("conflict", "Recovered Service name is occupied by a resource without DevDeploy ownership.")
        return None

    @staticmethod
    def _has_expected_labels(resource: Any, app_name: str) -> bool:
        labels = getattr(getattr(resource, "metadata", None), "labels", None)
        if not isinstance(labels, dict):
            return False
        return labels.get("app.kubernetes.io/name") == app_name and all(
            labels.get(key) == value for key, value in EXPECTED_LABELS.items()
        )

    @staticmethod
    def _condition_true(conditions: Any, condition_type: str) -> bool:
        return any(
            getattr(condition, "type", None) == condition_type
            and getattr(condition, "status", None) == "True"
            for condition in (conditions or [])
        )

    @staticmethod
    def _int_or_none(value: object) -> int | None:
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            return None
        return value

    @staticmethod
    def _result(
        status: RecoveryVerificationStatus,
        message: str,
    ) -> DeploymentRecoveryVerificationResult:
        return DeploymentRecoveryVerificationResult(
            status=status,
            message=message,
            checked_at=datetime.now(timezone.utc),
        )


class DeploymentRecoveryVerificationService:
    def __init__(
        self,
        *,
        readiness_client: RecoveredWorkloadReadinessClient | None,
        root_reader: RootApplicationObservationReader | None,
        managed_namespace: str,
        root_application_name: str = DEFAULT_ROOT_APPLICATION_NAME,
        root_application_namespace: str = DEFAULT_ROOT_APPLICATION_NAMESPACE,
        argo_observation_timeout_seconds: float = ARGO_OBSERVATION_TIMEOUT_SECONDS,
        argo_observation_interval_seconds: float = ARGO_OBSERVATION_INTERVAL_SECONDS,
        runtime_readiness_timeout_seconds: float = RUNTIME_READINESS_TIMEOUT_SECONDS,
        runtime_readiness_interval_seconds: float = RUNTIME_READINESS_INTERVAL_SECONDS,
        sleeper=time.sleep,
    ):
        self.readiness_client = readiness_client
        self.root_reader = root_reader
        self.managed_namespace = managed_namespace
        self.root_application_name = root_application_name
        self.root_application_namespace = root_application_namespace
        self.argo_observation_timeout_seconds = max(argo_observation_timeout_seconds, 0.0)
        self.argo_observation_interval_seconds = max(argo_observation_interval_seconds, 0.0)
        self.runtime_readiness_timeout_seconds = max(runtime_readiness_timeout_seconds, 0.0)
        self.runtime_readiness_interval_seconds = max(runtime_readiness_interval_seconds, 0.0)
        self.sleeper = sleeper

    def verify_recovered(
        self,
        deployment: DeploymentRecord,
        *,
        recovery_commit_sha: str | None,
    ) -> DeploymentRecoveryVerificationResult:
        if deployment.namespace != self.managed_namespace:
            return self._result("conflict", "Recovery namespace is not managed by DevDeploy.")
        if self.readiness_client is None or self.root_reader is None:
            return self._result("unavailable", "Recovery verification is unavailable because cluster access is not configured.")
        if not recovery_commit_sha:
            return self._result("pending", "Recovery is waiting for a recorded GitOps revision.")
        try:
            request = GitOpsStatusRequest(
                app_name=deployment.app_name,
                commit_sha=recovery_commit_sha,
                namespace=self.managed_namespace,
                root_application_name=self.root_application_name,
                root_application_namespace=self.root_application_namespace,
            )
        except GitOpsStatusError:
            return self._result("conflict", "Recovery revision or application identity is invalid.")

        argo_result = self._wait_for_recovery_revision(request, recovery_commit_sha)
        if argo_result is not None:
            return argo_result
        return self._wait_for_runtime_readiness(deployment)

    def _wait_for_recovery_revision(
        self,
        request: GitOpsStatusRequest,
        recovery_commit_sha: str,
    ) -> DeploymentRecoveryVerificationResult | None:
        try:
            self.root_reader.request_reconciliation(request, recovery_commit_sha)
        except GitOpsStatusError as error:
            logger.warning("Argo recovery reconciliation request failed: %s.", error.code)
            return self._result("unavailable", "Recovery could not request Argo CD reconciliation safely.")
        except Exception as error:
            logger.warning("Argo recovery reconciliation request failed: %s.", error.__class__.__name__)
            return self._result("unavailable", "Recovery could not request Argo CD reconciliation safely.")

        deadline = time.monotonic() + self.argo_observation_timeout_seconds
        while True:
            try:
                root = self.root_reader.read_root_application(request)
            except GitOpsStatusError as error:
                logger.warning("Argo recovery observation failed: %s.", error.code)
                return self._result("unavailable", "Recovery could not read Argo CD reconciliation status safely.")
            except Exception as error:
                logger.warning("Argo recovery observation failed: %s.", error.__class__.__name__)
                return self._result("unavailable", "Recovery could not read Argo CD reconciliation status safely.")

            if self._argo_processed_revision(root, recovery_commit_sha):
                return None
            if root.operation_phase in {"Error", "Failed"}:
                return self._result("failed", "Argo CD reported a failed recovery sync operation.")
            if time.monotonic() >= deadline:
                return self._result("pending", "Recovery is waiting for Argo CD to process the GitOps revision.")
            if self.argo_observation_interval_seconds:
                self.sleeper(self.argo_observation_interval_seconds)

    def _wait_for_runtime_readiness(self, deployment: DeploymentRecord) -> DeploymentRecoveryVerificationResult:
        deadline = time.monotonic() + self.runtime_readiness_timeout_seconds
        while True:
            try:
                result = self.readiness_client.verify_ready(
                    app_name=deployment.app_name,
                    namespace=deployment.namespace,
                    expected_replicas=deployment.replicas,
                )
            except Exception as error:
                logger.warning("Recovered runtime readiness check failed: %s.", error.__class__.__name__)
                return self._result("unavailable", "Recovered runtime readiness could not be verified safely.")
            if result.status != "pending":
                return result
            if time.monotonic() >= deadline:
                return result
            if self.runtime_readiness_interval_seconds:
                self.sleeper(self.runtime_readiness_interval_seconds)

    @staticmethod
    def _argo_processed_revision(root: RootApplicationSnapshot, expected_revision: str) -> bool:
        if not root.exists or root.failure_detected:
            return False
        if root.operation_phase != "Succeeded":
            return False
        if not DeploymentRecoveryVerificationService._revisions_match(expected_revision, root.observed_revision):
            return False
        if root.operation_revision is not None and not DeploymentRecoveryVerificationService._revisions_match(
            expected_revision,
            root.operation_revision,
        ):
            return False
        return True

    @staticmethod
    def _revisions_match(expected_revision: str, observed_revision: str | None) -> bool:
        observed = KubernetesGitOpsStatusReader._string_or_none(observed_revision)
        expected = KubernetesGitOpsStatusReader._string_or_none(expected_revision)
        if observed is None or expected is None:
            return False
        expected = expected.lower()
        observed = observed.lower()
        if expected == observed:
            return True
        shorter, longer = (expected, observed) if len(expected) < len(observed) else (observed, expected)
        return len(shorter) >= 7 and longer.startswith(shorter)

    @staticmethod
    def _result(
        status: RecoveryVerificationStatus,
        message: str,
    ) -> DeploymentRecoveryVerificationResult:
        return DeploymentRecoveryVerificationResult(
            status=status,
            message=message,
            checked_at=datetime.now(timezone.utc),
        )
