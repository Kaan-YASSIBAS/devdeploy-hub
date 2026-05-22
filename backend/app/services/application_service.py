import re
import unicodedata

from fastapi import HTTPException, status
from sqlalchemy import func
from sqlalchemy.orm import Session

from app.models.application import Application
from app.models.deployment import Deployment
from app.models.gitops_deployment_request import GitOpsDeploymentRequest
from app.models.user import User
from app.repositories.application_repository import ApplicationRepository
from app.schemas.application import ApplicationCreate, ApplicationUpdate


def slugify(value: str) -> str:
    normalized = unicodedata.normalize("NFKD", value).encode("ascii", "ignore").decode("ascii")
    slug = re.sub(r"[^a-zA-Z0-9]+", "-", normalized.lower()).strip("-")
    return slug or "application"


class ApplicationService:
    def __init__(self, db: Session):
        self.db = db
        self.applications = ApplicationRepository(db)

    def _ensure_access(self, application: Application | None, user: User) -> Application:
        if application is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Application not found")
        if user.role != "admin" and application.owner_id != user.id:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Application access denied")
        return application

    def _unique_slug(self, name: str, *, current_application_id: int | None = None) -> str:
        base_slug = slugify(name)
        slug = base_slug
        suffix = 2
        while True:
            existing = self.applications.get_by_slug(slug)
            if existing is None or existing.id == current_application_id:
                return slug
            slug = f"{base_slug}-{suffix}"
            suffix += 1

    def create(self, payload: ApplicationCreate, owner: User) -> Application:
        data = payload.model_dump(mode="json")
        data["slug"] = self._unique_slug(payload.name)
        application = self.applications.create(owner_id=owner.id, data=data)
        self.db.commit()
        self.db.refresh(application)
        return application

    def list_for_user(self, user: User) -> list[Application]:
        if user.role == "admin":
            return self.applications.list_all()
        return self.applications.list_for_owner(user.id)

    def get(self, application_id: int, user: User) -> Application:
        return self._ensure_access(self.applications.get_by_id(application_id), user)

    def update(self, application_id: int, payload: ApplicationUpdate, user: User) -> Application:
        application = self.get(application_id, user)
        data = payload.model_dump(mode="json", exclude_unset=True)
        if "name" in data and data["name"] != application.name:
            data["slug"] = self._unique_slug(data["name"], current_application_id=application.id)
        updated = self.applications.update(application, data)
        self.db.commit()
        self.db.refresh(updated)
        return updated

    def delete(self, application_id: int, user: User) -> None:
        application = self.get(application_id, user)
        legacy_deployment_count = (
            self.db.query(func.count(Deployment.id))
            .filter(Deployment.application_id == application.id)
            .scalar()
            or 0
        )
        gitops_request_count = (
            self.db.query(func.count(GitOpsDeploymentRequest.id))
            .filter(GitOpsDeploymentRequest.application_id == application.id)
            .scalar()
            or 0
        )
        if legacy_deployment_count or gitops_request_count:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="Application has deployment history and cannot be deleted.",
            )
        self.applications.delete(application)
        self.db.commit()
