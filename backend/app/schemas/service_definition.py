from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


def _clean_name(value: str) -> str:
    cleaned = value.strip()
    if len(cleaned) < 2 or any(ord(character) < 32 or ord(character) == 127 for character in cleaned):
        raise ValueError("name contains unsupported characters")
    return cleaned


def _clean_image(value: str | None) -> str | None:
    if value is None:
        return None
    cleaned = value.strip()
    if not cleaned or any(
        character.isspace() or ord(character) < 32 or ord(character) == 127
        for character in cleaned
    ):
        raise ValueError("default image contains unsupported characters")
    return cleaned


class ServiceDefinitionCreate(BaseModel):
    name: str = Field(min_length=2, max_length=120)
    description: str | None = Field(default=None, max_length=4000)
    default_image: str | None = Field(default=None, max_length=512)
    default_replicas: int = Field(default=1, ge=1, le=20)
    default_port: int | None = Field(default=None, ge=1, le=65535)

    model_config = ConfigDict(extra="forbid")

    @field_validator("name")
    @classmethod
    def validate_name(cls, value: str) -> str:
        return _clean_name(value)

    @field_validator("default_image")
    @classmethod
    def validate_default_image(cls, value: str | None) -> str | None:
        return _clean_image(value)


class ServiceDefinitionUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=2, max_length=120)
    description: str | None = Field(default=None, max_length=4000)
    default_image: str | None = Field(default=None, max_length=512)
    default_replicas: int | None = Field(default=None, ge=1, le=20)
    default_port: int | None = Field(default=None, ge=1, le=65535)

    model_config = ConfigDict(extra="forbid")

    @field_validator("name")
    @classmethod
    def validate_name(cls, value: str | None) -> str | None:
        return _clean_name(value) if value is not None else None

    @field_validator("default_image")
    @classmethod
    def validate_default_image(cls, value: str | None) -> str | None:
        return _clean_image(value)

    @model_validator(mode="after")
    def reject_null_required_fields(self) -> "ServiceDefinitionUpdate":
        for field_name in ("name", "default_replicas"):
            if field_name in self.model_fields_set and getattr(self, field_name) is None:
                raise ValueError(f"{field_name} cannot be null")
        return self


class ServiceDefinitionRead(BaseModel):
    id: int
    owner_id: int
    name: str
    description: str | None = None
    default_image: str | None = None
    default_replicas: int
    default_port: int | None = None
    created_at: datetime
    updated_at: datetime

    model_config = ConfigDict(from_attributes=True)
