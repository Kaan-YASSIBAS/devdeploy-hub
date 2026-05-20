from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

from app.schemas.deployment_event import DeploymentEventRead


Environment = Literal["dev", "staging", "prod"]
DeploymentStatus = Literal["pending", "running", "success", "failed"]
DeploymentStrategy = Literal["rolling", "recreate"]


class DeploymentCreate(BaseModel):
    application_id: int
    environment: Environment
    image_tag: str = Field(min_length=1, max_length=120)
    replica_count: int = Field(ge=1, le=100)
    strategy: DeploymentStrategy = "rolling"


class DeploymentStatusUpdate(BaseModel):
    status: DeploymentStatus
    message: str = Field(min_length=1, max_length=500)


class DeploymentRead(BaseModel):
    id: int
    application_id: int
    environment: Environment
    image_tag: str
    replica_count: int
    strategy: DeploymentStrategy
    status: DeploymentStatus
    requested_by_id: int
    created_at: datetime
    updated_at: datetime | None = None
    events: list[DeploymentEventRead] = Field(default_factory=list)

    model_config = ConfigDict(from_attributes=True)
