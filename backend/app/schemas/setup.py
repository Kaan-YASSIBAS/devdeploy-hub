from typing import Literal

from pydantic import BaseModel


PreflightCheckStatus = Literal["ok", "warning", "failed"]
PreflightOverallStatus = Literal["ready", "warnings", "blocked"]
PreflightRuntimeMode = Literal["host", "kubernetes", "unknown"]


class SetupPreflightCheck(BaseModel):
    id: str
    label: str
    status: PreflightCheckStatus
    message: str
    details: str | None = None


class SetupPreflightResponse(BaseModel):
    runtime_mode: PreflightRuntimeMode
    runtime_message: str
    overall_status: PreflightOverallStatus
    required_contexts: list[str]
    detected_contexts: list[str]
    required_clusters: list[str]
    detected_clusters: list[str]
    contexts_ready: bool
    clusters_ready: bool
    platform_ready: bool
    checks: list[SetupPreflightCheck]
