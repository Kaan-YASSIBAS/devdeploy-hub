from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from typing import Iterator
from urllib.parse import quote

from app.services.gitops.errors import GitOpsWriterError
from app.services.gitops.git_adapter import _git_askpass_environment, sanitize_git_output


GITHUB_NAME_PATTERN = re.compile(r"^[A-Za-z0-9_.-]{1,100}$")
GIT_COMMAND_TIMEOUT_SECONDS = 60


@dataclass(frozen=True, slots=True)
class ManagedGitRepositoryLease:
    repo_root: Path
    github_token: str


class ManagedGitRepositoryError(RuntimeError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


class GitHubManagedRepository:
    def __init__(self, *, workspace_root: Path | str | None = None, timeout_seconds: int = GIT_COMMAND_TIMEOUT_SECONDS):
        self.workspace_root = Path(workspace_root) if workspace_root is not None else Path(tempfile.gettempdir()) / "devdeploy-gitops-workspaces"
        self.timeout_seconds = timeout_seconds

    @contextmanager
    def lease(self, *, owner: str, repo: str, branch: str, token: str) -> Iterator[ManagedGitRepositoryLease]:
        owner = self._validate_github_name(owner, "owner")
        repo = self._validate_github_name(repo, "repository")
        branch = self._validate_branch(branch)
        token = token.strip() if token and token.strip() else ""
        if not token:
            raise ManagedGitRepositoryError(
                "github_token_missing",
                "The GitOps GitHub token is not configured.",
            )

        try:
            self.workspace_root.mkdir(mode=0o700, parents=True, exist_ok=True)
            workspace = Path(tempfile.mkdtemp(prefix="operation-", dir=self.workspace_root))
        except OSError:
            raise ManagedGitRepositoryError(
                "workspace_unavailable",
                "The managed GitOps workspace could not be prepared.",
            ) from None

        repo_root = workspace / repo
        try:
            clone_url = f"https://github.com/{quote(owner, safe='')}/{quote(repo, safe='')}.git"
            result = self._run_git(
                (
                    "clone",
                    "--depth",
                    "1",
                    "--branch",
                    branch,
                    "--single-branch",
                    clone_url,
                    str(repo_root),
                ),
                cwd=workspace,
                token=token,
            )
            if result.returncode != 0:
                raise ManagedGitRepositoryError(
                    "git_clone_failed",
                    self._safe_message("The managed GitOps repository clone failed.", result),
                )

            for key, value in (
                ("user.name", "DevDeploy Hub"),
                ("user.email", "devdeploy@localhost"),
            ):
                config_result = self._run_git(("config", key, value), cwd=repo_root, token=token)
                if config_result.returncode != 0:
                    raise ManagedGitRepositoryError(
                        "git_config_failed",
                        self._safe_message("The managed GitOps repository identity could not be configured.", config_result),
                    )

            yield ManagedGitRepositoryLease(repo_root=repo_root, github_token=token)
        finally:
            shutil.rmtree(workspace, ignore_errors=True)

    def _run_git(self, arguments: tuple[str, ...], *, cwd: Path, token: str) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update(_git_askpass_environment(token))
        try:
            return subprocess.run(
                ["git", *arguments],
                cwd=cwd,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=self.timeout_seconds,
                check=False,
                env=env,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            return subprocess.CompletedProcess(
                args=["git", *arguments],
                returncode=-1,
                stdout="",
                stderr=str(error.__class__.__name__),
            )

    @staticmethod
    def _validate_github_name(value: object, label: str) -> str:
        if not isinstance(value, str) or not GITHUB_NAME_PATTERN.fullmatch(value):
            raise ManagedGitRepositoryError(
                f"github_{label}_invalid",
                f"The configured GitHub {label} is invalid.",
            )
        return value

    @staticmethod
    def _validate_branch(value: object) -> str:
        if (
            not isinstance(value, str)
            or not value
            or value.startswith("-")
            or len(value) > 255
            or any(character.isspace() for character in value)
            or ".." in value
            or "//" in value
            or "@{" in value
        ):
            raise ManagedGitRepositoryError(
                "github_branch_invalid",
                "The configured GitOps branch is invalid.",
            )
        return value

    @staticmethod
    def _safe_message(message: str, result: subprocess.CompletedProcess[str]) -> str:
        diagnostic = sanitize_git_output(result.stderr or result.stdout)
        return f"{message} {diagnostic}".strip() if diagnostic else message