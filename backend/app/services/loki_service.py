from typing import Any

import httpx

from app.core.config import settings
from app.services.observability_errors import ObservabilityUnavailableError
from app.services.observability_http import RANGE_QUERY_TIMEOUT, get_bounded_json
from app.services.observability_query import escape_label_value, validate_namespace, validate_pod_name
from app.services.observability_service_proxy import KubernetesServiceProxyTransport


class LokiService:
    def __init__(self, base_url: str | None = None, service_proxy: KubernetesServiceProxyTransport | None = None) -> None:
        self._explicit_base_url = base_url is not None
        self.base_url = (base_url or settings.loki_base_url).rstrip("/")
        self.service_proxy = service_proxy

    def check_health(self) -> None:
        if self._use_service_proxy:
            payload = (self.service_proxy or KubernetesServiceProxyTransport.from_settings()).loki_labels()
        else:
            if not self.base_url:
                raise ObservabilityUnavailableError("Loki configuration is missing.")
            try:
                payload = get_bounded_json(
                    f"{self.base_url}/loki/api/v1/labels",
                    params=None,
                    timeout=RANGE_QUERY_TIMEOUT,
                    service_name="Loki",
                )
            except httpx.TimeoutException as exc:
                raise ObservabilityUnavailableError("Loki request timed out.") from exc
            except httpx.HTTPStatusError as exc:
                raise ObservabilityUnavailableError("Loki returned an unsuccessful response.") from exc
            except httpx.HTTPError as exc:
                raise ObservabilityUnavailableError("Loki is unreachable.") from exc
        if payload.get("status") != "success":
            raise ObservabilityUnavailableError("Loki health check failed.")

    def query_logs(self, namespace: str, limit: int = 100) -> list[dict[str, Any]]:
        safe_namespace = escape_label_value(validate_namespace(namespace))
        return self._query_range(query=f'{{namespace="{safe_namespace}"}}', limit=limit)

    def query_logs_by_pod(self, namespace: str, pod: str, limit: int = 100) -> list[dict[str, Any]]:
        safe_namespace = escape_label_value(validate_namespace(namespace))
        safe_pod = escape_label_value(validate_pod_name(pod))
        return self._query_range(query=f'{{namespace="{safe_namespace}", pod="{safe_pod}"}}', limit=limit)

    def _query_range(self, query: str, limit: int) -> list[dict[str, Any]]:
        safe_limit = min(max(limit, 1), 500)
        if self._use_service_proxy:
            payload = (self.service_proxy or KubernetesServiceProxyTransport.from_settings()).loki_query_range(
                {"query": query, "limit": safe_limit, "direction": "backward"}
            )
        else:
            if not self.base_url:
                raise ObservabilityUnavailableError("Loki configuration is missing.")
            url = f"{self.base_url}/loki/api/v1/query_range"
            try:
                payload = get_bounded_json(
                    url,
                    params={"query": query, "limit": safe_limit, "direction": "backward"},
                    timeout=RANGE_QUERY_TIMEOUT,
                    service_name="Loki",
                )
            except httpx.TimeoutException as exc:
                raise ObservabilityUnavailableError("Loki request timed out.") from exc
            except httpx.HTTPStatusError as exc:
                raise ObservabilityUnavailableError("Loki returned an unsuccessful response.") from exc
            except httpx.HTTPError as exc:
                raise ObservabilityUnavailableError("Loki is unreachable.") from exc
        if payload.get("status") != "success":
            raise ObservabilityUnavailableError("Loki query failed.")

        entries: list[dict[str, Any]] = []
        for stream in payload.get("data", {}).get("result", []):
            labels = stream.get("stream", {})
            for timestamp, line in stream.get("values", []):
                entries.append({"timestamp": timestamp, "line": line, "labels": labels})

        return entries[:safe_limit]

    @property
    def _use_service_proxy(self) -> bool:
        return settings.observability_access_mode == "kubernetes_service_proxy" and not self._explicit_base_url
