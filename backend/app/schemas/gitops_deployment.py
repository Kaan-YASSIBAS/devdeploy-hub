import re
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator


GitOpsDeploymentStatus = Literal["pending", "pending_manual_trigger", "workflow_triggered", "pr_opened", "failed"]
TAG_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
INGRESS_HOST_PATTERN = re.compile(r"^[a-z0-9]([-.a-z0-9]*[a-z0-9])?$")


class GitOpsDeploymentCreate(BaseModel):
    application_id: int | None = None
    app_name: str = Field(min_length=1, max_length=63, pattern=r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")
    image: str = Field(min_length=1, max_length=255)
    tag: str = Field(min_length=1, max_length=128)
    namespace: str = Field(default="devdeploy-workloads", min_length=1, max_length=63, pattern=r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")
    container_port: int = Field(ge=1024, le=65535)
    replicas: int = Field(default=1, ge=1, le=5)
    ingress_host: str | None = Field(default=None, max_length=253)

    @field_validator("image")
    @classmethod
    def validate_image(cls, value: str) -> str:
        if not value.startswith("ghcr.io/"):
            raise ValueError("image must start with ghcr.io/")
        if ":" in value.split("/", 1)[1]:
            raise ValueError("image must not include a tag; use the tag field")
        return value

    @field_validator("tag")
    @classmethod
    def validate_tag(cls, value: str) -> str:
        if value.lower() == "latest":
            raise ValueError("tag cannot be latest")
        if not TAG_PATTERN.fullmatch(value):
            raise ValueError("tag contains unsupported characters")
        return value

    @field_validator("ingress_host")
    @classmethod
    def validate_ingress_host(cls, value: str | None) -> str | None:
        if value == "":
            return None
        if value and not INGRESS_HOST_PATTERN.fullmatch(value):
            raise ValueError("ingress host must be a lowercase DNS host")
        return value


class GitOpsDeploymentRequestRead(BaseModel):
    id: int
    application_id: int | None = None
    app_name: str
    image: str
    tag: str
    namespace: str
    container_port: int
    replicas: int
    ingress_host: str | None = None
    status: GitOpsDeploymentStatus
    workflow_run_url: str | None = None
    pull_request_url: str | None = None
    error_message: str | None = None
    created_by_id: int
    created_at: datetime
    updated_at: datetime | None = None

    model_config = ConfigDict(from_attributes=True)


class GitOpsDeploymentResponse(BaseModel):
    request: GitOpsDeploymentRequestRead
    workflow_triggered: bool
    message: str
    manual_workflow: str | None = None
    manual_inputs: dict[str, str] = Field(default_factory=dict)
