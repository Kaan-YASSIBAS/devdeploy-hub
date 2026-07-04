from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path, PureWindowsPath

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.responses import JSONResponse

from app.core.config import settings
from app.core.deps import get_current_user
from app.models.user import User
from app.schemas.gitops_app import (
    GitOpsAppCreateRequest,
    GitOpsAppCreateResponse,
    GitOpsAppStatusResponse,
    GitOpsRootApplicationStatusResponse,
    GitOpsWorkloadStatusResponse,
)
from app.services.gitops.deploy_operation import (
    DeployWorkloadOperationRequest,
    DeployWorkloadOperationResult,
    DeployWorkloadOperationService,
)
from app.services.gitops.git_adapter import sanitize_git_output
from app.services.gitops.manifests import WORKLOAD_NAMESPACE
from app.services.gitops.kubernetes_status_reader import KubernetesGitOpsStatusReader
from app.services.gitops.status_reader import (
    GitOpsStatusError,
    GitOpsStatusEvaluator,
    GitOpsStatusRequest,
    GitOpsStatusResult,
    GitOpsStatusService,
)


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


@dataclass(frozen=True, slots=True)
class GitOpsStatusReaderConfig:
    root_application_name: str
    root_application_namespace: str
    workload_namespace: str


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


def get_gitops_status_reader_config() -> GitOpsStatusReaderConfig:
    return GitOpsStatusReaderConfig(
        root_application_name=settings.argocd_root_application_name,
        root_application_namespace=settings.argocd_namespace,
        workload_namespace=settings.workload_namespace,
    )


@lru_cache(maxsize=1)
def get_gitops_status_service() -> GitOpsStatusService:
    if settings.status_reader_mode == "unavailable":
        return GitOpsStatusService()
    try:
        reader = KubernetesGitOpsStatusReader.from_server_config(
            management_kubeconfig=settings.management_kubeconfig,
            management_kubeconfig_context=settings.management_kubeconfig_context,
            workload_kubeconfig=settings.workload_kubeconfig,
            workload_kubeconfig_context=settings.workload_kubeconfig_context,
            use_in_cluster_management=settings.kubernetes_in_cluster,
        )
    except GitOpsStatusError:
        return GitOpsStatusService()
    return GitOpsStatusService(reader=reader)


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


def _status_response_from_result(result: GitOpsStatusResult) -> GitOpsAppStatusResponse:
    return GitOpsAppStatusResponse(
        status=result.status,
        app_name=result.app_name,
        namespace=result.namespace,
        commit_sha=result.commit_sha,
        observed_revision=result.observed_revision,
        root_application=GitOpsRootApplicationStatusResponse(
            name=result.root_application.name,
            sync_status=result.root_application.sync_status,
            health_status=result.root_application.health_status,
            observed_commit_match=result.root_application.observed_commit_match,
        ),
        workload=GitOpsWorkloadStatusResponse(
            deployment_ready=result.workload.deployment_ready,
            service_ready=result.workload.service_ready,
            pods_ready=result.workload.pods_ready,
            desired_replicas=result.workload.desired_replicas,
            ready_replicas=result.workload.ready_replicas,
            available_replicas=result.workload.available_replicas,
            pod_count=result.workload.pod_count,
            ready_pod_count=result.workload.ready_pod_count,
        ),
        message=sanitize_git_output(result.message),
        error_code=result.error_code,
    )


@router.get(
    "/apps/{app_name}/status",
    response_model=GitOpsAppStatusResponse,
    responses={
        status.HTTP_400_BAD_REQUEST: {"description": "Invalid app name or commit SHA"},
        status.HTTP_403_FORBIDDEN: {"model": GitOpsAppStatusResponse},
        status.HTTP_503_SERVICE_UNAVAILABLE: {"model": GitOpsAppStatusResponse},
    },
)
def get_gitops_app_status(
    app_name: str,
    commit_sha: str,
    current_user: User = Depends(get_current_user),
    config: GitOpsStatusReaderConfig = Depends(get_gitops_status_reader_config),
    status_service: GitOpsStatusService = Depends(get_gitops_status_service),
) -> GitOpsAppStatusResponse | JSONResponse:
    _ = current_user
    try:
        request = GitOpsStatusRequest(
            app_name=app_name,
            commit_sha=commit_sha,
            namespace=config.workload_namespace,
            root_application_name=config.root_application_name,
            root_application_namespace=config.root_application_namespace,
        )
    except GitOpsStatusError as error:
        response_status = (
            status.HTTP_503_SERVICE_UNAVAILABLE
            if error.code == "status_configuration_invalid"
            else status.HTTP_400_BAD_REQUEST
        )
        raise HTTPException(status_code=response_status, detail=error.message) from None

    try:
        result = status_service.read_status(request)
    except Exception:
        result = GitOpsStatusEvaluator.unavailable_result(request, "status_reader_unavailable")

    response = _status_response_from_result(result)
    if result.error_code == "permission_denied":
        return JSONResponse(status_code=status.HTTP_403_FORBIDDEN, content=response.model_dump())
    if result.error_code == "status_reader_unavailable":
        return JSONResponse(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, content=response.model_dump())
    return response


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
