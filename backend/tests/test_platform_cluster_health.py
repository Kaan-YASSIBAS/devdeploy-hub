import unittest
from unittest.mock import Mock, patch

from fastapi import FastAPI
from fastapi.testclient import TestClient
from kubernetes import client
from kubernetes.client.exceptions import ApiException

from app.api.v1.endpoints.platform import (
    get_platform_cluster_health_service,
    router,
)
from app.core.deps import get_current_user
from app.services.gitops.status_reader import GitOpsStatusError
from app.services.platform_cluster_health import (
    KubernetesVersionApiProbe,
    PlatformClusterHealthService,
)


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
        self.assertTrue(body["platform_ready"])
        self.assertEqual(response.headers["cache-control"], "no-store, private")
        self.assertEqual(response.headers["vary"], "Authorization")

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
        self.assertFalse(body["platform_ready"])
        self.assertIn("launcher preflight", body["workload"]["recommended_action"].lower())
        self.assertTrue(any("runtime status" in item.lower() for item in body["workload"]["impact"]))
        self.assertTrue(
            any("only devdeploy-workload" in item.lower() for item in body["workload"]["recovery_steps"])
        )

    def test_permission_neutral_probe_uses_kubernetes_version_endpoint(self) -> None:
        api_client = Mock(spec=client.ApiClient)
        version_api = Mock()

        with patch(
            "app.services.platform_cluster_health.client.VersionApi",
            return_value=version_api,
        ) as version_api_factory:
            KubernetesVersionApiProbe(api_client).check_api()

        version_api_factory.assert_called_once_with(api_client)
        version_api.get_code.assert_called_once_with(_request_timeout=(3, 5))

    def test_forbidden_probe_is_reachable_and_does_not_reopen_setup_gate(self) -> None:
        self.authenticate()
        self.management_probe.error = ApiException(status=403, reason="Forbidden")

        response = self.get_health()

        management = response.json()["management"]
        self.assertEqual(management["status"], "degraded")
        self.assertTrue(management["api_reachable"])
        self.assertEqual(management["reason"], "api_forbidden")
        self.assertTrue(response.json()["platform_ready"])
        self.assertNotIn("Forbidden", str(response.json()))

    def test_management_health_stays_healthy_after_incluster_token_refresh(self) -> None:
        management_tokens = []

        def load_management(*, client_configuration, **kwargs) -> None:
            _ = kwargs
            client_configuration.host = "https://management.example:443"
            client_configuration.api_key["authorization"] = "bearer management-initial"
            refresh_count = {"value": 0}

            def refresh(configuration) -> None:
                refresh_count["value"] += 1
                configuration.api_key["authorization"] = f"bearer management-rotated-{refresh_count['value']}"
                configuration.refresh_api_key_hook = refresh

            client_configuration.refresh_api_key_hook = refresh

        def load_workload(*, client_configuration, **kwargs) -> None:
            _ = kwargs
            client_configuration.host = "https://workload.example:6443"
            client_configuration.api_key["authorization"] = "Bearer workload-token"

        class RefreshingVersionApi:
            def __init__(self, api_client) -> None:
                self.api_client = api_client

            def get_code(self, **kwargs) -> object:
                _ = kwargs
                configuration = self.api_client.configuration
                auth = configuration.auth_settings()["BearerToken"]["value"]
                if configuration.host == "https://management.example:443":
                    management_tokens.append(auth)
                    if configuration.api_key["authorization"] != configuration.api_key["BearerToken"]:
                        raise AssertionError("management BearerToken was stale after refresh")
                return object()

        with (
            patch(
                "app.services.gitops.kubernetes_status_reader.config.load_incluster_config",
                side_effect=load_management,
            ),
            patch(
                "app.services.gitops.kubernetes_status_reader.config.load_kube_config",
                side_effect=load_workload,
            ),
            patch("app.services.platform_cluster_health.client.VersionApi", RefreshingVersionApi),
        ):
            service = PlatformClusterHealthService.from_server_config(
                management_kubeconfig=None,
                management_kubeconfig_context=None,
                workload_kubeconfig="workload-kubeconfig.yaml",
                workload_kubeconfig_context="devdeploy-workload-observability",
                use_in_cluster_management=True,
            )

        first = service.read_health()
        second = service.read_health()

        self.assertEqual(first.management.status, "healthy")
        self.assertEqual(second.management.status, "healthy")
        self.assertTrue(first.platform_ready)
        self.assertTrue(second.platform_ready)
        self.assertGreaterEqual(len(set(management_tokens)), 2)

    def test_authentication_failure_is_reachable_but_blocks_readiness(self) -> None:
        self.authenticate()
        self.management_probe.error = ApiException(status=401, reason="Unauthorized")

        response = self.get_health()

        management = response.json()["management"]
        self.assertEqual(management["status"], "degraded")
        self.assertTrue(management["api_reachable"])
        self.assertEqual(management["reason"], "authentication_failed")
        self.assertFalse(response.json()["platform_ready"])

    def test_required_api_health_failure_is_reachable_but_blocks_readiness(self) -> None:
        self.authenticate()
        self.management_probe.error = ApiException(status=503, reason="Service Unavailable")

        response = self.get_health()

        management = response.json()["management"]
        self.assertEqual(management["status"], "degraded")
        self.assertTrue(management["api_reachable"])
        self.assertEqual(management["reason"], "api_degraded")
        self.assertFalse(response.json()["platform_ready"])

    def test_configuration_failure_is_distinct_from_transport_failure(self) -> None:
        self.authenticate()
        self.management_probe.error = GitOpsStatusError(
            "status_reader_unavailable",
            "sensitive configuration detail",
        )

        response = self.get_health()

        management = response.json()["management"]
        self.assertEqual(management["status"], "unknown")
        self.assertFalse(management["api_reachable"])
        self.assertEqual(management["reason"], "configuration_unavailable")
        self.assertFalse(response.json()["platform_ready"])
        self.assertNotIn("sensitive", str(response.json()).lower())

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

    def test_authenticated_response_cannot_be_reused_without_authentication(self) -> None:
        self.authenticate()
        authenticated = self.get_health()
        self.assertEqual(authenticated.status_code, 200)

        del self.app.dependency_overrides[get_current_user]
        unauthenticated = self.get_health()

        self.assertEqual(unauthenticated.status_code, 401)
        self.assertEqual(unauthenticated.headers.get("cache-control"), None)
        self.assertEqual(self.management_probe.calls, 1)
        self.assertEqual(self.workload_probe.calls, 1)


if __name__ == "__main__":
    unittest.main()
