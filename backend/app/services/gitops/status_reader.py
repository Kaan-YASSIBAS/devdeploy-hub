from dataclasses import dataclass
import re
from typing import Literal, Protocol

from app.services.gitops.models import validate_app_name


DEFAULT_WORKLOAD_NAMESPACE = "devdeploy-apps"
DEFAULT_ROOT_APPLICATION_NAME = "devdeploy-workloads-root"
DEFAULT_ROOT_APPLICATION_NAMESPACE = "argocd"
GIT_OBJECT_ID_PATTERN = re.compile(r"^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$")
KUBERNETES_NAME_PATTERN = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")
KNOWN_SYNC_STATUSES = {"Synced", "OutOfSync", "Unknown"}
KNOWN_HEALTH_STATUSES = {"Healthy", "Progressing", "Degraded", "Suspended", "Missing", "Unknown"}

GitOpsAppStatus = Literal[
    "pushed_waiting_for_argocd",
    "argocd_observing",
    "argocd_synced",
    "workload_progressing",
    "deployed",
    "degraded",
    "unknown",
]


class GitOpsStatusError(ValueError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


@dataclass(frozen=True, slots=True)
class GitOpsStatusRequest:
    app_name: str
    commit_sha: str
    namespace: str = DEFAULT_WORKLOAD_NAMESPACE
    root_application_name: str = DEFAULT_ROOT_APPLICATION_NAME
    root_application_namespace: str = DEFAULT_ROOT_APPLICATION_NAMESPACE

    def __post_init__(self) -> None:
        try:
            validate_app_name(self.app_name)
        except ValueError:
            raise GitOpsStatusError("invalid_app_name", "The app name is invalid.") from None
        if not isinstance(self.commit_sha, str) or not GIT_OBJECT_ID_PATTERN.fullmatch(self.commit_sha):
            raise GitOpsStatusError("invalid_commit_sha", "The commit SHA is invalid.")
        for value in (self.namespace, self.root_application_name, self.root_application_namespace):
            if (
                not isinstance(value, str)
                or len(value) > 63
                or not KUBERNETES_NAME_PATTERN.fullmatch(value)
            ):
                raise GitOpsStatusError(
                    "status_configuration_invalid",
                    "The server-side status reader configuration is invalid.",
                )


@dataclass(frozen=True, slots=True)
class RootApplicationSnapshot:
    exists: bool
    observed_revision: str | None = None
    sync_status: str | None = None
    health_status: str | None = None
    failure_detected: bool = False


@dataclass(frozen=True, slots=True)
class ServicePortSnapshot:
    name: str | None
    port: int
    target_port: int | str | None
    protocol: str | None


@dataclass(frozen=True, slots=True)
class WorkloadSnapshot:
    deployment_exists: bool = False
    service_exists: bool = False
    desired_replicas: int | None = None
    ready_replicas: int | None = None
    available_replicas: int | None = None
    updated_replicas: int | None = None
    generation: int | None = None
    observed_generation: int | None = None
    expected_service_port_exists: bool = False
    pod_count: int = 0
    running_pod_count: int = 0
    ready_pod_count: int = 0
    restart_count: int = 0
    waiting_reasons: tuple[str, ...] = ()
    pod_phases: tuple[str, ...] = ()
    failure_detected: bool = False
    pod_crashloop_detected: bool = False
    service_type: str | None = None
    service_cluster_ip: str | None = None
    service_ports: tuple[ServicePortSnapshot, ...] = ()


@dataclass(frozen=True, slots=True)
class GitOpsStatusSnapshot:
    root_application: RootApplicationSnapshot
    workload: WorkloadSnapshot


@dataclass(frozen=True, slots=True)
class RootApplicationStatusSummary:
    name: str
    sync_status: str | None
    health_status: str | None
    observed_commit_match: bool


@dataclass(frozen=True, slots=True)
class WorkloadStatusSummary:
    deployment_ready: bool
    service_ready: bool
    pods_ready: bool
    desired_replicas: int | None
    ready_replicas: int | None
    available_replicas: int | None
    pod_count: int
    ready_pod_count: int


@dataclass(frozen=True, slots=True)
class GitOpsStatusResult:
    status: GitOpsAppStatus
    app_name: str
    namespace: str
    commit_sha: str
    observed_revision: str | None
    root_application: RootApplicationStatusSummary
    workload: WorkloadStatusSummary
    message: str
    error_code: str | None = None


class GitOpsStatusSnapshotReader(Protocol):
    def read(self, request: GitOpsStatusRequest) -> GitOpsStatusSnapshot:
        ...


class UnavailableGitOpsStatusReader:
    def read(self, request: GitOpsStatusRequest) -> GitOpsStatusSnapshot:
        _ = request
        raise GitOpsStatusError(
            "status_reader_unavailable",
            "Deployment status is temporarily unavailable.",
        )


class GitOpsStatusEvaluator:
    def evaluate(self, request: GitOpsStatusRequest, snapshot: GitOpsStatusSnapshot) -> GitOpsStatusResult:
        observed_revision = self._normalize_revision(snapshot.root_application.observed_revision)
        sync_status = self._known_value(snapshot.root_application.sync_status, KNOWN_SYNC_STATUSES)
        health_status = self._known_value(snapshot.root_application.health_status, KNOWN_HEALTH_STATUSES)
        observed_commit_match = observed_revision == request.commit_sha.lower()
        root_summary = RootApplicationStatusSummary(
            name=request.root_application_name,
            sync_status=sync_status,
            health_status=health_status,
            observed_commit_match=observed_commit_match,
        )
        workload_summary = self._workload_summary(snapshot.workload)

        if not snapshot.root_application.exists:
            return self._result(
                request,
                observed_revision,
                root_summary,
                workload_summary,
                status="unknown",
                message="The configured Argo CD Root Application was not found.",
                error_code="argocd_application_missing",
            )

        if health_status == "Degraded" or snapshot.root_application.failure_detected:
            return self._result(
                request,
                observed_revision,
                root_summary,
                workload_summary,
                status="degraded",
                message="Argo CD reports a degraded workload tree.",
                error_code="argocd_degraded",
            )

        if not observed_commit_match:
            return self._result(
                request,
                observed_revision,
                root_summary,
                workload_summary,
                status="pushed_waiting_for_argocd",
                message="The GitOps commit is waiting for Argo CD observation.",
                error_code="argocd_revision_pending",
            )

        if sync_status != "Synced":
            return self._result(
                request,
                observed_revision,
                root_summary,
                workload_summary,
                status="argocd_observing",
                message="Argo CD has observed the commit and reconciliation is in progress.",
                error_code="argocd_out_of_sync" if sync_status == "OutOfSync" else None,
            )

        if health_status != "Healthy":
            return self._result(
                request,
                observed_revision,
                root_summary,
                workload_summary,
                status="argocd_synced",
                message="Argo CD has synchronized the commit; health evaluation is still in progress.",
            )

        if snapshot.workload.failure_detected or snapshot.workload.pod_crashloop_detected:
            return self._result(
                request,
                observed_revision,
                root_summary,
                workload_summary,
                status="degraded",
                message="The workload reports a readiness or runtime failure.",
                error_code=(
                    "workload_pod_crashloop"
                    if snapshot.workload.pod_crashloop_detected
                    else "unknown"
                ),
            )

        if (
            workload_summary.deployment_ready
            and workload_summary.service_ready
            and workload_summary.pods_ready
        ):
            return self._result(
                request,
                observed_revision,
                root_summary,
                workload_summary,
                status="deployed",
                message="Argo CD is synchronized and the workload is ready.",
            )

        return self._result(
            request,
            observed_revision,
            root_summary,
            workload_summary,
            status="workload_progressing",
            message="Argo CD is synchronized and workload readiness is pending.",
            error_code=self._workload_pending_error(snapshot.workload, workload_summary),
        )

    @staticmethod
    def unavailable_result(request: GitOpsStatusRequest, error_code: str) -> GitOpsStatusResult:
        message = (
            "Deployment status cannot be read with the configured permissions."
            if error_code == "permission_denied"
            else "Deployment status is temporarily unavailable."
        )
        return GitOpsStatusResult(
            status="unknown",
            app_name=request.app_name,
            namespace=request.namespace,
            commit_sha=request.commit_sha.lower(),
            observed_revision=None,
            root_application=RootApplicationStatusSummary(
                name=request.root_application_name,
                sync_status=None,
                health_status=None,
                observed_commit_match=False,
            ),
            workload=WorkloadStatusSummary(
                deployment_ready=False,
                service_ready=False,
                pods_ready=False,
                desired_replicas=None,
                ready_replicas=None,
                available_replicas=None,
                pod_count=0,
                ready_pod_count=0,
            ),
            message=message,
            error_code=error_code,
        )

    @staticmethod
    def _workload_summary(snapshot: WorkloadSnapshot) -> WorkloadStatusSummary:
        desired = GitOpsStatusEvaluator._nonnegative_int(snapshot.desired_replicas)
        ready = GitOpsStatusEvaluator._nonnegative_int(snapshot.ready_replicas)
        available = GitOpsStatusEvaluator._nonnegative_int(snapshot.available_replicas)
        updated = GitOpsStatusEvaluator._nonnegative_int(snapshot.updated_replicas)
        generation = GitOpsStatusEvaluator._nonnegative_int(snapshot.generation)
        observed_generation = GitOpsStatusEvaluator._nonnegative_int(snapshot.observed_generation)
        pod_count = GitOpsStatusEvaluator._nonnegative_int(snapshot.pod_count) or 0
        ready_pod_count = GitOpsStatusEvaluator._nonnegative_int(snapshot.ready_pod_count) or 0

        deployment_ready = bool(
            snapshot.deployment_exists
            and desired is not None
            and desired > 0
            and ready is not None
            and ready >= desired
            and available is not None
            and available >= desired
            and updated is not None
            and updated >= desired
            and generation is not None
            and observed_generation is not None
            and observed_generation >= generation
        )
        service_ready = bool(snapshot.service_exists and snapshot.expected_service_port_exists)
        running_pod_count = GitOpsStatusEvaluator._nonnegative_int(snapshot.running_pod_count) or 0
        pods_ready = bool(
            desired is not None
            and desired > 0
            and running_pod_count >= desired
            and ready_pod_count >= desired
        )
        return WorkloadStatusSummary(
            deployment_ready=deployment_ready,
            service_ready=service_ready,
            pods_ready=pods_ready,
            desired_replicas=desired,
            ready_replicas=ready,
            available_replicas=available,
            pod_count=pod_count,
            ready_pod_count=ready_pod_count,
        )

    @staticmethod
    def _workload_pending_error(
        snapshot: WorkloadSnapshot,
        summary: WorkloadStatusSummary,
    ) -> str:
        if not snapshot.deployment_exists:
            return "workload_deployment_missing"
        if not snapshot.service_exists or not summary.service_ready:
            return "workload_service_missing"
        return "workload_pods_not_ready"

    @staticmethod
    def _result(
        request: GitOpsStatusRequest,
        observed_revision: str | None,
        root_application: RootApplicationStatusSummary,
        workload: WorkloadStatusSummary,
        *,
        status: GitOpsAppStatus,
        message: str,
        error_code: str | None = None,
    ) -> GitOpsStatusResult:
        return GitOpsStatusResult(
            status=status,
            app_name=request.app_name,
            namespace=request.namespace,
            commit_sha=request.commit_sha.lower(),
            observed_revision=observed_revision,
            root_application=root_application,
            workload=workload,
            message=message,
            error_code=error_code,
        )

    @staticmethod
    def _normalize_revision(value: object) -> str | None:
        if not isinstance(value, str) or not GIT_OBJECT_ID_PATTERN.fullmatch(value):
            return None
        return value.lower()

    @staticmethod
    def _known_value(value: object, allowed: set[str]) -> str | None:
        return value if isinstance(value, str) and value in allowed else None

    @staticmethod
    def _nonnegative_int(value: object) -> int | None:
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            return None
        return value


class GitOpsStatusService:
    def __init__(
        self,
        *,
        reader: GitOpsStatusSnapshotReader | None = None,
        evaluator: GitOpsStatusEvaluator | None = None,
    ):
        self.reader = reader or UnavailableGitOpsStatusReader()
        self.evaluator = evaluator or GitOpsStatusEvaluator()

    def read_status(self, request: GitOpsStatusRequest) -> GitOpsStatusResult:
        try:
            snapshot = self.reader.read(request)
        except GitOpsStatusError as error:
            error_code = error.code if error.code in {"permission_denied", "status_reader_unavailable"} else "unknown"
            return self.evaluator.unavailable_result(request, error_code)
        except Exception:
            return self.evaluator.unavailable_result(request, "status_reader_unavailable")
        try:
            return self.evaluator.evaluate(request, snapshot)
        except Exception:
            return self.evaluator.unavailable_result(request, "status_reader_unavailable")
