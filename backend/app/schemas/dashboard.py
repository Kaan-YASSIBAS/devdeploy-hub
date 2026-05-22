from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field

from app.schemas.gitops_deployment import DeploymentListItem


ClusterHealthStatus = Literal["healthy", "degraded", "unavailable", "not_configured"]
TimelineEventStatus = Literal["complete", "current", "pending", "failed"]


class EnvironmentDistributionItem(BaseModel):
    environment: str
    count: int


class DashboardTimelineEvent(BaseModel):
    id: str
    deployment_name: str
    namespace: str
    event_type: str
    message: str
    status: TimelineEventStatus
    timestamp: datetime


class DashboardClusterHealthItem(BaseModel):
    key: Literal["kubernetes", "argocd", "prometheus", "loki"]
    name: str
    status: ClusterHealthStatus
    detail: str | None = None


class DashboardSummaryResponse(BaseModel):
    application_count: int
    deployment_count: int
    pending_deployment_count: int
    running_deployment_count: int
    successful_deployment_count: int
    failed_deployment_count: int
    environment_distribution: list[EnvironmentDistributionItem] = Field(default_factory=list)
    recent_deployments: list[DeploymentListItem] = Field(default_factory=list)
    deployment_timeline: list[DashboardTimelineEvent] = Field(default_factory=list)
    cluster_health: list[DashboardClusterHealthItem] = Field(default_factory=list)
