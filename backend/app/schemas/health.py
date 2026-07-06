from typing import Literal

from pydantic import BaseModel, Field


DatabaseMigrationState = Literal["up_to_date", "pending", "unavailable", "error"]


class DatabaseMigrationStatusRead(BaseModel):
    status: DatabaseMigrationState
    current_revisions: list[str] = Field(default_factory=list)
    head_revisions: list[str] = Field(default_factory=list)
    message: str


class BackendReadinessResponse(BaseModel):
    status: Literal["ready", "not_ready"]
    service: Literal["devdeploy-backend"] = "devdeploy-backend"
    database_migrations: DatabaseMigrationStatusRead
