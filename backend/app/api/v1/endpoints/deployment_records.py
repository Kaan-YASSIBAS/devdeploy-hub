from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Response, status
from fastapi.responses import JSONResponse
from sqlalchemy.orm import Session

from app.api.v1.endpoints.gitops import (
    GitOpsDeployRepositoryConfig,
    get_deploy_workload_operation_service,
    get_gitops_deploy_repository_config,
)
from app.core.deps import get_current_user, get_db
from app.api.v1.runtime_status import (
    get_deployment_drift_service,
    get_product_runtime_status_service,
)
from app.models.deployment_record import DeploymentRecord
from app.models.user import User
from app.schemas.archive import ArchiveFilter
from app.schemas.deployment_record import (
    DeploymentRecordCreate,
    DeploymentRecordRead,
    DeploymentRecordRecoverResponse,
    DeploymentRecordUpdate,
)
from app.schemas.deployment_access import DeploymentAccessRead
from app.schemas.runtime_status import UntrackedDeploymentListResponse
from app.services.deployment_record_service import DeploymentRecordService
from app.services.deployment_access_service import DeploymentAccessService
from app.services.deployment_drift import DeploymentDriftService
from app.services.gitops.deploy_operation import (
    DeployWorkloadOperationRequest,
    DeployWorkloadOperationService,
)
from app.services.gitops.git_adapter import sanitize_git_output
from app.services.product_runtime_status import ProductRuntimeStatusService


router = APIRouter(prefix="/deployment-records", tags=["deployment-records"])
RECOVER_INTERNAL_MESSAGE = "The deployment recovery operation failed unexpectedly."
RECONCILE_INTERNAL_MESSAGE = "The deployment reconcile operation failed unexpectedly."
RECOVER_ERROR_STATUS_CODES = {
    "validation_failed": status.HTTP_400_BAD_REQUEST,
    "repo_write_failed": status.HTTP_409_CONFLICT,
    "render_failed": status.HTTP_400_BAD_REQUEST,
    "commit_failed": status.HTTP_409_CONFLICT,
    "push_failed": status.HTTP_502_BAD_GATEWAY,
}
RegenerateAction = Literal["recover", "reconcile"]


def _read_response(
    deployment: DeploymentRecord,
    runtime_service: ProductRuntimeStatusService,
    drift_service: DeploymentDriftService,
) -> DeploymentRecordRead:
    response = DeploymentRecordRead.model_validate(deployment)
    return response.model_copy(
        update={
            "runtime_status": runtime_service.deployment_status(deployment),
            "drift_status": drift_service.evaluate(deployment),
        }
    )


@router.post("", response_model=DeploymentRecordRead, status_code=status.HTTP_201_CREATED)
def create_deployment_record(
    payload: DeploymentRecordCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> DeploymentRecord:
    return DeploymentRecordService(db).create(payload, current_user)


@router.get("", response_model=list[DeploymentRecordRead])
def list_deployment_records(
    archive_filter: ArchiveFilter = "active",
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
    runtime_service: ProductRuntimeStatusService = Depends(get_product_runtime_status_service),
    drift_service: DeploymentDriftService = Depends(get_deployment_drift_service),
) -> list[DeploymentRecordRead]:
    deployments = DeploymentRecordService(db).list_for_user(current_user, archive_filter)
    return [
        _read_response(deployment, runtime_service, drift_service)
        for deployment in deployments
    ]


@router.get("/untracked", response_model=UntrackedDeploymentListResponse)
def list_untracked_deployments(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
    runtime_service: ProductRuntimeStatusService = Depends(get_product_runtime_status_service),
) -> UntrackedDeploymentListResponse:
    owned = DeploymentRecordService(db).list_owned(current_user)
    return runtime_service.untracked_deployments({deployment.app_name for deployment in owned})


@router.get("/{deployment_id}", response_model=DeploymentRecordRead)
def get_deployment_record(
    deployment_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
    runtime_service: ProductRuntimeStatusService = Depends(get_product_runtime_status_service),
    drift_service: DeploymentDriftService = Depends(get_deployment_drift_service),
) -> DeploymentRecordRead:
    deployment = DeploymentRecordService(db).get(deployment_id, current_user)
    return _read_response(deployment, runtime_service, drift_service)


@router.get("/{deployment_id}/access", response_model=DeploymentAccessRead)
def get_deployment_access(
    deployment_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
    runtime_service: ProductRuntimeStatusService = Depends(get_product_runtime_status_service),
) -> DeploymentAccessRead:
    deployment = DeploymentRecordService(db).get_owned(deployment_id, current_user)
    if deployment.archived_at is not None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Archived deployment records are not available for app access.",
        )
    return DeploymentAccessService(runtime_service).evaluate(deployment)


@router.patch("/{deployment_id}", response_model=DeploymentRecordRead)
def update_deployment_record(
    deployment_id: int,
    payload: DeploymentRecordUpdate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> DeploymentRecord:
    return DeploymentRecordService(db).update(deployment_id, payload, current_user)


@router.post("/{deployment_id}/archive", response_model=DeploymentRecordRead)
def archive_deployment_record(
    deployment_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> DeploymentRecord:
    return DeploymentRecordService(db).archive(deployment_id, current_user)


@router.post(
    "/{deployment_id}/recover",
    response_model=DeploymentRecordRecoverResponse,
    status_code=status.HTTP_202_ACCEPTED,
)
def recover_deployment_record(
    deployment_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
    config: GitOpsDeployRepositoryConfig = Depends(get_gitops_deploy_repository_config),
    operation_service: DeployWorkloadOperationService = Depends(
        get_deploy_workload_operation_service
    ),
) -> DeploymentRecordRecoverResponse | JSONResponse:
    records = DeploymentRecordService(db)
    deployment = records.get_owned(deployment_id, current_user)
    if deployment.archived_at is not None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Archived deployment records cannot be recovered.",
        )

    return _regenerate_deployment_record(
        action="recover",
        records=records,
        deployment=deployment,
        db=db,
        config=config,
        operation_service=operation_service,
    )


@router.post(
    "/{deployment_id}/reconcile",
    response_model=DeploymentRecordRecoverResponse,
    status_code=status.HTTP_202_ACCEPTED,
)
def reconcile_deployment_record(
    deployment_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
    config: GitOpsDeployRepositoryConfig = Depends(get_gitops_deploy_repository_config),
    operation_service: DeployWorkloadOperationService = Depends(
        get_deploy_workload_operation_service
    ),
) -> DeploymentRecordRecoverResponse | JSONResponse:
    records = DeploymentRecordService(db)
    deployment = records.get_owned(deployment_id, current_user)
    if deployment.archived_at is not None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Archived deployment records cannot be reconciled.",
        )

    return _regenerate_deployment_record(
        action="reconcile",
        records=records,
        deployment=deployment,
        db=db,
        config=config,
        operation_service=operation_service,
    )


def _regenerate_deployment_record(
    *,
    action: RegenerateAction,
    records: DeploymentRecordService,
    deployment: DeploymentRecord,
    db: Session,
    config: GitOpsDeployRepositoryConfig,
    operation_service: DeployWorkloadOperationService,
) -> DeploymentRecordRecoverResponse | JSONResponse:
    internal_message = (
        RECOVER_INTERNAL_MESSAGE if action == "recover" else RECONCILE_INTERNAL_MESSAGE
    )

    try:
        result = operation_service.execute(
            DeployWorkloadOperationRequest(
                repo_root=config.repo_root,
                source_root_relative=config.source_root_relative,
                expected_branch=config.expected_branch,
                remote_name=config.remote_name,
                remote_branch=config.remote_branch,
                app_name=deployment.app_name,
                image=deployment.image,
                replicas=deployment.replicas,
                container_port=deployment.container_port,
                service_port=deployment.service_port,
                service_type=deployment.service_type,
                namespace=deployment.namespace,
                write_mode=action,
            )
        )
    except Exception:
        response = DeploymentRecordRecoverResponse(
            status="internal_error",
            deployment_id=deployment.id,
            app_name=deployment.app_name,
            commit_sha=deployment.commit_sha,
            manifest_path=deployment.gitops_manifest_path,
            message=internal_message,
            error_code="internal_error",
        )
        return JSONResponse(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            content=response.model_dump(),
        )

    if result.status in {"pushed_waiting_for_argocd", "no_changes"}:
        if result.status == "pushed_waiting_for_argocd" and not result.commit_sha:
            response = DeploymentRecordRecoverResponse(
                status="internal_error",
                deployment_id=deployment.id,
                app_name=deployment.app_name,
                commit_sha=deployment.commit_sha,
                manifest_path=deployment.gitops_manifest_path,
                message=internal_message,
                error_code="internal_error",
            )
            return JSONResponse(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                content=response.model_dump(),
            )
        try:
            updated = records.mark_regenerated(
                deployment,
                source_path=result.source_path,
                commit_sha=result.commit_sha,
            )
        except Exception:
            db.rollback()
            response = DeploymentRecordRecoverResponse(
                status="internal_error",
                deployment_id=deployment.id,
                app_name=deployment.app_name,
                commit_sha=result.commit_sha or deployment.commit_sha,
                manifest_path=deployment.gitops_manifest_path,
                message=(
                    "The GitOps recovery succeeded, but the deployment record could not be updated."
                    if action == "recover"
                    else "The GitOps reconcile operation succeeded, but the deployment record could not be updated."
                ),
                error_code="product_record_persistence_failed",
            )
            return JSONResponse(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                content=response.model_dump(),
            )
        return DeploymentRecordRecoverResponse(
            status=(
                "pushed_waiting_for_argocd"
                if result.status == "pushed_waiting_for_argocd"
                else (
                    "no_changes_waiting_for_argocd"
                    if action == "recover"
                    else "no_changes"
                )
            ),
            deployment_id=updated.id,
            app_name=updated.app_name,
            commit_sha=updated.commit_sha,
            manifest_path=updated.gitops_manifest_path,
            message=(
                (
                    "The recovery commit was pushed and is waiting for Argo CD reconciliation."
                    if action == "recover"
                    else "The reconcile commit was pushed and is waiting for Argo CD reconciliation."
                )
                if result.status == "pushed_waiting_for_argocd"
                else (
                    "The GitOps manifests already match this record; Argo CD reconciliation is pending."
                    if action == "recover"
                    else "The deployment is already aligned with its GitOps manifests."
                )
            ),
        )

    response = DeploymentRecordRecoverResponse(
        status=result.status,
        deployment_id=deployment.id,
        app_name=deployment.app_name,
        commit_sha=result.commit_sha,
        manifest_path=deployment.gitops_manifest_path,
        message=sanitize_git_output(result.message),
        error_code=result.error_code,
    )
    return JSONResponse(
        status_code=RECOVER_ERROR_STATUS_CODES.get(
            result.status,
            status.HTTP_500_INTERNAL_SERVER_ERROR,
        ),
        content=response.model_dump(),
    )


@router.delete("/{deployment_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_deployment_record(
    deployment_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> Response:
    DeploymentRecordService(db).delete(deployment_id, current_user)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
