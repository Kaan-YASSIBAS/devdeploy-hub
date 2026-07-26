from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from app.services.gitops.deploy_operation import DEFAULT_SOURCE_ROOT_RELATIVE
from app.services.gitops.errors import GitOpsWriterError
from app.services.gitops.git_adapter import GitAdapter, GitCommitRequest, GitPushRequest
from app.services.gitops.models import WorkloadWriteRequest
from app.services.gitops.writer import GitOpsWorkloadWriter, WorkloadWriteResult


UpdateOperationStatus = Literal[
    "validation_failed",
    "repo_write_failed",
    "render_failed",
    "commit_failed",
    "push_failed",
    "no_changes",
    "pushed_waiting_for_argocd",
]


@dataclass(frozen=True, slots=True)
class UpdateWorkloadOperationRequest:
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


@dataclass(frozen=True, slots=True)
class UpdateWorkloadOperationResult:
    status: UpdateOperationStatus
    app_name: str
    source_path: str
    expected_paths: tuple[str, ...]
    committed: bool
    pushed: bool
    commit_sha: str | None
    message: str
    error_code: str | None = None


class UpdateWorkloadOperationService:
    def __init__(self, *, git_adapter: GitAdapter | None = None):
        self.git_adapter = git_adapter or GitAdapter()

    def execute(self, request: UpdateWorkloadOperationRequest) -> UpdateWorkloadOperationResult:
        app_name = request.app_name if isinstance(request.app_name, str) else ""
        try:
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
            write_result = writer.update(workload_request)
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
            return UpdateWorkloadOperationResult(
                status="no_changes",
                app_name=workload_request.app_name,
                source_path=source_path,
                expected_paths=expected_paths,
                committed=False,
                pushed=False,
                commit_sha=current_commit_sha,
                message="The GitOps workload manifests already match the requested update.",
            )

        try:
            commit_result = self.git_adapter.create_commit(
                GitCommitRequest(
                    repo_root=repo_root,
                    expected_branch=request.expected_branch,
                    expected_paths=expected_paths,
                    commit_message=f"deploy: update {workload_request.app_name} workload",
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

        return UpdateWorkloadOperationResult(
            status="pushed_waiting_for_argocd",
            app_name=workload_request.app_name,
            source_path=source_path,
            expected_paths=expected_paths,
            committed=True,
            pushed=True,
            commit_sha=push_result.commit_sha,
            message="The workload update commit was pushed and is waiting for Argo CD reconciliation.",
        )

    @staticmethod
    def _resolve_source_root(repo_root: Path | str, source_root_relative: object) -> tuple[Path, Path, str]:
        from app.services.gitops.deploy_operation import DeployWorkloadOperationService

        return DeployWorkloadOperationService._resolve_source_root(repo_root, source_root_relative)

    @staticmethod
    def _expected_paths(source_path: str, app_name: str) -> tuple[str, ...]:
        from app.services.gitops.deploy_operation import DeployWorkloadOperationService

        return DeployWorkloadOperationService._expected_paths(source_path, app_name)

    @staticmethod
    def _verify_write_result(
        repo_root: Path,
        write_result: WorkloadWriteResult,
        expected_paths: tuple[str, ...],
    ) -> None:
        from app.services.gitops.deploy_operation import DeployWorkloadOperationService

        DeployWorkloadOperationService._verify_write_result(repo_root, write_result, expected_paths)

    @staticmethod
    def _failure(
        *,
        status: UpdateOperationStatus,
        app_name: str,
        source_path: str,
        expected_paths: tuple[str, ...],
        error: GitOpsWriterError,
        committed: bool = False,
        commit_sha: str | None = None,
    ) -> UpdateWorkloadOperationResult:
        return UpdateWorkloadOperationResult(
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
