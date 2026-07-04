from fastapi import APIRouter, Depends, status
from sqlalchemy.orm import Session

from app.core.deps import get_current_user, get_db
from app.models.service_definition import ServiceDefinition
from app.models.user import User
from app.schemas.service_definition import (
    ServiceDefinitionCreate,
    ServiceDefinitionRead,
    ServiceDefinitionUpdate,
)
from app.services.service_definition_service import ServiceDefinitionService


router = APIRouter(prefix="/services", tags=["services"])


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
) -> list[ServiceDefinition]:
    return ServiceDefinitionService(db).list_for_user(current_user)


@router.get("/{service_id}", response_model=ServiceDefinitionRead)
def get_service_definition(
    service_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> ServiceDefinition:
    return ServiceDefinitionService(db).get(service_id, current_user)


@router.patch("/{service_id}", response_model=ServiceDefinitionRead)
def update_service_definition(
    service_id: int,
    payload: ServiceDefinitionUpdate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> ServiceDefinition:
    return ServiceDefinitionService(db).update(service_id, payload, current_user)
