from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field


PlatformClusterRole = Literal["management", "workload"]
PlatformClusterStatus = Literal["healthy", "degraded", "unreachable", "unknown"]
PlatformClusterHealthReason = Literal[
    "ok",
    "kubeconfig_unreachable",
    "api_unreachable",
    "api_port_unpublished",
    "unknown",
]


class PlatformClusterHealthItem(BaseModel):
    cluster_name: str
    context: str
    role: PlatformClusterRole
    status: PlatformClusterStatus
    api_reachable: bool
    reason: PlatformClusterHealthReason
    message: str
    recommended_action: str | None = None
    impact: list[str] = Field(default_factory=list)
    recovery_steps: list[str] = Field(default_factory=list)
    checked_at: datetime


class PlatformClusterHealthResponse(BaseModel):
    management: PlatformClusterHealthItem
    workload: PlatformClusterHealthItem
    platform_ready: bool
