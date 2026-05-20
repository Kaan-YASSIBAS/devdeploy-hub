from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict


EventLevel = Literal["info", "warning", "error", "success"]


class DeploymentEventRead(BaseModel):
    id: int
    deployment_id: int
    event_type: str
    level: EventLevel
    message: str
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)
