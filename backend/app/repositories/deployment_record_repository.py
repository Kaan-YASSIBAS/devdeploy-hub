from sqlalchemy.orm import Query, Session, selectinload

from app.models.deployment_record import DeploymentRecord
from app.schemas.archive import ArchiveFilter


class DeploymentRecordRepository:
    def __init__(self, db: Session):
        self.db = db

    def get_by_id(self, deployment_id: int) -> DeploymentRecord | None:
        return (
            self.db.query(DeploymentRecord)
            .options(selectinload(DeploymentRecord.service_definition))
            .filter(DeploymentRecord.id == deployment_id)
            .first()
        )

    @staticmethod
    def _apply_archive_filter(query: Query, archive_filter: ArchiveFilter) -> Query:
        if archive_filter == "active":
            return query.filter(DeploymentRecord.archived_at.is_(None))
        if archive_filter == "archived":
            return query.filter(DeploymentRecord.archived_at.is_not(None))
        if archive_filter == "all":
            return query
        raise ValueError("Unsupported archive filter")

    def list_all(self, archive_filter: ArchiveFilter = "active") -> list[DeploymentRecord]:
        query = (
            self.db.query(DeploymentRecord)
            .options(selectinload(DeploymentRecord.service_definition))
        )
        return (
            self._apply_archive_filter(query, archive_filter)
            .order_by(DeploymentRecord.created_at.desc())
            .all()
        )

    def list_for_owner(
        self,
        owner_id: int,
        archive_filter: ArchiveFilter = "active",
    ) -> list[DeploymentRecord]:
        query = (
            self.db.query(DeploymentRecord)
            .options(selectinload(DeploymentRecord.service_definition))
            .filter(DeploymentRecord.owner_id == owner_id)
        )
        return (
            self._apply_archive_filter(query, archive_filter)
            .order_by(DeploymentRecord.created_at.desc())
            .all()
        )

    def create(self, *, owner_id: int, data: dict) -> DeploymentRecord:
        deployment = DeploymentRecord(owner_id=owner_id, **data)
        self.db.add(deployment)
        self.db.flush()
        return deployment

    def update(self, deployment: DeploymentRecord, data: dict) -> DeploymentRecord:
        for key, value in data.items():
            setattr(deployment, key, value)
        self.db.flush()
        return deployment

    def count_for_service_definition(self, service_definition_id: int) -> int:
        return (
            self.db.query(DeploymentRecord)
            .filter(DeploymentRecord.service_definition_id == service_definition_id)
            .count()
        )

    def count_active_non_destroyed_for_service_definition(self, service_definition_id: int) -> int:
        return (
            self.db.query(DeploymentRecord)
            .filter(
                DeploymentRecord.service_definition_id == service_definition_id,
                DeploymentRecord.archived_at.is_(None),
                DeploymentRecord.desired_state != "destroyed",
            )
            .count()
        )

    def delete(self, deployment: DeploymentRecord) -> None:
        self.db.delete(deployment)
        self.db.flush()
