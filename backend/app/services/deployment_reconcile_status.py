from datetime import datetime, timezone
from typing import Protocol

from app.models.deployment_record import DeploymentRecord
from app.schemas.deployment_reconcile import DeploymentReconcileStatusRead
from app.schemas.deployment_drift import DeploymentDriftStatusRead
from app.schemas.runtime_status import DeploymentRuntimeStatusRead
from app.services.gitops.status_reader import (
    GitOpsStatusError,
    GitOpsStatusRequest,
    RootApplicationSnapshot,
)


FAILED_OPERATION_PHASES = {"Error", "Failed"}
ACTIVE_OPERATION_PHASES = {"Pending", "Running", "Terminating"}
MIN_SHORT_SHA_LENGTH = 7


class RootApplicationReader(Protocol):
    def read_root_application(self, request: GitOpsStatusRequest) -> RootApplicationSnapshot: ...


class DeploymentReconcileStatusService:
    def __init__(
        self,
        *,
        root_reader: RootApplicationReader | None,
        root_application_name: str,
        root_application_namespace: str,
    ):
        self.root_reader = root_reader
        self.root_application_name = root_application_name
        self.root_application_namespace = root_application_namespace
        self._root_snapshot: RootApplicationSnapshot | None = None
        self._root_read_attempted = False

    def evaluate(
        self,
        deployment: DeploymentRecord,
        runtime: DeploymentRuntimeStatusRead,
        drift: DeploymentDriftStatusRead | None = None,
    ) -> DeploymentReconcileStatusRead:
        checked_at = datetime.now(timezone.utc)
        if not deployment.commit_sha:
            return self._result(
                "unknown",
                checked_at,
                message="No GitOps commit is recorded for this deployment.",
            )
        if self.root_reader is None:
            return self._result(
                "unknown",
                checked_at,
                message="Argo CD reconciliation status is temporarily unavailable.",
            )

        root = self._read_root(deployment)
        if root is None:
            return self._result(
                "unknown",
                checked_at,
                message="Argo CD reconciliation status is temporarily unavailable.",
            )
        if not root.exists:
            return self._result(
                "unknown",
                checked_at,
                root=root,
                message="The configured Argo CD Root Application was not found.",
            )

        commit_observed = self._revisions_match(deployment.commit_sha, root.observed_revision)
        operation_matches = self._revisions_match(deployment.commit_sha, root.operation_revision)
        if root.failure_detected or root.health_status == "Degraded":
            return self._result(
                "degraded",
                checked_at,
                root=root,
                commit_observed=commit_observed,
                message="Argo CD reports a degraded reconciliation state.",
            )
        if root.operation_phase in FAILED_OPERATION_PHASES and (
            operation_matches or root.operation_revision is None
        ):
            return self._result(
                "degraded",
                checked_at,
                root=root,
                commit_observed=commit_observed,
                message="Argo CD reports a failed reconciliation operation.",
            )

        if not commit_observed:
            if self._current_revision_confirms_workload(deployment, root, runtime, drift):
                return self._result(
                    "synced",
                    checked_at,
                    root=root,
                    message=(
                        "The Root Application is synchronized at a newer repository revision, "
                        "and the tracked workload matches the deployment record."
                    ),
                )
            if operation_matches and root.operation_phase in ACTIVE_OPERATION_PHASES:
                return self._result(
                    "progressing",
                    checked_at,
                    root=root,
                    message="Argo CD is processing the recorded GitOps revision.",
                )
            return self._result(
                "unknown",
                checked_at,
                root=root,
                message="The Root Application revision does not confirm this deployment commit.",
            )

        if root.sync_status == "OutOfSync":
            state = (
                "progressing"
                if root.operation_phase in ACTIVE_OPERATION_PHASES
                else "drifted"
            )
            message = (
                "Argo CD is reconciling the observed GitOps revision."
                if state == "progressing"
                else "Argo CD observed the commit but reports the desired state as out of sync."
            )
            return self._result(
                state,
                checked_at,
                root=root,
                commit_observed=True,
                message=message,
            )

        if root.health_status == "Progressing" or root.operation_phase in ACTIVE_OPERATION_PHASES:
            return self._result(
                "progressing",
                checked_at,
                root=root,
                commit_observed=True,
                message="Argo CD or the workload is still progressing.",
            )

        if root.sync_status != "Synced" or root.health_status != "Healthy":
            return self._result(
                "unknown",
                checked_at,
                root=root,
                commit_observed=True,
                message="Argo CD evidence is incomplete for a safe reconciliation result.",
            )

        if runtime.display_status == "running" and runtime.deployment_found and runtime.service_found:
            return self._result(
                "synced",
                checked_at,
                root=root,
                commit_observed=True,
                message="GitOps revision, Argo CD, and workload runtime are synchronized and healthy.",
            )
        if runtime.display_status == "progressing":
            return self._result(
                "progressing",
                checked_at,
                root=root,
                commit_observed=True,
                message="Argo CD is synchronized and the workload is progressing toward readiness.",
            )
        if runtime.display_status == "not_found" or (
            runtime.display_status == "unknown" and runtime.deployment_found
        ):
            return self._result(
                "degraded",
                checked_at,
                root=root,
                commit_observed=True,
                message="Argo CD is synchronized but the managed workload is missing or unhealthy.",
            )
        return self._result(
            "unknown",
            checked_at,
            root=root,
            commit_observed=True,
            message="Runtime evidence is unavailable for a safe reconciliation result.",
        )

    @staticmethod
    def _current_revision_confirms_workload(
        deployment: DeploymentRecord,
        root: RootApplicationSnapshot,
        runtime: DeploymentRuntimeStatusRead,
        drift: DeploymentDriftStatusRead | None,
    ) -> bool:
        if root.sync_status != "Synced" or root.health_status != "Healthy":
            return False
        if runtime.display_status != "running" or not runtime.deployment_found or not runtime.service_found:
            return False
        if drift is None or drift.db_to_runtime.status != "aligned":
            return False

        expected = {
            ("apps", "Deployment", deployment.namespace, deployment.app_name),
            ("", "Service", deployment.namespace, deployment.app_name),
        }
        synced = {
            (resource.group, resource.kind, resource.namespace, resource.name)
            for resource in root.resources
            if resource.sync_status == "Synced"
        }
        return expected.issubset(synced)

    def _read_root(self, deployment: DeploymentRecord) -> RootApplicationSnapshot | None:
        if self._root_read_attempted:
            return self._root_snapshot
        self._root_read_attempted = True
        try:
            request = GitOpsStatusRequest(
                app_name=deployment.app_name,
                commit_sha=deployment.commit_sha,
                namespace=deployment.namespace,
                root_application_name=self.root_application_name,
                root_application_namespace=self.root_application_namespace,
            )
            self._root_snapshot = self.root_reader.read_root_application(request)
        except (GitOpsStatusError, OSError, TimeoutError, ValueError):
            self._root_snapshot = None
        return self._root_snapshot

    @staticmethod
    def _revisions_match(expected_revision: str, observed_revision: str | None) -> bool:
        if not isinstance(observed_revision, str):
            return False
        expected = expected_revision.lower()
        observed = observed_revision.lower()
        if expected == observed:
            return True
        shorter, longer = (expected, observed) if len(expected) < len(observed) else (observed, expected)
        return len(shorter) >= MIN_SHORT_SHA_LENGTH and longer.startswith(shorter)

    @staticmethod
    def _result(
        status: str,
        checked_at: datetime,
        *,
        root: RootApplicationSnapshot | None = None,
        commit_observed: bool = False,
        message: str,
    ) -> DeploymentReconcileStatusRead:
        return DeploymentReconcileStatusRead(
            status=status,
            observed_revision=root.observed_revision if root else None,
            sync_status=root.sync_status if root else None,
            health_status=root.health_status if root else None,
            commit_observed=commit_observed,
            checked_at=checked_at,
            message=message,
        )
