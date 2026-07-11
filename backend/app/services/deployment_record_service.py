from fastapi import HTTPException, status
from sqlalchemy.orm import Session

from app.models.deployment_record import DeploymentRecord, utc_now
from app.models.service_definition import ServiceDefinition
from app.models.user import User
from app.repositories.deployment_record_repository import DeploymentRecordRepository
from app.repositories.service_definition_repository import ServiceDefinitionRepository
from app.schemas.archive import ArchiveFilter
from app.schemas.deployment_record import DeploymentRecordCreate, DeploymentRecordUpdate
from app.services.gitops.product_records import PUBLISHED_STATUS_SUMMARY, build_manifest_path


class DeploymentRecordService:
    def __init__(self, db: Session):
        self.db = db
        self.deployments = DeploymentRecordRepository(db)
        self.services = ServiceDefinitionRepository(db)

    @staticmethod
    def _ensure_access(deployment: DeploymentRecord | None, user: User) -> DeploymentRecord:
        if deployment is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Deployment record not found")
        if user.role != "admin" and deployment.owner_id != user.id:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Deployment record access denied")
        return deployment

    def _owned_service(
        self,
        service_id: int | None,
        *,
        expected_owner_id: int,
        user: User,
    ) -> ServiceDefinition | None:
        if service_id is None:
            return None
        service = self.services.get_by_id(service_id)
        if service is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Service definition not found")
        if service.owner_id != expected_owner_id or (user.role != "admin" and service.owner_id != user.id):
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Service definition access denied")
        return service

    def create(self, payload: DeploymentRecordCreate, owner: User) -> DeploymentRecord:
        self._owned_service(
            payload.service_definition_id,
            expected_owner_id=owner.id,
            user=owner,
        )
        # This creates product-domain state only. GitOps publication remains an explicit, separate flow.
        deployment = self.deployments.create(owner_id=owner.id, data=payload.model_dump())
        self.db.commit()
        self.db.refresh(deployment)
        return self.deployments.get_by_id(deployment.id) or deployment

    def list_for_user(
        self,
        user: User,
        archive_filter: ArchiveFilter = "active",
    ) -> list[DeploymentRecord]:
        return self.deployments.list_for_owner(user.id, archive_filter)

    def list_owned(self, user: User) -> list[DeploymentRecord]:
        return self.deployments.list_for_owner(user.id)

    def get(self, deployment_id: int, user: User) -> DeploymentRecord:
        return self._ensure_access(self.deployments.get_by_id(deployment_id), user)

    def get_owned(self, deployment_id: int, user: User) -> DeploymentRecord:
        deployment = self.deployments.get_by_id(deployment_id)
        if deployment is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Deployment record not found")
        if deployment.owner_id != user.id:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Deployment record access denied")
        return deployment

    def update(
        self,
        deployment_id: int,
        payload: DeploymentRecordUpdate,
        user: User,
    ) -> DeploymentRecord:
        deployment = self.get(deployment_id, user)
        data = payload.model_dump(exclude_unset=True)
        if data.get("desired_state") == "destroyed":
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Use the destroy endpoint to mark deployment records as destroyed.",
            )
        if "service_definition_id" in data:
            self._owned_service(
                data["service_definition_id"],
                expected_owner_id=deployment.owner_id,
                user=user,
            )
        updated = self.deployments.update(deployment, data)
        self.db.commit()
        self.db.refresh(updated)
        return self.deployments.get_by_id(updated.id) or updated

    def archive(self, deployment_id: int, user: User) -> DeploymentRecord:
        deployment = self.get_owned(deployment_id, user)
        if deployment.archived_at is None:
            deployment.archived_at = utc_now()
            self.db.commit()
            self.db.refresh(deployment)
        return self.deployments.get_by_id(deployment.id) or deployment

    def delete(self, deployment_id: int, user: User) -> None:
        deployment = self.get_owned(deployment_id, user)
        self.deployments.delete(deployment)
        self.db.commit()

    def mark_regenerated(
        self,
        deployment: DeploymentRecord,
        *,
        source_path: str,
        commit_sha: str | None,
    ) -> DeploymentRecord:
        data = {
            "gitops_manifest_path": build_manifest_path(source_path, deployment.app_name),
            "desired_state": "pending",
            "status_summary": PUBLISHED_STATUS_SUMMARY,
        }
        if commit_sha is not None:
            data["commit_sha"] = commit_sha.lower()
        updated = self.deployments.update(deployment, data)
        self.db.commit()
        self.db.refresh(updated)
        return self.deployments.get_by_id(updated.id) or updated

    def mark_destroyed(
        self,
        deployment: DeploymentRecord,
        *,
        source_path: str,
        commit_sha: str | None,
        runtime_cleanup_status: str,
    ) -> DeploymentRecord:
        data = {
            "gitops_manifest_path": build_manifest_path(source_path, deployment.app_name),
            "desired_state": "destroyed",
            "status_summary": self._destroyed_status_summary(runtime_cleanup_status),
            "archived_at": deployment.archived_at or utc_now(),
        }
        if commit_sha is not None:
            data["commit_sha"] = commit_sha.lower()
        updated = self.deployments.update(deployment, data)
        self.db.commit()
        self.db.refresh(updated)
        return self.deployments.get_by_id(updated.id) or updated

    @staticmethod
    def _destroyed_status_summary(runtime_cleanup_status: str) -> str:
        if runtime_cleanup_status == "completed":
            return "GitOps manifests removed; runtime cleanup complete and stable absence verified."
        if runtime_cleanup_status == "not_required":
            return "GitOps manifests removed; no matching runtime Deployment or Service was present."
        if runtime_cleanup_status == "failed":
            return "GitOps manifests removed; runtime resources reappeared or remained after cleanup."
        if runtime_cleanup_status == "unavailable":
            return "GitOps manifests removed; runtime cleanup could not be verified."
        return "GitOps manifests removed; runtime cleanup is pending Argo CD observation or follow-up."
