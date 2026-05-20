from sqlalchemy import func
from sqlalchemy.orm import Session, selectinload

from app.models.application import Application
from app.models.deployment import Deployment
from app.models.deployment_event import DeploymentEvent


class DeploymentRepository:
    def __init__(self, db: Session):
        self.db = db

    def count(self, *, owner_id: int | None = None, status: str | None = None) -> int:
        query = self.db.query(func.count(Deployment.id))
        if owner_id is not None:
            query = query.join(Application).filter(Application.owner_id == owner_id)
        if status is not None:
            query = query.filter(Deployment.status == status)
        return query.scalar() or 0

    def get_by_id(self, deployment_id: int) -> Deployment | None:
        return (
            self.db.query(Deployment)
            .options(selectinload(Deployment.events), selectinload(Deployment.application))
            .filter(Deployment.id == deployment_id)
            .first()
        )

    def list_all(self) -> list[Deployment]:
        return (
            self.db.query(Deployment)
            .options(selectinload(Deployment.events))
            .order_by(Deployment.created_at.desc())
            .all()
        )

    def list_for_owner(self, owner_id: int) -> list[Deployment]:
        return (
            self.db.query(Deployment)
            .join(Application)
            .options(selectinload(Deployment.events))
            .filter(Application.owner_id == owner_id)
            .order_by(Deployment.created_at.desc())
            .all()
        )

    def create(self, *, requested_by_id: int, data: dict) -> Deployment:
        deployment = Deployment(requested_by_id=requested_by_id, **data)
        self.db.add(deployment)
        self.db.flush()
        return deployment

    def update_status(self, deployment: Deployment, status: str) -> Deployment:
        deployment.status = status
        self.db.flush()
        return deployment

    def create_event(self, *, deployment_id: int, event_type: str, level: str, message: str) -> DeploymentEvent:
        event = DeploymentEvent(
            deployment_id=deployment_id,
            event_type=event_type,
            level=level,
            message=message,
        )
        self.db.add(event)
        self.db.flush()
        return event
