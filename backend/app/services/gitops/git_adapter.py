from dataclasses import dataclass
from pathlib import Path, PureWindowsPath
import re
import subprocess
from typing import Sequence

from app.services.gitops.errors import GitOpsWriterError


MAX_COMMIT_MESSAGE_LENGTH = 200
MAX_EXPECTED_PATHS = 64
GIT_TIMEOUT_SECONDS = 15
CONTROL_CHARACTER_PATTERN = re.compile(r"[\x00-\x1f\x7f]")
URL_CREDENTIAL_PATTERN = re.compile(r"(?i)\b([a-z][a-z0-9+.-]*://)[^/@\s]+@")
KEY_VALUE_SECRET_PATTERN = re.compile(
    r"(?i)\b(token|password|passwd|secret|authorization)\s*[:=]\s*[^\s,;]+"
)
BEARER_PATTERN = re.compile(r"(?i)\bbearer\s+[^\s,;]+")
TOKEN_PATTERN = re.compile(r"(?i)\b(?:github_pat_|gh[pousr]_)[a-z0-9_]+")
REMOTE_NAME_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
BRANCH_NAME_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]{0,254}$")
PUSH_REJECTION_PATTERN = re.compile(r"(?i)(?:\[rejected\]|non-fast-forward|fetch first)")
ALLOWED_GIT_COMMANDS = frozenset({"add", "commit", "diff", "ls-files", "push", "rev-parse"})
OPERATION_MARKERS = ("MERGE_HEAD", "CHERRY_PICK_HEAD", "rebase-merge", "rebase-apply")


@dataclass(frozen=True, slots=True)
class GitCommitRequest:
    repo_root: Path | str
    expected_paths: tuple[str, ...]
    commit_message: str
    expected_branch: str = "main"


@dataclass(frozen=True, slots=True)
class GitCommitResult:
    committed: bool
    commit_sha: str | None
    message: str


@dataclass(frozen=True, slots=True)
class GitPushRequest:
    repo_root: Path | str
    expected_branch: str = "main"
    remote_name: str = "origin"
    remote_branch: str = "main"
    expected_commit_sha: str | None = None


@dataclass(frozen=True, slots=True)
class GitPushResult:
    pushed: bool
    commit_sha: str
    remote_name: str
    remote_branch: str
    message: str


@dataclass(frozen=True, slots=True)
class _GitCommandResult:
    return_code: int
    stdout: str
    stderr: str


def sanitize_git_output(value: object) -> str:
    """Return a bounded diagnostic string with common credential forms redacted."""
    if not isinstance(value, str):
        return ""
    sanitized = URL_CREDENTIAL_PATTERN.sub(r"\1<redacted>@", value)
    sanitized = KEY_VALUE_SECRET_PATTERN.sub(lambda match: f"{match.group(1)}=<redacted>", sanitized)
    sanitized = BEARER_PATTERN.sub("Bearer <redacted>", sanitized)
    sanitized = TOKEN_PATTERN.sub("<redacted>", sanitized)
    sanitized = " ".join(sanitized.split())
    return sanitized[:500]


class GitAdapter:
    def __init__(self, *, timeout_seconds: int = GIT_TIMEOUT_SECONDS):
        self.timeout_seconds = timeout_seconds

    def create_commit(self, request: GitCommitRequest) -> GitCommitResult:
        repo_root = self._validate_repository(request.repo_root)
        self._validate_operation_state(repo_root)
        self._validate_branch(repo_root, request.expected_branch)
        expected_paths = self._validate_expected_paths(repo_root, request.expected_paths)
        commit_message = self._validate_commit_message(request.commit_message)
        self._validate_changed_paths(repo_root, expected_paths)

        stage_result = self._run_git(("add", "--", *expected_paths), cwd=repo_root)
        if stage_result.return_code != 0:
            raise GitOpsWriterError(
                "git_stage_failed",
                self._safe_failure_message("Git could not stage the expected GitOps paths.", stage_result),
            )

        staged_paths = self._path_set_from_git(
            self._require_git_success(
                ("diff", "--cached", "--name-only", "-z", "--"),
                cwd=repo_root,
                code="git_stage_failed",
                message="Git could not verify the staged GitOps paths.",
            ).stdout
        )
        if not staged_paths:
            raise GitOpsWriterError("git_no_changes", "The expected GitOps paths contain no changes to commit.")
        if not staged_paths.issubset(set(expected_paths)):
            raise GitOpsWriterError(
                "git_unexpected_changes",
                "The Git index contains changes outside the expected GitOps paths.",
            )

        commit_result = self._run_git(("commit", "-m", commit_message), cwd=repo_root)
        if commit_result.return_code != 0:
            raise GitOpsWriterError(
                "git_commit_failed",
                self._safe_failure_message("Git could not create the local commit.", commit_result),
            )

        revision = self._require_git_success(
            ("rev-parse", "HEAD"),
            cwd=repo_root,
            code="git_commit_failed",
            message="Git created a commit but its revision could not be verified.",
        ).stdout.strip()
        if not re.fullmatch(r"[0-9a-fA-F]{40,64}", revision):
            raise GitOpsWriterError(
                "git_commit_failed",
                "Git created a commit but returned an invalid revision.",
            )

        return GitCommitResult(
            committed=True,
            commit_sha=revision.lower(),
            message="The GitOps changes were committed locally.",
        )

    def read_head(self, *, repo_root: Path | str, expected_branch: str) -> str:
        resolved_root = self._validate_repository(repo_root)
        self._validate_operation_state(resolved_root)
        self._validate_branch(resolved_root, expected_branch)
        return self._read_head_sha(resolved_root)

    def validate_commit_preconditions(
        self,
        *,
        repo_root: Path | str,
        expected_branch: str,
        expected_paths: Sequence[str],
    ) -> None:
        resolved_root = self._validate_repository(repo_root)
        self._validate_operation_state(resolved_root)
        self._validate_branch(resolved_root, expected_branch)
        normalized_paths = self._validate_expected_paths(resolved_root, expected_paths)
        self._validate_changed_paths(resolved_root, normalized_paths)

    def validate_push_target(self, *, remote_name: str, remote_branch: str) -> None:
        self._validate_remote_name(remote_name)
        self._validate_remote_branch(remote_branch)

    def push(self, request: GitPushRequest) -> GitPushResult:
        repo_root = self._validate_repository(request.repo_root)
        self._validate_operation_state(repo_root)
        self._validate_branch(repo_root, request.expected_branch)
        remote_name = self._validate_remote_name(request.remote_name)
        remote_branch = self._validate_remote_branch(request.remote_branch)
        commit_sha = self._read_head_sha(repo_root)

        if request.expected_commit_sha is not None:
            expected_commit_sha = self._validate_commit_sha(request.expected_commit_sha)
            if commit_sha != expected_commit_sha:
                raise GitOpsWriterError(
                    "git_head_mismatch",
                    "The local Git HEAD does not match the expected commit.",
                )

        push_result = self._run_git(
            ("push", remote_name, f"HEAD:{remote_branch}"),
            cwd=repo_root,
        )
        if push_result.return_code != 0:
            diagnostic = f"{push_result.stderr}\n{push_result.stdout}"
            if PUSH_REJECTION_PATTERN.search(diagnostic):
                raise GitOpsWriterError(
                    "git_push_rejected",
                    self._safe_failure_message(
                        "The remote rejected the GitOps commit without updating the branch.",
                        push_result,
                    ),
                )
            raise GitOpsWriterError(
                "git_push_failed",
                self._safe_failure_message("The GitOps commit could not be pushed.", push_result),
            )

        return GitPushResult(
            pushed=True,
            commit_sha=commit_sha,
            remote_name=remote_name,
            remote_branch=remote_branch,
            message="The GitOps commit was pushed successfully.",
        )

    def _validate_repository(self, repo_root: Path | str) -> Path:
        try:
            resolved_root = Path(repo_root).resolve(strict=True)
        except (OSError, RuntimeError, TypeError):
            raise GitOpsWriterError("git_repo_invalid", "The configured Git repository is unavailable.") from None
        if not resolved_root.is_dir():
            raise GitOpsWriterError("git_repo_invalid", "The configured Git repository is not a directory.")

        inside_result = self._run_git(("rev-parse", "--is-inside-work-tree"), cwd=resolved_root)
        top_level_result = self._run_git(("rev-parse", "--show-toplevel"), cwd=resolved_root)
        if inside_result.return_code != 0 or inside_result.stdout.strip().lower() != "true":
            raise GitOpsWriterError("git_repo_invalid", "The configured path is not a Git worktree.")
        if top_level_result.return_code != 0:
            raise GitOpsWriterError("git_repo_invalid", "The Git worktree root could not be verified.")
        try:
            top_level = Path(top_level_result.stdout.strip()).resolve(strict=True)
        except (OSError, RuntimeError):
            raise GitOpsWriterError("git_repo_invalid", "The Git worktree root could not be verified.") from None
        if top_level != resolved_root:
            raise GitOpsWriterError("git_repo_invalid", "The configured path must be the Git worktree root.")
        return resolved_root

    def _validate_operation_state(self, repo_root: Path) -> None:
        git_dir_result = self._require_git_success(
            ("rev-parse", "--git-dir"),
            cwd=repo_root,
            code="git_repo_invalid",
            message="The Git metadata directory could not be verified.",
        )
        git_dir = Path(git_dir_result.stdout.strip())
        if not git_dir.is_absolute():
            git_dir = repo_root / git_dir
        try:
            resolved_git_dir = git_dir.resolve(strict=True)
        except (OSError, RuntimeError):
            raise GitOpsWriterError("git_repo_invalid", "The Git metadata directory is unavailable.") from None
        if any((resolved_git_dir / marker).exists() for marker in OPERATION_MARKERS):
            raise GitOpsWriterError(
                "git_operation_in_progress",
                "A merge, rebase, or cherry-pick is already in progress.",
            )

    def _validate_branch(self, repo_root: Path, expected_branch: object) -> None:
        if not self._is_safe_branch_name(expected_branch):
            raise GitOpsWriterError("git_branch_mismatch", "The expected Git branch is invalid.")
        branch_result = self._require_git_success(
            ("rev-parse", "--abbrev-ref", "HEAD"),
            cwd=repo_root,
            code="git_repo_invalid",
            message="The current Git branch could not be determined.",
        )
        if branch_result.stdout.strip() != expected_branch:
            raise GitOpsWriterError(
                "git_branch_mismatch",
                "The current Git branch does not match the configured branch.",
            )

    @staticmethod
    def _validate_remote_name(remote_name: object) -> str:
        if not isinstance(remote_name, str) or not REMOTE_NAME_PATTERN.fullmatch(remote_name):
            raise GitOpsWriterError("git_remote_invalid", "The configured Git remote name is invalid.")
        return remote_name

    @classmethod
    def _validate_remote_branch(cls, remote_branch: object) -> str:
        if not cls._is_safe_branch_name(remote_branch):
            raise GitOpsWriterError("git_remote_branch_invalid", "The configured remote branch is invalid.")
        return remote_branch

    @staticmethod
    def _is_safe_branch_name(branch: object) -> bool:
        if not isinstance(branch, str) or not BRANCH_NAME_PATTERN.fullmatch(branch):
            return False
        if ".." in branch or "//" in branch or "@{" in branch:
            return False
        parts = branch.split("/")
        return not (
            branch.endswith(("/", "."))
            or any(part.startswith(".") or part.endswith(".lock") for part in parts)
        )

    @staticmethod
    def _validate_commit_sha(commit_sha: object) -> str:
        if not isinstance(commit_sha, str) or not re.fullmatch(r"[0-9a-fA-F]{40,64}", commit_sha):
            raise GitOpsWriterError("git_head_mismatch", "The expected Git commit is invalid.")
        return commit_sha.lower()

    def _read_head_sha(self, repo_root: Path) -> str:
        result = self._require_git_success(
            ("rev-parse", "HEAD"),
            cwd=repo_root,
            code="git_repo_invalid",
            message="The local Git HEAD could not be read.",
        )
        commit_sha = result.stdout.strip().lower()
        if not re.fullmatch(r"[0-9a-f]{40,64}", commit_sha):
            raise GitOpsWriterError("git_repo_invalid", "The local Git HEAD is invalid.")
        return commit_sha

    def _validate_expected_paths(self, repo_root: Path, paths: object) -> tuple[str, ...]:
        if not isinstance(paths, (tuple, list)) or not paths or len(paths) > MAX_EXPECTED_PATHS:
            raise GitOpsWriterError("git_path_invalid", "Expected GitOps paths are required.")

        normalized_paths: list[str] = []
        seen: set[str] = set()
        for value in paths:
            if not isinstance(value, str) or not value or "\\" in value or CONTROL_CHARACTER_PATTERN.search(value):
                raise GitOpsWriterError("git_path_invalid", "An expected GitOps path is invalid.")
            path = Path(value)
            windows_path = PureWindowsPath(value)
            if path.is_absolute() or windows_path.is_absolute() or windows_path.drive:
                raise GitOpsWriterError("git_path_invalid", "Expected GitOps paths must be relative.")
            if any(part in {"", ".", ".."} or part.lower() == ".git" for part in path.parts):
                raise GitOpsWriterError("git_path_invalid", "An expected GitOps path is not allowed.")

            normalized = path.as_posix()
            try:
                candidate = (repo_root / path).resolve(strict=False)
                candidate.relative_to(repo_root)
            except (OSError, RuntimeError, ValueError):
                raise GitOpsWriterError(
                    "git_path_invalid",
                    "An expected GitOps path resolves outside the repository.",
                ) from None
            if candidate.exists() and candidate.is_dir():
                raise GitOpsWriterError("git_path_invalid", "Expected GitOps paths must identify files.")
            if normalized not in seen:
                normalized_paths.append(normalized)
                seen.add(normalized)
        return tuple(normalized_paths)

    @staticmethod
    def _validate_commit_message(message: object) -> str:
        if (
            not isinstance(message, str)
            or not message.strip()
            or len(message) > MAX_COMMIT_MESSAGE_LENGTH
            or CONTROL_CHARACTER_PATTERN.search(message)
        ):
            raise GitOpsWriterError(
                "git_commit_failed",
                "The Git commit message is invalid.",
            )
        return message.strip()

    def _changed_paths(self, repo_root: Path) -> set[str]:
        commands = (
            ("diff", "--name-only", "-z", "--"),
            ("diff", "--cached", "--name-only", "-z", "--"),
            ("ls-files", "--others", "--exclude-standard", "-z", "--"),
        )
        changed: set[str] = set()
        for command in commands:
            result = self._require_git_success(
                command,
                cwd=repo_root,
                code="git_repo_invalid",
                message="The Git worktree state could not be verified.",
            )
            changed.update(self._path_set_from_git(result.stdout))
        return changed

    def _validate_changed_paths(self, repo_root: Path, expected_paths: Sequence[str]) -> None:
        if not self._changed_paths(repo_root).issubset(set(expected_paths)):
            raise GitOpsWriterError(
                "git_unexpected_changes",
                "The Git worktree contains changes outside the expected GitOps paths.",
            )

    @staticmethod
    def _path_set_from_git(output: str) -> set[str]:
        return {path for path in output.split("\0") if path}

    def _require_git_success(
        self,
        arguments: Sequence[str],
        *,
        cwd: Path,
        code: str,
        message: str,
    ) -> _GitCommandResult:
        result = self._run_git(arguments, cwd=cwd)
        if result.return_code != 0:
            raise GitOpsWriterError(code, self._safe_failure_message(message, result))
        return result

    def _run_git(self, arguments: Sequence[str], *, cwd: Path) -> _GitCommandResult:
        if not arguments or arguments[0] not in ALLOWED_GIT_COMMANDS:
            raise GitOpsWriterError("git_commit_failed", "The requested Git command is not allowed.")
        try:
            completed = subprocess.run(
                ["git", *arguments],
                cwd=cwd,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=self.timeout_seconds,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            return _GitCommandResult(
                return_code=-1,
                stdout="",
                stderr="Git command execution failed or timed out.",
            )
        return _GitCommandResult(
            return_code=completed.returncode,
            stdout=completed.stdout,
            stderr=completed.stderr,
        )

    @staticmethod
    def _safe_failure_message(message: str, result: _GitCommandResult) -> str:
        diagnostic = sanitize_git_output(result.stderr or result.stdout)
        return f"{message} {diagnostic}".strip() if diagnostic else message
