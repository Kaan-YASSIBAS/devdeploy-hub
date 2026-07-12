from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.api.v1.runtime_status import get_deployment_drift_service, get_product_runtime_status_service
from app.core.deps import get_current_user, get_db
from app.models.user import User
from app.schemas.dashboard import DashboardSummaryResponse
from app.services.dashboard_service import DashboardService
from app.services.deployment_drift import DeploymentDriftService
from app.services.product_runtime_status import ProductRuntimeStatusService


router = APIRouter(prefix="/dashboard", tags=["dashboard"])


@router.get("/summary", response_model=DashboardSummaryResponse)
def get_dashboard_summary(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    runtime_service: ProductRuntimeStatusService = Depends(get_product_runtime_status_service),
    drift_service: DeploymentDriftService = Depends(get_deployment_drift_service),
) -> DashboardSummaryResponse:
    return DashboardService(
        db,
        runtime_service=runtime_service,
        drift_service=drift_service,
    ).summary(current_user)
