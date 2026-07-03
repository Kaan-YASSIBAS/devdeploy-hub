from dataclasses import dataclass
from pathlib import Path, PureWindowsPath

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.responses import JSONResponse

from app.core.config import settings
from app.core.deps import get_current_user
from app.models.user import User
from app.schemas.gitops_app import GitOpsAppCreateRequest, GitOpsAppCreateResponse
from app.services.gitops.deploy_operation import (
    DeployWorkloadOperationRequest,
    DeployWorkloadOperationResult,
    DeployWorkloadOperationService,
)
from app.services.gitops.git_adapter import sanitize_git_output
from app.services.gitops.manifests import WORKLOAD_NAMESPACE


router = APIRouter(prefix="/gitops", tags=["gitops"])
SUCCESS_MESSAGE = "The GitOps change was pushed. Automatic Argo CD reconciliation is pending."
INTERNAL_ERROR_MESSAGE = "The GitOps deploy operation failed unexpectedly."
ERROR_STATUS_CODES = {
    "validation_failed": status.HTTP_400_BAD_REQUEST,
    "repo_write_failed": status.HTTP_409_CONFLICT,
    "render_failed": status.HTTP_400_BAD_REQUEST,
    "commit_failed": status.HTTP_409_CONFLICT,
    "push_failed": status.HTTP_502_BAD_GATEWAY,
}


@dataclass(frozen=True, slots=True)
class GitOpsDeployRepositoryConfig:
    repo_root: str
    source_root_relative: str
    expected_branch: str
    remote_name: str
    remote_branch: str


def get_gitops_deploy_repository_config() -> GitOpsDeployRepositoryConfig:
    if not settings.gitops_repo_root or not settings.gitops_repo_root.strip():
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="The GitOps repository is not configured.",
        )
    return GitOpsDeployRepositoryConfig(
        repo_root=settings.gitops_repo_root,
        source_root_relative=settings.gitops_source_root,
        expected_branch=settings.gitops_branch,
        remote_name=settings.gitops_remote,
        remote_branch=settings.gitops_remote_branch,
    )


def get_deploy_workload_operation_service() -> DeployWorkloadOperationService:
    return DeployWorkloadOperationService()


def _safe_response_source_path(value: object) -> str:
    if (
        not isinstance(value, str)
        or not value
        or "\\" in value
        or any(ord(character) < 32 or ord(character) == 127 for character in value)
    ):
        return ""
    path = Path(value)
    windows_path = PureWindowsPath(value)
    if path.is_absolute() or windows_path.is_absolute() or windows_path.drive:
        return ""
    if any(part in {"", ".", ".."} or part.lower() == ".git" for part in path.parts):
        return ""
    return path.as_posix()


def _response_from_result(
    payload: GitOpsAppCreateRequest,
    config: GitOpsDeployRepositoryConfig,
    result: DeployWorkloadOperationResult,
) -> GitOpsAppCreateResponse:
    success = result.status == "pushed_waiting_for_argocd"
    return GitOpsAppCreateResponse(
        status=result.status,
        app_name=payload.app_name,
        namespace=WORKLOAD_NAMESPACE,
        source_path=_safe_response_source_path(config.source_root_relative),
        commit_sha=result.commit_sha,
        message=SUCCESS_MESSAGE if success else sanitize_git_output(result.message),
        error_code=result.error_code,
    )


@router.post(
    "/apps",
    response_model=GitOpsAppCreateResponse,
    status_code=status.HTTP_202_ACCEPTED,
    responses={
        status.HTTP_400_BAD_REQUEST: {"model": GitOpsAppCreateResponse},
        status.HTTP_409_CONFLICT: {"model": GitOpsAppCreateResponse},
        status.HTTP_500_INTERNAL_SERVER_ERROR: {"model": GitOpsAppCreateResponse},
        status.HTTP_502_BAD_GATEWAY: {"model": GitOpsAppCreateResponse},
    },
)
def create_gitops_app(
    payload: GitOpsAppCreateRequest,
    current_user: User = Depends(get_current_user),
    config: GitOpsDeployRepositoryConfig = Depends(get_gitops_deploy_repository_config),
    operation_service: DeployWorkloadOperationService = Depends(get_deploy_workload_operation_service),
) -> GitOpsAppCreateResponse | JSONResponse:
    _ = current_user
    # V1 local-first mode uses one server-configured worktree; per-user repository ownership is future work.
    try:
        result = operation_service.execute(
            DeployWorkloadOperationRequest(
                repo_root=config.repo_root,
                source_root_relative=config.source_root_relative,
                expected_branch=config.expected_branch,
                remote_name=config.remote_name,
                remote_branch=config.remote_branch,
                app_name=payload.app_name,
                image=payload.image,
                replicas=payload.replicas,
                container_port=payload.container_port,
                service_port=payload.service_port,
                service_type=payload.service_type,
            )
        )
    except Exception:
        response = GitOpsAppCreateResponse(
            status="internal_error",
            app_name=payload.app_name,
            namespace=WORKLOAD_NAMESPACE,
            source_path=_safe_response_source_path(config.source_root_relative),
            message=INTERNAL_ERROR_MESSAGE,
            error_code="internal_error",
        )
        return JSONResponse(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, content=response.model_dump())

    response = _response_from_result(payload, config, result)
    if result.status == "pushed_waiting_for_argocd":
        return response

    response_status = ERROR_STATUS_CODES.get(result.status, status.HTTP_500_INTERNAL_SERVER_ERROR)
    return JSONResponse(status_code=response_status, content=response.model_dump())
