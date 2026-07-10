from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from app.services.gitops.deploy_operation import DEFAULT_SOURCE_ROOT_RELATIVE, DeployWorkloadOperationService
from app.services.gitops.errors import GitOpsWriterError
from app.services.gitops.git_adapter import GitAdapter, GitCommitRequest, GitPushRequest
from app.services.gitops.models import validate_app_name
from app.services.gitops.writer import GitOpsWorkloadWriter, WorkloadDestroyResult


DestroyOperationStatus = Literal[
    "validation_failed",
    "repo_write_failed",
    "commit_failed",
    "push_failed",
    "no_changes",
    "pushed_waiting_for_argocd",
]


@dataclass(frozen=True, slots=True)
class DestroyWorkloadOperationRequest:
    repo_root: Path | str
    app_name: str
    source_root_relative: str = DEFAULT_SOURCE_ROOT_RELATIVE
    expected_branch: str = "main"
    remote_name: str = "origin"
    remote_branch: str = "main"


@dataclass(frozen=True, slots=True)
class DestroyWorkloadOperationResult:
    status: DestroyOperationStatus
    app_name: str
    source_path: str
    expected_paths: tuple[str, ...]
    committed: bool
    pushed: bool
    commit_sha: str | None
    message: str
    error_code: str | None = None


class DestroyWorkloadOperationService:
    def __init__(self, *, git_adapter: GitAdapter | None = None):
        self.git_adapter = git_adapter or GitAdapter()

    def execute(self, request: DestroyWorkloadOperationRequest) -> DestroyWorkloadOperationResult:
        app_name = request.app_name if isinstance(request.app_name, str) else ""
        try:
            validated_app_name = validate_app_name(request.app_name)
            repo_root, source_root, source_path = DeployWorkloadOperationService._resolve_source_root(
                request.repo_root,
                request.source_root_relative,
            )
            expected_paths = self._expected_paths(source_root, source_path, validated_app_name)
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
                app_name=validated_app_name,
                source_path=source_path,
                expected_paths=expected_paths,
                error=error,
            )

        try:
            writer = GitOpsWorkloadWriter(source_root)
            write_result = writer.destroy(validated_app_name)
            self._verify_destroy_result(repo_root, write_result, expected_paths)
        except GitOpsWriterError as error:
            return self._failure(
                status="repo_write_failed",
                app_name=validated_app_name,
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
                    app_name=validated_app_name,
                    source_path=source_path,
                    expected_paths=expected_paths,
                    error=error,
                )
            return DestroyWorkloadOperationResult(
                status="no_changes",
                app_name=validated_app_name,
                source_path=source_path,
                expected_paths=expected_paths,
                committed=False,
                pushed=False,
                commit_sha=current_commit_sha,
                message="The GitOps workload manifests were already absent.",
            )

        try:
            commit_result = self.git_adapter.create_commit(
                GitCommitRequest(
                    repo_root=repo_root,
                    expected_branch=request.expected_branch,
                    expected_paths=expected_paths,
                    commit_message=f"destroy: remove {validated_app_name} workload",
                )
            )
        except GitOpsWriterError as error:
            return self._failure(
                status="commit_failed",
                app_name=validated_app_name,
                source_path=source_path,
                expected_paths=expected_paths,
                error=error,
            )

        if not commit_result.committed or not commit_result.commit_sha:
            return self._failure(
                status="commit_failed",
                app_name=validated_app_name,
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
                app_name=validated_app_name,
                source_path=source_path,
                expected_paths=expected_paths,
                error=error,
                committed=True,
                commit_sha=commit_result.commit_sha,
            )

        return DestroyWorkloadOperationResult(
            status="pushed_waiting_for_argocd",
            app_name=validated_app_name,
            source_path=source_path,
            expected_paths=expected_paths,
            committed=True,
            pushed=True,
            commit_sha=push_result.commit_sha,
            message="The workload removal commit was pushed.",
        )

    @staticmethod
    def _expected_paths(source_root: Path, source_path: str, app_name: str) -> tuple[str, ...]:
        app_dir = source_root / "apps" / app_name
        paths = [f"{source_path}/kustomization.yaml"]
        if app_dir.exists():
            for file_name in ("kustomization.yaml", "deployment.yaml", "service.yaml"):
                file_path = app_dir / file_name
                if file_path.exists():
                    paths.append(f"{source_path}/apps/{app_name}/{file_name}")
        return tuple(paths)

    @staticmethod
    def _verify_destroy_result(
        repo_root: Path,
        write_result: WorkloadDestroyResult,
        expected_paths: tuple[str, ...],
    ) -> None:
        try:
            actual_paths = {
                write_result.root_kustomization.resolve(strict=True).relative_to(repo_root).as_posix(),
                *(
                    path.resolve(strict=False).relative_to(repo_root).as_posix()
                    for path in write_result.removed_files
                ),
            }
        except (OSError, RuntimeError, ValueError):
            raise GitOpsWriterError("unsafe_path", "The writer returned an unsafe GitOps path.") from None
        if actual_paths != set(expected_paths):
            raise GitOpsWriterError("unsafe_path", "The writer changed an unexpected GitOps path.")

    @staticmethod
    def _failure(
        *,
        status: DestroyOperationStatus,
        app_name: str,
        source_path: str,
        expected_paths: tuple[str, ...],
        error: GitOpsWriterError,
        committed: bool = False,
        commit_sha: str | None = None,
    ) -> DestroyWorkloadOperationResult:
        return DestroyWorkloadOperationResult(
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
