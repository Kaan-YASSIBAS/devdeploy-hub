import unittest
from types import SimpleNamespace

from kubernetes.client.exceptions import ApiException

from app.services.deployment_recovery_service import (
    DeploymentRecoveryVerificationService,
    KubernetesRecoveredWorkloadReadinessClient,
)
from app.services.gitops.status_reader import RootApplicationSnapshot


OWNED_LABELS = {
    "app.kubernetes.io/name": "smoke-nginx",
    "app.kubernetes.io/managed-by": "devdeploy",
    "app.kubernetes.io/part-of": "devdeploy-workloads",
}


def deployment_record():
    return SimpleNamespace(
        app_name="smoke-nginx",
        namespace="devdeploy-apps",
        replicas=1,
    )


def owned_deployment(*, available: bool = True, labels: dict[str, str] | None = None):
    return SimpleNamespace(
        metadata=SimpleNamespace(
            name="smoke-nginx",
            labels=labels if labels is not None else OWNED_LABELS,
            generation=3,
        ),
        status=SimpleNamespace(
            observed_generation=3,
            ready_replicas=1 if available else 0,
            available_replicas=1 if available else 0,
            updated_replicas=1 if available else 0,
            conditions=[
                SimpleNamespace(type="Available", status="True" if available else "False")
            ],
        ),
    )


def owned_service(*, labels: dict[str, str] | None = None):
    return SimpleNamespace(
        metadata=SimpleNamespace(
            name="smoke-nginx",
            labels=labels if labels is not None else OWNED_LABELS,
        )
    )


class FakeAppsApi:
    def __init__(self, deployment=None):
        self.deployment = deployment
        self.read_calls = []

    def read_namespaced_deployment(self, **kwargs):
        self.read_calls.append(kwargs)
        if self.deployment is None:
            raise ApiException(status=404)
        return self.deployment


class FakeCoreApi:
    def __init__(self, service=None):
        self.service = service
        self.read_calls = []

    def read_namespaced_service(self, **kwargs):
        self.read_calls.append(kwargs)
        if self.service is None:
            raise ApiException(status=404)
        return self.service


class FakeRootReader:
    def __init__(self, roots):
        self.roots = list(roots)
        self.calls = []
        self.reconcile_calls = []

    def read_root_application(self, request):
        self.calls.append(request)
        if len(self.roots) > 1:
            return self.roots.pop(0)
        return self.roots[0]

    def request_reconciliation(self, request, revision):
        self.reconcile_calls.append({"request": request, "revision": revision})


class DeploymentRecoveryVerificationServiceTestCase(unittest.TestCase):
    def ready_client(self) -> KubernetesRecoveredWorkloadReadinessClient:
        return KubernetesRecoveredWorkloadReadinessClient(
            apps_api=FakeAppsApi(owned_deployment()),
            core_api=FakeCoreApi(owned_service()),
        )

    def service(self, *, root_reader, readiness_client=None) -> DeploymentRecoveryVerificationService:
        return DeploymentRecoveryVerificationService(
            readiness_client=readiness_client or self.ready_client(),
            root_reader=root_reader,
            managed_namespace="devdeploy-apps",
            argo_observation_timeout_seconds=0,
            argo_observation_interval_seconds=0,
            runtime_readiness_timeout_seconds=0,
            runtime_readiness_interval_seconds=0,
        )

    def test_matching_revision_and_succeeded_operation_allows_runtime_readiness(self) -> None:
        root_reader = FakeRootReader(
            [
                RootApplicationSnapshot(
                    exists=True,
                    observed_revision="a" * 40,
                    sync_status="OutOfSync",
                    health_status="Healthy",
                    operation_phase="Succeeded",
                    operation_revision="a" * 40,
                )
            ]
        )

        result = self.service(root_reader=root_reader).verify_recovered(
            deployment_record(),
            recovery_commit_sha="a" * 40,
        )

        self.assertEqual(result.status, "ready")
        self.assertEqual(root_reader.reconcile_calls[0]["revision"], "a" * 40)

    def test_succeeded_operation_for_another_revision_does_not_allow_readiness(self) -> None:
        root_reader = FakeRootReader(
            [
                RootApplicationSnapshot(
                    exists=True,
                    observed_revision="b" * 40,
                    sync_status="Synced",
                    health_status="Healthy",
                    operation_phase="Succeeded",
                    operation_revision="c" * 40,
                )
            ]
        )

        result = self.service(root_reader=root_reader).verify_recovered(
            deployment_record(),
            recovery_commit_sha="b" * 40,
        )

        self.assertEqual(result.status, "pending")

    def test_failed_operation_does_not_activate_recovery(self) -> None:
        root_reader = FakeRootReader(
            [
                RootApplicationSnapshot(
                    exists=True,
                    observed_revision="d" * 40,
                    sync_status="OutOfSync",
                    health_status="Degraded",
                    operation_phase="Failed",
                    operation_revision="d" * 40,
                )
            ]
        )

        result = self.service(root_reader=root_reader).verify_recovered(
            deployment_record(),
            recovery_commit_sha="d" * 40,
        )

        self.assertEqual(result.status, "failed")

    def test_deployment_ownership_mismatch_returns_conflict(self) -> None:
        root_reader = FakeRootReader(
            [
                RootApplicationSnapshot(
                    exists=True,
                    observed_revision="e" * 40,
                    sync_status="OutOfSync",
                    health_status="Healthy",
                    operation_phase="Succeeded",
                    operation_revision="e" * 40,
                )
            ]
        )
        readiness_client = KubernetesRecoveredWorkloadReadinessClient(
            apps_api=FakeAppsApi(owned_deployment(labels={"app.kubernetes.io/name": "smoke-nginx"})),
            core_api=FakeCoreApi(owned_service()),
        )

        result = self.service(
            root_reader=root_reader,
            readiness_client=readiness_client,
        ).verify_recovered(deployment_record(), recovery_commit_sha="e" * 40)

        self.assertEqual(result.status, "conflict")

    def test_service_ownership_mismatch_returns_conflict(self) -> None:
        root_reader = FakeRootReader(
            [
                RootApplicationSnapshot(
                    exists=True,
                    observed_revision="f" * 40,
                    sync_status="OutOfSync",
                    health_status="Healthy",
                    operation_phase="Succeeded",
                    operation_revision="f" * 40,
                )
            ]
        )
        readiness_client = KubernetesRecoveredWorkloadReadinessClient(
            apps_api=FakeAppsApi(owned_deployment()),
            core_api=FakeCoreApi(owned_service(labels={"app.kubernetes.io/name": "smoke-nginx"})),
        )

        result = self.service(
            root_reader=root_reader,
            readiness_client=readiness_client,
        ).verify_recovered(deployment_record(), recovery_commit_sha="f" * 40)

        self.assertEqual(result.status, "conflict")

    def test_missing_service_keeps_recovery_pending(self) -> None:
        root_reader = FakeRootReader(
            [
                RootApplicationSnapshot(
                    exists=True,
                    observed_revision="1" * 40,
                    sync_status="OutOfSync",
                    health_status="Healthy",
                    operation_phase="Succeeded",
                    operation_revision="1" * 40,
                )
            ]
        )
        readiness_client = KubernetesRecoveredWorkloadReadinessClient(
            apps_api=FakeAppsApi(owned_deployment()),
            core_api=FakeCoreApi(),
        )

        result = self.service(
            root_reader=root_reader,
            readiness_client=readiness_client,
        ).verify_recovered(deployment_record(), recovery_commit_sha="1" * 40)

        self.assertEqual(result.status, "pending")


if __name__ == "__main__":
    unittest.main()
