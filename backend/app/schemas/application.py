from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, HttpUrl


Environment = Literal["dev", "staging", "prod"]


class ApplicationCreate(BaseModel):
    name: str = Field(min_length=2, max_length=120)
    description: str | None = Field(default=None, max_length=4000)
    repository_url: HttpUrl | None = None
    image_name: str = Field(min_length=1, max_length=255)
    container_port: int = Field(ge=1, le=65535)
    default_environment: Environment = "dev"


class ApplicationUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=2, max_length=120)
    description: str | None = Field(default=None, max_length=4000)
    repository_url: HttpUrl | None = None
    image_name: str | None = Field(default=None, min_length=1, max_length=255)
    container_port: int | None = Field(default=None, ge=1, le=65535)
    default_environment: Environment | None = None


class ApplicationRead(BaseModel):
    id: int
    name: str
    slug: str
    description: str | None = None
    repository_url: str | None = None
    image_name: str
    container_port: int
    default_environment: Environment
    owner_id: int
    created_at: datetime
    updated_at: datetime | None = None

    model_config = ConfigDict(from_attributes=True)
