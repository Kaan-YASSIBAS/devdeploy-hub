from fastapi import APIRouter, Depends, status
from sqlalchemy.orm import Session

from app.core.deps import get_current_user, get_db, require_admin
from app.models.deployment import Deployment
from app.models.user import User
from app.schemas.deployment import DeploymentCreate, DeploymentRead, DeploymentStatusUpdate
from app.schemas.gitops_deployment import (
    DeploymentListItem,
    GitOpsDeploymentCreate,
    GitOpsDeploymentDeleteResponse,
    GitOpsDeploymentResponse,
)
from app.services.deployment_service import DeploymentService
from app.services.gitops_deployment_service import GitOpsDeploymentService


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


@router.post("/gitops", response_model=GitOpsDeploymentResponse, status_code=status.HTTP_201_CREATED)
def create_gitops_deployment(
    payload: GitOpsDeploymentCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> GitOpsDeploymentResponse:
    return GitOpsDeploymentService(db).create(payload, current_user)


@router.get("/gitops", response_model=list[DeploymentListItem])
def list_gitops_deployments(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> list[DeploymentListItem]:
    return GitOpsDeploymentService(db).list_deployments(current_user)


@router.get("/gitops/{namespace}/{name}", response_model=DeploymentListItem)
def get_gitops_deployment(
    namespace: str,
    name: str,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> DeploymentListItem:
    return GitOpsDeploymentService(db).get_deployment(namespace, name, current_user)


@router.delete("/gitops/{namespace}/{name}", response_model=GitOpsDeploymentDeleteResponse)
def delete_gitops_deployment(
    namespace: str,
    name: str,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> GitOpsDeploymentDeleteResponse:
    return GitOpsDeploymentService(db).delete(namespace, name, current_user)


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
