import unittest
from types import SimpleNamespace

from app.schemas.runtime_status import DeploymentRuntimeStatusRead
from app.schemas.deployment_drift import (
    DeploymentDriftStatusRead,
    DriftComparisonRead,
)
from app.services.deployment_reconcile_status import DeploymentReconcileStatusService
from app.services.gitops.status_reader import ArgoResourceSnapshot, RootApplicationSnapshot
from datetime import datetime, timezone


COMMIT_SHA = "a" * 40


class StaticRootApplicationReader:
    def __init__(self, snapshot: RootApplicationSnapshot | None):
        self.snapshot = snapshot
        self.requests = []

    def read_root_application(self, request):
        self.requests.append(request)
        if self.snapshot is None:
            raise OSError("raw Kubernetes connection detail")
        return self.snapshot


def deployment(commit_sha: str | None = COMMIT_SHA):
    return SimpleNamespace(
        app_name="recover-nginx",
        namespace="devdeploy-apps",
        commit_sha=commit_sha,
    )


def runtime(
    display_status: str = "running",
    *,
    deployment_found: bool = True,
    service_found: bool = True,
) -> DeploymentRuntimeStatusRead:
    return DeploymentRuntimeStatusRead(
        display_status=display_status,
        deployment_found=deployment_found,
        service_found=service_found,
    )


def service(snapshot: RootApplicationSnapshot | None) -> DeploymentReconcileStatusService:
    return DeploymentReconcileStatusService(
        root_reader=StaticRootApplicationReader(snapshot),
        root_application_name="devdeploy-workloads-root",
        root_application_namespace="argocd",
    )

def aligned_runtime_drift() -> DeploymentDriftStatusRead:
    return DeploymentDriftStatusRead(
        status="unknown",
        db_to_gitops=DriftComparisonRead(status="unknown"),
        db_to_runtime=DriftComparisonRead(status="aligned"),
        checked_at=datetime.now(timezone.utc),
        message="GitOps manifest access is unavailable, but runtime alignment is known.",
    )


class DeploymentReconcileStatusTestCase(unittest.TestCase):
    def test_matching_revision_and_healthy_evidence_is_synced(self) -> None:
        result = service(
            RootApplicationSnapshot(
                exists=True,
                observed_revision=COMMIT_SHA,
                sync_status="Synced",
                health_status="Healthy",
            )
        ).evaluate(deployment(), runtime())

        self.assertEqual(result.status, "synced")
        self.assertTrue(result.commit_observed)

    def test_short_observed_revision_is_accepted_when_unambiguous(self) -> None:
        result = service(
            RootApplicationSnapshot(
                exists=True,
                observed_revision=COMMIT_SHA[:12],
                sync_status="Synced",
                health_status="Healthy",
            )
        ).evaluate(deployment(), runtime())

        self.assertEqual(result.status, "synced")

    def test_missing_revision_evidence_remains_unknown(self) -> None:
        result = service(
            RootApplicationSnapshot(
                exists=True,
                observed_revision=None,
                sync_status="Synced",
                health_status="Healthy",
            )
        ).evaluate(deployment(), runtime())

        self.assertEqual(result.status, "unknown")
        self.assertFalse(result.commit_observed)

    def test_newer_root_revision_with_tracked_aligned_workload_is_synced(self) -> None:
        result = service(
            RootApplicationSnapshot(
                exists=True,
                observed_revision="b" * 40,
                sync_status="Synced",
                health_status="Healthy",
                resources=(
                    ArgoResourceSnapshot(
                        group="apps",
                        kind="Deployment",
                        namespace="devdeploy-apps",
                        name="recover-nginx",
                        sync_status="Synced",
                    ),
                    ArgoResourceSnapshot(
                        group="",
                        kind="Service",
                        namespace="devdeploy-apps",
                        name="recover-nginx",
                        sync_status="Synced",
                    ),
                ),
            )
        ).evaluate(deployment(), runtime(), aligned_runtime_drift())

        self.assertEqual(result.status, "synced")
        self.assertFalse(result.commit_observed)
        self.assertIn("newer repository revision", result.message)

    def test_newer_revision_without_tracked_resource_evidence_stays_unknown(self) -> None:
        result = service(
            RootApplicationSnapshot(
                exists=True,
                observed_revision="b" * 40,
                sync_status="Synced",
                health_status="Healthy",
            )
        ).evaluate(deployment(), runtime(), aligned_runtime_drift())

        self.assertEqual(result.status, "unknown")

    def test_out_of_sync_without_active_operation_is_drifted(self) -> None:
        result = service(
            RootApplicationSnapshot(
                exists=True,
                observed_revision=COMMIT_SHA,
                sync_status="OutOfSync",
                health_status="Healthy",
                operation_phase="Succeeded",
            )
        ).evaluate(deployment(), runtime())

        self.assertEqual(result.status, "drifted")

    def test_out_of_sync_during_matching_operation_is_progressing(self) -> None:
        result = service(
            RootApplicationSnapshot(
                exists=True,
                observed_revision=COMMIT_SHA,
                sync_status="OutOfSync",
                health_status="Progressing",
                operation_phase="Running",
                operation_revision=COMMIT_SHA,
            )
        ).evaluate(deployment(), runtime("progressing"))

        self.assertEqual(result.status, "progressing")

    def test_degraded_root_or_runtime_is_degraded(self) -> None:
        root_degraded = service(
            RootApplicationSnapshot(
                exists=True,
                observed_revision=COMMIT_SHA,
                sync_status="Synced",
                health_status="Degraded",
            )
        ).evaluate(deployment(), runtime())
        runtime_degraded = service(
            RootApplicationSnapshot(
                exists=True,
                observed_revision=COMMIT_SHA,
                sync_status="Synced",
                health_status="Healthy",
            )
        ).evaluate(
            deployment(),
            runtime("unknown", deployment_found=True, service_found=True),
        )

        self.assertEqual(root_degraded.status, "degraded")
        self.assertEqual(runtime_degraded.status, "degraded")

    def test_runtime_unavailable_does_not_claim_synced(self) -> None:
        result = service(
            RootApplicationSnapshot(
                exists=True,
                observed_revision=COMMIT_SHA,
                sync_status="Synced",
                health_status="Healthy",
            )
        ).evaluate(
            deployment(),
            runtime("unknown", deployment_found=False, service_found=False),
        )

        self.assertEqual(result.status, "unknown")

    def test_root_reader_failure_is_sanitized_unknown(self) -> None:
        result = service(None).evaluate(deployment(), runtime())

        self.assertEqual(result.status, "unknown")
        self.assertNotIn("Kubernetes", result.message)


if __name__ == "__main__":
    unittest.main()
