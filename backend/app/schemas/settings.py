from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, EmailStr, Field


IntegrationStatus = Literal[
    "connected",
    "degraded",
    "not_configured",
    "unavailable",
    "error",
    "optional",
]


class ProfileSettingsResponse(BaseModel):
    id: int
    display_name: str
    email: EmailStr
    role: Literal["admin", "developer"]


class ProfileSettingsUpdate(BaseModel):
    display_name: str = Field(min_length=1, max_length=120)


class WorkspaceSettingsResponse(BaseModel):
    id: int
    name: str
    plan: str
    created_at: datetime
    updated_at: datetime | None = None

    model_config = ConfigDict(from_attributes=True)


class WorkspaceSettingsUpdate(BaseModel):
    name: str = Field(min_length=1, max_length=160)


class ApiTokenResponse(BaseModel):
    id: int
    name: str
    prefix: str
    last_four: str
    created_at: datetime
    last_used_at: datetime | None = None
    revoked_at: datetime | None = None
    active: bool


class ApiTokenCreateRequest(BaseModel):
    name: str = Field(min_length=1, max_length=120)


class ApiTokenCreateResponse(BaseModel):
    token: str
    item: ApiTokenResponse


class IntegrationStatusResponse(BaseModel):
    key: Literal["github", "argocd", "kubernetes", "prometheus", "loki", "grafana"]
    name: str
    status: IntegrationStatus
    detail: str | None = None


class SettingsSummaryResponse(BaseModel):
    profile: ProfileSettingsResponse
    workspace: WorkspaceSettingsResponse
    api_tokens: list[ApiTokenResponse]
    integrations: list[IntegrationStatusResponse]
