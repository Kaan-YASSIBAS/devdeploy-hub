from sqlalchemy.orm import Session, selectinload

from app.models.deployment_record import DeploymentRecord


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

    def list_all(self) -> list[DeploymentRecord]:
        return (
            self.db.query(DeploymentRecord)
            .options(selectinload(DeploymentRecord.service_definition))
            .filter(DeploymentRecord.archived_at.is_(None))
            .order_by(DeploymentRecord.created_at.desc())
            .all()
        )

    def list_for_owner(self, owner_id: int) -> list[DeploymentRecord]:
        return (
            self.db.query(DeploymentRecord)
            .options(selectinload(DeploymentRecord.service_definition))
            .filter(
                DeploymentRecord.owner_id == owner_id,
                DeploymentRecord.archived_at.is_(None),
            )
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
