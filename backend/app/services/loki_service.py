from typing import Any

import httpx

from app.core.config import settings
from app.services.observability_errors import ObservabilityUnavailableError
from app.services.observability_query import escape_label_value, validate_namespace, validate_pod_name


class LokiService:
    def __init__(self, base_url: str | None = None) -> None:
        self.base_url = (base_url or settings.loki_base_url).rstrip("/")

    def check_health(self) -> None:
        self.query_logs(namespace="devdeploy", limit=1)

    def query_logs(self, namespace: str, limit: int = 100) -> list[dict[str, Any]]:
        safe_namespace = escape_label_value(validate_namespace(namespace))
        return self._query_range(query=f'{{namespace="{safe_namespace}"}}', limit=limit)

    def query_logs_by_pod(self, namespace: str, pod: str, limit: int = 100) -> list[dict[str, Any]]:
        safe_namespace = escape_label_value(validate_namespace(namespace))
        safe_pod = escape_label_value(validate_pod_name(pod))
        return self._query_range(query=f'{{namespace="{safe_namespace}", pod="{safe_pod}"}}', limit=limit)

    def _query_range(self, query: str, limit: int) -> list[dict[str, Any]]:
        url = f"{self.base_url}/loki/api/v1/query_range"
        try:
            response = httpx.get(
                url,
                params={"query": query, "limit": limit, "direction": "backward"},
                timeout=8.0,
            )
            response.raise_for_status()
        except httpx.HTTPError as exc:
            raise ObservabilityUnavailableError(f"Loki unavailable: {exc}") from exc

        payload = response.json()
        if payload.get("status") != "success":
            error = payload.get("error") or "query failed"
            raise ObservabilityUnavailableError(f"Loki query failed: {error}")

        entries: list[dict[str, Any]] = []
        for stream in payload.get("data", {}).get("result", []):
            labels = stream.get("stream", {})
            for timestamp, line in stream.get("values", []):
                entries.append({"timestamp": timestamp, "line": line, "labels": labels})

        return entries[:limit]
