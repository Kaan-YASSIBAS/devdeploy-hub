from typing import Literal

from pydantic import BaseModel


DeploymentAccessStatus = Literal[
    "available",
    "not_ready",
    "service_missing",
    "runtime_unavailable",
    "unsupported",
    "unknown",
]


class DeploymentAccessServiceRead(BaseModel):
    name: str
    namespace: str
    port: int | None = None
    service_type: str | None = None


class DeploymentAccessRead(BaseModel):
    available: bool
    status: DeploymentAccessStatus
    app_name: str
    message: str
    preview_url: None = None
    service: DeploymentAccessServiceRead | None = None
