from fastapi import HTTPException, status
from sqlalchemy.orm import Session

from app.models.service_definition import ServiceDefinition, utc_now
from app.models.user import User
from app.repositories.deployment_record_repository import DeploymentRecordRepository
from app.repositories.service_definition_repository import ServiceDefinitionRepository
from app.schemas.archive import ArchiveFilter
from app.schemas.service_definition import ServiceDefinitionCreate, ServiceDefinitionUpdate
from app.schemas.telemetry import HttpTelemetryConfig, telemetry_columns


class ServiceDefinitionService:
    def __init__(self, db: Session):
        self.db = db
        self.services = ServiceDefinitionRepository(db)
        self.deployments = DeploymentRecordRepository(db)

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

    @staticmethod
    def _telemetry_columns_for_service(
        telemetry: HttpTelemetryConfig,
        *,
        default_port: int | None,
    ) -> dict:
        if telemetry.enabled and telemetry.mode == "managed_http_proxy":
            if default_port is None:
                raise HTTPException(
                    status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                    detail="managed_http_proxy requires default_port on the service definition.",
                )
            if telemetry.service_port != default_port:
                raise HTTPException(
                    status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                    detail="telemetry.service_port must match the service definition default_port.",
                )
            runtime_ports = {
                default_port,
                telemetry.application_container_port,
                telemetry.proxy_listener_port,
                telemetry.admin_port,
            }
            if len(runtime_ports) != 4:
                raise HTTPException(
                    status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                    detail=(
                        "default_port, application_container_port, proxy_listener_port, "
                        "and admin_port must be distinct for managed_http_proxy."
                    ),
                )
        return telemetry_columns(telemetry)

    def create(self, payload: ServiceDefinitionCreate, owner: User) -> ServiceDefinition:
        self._ensure_name_available(owner_id=owner.id, name=payload.name)
        data = payload.model_dump(exclude={"telemetry"})
        data.update(
            self._telemetry_columns_for_service(
                payload.telemetry,
                default_port=payload.default_port,
            )
        )
        service = self.services.create(owner_id=owner.id, data=data)
        self.db.commit()
        self.db.refresh(service)
        return service

    def repair_archived_services_linked_to_active_deployments(self, owner_id: int) -> int:
        repaired = 0
        for service in self.services.list_archived_with_active_deployment_links(owner_id):
            service.archived_at = None
            repaired += 1
        if repaired:
            self.db.commit()
        return repaired

    def list_for_user(
        self,
        user: User,
        archive_filter: ArchiveFilter = "active",
    ) -> list[ServiceDefinition]:
        if archive_filter != "archived":
            self.repair_archived_services_linked_to_active_deployments(user.id)
        return self.services.list_for_owner(user.id, archive_filter)

    def list_owned(self, user: User) -> list[ServiceDefinition]:
        self.repair_archived_services_linked_to_active_deployments(user.id)
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
        data = payload.model_dump(exclude_unset=True, exclude={"telemetry"})
        if "telemetry" in payload.model_fields_set and payload.telemetry is not None:
            default_port = data.get("default_port", service.default_port)
            data.update(
                self._telemetry_columns_for_service(
                    payload.telemetry,
                    default_port=default_port,
                )
            )
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

    def archive(self, service_id: int, user: User) -> ServiceDefinition:
        service = self.services.get_by_id(service_id)
        if service is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Service definition not found")
        if service.owner_id != user.id:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Service definition access denied")
        if service.archived_at is None:
            service.archived_at = utc_now()
            self.db.commit()
            self.db.refresh(service)
        return service

    def delete(self, service_id: int, user: User) -> None:
        service = self.services.get_by_id(service_id)
        if service is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Service definition not found")
        if service.owner_id != user.id:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Service definition access denied")
        if self.deployments.count_for_service_definition(service.id):
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="Service definition is still used by deployment records.",
            )
        self.services.delete(service)
        self.db.commit()
