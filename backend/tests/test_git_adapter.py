from pathlib import Path
import re
import subprocess
import tempfile
import unittest

from app.services.gitops.errors import GitOpsWriterError
from app.services.gitops.git_adapter import (
    GitAdapter,
    GitCommitRequest,
    sanitize_git_output,
)


class RecordingGitAdapter(GitAdapter):
    def __init__(self) -> None:
        super().__init__()
        self.commands: list[tuple[str, ...]] = []

    def _run_git(self, arguments, *, cwd):
        self.commands.append(tuple(arguments))
        return super()._run_git(arguments, cwd=cwd)


class GitAdapterTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.repo_root = Path(self.temporary_directory.name)
        self._git("init", "--initial-branch=main")
        self._git("config", "user.name", "DevDeploy Test")
        self._git("config", "user.email", "devdeploy-test@example.invalid")
        self._write("README.md", "test repository\n")
        self._git("add", "--", "README.md")
        self._git("commit", "-m", "test: initialize repository")

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def _git(self, *arguments: str) -> str:
        completed = subprocess.run(
            ["git", *arguments],
            cwd=self.repo_root,
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


if __name__ == "__main__":
    unittest.main()
