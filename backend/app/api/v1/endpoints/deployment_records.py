import logging
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Request, Response, status
from fastapi.responses import JSONResponse
from sqlalchemy.orm import Session

from app.api.v1.endpoints.gitops import (
    GitOpsDeployRepositoryConfig,
    get_deploy_workload_operation_service,
    get_gitops_deploy_repository_config,
    prepare_gitops_repository,
)
from app.core.deps import get_current_user, get_db
from app.api.v1.runtime_status import (
    get_deployment_destroy_runtime_cleanup_service,
    get_deployment_drift_service,
    get_deployment_reconcile_status_service,
    get_deployment_recovery_verification_service,
    get_product_runtime_status_service,
    get_workload_service_proxy_client,
)
from app.core.config import settings
from app.models.deployment_record import DeploymentRecord
from app.models.user import User
from app.schemas.archive import ArchiveFilter
from app.schemas.deployment_record import (
    DeploymentRecordCreate,
    DeploymentRecordDestroyResponse,
    DeploymentRecordGitOpsUpdate,
    DeploymentRecordGitOpsUpdateResponse,
    DeploymentRecordRead,
    DeploymentRecordRecoverResponse,
    DeploymentRuntimeCleanupRead,
    DeploymentRecordUpdate,
)
from app.schemas.deployment_access import DeploymentAccessRead
from app.schemas.runtime_status import UntrackedDeploymentListResponse
from app.services.deployment_record_service import DeploymentRecordService
from app.services.deployment_reconcile_status import DeploymentReconcileStatusService
from app.services.deployment_access_service import DeploymentAccessService
from app.services.deployment_drift import DeploymentDriftService
from app.services.deployment_preview_service import (
    DeploymentPreviewService,
    PreviewForbiddenError,
    PreviewPathError,
    PreviewServiceUnavailableError,
    PreviewTimeoutError,
    PreviewUnavailableError,
    PreviewUpstreamError,
    WorkloadServiceProxy,
)
from app.services.deployment_destroy_service import DeploymentDestroyRuntimeCleanupService
from app.services.deployment_recovery_service import (
    DeploymentRecoveryVerificationResult,
    DeploymentRecoveryVerificationService,
)
from app.services.gitops.deploy_operation import (
    DeployWorkloadOperationRequest,
    DeployWorkloadOperationService,
)
from app.services.gitops.update_operation import (
    UpdateWorkloadOperationRequest,
    UpdateWorkloadOperationService,
)
from app.services.gitops.destroy_operation import (
    DestroyWorkloadOperationRequest,
    DestroyWorkloadOperationResult,
    DestroyWorkloadOperationService,
)
from app.services.gitops.git_adapter import GitAdapter, sanitize_git_output
from app.services.gitops.managed_repository import ManagedGitRepositoryError
from app.services.preview_session import (
    PREVIEW_SESSION_COOKIE,
    PREVIEW_SESSION_TTL_SECONDS,
    create_preview_session_token,
    decode_preview_session_token,
)
from app.services.product_runtime_status import ProductRuntimeStatusService
from app.repositories.user_repository import UserRepository


logger = logging.getLogger(__name__)

router = APIRouter(prefix="/deployment-records", tags=["deployment-records"])
RECOVER_INTERNAL_MESSAGE = "The deployment recovery operation failed unexpectedly."
RECONCILE_INTERNAL_MESSAGE = "The deployment reconcile operation failed unexpectedly."
DESTROY_INTERNAL_MESSAGE = "The deployment destroy operation failed unexpectedly."
UPDATE_INTERNAL_MESSAGE = "The deployment update operation failed unexpectedly."
RECOVER_ERROR_STATUS_CODES = {
    "validation_failed": status.HTTP_400_BAD_REQUEST,
    "repo_write_failed": status.HTTP_409_CONFLICT,
    "render_failed": status.HTTP_400_BAD_REQUEST,
    "commit_failed": status.HTTP_409_CONFLICT,
    "push_failed": status.HTTP_502_BAD_GATEWAY,
}
DESTROY_ERROR_STATUS_CODES = RECOVER_ERROR_STATUS_CODES
UPDATE_ERROR_STATUS_CODES = RECOVER_ERROR_STATUS_CODES
RegenerateAction = Literal["recover", "reconcile"]
PREVIEW_ALLOWED_METHODS = {"GET", "HEAD", "POST", "OPTIONS"}
PREVIEW_RUNTIME_AUTH_HEADER = "X-DevDeploy-Preview-Session"
PREVIEW_DEFAULT_CORS_REQUEST_HEADERS = (
    f"Accept, Accept-Language, Content-Type, User-Agent, X-APP, {PREVIEW_RUNTIME_AUTH_HEADER}"
)
PREVIEW_SECURITY_HEADERS = {
    "Cache-Control": "no-store",
    "Content-Security-Policy": (
        "sandbox allow-scripts; default-src 'self' data: blob: https:; "
        "base-uri 'none'; connect-src 'self' http: https: ws: wss:; form-action 'none'; "
        "frame-ancestors 'none'; img-src 'self' data: blob: https:; "
        "script-src 'self' 'unsafe-inline' 'unsafe-eval' blob: https:; "
        "style-src 'self' 'unsafe-inline' https:; font-src 'self' data: https:"
    ),
    "Cross-Origin-Resource-Policy": "same-origin",
    "Referrer-Policy": "no-referrer",
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
}


def _read_response(
    deployment: DeploymentRecord,
    runtime_service: ProductRuntimeStatusService,
    drift_service: DeploymentDriftService,
    reconcile_service: DeploymentReconcileStatusService,
) -> DeploymentRecordRead:
    response = DeploymentRecordRead.model_validate(deployment)
    runtime_status = runtime_service.deployment_status(deployment)
    drift_status = drift_service.evaluate(deployment)
    return response.model_copy(
        update={
            "runtime_status": runtime_status,
            "drift_status": drift_status,
            "reconcile_status": reconcile_service.evaluate(
                deployment,
                runtime_status,
                drift_status,
            ),
        }
    )


def get_destroy_workload_operation_service() -> DestroyWorkloadOperationService:
    return DestroyWorkloadOperationService()


def get_update_workload_operation_service() -> UpdateWorkloadOperationService:
    return UpdateWorkloadOperationService()


def _deploy_operation_for_repository(
    operation_service: DeployWorkloadOperationService,
    git_adapter: GitAdapter | None,
) -> DeployWorkloadOperationService:
    if git_adapter is not None and type(operation_service) is DeployWorkloadOperationService:
        return DeployWorkloadOperationService(git_adapter=git_adapter)
    return operation_service


def _update_operation_for_repository(
    operation_service: UpdateWorkloadOperationService,
    git_adapter: GitAdapter | None,
) -> UpdateWorkloadOperationService:
    if git_adapter is not None and type(operation_service) is UpdateWorkloadOperationService:
        return UpdateWorkloadOperationService(git_adapter=git_adapter)
    return operation_service


def _destroy_operation_for_repository(
    operation_service: DestroyWorkloadOperationService,
    git_adapter: GitAdapter | None,
) -> DestroyWorkloadOperationService:
    if git_adapter is not None and type(operation_service) is DestroyWorkloadOperationService:
        return DestroyWorkloadOperationService(git_adapter=git_adapter)
    return operation_service


def _repository_unavailable_response(error: ManagedGitRepositoryError) -> HTTPException:
    return HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=error.message)


def _runtime_cleanup_read(runtime_cleanup) -> DeploymentRuntimeCleanupRead:
    return DeploymentRuntimeCleanupRead(
        status=runtime_cleanup.status,
        deployment_deleted=runtime_cleanup.deployment_deleted,
        service_deleted=runtime_cleanup.service_deleted,
        message=runtime_cleanup.message,
        checked_at=runtime_cleanup.checked_at,
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
    reconcile_service: DeploymentReconcileStatusService = Depends(
        get_deployment_reconcile_status_service
    ),
) -> list[DeploymentRecordRead]:
    deployments = DeploymentRecordService(db).list_for_user(current_user, archive_filter)
    return [
        _read_response(deployment, runtime_service, drift_service, reconcile_service)
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
    reconcile_service: DeploymentReconcileStatusService = Depends(
        get_deployment_reconcile_status_service
    ),
) -> DeploymentRecordRead:
    deployment = DeploymentRecordService(db).get(deployment_id, current_user)
    return _read_response(deployment, runtime_service, drift_service, reconcile_service)


@router.get("/{deployment_id}/access", response_model=DeploymentAccessRead)
def get_deployment_access(
    deployment_id: int,
    response: Response,
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
    access = DeploymentAccessService(runtime_service).evaluate(deployment)
    if access.available and access.preview_url:
        response.set_cookie(
            key=PREVIEW_SESSION_COOKIE,
            value=create_preview_session_token(
                user_id=current_user.id,
                deployment_id=deployment.id,
            ),
            max_age=PREVIEW_SESSION_TTL_SECONDS,
            httponly=True,
            secure=True,
            samesite="none",
            path=f"/api/v1/deployment-records/{deployment.id}/preview/",
        )
    return access


def _preview_cors_headers(request: Request) -> dict[str, str]:
    requested_headers = request.headers.get("access-control-request-headers")
    allowed_headers = PREVIEW_DEFAULT_CORS_REQUEST_HEADERS
    if requested_headers:
        safe_requested_headers: list[str] = []
        for header_name in requested_headers.split(","):
            normalized = header_name.strip()
            lowered = normalized.lower()
            if not normalized:
                continue
            if lowered in {"authorization", "cookie", "host", "connection", "proxy-authorization"}:
                continue
            if lowered == PREVIEW_RUNTIME_AUTH_HEADER.lower():
                safe_requested_headers.append(PREVIEW_RUNTIME_AUTH_HEADER)
                continue
            if lowered.startswith("x-forwarded-") or lowered.startswith("x-devdeploy-"):
                continue
            if any(marker in lowered for marker in ("auth", "token", "secret", "key")):
                continue
            if all(character.isalnum() or character in "-_" for character in normalized):
                safe_requested_headers.append(normalized)
        if safe_requested_headers:
            allowed_headers = ", ".join(sorted(set(safe_requested_headers), key=str.lower))

    return {
        "Access-Control-Allow-Origin": "null",
        "Access-Control-Allow-Credentials": "true",
        "Access-Control-Allow-Methods": ", ".join(sorted(PREVIEW_ALLOWED_METHODS)),
        "Access-Control-Allow-Headers": allowed_headers,
        "Access-Control-Max-Age": "600",
        "Vary": "Origin",
    }


def _preview_json_error_response(
    *,
    request: Request,
    status_code: int,
    detail: str,
) -> JSONResponse:
    return JSONResponse(
        status_code=status_code,
        content={"detail": detail},
        headers={**PREVIEW_SECURITY_HEADERS, **_preview_cors_headers(request)},
    )


def _preview_http_exception_response(error: HTTPException, request: Request) -> JSONResponse:
    detail = error.detail if isinstance(error.detail, str) else "Preview request failed."
    return _preview_json_error_response(
        request=request,
        status_code=int(error.status_code),
        detail=detail,
    )

def _get_preview_user(
    deployment_id: int,
    request: Request,
    db: Session,
) -> User:
    token = request.headers.get(PREVIEW_RUNTIME_AUTH_HEADER) or request.cookies.get(
        PREVIEW_SESSION_COOKIE
    )
    preview_session = decode_preview_session_token(token) if token else None
    if preview_session is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="A valid app preview session is required.",
        )
    if preview_session.deployment_id != deployment_id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="The app preview session does not match this deployment.",
        )
    user = UserRepository(db).get_by_id(preview_session.user_id)
    if user is None or not user.is_active:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="A valid app preview session is required.",
        )
    return user


@router.api_route("/{deployment_id}/preview/", methods=["GET", "HEAD", "POST", "OPTIONS"])
@router.api_route(
    "/{deployment_id}/preview/{preview_path:path}",
    methods=["GET", "HEAD", "POST", "OPTIONS"],
)
async def get_deployment_preview(
    deployment_id: int,
    request: Request,
    preview_path: str = "",
    db: Session = Depends(get_db),
    runtime_service: ProductRuntimeStatusService = Depends(get_product_runtime_status_service),
    proxy: WorkloadServiceProxy | None = Depends(get_workload_service_proxy_client),
) -> Response:
    cors_headers = _preview_cors_headers(request)
    method = request.method.upper()
    if method == "OPTIONS":
        return Response(
            status_code=status.HTTP_204_NO_CONTENT,
            headers={**PREVIEW_SECURITY_HEADERS, **cors_headers},
        )
    if method not in PREVIEW_ALLOWED_METHODS:
        return _preview_json_error_response(
            request=request,
            status_code=status.HTTP_405_METHOD_NOT_ALLOWED,
            detail="Preview method is not allowed.",
        )

    try:
        current_user = _get_preview_user(deployment_id, request, db)
        deployment = DeploymentRecordService(db).get_owned(deployment_id, current_user)
        if deployment.archived_at is not None:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="Archived deployment records are not available for app preview.",
            )
        if request.url.query:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Preview query parameters are not supported.",
            )
    except HTTPException as error:
        return _preview_http_exception_response(error, request)

    body = await request.body() if method == "POST" else None
    preview_service = DeploymentPreviewService(
        access_service=DeploymentAccessService(runtime_service),
        proxy=proxy,
    )
    try:
        result = preview_service.preview(
            deployment,
            preview_path,
            method=method,
            body=body,
            request_headers=request.headers,
        )
    except PreviewPathError as error:
        return _preview_json_error_response(
            request=request,
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=str(error),
        )
    except PreviewUnavailableError as error:
        unavailable_status = (
            status.HTTP_503_SERVICE_UNAVAILABLE
            if error.access_status in {"runtime_unavailable", "unknown"}
            else status.HTTP_409_CONFLICT
        )
        return _preview_json_error_response(
            request=request,
            status_code=unavailable_status,
            detail=f"App preview is unavailable: {error.access_status}.",
        )
    except PreviewTimeoutError:
        return _preview_json_error_response(
            request=request,
            status_code=status.HTTP_504_GATEWAY_TIMEOUT,
            detail="The app preview request timed out.",
        )
    except PreviewForbiddenError:
        return _preview_json_error_response(
            request=request,
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Workload preview access is denied.",
        )
    except PreviewServiceUnavailableError:
        return _preview_json_error_response(
            request=request,
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="The app preview service is unavailable.",
        )
    except PreviewUpstreamError:
        return _preview_json_error_response(
            request=request,
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="The app preview upstream is unavailable.",
        )

    response_headers = {
        **PREVIEW_SECURITY_HEADERS,
        **cors_headers,
        **result.headers,
    }
    preview_base_path = f"/api/v1/deployment-records/{deployment_id}/preview/"
    response_body = DeploymentPreviewService.rewrite_html_for_preview(
        result.body,
        response_headers,
        preview_base_path=preview_base_path,
        runtime_auth_token=create_preview_session_token(
            user_id=current_user.id,
            deployment_id=deployment_id,
        ),
    )
    base_marker = f'<base href="{preview_base_path}">'.encode("utf-8")
    shim_marker = b"devdeploy-preview-routing"
    injected = base_marker in response_body and shim_marker in response_body
    preview_path_header = f"/{preview_path.lstrip('/')}" if preview_path else "/"
    response_headers.update(
        {
            "X-DevDeploy-Preview-Transport": "port-forward",
            "X-DevDeploy-Preview-Injected": "true" if injected else "false",
            "X-DevDeploy-Preview-Path": preview_path_header,
        }
    )
    logger.info(
        "Deployment preview response prepared: deployment_record_id=%s method=%s preview_path=%s status_code=%s content_type=%s injected=%s body_has_base=%s body_has_shim=%s",
        deployment_id,
        method,
        preview_path_header,
        result.status_code,
        response_headers.get("Content-Type", ""),
        injected,
        base_marker in response_body,
        shim_marker in response_body,
    )
    return Response(
        content=b"" if method == "HEAD" else response_body,
        status_code=result.status_code,
        headers=response_headers,
    )


@router.patch("/{deployment_id}", response_model=DeploymentRecordRead)
def update_deployment_record(
    deployment_id: int,
    payload: DeploymentRecordUpdate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> DeploymentRecord:
    return DeploymentRecordService(db).update(deployment_id, payload, current_user)


@router.patch(
    "/{deployment_id}/gitops",
    response_model=DeploymentRecordGitOpsUpdateResponse,
    status_code=status.HTTP_202_ACCEPTED,
)
def update_gitops_deployment_record(
    deployment_id: int,
    payload: DeploymentRecordGitOpsUpdate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
    config: GitOpsDeployRepositoryConfig = Depends(get_gitops_deploy_repository_config),
    operation_service: UpdateWorkloadOperationService = Depends(
        get_update_workload_operation_service
    ),
    runtime_service: ProductRuntimeStatusService = Depends(get_product_runtime_status_service),
    drift_service: DeploymentDriftService = Depends(get_deployment_drift_service),
    reconcile_service: DeploymentReconcileStatusService = Depends(
        get_deployment_reconcile_status_service
    ),
) -> DeploymentRecordGitOpsUpdateResponse | JSONResponse:
    records = DeploymentRecordService(db)
    deployment = records.get_owned(deployment_id, current_user)
    if deployment.archived_at is not None or deployment.desired_state == "destroyed":
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Archived or destroyed deployment records cannot be updated.",
        )
    if not deployment.gitops_manifest_path:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Only GitOps-managed deployment records can be updated through this endpoint.",
        )
    if deployment.desired_state != "pending":
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Only active GitOps-managed deployment records can be updated through this endpoint.",
        )

    merged = {
        "image": payload.image if payload.image is not None else deployment.image,
        "replicas": payload.replicas if payload.replicas is not None else deployment.replicas,
        "container_port": (
            payload.container_port
            if payload.container_port is not None
            else deployment.container_port
        ),
        "service_port": payload.service_port if payload.service_port is not None else deployment.service_port,
        "preview_path": payload.preview_path if payload.preview_path is not None else deployment.preview_path,
    }
    changed_fields = {
        field_name
        for field_name, value in merged.items()
        if getattr(deployment, field_name) != value
    }
    if not changed_fields:
        return DeploymentRecordGitOpsUpdateResponse(
            status="no_changes",
            deployment_id=deployment.id,
            app_name=deployment.app_name,
            commit_sha=deployment.commit_sha,
            manifest_path=deployment.gitops_manifest_path,
            deployment=_read_response(deployment, runtime_service, drift_service, reconcile_service),
            message="The deployment record already matches the requested update.",
        )

    try:
        with prepare_gitops_repository(config) as repository:
            service = _update_operation_for_repository(operation_service, repository.git_adapter)
            result = service.execute(
                UpdateWorkloadOperationRequest(
                    repo_root=repository.repo_root,
                    source_root_relative=config.source_root_relative,
                    expected_branch=config.expected_branch,
                    remote_name=config.remote_name,
                    remote_branch=config.remote_branch,
                    app_name=deployment.app_name,
                    image=merged["image"],
                    replicas=merged["replicas"],
                    container_port=merged["container_port"],
                    service_port=merged["service_port"],
                    service_type=deployment.service_type,
                    namespace=deployment.namespace,
                )
            )
    except ManagedGitRepositoryError as error:
        raise _repository_unavailable_response(error) from None
    except Exception:
        response = DeploymentRecordGitOpsUpdateResponse(
            status="internal_error",
            deployment_id=deployment.id,
            app_name=deployment.app_name,
            commit_sha=deployment.commit_sha,
            manifest_path=deployment.gitops_manifest_path,
            message=UPDATE_INTERNAL_MESSAGE,
            error_code="internal_error",
        )
        return JSONResponse(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            content=response.model_dump(),
        )

    if result.status in {"pushed_waiting_for_argocd", "no_changes"}:
        try:
            updated = records.mark_gitops_updated(
                deployment,
                source_path=result.source_path,
                commit_sha=(
                    result.commit_sha
                    if result.status == "pushed_waiting_for_argocd"
                    or {"image", "replicas", "container_port", "service_port"} & changed_fields
                    else None
                ),
                image=merged["image"],
                replicas=merged["replicas"],
                container_port=merged["container_port"],
                service_port=merged["service_port"],
                preview_path=merged["preview_path"],
            )
        except Exception:
            db.rollback()
            response = DeploymentRecordGitOpsUpdateResponse(
                status="internal_error",
                deployment_id=deployment.id,
                app_name=deployment.app_name,
                commit_sha=result.commit_sha or deployment.commit_sha,
                manifest_path=deployment.gitops_manifest_path,
                message=(
                    "The GitOps update succeeded, but the deployment record could not be updated."
                ),
                error_code="product_record_persistence_failed",
            )
            return JSONResponse(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                content=response.model_dump(),
            )
        return DeploymentRecordGitOpsUpdateResponse(
            status="updated",
            deployment_id=updated.id,
            app_name=updated.app_name,
            commit_sha=updated.commit_sha,
            manifest_path=updated.gitops_manifest_path,
            deployment=_read_response(updated, runtime_service, drift_service, reconcile_service),
            message=(
                "The deployment update commit was pushed and is waiting for Argo CD reconciliation."
                if result.status == "pushed_waiting_for_argocd"
                else "The deployment record was updated; GitOps manifests already matched the requested state."
            ),
        )

    response = DeploymentRecordGitOpsUpdateResponse(
        status=result.status,
        deployment_id=deployment.id,
        app_name=deployment.app_name,
        commit_sha=result.commit_sha,
        manifest_path=deployment.gitops_manifest_path,
        message=sanitize_git_output(result.message),
        error_code=result.error_code,
    )
    return JSONResponse(
        status_code=UPDATE_ERROR_STATUS_CODES.get(
            result.status,
            status.HTTP_500_INTERNAL_SERVER_ERROR,
        ),
        content=response.model_dump(),
    )


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
    recovery_verification_service: DeploymentRecoveryVerificationService = Depends(
        get_deployment_recovery_verification_service
    ),
) -> DeploymentRecordRecoverResponse | JSONResponse:
    records = DeploymentRecordService(db)
    deployment = records.get_owned(deployment_id, current_user)
    if deployment.archived_at is not None:
        if deployment.desired_state == "destroyed":
            return _recover_destroyed_deployment_record(
                records=records,
                deployment=deployment,
                db=db,
                config=config,
                operation_service=operation_service,
                recovery_verification_service=recovery_verification_service,
            )
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


def _recover_destroyed_deployment_record(
    *,
    records: DeploymentRecordService,
    deployment: DeploymentRecord,
    db: Session,
    config: GitOpsDeployRepositoryConfig,
    operation_service: DeployWorkloadOperationService,
    recovery_verification_service: DeploymentRecoveryVerificationService,
) -> DeploymentRecordRecoverResponse | JSONResponse:
    if deployment.service_definition_id is None or deployment.service_definition is None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Destroyed deployment records require an owned service definition before recovery.",
        )
    if deployment.service_definition.owner_id != deployment.owner_id:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Destroyed deployment record ownership is inconsistent with its service definition.",
        )

    try:
        with prepare_gitops_repository(config) as repository:
            service = _deploy_operation_for_repository(operation_service, repository.git_adapter)
            result = service.execute(
                DeployWorkloadOperationRequest(
                    repo_root=repository.repo_root,
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
                    write_mode="restore_destroyed",
                )
            )
    except ManagedGitRepositoryError as error:
        raise _repository_unavailable_response(error) from None
    except Exception:
        response = DeploymentRecordRecoverResponse(
            status="internal_error",
            deployment_id=deployment.id,
            app_name=deployment.app_name,
            commit_sha=deployment.commit_sha,
            manifest_path=deployment.gitops_manifest_path,
            message=RECOVER_INTERNAL_MESSAGE,
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
                message=RECOVER_INTERNAL_MESSAGE,
                error_code="internal_error",
            )
            return JSONResponse(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                content=response.model_dump(),
            )

        if result.status == "pushed_waiting_for_argocd":
            recovery_commit_sha = result.commit_sha
            try:
                deployment = records.mark_recovery_pending(
                    deployment,
                    source_path=result.source_path,
                    commit_sha=recovery_commit_sha,
                )
            except Exception:
                db.rollback()
                response = DeploymentRecordRecoverResponse(
                    status="internal_error",
                    deployment_id=deployment.id,
                    app_name=deployment.app_name,
                    commit_sha=recovery_commit_sha,
                    manifest_path=deployment.gitops_manifest_path,
                    message=(
                        "The destroyed deployment recovery commit was pushed, but the deployment "
                        "record could not store the recovery revision."
                    ),
                    error_code="product_record_persistence_failed",
                )
                return JSONResponse(
                    status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                    content=response.model_dump(),
                )
        else:
            recovery_commit_sha = deployment.commit_sha
            if not recovery_commit_sha:
                verification = DeploymentRecoveryVerificationResult(
                    status="failed",
                    message=(
                        "Recovery manifests already exist, but no recorded recovery revision "
                        "is available for safe verification."
                    ),
                    checked_at=deployment.updated_at,
                )
                return _destroyed_recovery_not_ready_response(
                    deployment=deployment,
                    verification=verification,
                    commit_sha=None,
                )
        verification = recovery_verification_service.verify_recovered(
            deployment,
            recovery_commit_sha=recovery_commit_sha,
        )
        if verification.status != "ready":
            return _destroyed_recovery_not_ready_response(
                deployment=deployment,
                verification=verification,
                commit_sha=recovery_commit_sha,
            )

        try:
            updated = records.mark_recovered(
                deployment,
                source_path=result.source_path,
                commit_sha=recovery_commit_sha,
            )
        except Exception:
            db.rollback()
            response = DeploymentRecordRecoverResponse(
                status="internal_error",
                deployment_id=deployment.id,
                app_name=deployment.app_name,
                commit_sha=recovery_commit_sha,
                manifest_path=deployment.gitops_manifest_path,
                message=(
                    "The destroyed deployment was recovered in GitOps and runtime readiness was verified, "
                    "but the deployment record could not be reactivated."
                ),
                error_code="product_record_persistence_failed",
            )
            return JSONResponse(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                content=response.model_dump(),
            )

        return DeploymentRecordRecoverResponse(
            status="recovered",
            deployment_id=updated.id,
            app_name=updated.app_name,
            commit_sha=updated.commit_sha,
            manifest_path=updated.gitops_manifest_path,
            message="Destroyed deployment recovery completed and runtime readiness was verified.",
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


def _destroyed_recovery_not_ready_response(
    *,
    deployment: DeploymentRecord,
    verification: DeploymentRecoveryVerificationResult,
    commit_sha: str | None,
) -> JSONResponse:
    response_status = {
        "pending": "runtime_pending",
        "conflict": "runtime_conflict",
        "unavailable": "runtime_unavailable",
        "failed": "recovery_failed",
    }.get(verification.status, "runtime_pending")
    http_status = {
        "runtime_conflict": status.HTTP_409_CONFLICT,
        "runtime_unavailable": status.HTTP_503_SERVICE_UNAVAILABLE,
        "recovery_failed": status.HTTP_409_CONFLICT,
    }.get(response_status, status.HTTP_202_ACCEPTED)
    response = DeploymentRecordRecoverResponse(
        status=response_status,
        deployment_id=deployment.id,
        app_name=deployment.app_name,
        commit_sha=commit_sha,
        manifest_path=deployment.gitops_manifest_path,
        message=verification.message,
        error_code=verification.status,
    )
    return JSONResponse(status_code=http_status, content=response.model_dump())


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
        with prepare_gitops_repository(config) as repository:
            service = _deploy_operation_for_repository(operation_service, repository.git_adapter)
            result = service.execute(
                DeployWorkloadOperationRequest(
                    repo_root=repository.repo_root,
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
    except ManagedGitRepositoryError as error:
        raise _repository_unavailable_response(error) from None
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


@router.post(
    "/{deployment_id}/destroy",
    response_model=DeploymentRecordDestroyResponse,
    status_code=status.HTTP_202_ACCEPTED,
)
def destroy_deployment_record(
    deployment_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
    config: GitOpsDeployRepositoryConfig = Depends(get_gitops_deploy_repository_config),
    operation_service: DestroyWorkloadOperationService = Depends(
        get_destroy_workload_operation_service
    ),
    runtime_cleanup_service: DeploymentDestroyRuntimeCleanupService = Depends(
        get_deployment_destroy_runtime_cleanup_service
    ),
) -> DeploymentRecordDestroyResponse | JSONResponse:
    records = DeploymentRecordService(db)
    deployment = records.get_owned(deployment_id, current_user)
    if deployment.archived_at is not None:
        if deployment.desired_state == "destroyed":
            return _retry_destroy_runtime_cleanup(
                records=records,
                deployment=deployment,
                db=db,
                config=config,
                runtime_cleanup_service=runtime_cleanup_service,
            )
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Archived deployment records cannot be destroyed.",
        )

    try:
        with prepare_gitops_repository(config) as repository:
            service = _destroy_operation_for_repository(operation_service, repository.git_adapter)
            result = service.execute(
                DestroyWorkloadOperationRequest(
                    repo_root=repository.repo_root,
                    source_root_relative=config.source_root_relative,
                    expected_branch=config.expected_branch,
                    remote_name=config.remote_name,
                    remote_branch=config.remote_branch,
                    app_name=deployment.app_name,
                )
            )
    except ManagedGitRepositoryError as error:
        raise _repository_unavailable_response(error) from None
    except Exception:
        response = DeploymentRecordDestroyResponse(
            status="internal_error",
            deployment_id=deployment.id,
            app_name=deployment.app_name,
            commit_sha=deployment.commit_sha,
            manifest_path=deployment.gitops_manifest_path,
            message=DESTROY_INTERNAL_MESSAGE,
            error_code="internal_error",
        )
        return JSONResponse(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            content=response.model_dump(mode="json"),
        )

    if result.status in {"pushed_waiting_for_argocd", "no_changes"}:
        return _finish_destroyed_deployment_record(
            records=records,
            deployment=deployment,
            db=db,
            result=result,
            runtime_cleanup_service=runtime_cleanup_service,
        )

    response = DeploymentRecordDestroyResponse(
        status=result.status,
        deployment_id=deployment.id,
        app_name=deployment.app_name,
        commit_sha=result.commit_sha,
        manifest_path=deployment.gitops_manifest_path,
        message=sanitize_git_output(result.message),
        error_code=result.error_code,
    )
    return JSONResponse(
        status_code=DESTROY_ERROR_STATUS_CODES.get(
            result.status,
            status.HTTP_500_INTERNAL_SERVER_ERROR,
        ),
        content=response.model_dump(mode="json"),
    )


def _finish_destroyed_deployment_record(
    *,
    records: DeploymentRecordService,
    deployment: DeploymentRecord,
    db: Session,
    result: DestroyWorkloadOperationResult,
    runtime_cleanup_service: DeploymentDestroyRuntimeCleanupService,
) -> DeploymentRecordDestroyResponse | JSONResponse:
    runtime_cleanup = runtime_cleanup_service.cleanup(
        deployment,
        destroy_commit_sha=result.commit_sha or deployment.commit_sha,
    )
    try:
        updated = records.mark_destroyed(
            deployment,
            source_path=result.source_path,
            commit_sha=result.commit_sha,
            runtime_cleanup_status=runtime_cleanup.status,
        )
    except Exception:
        db.rollback()
        response = DeploymentRecordDestroyResponse(
            status="internal_error",
            deployment_id=deployment.id,
            app_name=deployment.app_name,
            commit_sha=result.commit_sha or deployment.commit_sha,
            manifest_path=deployment.gitops_manifest_path,
            runtime_cleanup=_runtime_cleanup_read(runtime_cleanup),
            message="The GitOps destroy operation succeeded, but the deployment record could not be updated.",
            error_code="product_record_persistence_failed",
        )
        return JSONResponse(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            content=response.model_dump(mode="json"),
        )

    cleanup_read = _runtime_cleanup_read(runtime_cleanup)
    cleanup_complete = runtime_cleanup.status in {"completed", "not_required"}
    if not cleanup_complete:
        response_status = "runtime_cleanup_pending"
        message = (
            "The GitOps workload manifests were removed, but runtime cleanup is waiting for safe completion."
        )
    elif result.status == "no_changes":
        response_status = "no_changes"
        message = "The GitOps workload manifests were already absent; the record was archived as destroyed."
    else:
        response_status = "destroyed"
        message = "The GitOps workload manifests were removed and runtime cleanup stable absence was verified."
    return DeploymentRecordDestroyResponse(
        status=response_status,
        deployment_id=updated.id,
        app_name=updated.app_name,
        commit_sha=updated.commit_sha,
        manifest_path=updated.gitops_manifest_path,
        runtime_cleanup=cleanup_read,
        message=message,
    )


def _retry_destroy_runtime_cleanup(
    *,
    records: DeploymentRecordService,
    deployment: DeploymentRecord,
    db: Session,
    config: GitOpsDeployRepositoryConfig,
    runtime_cleanup_service: DeploymentDestroyRuntimeCleanupService,
) -> DeploymentRecordDestroyResponse | JSONResponse:
    runtime_cleanup = runtime_cleanup_service.cleanup(
        deployment,
        destroy_commit_sha=deployment.commit_sha,
    )
    try:
        updated = records.mark_destroyed(
            deployment,
            source_path=config.source_root_relative,
            commit_sha=deployment.commit_sha,
            runtime_cleanup_status=runtime_cleanup.status,
        )
    except Exception:
        db.rollback()
        response = DeploymentRecordDestroyResponse(
            status="internal_error",
            deployment_id=deployment.id,
            app_name=deployment.app_name,
            commit_sha=deployment.commit_sha,
            manifest_path=deployment.gitops_manifest_path,
            runtime_cleanup=_runtime_cleanup_read(runtime_cleanup),
            message="The runtime cleanup retry completed, but the deployment record could not be updated.",
            error_code="product_record_persistence_failed",
        )
        return JSONResponse(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            content=response.model_dump(mode="json"),
        )

    cleanup_complete = runtime_cleanup.status in {"completed", "not_required"}
    return DeploymentRecordDestroyResponse(
        status="destroyed" if cleanup_complete else "runtime_cleanup_pending",
        deployment_id=updated.id,
        app_name=updated.app_name,
        commit_sha=updated.commit_sha,
        manifest_path=updated.gitops_manifest_path,
        runtime_cleanup=_runtime_cleanup_read(runtime_cleanup),
        message=(
            "Runtime cleanup retry completed and stable absence was verified."
            if cleanup_complete
            else "Runtime cleanup retry is still waiting for safe completion."
        ),
    )


@router.delete("/{deployment_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_deployment_record(
    deployment_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> Response:
    DeploymentRecordService(db).delete(deployment_id, current_user)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
