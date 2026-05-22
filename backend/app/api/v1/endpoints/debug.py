from fastapi import APIRouter, HTTPException, status

from app.core.config import settings


router = APIRouter(prefix="/debug", tags=["debug"])


@router.get("/error")
def trigger_debug_error() -> None:
    if settings.environment != "development":
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Not found")
    raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="Development metrics test error")
