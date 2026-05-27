from collections.abc import Callable
from typing import TypeVar

from fastapi import APIRouter, Depends, HTTPException, Query, status
from kubernetes.client import ApiException

from app.core.deps import get_current_user
from app.models.user import User
from app.schemas.observability import (
    ClusterSummary,
    DeploymentSummary,
    LogEntry,
    MetricsSummary,
    MetricsTimeSeriesResponse,
    NamespaceSummary,
    ObservabilityComponentHealth,
    ObservabilityHealth,
    PodSummary,
    ServiceSummary,
)
from app.services.kubernetes_service import KubernetesService
from app.services.loki_service import LokiService
from app.services.observability_errors import ObservabilityUnavailableError
from app.services.observability_query import (
    validate_metric_range,
    validate_metric_step,
    validate_namespace,
    validate_optional_namespace,
    validate_pod_name,
)
from app.services.prometheus_service import PrometheusQueryError, PrometheusService


router = APIRouter(prefix="/observability", tags=["observability"])
T = TypeVar("T")


def _unavailable(detail: str) -> HTTPException:
    return HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=detail)


def _call_observability(operation: Callable[[], T]) -> T:
    try:
        return operation()
    except ObservabilityUnavailableError as exc:
        raise _unavailable(str(exc)) from exc
    except ApiException as exc:
        detail = exc.reason or str(exc.status)
        raise _unavailable(f"Kubernetes API request failed: {detail}") from exc


def _bad_request(detail: str) -> HTTPException:
    return HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=detail)


def _component_health(check: Callable[[], None]) -> ObservabilityComponentHealth:
    try:
        check()
    except (ObservabilityUnavailableError, ApiException) as exc:
        return ObservabilityComponentHealth(available=False, detail=str(exc))
    return ObservabilityComponentHealth(available=True)


@router.get("/health", response_model=ObservabilityHealth)
def observability_health(current_user: User = Depends(get_current_user)) -> ObservabilityHealth:
    _ = current_user
    kubernetes_service = KubernetesService()
    prometheus_service = PrometheusService()
    loki_service = LokiService()

    return ObservabilityHealth(
        kubernetes=_component_health(kubernetes_service.check_health),
        prometheus=_component_health(prometheus_service.check_health),
        loki=_component_health(loki_service.check_health),
    )


@router.get("/cluster/summary", response_model=ClusterSummary)
def get_cluster_summary(current_user: User = Depends(get_current_user)) -> dict:
    _ = current_user
    return _call_observability(KubernetesService().get_cluster_summary)


@router.get("/kubernetes/namespaces", response_model=list[NamespaceSummary])
def list_namespaces(current_user: User = Depends(get_current_user)) -> list[dict]:
    _ = current_user
    return _call_observability(KubernetesService().list_namespaces)


@router.get("/kubernetes/pods", response_model=list[PodSummary])
def list_pods(
    namespace: str | None = Query(default=None),
    current_user: User = Depends(get_current_user),
) -> list[dict]:
    _ = current_user
    try:
        safe_namespace = validate_optional_namespace(namespace)
    except ObservabilityUnavailableError as exc:
        raise _bad_request(str(exc)) from exc
    return _call_observability(lambda: KubernetesService().list_pods(namespace=safe_namespace))


@router.get("/kubernetes/deployments", response_model=list[DeploymentSummary])
def list_deployments(
    namespace: str | None = Query(default=None),
    current_user: User = Depends(get_current_user),
) -> list[dict]:
    _ = current_user
    try:
        safe_namespace = validate_optional_namespace(namespace)
    except ObservabilityUnavailableError as exc:
        raise _bad_request(str(exc)) from exc
    return _call_observability(lambda: KubernetesService().list_deployments(namespace=safe_namespace))


@router.get("/kubernetes/services", response_model=list[ServiceSummary])
def list_services(
    namespace: str | None = Query(default=None),
    current_user: User = Depends(get_current_user),
) -> list[dict]:
    _ = current_user
    try:
        safe_namespace = validate_optional_namespace(namespace)
    except ObservabilityUnavailableError as exc:
        raise _bad_request(str(exc)) from exc
    return _call_observability(lambda: KubernetesService().list_services(namespace=safe_namespace))


@router.get("/metrics/cluster", response_model=MetricsSummary)
def get_cluster_metrics(current_user: User = Depends(get_current_user)) -> dict:
    _ = current_user
    return _call_observability(PrometheusService().get_cluster_metrics_summary)


@router.get("/metrics/namespaces/{namespace}", response_model=MetricsSummary)
def get_namespace_metrics(namespace: str, current_user: User = Depends(get_current_user)) -> dict:
    _ = current_user
    try:
        safe_namespace = validate_namespace(namespace)
    except ObservabilityUnavailableError as exc:
        raise _bad_request(str(exc)) from exc
    return _call_observability(lambda: PrometheusService().get_namespace_metrics(safe_namespace))


@router.get("/metrics/timeseries", response_model=MetricsTimeSeriesResponse)
def get_metrics_timeseries(
    namespace: str = Query(default="devdeploy"),
    range_value: str = Query(default="15m", alias="range"),
    step: str | None = Query(default=None),
    metric: str | None = Query(default=None),
    current_user: User = Depends(get_current_user),
) -> dict:
    _ = current_user
    try:
        safe_namespace = validate_namespace(namespace)
        safe_range = validate_metric_range(range_value)
        safe_step = validate_metric_step(step)
    except ObservabilityUnavailableError as exc:
        raise _bad_request(str(exc)) from exc

    try:
        return PrometheusService().get_metrics_timeseries(
            namespace=safe_namespace,
            range_value=safe_range,
            step=safe_step,
            metric=metric,
        )
    except PrometheusQueryError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
    except ObservabilityUnavailableError as exc:
        raise _unavailable(str(exc)) from exc


@router.get("/logs", response_model=list[LogEntry])
def query_logs(
    namespace: str = Query(default="devdeploy"),
    pod: str | None = Query(default=None),
    limit: int = Query(default=100, ge=1, le=500),
    current_user: User = Depends(get_current_user),
) -> list[dict]:
    _ = current_user
    service = LokiService()
    try:
        safe_namespace = validate_namespace(namespace)
        safe_pod = validate_pod_name(pod) if pod else None
    except ObservabilityUnavailableError as exc:
        raise _bad_request(str(exc)) from exc
    if safe_pod:
        return _call_observability(lambda: service.query_logs_by_pod(namespace=safe_namespace, pod=safe_pod, limit=limit))
    return _call_observability(lambda: service.query_logs(namespace=safe_namespace, limit=limit))
