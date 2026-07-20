import subprocess
import tempfile
import unittest
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.api.v1.endpoints import deployment_records, gitops
from app.api.v1.endpoints.gitops import GitOpsDeployRepositoryConfig
from app.core.deps import get_current_user
from app.services.gitops.deploy_operation import DeployWorkloadOperationResult
from app.services.gitops.destroy_operation import DestroyWorkloadOperationResult
from app.services.gitops.git_adapter import _ensure_git_askpass_script, _git_askpass_environment
from app.services.gitops.managed_repository import GitHubManagedRepository, ManagedGitRepositoryError


class FakeDeployOperationService:
    def __init__(self):
        self.requests = []
        self.git_adapter = None

    def execute(self, request):
        self.requests.append(request)
        return DeployWorkloadOperationResult(
            status="pushed_waiting_for_argocd",
            app_name=request.app_name,
            source_path=request.source_root_relative,
            expected_paths=("gitops/workloads/devdeploy-apps/kustomization.yaml",),
            committed=True,
            pushed=True,
            commit_sha="a" * 40,
            message="pushed",
        )


class FakeDestroyOperationService:
    def __init__(self):
        self.requests = []
        self.git_adapter = None

    def execute(self, request):
        self.requests.append(request)
        return DestroyWorkloadOperationResult(
            status="pushed_waiting_for_argocd",
            app_name=request.app_name,
            source_path=request.source_root_relative,
            expected_paths=("gitops/workloads/devdeploy-apps/kustomization.yaml",),
            committed=True,
            pushed=True,
            commit_sha="b" * 40,
            message="pushed",
        )


class FakeProductRecordService:
    def __init__(self):
        self.requests = []

    def record_published_deployment(self, request):
        self.requests.append(request)


class GitOpsManagedRepositoryTestCase(unittest.TestCase):
    def test_askpass_environment_does_not_put_token_in_script(self) -> None:
        token = "test-token-super-secret-value"
        env = _git_askpass_environment(token)
        script = Path(env["GIT_ASKPASS"])

        self.assertEqual(env["DEVDEPLOY_GIT_PASSWORD"], token)
        self.assertEqual(env["GIT_TERMINAL_PROMPT"], "0")
        self.assertNotIn(token, script.read_text(encoding="utf-8"))

    def test_managed_clone_uses_clean_github_url_and_cleans_workspace(self) -> None:
        calls = []

        def fake_run(args, **kwargs):
            calls.append((args, kwargs))
            if args[1] == "clone":
                Path(args[-1]).mkdir(parents=True)
            return subprocess.CompletedProcess(args=args, returncode=0, stdout="", stderr="")

        with tempfile.TemporaryDirectory() as temp_dir:
            repository = GitHubManagedRepository(workspace_root=temp_dir)
            with patch("app.services.gitops.managed_repository.subprocess.run", side_effect=fake_run):
                with repository.lease(owner="Kaan-YASSIBAS", repo="devdeploy-hub", branch="main", token="secret-token") as lease:
                    leased_root = lease.repo_root
                    self.assertTrue(leased_root.exists())
                    self.assertEqual(lease.github_token, "secret-token")
                self.assertFalse(leased_root.exists())

        clone_args = calls[0][0]
        self.assertEqual(clone_args[0:5], ["git", "clone", "--depth", "1", "--branch"])
        self.assertIn("https://github.com/Kaan-YASSIBAS/devdeploy-hub.git", clone_args)
        self.assertTrue(all("secret-token" not in str(args) for args, _kwargs in calls))
        self.assertTrue(all(kwargs["env"]["DEVDEPLOY_GIT_PASSWORD"] == "secret-token" for _args, kwargs in calls))

    def test_invalid_github_configuration_fails_safely(self) -> None:
        with self.assertRaises(ManagedGitRepositoryError) as raised:
            with GitHubManagedRepository().lease(owner="../bad", repo="devdeploy-hub", branch="main", token="token"):
                pass
        self.assertEqual(raised.exception.code, "github_owner_invalid")


class GitOpsManagedApiTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.app = FastAPI()
        self.app.include_router(gitops.router, prefix="/api/v1")
        self.app.include_router(deployment_records.router, prefix="/api/v1")
        self.config = GitOpsDeployRepositoryConfig(
            repo_root=None,
            source_root_relative="gitops/workloads/devdeploy-apps",
            expected_branch="main",
            remote_name="origin",
            remote_branch="main",
            provider="managed_github_clone",
            github_owner="Kaan-YASSIBAS",
            github_repo="devdeploy-hub",
            github_token="secret-token",
        )
        self.deploy_service = FakeDeployOperationService()
        self.destroy_service = FakeDestroyOperationService()
        self.product_records = FakeProductRecordService()
        self.app.dependency_overrides[get_current_user] = lambda: SimpleNamespace(id=7, is_active=True)
        self.app.dependency_overrides[gitops.get_gitops_deploy_repository_config] = lambda: self.config
        self.app.dependency_overrides[deployment_records.get_gitops_deploy_repository_config] = lambda: self.config
        self.app.dependency_overrides[gitops.get_deploy_workload_operation_service] = lambda: self.deploy_service
        self.app.dependency_overrides[deployment_records.get_deploy_workload_operation_service] = lambda: self.deploy_service
        self.app.dependency_overrides[gitops.get_gitops_product_record_service] = lambda: self.product_records
        self.app.dependency_overrides[deployment_records.get_destroy_workload_operation_service] = lambda: self.destroy_service
        self.client = TestClient(self.app, raise_server_exceptions=False)

    def tearDown(self) -> None:
        self.client.close()

    @staticmethod
    def payload() -> dict:
        return {
            "app_name": "gitops-flow-smoke-nginx",
            "image": "nginx:latest",
            "replicas": 1,
            "container_port": 80,
            "service_port": 80,
            "service_type": "ClusterIP",
        }

    @contextmanager
    def fake_repository(self):
        yield gitops.PreparedGitOpsRepository(repo_root="C:/managed/clone", git_adapter=None)

    def test_create_uses_managed_repository_without_repo_root_config(self) -> None:
        with patch("app.api.v1.endpoints.gitops.prepare_gitops_repository", return_value=self.fake_repository()):
            response = self.client.post("/api/v1/gitops/apps", json=self.payload())

        self.assertEqual(response.status_code, 202)
        self.assertEqual(self.deploy_service.requests[0].repo_root, "C:/managed/clone")
        self.assertEqual(len(self.product_records.requests), 1)
        self.assertNotIn("secret-token", str(response.json()))

    def test_destroy_uses_managed_repository_without_repo_root_config(self) -> None:
        deployment = SimpleNamespace(
            id=3,
            owner_id=7,
            app_name="gitops-flow-smoke-nginx",
            image="nginx:latest",
            replicas=1,
            container_port=80,
            service_port=80,
            service_type="ClusterIP",
            namespace="devdeploy-apps",
            commit_sha="a" * 40,
            gitops_manifest_path="gitops/workloads/devdeploy-apps/apps/gitops-flow-smoke-nginx",
            archived_at=None,
            desired_state="pending",
        )
        records = SimpleNamespace(
            get_owned=lambda deployment_id, user: deployment,
            mark_destroyed=lambda deployment, source_path, commit_sha, runtime_cleanup_status: deployment,
        )
        cleanup = SimpleNamespace(
            status="not_required",
            deployment_deleted=False,
            service_deleted=False,
            message="No matching runtime resources were found.",
            checked_at=datetime.now(timezone.utc),
        )
        cleanup_service = SimpleNamespace(cleanup=lambda deployment, destroy_commit_sha: cleanup)
        self.app.dependency_overrides[deployment_records.get_db] = lambda: SimpleNamespace(rollback=lambda: None)
        self.app.dependency_overrides[deployment_records.DeploymentRecordService] = lambda db: records
        self.app.dependency_overrides[deployment_records.get_deployment_destroy_runtime_cleanup_service] = lambda: cleanup_service

        with patch("app.api.v1.endpoints.deployment_records.DeploymentRecordService", return_value=records), patch(
            "app.api.v1.endpoints.gitops.prepare_gitops_repository", return_value=self.fake_repository()
        ), patch(
            "app.api.v1.endpoints.deployment_records.prepare_gitops_repository", return_value=self.fake_repository()
        ):
            response = self.client.post("/api/v1/deployment-records/3/destroy")

        self.assertEqual(response.status_code, 202)
        self.assertEqual(self.destroy_service.requests[0].repo_root, "C:/managed/clone")
        self.assertNotIn("secret-token", str(response.json()))


if __name__ == "__main__":
    unittest.main()
