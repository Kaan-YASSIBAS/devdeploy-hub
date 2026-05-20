from fastapi import HTTPException, status
from sqlalchemy.orm import Session

from app.models.deployment import Deployment
from app.models.user import User
from app.repositories.application_repository import ApplicationRepository
from app.repositories.deployment_repository import DeploymentRepository
from app.schemas.deployment import DeploymentCreate, DeploymentStatusUpdate


class DeploymentService:
    def __init__(self, db: Session):
        self.db = db
        self.applications = ApplicationRepository(db)
        self.deployments = DeploymentRepository(db)

    def _ensure_access(self, deployment: Deployment | None, user: User) -> Deployment:
        if deployment is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Deployment not found")
        if user.role != "admin" and deployment.application.owner_id != user.id:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Deployment access denied")
        return deployment

    def create(self, payload: DeploymentCreate, requested_by: User) -> Deployment:
        application = self.applications.get_by_id(payload.application_id)
        if application is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Application not found")
        if requested_by.role != "admin" and application.owner_id != requested_by.id:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Application access denied")

        deployment = self.deployments.create(
            requested_by_id=requested_by.id,
            data=payload.model_dump(),
        )
        self.deployments.create_event(
            deployment_id=deployment.id,
            event_type="request_created",
            level="info",
            message="Request created",
        )
        self.deployments.create_event(
            deployment_id=deployment.id,
            event_type="deployment_queued",
            level="info",
            message="Deployment queued",
        )
        self.db.commit()
        self.db.refresh(deployment)
        return self.deployments.get_by_id(deployment.id) or deployment

    def list_for_user(self, user: User) -> list[Deployment]:
        if user.role == "admin":
            return self.deployments.list_all()
        return self.deployments.list_for_owner(user.id)

    def get(self, deployment_id: int, user: User) -> Deployment:
        return self._ensure_access(self.deployments.get_by_id(deployment_id), user)

    def update_status(self, deployment_id: int, payload: DeploymentStatusUpdate, admin: User) -> Deployment:
        deployment = self.get(deployment_id, admin)
        updated = self.deployments.update_status(deployment, payload.status)
        self.deployments.create_event(
            deployment_id=deployment.id,
            event_type=f"deployment_{payload.status}",
            level=self._level_for_status(payload.status),
            message=payload.message,
        )
        self.db.commit()
        self.db.refresh(updated)
        return self.deployments.get_by_id(updated.id) or updated

    @staticmethod
    def _level_for_status(status_value: str) -> str:
        if status_value == "success":
            return "success"
        if status_value == "failed":
            return "error"
        return "info"
