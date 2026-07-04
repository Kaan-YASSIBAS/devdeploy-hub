from fastapi import APIRouter, Depends, status
from sqlalchemy.orm import Session

from app.core.deps import get_current_user, get_db
from app.api.v1.runtime_status import get_product_runtime_status_service
from app.models.deployment_record import DeploymentRecord
from app.models.user import User
from app.schemas.deployment_record import (
    DeploymentRecordCreate,
    DeploymentRecordRead,
    DeploymentRecordUpdate,
)
from app.schemas.runtime_status import UntrackedDeploymentListResponse
from app.services.deployment_record_service import DeploymentRecordService
from app.services.product_runtime_status import ProductRuntimeStatusService


router = APIRouter(prefix="/deployment-records", tags=["deployment-records"])


def _read_response(
    deployment: DeploymentRecord,
    runtime_service: ProductRuntimeStatusService,
) -> DeploymentRecordRead:
    response = DeploymentRecordRead.model_validate(deployment)
    return response.model_copy(
        update={"runtime_status": runtime_service.deployment_status(deployment)}
    )


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
    runtime_service: ProductRuntimeStatusService = Depends(get_product_runtime_status_service),
) -> list[DeploymentRecordRead]:
    deployments = DeploymentRecordService(db).list_for_user(current_user)
    return [_read_response(deployment, runtime_service) for deployment in deployments]


@router.get("/untracked", response_model=UntrackedDeploymentListResponse)
def list_untracked_deployments(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
    runtime_service: ProductRuntimeStatusService = Depends(get_product_runtime_status_service),
) -> UntrackedDeploymentListResponse:
    owned = DeploymentRecordService(db).list_owned(current_user)
    return runtime_service.untracked_deployments({deployment.app_name for deployment in owned})


@router.get("/{deployment_id}", response_model=DeploymentRecordRead)
def get_deployment_record(
    deployment_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
    runtime_service: ProductRuntimeStatusService = Depends(get_product_runtime_status_service),
) -> DeploymentRecordRead:
    deployment = DeploymentRecordService(db).get(deployment_id, current_user)
    return _read_response(deployment, runtime_service)


@router.patch("/{deployment_id}", response_model=DeploymentRecordRead)
def update_deployment_record(
    deployment_id: int,
    payload: DeploymentRecordUpdate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> DeploymentRecord:
    return DeploymentRecordService(db).update(deployment_id, payload, current_user)
