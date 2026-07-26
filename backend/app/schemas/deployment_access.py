from typing import Literal

from pydantic import BaseModel, Field


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
    preview_url: str | None = Field(
        default=None,
        pattern=r"^/api/v1/deployment-records/[1-9][0-9]*/preview/(?:[A-Za-z0-9._~!$&'()*+,;=:@%-]+(?:/[A-Za-z0-9._~!$&'()*+,;=:@%-]+)*/?)?$",
    )
    service: DeploymentAccessServiceRead | None = None
