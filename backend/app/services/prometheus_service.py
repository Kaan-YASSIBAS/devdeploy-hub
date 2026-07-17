import logging
import re
from datetime import datetime, timedelta, timezone
from typing import Any

import httpx

from app.core.config import settings
from app.services.observability_http import QUERY_TIMEOUT, RANGE_QUERY_TIMEOUT, get_bounded_json
from app.services.observability_errors import ObservabilityUnavailableError
from app.services.observability_query import (
    escape_label_value,
    validate_metric_range,
    validate_metric_step,
    validate_namespace,
)
from app.services.observability_service_proxy import KubernetesServiceProxyTransport


logger = logging.getLogger(__name__)


class PrometheusQueryError(Exception):
    pass


class PrometheusService:
    def __init__(self, base_url: str | None = None, service_proxy: KubernetesServiceProxyTransport | None = None) -> None:
        self._explicit_base_url = base_url is not None
        self.base_url = (base_url or settings.prometheus_base_url).rstrip("/")
        self.service_proxy = service_proxy

    def check_health(self) -> None:
        self.query("vector(1)")

    def query(self, promql: str) -> dict[str, Any]:
        if self._use_service_proxy:
            payload = (self.service_proxy or KubernetesServiceProxyTransport.from_settings()).prometheus_query(
                {"query": promql}
            )
            if payload.get("status") != "success":
                raise ObservabilityUnavailableError("Prometheus query failed.")
            return payload
        if not self.base_url:
            raise ObservabilityUnavailableError("Prometheus configuration is missing.")
        url = f"{self.base_url}/api/v1/query"
        try:
            payload = get_bounded_json(
                url,
                params={"query": promql},
                timeout=QUERY_TIMEOUT,
                service_name="Prometheus",
            )
        except httpx.TimeoutException as exc:
            raise ObservabilityUnavailableError("Prometheus request timed out.") from exc
        except httpx.HTTPStatusError as exc:
            raise ObservabilityUnavailableError("Prometheus returned an unsuccessful response.") from exc
        except httpx.HTTPError as exc:
            raise ObservabilityUnavailableError("Prometheus is unreachable.") from exc
        if payload.get("status") != "success":
            raise ObservabilityUnavailableError("Prometheus query failed.")
        return payload

    def query_range(self, promql: str, start: datetime, end: datetime, step: str) -> dict[str, Any]:
        if self._use_service_proxy:
            payload = (self.service_proxy or KubernetesServiceProxyTransport.from_settings()).prometheus_query_range(
                {
                    "query": promql,
                    "start": start.timestamp(),
                    "end": end.timestamp(),
                    "step": step,
                }
            )
            if payload.get("status") != "success":
                raise PrometheusQueryError("Prometheus range query failed.")
            return payload
        if not self.base_url:
            raise ObservabilityUnavailableError("Prometheus configuration is missing.")
        url = f"{self.base_url}/api/v1/query_range"
        try:
            payload = get_bounded_json(
                url,
                params={
                    "query": promql,
                    "start": start.timestamp(),
                    "end": end.timestamp(),
                    "step": step,
                },
                timeout=RANGE_QUERY_TIMEOUT,
                service_name="Prometheus",
            )
        except httpx.TimeoutException as exc:
            raise ObservabilityUnavailableError("Prometheus request timed out.") from exc
        except httpx.HTTPStatusError as exc:
            raise ObservabilityUnavailableError("Prometheus returned an unsuccessful response.") from exc
        except httpx.HTTPError as exc:
            raise ObservabilityUnavailableError("Prometheus is unreachable.") from exc
        if payload.get("status") != "success":
            raise PrometheusQueryError("Prometheus range query failed.")
        return payload

    def get_cluster_metrics_summary(self) -> dict[str, float]:
        return self._build_summary(namespace=None)

    def get_namespace_metrics(self, namespace: str) -> dict[str, float]:
        return self._build_summary(namespace=validate_namespace(namespace))

    def get_metrics_timeseries(
        self,
        namespace: str = "devdeploy",
        range_value: str = "15m",
        step: str | None = None,
        metric: str | None = None,
    ) -> dict[str, Any]:
        namespace = validate_namespace(namespace)
        range_window = validate_metric_range(range_value)
        duration = self._parse_duration(range_window)
        step_value = validate_metric_step(step or self._default_step(duration))
        if step_value is None:
            raise PrometheusQueryError("step is required")
        end = datetime.now(timezone.utc)
        start = end - duration

        definitions = self._timeseries_definitions(namespace, restart_window=range_window)
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
            "range": range_window,
            "step": step_value,
            "prometheus_available": True,
            "series": series,
        }

    def _build_summary(self, namespace: str | None) -> dict[str, float]:
        namespace_value = escape_label_value(namespace) if namespace else None
        selector = f'namespace="{namespace_value}",' if namespace_value else ""
        deployment_selector = f'{{namespace="{namespace_value}"}}' if namespace_value else ""

        queries = {
            "cpu_usage_cores": f'sum(rate(container_cpu_usage_seconds_total{{{selector}container!="",image!=""}}[5m]))',
            "memory_working_set_bytes": f'sum(container_memory_working_set_bytes{{{selector}container!="",image!=""}})',
            "pod_count": f'count(kube_pod_info{{namespace="{namespace_value}"}})' if namespace_value else "count(kube_pod_info)",
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

            if key == "pod_restarts" and not self._matrix_has_series(payload):
                self._log_empty_restart_series(definition, start=start, end=end, step=step)

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

        if key == "request_rate":
            detail = "No request rate samples returned for this time range."
        elif key == "error_rate":
            detail = (
                "No 5xx error metrics. The system has not produced server errors or the app is "
                "not exposing 5xx metrics."
            )
        elif key == "pod_restarts":
            detail = (
                "Prometheus could not return pod restart data for this metric."
                if last_error
                else "No kube_pod_container_status_restarts_total series returned for this namespace and range."
            )
        else:
            detail = "Prometheus could not return data for this metric." if last_error else "No data returned for this metric."

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
    def _matrix_has_series(payload: dict[str, Any]) -> bool:
        return bool(payload.get("data", {}).get("result", []))

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
    def _log_empty_restart_series(
        definition: dict[str, str],
        start: datetime,
        end: datetime,
        step: str,
    ) -> None:
        logger.info(
            "Prometheus returned no pod restart series for namespace=%s range=%s window=%s step=%s start=%s end=%s",
            definition.get("namespace", ""),
            definition.get("range", ""),
            definition.get("restart_window", ""),
            step,
            start.isoformat(),
            end.isoformat(),
        )

    @staticmethod
    def _timeseries_definitions(namespace: str, restart_window: str) -> dict[str, dict[str, str]]:
        namespace_value = escape_label_value(namespace)
        namespace_selector = f'namespace="{namespace_value}"'
        ingress_namespace_selector = f'exported_namespace="{namespace_value}"'
        error_status_selector = 'status=~"5..|5xx"'
        error_status_code_selector = 'status_code=~"5..|5xx"'
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
                "namespace": namespace,
                "range": restart_window,
                "restart_window": restart_window,
                "queries": f"sum(increase(kube_pod_container_status_restarts_total{{{namespace_selector}}}[5m]))",
            },
            "request_rate": {
                "name": "Request rate",
                "unit": "requests/s",
                "queries": "\n".join(
                    [
                        f"sum(rate(http_requests_total{{{namespace_selector}}}[5m]))",
                        f"sum(rate(http_request_duration_seconds_count{{{namespace_selector}}}[5m]))",
                        f"sum(rate(nginx_ingress_controller_requests{{{ingress_namespace_selector}}}[5m]))",
                    ]
                ),
            },
            "error_rate": {
                "name": "Error rate",
                "unit": "errors/s",
                "queries": "\n".join(
                    [
                        f"sum(rate(http_requests_total{{{namespace_selector},{error_status_selector}}}[5m]))",
                        f"sum(rate(http_requests_total{{{namespace_selector},{error_status_code_selector}}}[5m]))",
                        f"sum(rate(http_request_duration_seconds_count{{{namespace_selector},{error_status_selector}}}[5m]))",
                        f"sum(rate(http_request_duration_seconds_count{{{namespace_selector},{error_status_code_selector}}}[5m]))",
                        f"sum(rate(nginx_ingress_controller_requests{{{ingress_namespace_selector},{error_status_selector}}}[5m]))",
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

    @property
    def _use_service_proxy(self) -> bool:
        return settings.observability_access_mode == "kubernetes_service_proxy" and not self._explicit_base_url
