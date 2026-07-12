import unittest
import time
from types import SimpleNamespace
from unittest.mock import patch

from fastapi import FastAPI
from fastapi.testclient import TestClient
import httpx

from app.api.v1 import observability
from app.core.deps import get_current_user
from app.schemas.observability import ObservabilityComponentHealth, ObservabilityStatus
from app.services.loki_service import LokiService
from app.services.observability_errors import ObservabilityUnavailableError
from app.services.observability_service_proxy import KubernetesServiceProxyTransport
from app.services.observability_status_service import ObservabilityStatusService
from app.services.prometheus_service import PrometheusService


class FakeStatusService:
    def __init__(self, response: ObservabilityStatus):
        self.response = response
        self.calls = 0

    def get_status(self) -> ObservabilityStatus:
        self.calls += 1
        return self.response


def component(status: str, *, available: bool) -> ObservabilityComponentHealth:
    return ObservabilityComponentHealth(
        available=available,
        status=status,  # type: ignore[arg-type]
        detail=f"{status} detail",
        message_code=f"test.{status}",
        capabilities={"arbitrary_promql": False, "arbitrary_logql": False},
    )


class StreamResponse:
    def __init__(
        self,
        payload: bytes = b'{"status":"success","data":{"result":[]}}',
        *,
        content_length: int | None = None,
        content_type: str = "application/json",
    ) -> None:
        self.payload = payload
        self.headers = {"content-type": content_type}
        if content_length is not None:
            self.headers["content-length"] = str(content_length)

    def __enter__(self) -> "StreamResponse":
        return self

    def __exit__(self, exc_type, exc, traceback) -> None:
        return None

    def raise_for_status(self) -> None:
        return None

    def iter_bytes(self):
        yield self.payload


class KubernetesProxyResponse:
    def __init__(self, payload: bytes = b'{"status":"success","data":{"result":[]}}') -> None:
        self.payload = payload
        self.headers = {"content-type": "application/json"}

    def stream(self, amt: int = 65536):
        yield self.payload


class FakeApiClient:
    def __init__(self, response: KubernetesProxyResponse | None = None) -> None:
        self.response = response or KubernetesProxyResponse()
        self.calls: list[dict[str, object]] = []

    def call_api(self, **kwargs):
        self.calls.append(kwargs)
        return self.response


class ObservabilityStatusApiTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.app = FastAPI()
        self.app.include_router(observability.router, prefix="/api/v1")
        self.response = ObservabilityStatus(
            kubernetes=component("connected", available=True),
            prometheus=component("connected", available=True),
            loki=component("unavailable", available=False),
            grafana=component("optional", available=False),
        )
        self.status_service = FakeStatusService(self.response)
        self.app.dependency_overrides[
            observability.get_observability_status_service
        ] = lambda: self.status_service
        self.client = TestClient(self.app, raise_server_exceptions=False)

    def tearDown(self) -> None:
        self.client.close()

    def authenticate(self) -> None:
        self.app.dependency_overrides[get_current_user] = lambda: object()

    def authenticate_as(self, role: str) -> None:
        self.app.dependency_overrides[get_current_user] = lambda: SimpleNamespace(role=role)

    def test_status_requires_authentication(self) -> None:
        response = self.client.get("/api/v1/observability/status")

        self.assertEqual(response.status_code, 401)
        self.assertEqual(self.status_service.calls, 0)

    def test_status_returns_sanitized_component_states_without_internal_urls(self) -> None:
        self.authenticate()

        response = self.client.get(
            "/api/v1/observability/status",
            params={
                "prometheus_url": "http://prometheus.internal:9090",
                "loki_path": "/loki/api/v1/query_range",
            },
        )

        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["prometheus"]["status"], "connected")
        self.assertEqual(body["loki"]["status"], "unavailable")
        self.assertEqual(body["grafana"]["status"], "optional")
        self.assertFalse(body["prometheus"]["capabilities"]["arbitrary_promql"])
        self.assertFalse(body["loki"]["capabilities"]["arbitrary_logql"])
        response_text = str(body).lower()
        self.assertNotIn("prometheus.internal", response_text)
        self.assertNotIn("query_range", response_text)
        self.assertNotIn("token", response_text)

    def test_health_endpoint_remains_backward_compatible(self) -> None:
        self.authenticate()

        response = self.client.get("/api/v1/observability/health")

        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertIn("kubernetes", body)
        self.assertIn("prometheus", body)
        self.assertIn("loki", body)
        self.assertNotIn("grafana", body)
        self.assertTrue(body["prometheus"]["available"])

    def test_logs_endpoint_requires_platform_admin_scope(self) -> None:
        self.authenticate_as("developer")

        response = self.client.get("/api/v1/observability/logs")

        self.assertEqual(response.status_code, 403)


class ObservabilityStatusServiceTestCase(unittest.TestCase):
    def tearDown(self) -> None:
        ObservabilityStatusService.clear_cache()

    def test_prometheus_success_and_grafana_optional(self) -> None:
        service = ObservabilityStatusService(
            kubernetes_check=lambda: None,
            prometheus_check=lambda: None,
            loki_check=lambda: None,
            prometheus_configured=True,
            loki_configured=True,
            grafana_configured=False,
            cache_ttl_seconds=0,
        )

        status = service.get_status()

        self.assertEqual(status.prometheus.status, "connected")
        self.assertEqual(status.loki.status, "connected")
        self.assertEqual(status.grafana.status, "optional")
        self.assertFalse(status.grafana.capabilities["required_for_product"])

    def test_prometheus_not_configured(self) -> None:
        service = ObservabilityStatusService(
            kubernetes_check=lambda: None,
            prometheus_check=lambda: None,
            loki_check=lambda: None,
            prometheus_configured=False,
            loki_configured=True,
            grafana_configured=False,
            cache_ttl_seconds=0,
        )

        status = service.get_status()

        self.assertEqual(status.prometheus.status, "not_configured")
        self.assertFalse(status.prometheus.available)

    def test_timeout_and_malformed_responses_are_sanitized(self) -> None:
        service = ObservabilityStatusService(
            kubernetes_check=lambda: None,
            prometheus_check=lambda: (_ for _ in ()).throw(httpx.TimeoutException("raw timeout")),
            loki_check=lambda: (_ for _ in ()).throw(ValueError("raw parse body token=secret")),
            prometheus_configured=True,
            loki_configured=True,
            grafana_configured=False,
            cache_ttl_seconds=0,
        )

        status = service.get_status()

        self.assertEqual(status.prometheus.status, "unavailable")
        self.assertEqual(status.loki.status, "degraded")
        response_text = str(status.model_dump()).lower()
        self.assertNotIn("raw timeout", response_text)
        self.assertNotIn("token=secret", response_text)

    def test_configured_but_unreachable_is_unavailable(self) -> None:
        service = ObservabilityStatusService(
            kubernetes_check=lambda: None,
            prometheus_check=lambda: (_ for _ in ()).throw(httpx.ConnectError("http://internal")),
            loki_check=lambda: None,
            prometheus_configured=True,
            loki_configured=True,
            grafana_configured=False,
            cache_ttl_seconds=0,
        )

        status = service.get_status()

        self.assertEqual(status.prometheus.status, "unavailable")
        self.assertFalse(status.prometheus.available)
        self.assertNotIn("http://internal", str(status.model_dump()).lower())

    def test_status_checks_run_concurrently(self) -> None:
        def slow_check() -> None:
            time.sleep(0.2)

        service = ObservabilityStatusService(
            kubernetes_check=slow_check,
            prometheus_check=slow_check,
            loki_check=slow_check,
            grafana_check=slow_check,
            prometheus_configured=True,
            loki_configured=True,
            grafana_configured=True,
            cache_ttl_seconds=0,
        )

        started = time.perf_counter()
        service.get_status()
        elapsed = time.perf_counter() - started

        self.assertLess(elapsed, 0.6)

    def test_cache_expires_and_returns_independent_response_objects(self) -> None:
        calls = 0

        def counted_check() -> None:
            nonlocal calls
            calls += 1

        service = ObservabilityStatusService(
            kubernetes_check=counted_check,
            prometheus_check=lambda: None,
            loki_check=lambda: None,
            prometheus_configured=True,
            loki_configured=True,
            grafana_configured=False,
            cache_ttl_seconds=1,
        )

        first = service.get_status()
        first.kubernetes.capabilities["mutated"] = True
        second = service.get_status()

        self.assertEqual(calls, 1)
        self.assertNotIn("mutated", second.kubernetes.capabilities)

        ObservabilityStatusService.clear_cache()
        service.get_status()
        self.assertEqual(calls, 2)

    def test_kubernetes_configuration_error_is_not_configured(self) -> None:
        service = ObservabilityStatusService(
            kubernetes_check=lambda: (_ for _ in ()).throw(
                ObservabilityUnavailableError("Kubernetes configuration unavailable: token=secret")
            ),
            prometheus_check=lambda: None,
            loki_check=lambda: None,
            prometheus_configured=True,
            loki_configured=True,
            grafana_configured=False,
            cache_ttl_seconds=0,
        )

        status = service.get_status()

        self.assertEqual(status.kubernetes.status, "not_configured")
        self.assertNotIn("token=secret", str(status.model_dump()).lower())


class PrometheusAndLokiHealthParsingTestCase(unittest.TestCase):
    def test_prometheus_health_uses_strict_timeout_and_no_redirects(self) -> None:
        response = StreamResponse()

        with patch("app.services.observability_http.httpx.stream", return_value=response) as stream:
            PrometheusService(base_url="http://prometheus.example").check_health()

        timeout = stream.call_args.kwargs["timeout"]
        self.assertEqual(timeout.connect, 2.0)
        self.assertEqual(timeout.read, 5.0)
        self.assertFalse(stream.call_args.kwargs["follow_redirects"])

    def test_prometheus_malformed_response_is_sanitized(self) -> None:
        response = StreamResponse(b"{bad-json")

        with patch("app.services.observability_http.httpx.stream", return_value=response):
            with self.assertRaisesRegex(ObservabilityUnavailableError, "malformed"):
                PrometheusService(base_url="http://prometheus.example").check_health()

    def test_prometheus_oversized_response_is_rejected(self) -> None:
        response = StreamResponse(b'{"status":"success"}', content_length=3 * 1024 * 1024)

        with patch("app.services.observability_http.httpx.stream", return_value=response):
            with self.assertRaisesRegex(ObservabilityUnavailableError, "too large"):
                PrometheusService(base_url="http://prometheus.example").check_health()

    def test_loki_health_uses_strict_timeout_and_no_redirects(self) -> None:
        response = StreamResponse()

        with patch("app.services.observability_http.httpx.stream", return_value=response) as stream:
            LokiService(base_url="http://loki.example").check_health()

        timeout = stream.call_args.kwargs["timeout"]
        self.assertEqual(timeout.connect, 2.0)
        self.assertEqual(timeout.read, 8.0)
        self.assertFalse(stream.call_args.kwargs["follow_redirects"])
        self.assertEqual(stream.call_args.kwargs["params"]["limit"], 1)

    def test_loki_malformed_response_is_sanitized(self) -> None:
        response = StreamResponse(b"{bad-json")

        with patch("app.services.observability_http.httpx.stream", return_value=response):
            with self.assertRaisesRegex(ObservabilityUnavailableError, "malformed"):
                LokiService(base_url="http://loki.example").check_health()

    def test_loki_limit_is_bounded_before_upstream_request(self) -> None:
        response = StreamResponse()

        with patch("app.services.observability_http.httpx.stream", return_value=response) as stream:
            LokiService(base_url="http://loki.example").query_logs(namespace="devdeploy-apps", limit=10_000)

        self.assertEqual(stream.call_args.kwargs["params"]["limit"], 500)


class ObservabilityServiceProxyTransportTestCase(unittest.TestCase):
    def transport(self) -> tuple[KubernetesServiceProxyTransport, FakeApiClient]:
        api_client = FakeApiClient()
        return (
            KubernetesServiceProxyTransport(
                api_client=api_client,
                namespace="monitoring",
                max_response_bytes=2 * 1024 * 1024,
            ),
            api_client,
        )

    def test_prometheus_service_proxy_uses_fixed_allowlisted_path(self) -> None:
        transport, api_client = self.transport()

        payload = transport.prometheus_query({"query": "up"})

        self.assertEqual(payload["status"], "success")
        call = api_client.calls[0]
        self.assertEqual(
            call["resource_path"],
            "/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query",
        )
        self.assertEqual(call["method"], "GET")
        self.assertFalse(call["_preload_content"])

    def test_loki_service_proxy_uses_fixed_allowlisted_path(self) -> None:
        transport, api_client = self.transport()

        transport.loki_query_range({"query": '{namespace="devdeploy-apps"}', "limit": 1})

        self.assertEqual(
            api_client.calls[0]["resource_path"],
            "/api/v1/namespaces/monitoring/services/loki-gateway:80/proxy/loki/api/v1/query_range",
        )

    def test_grafana_service_proxy_uses_fixed_allowlisted_path(self) -> None:
        transport, api_client = self.transport()

        transport.grafana_health()

        self.assertEqual(
            api_client.calls[0]["resource_path"],
            "/api/v1/namespaces/monitoring/services/kube-prometheus-stack-grafana:80/proxy/api/health",
        )

    def test_arbitrary_proxy_path_is_rejected(self) -> None:
        transport, _ = self.transport()

        with self.assertRaisesRegex(ObservabilityUnavailableError, "not allowed"):
            transport.request_json(
                service_name="loki-gateway",
                service_port=80,
                path="/api/v1/namespaces/default/secrets",
                params={},
                service_label="Loki",
            )

    def test_arbitrary_service_or_namespace_is_rejected(self) -> None:
        api_client = FakeApiClient()

        with self.assertRaisesRegex(ObservabilityUnavailableError, "namespace"):
            KubernetesServiceProxyTransport(
                api_client=api_client,
                namespace="../default",
                max_response_bytes=100,
            )

        transport, _ = self.transport()
        with self.assertRaisesRegex(ObservabilityUnavailableError, "service"):
            transport.request_json(
                service_name="http://example.com",
                service_port=80,
                path="/api/v1/query",
                params={},
                service_label="Prometheus",
            )

    def test_service_proxy_response_is_bounded(self) -> None:
        api_client = FakeApiClient(KubernetesProxyResponse(b'{"status":"success"}'))
        transport = KubernetesServiceProxyTransport(
            api_client=api_client,
            namespace="monitoring",
            max_response_bytes=4,
        )

        with self.assertRaisesRegex(ObservabilityUnavailableError, "too large"):
            transport.prometheus_query({"query": "up"})

    def test_prometheus_and_loki_services_use_service_proxy_mode(self) -> None:
        transport, api_client = self.transport()

        with patch("app.services.prometheus_service.settings.observability_access_mode", "kubernetes_service_proxy"):
            PrometheusService(service_proxy=transport).check_health()
        with patch("app.services.loki_service.settings.observability_access_mode", "kubernetes_service_proxy"):
            LokiService(service_proxy=transport).check_health()

        self.assertEqual(len(api_client.calls), 2)


if __name__ == "__main__":
    unittest.main()
