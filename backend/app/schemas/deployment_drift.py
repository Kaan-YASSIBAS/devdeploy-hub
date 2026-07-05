from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field


DriftComparisonStatus = Literal["aligned", "drifted", "missing", "unknown"]
DeploymentDriftStatus = Literal[
    "aligned",
    "drifted",
    "gitops_missing",
    "runtime_missing",
    "unknown",
]
DriftDifferenceSource = Literal["gitops", "runtime"]
DriftValue = str | int | None


class DriftDifferenceRead(BaseModel):
    field: str
    expected: DriftValue
    actual: DriftValue
    source: DriftDifferenceSource


class DriftComparisonRead(BaseModel):
    status: DriftComparisonStatus
    differences: list[DriftDifferenceRead] = Field(default_factory=list)


class DeploymentDriftStatusRead(BaseModel):
    status: DeploymentDriftStatus
    db_to_gitops: DriftComparisonRead
    db_to_runtime: DriftComparisonRead
    checked_at: datetime
    message: str
