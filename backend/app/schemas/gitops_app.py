from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator


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

    model_config = ConfigDict(extra="forbid")

    @field_validator("image")
    @classmethod
    def validate_image(cls, value: str) -> str:
        if any(character.isspace() or ord(character) < 32 or ord(character) == 127 for character in value):
            raise ValueError("image contains unsupported characters")
        return value


class GitOpsAppCreateResponse(BaseModel):
    status: str
    app_name: str
    namespace: str
    source_path: str
    commit_sha: str | None = None
    message: str
    error_code: str | None = None
