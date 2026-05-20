from fastapi import APIRouter, Depends, status
from sqlalchemy.orm import Session

from app.core.deps import get_current_user, get_db, require_admin
from app.models.deployment import Deployment
from app.models.user import User
from app.schemas.deployment import DeploymentCreate, DeploymentRead, DeploymentStatusUpdate
from app.services.deployment_service import DeploymentService


router = APIRouter(prefix="/deployments", tags=["deployments"])


@router.post("", response_model=DeploymentRead, status_code=status.HTTP_201_CREATED)
def create_deployment(
    payload: DeploymentCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> Deployment:
    return DeploymentService(db).create(payload, current_user)


@router.get("", response_model=list[DeploymentRead])
def list_deployments(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> list[Deployment]:
    return DeploymentService(db).list_for_user(current_user)


@router.get("/{deployment_id}", response_model=DeploymentRead)
def get_deployment(
    deployment_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> Deployment:
    return DeploymentService(db).get(deployment_id, current_user)


@router.patch("/{deployment_id}/status", response_model=DeploymentRead)
def update_deployment_status(
    deployment_id: int,
    payload: DeploymentStatusUpdate,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_admin),
) -> Deployment:
    return DeploymentService(db).update_status(deployment_id, payload, current_user)
