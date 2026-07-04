from fastapi import APIRouter, Depends, status
from sqlalchemy.orm import Session

from app.core.deps import get_current_user, get_db
from app.models.deployment_record import DeploymentRecord
from app.models.user import User
from app.schemas.deployment_record import (
    DeploymentRecordCreate,
    DeploymentRecordRead,
    DeploymentRecordUpdate,
)
from app.services.deployment_record_service import DeploymentRecordService


router = APIRouter(prefix="/deployment-records", tags=["deployment-records"])


@router.post("", response_model=DeploymentRecordRead, status_code=status.HTTP_201_CREATED)
def create_deployment_record(
    payload: DeploymentRecordCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> DeploymentRecord:
    return DeploymentRecordService(db).create(payload, current_user)


@router.get("", response_model=list[DeploymentRecordRead])
def list_deployment_records(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> list[DeploymentRecord]:
    return DeploymentRecordService(db).list_for_user(current_user)


@router.get("/{deployment_id}", response_model=DeploymentRecordRead)
def get_deployment_record(
    deployment_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> DeploymentRecord:
    return DeploymentRecordService(db).get(deployment_id, current_user)


@router.patch("/{deployment_id}", response_model=DeploymentRecordRead)
def update_deployment_record(
    deployment_id: int,
    payload: DeploymentRecordUpdate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> DeploymentRecord:
    return DeploymentRecordService(db).update(deployment_id, payload, current_user)
