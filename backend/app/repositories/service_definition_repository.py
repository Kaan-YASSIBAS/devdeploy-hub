from sqlalchemy import exists, or_
from sqlalchemy.orm import Query, Session, aliased

from app.models.deployment_record import DeploymentRecord
from app.models.service_definition import ServiceDefinition
from app.schemas.archive import ArchiveFilter


class ServiceDefinitionRepository:
    def __init__(self, db: Session):
        self.db = db

    def get_by_id(self, service_id: int) -> ServiceDefinition | None:
        return self.db.query(ServiceDefinition).filter(ServiceDefinition.id == service_id).first()

    def get_by_owner_and_name(self, owner_id: int, name: str) -> ServiceDefinition | None:
        return (
            self.db.query(ServiceDefinition)
            .filter(ServiceDefinition.owner_id == owner_id, ServiceDefinition.name == name)
            .first()
        )

    def list_archived_with_active_deployment_links(self, owner_id: int) -> list[ServiceDefinition]:
        return (
            self.db.query(ServiceDefinition)
            .join(
                DeploymentRecord,
                DeploymentRecord.service_definition_id == ServiceDefinition.id,
            )
            .filter(
                ServiceDefinition.owner_id == owner_id,
                ServiceDefinition.archived_at.is_not(None),
                DeploymentRecord.owner_id == owner_id,
                DeploymentRecord.archived_at.is_(None),
                DeploymentRecord.desired_state != "destroyed",
            )
            .distinct()
            .all()
        )

    def list_active_with_only_inactive_deployment_links(self, owner_id: int) -> list[ServiceDefinition]:
        active_deployment = aliased(DeploymentRecord)
        active_link_exists = exists().where(
            active_deployment.service_definition_id == ServiceDefinition.id,
            active_deployment.owner_id == owner_id,
            active_deployment.archived_at.is_(None),
            active_deployment.desired_state != "destroyed",
        )
        return (
            self.db.query(ServiceDefinition)
            .join(
                DeploymentRecord,
                DeploymentRecord.service_definition_id == ServiceDefinition.id,
            )
            .filter(
                ServiceDefinition.owner_id == owner_id,
                ServiceDefinition.archived_at.is_(None),
                DeploymentRecord.owner_id == owner_id,
                or_(
                    DeploymentRecord.archived_at.is_not(None),
                    DeploymentRecord.desired_state == "destroyed",
                ),
                ~active_link_exists,
            )
            .distinct()
            .all()
        )

    @staticmethod
    def _apply_archive_filter(query: Query, archive_filter: ArchiveFilter) -> Query:
        if archive_filter == "active":
            return query.filter(ServiceDefinition.archived_at.is_(None))
        if archive_filter == "archived":
            return query.filter(ServiceDefinition.archived_at.is_not(None))
        if archive_filter == "all":
            return query
        raise ValueError("Unsupported archive filter")

    def list_all(self, archive_filter: ArchiveFilter = "active") -> list[ServiceDefinition]:
        return (
            self._apply_archive_filter(self.db.query(ServiceDefinition), archive_filter)
            .order_by(ServiceDefinition.created_at.desc())
            .all()
        )

    def list_for_owner(
        self,
        owner_id: int,
        archive_filter: ArchiveFilter = "active",
    ) -> list[ServiceDefinition]:
        query = self.db.query(ServiceDefinition).filter(ServiceDefinition.owner_id == owner_id)
        return (
            self._apply_archive_filter(query, archive_filter)
            .order_by(ServiceDefinition.created_at.desc())
            .all()
        )

    def create(self, *, owner_id: int, data: dict) -> ServiceDefinition:
        service = ServiceDefinition(owner_id=owner_id, **data)
        self.db.add(service)
        self.db.flush()
        return service

    def update(self, service: ServiceDefinition, data: dict) -> ServiceDefinition:
        for key, value in data.items():
            setattr(service, key, value)
        self.db.flush()
        return service

    def delete(self, service: ServiceDefinition) -> None:
        self.db.delete(service)
        self.db.flush()
