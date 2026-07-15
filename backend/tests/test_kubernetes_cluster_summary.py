import unittest
from types import SimpleNamespace
from unittest.mock import patch

from fastapi import FastAPI
from fastapi.testclient import TestClient
from kubernetes.client import ApiException

from app.api.v1 import observability
from app.core.deps import get_current_user
from app.services.kubernetes_service import KubernetesService


class FakeCoreApi:
    def __init__(self) -> None:
        self.calls = []

    def list_namespace(self):
        self.calls.append(("namespaces", None))
        return SimpleNamespace(items=[object(), object()])

    def list_namespaced_pod(self, namespace):
        self.calls.append(("pods", namespace))
        return SimpleNamespace(items=[object()])

    def list_namespaced_service(self, namespace):
        self.calls.append(("services", namespace))
        return SimpleNamespace(items=[object()])

    def list_node(self):
        self.calls.append(("nodes", None))
        ready = SimpleNamespace(type="Ready", status="True")
        node = SimpleNamespace(status=SimpleNamespace(conditions=[ready]))
        return SimpleNamespace(items=[node])

    def list_pod_for_all_namespaces(self):
        raise AssertionError("cluster-wide pod reads are forbidden")

    def list_service_for_all_namespaces(self):
        raise AssertionError("cluster-wide service reads are forbidden")


class FakeAppsApi:
    def __init__(self) -> None:
        self.calls = []

    def list_namespaced_deployment(self, namespace):
        self.calls.append(("deployments", namespace))
        return SimpleNamespace(items=[object()])

    def list_deployment_for_all_namespaces(self):
        raise AssertionError("cluster-wide deployment reads are forbidden")


class KubernetesClusterSummaryServiceTestCase(unittest.TestCase):
    def test_summary_uses_namespaced_workload_reads(self) -> None:
        core_api = FakeCoreApi()
        apps_api = FakeAppsApi()
        service = KubernetesService()
        service.__dict__["_core_api"] = core_api
        service.__dict__["_apps_api"] = apps_api

        summary = service.get_cluster_summary(namespace="devdeploy-apps")

        self.assertEqual(
            core_api.calls,
            [
                ("namespaces", None),
                ("pods", "devdeploy-apps"),
                ("services", "devdeploy-apps"),
                ("nodes", None),
            ],
        )
        self.assertEqual(apps_api.calls, [("deployments", "devdeploy-apps")])
        self.assertEqual(summary["namespaces_count"], 2)
        self.assertEqual(summary["pods_count"], 1)
        self.assertEqual(summary["deployments_count"], 1)
        self.assertEqual(summary["services_count"], 1)
        self.assertEqual(summary["nodes_count"], 1)
        self.assertEqual(summary["ready_nodes_count"], 1)


class KubernetesClusterSummaryApiTestCase(unittest.TestCase):
    def setUp(self) -> None:
        app = FastAPI()
        app.include_router(observability.router, prefix="/api/v1")
        app.dependency_overrides[get_current_user] = lambda: SimpleNamespace(role="admin")
        self.client = TestClient(app, raise_server_exceptions=False)

    def tearDown(self) -> None:
        self.client.close()

    def test_summary_passes_validated_namespace(self) -> None:
        result = {
            "current_context": "test",
            "namespaces_count": 2,
            "pods_count": 1,
            "deployments_count": 1,
            "services_count": 1,
            "nodes_count": 1,
            "ready_nodes_count": 1,
        }
        fake = SimpleNamespace(get_cluster_summary=lambda *, namespace: result)
        with patch("app.api.v1.observability.KubernetesService", return_value=fake):
            response = self.client.get(
                "/api/v1/observability/cluster/summary",
                params={"namespace": "devdeploy-apps"},
            )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), result)

    def test_forbidden_is_reported_as_degraded_service_availability(self) -> None:
        def forbidden(*, namespace):
            raise ApiException(status=403, reason="Forbidden")

        fake = SimpleNamespace(get_cluster_summary=forbidden)
        with patch("app.api.v1.observability.KubernetesService", return_value=fake):
            response = self.client.get(
                "/api/v1/observability/cluster/summary",
                params={"namespace": "devdeploy-apps"},
            )
        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.json()["detail"], "Kubernetes API request failed: Forbidden")

    def test_invalid_namespace_is_rejected_before_client_creation(self) -> None:
        with patch("app.api.v1.observability.KubernetesService") as factory:
            response = self.client.get(
                "/api/v1/observability/cluster/summary",
                params={"namespace": "../default"},
            )
        self.assertEqual(response.status_code, 400)
        factory.assert_not_called()


if __name__ == "__main__":
    unittest.main()
