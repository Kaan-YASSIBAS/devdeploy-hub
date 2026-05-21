from typing import Any

import httpx

from app.core.config import settings
from app.services.observability_errors import ObservabilityUnavailableError


class PrometheusService:
    def __init__(self, base_url: str | None = None) -> None:
        self.base_url = (base_url or settings.prometheus_base_url).rstrip("/")

    def check_health(self) -> None:
        self.query("up")

    def query(self, promql: str) -> dict[str, Any]:
        url = f"{self.base_url}/api/v1/query"
        try:
            response = httpx.get(url, params={"query": promql}, timeout=5.0)
            response.raise_for_status()
        except httpx.HTTPError as exc:
            raise ObservabilityUnavailableError(f"Prometheus unavailable: {exc}") from exc

        payload = response.json()
        if payload.get("status") != "success":
            error = payload.get("error") or "query failed"
            raise ObservabilityUnavailableError(f"Prometheus query failed: {error}")
        return payload

    def get_cluster_metrics_summary(self) -> dict[str, float]:
        return self._build_summary(namespace=None)

    def get_namespace_metrics(self, namespace: str) -> dict[str, float]:
        return self._build_summary(namespace=namespace)

    def _build_summary(self, namespace: str | None) -> dict[str, float]:
        selector = f'namespace="{namespace}",' if namespace else ""
        deployment_selector = f'{{namespace="{namespace}"}}' if namespace else ""

        queries = {
            "cpu_usage_cores": f'sum(rate(container_cpu_usage_seconds_total{{{selector}container!="",image!=""}}[5m]))',
            "memory_working_set_bytes": f'sum(container_memory_working_set_bytes{{{selector}container!="",image!=""}})',
            "pod_count": f'count(kube_pod_info{{namespace="{namespace}"}})' if namespace else "count(kube_pod_info)",
            "restart_count": f"sum(kube_pod_container_status_restarts_total{{{selector[:-1]}}})"
            if namespace
            else "sum(kube_pod_container_status_restarts_total)",
            "deployment_available_replicas": f"sum(kube_deployment_status_replicas_available{deployment_selector})",
        }

        return {key: self._first_value_float(self.query(query)) for key, query in queries.items()}

    @staticmethod
    def _first_value_float(payload: dict[str, Any]) -> float:
        results = payload.get("data", {}).get("result", [])
        if not results:
            return 0.0
        value = results[0].get("value")
        if not value or len(value) < 2:
            return 0.0
        try:
            return float(value[1])
        except (TypeError, ValueError):
            return 0.0
