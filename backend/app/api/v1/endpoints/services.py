from fastapi import APIRouter, Depends, status
from sqlalchemy.orm import Session

from app.core.deps import get_current_user, get_db
from app.api.v1.runtime_status import get_product_runtime_status_service
from app.models.service_definition import ServiceDefinition
from app.models.user import User
from app.schemas.service_definition import (
    ServiceDefinitionCreate,
    ServiceDefinitionRead,
    ServiceDefinitionUpdate,
)
from app.schemas.runtime_status import UntrackedServiceListResponse
from app.services.service_definition_service import ServiceDefinitionService
from app.services.product_runtime_status import ProductRuntimeStatusService


router = APIRouter(prefix="/services", tags=["services"])


def _read_response(
    service: ServiceDefinition,
    runtime_service: ProductRuntimeStatusService,
) -> ServiceDefinitionRead:
    response = ServiceDefinitionRead.model_validate(service)
    return response.model_copy(update={"runtime_status": runtime_service.service_status(service)})


@router.post("", response_model=ServiceDefinitionRead, status_code=status.HTTP_201_CREATED)
def create_service_definition(
    payload: ServiceDefinitionCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> ServiceDefinition:
    return ServiceDefinitionService(db).create(payload, current_user)


@router.get("", response_model=list[ServiceDefinitionRead])
def list_service_definitions(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
    runtime_service: ProductRuntimeStatusService = Depends(get_product_runtime_status_service),
) -> list[ServiceDefinitionRead]:
    services = ServiceDefinitionService(db).list_for_user(current_user)
    return [_read_response(service, runtime_service) for service in services]


@router.get("/untracked", response_model=UntrackedServiceListResponse)
def list_untracked_services(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
    runtime_service: ProductRuntimeStatusService = Depends(get_product_runtime_status_service),
) -> UntrackedServiceListResponse:
    owned = ServiceDefinitionService(db).list_owned(current_user)
    return runtime_service.untracked_services({service.name for service in owned})


@router.get("/{service_id}", response_model=ServiceDefinitionRead)
def get_service_definition(
    service_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
    runtime_service: ProductRuntimeStatusService = Depends(get_product_runtime_status_service),
) -> ServiceDefinitionRead:
    service = ServiceDefinitionService(db).get(service_id, current_user)
    return _read_response(service, runtime_service)


@router.patch("/{service_id}", response_model=ServiceDefinitionRead)
def update_service_definition(
    service_id: int,
    payload: ServiceDefinitionUpdate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> ServiceDefinition:
    return ServiceDefinitionService(db).update(service_id, payload, current_user)
