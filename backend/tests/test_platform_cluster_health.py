import unittest

from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.api.v1.endpoints.platform import (
    get_platform_cluster_health_service,
    router,
)
from app.core.deps import get_current_user
from app.services.platform_cluster_health import PlatformClusterHealthService


class FakeProbe:
    def __init__(self, error: Exception | None = None):
        self.error = error
        self.calls = 0

    def check_api(self) -> None:
        self.calls += 1
        if self.error is not None:
            raise self.error


class PlatformClusterHealthApiTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.app = FastAPI()
        self.app.include_router(router, prefix="/api/v1")
        self.management_probe = FakeProbe()
        self.workload_probe = FakeProbe()
        self.service = PlatformClusterHealthService(
            management_probe=self.management_probe,
            workload_probe=self.workload_probe,
        )
        self.app.dependency_overrides[get_platform_cluster_health_service] = lambda: self.service
        self.client = TestClient(self.app, raise_server_exceptions=False)

    def tearDown(self) -> None:
        self.client.close()

    def authenticate(self) -> None:
        self.app.dependency_overrides[get_current_user] = lambda: object()

    def get_health(self):
        return self.client.get("/api/v1/platform/cluster-health")

    def test_unauthenticated_request_is_rejected(self) -> None:
        response = self.get_health()

        self.assertEqual(response.status_code, 401)
        self.assertEqual(self.management_probe.calls, 0)
        self.assertEqual(self.workload_probe.calls, 0)

    def test_reachable_clusters_return_healthy(self) -> None:
        self.authenticate()

        response = self.get_health()

        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["management"]["status"], "healthy")
        self.assertTrue(body["management"]["api_reachable"])
        self.assertEqual(body["management"]["reason"], "ok")
        self.assertEqual(body["workload"]["status"], "healthy")
        self.assertTrue(body["workload"]["api_reachable"])

    def test_workload_failure_returns_unreachable_without_500(self) -> None:
        self.authenticate()
        self.workload_probe.error = RuntimeError("workload API refused the connection")

        response = self.get_health()

        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["management"]["status"], "healthy")
        self.assertEqual(body["workload"]["status"], "unreachable")
        self.assertFalse(body["workload"]["api_reachable"])
        self.assertEqual(body["workload"]["reason"], "api_unreachable")
        self.assertIn("launcher preflight", body["workload"]["recommended_action"].lower())
        self.assertTrue(any("runtime status" in item.lower() for item in body["workload"]["impact"]))
        self.assertTrue(
            any("only devdeploy-workload" in item.lower() for item in body["workload"]["recovery_steps"])
        )

    def test_management_failure_is_sanitized(self) -> None:
        self.authenticate()
        self.management_probe.error = RuntimeError(
            "token=raw-token kubeconfig=C:/sensitive/client.yaml certificate data"
        )

        response = self.get_health()

        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["management"]["status"], "unreachable")
        self.assertFalse(body["management"]["api_reachable"])
        self.assertTrue(
            any("platform data" in item.lower() for item in body["management"]["recovery_steps"])
        )
        response_text = str(body).lower()
        for forbidden in ("raw-token", "kubeconfig", "client.yaml", "certificate data", "secret"):
            self.assertNotIn(forbidden, response_text)

    def test_response_does_not_expose_configuration_paths_or_accept_context_overrides(self) -> None:
        self.authenticate()

        response = self.client.get(
            "/api/v1/platform/cluster-health",
            params={
                "management_kubeconfig": "C:/sensitive/management.yaml",
                "workload_kubeconfig_context": "untrusted-context",
            },
        )

        self.assertEqual(response.status_code, 200)
        response_text = str(response.json()).lower()
        self.assertNotIn("sensitive", response_text)
        self.assertNotIn("untrusted-context", response_text)
        self.assertEqual(response.json()["management"]["context"], "kind-devdeploy-mgmt")
        self.assertEqual(response.json()["workload"]["context"], "kind-devdeploy-workload")


if __name__ == "__main__":
    unittest.main()
