from dataclasses import dataclass
from pathlib import Path, PureWindowsPath
from typing import Literal

from app.services.gitops.errors import GitOpsWriterError
from app.services.gitops.git_adapter import GitAdapter, GitCommitRequest, GitPushRequest
from app.services.gitops.models import WorkloadWriteRequest
from app.services.gitops.writer import GitOpsWorkloadWriter, WorkloadWriteResult


DEFAULT_SOURCE_ROOT_RELATIVE = "gitops/workloads/devdeploy-apps"
DeployOperationStatus = Literal[
    "validation_failed",
    "repo_write_failed",
    "render_failed",
    "commit_failed",
    "push_failed",
    "no_changes",
    "pushed_waiting_for_argocd",
]
DeployWriteMode = Literal["create", "recover", "reconcile", "restore_destroyed"]


@dataclass(frozen=True, slots=True)
class DeployWorkloadOperationRequest:
    repo_root: Path | str
    app_name: str
    image: str
    source_root_relative: str = DEFAULT_SOURCE_ROOT_RELATIVE
    expected_branch: str = "main"
    remote_name: str = "origin"
    remote_branch: str = "main"
    replicas: int = 1
    container_port: int = 80
    service_port: int = 80
    service_type: str = "ClusterIP"
    namespace: str = "devdeploy-apps"
    write_mode: DeployWriteMode = "create"


@dataclass(frozen=True, slots=True)
class DeployWorkloadOperationResult:
    status: DeployOperationStatus
    app_name: str
    source_path: str
    expected_paths: tuple[str, ...]
    committed: bool
    pushed: bool
    commit_sha: str | None
    message: str
    error_code: str | None = None


class DeployWorkloadOperationService:
    def __init__(self, *, git_adapter: GitAdapter | None = None):
        self.git_adapter = git_adapter or GitAdapter()

    def execute(self, request: DeployWorkloadOperationRequest) -> DeployWorkloadOperationResult:
        app_name = request.app_name if isinstance(request.app_name, str) else ""
        try:
            if request.write_mode not in ("create", "recover", "reconcile", "restore_destroyed"):
                raise GitOpsWriterError("invalid_write_mode", "The GitOps write mode is invalid.")
            workload_request = WorkloadWriteRequest(
                app_name=request.app_name,
                image=request.image,
                replicas=request.replicas,
                container_port=request.container_port,
                service_port=request.service_port,
                service_type=request.service_type,
                namespace=request.namespace,
            )
            repo_root, source_root, source_path = self._resolve_source_root(
                request.repo_root,
                request.source_root_relative,
            )
            expected_paths = self._expected_paths(source_path, workload_request.app_name)
            self.git_adapter.validate_push_target(
                remote_name=request.remote_name,
                remote_branch=request.remote_branch,
            )
        except GitOpsWriterError as error:
            return self._failure(
                status="validation_failed",
                app_name=app_name,
                source_path="",
                expected_paths=(),
                error=error,
            )

        try:
            self.git_adapter.validate_commit_preconditions(
                repo_root=repo_root,
                expected_branch=request.expected_branch,
                expected_paths=expected_paths,
            )
        except GitOpsWriterError as error:
            return self._failure(
                status="commit_failed",
                app_name=workload_request.app_name,
                source_path=source_path,
                expected_paths=expected_paths,
                error=error,
            )

        try:
            writer = GitOpsWorkloadWriter(source_root)
            if request.write_mode == "restore_destroyed":
                write_result = writer.restore_destroyed(workload_request)
            elif request.write_mode in ("recover", "reconcile"):
                write_result = writer.recover(workload_request)
            else:
                write_result = writer.create(workload_request)
            self._verify_write_result(repo_root, write_result, expected_paths)
        except GitOpsWriterError as error:
            return self._failure(
                status="render_failed" if error.code == "render_failed" else "repo_write_failed",
                app_name=workload_request.app_name,
                source_path=source_path,
                expected_paths=expected_paths,
                error=error,
            )

        if not write_result.changed:
            try:
                current_commit_sha = self.git_adapter.read_head(
                    repo_root=repo_root,
                    expected_branch=request.expected_branch,
                )
            except GitOpsWriterError as error:
                return self._failure(
                    status="commit_failed",
                    app_name=workload_request.app_name,
                    source_path=source_path,
                    expected_paths=expected_paths,
                    error=error,
                )
            return DeployWorkloadOperationResult(
                status="no_changes",
                app_name=workload_request.app_name,
                source_path=source_path,
                expected_paths=expected_paths,
                committed=False,
                pushed=False,
                commit_sha=current_commit_sha,
                message=(
                    "The GitOps workload manifests already match the requested reconcile state."
                    if request.write_mode == "reconcile"
                    else "The GitOps workload manifests already match the requested recovery state."
                ),
            )

        try:
            commit_result = self.git_adapter.create_commit(
                GitCommitRequest(
                    repo_root=repo_root,
                    expected_branch=request.expected_branch,
                    expected_paths=expected_paths,
                    commit_message=self._commit_message(
                        request.write_mode,
                        workload_request.app_name,
                    ),
                )
            )
        except GitOpsWriterError as error:
            return self._failure(
                status="commit_failed",
                app_name=workload_request.app_name,
                source_path=source_path,
                expected_paths=expected_paths,
                error=error,
            )

        if not commit_result.committed or not commit_result.commit_sha:
            return self._failure(
                status="commit_failed",
                app_name=workload_request.app_name,
                source_path=source_path,
                expected_paths=expected_paths,
                error=GitOpsWriterError(
                    "git_commit_failed",
                    "The local Git commit result could not be verified.",
                ),
            )

        try:
            push_result = self.git_adapter.push(
                GitPushRequest(
                    repo_root=repo_root,
                    expected_branch=request.expected_branch,
                    remote_name=request.remote_name,
                    remote_branch=request.remote_branch,
                    expected_commit_sha=commit_result.commit_sha,
                )
            )
        except GitOpsWriterError as error:
            return self._failure(
                status="push_failed",
                app_name=workload_request.app_name,
                source_path=source_path,
                expected_paths=expected_paths,
                error=error,
                committed=True,
                commit_sha=commit_result.commit_sha,
            )

        return DeployWorkloadOperationResult(
            status="pushed_waiting_for_argocd",
            app_name=workload_request.app_name,
            source_path=source_path,
            expected_paths=expected_paths,
            committed=True,
            pushed=True,
            commit_sha=push_result.commit_sha,
            message="The workload commit was pushed and is waiting for Argo CD reconciliation.",
        )

    @staticmethod
    def _commit_message(write_mode: DeployWriteMode, app_name: str) -> str:
        if write_mode == "recover":
            return f"recover: restore {app_name} workload"
        if write_mode == "restore_destroyed":
            return f"recover: reactivate {app_name} workload"
        if write_mode == "reconcile":
            return f"reconcile: align {app_name} workload"
        return f"deploy: add {app_name} workload"

    @staticmethod
    def _resolve_source_root(repo_root: Path | str, source_root_relative: object) -> tuple[Path, Path, str]:
        try:
            resolved_repo = Path(repo_root).resolve(strict=True)
        except (OSError, RuntimeError, TypeError):
            raise GitOpsWriterError("repo_not_configured", "The configured Git repository is unavailable.") from None
        if not resolved_repo.is_dir():
            raise GitOpsWriterError("repo_not_configured", "The configured Git repository is not a directory.")
        if (
            not isinstance(source_root_relative, str)
            or not source_root_relative
            or "\\" in source_root_relative
            or any(ord(character) < 32 or ord(character) == 127 for character in source_root_relative)
        ):
            raise GitOpsWriterError("unsafe_path", "The configured GitOps source path is invalid.")

        relative_path = Path(source_root_relative)
        windows_path = PureWindowsPath(source_root_relative)
        if relative_path.is_absolute() or windows_path.is_absolute() or windows_path.drive:
            raise GitOpsWriterError("unsafe_path", "The configured GitOps source path must be relative.")
        if any(part in {"", ".", ".."} or part.lower() == ".git" for part in relative_path.parts):
            raise GitOpsWriterError("unsafe_path", "The configured GitOps source path is not allowed.")

        try:
            source_root = (resolved_repo / relative_path).resolve(strict=True)
            source_root.relative_to(resolved_repo)
        except (OSError, RuntimeError, ValueError):
            raise GitOpsWriterError("repo_not_configured", "The configured GitOps source root is unavailable.") from None
        if not source_root.is_dir():
            raise GitOpsWriterError("repo_not_configured", "The configured GitOps source root is not a directory.")
        return resolved_repo, source_root, relative_path.as_posix()

    @staticmethod
    def _expected_paths(source_path: str, app_name: str) -> tuple[str, ...]:
        app_path = f"{source_path}/apps/{app_name}"
        return (
            f"{source_path}/kustomization.yaml",
            f"{app_path}/kustomization.yaml",
            f"{app_path}/deployment.yaml",
            f"{app_path}/service.yaml",
        )

    @staticmethod
    def _verify_write_result(
        repo_root: Path,
        write_result: WorkloadWriteResult,
        expected_paths: tuple[str, ...],
    ) -> None:
        try:
            actual_paths = {
                write_result.root_kustomization.resolve(strict=True).relative_to(repo_root).as_posix(),
                *(path.resolve(strict=True).relative_to(repo_root).as_posix() for path in write_result.written_files),
            }
        except (OSError, RuntimeError, ValueError):
            raise GitOpsWriterError("unsafe_path", "The writer returned an unsafe GitOps path.") from None
        if actual_paths != set(expected_paths):
            raise GitOpsWriterError("unsafe_path", "The writer changed an unexpected GitOps path.")

    @staticmethod
    def _failure(
        *,
        status: DeployOperationStatus,
        app_name: str,
        source_path: str,
        expected_paths: tuple[str, ...],
        error: GitOpsWriterError,
        committed: bool = False,
        commit_sha: str | None = None,
    ) -> DeployWorkloadOperationResult:
        return DeployWorkloadOperationResult(
            status=status,
            app_name=app_name,
            source_path=source_path,
            expected_paths=expected_paths,
            committed=committed,
            pushed=False,
            commit_sha=commit_sha,
            message=error.message,
            error_code=error.code,
        )
