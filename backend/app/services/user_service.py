from sqlalchemy.orm import Session

from app.models.user import User
from app.repositories.application_repository import ApplicationRepository
from app.repositories.deployment_repository import DeploymentRepository
from app.schemas.user import UserSummary


class UserService:
    def __init__(self, db: Session):
        self.applications = ApplicationRepository(db)
        self.deployments = DeploymentRepository(db)

    def summary(self, user: User) -> UserSummary:
        owner_id = None if user.role == "admin" else user.id
        return UserSummary(
            total_applications=self.applications.count(owner_id=owner_id),
            total_deployments=self.deployments.count(owner_id=owner_id),
            pending_deployments=self.deployments.count(owner_id=owner_id, status="pending"),
            running_deployments=self.deployments.count(owner_id=owner_id, status="running"),
            successful_deployments=self.deployments.count(owner_id=owner_id, status="success"),
            failed_deployments=self.deployments.count(owner_id=owner_id, status="failed"),
        )
