import json
import logging
import re
from collections.abc import Mapping
from pathlib import Path
from typing import Any
from urllib.parse import quote

from kubernetes import client, config
from kubernetes.client import ApiException
from kubernetes.config.kube_config import KubeConfigLoader
from kubernetes.config.config_exception import ConfigException

from app.core.config import settings
from app.services.observability_errors import (
    ObservabilityMalformedResponseError,
    ObservabilityRestrictedError,
    ObservabilityUnavailableError,
)


KUBERNETES_DNS_LABEL = re.compile(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")
ALLOWED_PROXY_PATHS = {
    "/api/v1/query",
    "/api/v1/query_range",
    "/loki/api/v1/labels",
    "/loki/api/v1/query_range",
    "/api/health",
}
REQUEST_TIMEOUT = (2, 8)
logger = logging.getLogger(__name__)


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

    def loki_labels(self) -> dict[str, Any]:
        return self.request_json(
            service_name=settings.observability_loki_service_name,
            service_port=settings.observability_loki_service_port,
            path="/loki/api/v1/labels",
            params={},
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
        logger.info(
            "Observability service proxy request: mode=%s namespace=%s service=%s port=%s path=%s resource_path=%s",
            settings.observability_access_mode,
            self.namespace,
            safe_service,
            service_port,
            path,
            resource_path,
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
                response_types_map={},
                auth_settings=["BearerToken"],
                async_req=False,
                _return_http_data_only=True,
                _preload_content=False,
                _request_timeout=self.request_timeout,
                _request_auth=self._request_auth(),
            )
        except ApiException as exc:
            logger.warning(
                "Observability service proxy Kubernetes API failure: service=%s status=%s reason=%s",
                service_label,
                exc.status,
                exc.reason,
            )
            if exc.status in {401, 403}:
                raise ObservabilityRestrictedError(f"{service_label} service proxy access is restricted.") from exc
            raise ObservabilityUnavailableError(f"{service_label} service proxy request failed.") from exc
        except Exception as exc:
            logger.warning(
                "Observability service proxy request failure: service=%s error=%s",
                service_label,
                exc.__class__.__name__,
            )
            raise ObservabilityUnavailableError(f"{service_label} service proxy request failed.") from exc

        return self._read_json_response(response, service_label)

    @staticmethod
    def _service_proxy_path(*, namespace: str, service_name: str, service_port: int, path: str) -> str:
        encoded_path = quote(path.lstrip("/"), safe="/")
        return f"/api/v1/namespaces/{namespace}/services/http:{service_name}:{service_port}/proxy/{encoded_path}"

    @staticmethod
    def _validate_name(value: str, label: str) -> str:
        if not isinstance(value, str) or len(value) > 63 or not KUBERNETES_DNS_LABEL.fullmatch(value):
            raise ObservabilityUnavailableError(f"Configured {label} name is invalid.")
        return value

    @staticmethod
    def _build_workload_api_client() -> client.ApiClient:
        configuration = client.Configuration()
        kubeconfig_path = settings.resolved_observability_workload_kubeconfig
        if not kubeconfig_path:
            raise ObservabilityUnavailableError("Workload kubeconfig is required for observability service proxy.")
        try:
            load_options: dict[str, Any] = {
                "config_file": kubeconfig_path,
                "client_configuration": configuration,
            }
            if settings.observability_workload_kubeconfig_context:
                load_options["context"] = settings.observability_workload_kubeconfig_context.strip()
            config.load_kube_config(**load_options)
            KubernetesServiceProxyTransport._normalize_authorization_header(configuration)
        except (ConfigException, OSError, ValueError) as exc:
            KubernetesServiceProxyTransport._load_json_kubeconfig_fallback(
                kubeconfig_path,
                configuration,
                context=settings.observability_workload_kubeconfig_context,
                original_error=exc,
            )
        except Exception as exc:
            KubernetesServiceProxyTransport._load_json_kubeconfig_fallback(
                kubeconfig_path,
                configuration,
                context=settings.observability_workload_kubeconfig_context,
                original_error=exc,
            )
        return client.ApiClient(configuration)

    @staticmethod
    def _normalize_authorization_header(configuration: client.Configuration) -> None:
        authorization = configuration.api_key.get("authorization") or configuration.api_key.get("BearerToken")
        if not authorization:
            return
        token = authorization.strip()
        while token.lower().startswith("bearer "):
            token = token[7:].strip()
        if not token:
            return
        configuration.api_key["authorization"] = token
        configuration.api_key_prefix["authorization"] = "Bearer"
        configuration.api_key["BearerToken"] = token
        configuration.api_key_prefix["BearerToken"] = "Bearer"

    @staticmethod
    def _load_json_kubeconfig_fallback(
        kubeconfig_path: str,
        configuration: client.Configuration,
        *,
        context: str | None,
        original_error: Exception,
    ) -> None:
        try:
            raw_config = Path(kubeconfig_path).read_text(encoding="utf-8-sig")
            payload = json.loads(raw_config)
            if not isinstance(payload, dict):
                raise ValueError("Kubeconfig JSON root must be an object.")
            active_context = context.strip() if context and context.strip() else None
            KubeConfigLoader(config_dict=payload, active_context=active_context).load_and_set(configuration)
            KubernetesServiceProxyTransport._normalize_authorization_header(configuration)
            logger.info(
                "Loaded observability workload kubeconfig with JSON fallback after standard loader failure: error=%s",
                original_error.__class__.__name__,
            )
        except Exception as fallback_error:
            logger.warning(
                "Observability workload kubeconfig load failed: standard_error=%s fallback_error=%s",
                original_error.__class__.__name__,
                fallback_error.__class__.__name__,
            )
            raise ObservabilityUnavailableError("Workload kubeconfig is unavailable.") from fallback_error

    def _read_json_response(self, response: Any, service_label: str) -> dict[str, Any]:
        content_type = self._response_header(response, "content-type")
        response_status = self._response_status(response)
        logger.info(
            "Observability service proxy response: service=%s status=%s content_type=%s",
            service_label,
            response_status,
            self._response_content_type_category(content_type),
        )
        if content_type and "json" not in content_type.lower():
            logger.warning(
                "Observability service proxy unsupported response type: service=%s status=%s content_type=%s",
                service_label,
                response_status,
                self._response_content_type_category(content_type),
            )
            raise ObservabilityMalformedResponseError(f"{service_label} returned an unsupported response type.")

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
            logger.warning(
                "Observability service proxy malformed JSON: service=%s status=%s bytes=%s",
                service_label,
                response_status,
                len(body),
            )
            raise ObservabilityMalformedResponseError(f"{service_label} returned a malformed response.") from exc
        if not isinstance(payload, dict):
            logger.warning(
                "Observability service proxy unexpected JSON shape: service=%s status=%s shape=%s",
                service_label,
                response_status,
                type(payload).__name__,
            )
            raise ObservabilityMalformedResponseError(f"{service_label} returned a malformed response.")
        logger.info(
            "Observability service proxy JSON parsed: service=%s status=%s shape=dict keys=%s",
            service_label,
            response_status,
            sorted(str(key) for key in payload.keys())[:8],
        )
        return payload

    def _request_auth(self) -> dict[str, str] | None:
        configuration = getattr(self.api_client, "configuration", None)
        if configuration is None:
            return None
        api_key = getattr(configuration, "api_key", {}) or {}
        authorization = api_key.get("authorization") or api_key.get("Authorization")
        if not authorization:
            raise ObservabilityUnavailableError("Workload kubeconfig credentials are unavailable.")
        prefix = (getattr(configuration, "api_key_prefix", {}) or {}).get("authorization")
        value = f"{prefix} {authorization}" if prefix and not str(authorization).lower().startswith("bearer ") else authorization
        return {
            "in": "header",
            "key": "authorization",
            "value": value,
        }

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

    @staticmethod
    def _response_status(response: Any) -> int | str:
        status = getattr(response, "status", None)
        if status is None:
            status = getattr(response, "status_code", None)
        return status if status is not None else "unknown"

    @staticmethod
    def _response_content_type_category(content_type: str) -> str:
        if not content_type:
            return "missing"
        lower = content_type.lower()
        if "json" in lower:
            return "json"
        if "text" in lower:
            return "text"
        return "other"
