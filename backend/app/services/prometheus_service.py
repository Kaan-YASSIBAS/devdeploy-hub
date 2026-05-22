import re
from datetime import datetime, timedelta, timezone
from typing import Any

import httpx

from app.core.config import settings
from app.services.observability_errors import ObservabilityUnavailableError


class PrometheusQueryError(Exception):
    pass


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

    def query_range(self, promql: str, start: datetime, end: datetime, step: str) -> dict[str, Any]:
        url = f"{self.base_url}/api/v1/query_range"
        try:
            response = httpx.get(
                url,
                params={
                    "query": promql,
                    "start": start.timestamp(),
                    "end": end.timestamp(),
                    "step": step,
                },
                timeout=8.0,
            )
            response.raise_for_status()
        except httpx.HTTPError as exc:
            raise ObservabilityUnavailableError(f"Prometheus unavailable: {exc}") from exc

        payload = response.json()
        if payload.get("status") != "success":
            error = payload.get("error") or "query failed"
            raise PrometheusQueryError(str(error))
        return payload

    def get_cluster_metrics_summary(self) -> dict[str, float]:
        return self._build_summary(namespace=None)

    def get_namespace_metrics(self, namespace: str) -> dict[str, float]:
        return self._build_summary(namespace=namespace)

    def get_metrics_timeseries(
        self,
        namespace: str = "devdeploy",
        range_value: str = "15m",
        step: str | None = None,
        metric: str | None = None,
    ) -> dict[str, Any]:
        duration = self._parse_duration(range_value)
        step_value = step or self._default_step(duration)
        self._parse_duration(step_value)
        end = datetime.now(timezone.utc)
        start = end - duration

        definitions = self._timeseries_definitions(namespace)
        if metric:
            definitions = {key: value for key, value in definitions.items() if key == metric}
            if not definitions:
                raise PrometheusQueryError(f"Unsupported metric: {metric}")

        series = [
            self._build_timeseries(key, definition, start, end, step_value)
            for key, definition in definitions.items()
        ]

        return {
            "namespace": namespace,
            "range": range_value,
            "step": step_value,
            "prometheus_available": True,
            "series": series,
        }

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

    def _build_timeseries(
        self,
        key: str,
        definition: dict[str, str],
        start: datetime,
        end: datetime,
        step: str,
    ) -> dict[str, Any]:
        last_error: str | None = None
        for query in definition["queries"].split("\n"):
            query = query.strip()
            if not query:
                continue
            try:
                payload = self.query_range(query, start=start, end=end, step=step)
            except PrometheusQueryError as exc:
                last_error = str(exc)
                continue

            points = self._matrix_points(payload)
            if points:
                return {
                    "key": key,
                    "name": definition["name"],
                    "unit": definition["unit"],
                    "status": "ok",
                    "detail": None,
                    "points": points,
                }

        detail = (
            "Request metrics are not exposed by the application yet."
            if key in {"request_rate", "error_rate"}
            else last_error or "No data returned for this metric."
        )
        status = "unavailable" if last_error else "empty"
        return {
            "key": key,
            "name": definition["name"],
            "unit": definition["unit"],
            "status": status,
            "detail": detail,
            "points": [],
        }

    @staticmethod
    def _matrix_points(payload: dict[str, Any]) -> list[dict[str, Any]]:
        results = payload.get("data", {}).get("result", [])
        if not results:
            return []

        values = results[0].get("values") or []
        points: list[dict[str, Any]] = []
        for raw_timestamp, raw_value in values:
            try:
                value = float(raw_value)
            except (TypeError, ValueError):
                continue
            points.append(
                {
                    "timestamp": datetime.fromtimestamp(float(raw_timestamp), tz=timezone.utc),
                    "value": value,
                }
            )
        return points

    @staticmethod
    def _timeseries_definitions(namespace: str) -> dict[str, dict[str, str]]:
        namespace_selector = f'namespace="{namespace}"'
        ingress_namespace_selector = f'exported_namespace="{namespace}"'
        return {
            "cpu_usage": {
                "name": "CPU usage",
                "unit": "cores",
                "queries": (
                    f'sum(rate(container_cpu_usage_seconds_total{{{namespace_selector},container!="",image!=""}}[5m]))'
                ),
            },
            "memory_working_set": {
                "name": "Memory working set",
                "unit": "bytes",
                "queries": (
                    f'sum(container_memory_working_set_bytes{{{namespace_selector},container!="",image!=""}})'
                ),
            },
            "pod_restarts": {
                "name": "Pod restarts",
                "unit": "count",
                "queries": f"sum(increase(kube_pod_container_status_restarts_total{{{namespace_selector}}}[5m]))",
            },
            "request_rate": {
                "name": "Request rate",
                "unit": "requests/s",
                "queries": "\n".join(
                    [
                        f"sum(rate(http_requests_total{{{namespace_selector}}}[5m]))",
                        f"sum(rate(nginx_ingress_controller_requests{{{ingress_namespace_selector}}}[5m]))",
                    ]
                ),
            },
            "error_rate": {
                "name": "Error rate",
                "unit": "errors/s",
                "queries": "\n".join(
                    [
                        f'sum(rate(http_requests_total{{{namespace_selector},status=~"5.."}}[5m]))',
                        f'sum(rate(nginx_ingress_controller_requests{{{ingress_namespace_selector},status=~"5.."}}[5m]))',
                    ]
                ),
            },
        }

    @staticmethod
    def _parse_duration(value: str) -> timedelta:
        match = re.fullmatch(r"([1-9][0-9]*)([smhd])", value.strip())
        if not match:
            raise PrometheusQueryError("Duration must look like 5m, 15m, 1h, 6h, 24h, or 7d.")

        amount = int(match.group(1))
        unit = match.group(2)
        if unit == "s":
            return timedelta(seconds=amount)
        if unit == "m":
            return timedelta(minutes=amount)
        if unit == "h":
            return timedelta(hours=amount)
        return timedelta(days=amount)

    @staticmethod
    def _default_step(duration: timedelta) -> str:
        if duration <= timedelta(minutes=5):
            return "15s"
        if duration <= timedelta(minutes=15):
            return "30s"
        if duration <= timedelta(hours=1):
            return "1m"
        if duration <= timedelta(hours=6):
            return "5m"
        if duration <= timedelta(hours=24):
            return "15m"
        return "1h"
