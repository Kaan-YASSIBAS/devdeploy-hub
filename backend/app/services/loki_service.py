from typing import Any

import httpx

from app.core.config import settings
from app.services.observability_errors import ObservabilityUnavailableError
from app.services.observability_http import RANGE_QUERY_TIMEOUT, get_bounded_json
from app.services.observability_query import escape_label_value, validate_namespace, validate_pod_name


class LokiService:
    def __init__(self, base_url: str | None = None) -> None:
        self.base_url = (base_url or settings.loki_base_url).rstrip("/")

    def check_health(self) -> None:
        self.query_logs(namespace=settings.workload_namespace, limit=1)

    def query_logs(self, namespace: str, limit: int = 100) -> list[dict[str, Any]]:
        safe_namespace = escape_label_value(validate_namespace(namespace))
        return self._query_range(query=f'{{namespace="{safe_namespace}"}}', limit=limit)

    def query_logs_by_pod(self, namespace: str, pod: str, limit: int = 100) -> list[dict[str, Any]]:
        safe_namespace = escape_label_value(validate_namespace(namespace))
        safe_pod = escape_label_value(validate_pod_name(pod))
        return self._query_range(query=f'{{namespace="{safe_namespace}", pod="{safe_pod}"}}', limit=limit)

    def _query_range(self, query: str, limit: int) -> list[dict[str, Any]]:
        url = f"{self.base_url}/loki/api/v1/query_range"
        safe_limit = min(max(limit, 1), 500)
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
