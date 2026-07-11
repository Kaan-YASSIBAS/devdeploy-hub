import unittest
from types import SimpleNamespace

from kubernetes.client.exceptions import ApiException

from app.services.deployment_destroy_service import (
    DeploymentDestroyRuntimeCleanupService,
    KubernetesWorkloadRuntimeCleanupClient,
)
from app.services.gitops.status_reader import RootApplicationSnapshot


def resource(name: str, labels: dict[str, str]):
    return SimpleNamespace(
        metadata=SimpleNamespace(
            name=name,
            labels=labels,
        )
    )


OWNED_LABELS = {
    "app.kubernetes.io/name": "smoke-nginx",
    "app.kubernetes.io/managed-by": "devdeploy",
    "app.kubernetes.io/part-of": "devdeploy-workloads",
}


class FakeAppsApi:
    def __init__(self, deployment=None):
        self.deployment = deployment
        self.read_calls = []
        self.delete_calls = []
        self.reappear_after_delete = False

    def read_namespaced_deployment(self, **kwargs):
        self.read_calls.append(kwargs)
        if self.deployment is None:
            raise ApiException(status=404)
        return self.deployment

    def delete_namespaced_deployment(self, **kwargs):
        self.delete_calls.append(kwargs)
        self.deployment = resource("smoke-nginx", OWNED_LABELS) if self.reappear_after_delete else None


class FakeCoreApi:
    def __init__(self, service=None):
        self.service = service
        self.read_calls = []
        self.delete_calls = []
        self.reappear_after_delete = False

    def read_namespaced_service(self, **kwargs):
        self.read_calls.append(kwargs)
        if self.service is None:
            raise ApiException(status=404)
        return self.service

    def delete_namespaced_service(self, **kwargs):
        self.delete_calls.append(kwargs)
        self.service = resource("smoke-nginx", OWNED_LABELS) if self.reappear_after_delete else None


class FakeRootReader:
    def __init__(self, roots):
        self.roots = list(roots)
        self.calls = []

    def read_root_application(self, request):
        self.calls.append(request)
        if len(self.roots) > 1:
            return self.roots.pop(0)
        return self.roots[0]


class FakeCleanupClient:
    def __init__(self):
        self.calls = []

    def cleanup_workload(self, *, app_name: str, namespace: str):
        self.calls.append({"app_name": app_name, "namespace": namespace})
        apps_api = FakeAppsApi(resource(app_name, {**OWNED_LABELS, "app.kubernetes.io/name": app_name}))
        core_api = FakeCoreApi(resource(app_name, {**OWNED_LABELS, "app.kubernetes.io/name": app_name}))
        return KubernetesWorkloadRuntimeCleanupClient(
            apps_api=apps_api,
            core_api=core_api,
            stabilization_rechecks=0,
        ).cleanup_workload(app_name=app_name, namespace=namespace)


def deployment_record():
    return SimpleNamespace(
        app_name="smoke-nginx",
        namespace="devdeploy-apps",
    )


class KubernetesWorkloadRuntimeCleanupClientTestCase(unittest.TestCase):
    def test_cleanup_deletes_only_exact_owned_deployment_and_service(self) -> None:
        apps_api = FakeAppsApi(resource("smoke-nginx", OWNED_LABELS))
        core_api = FakeCoreApi(resource("smoke-nginx", OWNED_LABELS))
        client = KubernetesWorkloadRuntimeCleanupClient(
            apps_api=apps_api,
            core_api=core_api,
        )

        result = client.cleanup_workload(app_name="smoke-nginx", namespace="devdeploy-apps")

        self.assertEqual(result.status, "completed")
        self.assertTrue(result.deployment_deleted)
        self.assertTrue(result.service_deleted)
        self.assertEqual(apps_api.read_calls[0]["name"], "smoke-nginx")
        self.assertEqual(apps_api.read_calls[0]["namespace"], "devdeploy-apps")
        self.assertEqual(core_api.read_calls[0]["name"], "smoke-nginx")
        self.assertEqual(core_api.read_calls[0]["namespace"], "devdeploy-apps")
        self.assertEqual(apps_api.delete_calls[0]["name"], "smoke-nginx")
        self.assertEqual(core_api.delete_calls[0]["name"], "smoke-nginx")
        self.assertNotIn("label_selector", apps_api.delete_calls[0])
        self.assertNotIn("label_selector", core_api.delete_calls[0])
        self.assertGreaterEqual(len(apps_api.read_calls), 2)
        self.assertGreaterEqual(len(core_api.read_calls), 2)

    def test_cleanup_skips_resources_without_devdeploy_ownership_labels(self) -> None:
        labels = {"app.kubernetes.io/name": "smoke-nginx"}
        apps_api = FakeAppsApi(resource("smoke-nginx", labels))
        core_api = FakeCoreApi(resource("smoke-nginx", OWNED_LABELS))
        client = KubernetesWorkloadRuntimeCleanupClient(
            apps_api=apps_api,
            core_api=core_api,
        )

        result = client.cleanup_workload(app_name="smoke-nginx", namespace="devdeploy-apps")

        self.assertEqual(result.status, "pending")
        self.assertFalse(result.deployment_deleted)
        self.assertTrue(result.service_deleted)
        self.assertEqual(apps_api.delete_calls, [])

    def test_cleanup_reports_not_required_when_resources_are_absent(self) -> None:
        apps_api = FakeAppsApi()
        core_api = FakeCoreApi()
        client = KubernetesWorkloadRuntimeCleanupClient(
            apps_api=apps_api,
            core_api=core_api,
        )

        result = client.cleanup_workload(app_name="smoke-nginx", namespace="devdeploy-apps")

        self.assertEqual(result.status, "not_required")
        self.assertFalse(result.deployment_deleted)
        self.assertFalse(result.service_deleted)

    def test_cleanup_reports_failed_when_resource_reappears_during_stabilization(self) -> None:
        apps_api = FakeAppsApi(resource("smoke-nginx", OWNED_LABELS))
        core_api = FakeCoreApi(resource("smoke-nginx", OWNED_LABELS))
        apps_api.reappear_after_delete = True
        client = KubernetesWorkloadRuntimeCleanupClient(
            apps_api=apps_api,
            core_api=core_api,
            stabilization_rechecks=1,
            stabilization_interval_seconds=0,
        )

        result = client.cleanup_workload(app_name="smoke-nginx", namespace="devdeploy-apps")

        self.assertEqual(result.status, "failed")
        self.assertTrue(result.deployment_deleted)
        self.assertTrue(result.service_deleted)

    def test_destroy_service_does_not_cleanup_before_argo_observes_destroy_revision(self) -> None:
        cleanup_client = FakeCleanupClient()
        root_reader = FakeRootReader(
            [
                RootApplicationSnapshot(
                    exists=True,
                    observed_revision="a" * 40,
                    sync_status="Synced",
                    health_status="Healthy",
                )
            ]
        )
        service = DeploymentDestroyRuntimeCleanupService(
            client=cleanup_client,
            managed_namespace="devdeploy-apps",
            root_reader=root_reader,
            argo_observation_timeout_seconds=0,
            argo_observation_interval_seconds=0,
        )

        result = service.cleanup(deployment_record(), destroy_commit_sha="b" * 40)

        self.assertEqual(result.status, "pending")
        self.assertEqual(cleanup_client.calls, [])

    def test_destroy_service_matches_short_and_full_destroy_revisions(self) -> None:
        cleanup_client = FakeCleanupClient()
        root_reader = FakeRootReader(
            [
                RootApplicationSnapshot(
                    exists=True,
                    observed_revision=("b" * 40)[:12],
                    sync_status="Synced",
                    health_status="Healthy",
                )
            ]
        )
        service = DeploymentDestroyRuntimeCleanupService(
            client=cleanup_client,
            managed_namespace="devdeploy-apps",
            root_reader=root_reader,
            argo_observation_timeout_seconds=0,
            argo_observation_interval_seconds=0,
        )

        result = service.cleanup(deployment_record(), destroy_commit_sha="b" * 40)

        self.assertEqual(result.status, "completed")
        self.assertEqual(cleanup_client.calls, [{"app_name": "smoke-nginx", "namespace": "devdeploy-apps"}])

    def test_destroy_service_waits_until_argo_reconciliation_is_synced(self) -> None:
        cleanup_client = FakeCleanupClient()
        root_reader = FakeRootReader(
            [
                RootApplicationSnapshot(
                    exists=True,
                    observed_revision="c" * 40,
                    sync_status="OutOfSync",
                    health_status="Progressing",
                ),
                RootApplicationSnapshot(
                    exists=True,
                    observed_revision="c" * 40,
                    sync_status="Synced",
                    health_status="Healthy",
                ),
            ]
        )
        service = DeploymentDestroyRuntimeCleanupService(
            client=cleanup_client,
            managed_namespace="devdeploy-apps",
            root_reader=root_reader,
            argo_observation_timeout_seconds=1,
            argo_observation_interval_seconds=0,
        )

        result = service.cleanup(deployment_record(), destroy_commit_sha="c" * 40)

        self.assertEqual(result.status, "completed")
        self.assertEqual(len(root_reader.calls), 2)

    def test_destroy_service_reports_pending_on_argo_observation_timeout(self) -> None:
        cleanup_client = FakeCleanupClient()
        root_reader = FakeRootReader(
            [
                RootApplicationSnapshot(
                    exists=True,
                    observed_revision="d" * 40,
                    sync_status="Synced",
                    health_status="Healthy",
                )
            ]
        )
        service = DeploymentDestroyRuntimeCleanupService(
            client=cleanup_client,
            managed_namespace="devdeploy-apps",
            root_reader=root_reader,
            argo_observation_timeout_seconds=0,
            argo_observation_interval_seconds=0,
        )

        result = service.cleanup(deployment_record(), destroy_commit_sha="e" * 40)

        self.assertEqual(result.status, "pending")
        self.assertEqual(cleanup_client.calls, [])


if __name__ == "__main__":
    unittest.main()
