from collections import Counter
from collections.abc import Callable
from typing import Literal

from kubernetes.client import ApiException
from sqlalchemy.orm import Session

from app.models.deployment_record import DeploymentRecord
from app.models.user import User
from app.repositories.deployment_record_repository import DeploymentRecordRepository
from app.repositories.service_definition_repository import ServiceDefinitionRepository
from app.schemas.dashboard import (
    DashboardClusterHealthItem,
    DashboardSummaryResponse,
    DashboardTimelineEvent,
)
from app.schemas.gitops_deployment import DeploymentListItem
from app.schemas.runtime_status import DeploymentRuntimeStatusRead
from app.services.deployment_drift import DeploymentDriftService, UnavailableGitOpsManifestReader
from app.services.kubernetes_service import KubernetesService
from app.services.loki_service import LokiService
from app.services.observability_errors import ObservabilityUnavailableError
from app.services.prometheus_service import PrometheusService
from app.services.product_runtime_status import ProductRuntimeStatusService


ClusterHealthKey = Literal["kubernetes", "argocd", "prometheus", "loki"]


class DashboardService:
    def __init__(
        self,
        db: Session,
        *,
        runtime_service: ProductRuntimeStatusService | None = None,
        drift_service: DeploymentDriftService | None = None,
    ):
        self.db = db
        self.services = ServiceDefinitionRepository(db)
        self.deployments = DeploymentRecordRepository(db)
        self.runtime_service = runtime_service or ProductRuntimeStatusService()
        self.drift_service = drift_service or DeploymentDriftService(
            manifest_reader=UnavailableGitOpsManifestReader(),
            runtime_service=self.runtime_service,
        )

    def summary(self, current_user: User) -> DashboardSummaryResponse:
        services = self.services.list_for_owner(current_user.id, archive_filter="active")
        deployments = self.deployments.list_for_owner(current_user.id, archive_filter="active")
        deployment_items = [self._dashboard_deployment_item(deployment) for deployment in deployments]

        return DashboardSummaryResponse(
            application_count=len(services),
            deployment_count=len(deployments),
            pending_deployment_count=sum(1 for deployment in deployments if self._is_pending(deployment)),
            running_deployment_count=sum(1 for deployment in deployments if self._is_running(deployment)),
            successful_deployment_count=sum(1 for deployment in deployments if self._is_successful(deployment)),
            failed_deployment_count=sum(1 for deployment in deployments if self._is_failed(deployment)),
            environment_distribution=self._environment_distribution(deployment_items),
            recent_deployments=deployment_items[:5],
            deployment_timeline=self._deployment_timeline(deployment_items[:5]),
            cluster_health=self._cluster_health(),
        )

    def _is_pending(self, deployment: DeploymentRecord) -> bool:
        if self._is_failed(deployment) or self._is_running(deployment):
            return False
        runtime = self.runtime_service.deployment_status(deployment)
        if runtime.display_status == "progressing":
            return True
        if runtime.display_status == "not_found" and not self._has_completed_operation(deployment):
            return True
        if runtime.display_status == "unknown" and deployment.desired_state in {"draft", "pending"}:
            return True
        return deployment.desired_state == "draft"

    def _is_running(self, deployment: DeploymentRecord) -> bool:
        return self.runtime_service.deployment_status(deployment).display_status == "running"

    def _is_successful(self, deployment: DeploymentRecord) -> bool:
        return (
            self._is_running(deployment)
            and self._has_completed_operation(deployment)
            and not self._is_failed(deployment)
        )

    def _is_failed(self, deployment: DeploymentRecord) -> bool:
        runtime = self.runtime_service.deployment_status(deployment)
        drift = self.drift_service.evaluate(deployment)
        if drift.status in {"gitops_missing", "runtime_missing"}:
            return True
        if self._has_failed_status_summary(deployment.status_summary):
            return True
        return runtime.display_status == "not_found" and self._has_completed_operation(deployment)

    def _dashboard_deployment_item(self, deployment: DeploymentRecord) -> DeploymentListItem:
        runtime = self.runtime_service.deployment_status(deployment)
        status = self._deployment_list_status(deployment, runtime)
        return DeploymentListItem(
            id=deployment.id,
            name=deployment.app_name,
            app_name=deployment.app_name,
            namespace=deployment.namespace,
            image=deployment.image,
            tag=None,
            environment="cluster",
            replicas=runtime.desired_replicas or deployment.replicas,
            available_replicas=runtime.available_replicas or 0,
            updated_replicas=runtime.updated_replicas or 0,
            status=status,  # type: ignore[arg-type]
            source="gitops" if deployment.gitops_manifest_path or deployment.commit_sha else "legacy",
            is_live=runtime.deployment_found,
            created_at=deployment.created_at,
            updated_at=deployment.updated_at,
        )

    @staticmethod
    def _deployment_list_status(
        deployment: DeploymentRecord,
        runtime: DeploymentRuntimeStatusRead,
    ) -> str:
        if runtime.display_status == "running":
            return "running"
        if runtime.display_status == "progressing":
            return "progressing"
        if runtime.display_status == "not_found":
            return "pending" if deployment.desired_state == "draft" else "failed"
        return "pending" if deployment.desired_state in {"draft", "pending"} else "unknown"

    @staticmethod
    def _has_completed_operation(deployment: DeploymentRecord) -> bool:
        if deployment.commit_sha:
            return True
        summary = (deployment.status_summary or "").lower()
        return "gitops manifests published" in summary or "recovered" in summary

    @staticmethod
    def _has_failed_status_summary(summary: str | None) -> bool:
        value = (summary or "").lower()
        return any(marker in value for marker in ("failed", "conflict", "could not"))

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
                        status="failed" if deployment.status == "failed" else "complete",
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
