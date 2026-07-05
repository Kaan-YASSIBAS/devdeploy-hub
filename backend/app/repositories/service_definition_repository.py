from sqlalchemy.orm import Query, Session

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
