from fastapi import APIRouter, Depends

from app.core.deps import get_current_user
from app.models.user import User
from app.schemas.setup import SetupPreflightResponse
from app.services.preflight_service import PreflightService


router = APIRouter(prefix="/setup", tags=["setup"])


@router.get("/preflight", response_model=SetupPreflightResponse)
def get_setup_preflight(
    current_user: User = Depends(get_current_user),
) -> SetupPreflightResponse:
    _ = current_user
    return PreflightService.run()
