from fastapi import HTTPException, status
from sqlalchemy.orm import Session

from app.models.service_definition import ServiceDefinition
from app.models.user import User
from app.repositories.service_definition_repository import ServiceDefinitionRepository
from app.schemas.service_definition import ServiceDefinitionCreate, ServiceDefinitionUpdate


class ServiceDefinitionService:
    def __init__(self, db: Session):
        self.db = db
        self.services = ServiceDefinitionRepository(db)

    @staticmethod
    def _ensure_access(service: ServiceDefinition | None, user: User) -> ServiceDefinition:
        if service is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Service definition not found")
        if user.role != "admin" and service.owner_id != user.id:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Service definition access denied")
        return service

    def _ensure_name_available(
        self,
        *,
        owner_id: int,
        name: str,
        current_service_id: int | None = None,
    ) -> None:
        existing = self.services.get_by_owner_and_name(owner_id, name)
        if existing is not None and existing.id != current_service_id:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="A service definition with this name already exists.",
            )

    def create(self, payload: ServiceDefinitionCreate, owner: User) -> ServiceDefinition:
        self._ensure_name_available(owner_id=owner.id, name=payload.name)
        service = self.services.create(owner_id=owner.id, data=payload.model_dump())
        self.db.commit()
        self.db.refresh(service)
        return service

    def list_for_user(self, user: User) -> list[ServiceDefinition]:
        if user.role == "admin":
            return self.services.list_all()
        return self.services.list_for_owner(user.id)

    def list_owned(self, user: User) -> list[ServiceDefinition]:
        return self.services.list_for_owner(user.id)

    def get(self, service_id: int, user: User) -> ServiceDefinition:
        return self._ensure_access(self.services.get_by_id(service_id), user)

    def update(
        self,
        service_id: int,
        payload: ServiceDefinitionUpdate,
        user: User,
    ) -> ServiceDefinition:
        service = self.get(service_id, user)
        data = payload.model_dump(exclude_unset=True)
        if "name" in data:
            self._ensure_name_available(
                owner_id=service.owner_id,
                name=data["name"],
                current_service_id=service.id,
            )
        updated = self.services.update(service, data)
        self.db.commit()
        self.db.refresh(updated)
        return updated
