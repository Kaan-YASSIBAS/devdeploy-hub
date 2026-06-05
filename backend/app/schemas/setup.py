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
    checks: list[SetupPreflightCheck]
