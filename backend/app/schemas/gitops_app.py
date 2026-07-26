from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

from app.schemas.preview_path import normalize_preview_path


class GitOpsAppCreateRequest(BaseModel):
    app_name: str = Field(
        min_length=1,
        max_length=40,
        pattern=r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$",
    )
    image: str = Field(min_length=1, max_length=512)
    replicas: int = Field(default=1, ge=1, le=20)
    container_port: int = Field(default=80, ge=1, le=65535)
    service_port: int = Field(default=80, ge=1, le=65535)
    service_type: Literal["ClusterIP"] = "ClusterIP"
    preview_path: str = Field(default="/", max_length=2048)

    model_config = ConfigDict(extra="forbid")

    @field_validator("image")
    @classmethod
    def validate_image(cls, value: str) -> str:
        if any(character.isspace() or ord(character) < 32 or ord(character) == 127 for character in value):
            raise ValueError("image contains unsupported characters")
        return value

    @field_validator("preview_path")
    @classmethod
    def validate_preview_path(cls, value: str | None) -> str:
        return normalize_preview_path(value)


class GitOpsAppCreateResponse(BaseModel):
    status: str
    app_name: str
    namespace: str
    source_path: str
    commit_sha: str | None = None
    message: str
    error_code: str | None = None


class GitOpsDiscoveredAppResponse(BaseModel):
    app_name: str
    image: str
    replicas: int
    container_port: int
    service_port: int
    service_type: Literal["ClusterIP"]
    namespace: str
    manifest_path: str
    status: Literal["unknown"]


class GitOpsAppListResponse(BaseModel):
    items: list[GitOpsDiscoveredAppResponse]


GitOpsAppStatusValue = Literal[
    "pushed_waiting_for_argocd",
    "argocd_observing",
    "argocd_synced",
    "workload_progressing",
    "deployed",
    "degraded",
    "unknown",
]


class GitOpsRootApplicationStatusResponse(BaseModel):
    name: str
    sync_status: str | None = None
    health_status: str | None = None
    observed_commit_match: bool


class GitOpsWorkloadStatusResponse(BaseModel):
    deployment_ready: bool
    service_ready: bool
    pods_ready: bool
    desired_replicas: int | None = None
    ready_replicas: int | None = None
    available_replicas: int | None = None
    pod_count: int
    ready_pod_count: int


class GitOpsAppStatusResponse(BaseModel):
    status: GitOpsAppStatusValue
    app_name: str
    namespace: str
    commit_sha: str
    observed_revision: str | None = None
    root_application: GitOpsRootApplicationStatusResponse
    workload: GitOpsWorkloadStatusResponse
    message: str
    error_code: str | None = None
