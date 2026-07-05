from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

from app.services.gitops.deploy_operation import (
    DeployWorkloadOperationRequest,
    DeployWorkloadOperationService,
)
from app.services.gitops.errors import GitOpsWriterError
from app.services.gitops.git_adapter import _GitCommandResult, GitAdapter


ROOT_KUSTOMIZATION = """apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
"""


class CommitFailureGitAdapter(GitAdapter):
    def __init__(self) -> None:
        super().__init__()
        self.push_called = False

    def create_commit(self, request):
        raise GitOpsWriterError("git_commit_failed", "The local commit failed safely.")

    def push(self, request):
        self.push_called = True
        return super().push(request)


class CredentialPushFailureGitAdapter(GitAdapter):
    def _run_git(self, arguments, *, cwd):
        if arguments and arguments[0] == "push":
            return _GitCommandResult(
                return_code=1,
                stdout="",
                stderr=(
                    "fatal: unable to access "
                    "https://user:super-secret@example.invalid/repository.git password=plain-password"
                ),
            )
        return super()._run_git(arguments, cwd=cwd)


class DeployWorkloadOperationTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.test_root = Path(self.temporary_directory.name)
        self.repo_root = self.test_root / "worktree"
        self.repo_root.mkdir()
        self.source_root = self.repo_root / "gitops" / "workloads" / "devdeploy-apps"
        (self.source_root / "apps").mkdir(parents=True)
        (self.source_root / "kustomization.yaml").write_text(ROOT_KUSTOMIZATION, encoding="utf-8")

        self._git(self.repo_root, "init", "--initial-branch=main")
        self._git(self.repo_root, "config", "user.name", "DevDeploy Test")
        self._git(self.repo_root, "config", "user.email", "devdeploy-test@example.invalid")
        self._git(self.repo_root, "add", "--", "gitops")
        self._git(self.repo_root, "commit", "-m", "test: initialize GitOps repository")
        self.initial_sha = self._git(self.repo_root, "rev-parse", "HEAD").strip()

        self.remote = self.test_root / "remote.git"
        self.remote.mkdir()
        self._git(self.remote, "init", "--bare", "--initial-branch=main")
        self._git(self.repo_root, "remote", "add", "origin", str(self.remote))

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def _git(self, cwd: Path, *arguments: str) -> str:
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

    def request(
        self,
        *,
        app_name: str = "payment-api",
        write_mode: str = "create",
    ) -> DeployWorkloadOperationRequest:
        return DeployWorkloadOperationRequest(
            repo_root=self.repo_root,
            app_name=app_name,
            image="ghcr.io/example/payment-api:v1.0.0",
            replicas=2,
            container_port=8080,
            service_port=80,
            write_mode=write_mode,
        )

    def remote_refs(self) -> str:
        return self._git(self.remote, "for-each-ref", "--format=%(refname)")

    def test_successful_operation_writes_commits_and_pushes_expected_files(self) -> None:
        result = DeployWorkloadOperationService().execute(self.request())

        expected_paths = {
            "gitops/workloads/devdeploy-apps/kustomization.yaml",
            "gitops/workloads/devdeploy-apps/apps/payment-api/kustomization.yaml",
            "gitops/workloads/devdeploy-apps/apps/payment-api/deployment.yaml",
            "gitops/workloads/devdeploy-apps/apps/payment-api/service.yaml",
        }
        self.assertEqual(result.status, "pushed_waiting_for_argocd", result.message)
        self.assertTrue(result.committed)
        self.assertTrue(result.pushed)
        self.assertRegex(result.commit_sha or "", r"^[0-9a-f]{40,64}$")
        self.assertEqual(set(result.expected_paths), expected_paths)
        self.assertEqual(
            self._git(self.remote, "rev-parse", "refs/heads/main").strip(),
            result.commit_sha,
        )
        committed_paths = set(
            self._git(
                self.remote,
                "diff-tree",
                "--no-commit-id",
                "--name-only",
                "-r",
                result.commit_sha or "",
            ).splitlines()
        )
        self.assertEqual(committed_paths, expected_paths)
        self.assertEqual(
            self._git(self.repo_root, "show", "-s", "--format=%s", "HEAD").strip(),
            "deploy: add payment-api workload",
        )

        deployment = yaml.safe_load(
            (self.source_root / "apps" / "payment-api" / "deployment.yaml").read_text(encoding="utf-8")
        )
        self.assertEqual(deployment["spec"]["replicas"], 2)
        pod_spec = deployment["spec"]["template"]["spec"]
        self.assertTrue(pod_spec["securityContext"]["runAsNonRoot"])
        self.assertEqual(pod_spec["securityContext"]["runAsUser"], 101)
        self.assertEqual(pod_spec["securityContext"]["runAsGroup"], 101)
        self.assertEqual(pod_spec["securityContext"]["fsGroup"], 101)
        self.assertEqual(pod_spec["securityContext"]["seccompProfile"]["type"], "RuntimeDefault")
        container = pod_spec["containers"][0]
        self.assertEqual(container["image"], self.request().image)
        self.assertFalse(container["securityContext"]["allowPrivilegeEscalation"])
        self.assertTrue(container["securityContext"]["readOnlyRootFilesystem"])
        self.assertEqual(container["securityContext"]["capabilities"]["drop"], ["ALL"])
        self.assertEqual(
            {mount["name"]: mount["mountPath"] for mount in container["volumeMounts"]},
            {
                "nginx-cache": "/var/cache/nginx",
                "nginx-run": "/var/run",
                "tmp": "/tmp",
            },
        )
        self.assertTrue(all(volume["emptyDir"] == {} for volume in pod_spec["volumes"]))
        self.assertTrue(all("hostPath" not in volume for volume in pod_spec["volumes"]))

    def test_invalid_app_name_fails_validation_without_commit_or_push(self) -> None:
        result = DeployWorkloadOperationService().execute(self.request(app_name="Invalid/App"))

        self.assertEqual(result.status, "validation_failed")
        self.assertEqual(result.error_code, "invalid_app_name")
        self.assertFalse(result.committed)
        self.assertFalse(result.pushed)
        self.assertEqual(self._git(self.repo_root, "rev-parse", "HEAD").strip(), self.initial_sha)
        self.assertEqual(self.remote_refs(), "")

    def test_existing_app_folder_fails_without_commit_or_push(self) -> None:
        (self.source_root / "apps" / "payment-api").mkdir()

        result = DeployWorkloadOperationService().execute(self.request())

        self.assertEqual(result.status, "repo_write_failed")
        self.assertEqual(result.error_code, "app_exists")
        self.assertFalse(result.committed)
        self.assertFalse(result.pushed)
        self.assertEqual(self._git(self.repo_root, "rev-parse", "HEAD").strip(), self.initial_sha)
        self.assertEqual(self.remote_refs(), "")

    def test_recovery_operation_restores_commits_and_pushes_missing_manifests(self) -> None:
        result = DeployWorkloadOperationService().execute(self.request(write_mode="recover"))

        self.assertEqual(result.status, "pushed_waiting_for_argocd")
        self.assertTrue(result.committed)
        self.assertTrue(result.pushed)
        self.assertEqual(
            self._git(self.repo_root, "show", "-s", "--format=%s", "HEAD").strip(),
            "recover: restore payment-api workload",
        )
        root = yaml.safe_load((self.source_root / "kustomization.yaml").read_text(encoding="utf-8"))
        self.assertEqual(root["resources"], ["apps/payment-api"])

    def test_recovery_operation_handles_matching_manifests_without_duplicate_commit(self) -> None:
        first = DeployWorkloadOperationService().execute(self.request(write_mode="recover"))
        first_head = self._git(self.repo_root, "rev-parse", "HEAD").strip()

        second = DeployWorkloadOperationService().execute(self.request(write_mode="recover"))

        self.assertEqual(first.status, "pushed_waiting_for_argocd")
        self.assertEqual(second.status, "no_changes")
        self.assertFalse(second.committed)
        self.assertFalse(second.pushed)
        self.assertEqual(second.commit_sha, first_head)
        self.assertEqual(self._git(self.repo_root, "rev-parse", "HEAD").strip(), first_head)

    def test_reconcile_rewrites_drifted_manifest_and_uses_scoped_commit(self) -> None:
        initial = DeployWorkloadOperationService().execute(self.request(write_mode="recover"))
        deployment_path = self.source_root / "apps" / "payment-api" / "deployment.yaml"
        deployment = yaml.safe_load(deployment_path.read_text(encoding="utf-8"))
        deployment["spec"]["replicas"] = 1
        deployment_path.write_text(
            yaml.safe_dump(deployment, sort_keys=False),
            encoding="utf-8",
        )
        self._git(self.repo_root, "add", "--", deployment_path.relative_to(self.repo_root).as_posix())
        self._git(self.repo_root, "commit", "-m", "test: simulate GitOps drift")

        result = DeployWorkloadOperationService().execute(self.request(write_mode="reconcile"))

        self.assertEqual(initial.status, "pushed_waiting_for_argocd")
        self.assertEqual(result.status, "pushed_waiting_for_argocd", result.message)
        self.assertTrue(result.committed)
        self.assertTrue(result.pushed)
        self.assertEqual(
            self._git(self.repo_root, "show", "-s", "--format=%s", "HEAD").strip(),
            "reconcile: align payment-api workload",
        )
        reconciled = yaml.safe_load(deployment_path.read_text(encoding="utf-8"))
        self.assertEqual(reconciled["spec"]["replicas"], 2)
        self.assertEqual(
            yaml.safe_load((self.source_root / "kustomization.yaml").read_text(encoding="utf-8"))[
                "resources"
            ],
            ["apps/payment-api"],
        )

    def test_reconcile_no_change_reuses_head_without_empty_commit(self) -> None:
        first = DeployWorkloadOperationService().execute(self.request(write_mode="reconcile"))
        first_head = self._git(self.repo_root, "rev-parse", "HEAD").strip()

        second = DeployWorkloadOperationService().execute(self.request(write_mode="reconcile"))

        self.assertEqual(first.status, "pushed_waiting_for_argocd")
        self.assertEqual(second.status, "no_changes")
        self.assertFalse(second.committed)
        self.assertFalse(second.pushed)
        self.assertEqual(second.commit_sha, first_head)
        self.assertEqual(self._git(self.repo_root, "rev-parse", "HEAD").strip(), first_head)

    def test_commit_failure_stops_before_push(self) -> None:
        adapter = CommitFailureGitAdapter()

        result = DeployWorkloadOperationService(git_adapter=adapter).execute(self.request())

        self.assertEqual(result.status, "commit_failed")
        self.assertEqual(result.error_code, "git_commit_failed")
        self.assertFalse(result.committed)
        self.assertFalse(result.pushed)
        self.assertFalse(adapter.push_called)
        self.assertEqual(self._git(self.repo_root, "rev-parse", "HEAD").strip(), self.initial_sha)
        self.assertEqual(self.remote_refs(), "")

    def test_push_failure_returns_local_commit_with_sanitized_error(self) -> None:
        service = DeployWorkloadOperationService(git_adapter=CredentialPushFailureGitAdapter())

        result = service.execute(self.request())

        self.assertEqual(result.status, "push_failed")
        self.assertEqual(result.error_code, "git_push_failed")
        self.assertTrue(result.committed)
        self.assertFalse(result.pushed)
        self.assertEqual(result.commit_sha, self._git(self.repo_root, "rev-parse", "HEAD").strip())
        self.assertNotIn("user:super-secret", result.message)
        self.assertNotIn("plain-password", result.message)
        self.assertIn("<redacted>", result.message)
        self.assertEqual(self.remote_refs(), "")

    def test_unrelated_dirty_file_fails_before_writer_or_push(self) -> None:
        (self.repo_root / "notes.txt").write_text("user-owned change\n", encoding="utf-8")

        result = DeployWorkloadOperationService().execute(self.request())

        self.assertEqual(result.status, "commit_failed")
        self.assertEqual(result.error_code, "git_unexpected_changes")
        self.assertFalse(result.committed)
        self.assertFalse(result.pushed)
        self.assertFalse((self.source_root / "apps" / "payment-api").exists())
        self.assertEqual(self.remote_refs(), "")

    def test_unsafe_source_path_fails_validation(self) -> None:
        request = DeployWorkloadOperationRequest(
            repo_root=self.repo_root,
            source_root_relative="../outside",
            app_name="payment-api",
            image="nginx:1.27",
        )

        result = DeployWorkloadOperationService().execute(request)

        self.assertEqual(result.status, "validation_failed")
        self.assertEqual(result.error_code, "unsafe_path")
        self.assertEqual(self._git(self.repo_root, "rev-parse", "HEAD").strip(), self.initial_sha)
        self.assertEqual(self.remote_refs(), "")

    def test_invalid_remote_target_fails_before_writer_or_commit(self) -> None:
        request = DeployWorkloadOperationRequest(
            repo_root=self.repo_root,
            app_name="payment-api",
            image="nginx:1.27",
            remote_name="../origin",
        )

        result = DeployWorkloadOperationService().execute(request)

        self.assertEqual(result.status, "validation_failed")
        self.assertEqual(result.error_code, "git_remote_invalid")
        self.assertFalse(result.committed)
        self.assertFalse((self.source_root / "apps" / "payment-api").exists())
        self.assertEqual(self._git(self.repo_root, "rev-parse", "HEAD").strip(), self.initial_sha)
        self.assertEqual(self.remote_refs(), "")


if __name__ == "__main__":
    unittest.main()
