import unittest

from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.api.v1.endpoints import deployment_records, gitops, services
from app.core.deps import get_current_user, get_db
from app.db.database import Base
from app.models.user import User
from app.services.gitops.deploy_operation import DeployWorkloadOperationResult


class FakeDeployOperationService:
    def __init__(self):
        self.result = self.success_result("a" * 40)
        self.requests = []

    @staticmethod
    def success_result(commit_sha: str) -> DeployWorkloadOperationResult:
        return DeployWorkloadOperationResult(
            status="pushed_waiting_for_argocd",
            app_name="payment-api",
            source_path="gitops/workloads/devdeploy-apps",
            expected_paths=(),
            committed=True,
            pushed=True,
            commit_sha=commit_sha,
            message="The workload commit was pushed.",
        )

    def execute(self, request):
        self.requests.append(request)
        return self.result


class GitOpsProductRecordsTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.engine = create_engine(
            "sqlite://",
            connect_args={"check_same_thread": False},
            poolclass=StaticPool,
        )
        self.session_factory = sessionmaker(autocommit=False, autoflush=False, bind=self.engine)
        Base.metadata.create_all(self.engine)
        self.db = self.session_factory()
        self.user_a = User(
            email="owner-a@example.test",
            username="owner-a",
            hashed_password="test-only",
            role="developer",
            is_active=True,
        )
        self.user_b = User(
            email="owner-b@example.test",
            username="owner-b",
            hashed_password="test-only",
            role="developer",
            is_active=True,
        )
        self.db.add_all([self.user_a, self.user_b])
        self.db.commit()
        self.db.refresh(self.user_a)
        self.db.refresh(self.user_b)
        self.current_user = self.user_a
        self.operation_service = FakeDeployOperationService()
        self.config = gitops.GitOpsDeployRepositoryConfig(
            repo_root="C:/safe/devdeploy-repository",
            source_root_relative="gitops/workloads/devdeploy-apps",
            expected_branch="main",
            remote_name="origin",
            remote_branch="main",
        )

        self.app = FastAPI()
        self.app.include_router(gitops.router, prefix="/api/v1")
        self.app.include_router(services.router, prefix="/api/v1")
        self.app.include_router(deployment_records.router, prefix="/api/v1")

        def override_get_db():
            yield self.db

        self.app.dependency_overrides[get_db] = override_get_db
        self.app.dependency_overrides[get_current_user] = lambda: self.current_user
        self.app.dependency_overrides[gitops.get_gitops_deploy_repository_config] = lambda: self.config
        self.app.dependency_overrides[
            gitops.get_deploy_workload_operation_service
        ] = lambda: self.operation_service
        self.client = TestClient(self.app, raise_server_exceptions=False)

    def tearDown(self) -> None:
        self.client.close()
        self.db.close()
        Base.metadata.drop_all(self.engine)
        self.engine.dispose()

    @staticmethod
    def payload(**overrides) -> dict:
        return {
            "app_name": "payment-api",
            "image": "ghcr.io/example/payment-api:v1.0.0",
            "replicas": 2,
            "container_port": 8080,
            "service_port": 80,
            "service_type": "ClusterIP",
            **overrides,
        }

    def deploy(self, **overrides):
        return self.client.post("/api/v1/gitops/apps", json=self.payload(**overrides))

    def test_successful_deploy_creates_linked_product_records(self) -> None:
        response = self.deploy()

        self.assertEqual(response.status_code, 202, response.text)
        services_response = self.client.get("/api/v1/services")
        deployments_response = self.client.get("/api/v1/deployment-records")
        self.assertEqual(services_response.status_code, 200)
        self.assertEqual(deployments_response.status_code, 200)
        service_items = services_response.json()
        deployment_items = deployments_response.json()
        self.assertEqual(len(service_items), 1)
        self.assertEqual(len(deployment_items), 1)

        service = service_items[0]
        deployment = deployment_items[0]
        self.assertEqual(service["owner_id"], self.user_a.id)
        self.assertEqual(service["name"], "payment-api")
        self.assertEqual(service["default_image"], self.payload()["image"])
        self.assertEqual(service["default_replicas"], 2)
        self.assertEqual(service["default_port"], 80)
        self.assertEqual(deployment["owner_id"], self.user_a.id)
        self.assertEqual(deployment["service_definition_id"], service["id"])
        self.assertEqual(deployment["commit_sha"], "a" * 40)
        self.assertEqual(
            deployment["gitops_manifest_path"],
            "gitops/workloads/devdeploy-apps/apps/payment-api",
        )
        self.assertEqual(deployment["desired_state"], "pending")
        self.assertEqual(deployment["status_summary"], "GitOps manifests published")

    def test_existing_owned_service_is_reused_and_defaults_are_refreshed(self) -> None:
        self.assertEqual(self.deploy().status_code, 202)
        self.operation_service.result = self.operation_service.success_result("b" * 40)

        second_response = self.deploy(
            image="ghcr.io/example/payment-api:v2.0.0",
            replicas=3,
            service_port=8081,
        )

        self.assertEqual(second_response.status_code, 202, second_response.text)
        service_items = self.client.get("/api/v1/services").json()
        deployment_items = self.client.get("/api/v1/deployment-records").json()
        self.assertEqual(len(service_items), 1)
        self.assertEqual(len(deployment_items), 2)
        self.assertEqual(service_items[0]["default_image"], "ghcr.io/example/payment-api:v2.0.0")
        self.assertEqual(service_items[0]["default_replicas"], 3)
        self.assertEqual(service_items[0]["default_port"], 8081)
        self.assertTrue(
            all(item["service_definition_id"] == service_items[0]["id"] for item in deployment_items)
        )

    def test_gitops_conflict_does_not_create_duplicate_product_records(self) -> None:
        self.assertEqual(self.deploy().status_code, 202)
        self.operation_service.result = DeployWorkloadOperationResult(
            status="repo_write_failed",
            app_name="payment-api",
            source_path="gitops/workloads/devdeploy-apps",
            expected_paths=(),
            committed=False,
            pushed=False,
            commit_sha=None,
            message="The app path already exists.",
            error_code="app_already_exists",
        )

        response = self.deploy()

        self.assertEqual(response.status_code, 409)
        self.assertEqual(len(self.client.get("/api/v1/services").json()), 1)
        self.assertEqual(len(self.client.get("/api/v1/deployment-records").json()), 1)

    def test_records_are_user_scoped_when_gitops_allows_the_same_app_name(self) -> None:
        self.assertEqual(self.deploy().status_code, 202)
        self.current_user = self.user_b
        self.operation_service.result = self.operation_service.success_result("b" * 40)

        second_response = self.deploy()

        self.assertEqual(second_response.status_code, 202, second_response.text)
        user_b_services = self.client.get("/api/v1/services").json()
        user_b_deployments = self.client.get("/api/v1/deployment-records").json()
        self.assertEqual(len(user_b_services), 1)
        self.assertEqual(len(user_b_deployments), 1)
        self.assertEqual(user_b_services[0]["owner_id"], self.user_b.id)
        self.assertEqual(user_b_deployments[0]["owner_id"], self.user_b.id)

        self.current_user = self.user_a
        self.assertEqual(len(self.client.get("/api/v1/services").json()), 1)
        self.assertEqual(len(self.client.get("/api/v1/deployment-records").json()), 1)


if __name__ == "__main__":
    unittest.main()
