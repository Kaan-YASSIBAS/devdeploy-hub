from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import logging
import time
from typing import Any

import httpx
from kubernetes.client import ApiException

from app.core.config import settings
from app.schemas.observability import ObservabilityComponentHealth, ObservabilityStatus
from app.services.kubernetes_service import KubernetesService
from app.services.loki_service import LokiService
from app.services.observability_http import QUERY_TIMEOUT, get_bounded_json
from app.services.observability_errors import (
    ObservabilityMalformedResponseError,
    ObservabilityRestrictedError,
    ObservabilityUnavailableError,
)
from app.services.observability_service_proxy import KubernetesServiceProxyTransport
from app.services.prometheus_service import PrometheusService


Check = Callable[[], None]
CacheKey = tuple[Any, ...]
logger = logging.getLogger(__name__)


_STATUS_CACHE: tuple[float, CacheKey, ObservabilityStatus] | None = None


class ObservabilityStatusService:
    def __init__(
        self,
        *,
        kubernetes_check: Check | None = None,
        prometheus_check: Check | None = None,
        loki_check: Check | None = None,
        grafana_check: Check | None = None,
        prometheus_configured: bool | None = None,
        loki_configured: bool | None = None,
        grafana_configured: bool | None = None,
        cache_ttl_seconds: int | None = None,
    ) -> None:
        self.kubernetes_check = kubernetes_check or KubernetesService().check_health
        self.prometheus_check = prometheus_check or PrometheusService().check_health
        self.loki_check = loki_check or LokiService().check_health
        self.grafana_check = grafana_check or self._grafana_health
        self.prometheus_configured = (
            self._component_configured(settings.prometheus_base_url)
            if prometheus_configured is None
            else prometheus_configured
        )
        self.loki_configured = (
            self._component_configured(settings.loki_base_url)
            if loki_configured is None
            else loki_configured
        )
        self.grafana_configured = (
            self._component_configured(settings.grafana_base_url or "")
            if grafana_configured is None
            else grafana_configured
        )
        self.cache_ttl_seconds = (
            settings.observability_health_cache_seconds
            if cache_ttl_seconds is None
            else max(cache_ttl_seconds, 0)
        )

    def get_status(self) -> ObservabilityStatus:
        global _STATUS_CACHE
        now = time.monotonic()
        cache_key = self._cache_key()
        if self.cache_ttl_seconds and _STATUS_CACHE is not None:
            expires_at, cached_key, cached = _STATUS_CACHE
            if now < expires_at and cached_key == cache_key:
                return cached.model_copy(deep=True)

        status = self._collect_status()
        if self.cache_ttl_seconds:
            _STATUS_CACHE = (now + self.cache_ttl_seconds, cache_key, status.model_copy(deep=True))
        return status

    @staticmethod
    def clear_cache() -> None:
        global _STATUS_CACHE
        _STATUS_CACHE = None

    def _cache_key(self) -> CacheKey:
        return (
            self.prometheus_configured,
            self.loki_configured,
            self.grafana_configured,
            settings.prometheus_base_url,
            settings.loki_base_url,
            settings.grafana_base_url,
            settings.observability_access_mode,
            settings.observability_monitoring_namespace,
            settings.observability_prometheus_service_name,
            settings.observability_prometheus_service_port,
            settings.observability_loki_service_name,
            settings.observability_loki_service_port,
            settings.observability_grafana_service_name,
            settings.observability_grafana_service_port,
            settings.resolved_observability_workload_kubeconfig,
            settings.observability_workload_kubeconfig_context,
            settings.observability_max_response_bytes,
        )

    def _collect_status(self) -> ObservabilityStatus:
        tasks = {
            "kubernetes": lambda: self._required_component(
                key="kubernetes",
                label="Kubernetes",
                check=self.kubernetes_check,
                configured=True,
                capabilities={
                    "cluster_summary": True,
                    "resource_inventory": True,
                },
            ),
            "prometheus": lambda: self._required_component(
                key="prometheus",
                label="Prometheus",
                check=self.prometheus_check,
                configured=self.prometheus_configured,
                capabilities={
                    "metrics_summary": self.prometheus_configured,
                    "timeseries": self.prometheus_configured,
                    "arbitrary_promql": False,
                },
            ),
            "loki": lambda: self._required_component(
                key="loki",
                label="Loki",
                check=self.loki_check,
                configured=self.loki_configured,
                capabilities={
                    "logs": self.loki_configured,
                    "arbitrary_logql": False,
                    "streaming": False,
                },
            ),
            "grafana": lambda: self._optional_component(
                key="grafana",
                label="Grafana",
                check=self.grafana_check,
                configured=self.grafana_configured,
                capabilities={
                    "dashboards": self.grafana_configured,
                    "required_for_product": False,
                },
            ),
        }
        with ThreadPoolExecutor(max_workers=len(tasks)) as executor:
            futures = {key: executor.submit(task) for key, task in tasks.items()}
            results = {key: future.result() for key, future in futures.items()}
        return ObservabilityStatus(**results)

    @staticmethod
    def _required_component(
        *,
        key: str,
        label: str,
        check: Check,
        configured: bool,
        capabilities: dict[str, bool],
    ) -> ObservabilityComponentHealth:
        if not configured:
            return ObservabilityStatusService._component(
                available=False,
                status="not_configured",
                detail=f"{label} is not configured.",
                message_code=f"{key}.not_configured",
                capabilities=capabilities,
            )
        return ObservabilityStatusService._checked_component(
            key=key,
            label=label,
            check=check,
            capabilities=capabilities,
        )

    @staticmethod
    def _optional_component(
        *,
        key: str,
        label: str,
        check: Check,
        configured: bool,
        capabilities: dict[str, bool],
    ) -> ObservabilityComponentHealth:
        if not configured:
            return ObservabilityStatusService._component(
                available=False,
                status="optional",
                detail=f"{label} is optional and is not configured.",
                message_code=f"{key}.optional",
                capabilities=capabilities,
            )
        return ObservabilityStatusService._checked_component(
            key=key,
            label=label,
            check=check,
            capabilities=capabilities,
        )

    @staticmethod
    def _checked_component(
        *,
        key: str,
        label: str,
        check: Check,
        capabilities: dict[str, bool],
    ) -> ObservabilityComponentHealth:
        logger.info(
            "Observability health evaluation started: component=%s mode=%s",
            key,
            settings.observability_access_mode,
        )
        try:
            check()
        except ObservabilityRestrictedError:
            component = ObservabilityStatusService._component(
                available=False,
                status="restricted",
                detail=f"{label} access is restricted by backend-to-service credentials.",
                message_code=f"{key}.restricted",
                capabilities=capabilities,
            )
            ObservabilityStatusService._log_component_result(key, component)
            return component
        except ObservabilityMalformedResponseError:
            component = ObservabilityStatusService._component(
                available=False,
                status="degraded",
                detail=f"{label} returned an unreadable health response.",
                message_code=f"{key}.degraded",
                capabilities=capabilities,
            )
            ObservabilityStatusService._log_component_result(key, component)
            return component
        except ObservabilityUnavailableError as exc:
            reason = "not_configured" if "configuration" in str(exc).lower() else "unavailable"
            component = ObservabilityStatusService._component(
                available=False,
                status=reason,
                detail=f"{label} is not reachable.",
                message_code=f"{key}.{reason}",
                capabilities=capabilities,
            )
            ObservabilityStatusService._log_component_result(key, component)
            return component
        except (ApiException, httpx.HTTPError):
            component = ObservabilityStatusService._component(
                available=False,
                status="unavailable",
                detail=f"{label} is not reachable.",
                message_code=f"{key}.unavailable",
                capabilities=capabilities,
            )
            ObservabilityStatusService._log_component_result(key, component)
            return component
        except Exception:
            component = ObservabilityStatusService._component(
                available=False,
                status="degraded",
                detail=f"{label} returned an unreadable health response.",
                message_code=f"{key}.degraded",
                capabilities=capabilities,
            )
            ObservabilityStatusService._log_component_result(key, component)
            return component
        component = ObservabilityStatusService._component(
            available=True,
            status="connected",
            detail=f"{label} is reachable.",
            message_code=f"{key}.connected",
            capabilities=capabilities,
        )
        ObservabilityStatusService._log_component_result(key, component)
        return component

    @staticmethod
    def _component(
        *,
        available: bool,
        status: str,
        detail: str,
        message_code: str,
        capabilities: dict[str, bool],
        version: str | None = None,
    ) -> ObservabilityComponentHealth:
        return ObservabilityComponentHealth(
            available=available,
            status=status,  # type: ignore[arg-type]
            detail=detail,
            checked_at=datetime.now(timezone.utc),
            message_code=message_code,
            capabilities=capabilities,
            version=version,
        )

    @staticmethod
    def _grafana_health() -> None:
        if settings.observability_access_mode == "kubernetes_service_proxy":
            payload = KubernetesServiceProxyTransport.from_settings().grafana_health()
            ObservabilityStatusService._validate_grafana_payload(payload)
            return
        if not settings.grafana_base_url:
            raise ObservabilityUnavailableError("Grafana is not configured.")
        try:
            payload: Any = get_bounded_json(
                f"{settings.grafana_base_url.rstrip('/')}/api/health",
                params=None,
                timeout=QUERY_TIMEOUT,
                service_name="Grafana",
            )
        except httpx.TimeoutException as exc:
            raise ObservabilityUnavailableError("Grafana request timed out.") from exc
        except httpx.HTTPError as exc:
            raise ObservabilityUnavailableError("Grafana is not reachable.") from exc
        if not isinstance(payload, dict):
            raise ObservabilityMalformedResponseError("Grafana returned an unreadable response.")
        ObservabilityStatusService._validate_grafana_payload(payload)

    @staticmethod
    def _validate_grafana_payload(payload: dict[str, Any]) -> None:
        if payload.get("database") != "ok":
            raise ObservabilityUnavailableError("Grafana health check failed.")

    @staticmethod
    def _component_configured(base_url: str) -> bool:
        return settings.observability_access_mode == "kubernetes_service_proxy" or bool(base_url.strip())

    @staticmethod
    def _log_component_result(key: str, component: ObservabilityComponentHealth) -> None:
        logger.info(
            "Observability health evaluation completed: component=%s status=%s available=%s message_code=%s",
            key,
            component.status,
            component.available,
            component.message_code,
        )
