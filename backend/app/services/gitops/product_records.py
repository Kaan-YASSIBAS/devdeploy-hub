from dataclasses import dataclass
from pathlib import PurePosixPath

from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from app.repositories.deployment_record_repository import DeploymentRecordRepository
from app.repositories.service_definition_repository import ServiceDefinitionRepository


PUBLISHED_STATUS_SUMMARY = "GitOps manifests published"


class ProductRecordPersistenceError(RuntimeError):
    """Raised when a published GitOps change cannot be recorded safely."""


def build_manifest_path(source_path: str, app_name: str) -> str:
    root = PurePosixPath(source_path)
    if (
        not source_path
        or root.is_absolute()
        or any(part in {"", ".", ".."} or part.lower() == ".git" for part in root.parts)
    ):
        raise ProductRecordPersistenceError("The published GitOps manifest path is invalid.")
    return (root / "apps" / app_name).as_posix()


@dataclass(frozen=True, slots=True)
class PublishedDeploymentRecordRequest:
    owner_id: int
    app_name: str
    image: str
    replicas: int
    container_port: int
    service_port: int
    service_type: str
    namespace: str
    source_path: str
    commit_sha: str


@dataclass(frozen=True, slots=True)
class PublishedDeploymentRecordResult:
    service_definition_id: int
    deployment_record_id: int


class GitOpsProductRecordService:
    def __init__(self, db: Session):
        self.db = db
        self.services = ServiceDefinitionRepository(db)
        self.deployments = DeploymentRecordRepository(db)

    def record_published_deployment(
        self,
        request: PublishedDeploymentRecordRequest,
    ) -> PublishedDeploymentRecordResult:
        manifest_path = build_manifest_path(request.source_path, request.app_name)
        try:
            service = self.services.get_by_owner_and_name(request.owner_id, request.app_name)
            service_defaults = {
                "default_image": request.image,
                "default_replicas": request.replicas,
                "default_port": request.service_port,
            }
            if service is None:
                service = self.services.create(
                    owner_id=request.owner_id,
                    data={
                        "name": request.app_name,
                        "description": None,
                        **service_defaults,
                    },
                )
            else:
                if service.archived_at is not None:
                    service_defaults["archived_at"] = None
                self.services.update(service, service_defaults)

            deployment = self.deployments.create(
                owner_id=request.owner_id,
                data={
                    "service_definition_id": service.id,
                    "app_name": request.app_name,
                    "image": request.image,
                    "replicas": request.replicas,
                    "container_port": request.container_port,
                    "service_port": request.service_port,
                    "service_type": request.service_type,
                    "namespace": request.namespace,
                    "gitops_manifest_path": manifest_path,
                    "commit_sha": request.commit_sha.lower(),
                    "desired_state": "pending",
                    "status_summary": PUBLISHED_STATUS_SUMMARY,
                },
            )
            self.db.commit()
            return PublishedDeploymentRecordResult(
                service_definition_id=service.id,
                deployment_record_id=deployment.id,
            )
        except SQLAlchemyError as error:
            self.db.rollback()
            raise ProductRecordPersistenceError(
                "The published GitOps change could not be recorded in the product database."
            ) from error
