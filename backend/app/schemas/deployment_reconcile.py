from datetime import datetime
from typing import Literal

from pydantic import BaseModel


DeploymentReconcileState = Literal[
    "synced",
    "progressing",
    "degraded",
    "drifted",
    "unknown",
]


class DeploymentReconcileStatusRead(BaseModel):
    status: DeploymentReconcileState
    observed_revision: str | None = None
    sync_status: str | None = None
    health_status: str | None = None
    commit_observed: bool = False
    checked_at: datetime
    message: str
