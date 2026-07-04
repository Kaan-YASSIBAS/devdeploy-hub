import unittest
from types import SimpleNamespace

from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.api.v1.endpoints.gitops import (
    GitOpsDeployRepositoryConfig,
    get_deploy_workload_operation_service,
    get_gitops_app_discovery_service,
    get_gitops_deploy_repository_config,
    get_gitops_product_record_service,
    router,
)
from app.core.deps import get_current_user
from app.services.gitops.deploy_operation import DeployWorkloadOperationResult
from app.services.gitops.discovery import DiscoveredGitOpsApp
from app.services.gitops.product_records import ProductRecordPersistenceError


class FakeDeployOperationService:
    def __init__(self, result: DeployWorkloadOperationResult | None = None, *, raises: bool = False):
        self.result = result
        self.raises = raises
        self.requests = []

    def execute(self, request):
        self.requests.append(request)
        if self.raises:
            raise RuntimeError("internal detail that must not be returned")
        if self.result is None:
            raise AssertionError("Fake operation result is not configured")
        return self.result


class FakeDiscoveryService:
    def __init__(self):
        self.calls = []

    def discover(self, **kwargs):
        self.calls.append(kwargs)
        return [
            DiscoveredGitOpsApp(
                app_name="payment-api",
                image="ghcr.io/example/payment-api:v1.0.0",
                replicas=2,
                container_port=8080,
                service_port=80,
                service_type="ClusterIP",
                namespace="devdeploy-apps",
                manifest_path="apps/payment-api",
            )
        ]


class FakeProductRecordService:
    def __init__(self, *, raises: bool = False):
        self.raises = raises
        self.requests = []

    def record_published_deployment(self, request):
        self.requests.append(request)
        if self.raises:
            raise ProductRecordPersistenceError("internal database detail")


class GitOpsApiTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.app = FastAPI()
        self.app.include_router(router, prefix="/api/v1")
        self.config = GitOpsDeployRepositoryConfig(
            repo_root="C:/safe/devdeploy-repository",
            source_root_relative="gitops/workloads/devdeploy-apps",
            expected_branch="main",
            remote_name="origin",
            remote_branch="main",
        )
        self.service = FakeDeployOperationService(self.success_result())
        self.discovery_service = FakeDiscoveryService()
        self.product_record_service = FakeProductRecordService()
        self.app.dependency_overrides[get_gitops_deploy_repository_config] = lambda: self.config
        self.app.dependency_overrides[get_deploy_workload_operation_service] = lambda: self.service
        self.app.dependency_overrides[get_gitops_app_discovery_service] = lambda: self.discovery_service
        self.app.dependency_overrides[get_gitops_product_record_service] = lambda: self.product_record_service
        self.client = TestClient(self.app, raise_server_exceptions=False)

    def tearDown(self) -> None:
        self.client.close()

    @staticmethod
    def payload() -> dict:
        return {
            "app_name": "payment-api",
            "image": "ghcr.io/example/payment-api:v1.0.0",
            "replicas": 2,
            "container_port": 8080,
            "service_port": 80,
            "service_type": "ClusterIP",
        }

    @staticmethod
    def success_result() -> DeployWorkloadOperationResult:
        return DeployWorkloadOperationResult(
            status="pushed_waiting_for_argocd",
            app_name="payment-api",
            source_path="gitops/workloads/devdeploy-apps",
            expected_paths=(),
            committed=True,
            pushed=True,
            commit_sha="a" * 40,
            message="Internal success message",
        )

    def authenticate(self) -> None:
        self.app.dependency_overrides[get_current_user] = lambda: SimpleNamespace(id=7)

    def test_unauthenticated_request_is_rejected(self) -> None:
        response = self.client.post("/api/v1/gitops/apps", json=self.payload())

        self.assertEqual(response.status_code, 401)
        self.assertEqual(self.service.requests, [])

    def test_unauthenticated_list_request_is_rejected(self) -> None:
        response = self.client.get("/api/v1/gitops/apps")

        self.assertEqual(response.status_code, 401)
        self.assertEqual(self.discovery_service.calls, [])

    def test_list_returns_discovered_apps_without_live_status_dependency(self) -> None:
        self.authenticate()

        response = self.client.get("/api/v1/gitops/apps")

        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(len(body["items"]), 1)
        self.assertEqual(body["items"][0]["app_name"], "payment-api")
        self.assertEqual(body["items"][0]["status"], "unknown")
        self.assertEqual(
            self.discovery_service.calls,
            [
                {
                    "repo_root": self.config.repo_root,
                    "source_root_relative": self.config.source_root_relative,
                }
            ],
        )

    def test_valid_request_calls_operation_and_returns_pending_reconciliation(self) -> None:
        self.authenticate()

        response = self.client.post("/api/v1/gitops/apps", json=self.payload())

        self.assertEqual(response.status_code, 202)
        body = response.json()
        self.assertEqual(body["status"], "pushed_waiting_for_argocd")
        self.assertEqual(body["namespace"], "devdeploy-apps")
        self.assertEqual(body["source_path"], "gitops/workloads/devdeploy-apps")
        self.assertEqual(body["commit_sha"], "a" * 40)
        self.assertIn("reconciliation is pending", body["message"])
        self.assertNotIn("deployed", str(body).lower())
        self.assertNotIn(self.config.repo_root, str(body))

        self.assertEqual(len(self.service.requests), 1)
        operation_request = self.service.requests[0]
        self.assertEqual(operation_request.repo_root, self.config.repo_root)
        self.assertEqual(operation_request.app_name, self.payload()["app_name"])
        self.assertEqual(operation_request.image, self.payload()["image"])
        self.assertEqual(operation_request.expected_branch, "main")
        self.assertEqual(len(self.product_record_service.requests), 1)
        record_request = self.product_record_service.requests[0]
        self.assertEqual(record_request.owner_id, 7)
        self.assertEqual(record_request.app_name, self.payload()["app_name"])
        self.assertEqual(record_request.commit_sha, "a" * 40)

    def test_validation_failure_maps_to_safe_bad_request(self) -> None:
        self.authenticate()
        self.service.result = DeployWorkloadOperationResult(
            status="validation_failed",
            app_name="payment-api",
            source_path="",
            expected_paths=(),
            committed=False,
            pushed=False,
            commit_sha=None,
            message="App name is invalid.",
            error_code="invalid_app_name",
        )

        response = self.client.post("/api/v1/gitops/apps", json=self.payload())

        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.json()["status"], "validation_failed")
        self.assertEqual(response.json()["error_code"], "invalid_app_name")
        self.assertEqual(self.product_record_service.requests, [])

    def test_push_failure_maps_to_safe_gateway_response_and_redacts_credentials(self) -> None:
        self.authenticate()
        self.service.result = DeployWorkloadOperationResult(
            status="push_failed",
            app_name="payment-api",
            source_path="gitops/workloads/devdeploy-apps",
            expected_paths=(),
            committed=True,
            pushed=False,
            commit_sha="b" * 40,
            message=(
                "fatal: https://user:super-secret@example.invalid/repository.git "
                "token=plain-token"
            ),
            error_code="git_push_failed",
        )

        response = self.client.post("/api/v1/gitops/apps", json=self.payload())

        self.assertEqual(response.status_code, 502)
        body = response.json()
        self.assertEqual(body["status"], "push_failed")
        self.assertEqual(body["error_code"], "git_push_failed")
        self.assertNotIn("user:super-secret", str(body))
        self.assertNotIn("plain-token", str(body))
        self.assertIn("<redacted>", body["message"])
        self.assertEqual(self.product_record_service.requests, [])

    def test_repository_token_namespace_and_commit_fields_are_forbidden(self) -> None:
        self.authenticate()
        forbidden_fields = {
            "repo_root": "C:/other/repo",
            "git_token": "not-a-real-token",
            "namespace": "other-namespace",
            "commit_message": "arbitrary commit",
        }

        for field_name, value in forbidden_fields.items():
            with self.subTest(field=field_name):
                payload = {**self.payload(), field_name: value}
                response = self.client.post("/api/v1/gitops/apps", json=payload)
                self.assertEqual(response.status_code, 422)

        self.assertEqual(self.service.requests, [])

    def test_unexpected_service_error_returns_sanitized_internal_error(self) -> None:
        self.authenticate()
        self.service.raises = True

        response = self.client.post("/api/v1/gitops/apps", json=self.payload())

        self.assertEqual(response.status_code, 500)
        body = response.json()
        self.assertEqual(body["status"], "internal_error")
        self.assertEqual(body["error_code"], "internal_error")
        self.assertNotIn("internal detail", str(body))
        self.assertEqual(self.product_record_service.requests, [])

    def test_product_record_failure_after_push_is_sanitized(self) -> None:
        self.authenticate()
        self.product_record_service.raises = True

        response = self.client.post("/api/v1/gitops/apps", json=self.payload())

        self.assertEqual(response.status_code, 500)
        body = response.json()
        self.assertEqual(body["status"], "internal_error")
        self.assertEqual(body["error_code"], "product_record_persistence_failed")
        self.assertEqual(body["commit_sha"], "a" * 40)
        self.assertNotIn("internal database detail", str(body))

    def test_unsafe_configured_source_path_is_not_exposed(self) -> None:
        self.authenticate()
        self.config = GitOpsDeployRepositoryConfig(
            repo_root="C:/safe/devdeploy-repository",
            source_root_relative="C:/sensitive/absolute/path",
            expected_branch="main",
            remote_name="origin",
            remote_branch="main",
        )

        response = self.client.post("/api/v1/gitops/apps", json=self.payload())

        self.assertEqual(response.status_code, 202)
        self.assertEqual(response.json()["source_path"], "")
        self.assertNotIn("sensitive", str(response.json()))


if __name__ == "__main__":
    unittest.main()
