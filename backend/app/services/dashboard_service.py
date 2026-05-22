from collections import Counter
from collections.abc import Callable
from typing import Literal

from kubernetes.client import ApiException
from sqlalchemy.orm import Session

from app.models.user import User
from app.repositories.application_repository import ApplicationRepository
from app.schemas.dashboard import (
    DashboardClusterHealthItem,
    DashboardSummaryResponse,
    DashboardTimelineEvent,
)
from app.schemas.gitops_deployment import DeploymentListItem
from app.services.gitops_deployment_service import GitOpsDeploymentService
from app.services.kubernetes_service import KubernetesService
from app.services.loki_service import LokiService
from app.services.observability_errors import ObservabilityUnavailableError
from app.services.prometheus_service import PrometheusService


ClusterHealthKey = Literal["kubernetes", "argocd", "prometheus", "loki"]


class DashboardService:
    def __init__(self, db: Session):
        self.db = db
        self.applications = ApplicationRepository(db)

    def summary(self, current_user: User) -> DashboardSummaryResponse:
        application_count = self.applications.count(
            owner_id=None if current_user.role == "admin" else current_user.id
        )
        deployments = self._dashboard_deployments(self._list_deployments(current_user))

        return DashboardSummaryResponse(
            application_count=application_count,
            deployment_count=len(deployments),
            pending_deployment_count=self._count_status(deployments, {"pending", "progressing"}),
            running_deployment_count=self._count_status(deployments, {"running"}),
            successful_deployment_count=self._count_status(deployments, {"success"}),
            failed_deployment_count=self._count_status(deployments, {"failed"}),
            environment_distribution=self._environment_distribution(deployments),
            recent_deployments=deployments[:5],
            deployment_timeline=self._deployment_timeline(deployments[:5]),
            cluster_health=self._cluster_health(),
        )

    def _list_deployments(self, current_user: User) -> list[DeploymentListItem]:
        try:
            return GitOpsDeploymentService(self.db).list_deployments(current_user)
        except (ObservabilityUnavailableError, ApiException):
            return self._legacy_deployments_only(current_user)

    def _legacy_deployments_only(self, current_user: User) -> list[DeploymentListItem]:
        service = GitOpsDeploymentService(self.db)
        legacy_deployments = (
            service.deployments.list_all()
            if current_user.role == "admin"
            else service.deployments.list_for_owner(current_user.id)
        )
        items = [service._from_legacy_deployment(deployment) for deployment in legacy_deployments]
        return sorted(items, key=service._sort_timestamp, reverse=True)

    @staticmethod
    def _dashboard_deployments(deployments: list[DeploymentListItem]) -> list[DeploymentListItem]:
        return [
            deployment
            for deployment in deployments
            if DashboardService._is_dashboard_deployment(deployment)
        ]

    @staticmethod
    def _is_dashboard_deployment(deployment: DeploymentListItem) -> bool:
        if deployment.status == "stale":
            return False
        if deployment.source == "gitops" and not deployment.is_live and deployment.status == "failed":
            return False
        return True

    @staticmethod
    def _count_status(deployments: list[DeploymentListItem], statuses: set[str]) -> int:
        return sum(1 for deployment in deployments if deployment.status in statuses)

    @staticmethod
    def _environment_distribution(deployments: list[DeploymentListItem]) -> list[dict[str, int | str]]:
        counts = Counter(deployment.environment or "cluster" for deployment in deployments)
        return [
            {"environment": environment, "count": count}
            for environment, count in sorted(counts.items())
            if count > 0
        ]

    @staticmethod
    def _deployment_timeline(deployments: list[DeploymentListItem]) -> list[DashboardTimelineEvent]:
        events: list[DashboardTimelineEvent] = []
        for deployment in deployments:
            created_at = deployment.created_at
            updated_at = deployment.updated_at
            if created_at is not None:
                events.append(
                    DashboardTimelineEvent(
                        id=f"{deployment.namespace}/{deployment.name}/created",
                        deployment_name=deployment.name,
                        namespace=deployment.namespace,
                        event_type="request_created" if deployment.source == "gitops" else "deployment_created",
                        message=(
                            "GitOps deployment request was created."
                            if deployment.source == "gitops"
                            else "Kubernetes deployment was observed."
                        ),
                        status="complete",
                        timestamp=created_at,
                    )
                )
            if updated_at is not None and updated_at != created_at:
                events.append(
                    DashboardTimelineEvent(
                        id=f"{deployment.namespace}/{deployment.name}/updated",
                        deployment_name=deployment.name,
                        namespace=deployment.namespace,
                        event_type="deployment_updated",
                        message="Kubernetes deployment status was updated.",
                        status="failed" if deployment.status == "failed" else "current",
                        timestamp=updated_at,
                    )
                )
            if deployment.status == "running" and updated_at is not None:
                events.append(
                    DashboardTimelineEvent(
                        id=f"{deployment.namespace}/{deployment.name}/healthy",
                        deployment_name=deployment.name,
                        namespace=deployment.namespace,
                        event_type="deployment_healthy",
                        message="Deployment has the requested available replicas.",
                        status="complete",
                        timestamp=updated_at,
                    )
                )
        return sorted(events, key=lambda event: event.timestamp, reverse=True)[:8]

    def _cluster_health(self) -> list[DashboardClusterHealthItem]:
        return [
            self._safe_health("kubernetes", "Kubernetes", self._kubernetes_health),
            self._safe_health("argocd", "Argo CD", self._argocd_health),
            self._safe_health("prometheus", "Prometheus", self._prometheus_health),
            self._safe_health("loki", "Loki", self._loki_health),
        ]

    @staticmethod
    def _safe_health(
        key: ClusterHealthKey,
        name: str,
        check: Callable[[], DashboardClusterHealthItem],
    ) -> DashboardClusterHealthItem:
        try:
            return check()
        except Exception as exc:
            return DashboardClusterHealthItem(
                key=key,
                name=name,
                status="unavailable",
                detail=f"{name} health check failed: {exc.__class__.__name__}",
            )

    @staticmethod
    def _kubernetes_health() -> DashboardClusterHealthItem:
        try:
            KubernetesService().check_health()
        except ObservabilityUnavailableError as exc:
            return DashboardClusterHealthItem(
                key="kubernetes",
                name="Kubernetes",
                status="not_configured",
                detail=str(exc),
            )
        except ApiException as exc:
            return DashboardClusterHealthItem(
                key="kubernetes",
                name="Kubernetes",
                status="unavailable",
                detail=f"Kubernetes API request failed: {exc.reason or exc.status}",
            )
        return DashboardClusterHealthItem(
            key="kubernetes",
            name="Kubernetes",
            status="healthy",
            detail="Kubernetes API is reachable.",
        )

    @staticmethod
    def _argocd_health() -> DashboardClusterHealthItem:
        service = KubernetesService()
        try:
            if not service.namespace_exists("argocd"):
                return DashboardClusterHealthItem(
                    key="argocd",
                    name="Argo CD",
                    status="not_configured",
                    detail="The argocd namespace was not found.",
                )
            if not service.argocd_application_exists("devdeploy-hub-release"):
                return DashboardClusterHealthItem(
                    key="argocd",
                    name="Argo CD",
                    status="degraded",
                    detail="The devdeploy-hub-release Application was not found.",
                )
        except ObservabilityUnavailableError as exc:
            return DashboardClusterHealthItem(
                key="argocd",
                name="Argo CD",
                status="not_configured",
                detail=str(exc),
            )
        except ApiException as exc:
            return DashboardClusterHealthItem(
                key="argocd",
                name="Argo CD",
                status="unavailable",
                detail=f"Argo CD Application check failed: {exc.reason or exc.status}",
            )
        return DashboardClusterHealthItem(
            key="argocd",
            name="Argo CD",
            status="healthy",
            detail="The release Application is visible.",
        )

    @staticmethod
    def _prometheus_health() -> DashboardClusterHealthItem:
        try:
            PrometheusService().check_health()
        except ObservabilityUnavailableError as exc:
            return DashboardClusterHealthItem(
                key="prometheus",
                name="Prometheus",
                status="not_configured",
                detail=str(exc),
            )
        return DashboardClusterHealthItem(
            key="prometheus",
            name="Prometheus",
            status="healthy",
            detail="Prometheus API is reachable.",
        )

    @staticmethod
    def _loki_health() -> DashboardClusterHealthItem:
        try:
            LokiService().check_health()
        except ObservabilityUnavailableError as exc:
            return DashboardClusterHealthItem(
                key="loki",
                name="Loki",
                status="not_configured",
                detail=str(exc),
            )
        return DashboardClusterHealthItem(
            key="loki",
            name="Loki",
            status="healthy",
            detail="Loki API is reachable.",
        )
