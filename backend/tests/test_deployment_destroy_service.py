import unittest
from types import SimpleNamespace

from kubernetes.client.exceptions import ApiException

from app.services.deployment_destroy_service import KubernetesWorkloadRuntimeCleanupClient


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

    def read_namespaced_deployment(self, **kwargs):
        self.read_calls.append(kwargs)
        if self.deployment is None:
            raise ApiException(status=404)
        return self.deployment

    def delete_namespaced_deployment(self, **kwargs):
        self.delete_calls.append(kwargs)


class FakeCoreApi:
    def __init__(self, service=None):
        self.service = service
        self.read_calls = []
        self.delete_calls = []

    def read_namespaced_service(self, **kwargs):
        self.read_calls.append(kwargs)
        if self.service is None:
            raise ApiException(status=404)
        return self.service

    def delete_namespaced_service(self, **kwargs):
        self.delete_calls.append(kwargs)


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


if __name__ == "__main__":
    unittest.main()
