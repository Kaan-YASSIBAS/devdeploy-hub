from datetime import datetime
from pathlib import Path, PureWindowsPath
import re
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from app.schemas.runtime_status import DeploymentRuntimeStatusRead


APP_NAME_PATTERN = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")
KUBERNETES_NAME_PATTERN = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")
COMMIT_SHA_PATTERN = re.compile(r"^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$")
DesiredState = Literal["draft", "pending"]


def _clean_image(value: str) -> str:
    cleaned = value.strip()
    if not cleaned or any(
        character.isspace() or ord(character) < 32 or ord(character) == 127
        for character in cleaned
    ):
        raise ValueError("image contains unsupported characters")
    return cleaned


def _clean_manifest_path(value: str | None) -> str | None:
    if value is None:
        return None
    if not value or "\\" in value or any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise ValueError("GitOps manifest path is invalid")
    path = Path(value)
    windows_path = PureWindowsPath(value)
    if path.is_absolute() or windows_path.is_absolute() or windows_path.drive:
        raise ValueError("GitOps manifest path must be relative")
    if any(part in {"", ".", ".."} or part.lower() == ".git" for part in path.parts):
        raise ValueError("GitOps manifest path is not allowed")
    return path.as_posix()


class DeploymentRecordCreate(BaseModel):
    service_definition_id: int | None = None
    app_name: str = Field(min_length=1, max_length=40, pattern=APP_NAME_PATTERN.pattern)
    image: str = Field(min_length=1, max_length=512)
    replicas: int = Field(default=1, ge=1, le=20)
    container_port: int = Field(default=80, ge=1, le=65535)
    service_port: int = Field(default=80, ge=1, le=65535)
    service_type: Literal["ClusterIP"] = "ClusterIP"
    namespace: str = Field(default="devdeploy-apps", min_length=1, max_length=63)
    gitops_manifest_path: str | None = Field(default=None, max_length=500)
    commit_sha: str | None = None
    desired_state: DesiredState = "draft"
    status_summary: str | None = Field(default=None, max_length=1000)

    model_config = ConfigDict(extra="forbid")

    @field_validator("image")
    @classmethod
    def validate_image(cls, value: str) -> str:
        return _clean_image(value)

    @field_validator("namespace")
    @classmethod
    def validate_namespace(cls, value: str) -> str:
        if not KUBERNETES_NAME_PATTERN.fullmatch(value):
            raise ValueError("namespace must be a Kubernetes DNS label")
        return value

    @field_validator("gitops_manifest_path")
    @classmethod
    def validate_manifest_path(cls, value: str | None) -> str | None:
        return _clean_manifest_path(value)

    @field_validator("commit_sha")
    @classmethod
    def validate_commit_sha(cls, value: str | None) -> str | None:
        if value is not None and not COMMIT_SHA_PATTERN.fullmatch(value):
            raise ValueError("commit SHA must be a full Git object ID")
        return value.lower() if value else None


class DeploymentRecordUpdate(BaseModel):
    service_definition_id: int | None = None
    app_name: str | None = Field(default=None, min_length=1, max_length=40, pattern=APP_NAME_PATTERN.pattern)
    image: str | None = Field(default=None, min_length=1, max_length=512)
    replicas: int | None = Field(default=None, ge=1, le=20)
    container_port: int | None = Field(default=None, ge=1, le=65535)
    service_port: int | None = Field(default=None, ge=1, le=65535)
    service_type: Literal["ClusterIP"] | None = None
    namespace: str | None = Field(default=None, min_length=1, max_length=63)
    gitops_manifest_path: str | None = Field(default=None, max_length=500)
    commit_sha: str | None = None
    desired_state: DesiredState | None = None
    status_summary: str | None = Field(default=None, max_length=1000)

    model_config = ConfigDict(extra="forbid")

    @field_validator("image")
    @classmethod
    def validate_image(cls, value: str | None) -> str | None:
        return _clean_image(value) if value is not None else None

    @field_validator("namespace")
    @classmethod
    def validate_namespace(cls, value: str | None) -> str | None:
        if value is not None and not KUBERNETES_NAME_PATTERN.fullmatch(value):
            raise ValueError("namespace must be a Kubernetes DNS label")
        return value

    @field_validator("gitops_manifest_path")
    @classmethod
    def validate_manifest_path(cls, value: str | None) -> str | None:
        return _clean_manifest_path(value)

    @field_validator("commit_sha")
    @classmethod
    def validate_commit_sha(cls, value: str | None) -> str | None:
        if value is not None and not COMMIT_SHA_PATTERN.fullmatch(value):
            raise ValueError("commit SHA must be a full Git object ID")
        return value.lower() if value else None

    @model_validator(mode="after")
    def reject_null_required_fields(self) -> "DeploymentRecordUpdate":
        for field_name in (
            "app_name",
            "image",
            "replicas",
            "container_port",
            "service_port",
            "service_type",
            "namespace",
            "desired_state",
        ):
            if field_name in self.model_fields_set and getattr(self, field_name) is None:
                raise ValueError(f"{field_name} cannot be null")
        return self


class DeploymentRecordRead(BaseModel):
    id: int
    owner_id: int
    service_definition_id: int | None = None
    app_name: str
    image: str
    replicas: int
    container_port: int
    service_port: int
    service_type: Literal["ClusterIP"]
    namespace: str
    gitops_manifest_path: str | None = None
    commit_sha: str | None = None
    desired_state: DesiredState
    status_summary: str | None = None
    created_at: datetime
    updated_at: datetime
    runtime_status: DeploymentRuntimeStatusRead | None = None

    model_config = ConfigDict(from_attributes=True)
