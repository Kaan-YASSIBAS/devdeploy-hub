from pathlib import Path
import re
import subprocess
import tempfile
import unittest

from app.services.gitops.errors import GitOpsWriterError
from app.services.gitops.git_adapter import (
    _GitCommandResult,
    GitAdapter,
    GitCommitRequest,
    GitPushRequest,
    sanitize_git_output,
)


class RecordingGitAdapter(GitAdapter):
    def __init__(self) -> None:
        super().__init__()
        self.commands: list[tuple[str, ...]] = []

    def _run_git(self, arguments, *, cwd):
        self.commands.append(tuple(arguments))
        return super()._run_git(arguments, cwd=cwd)


class CredentialFailureGitAdapter(GitAdapter):
    def _run_git(self, arguments, *, cwd):
        if arguments and arguments[0] == "push":
            return _GitCommandResult(
                return_code=1,
                stdout="",
                stderr=(
                    "fatal: unable to access "
                    "https://user:super-secret@example.invalid/repository.git token=plain-token"
                ),
            )
        return super()._run_git(arguments, cwd=cwd)


class GitAdapterTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.test_root = Path(self.temporary_directory.name)
        self.repo_root = self.test_root / "worktree"
        self.repo_root.mkdir()
        self._git("init", "--initial-branch=main")
        self._git("config", "user.name", "DevDeploy Test")
        self._git("config", "user.email", "devdeploy-test@example.invalid")
        self._write("README.md", "test repository\n")
        self._git("add", "--", "README.md")
        self._git("commit", "-m", "test: initialize repository")

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def _git(self, *arguments: str) -> str:
        return self._run_git(self.repo_root, *arguments)

    def _run_git(self, cwd: Path, *arguments: str) -> str:
        completed = subprocess.run(
            ["git", *arguments],
            cwd=cwd,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=10,
            check=False,
        )
        if completed.returncode != 0:
            self.fail(f"Test repository Git command failed: {completed.stderr}")
        return completed.stdout

    def _create_bare_remote(self) -> Path:
        remote = self.test_root / "remote.git"
        remote.mkdir()
        self._run_git(remote, "init", "--bare", "--initial-branch=main")
        self._git("remote", "add", "origin", str(remote))
        return remote

    def _create_local_commit(self, relative_path: str = "expected.yaml") -> str:
        self._write(relative_path, "kind: Service\n")
        result = GitAdapter().create_commit(self.request(relative_path))
        return result.commit_sha or ""

    def _write(self, relative_path: str, content: str) -> None:
        target = self.repo_root / relative_path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8", newline="\n")

    def assert_error_code(self, code: str, callback) -> None:
        with self.assertRaises(GitOpsWriterError) as raised:
            callback()
        self.assertEqual(raised.exception.code, code)

    def request(self, *paths: str, branch: str = "main") -> GitCommitRequest:
        return GitCommitRequest(
            repo_root=self.repo_root,
            expected_branch=branch,
            expected_paths=tuple(paths),
            commit_message="deploy: add nginx-demo workload",
        )

    def test_valid_commit_returns_sha_and_commits_only_expected_files(self) -> None:
        deployment = "gitops/workloads/devdeploy-apps/apps/nginx-demo/deployment.yaml"
        service = "gitops/workloads/devdeploy-apps/apps/nginx-demo/service.yaml"
        self._write(deployment, "kind: Deployment\n")
        self._write(service, "kind: Service\n")
        adapter = RecordingGitAdapter()

        result = adapter.create_commit(self.request(deployment, service))

        self.assertTrue(result.committed)
        self.assertRegex(result.commit_sha or "", r"^[0-9a-f]{40,64}$")
        committed_paths = set(self._git("show", "--format=", "--name-only", "-z", "HEAD").split("\0"))
        self.assertEqual(committed_paths - {""}, {deployment, service})
        self.assertNotIn("push", {command[0] for command in adapter.commands})

    def test_branch_mismatch_is_rejected(self) -> None:
        self._git("checkout", "-b", "feature/test")
        self._write("expected.yaml", "kind: Service\n")

        self.assert_error_code(
            "git_branch_mismatch",
            lambda: GitAdapter().create_commit(self.request("expected.yaml")),
        )

    def test_unexpected_untracked_file_is_rejected(self) -> None:
        self._write("expected.yaml", "kind: Service\n")
        self._write("unexpected.txt", "do not commit\n")

        self.assert_error_code(
            "git_unexpected_changes",
            lambda: GitAdapter().create_commit(self.request("expected.yaml")),
        )

    def test_unexpected_modified_file_is_rejected(self) -> None:
        self._write("expected.yaml", "kind: Service\n")
        self._write("README.md", "user-owned change\n")

        self.assert_error_code(
            "git_unexpected_changes",
            lambda: GitAdapter().create_commit(self.request("expected.yaml")),
        )

    def test_unexpected_staged_file_is_rejected(self) -> None:
        self._write("expected.yaml", "kind: Service\n")
        self._write("unexpected.txt", "already staged\n")
        self._git("add", "--", "unexpected.txt")

        self.assert_error_code(
            "git_unexpected_changes",
            lambda: GitAdapter().create_commit(self.request("expected.yaml")),
        )

    def test_unsafe_expected_paths_are_rejected(self) -> None:
        invalid_paths = (
            str((self.repo_root / "absolute.yaml").resolve()),
            "../outside.yaml",
            ".git/config",
            "gitops/.git/config",
        )

        for invalid_path in invalid_paths:
            with self.subTest(path=invalid_path):
                self.assert_error_code(
                    "git_path_invalid",
                    lambda invalid_path=invalid_path: GitAdapter().create_commit(self.request(invalid_path)),
                )

    def test_no_changes_returns_stable_error(self) -> None:
        self.assert_error_code(
            "git_no_changes",
            lambda: GitAdapter().create_commit(self.request("README.md")),
        )

    def test_operation_in_progress_is_rejected(self) -> None:
        git_directory = Path(self._git("rev-parse", "--git-dir").strip())
        if not git_directory.is_absolute():
            git_directory = self.repo_root / git_directory
        (git_directory / "MERGE_HEAD").write_text("0" * 40 + "\n", encoding="ascii")
        self._write("expected.yaml", "kind: Service\n")

        self.assert_error_code(
            "git_operation_in_progress",
            lambda: GitAdapter().create_commit(self.request("expected.yaml")),
        )

    def test_invalid_commit_message_is_rejected(self) -> None:
        self._write("expected.yaml", "kind: Service\n")
        request = GitCommitRequest(
            repo_root=self.repo_root,
            expected_paths=("expected.yaml",),
            commit_message="deploy: unsafe\nmessage",
        )

        self.assert_error_code("git_commit_failed", lambda: GitAdapter().create_commit(request))

    def test_sanitizer_redacts_credentials(self) -> None:
        raw = (
            "fatal: https://user:super-secret@example.com/repo.git "
            "token=plain-token Authorization=BearerValue github_pat_ABC123"
        )

        sanitized = sanitize_git_output(raw)

        for secret in ("user:super-secret", "plain-token", "BearerValue", "github_pat_ABC123"):
            self.assertNotIn(secret, sanitized)
        self.assertIn("<redacted>", sanitized)
        self.assertFalse(re.search(r"https://[^/\s]+:[^/\s]+@", sanitized))

    def test_successful_push_to_local_bare_remote_returns_head_sha(self) -> None:
        remote = self._create_bare_remote()
        commit_sha = self._create_local_commit()
        adapter = RecordingGitAdapter()

        result = adapter.push(
            GitPushRequest(
                repo_root=self.repo_root,
                expected_commit_sha=commit_sha,
            )
        )

        self.assertTrue(result.pushed)
        self.assertEqual(result.commit_sha, commit_sha)
        self.assertEqual(self._run_git(remote, "rev-parse", "refs/heads/main").strip(), commit_sha)
        self.assertIn(("push", "origin", "HEAD:main"), adapter.commands)

    def test_expected_commit_mismatch_is_rejected_before_push(self) -> None:
        self._create_local_commit()
        adapter = RecordingGitAdapter()

        self.assert_error_code(
            "git_head_mismatch",
            lambda: adapter.push(
                GitPushRequest(
                    repo_root=self.repo_root,
                    expected_commit_sha="0" * 40,
                )
            ),
        )
        self.assertNotIn("push", {command[0] for command in adapter.commands})

    def test_push_branch_mismatch_is_rejected(self) -> None:
        self._create_local_commit()

        self.assert_error_code(
            "git_branch_mismatch",
            lambda: GitAdapter().push(
                GitPushRequest(
                    repo_root=self.repo_root,
                    expected_branch="release",
                )
            ),
        )

    def test_invalid_remote_name_is_rejected(self) -> None:
        self._create_local_commit()

        for remote_name in ("../origin", "bad remote", "origin;publish"):
            with self.subTest(remote_name=remote_name):
                self.assert_error_code(
                    "git_remote_invalid",
                    lambda remote_name=remote_name: GitAdapter().push(
                        GitPushRequest(
                            repo_root=self.repo_root,
                            remote_name=remote_name,
                        )
                    ),
                )

    def test_invalid_remote_branch_is_rejected(self) -> None:
        self._create_local_commit()

        for remote_branch in ("../main", "bad branch", "main;publish", "main..other"):
            with self.subTest(remote_branch=remote_branch):
                self.assert_error_code(
                    "git_remote_branch_invalid",
                    lambda remote_branch=remote_branch: GitAdapter().push(
                        GitPushRequest(
                            repo_root=self.repo_root,
                            remote_branch=remote_branch,
                        )
                    ),
                )

    def test_remote_rejection_is_reported_without_rewriting_history(self) -> None:
        remote = self._create_bare_remote()
        self._git("push", "origin", "HEAD:main")

        competitor = self.test_root / "competitor"
        self._run_git(self.test_root, "clone", str(remote), str(competitor))
        self._run_git(competitor, "config", "user.name", "Competing Test")
        self._run_git(competitor, "config", "user.email", "competitor@example.invalid")
        (competitor / "competitor.txt").write_text("competing change\n", encoding="utf-8")
        self._run_git(competitor, "add", "--", "competitor.txt")
        self._run_git(competitor, "commit", "-m", "test: competing commit")
        self._run_git(competitor, "push", "origin", "HEAD:main")

        self._create_local_commit("local.yaml")

        self.assert_error_code(
            "git_push_rejected",
            lambda: GitAdapter().push(GitPushRequest(repo_root=self.repo_root)),
        )

    def test_push_failure_diagnostic_redacts_remote_credentials(self) -> None:
        self._create_local_commit()

        with self.assertRaises(GitOpsWriterError) as raised:
            CredentialFailureGitAdapter().push(GitPushRequest(repo_root=self.repo_root))

        self.assertEqual(raised.exception.code, "git_push_failed")
        self.assertNotIn("user:super-secret", raised.exception.message)
        self.assertNotIn("plain-token", raised.exception.message)
        self.assertIn("<redacted>", raised.exception.message)


if __name__ == "__main__":
    unittest.main()
