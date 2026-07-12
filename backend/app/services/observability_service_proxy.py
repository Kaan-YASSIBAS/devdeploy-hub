import json
import re
from collections.abc import Mapping
from pathlib import Path
from typing import Any
from urllib.parse import quote

from kubernetes import client, config
from kubernetes.config.config_exception import ConfigException

from app.core.config import settings
from app.services.observability_errors import ObservabilityUnavailableError


KUBERNETES_DNS_LABEL = re.compile(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")
ALLOWED_PROXY_PATHS = {
    "/api/v1/query",
    "/api/v1/query_range",
    "/loki/api/v1/query_range",
    "/api/health",
}
REQUEST_TIMEOUT = (2, 8)


class KubernetesServiceProxyTransport:
    def __init__(
        self,
        *,
        api_client: client.ApiClient,
        namespace: str,
        max_response_bytes: int,
        request_timeout: tuple[int, int] = REQUEST_TIMEOUT,
    ) -> None:
        self.api_client = api_client
        self.namespace = self._validate_name(namespace, "namespace")
        self.max_response_bytes = max_response_bytes
        self.request_timeout = request_timeout

    @classmethod
    def from_settings(cls) -> "KubernetesServiceProxyTransport":
        return cls(
            api_client=cls._build_workload_api_client(),
            namespace=settings.observability_monitoring_namespace,
            max_response_bytes=settings.observability_max_response_bytes,
        )

    def prometheus_query(self, params: Mapping[str, Any]) -> dict[str, Any]:
        return self.request_json(
            service_name=settings.observability_prometheus_service_name,
            service_port=settings.observability_prometheus_service_port,
            path="/api/v1/query",
            params=params,
            service_label="Prometheus",
        )

    def prometheus_query_range(self, params: Mapping[str, Any]) -> dict[str, Any]:
        return self.request_json(
            service_name=settings.observability_prometheus_service_name,
            service_port=settings.observability_prometheus_service_port,
            path="/api/v1/query_range",
            params=params,
            service_label="Prometheus",
        )

    def loki_query_range(self, params: Mapping[str, Any]) -> dict[str, Any]:
        return self.request_json(
            service_name=settings.observability_loki_service_name,
            service_port=settings.observability_loki_service_port,
            path="/loki/api/v1/query_range",
            params=params,
            service_label="Loki",
        )

    def grafana_health(self) -> dict[str, Any]:
        return self.request_json(
            service_name=settings.observability_grafana_service_name,
            service_port=settings.observability_grafana_service_port,
            path="/api/health",
            params={},
            service_label="Grafana",
        )

    def request_json(
        self,
        *,
        service_name: str,
        service_port: int,
        path: str,
        params: Mapping[str, Any],
        service_label: str,
    ) -> dict[str, Any]:
        safe_service = self._validate_name(service_name, "service")
        if path not in ALLOWED_PROXY_PATHS:
            raise ObservabilityUnavailableError(f"{service_label} path is not allowed.")
        if service_port < 1 or service_port > 65535:
            raise ObservabilityUnavailableError(f"{service_label} service port is invalid.")

        resource_path = self._service_proxy_path(
            namespace=self.namespace,
            service_name=safe_service,
            service_port=service_port,
            path=path,
        )
        try:
            response = self.api_client.call_api(
                resource_path=resource_path,
                method="GET",
                path_params={},
                query_params=list(params.items()),
                header_params={"Accept": "application/json"},
                body=None,
                post_params=[],
                files={},
                response_type=None,
                auth_settings=["BearerToken"],
                async_req=False,
                _return_http_data_only=True,
                _preload_content=False,
                _request_timeout=self.request_timeout,
            )
        except Exception as exc:
            raise ObservabilityUnavailableError(f"{service_label} service proxy request failed.") from exc

        return self._read_json_response(response, service_label)

    @staticmethod
    def _service_proxy_path(*, namespace: str, service_name: str, service_port: int, path: str) -> str:
        encoded_path = quote(path.lstrip("/"), safe="/")
        return f"/api/v1/namespaces/{namespace}/services/{service_name}:{service_port}/proxy/{encoded_path}"

    @staticmethod
    def _validate_name(value: str, label: str) -> str:
        if not isinstance(value, str) or len(value) > 63 or not KUBERNETES_DNS_LABEL.fullmatch(value):
            raise ObservabilityUnavailableError(f"Configured {label} name is invalid.")
        return value

    @staticmethod
    def _build_workload_api_client() -> client.ApiClient:
        configuration = client.Configuration()
        kubeconfig_path = settings.workload_kubeconfig
        if not kubeconfig_path:
            raise ObservabilityUnavailableError("Workload kubeconfig is required for observability service proxy.")
        try:
            load_options: dict[str, Any] = {
                "config_file": str(Path(kubeconfig_path).expanduser()),
                "client_configuration": configuration,
            }
            if settings.workload_kubeconfig_context:
                load_options["context"] = settings.workload_kubeconfig_context.strip()
            config.load_kube_config(**load_options)
        except (ConfigException, OSError, ValueError) as exc:
            raise ObservabilityUnavailableError("Workload kubeconfig is unavailable.") from exc
        return client.ApiClient(configuration)

    def _read_json_response(self, response: Any, service_label: str) -> dict[str, Any]:
        content_type = self._response_header(response, "content-type")
        if content_type and "json" not in content_type.lower():
            raise ObservabilityUnavailableError(f"{service_label} returned an unsupported response type.")

        body = bytearray()
        try:
            stream = getattr(response, "stream", None)
            if callable(stream):
                for chunk in stream(amt=65536):
                    body.extend(chunk)
                    self._enforce_size(body, service_label)
            else:
                while True:
                    chunk = response.read(65536)
                    if not chunk:
                        break
                    body.extend(chunk)
                    self._enforce_size(body, service_label)
        except ObservabilityUnavailableError:
            raise
        except Exception as exc:
            raise ObservabilityUnavailableError(f"{service_label} response could not be read.") from exc

        try:
            payload = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, ValueError) as exc:
            raise ObservabilityUnavailableError(f"{service_label} returned a malformed response.") from exc
        if not isinstance(payload, dict):
            raise ObservabilityUnavailableError(f"{service_label} returned a malformed response.")
        return payload

    def _enforce_size(self, body: bytearray, service_label: str) -> None:
        if len(body) > self.max_response_bytes:
            raise ObservabilityUnavailableError(f"{service_label} returned a response that is too large.")

    @staticmethod
    def _response_header(response: Any, key: str) -> str:
        headers = getattr(response, "headers", None)
        if isinstance(headers, Mapping):
            value = headers.get(key) or headers.get(key.title())
            return str(value) if value is not None else ""
        getheaders = getattr(response, "getheaders", None)
        if callable(getheaders):
            value = getheaders().get(key)
            return str(value) if value is not None else ""
        return ""
