import unittest
from unittest.mock import patch

from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.api.v1.endpoints import deployment_records, services
from app.api.v1.endpoints.deployment_records import PREVIEW_RUNTIME_AUTH_HEADER
from app.api.v1.runtime_status import (
    get_deployment_destroy_runtime_cleanup_service,
    get_deployment_drift_service,
    get_deployment_recovery_verification_service,
    get_product_runtime_status_service,
    get_workload_service_proxy_client,
)
from app.core.deps import get_current_user, get_db
from app.db.database import Base
from app.models.deployment_record import DeploymentRecord
from app.models.user import User
from app.services.gitops.deploy_operation import DeployWorkloadOperationResult
from app.services.gitops.destroy_operation import DestroyWorkloadOperationResult
from app.services.gitops.update_operation import UpdateWorkloadOperationResult
from app.services.gitops.status_reader import (
    NamedWorkloadSnapshot,
    ServicePortSnapshot,
    WorkloadSnapshot,
)
from app.services.deployment_preview_service import (
    PreviewForbiddenError,
    PreviewServiceUnavailableError,
    PreviewTimeoutError,
    PreviewUpstreamError,
    ServiceProxyResponse,
)
from app.services.deployment_destroy_service import DeploymentRuntimeCleanupResult
from app.services.deployment_drift import DeploymentDriftService, GitOpsManifestSnapshot
from app.services.deployment_recovery_service import DeploymentRecoveryVerificationResult
from app.services.preview_session import (
    PREVIEW_SESSION_COOKIE,
    create_preview_session_token,
)
from app.services.product_runtime_status import ProductRuntimeStatusService


class FakeWorkloadRuntimeReader:
    def __init__(self):
        self.snapshots = {}
        self.error: Exception | None = None
        self.calls = []
        self.discovered: tuple[NamedWorkloadSnapshot, ...] = ()

    def read_workload(self, app_name: str, namespace: str) -> WorkloadSnapshot:
        self.calls.append((app_name, namespace))
        if self.error is not None:
            raise self.error
        return self.snapshots.get((namespace, app_name), WorkloadSnapshot())

    def discover_workloads(self, namespace: str) -> tuple[NamedWorkloadSnapshot, ...]:
        self.calls.append(("discover", namespace))
        if self.error is not None:
            raise self.error
        return self.discovered


class FakeGitOpsManifestReader:
    def __init__(self):
        self.snapshot = GitOpsManifestSnapshot(
            status="missing",
            message="One or more required GitOps workload manifests are missing.",
        )

    def read(self, deployment):
        _ = deployment
        return self.snapshot


class FakeRecoverOperationService:
    def __init__(self):
        self.requests = []
        self.result = DeployWorkloadOperationResult(
            status="pushed_waiting_for_argocd",
            app_name="payments-api",
            source_path="gitops/workloads/devdeploy-apps",
            expected_paths=(),
            committed=True,
            pushed=True,
            commit_sha="c" * 40,
            message="Recovery commit pushed.",
        )

    def execute(self, request):
        self.requests.append(request)
        return self.result


class FakeDestroyOperationService:
    def __init__(self):
        self.requests = []
        self.result = DestroyWorkloadOperationResult(
            status="pushed_waiting_for_argocd",
            app_name="payments-api",
            source_path="gitops/workloads/devdeploy-apps",
            expected_paths=(),
            committed=True,
            pushed=True,
            commit_sha="e" * 40,
            message="Destroy commit pushed.",
        )

    def execute(self, request):
        self.requests.append(request)
        return self.result


class FakeUpdateOperationService:
    def __init__(self):
        self.requests = []
        self.result = UpdateWorkloadOperationResult(
            status="pushed_waiting_for_argocd",
            app_name="payments-api",
            source_path="gitops/workloads/devdeploy-apps",
            expected_paths=(),
            committed=True,
            pushed=True,
            commit_sha="f" * 40,
            message="Update commit pushed.",
        )

    def execute(self, request):
        self.requests.append(request)
        return self.result


class FakeDestroyRuntimeCleanupService:
    def __init__(self):
        self.calls = []
        self.result = DeploymentRuntimeCleanupResult(
            status="completed",
            deployment_deleted=True,
            service_deleted=True,
            message="Runtime cleanup completed.",
            checked_at=ProductDomainApiTestCase.fixed_datetime(),
        )

    def cleanup(self, deployment, *, destroy_commit_sha=None):
        self.calls.append(
            {
                "app_name": deployment.app_name,
                "namespace": deployment.namespace,
                "destroy_commit_sha": destroy_commit_sha,
            }
        )
        return self.result


class FakeRecoveryVerificationService:
    def __init__(self):
        self.calls = []
        self.result = DeploymentRecoveryVerificationResult(
            status="ready",
            message="Recovered runtime is ready.",
            checked_at=ProductDomainApiTestCase.fixed_datetime(),
        )

    def verify_recovered(self, deployment, *, recovery_commit_sha=None):
        self.calls.append(
            {
                "app_name": deployment.app_name,
                "namespace": deployment.namespace,
                "recovery_commit_sha": recovery_commit_sha,
            }
        )
        return self.result


class FakeWorkloadServiceProxy:
    def __init__(self):
        self.calls = []
        self.error: Exception | None = None
        self.response = ServiceProxyResponse(
            status_code=200,
            body=b"<html><body>preview</body></html>",
            headers={
                "Content-Type": "text/html; charset=utf-8",
                "Connection": "keep-alive",
                "Server": "internal-app-server",
                "Set-Cookie": "upstream_session=secret",
            },
        )

    def request(self, **kwargs) -> ServiceProxyResponse:
        self.calls.append(kwargs)
        if self.error is not None:
            raise self.error
        return self.response

    def get(self, **kwargs) -> ServiceProxyResponse:
        kwargs.setdefault("method", "GET")
        kwargs.setdefault("body", None)
        return self.request(**kwargs)


class NegotiatingWorkloadServiceProxy(FakeWorkloadServiceProxy):
    def request(self, **kwargs) -> ServiceProxyResponse:
        self.calls.append(kwargs)
        headers = kwargs.get("request_headers") or {}
        accept = headers.get("Accept", "")
        if "text/html" in accept:
            return ServiceProxyResponse(
                status_code=200,
                body=b"<html><body>podinfo ui</body></html>",
                headers={"Content-Type": "text/html; charset=utf-8"},
            )
        return ServiceProxyResponse(
            status_code=200,
            body=b'{"status":"json"}',
            headers={"Content-Type": "application/json"},
        )


class ProductDomainApiTestCase(unittest.TestCase):
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
        self.runtime_reader = FakeWorkloadRuntimeReader()
        self.manifest_reader = FakeGitOpsManifestReader()
        self.recover_operation = FakeRecoverOperationService()
        self.update_operation = FakeUpdateOperationService()
        self.destroy_operation = FakeDestroyOperationService()
        self.destroy_cleanup = FakeDestroyRuntimeCleanupService()
        self.recovery_verification = FakeRecoveryVerificationService()
        self.preview_proxy = FakeWorkloadServiceProxy()

        self.app = FastAPI()
        self.app.include_router(services.router, prefix="/api/v1")
        self.app.include_router(deployment_records.router, prefix="/api/v1")

        def override_get_db():
            yield self.db

        self.app.dependency_overrides[get_db] = override_get_db
        self.app.dependency_overrides[get_current_user] = lambda: self.current_user
        self.app.dependency_overrides[get_product_runtime_status_service] = lambda: ProductRuntimeStatusService(
            reader=self.runtime_reader,
            workload_namespace="devdeploy-apps",
        )
        self.app.dependency_overrides[get_deployment_drift_service] = lambda: DeploymentDriftService(
            manifest_reader=self.manifest_reader,
            runtime_service=ProductRuntimeStatusService(
                reader=self.runtime_reader,
                workload_namespace="devdeploy-apps",
            ),
        )
        self.app.dependency_overrides[
            get_workload_service_proxy_client
        ] = lambda: self.preview_proxy
        self.app.dependency_overrides[
            deployment_records.get_gitops_deploy_repository_config
        ] = lambda: deployment_records.GitOpsDeployRepositoryConfig(
            repo_root="C:/safe/devdeploy-repository",
            source_root_relative="gitops/workloads/devdeploy-apps",
            expected_branch="main",
            remote_name="origin",
            remote_branch="main",
        )
        self.app.dependency_overrides[
            deployment_records.get_deploy_workload_operation_service
        ] = lambda: self.recover_operation
        self.app.dependency_overrides[
            deployment_records.get_update_workload_operation_service
        ] = lambda: self.update_operation
        self.app.dependency_overrides[
            deployment_records.get_destroy_workload_operation_service
        ] = lambda: self.destroy_operation
        self.app.dependency_overrides[
            get_deployment_destroy_runtime_cleanup_service
        ] = lambda: self.destroy_cleanup
        self.app.dependency_overrides[
            get_deployment_recovery_verification_service
        ] = lambda: self.recovery_verification
        self.client = TestClient(self.app, base_url="https://testserver", raise_server_exceptions=False)

    def tearDown(self) -> None:
        self.client.close()
        self.db.close()
        Base.metadata.drop_all(self.engine)
        self.engine.dispose()

    @staticmethod
    def service_payload(name: str = "Payments API") -> dict:
        return {
            "name": name,
            "description": "Payment service definition",
            "default_image": "ghcr.io/example/payments:v1",
            "default_replicas": 2,
            "default_port": 8080,
        }

    @staticmethod
    def deployment_payload(service_id: int | None = None) -> dict:
        return {
            "service_definition_id": service_id,
            "app_name": "payments-api",
            "image": "ghcr.io/example/payments:v1",
            "replicas": 2,
            "container_port": 8080,
            "service_port": 80,
            "service_type": "ClusterIP",
            "namespace": "devdeploy-apps",
            "desired_state": "draft",
        }

    @staticmethod
    def fixed_datetime():
        from datetime import datetime, timezone

        return datetime(2026, 7, 6, 12, 0, tzinfo=timezone.utc)

    @staticmethod
    def ready_workload_snapshot() -> WorkloadSnapshot:
        return WorkloadSnapshot(
            deployment_exists=True,
            service_exists=True,
            desired_replicas=2,
            ready_replicas=2,
            available_replicas=2,
            updated_replicas=2,
            pod_count=2,
            running_pod_count=2,
            ready_pod_count=2,
            service_type="ClusterIP",
            service_cluster_ip="10.96.0.99",
            service_ports=(ServicePortSnapshot("http", 80, "http", "TCP"),),
        )

    def set_preview_cookie(self, *, user_id: int, deployment_id: int) -> None:
        self.client.cookies.set(
            PREVIEW_SESSION_COOKIE,
            create_preview_session_token(user_id=user_id, deployment_id=deployment_id),
            path=f"/api/v1/deployment-records/{deployment_id}/preview/",
        )

    def create_service(self, name: str = "Payments API") -> dict:
        response = self.client.post("/api/v1/services", json=self.service_payload(name))
        self.assertEqual(response.status_code, 201, response.text)
        return response.json()

    def create_deployment(self, service_id: int | None = None, **overrides) -> dict:
        response = self.client.post(
            "/api/v1/deployment-records",
            json={**self.deployment_payload(service_id), **overrides},
        )
        self.assertEqual(response.status_code, 201, response.text)
        return response.json()

    def create_gitops_deployment(self, service_id: int | None = None, **overrides) -> dict:
        return self.create_deployment(
            service_id,
            gitops_manifest_path="gitops/workloads/devdeploy-apps/apps/payments-api",
            commit_sha="a" * 40,
            desired_state="pending",
            status_summary="GitOps manifests published",
            **overrides,
        )

    def test_service_definition_create_list_get_and_update(self) -> None:
        created = self.create_service()

        listed = self.client.get("/api/v1/services")
        fetched = self.client.get(f"/api/v1/services/{created['id']}")
        updated = self.client.patch(
            f"/api/v1/services/{created['id']}",
            json={"name": "Payments Platform", "default_replicas": 3},
        )

        self.assertEqual(listed.status_code, 200)
        self.assertEqual([item["id"] for item in listed.json()], [created["id"]])
        self.assertEqual(fetched.status_code, 200)
        self.assertEqual(fetched.json()["owner_id"], self.user_a.id)
        self.assertEqual(updated.status_code, 200)
        self.assertEqual(updated.json()["name"], "Payments Platform")
        self.assertEqual(updated.json()["default_replicas"], 3)

    def test_deployment_record_create_list_get_and_update_without_gitops_execution(self) -> None:
        service = self.create_service()
        with patch(
            "app.services.gitops.deploy_operation.DeployWorkloadOperationService.execute"
        ) as execute_gitops:
            created = self.create_deployment(service["id"])

        execute_gitops.assert_not_called()
        listed = self.client.get("/api/v1/deployment-records")
        fetched = self.client.get(f"/api/v1/deployment-records/{created['id']}")
        updated = self.client.patch(
            f"/api/v1/deployment-records/{created['id']}",
            json={
                "desired_state": "pending",
                "gitops_manifest_path": "apps/payments-api",
                "commit_sha": "a" * 40,
                "status_summary": "Waiting for explicit GitOps publication",
            },
        )

        self.assertEqual(listed.status_code, 200)
        self.assertEqual([item["id"] for item in listed.json()], [created["id"]])
        self.assertEqual(fetched.status_code, 200)
        self.assertEqual(fetched.json()["owner_id"], self.user_a.id)
        self.assertEqual(updated.status_code, 200)
        self.assertEqual(updated.json()["desired_state"], "pending")
        self.assertEqual(updated.json()["commit_sha"], "a" * 40)

    def test_gitops_deployment_update_publishes_manifest_change_then_updates_domain_record(self) -> None:
        service = self.create_service()
        deployment = self.create_gitops_deployment(service["id"])

        response = self.client.patch(
            f"/api/v1/deployment-records/{deployment['id']}/gitops",
            json={
                "image": "ghcr.io/example/payments:v2",
                "replicas": 3,
                "container_port": 9090,
                "service_port": 8080,
                "preview_path": "ui",
            },
        )

        self.assertEqual(response.status_code, 202, response.text)
        body = response.json()
        self.assertEqual(body["status"], "updated")
        self.assertEqual(body["commit_sha"], "f" * 40)
        updated = body["deployment"]
        self.assertEqual(updated["image"], "ghcr.io/example/payments:v2")
        self.assertEqual(updated["replicas"], 3)
        self.assertEqual(updated["container_port"], 9090)
        self.assertEqual(updated["service_port"], 8080)
        self.assertEqual(updated["preview_path"], "/ui")
        self.assertEqual(updated["service_definition_id"], service["id"])

        self.assertEqual(len(self.update_operation.requests), 1)
        request = self.update_operation.requests[0]
        self.assertEqual(request.app_name, "payments-api")
        self.assertEqual(request.image, "ghcr.io/example/payments:v2")
        self.assertEqual(request.replicas, 3)
        self.assertEqual(request.container_port, 9090)
        self.assertEqual(request.service_port, 8080)
        self.assertEqual(request.service_type, "ClusterIP")
        self.assertEqual(request.namespace, "devdeploy-apps")

        refreshed_service = self.client.get(f"/api/v1/services/{service['id']}").json()
        self.assertEqual(refreshed_service["default_image"], "ghcr.io/example/payments:v2")
        self.assertEqual(refreshed_service["default_replicas"], 3)
        self.assertEqual(refreshed_service["default_port"], 8080)

    def test_gitops_deployment_update_supports_partial_replica_update(self) -> None:
        deployment = self.create_gitops_deployment()

        response = self.client.patch(
            f"/api/v1/deployment-records/{deployment['id']}/gitops",
            json={"replicas": 4},
        )

        self.assertEqual(response.status_code, 202, response.text)
        updated = response.json()["deployment"]
        self.assertEqual(updated["image"], deployment["image"])
        self.assertEqual(updated["replicas"], 4)
        self.assertEqual(updated["container_port"], deployment["container_port"])
        self.assertEqual(updated["service_port"], deployment["service_port"])
        self.assertEqual(self.update_operation.requests[0].replicas, 4)
        self.assertEqual(self.update_operation.requests[0].image, deployment["image"])

    def test_gitops_deployment_update_preview_path_only_preserves_commit_and_updates_access(self) -> None:
        deployment = self.create_gitops_deployment(preview_path="/")
        self.update_operation.result = UpdateWorkloadOperationResult(
            status="no_changes",
            app_name="payments-api",
            source_path="gitops/workloads/devdeploy-apps",
            expected_paths=(),
            committed=False,
            pushed=False,
            commit_sha="b" * 40,
            message="No manifest changes.",
        )
        self.runtime_reader.snapshots[("devdeploy-apps", "payments-api")] = self.ready_workload_snapshot()

        response = self.client.patch(
            f"/api/v1/deployment-records/{deployment['id']}/gitops",
            json={"preview_path": "ui"},
        )

        self.assertEqual(response.status_code, 202, response.text)
        self.assertEqual(response.json()["deployment"]["preview_path"], "/ui")
        self.assertEqual(response.json()["deployment"]["commit_sha"], deployment["commit_sha"])
        access = self.client.get(f"/api/v1/deployment-records/{deployment['id']}/access")
        self.assertEqual(access.status_code, 200, access.text)
        self.assertEqual(
            access.json()["preview_url"],
            f"/api/v1/deployment-records/{deployment['id']}/preview/ui",
        )

    def test_gitops_deployment_update_noop_does_not_call_gitops_operation(self) -> None:
        deployment = self.create_gitops_deployment(preview_path="/")

        response = self.client.patch(
            f"/api/v1/deployment-records/{deployment['id']}/gitops",
            json={
                "image": deployment["image"],
                "replicas": deployment["replicas"],
                "container_port": deployment["container_port"],
                "service_port": deployment["service_port"],
                "preview_path": "/",
            },
        )

        self.assertEqual(response.status_code, 202, response.text)
        self.assertEqual(response.json()["status"], "no_changes")
        self.assertEqual(self.update_operation.requests, [])

    def test_gitops_deployment_update_rejects_invalid_preview_path_and_port(self) -> None:
        deployment = self.create_gitops_deployment()

        invalid_preview = self.client.patch(
            f"/api/v1/deployment-records/{deployment['id']}/gitops",
            json={"preview_path": "https://attacker.example"},
        )
        invalid_port = self.client.patch(
            f"/api/v1/deployment-records/{deployment['id']}/gitops",
            json={"service_port": 70000},
        )

        self.assertEqual(invalid_preview.status_code, 422, invalid_preview.text)
        self.assertEqual(invalid_port.status_code, 422, invalid_port.text)
        self.assertEqual(self.update_operation.requests, [])

    def test_gitops_deployment_update_rejects_archived_destroyed_and_non_gitops_records(self) -> None:
        non_gitops = self.create_deployment()
        draft_gitops = self.create_deployment(
            app_name="draft-api",
            gitops_manifest_path="gitops/workloads/devdeploy-apps/apps/draft-api",
            commit_sha="a" * 40,
            desired_state="draft",
        )
        gitops = self.create_gitops_deployment(app_name="archived-api")
        destroyed = self.create_gitops_deployment(app_name="destroyed-api")
        archived_record = self.db.get(DeploymentRecord, gitops["id"])
        destroyed_record = self.db.get(DeploymentRecord, destroyed["id"])
        self.assertIsNotNone(archived_record)
        self.assertIsNotNone(destroyed_record)
        archived_record.archived_at = self.fixed_datetime()
        destroyed_record.desired_state = "destroyed"
        self.db.commit()

        non_gitops_response = self.client.patch(
            f"/api/v1/deployment-records/{non_gitops['id']}/gitops",
            json={"replicas": 3},
        )
        draft_gitops_response = self.client.patch(
            f"/api/v1/deployment-records/{draft_gitops['id']}/gitops",
            json={"replicas": 3},
        )
        archived_response = self.client.patch(
            f"/api/v1/deployment-records/{gitops['id']}/gitops",
            json={"replicas": 3},
        )
        destroyed_response = self.client.patch(
            f"/api/v1/deployment-records/{destroyed['id']}/gitops",
            json={"replicas": 3},
        )

        self.assertEqual(non_gitops_response.status_code, 409, non_gitops_response.text)
        self.assertEqual(draft_gitops_response.status_code, 409, draft_gitops_response.text)
        self.assertEqual(archived_response.status_code, 409, archived_response.text)
        self.assertEqual(destroyed_response.status_code, 409, destroyed_response.text)
        self.assertEqual(self.update_operation.requests, [])

    def test_gitops_deployment_update_failure_does_not_update_domain_record(self) -> None:
        deployment = self.create_gitops_deployment()
        self.update_operation.result = UpdateWorkloadOperationResult(
            status="push_failed",
            app_name="payments-api",
            source_path="gitops/workloads/devdeploy-apps",
            expected_paths=(),
            committed=True,
            pushed=False,
            commit_sha="f" * 40,
            message="remote rejected token=secret-value",
            error_code="git_push_failed",
        )

        response = self.client.patch(
            f"/api/v1/deployment-records/{deployment['id']}/gitops",
            json={"image": "ghcr.io/example/payments:v2"},
        )

        self.assertEqual(response.status_code, 502, response.text)
        self.assertNotIn("secret-value", response.text)
        self.db.expire_all()
        record = self.db.get(DeploymentRecord, deployment["id"])
        self.assertIsNotNone(record)
        self.assertEqual(record.image, deployment["image"])
        self.assertEqual(record.commit_sha, deployment["commit_sha"])

    def test_deployment_record_create_reactivates_archived_service_definition(self) -> None:
        service = self.create_service("payments-api")
        archived = self.client.post(f"/api/v1/services/{service['id']}/archive")
        self.assertEqual(archived.status_code, 200, archived.text)
        self.assertIsNotNone(archived.json()["archived_at"])

        deployment = self.create_deployment(service["id"])

        active_services = self.client.get("/api/v1/services").json()
        self.assertEqual(len(active_services), 1)
        self.assertEqual(active_services[0]["id"], service["id"])
        self.assertIsNone(active_services[0]["archived_at"])
        self.assertEqual(deployment["service_definition_id"], service["id"])

    def test_services_api_repairs_existing_active_deployment_linked_to_archived_service(self) -> None:
        service = self.create_service("payments-api")
        archived = self.client.post(f"/api/v1/services/{service['id']}/archive")
        self.assertEqual(archived.status_code, 200, archived.text)
        deployment = DeploymentRecord(
            owner_id=self.user_a.id,
            service_definition_id=service["id"],
            app_name="payments-api",
            image="ghcr.io/example/payments:v1",
            replicas=1,
            container_port=80,
            service_port=80,
            service_type="ClusterIP",
            namespace="devdeploy-apps",
            desired_state="pending",
        )
        self.db.add(deployment)
        self.db.commit()
        self.runtime_reader.discovered = (
            NamedWorkloadSnapshot(
                "payments-api",
                WorkloadSnapshot(
                    deployment_exists=True,
                    service_exists=True,
                    desired_replicas=1,
                    ready_replicas=1,
                    available_replicas=1,
                    updated_replicas=1,
                    pod_count=1,
                    running_pod_count=1,
                    ready_pod_count=1,
                    expected_service_port_exists=True,
                    service_type="ClusterIP",
                    service_cluster_ip="10.96.0.10",
                    service_ports=(ServicePortSnapshot("http", 80, "http", "TCP"),),
                ),
            ),
            NamedWorkloadSnapshot(
                "runtime-only",
                WorkloadSnapshot(
                    service_exists=True,
                    expected_service_port_exists=True,
                    service_type="ClusterIP",
                    service_cluster_ip="10.96.0.11",
                    service_ports=(ServicePortSnapshot("http", 80, "http", "TCP"),),
                ),
            ),
        )

        active_services = self.client.get("/api/v1/services")
        untracked_services = self.client.get("/api/v1/services/untracked")

        self.assertEqual(active_services.status_code, 200, active_services.text)
        self.assertEqual([item["id"] for item in active_services.json()], [service["id"]])
        self.assertIsNone(active_services.json()[0]["archived_at"])
        self.assertEqual(untracked_services.status_code, 200, untracked_services.text)
        self.assertEqual([item["name"] for item in untracked_services.json()["items"]], ["runtime-only"])

    def test_services_api_archives_service_linked_only_to_destroyed_deployments(self) -> None:
        service = self.create_service("payments-api")
        deployment = self.create_deployment(service["id"])
        record = self.db.get(DeploymentRecord, deployment["id"])
        self.assertIsNotNone(record)
        record.desired_state = "destroyed"
        record.archived_at = self.fixed_datetime()
        self.db.commit()

        active_services = self.client.get("/api/v1/services").json()
        archived_services = self.client.get("/api/v1/services", params={"archive_filter": "archived"}).json()

        self.assertEqual(active_services, [])
        self.assertEqual([item["id"] for item in archived_services], [service["id"]])
        self.assertIsNotNone(archived_services[0]["archived_at"])

    def test_services_api_keeps_service_active_when_another_deployment_still_uses_it(self) -> None:
        service = self.create_service("payments-api")
        first = self.create_deployment(service["id"])
        second_response = self.client.post(
            "/api/v1/deployment-records",
            json={**self.deployment_payload(service["id"]), "app_name": "payments-worker"},
        )
        self.assertEqual(second_response.status_code, 201, second_response.text)
        record = self.db.get(DeploymentRecord, first["id"])
        self.assertIsNotNone(record)
        record.desired_state = "destroyed"
        record.archived_at = self.fixed_datetime()
        self.db.commit()

        active_services = self.client.get("/api/v1/services").json()
        archived_services = self.client.get("/api/v1/services", params={"archive_filter": "archived"}).json()

        self.assertEqual([item["id"] for item in active_services], [service["id"]])
        self.assertEqual(archived_services, [])

    def test_user_cannot_list_get_or_update_another_users_records(self) -> None:
        service = self.create_service()
        deployment = self.create_deployment(service["id"])
        self.current_user = self.user_b

        self.assertEqual(self.client.get("/api/v1/services").json(), [])
        self.assertEqual(self.client.get("/api/v1/deployment-records").json(), [])
        self.assertEqual(self.client.get(f"/api/v1/services/{service['id']}").status_code, 403)
        self.assertEqual(
            self.client.patch(f"/api/v1/services/{service['id']}", json={"name": "Denied"}).status_code,
            403,
        )
        self.assertEqual(
            self.client.get(f"/api/v1/deployment-records/{deployment['id']}").status_code,
            403,
        )
        self.assertEqual(
            self.client.patch(
                f"/api/v1/deployment-records/{deployment['id']}",
                json={"desired_state": "pending"},
            ).status_code,
            403,
        )

    def test_service_archive_is_owner_scoped_idempotent_and_hidden_from_list(self) -> None:
        service = self.create_service()

        archived = self.client.post(f"/api/v1/services/{service['id']}/archive")
        listed = self.client.get("/api/v1/services")
        fetched = self.client.get(f"/api/v1/services/{service['id']}")
        archived_again = self.client.post(f"/api/v1/services/{service['id']}/archive")

        self.assertEqual(archived.status_code, 200, archived.text)
        self.assertIsNotNone(archived.json()["archived_at"])
        self.assertEqual(listed.status_code, 200)
        self.assertEqual(listed.json(), [])
        self.assertEqual(fetched.status_code, 200)
        self.assertEqual(fetched.json()["archived_at"], archived.json()["archived_at"])
        active_services = self.client.get("/api/v1/services").json()
        archived_services = self.client.get("/api/v1/services", params={"archive_filter": "archived"}).json()
        self.assertEqual(active_services, [])
        self.assertEqual([item["id"] for item in archived_services], [service["id"]])
        self.assertIsNotNone(archived_services[0]["archived_at"])
        self.assertEqual(archived_again.status_code, 200)
        self.assertEqual(archived_again.json()["archived_at"], archived.json()["archived_at"])

        self.current_user = self.user_b
        denied = self.client.post(f"/api/v1/services/{service['id']}/archive")
        self.assertEqual(denied.status_code, 403)

    def test_deployment_archive_is_owner_scoped_idempotent_and_hidden_from_list(self) -> None:
        service = self.create_service("payments-api")
        deployment = self.create_deployment(service["id"])

        archived = self.client.post(
            f"/api/v1/deployment-records/{deployment['id']}/archive"
        )
        listed = self.client.get("/api/v1/deployment-records")
        fetched = self.client.get(f"/api/v1/deployment-records/{deployment['id']}")
        archived_again = self.client.post(
            f"/api/v1/deployment-records/{deployment['id']}/archive"
        )

        self.assertEqual(archived.status_code, 200, archived.text)
        self.assertIsNotNone(archived.json()["archived_at"])
        self.assertEqual(listed.status_code, 200)
        self.assertEqual(listed.json(), [])
        self.assertEqual(fetched.status_code, 200)
        self.assertEqual(fetched.json()["archived_at"], archived.json()["archived_at"])
        active_services = self.client.get("/api/v1/services").json()
        archived_services = self.client.get("/api/v1/services", params={"archive_filter": "archived"}).json()
        self.assertEqual(active_services, [])
        self.assertEqual([item["id"] for item in archived_services], [service["id"]])
        self.assertIsNotNone(archived_services[0]["archived_at"])
        self.assertEqual(archived_again.status_code, 200)
        self.assertEqual(archived_again.json()["archived_at"], archived.json()["archived_at"])

        self.current_user = self.user_b
        denied = self.client.post(
            f"/api/v1/deployment-records/{deployment['id']}/archive"
        )
        self.assertEqual(denied.status_code, 403)

    def test_owner_can_recover_active_record_without_creating_duplicate_records(self) -> None:
        service = self.create_service("payments-api")
        deployment = self.create_deployment(service["id"])

        response = self.client.post(
            f"/api/v1/deployment-records/{deployment['id']}/recover"
        )

        self.assertEqual(response.status_code, 202, response.text)
        body = response.json()
        self.assertEqual(body["status"], "pushed_waiting_for_argocd")
        self.assertEqual(body["deployment_id"], deployment["id"])
        self.assertEqual(body["commit_sha"], "c" * 40)
        self.assertEqual(
            body["manifest_path"],
            "gitops/workloads/devdeploy-apps/apps/payments-api",
        )
        self.assertEqual(
            len(self.client.get("/api/v1/deployment-records", params={"archive_filter": "all"}).json()),
            1,
        )
        self.assertEqual(
            len(self.client.get("/api/v1/services", params={"archive_filter": "all"}).json()),
            1,
        )
        updated = self.client.get(f"/api/v1/deployment-records/{deployment['id']}").json()
        self.assertEqual(updated["commit_sha"], "c" * 40)
        self.assertEqual(updated["desired_state"], "pending")
        self.assertEqual(updated["status_summary"], "GitOps manifests published")
        operation_request = self.recover_operation.requests[0]
        self.assertEqual(operation_request.write_mode, "recover")
        self.assertEqual(operation_request.app_name, deployment["app_name"])
        self.assertEqual(operation_request.image, deployment["image"])
        self.assertEqual(operation_request.namespace, deployment["namespace"])

    def test_archived_deployment_record_cannot_be_recovered(self) -> None:
        deployment = self.create_deployment()
        self.assertEqual(
            self.client.post(f"/api/v1/deployment-records/{deployment['id']}/archive").status_code,
            200,
        )

        response = self.client.post(
            f"/api/v1/deployment-records/{deployment['id']}/recover"
        )

        self.assertEqual(response.status_code, 409)
        self.assertEqual(self.recover_operation.requests, [])

    def test_owner_can_recover_destroyed_archived_record_after_runtime_verification(self) -> None:
        service = self.create_service("payments-api")
        deployment = self.create_deployment(service["id"])
        destroyed = self.client.post(f"/api/v1/deployment-records/{deployment['id']}/destroy")
        self.assertEqual(destroyed.status_code, 202, destroyed.text)
        archived_services = self.client.get("/api/v1/services", params={"archive_filter": "archived"}).json()
        self.assertEqual([item["id"] for item in archived_services], [service["id"]])
        self.recover_operation.requests.clear()
        self.recovery_verification.calls.clear()

        response = self.client.post(
            f"/api/v1/deployment-records/{deployment['id']}/recover",
            json={
                "app_name": "attacker-app",
                "namespace": "kube-system",
                "repo_root": "../outside",
                "argo_application": "other-root",
            },
        )

        self.assertEqual(response.status_code, 202, response.text)
        body = response.json()
        self.assertEqual(body["status"], "recovered")
        self.assertEqual(body["deployment_id"], deployment["id"])
        self.assertEqual(body["commit_sha"], "c" * 40)
        self.assertEqual(
            body["manifest_path"],
            "gitops/workloads/devdeploy-apps/apps/payments-api",
        )
        updated = self.client.get(f"/api/v1/deployment-records/{deployment['id']}").json()
        self.assertIsNone(updated["archived_at"])
        self.assertEqual(updated["desired_state"], "pending")
        self.assertEqual(updated["service_definition_id"], service["id"])
        self.assertIn("previously destroyed", updated["status_summary"])
        self.assertEqual(
            len(self.client.get("/api/v1/deployment-records", params={"archive_filter": "all"}).json()),
            1,
        )
        active_services = self.client.get("/api/v1/services").json()
        self.assertEqual([item["id"] for item in active_services], [service["id"]])
        self.assertIsNone(active_services[0]["archived_at"])
        operation_request = self.recover_operation.requests[0]
        self.assertEqual(operation_request.write_mode, "restore_destroyed")
        self.assertEqual(operation_request.app_name, deployment["app_name"])
        self.assertEqual(operation_request.namespace, deployment["namespace"])
        self.assertEqual(operation_request.image, deployment["image"])
        self.assertEqual(
            self.recovery_verification.calls,
            [{"app_name": "payments-api", "namespace": "devdeploy-apps", "recovery_commit_sha": "c" * 40}],
        )

    def test_destroyed_recovery_runtime_pending_does_not_reactivate_record(self) -> None:
        service = self.create_service("payments-api")
        deployment = self.create_deployment(service["id"])
        self.assertEqual(
            self.client.post(f"/api/v1/deployment-records/{deployment['id']}/destroy").status_code,
            202,
        )
        self.recover_operation.requests.clear()
        self.recovery_verification.result = DeploymentRecoveryVerificationResult(
            status="pending",
            message="Recovery is waiting for Argo CD to process the GitOps revision.",
            checked_at=self.fixed_datetime(),
        )

        response = self.client.post(f"/api/v1/deployment-records/{deployment['id']}/recover")

        self.assertEqual(response.status_code, 202, response.text)
        self.assertEqual(response.json()["status"], "runtime_pending")
        updated = self.client.get(
            f"/api/v1/deployment-records/{deployment['id']}",
            params={"archive_filter": "all"},
        ).json()
        self.assertEqual(updated["desired_state"], "destroyed")
        self.assertIsNotNone(updated["archived_at"])
        self.assertEqual(updated["commit_sha"], "c" * 40)
        self.assertIn("recovery manifests published", updated["status_summary"])
        self.assertEqual(
            self.recovery_verification.calls,
            [{"app_name": "payments-api", "namespace": "devdeploy-apps", "recovery_commit_sha": "c" * 40}],
        )
        self.assertEqual(
            self.client.get("/api/v1/deployment-records", params={"archive_filter": "active"}).json(),
            [],
        )

    def test_destroyed_recovery_no_changes_retry_uses_recorded_recovery_commit(self) -> None:
        service = self.create_service("payments-api")
        deployment = self.create_deployment(service["id"])
        self.assertEqual(
            self.client.post(f"/api/v1/deployment-records/{deployment['id']}/destroy").status_code,
            202,
        )
        record = self.db.get(DeploymentRecord, deployment["id"])
        self.assertIsNotNone(record)
        record.commit_sha = "c" * 40
        record.status_summary = (
            "GitOps recovery manifests published; recovery is waiting for Argo CD "
            "and runtime readiness before reactivation."
        )
        self.db.commit()
        self.recover_operation.requests.clear()
        self.recovery_verification.calls.clear()
        self.recover_operation.result = DeployWorkloadOperationResult(
            status="no_changes",
            app_name="payments-api",
            source_path="gitops/workloads/devdeploy-apps",
            expected_paths=(),
            committed=False,
            pushed=False,
            commit_sha="f" * 40,
            message="The GitOps workload manifests already match the requested recovery state.",
        )

        response = self.client.post(f"/api/v1/deployment-records/{deployment['id']}/recover")

        self.assertEqual(response.status_code, 202, response.text)
        self.assertEqual(response.json()["status"], "recovered")
        self.assertEqual(response.json()["commit_sha"], "c" * 40)
        updated = self.client.get(f"/api/v1/deployment-records/{deployment['id']}").json()
        self.assertIsNone(updated["archived_at"])
        self.assertEqual(updated["desired_state"], "pending")
        self.assertEqual(updated["commit_sha"], "c" * 40)
        self.assertEqual(
            self.recovery_verification.calls,
            [{"app_name": "payments-api", "namespace": "devdeploy-apps", "recovery_commit_sha": "c" * 40}],
        )

    def test_destroyed_recovery_no_changes_without_recorded_commit_is_not_verified(self) -> None:
        service = self.create_service("payments-api")
        deployment = self.create_deployment(service["id"])
        self.assertEqual(
            self.client.post(f"/api/v1/deployment-records/{deployment['id']}/destroy").status_code,
            202,
        )
        record = self.db.get(DeploymentRecord, deployment["id"])
        self.assertIsNotNone(record)
        record.commit_sha = None
        self.db.commit()
        self.recover_operation.requests.clear()
        self.recovery_verification.calls.clear()
        self.recover_operation.result = DeployWorkloadOperationResult(
            status="no_changes",
            app_name="payments-api",
            source_path="gitops/workloads/devdeploy-apps",
            expected_paths=(),
            committed=False,
            pushed=False,
            commit_sha="f" * 40,
            message="The GitOps workload manifests already match the requested recovery state.",
        )

        response = self.client.post(f"/api/v1/deployment-records/{deployment['id']}/recover")

        self.assertEqual(response.status_code, 409, response.text)
        self.assertEqual(response.json()["status"], "recovery_failed")
        self.assertIsNone(response.json()["commit_sha"])
        self.assertEqual(self.recovery_verification.calls, [])
        updated = self.client.get(f"/api/v1/deployment-records/{deployment['id']}").json()
        self.assertEqual(updated["desired_state"], "destroyed")
        self.assertIsNotNone(updated["archived_at"])
        self.assertIsNone(updated["commit_sha"])

    def test_destroyed_recovery_runtime_conflict_does_not_reactivate_record(self) -> None:
        service = self.create_service("payments-api")
        deployment = self.create_deployment(service["id"])
        self.assertEqual(
            self.client.post(f"/api/v1/deployment-records/{deployment['id']}/destroy").status_code,
            202,
        )
        self.recover_operation.requests.clear()
        self.recovery_verification.result = DeploymentRecoveryVerificationResult(
            status="conflict",
            message="Recovered Deployment name is occupied by a resource without DevDeploy ownership.",
            checked_at=self.fixed_datetime(),
        )

        response = self.client.post(f"/api/v1/deployment-records/{deployment['id']}/recover")

        self.assertEqual(response.status_code, 409, response.text)
        self.assertEqual(response.json()["status"], "runtime_conflict")
        updated = self.client.get(f"/api/v1/deployment-records/{deployment['id']}").json()
        self.assertEqual(updated["desired_state"], "destroyed")
        self.assertIsNotNone(updated["archived_at"])

    def test_destroyed_recovery_git_failure_does_not_reactivate_record(self) -> None:
        service = self.create_service("payments-api")
        deployment = self.create_deployment(service["id"])
        self.assertEqual(
            self.client.post(f"/api/v1/deployment-records/{deployment['id']}/destroy").status_code,
            202,
        )
        self.recover_operation.requests.clear()
        self.recover_operation.result = DeployWorkloadOperationResult(
            status="push_failed",
            app_name="payments-api",
            source_path="gitops/workloads/devdeploy-apps",
            expected_paths=(),
            committed=True,
            pushed=False,
            commit_sha="d" * 40,
            message="fatal: https://user:super-secret@example.invalid/repository.git",
            error_code="git_push_failed",
        )

        response = self.client.post(f"/api/v1/deployment-records/{deployment['id']}/recover")

        self.assertEqual(response.status_code, 502)
        self.assertEqual(self.recovery_verification.calls, [])
        self.assertNotIn("user:super-secret", response.text)
        updated = self.client.get(f"/api/v1/deployment-records/{deployment['id']}").json()
        self.assertEqual(updated["desired_state"], "destroyed")
        self.assertIsNotNone(updated["archived_at"])

    def test_destroyed_recovery_requires_owned_service_definition(self) -> None:
        deployment = self.create_deployment()
        self.assertEqual(
            self.client.post(f"/api/v1/deployment-records/{deployment['id']}/destroy").status_code,
            202,
        )
        self.recover_operation.requests.clear()

        response = self.client.post(f"/api/v1/deployment-records/{deployment['id']}/recover")

        self.assertEqual(response.status_code, 409)
        self.assertEqual(self.recover_operation.requests, [])
        updated = self.client.get(f"/api/v1/deployment-records/{deployment['id']}").json()
        self.assertEqual(updated["desired_state"], "destroyed")

    def test_user_cannot_recover_another_users_deployment_record(self) -> None:
        deployment = self.create_deployment()
        self.current_user = self.user_b

        response = self.client.post(
            f"/api/v1/deployment-records/{deployment['id']}/recover"
        )

        self.assertEqual(response.status_code, 403)
        self.assertEqual(self.recover_operation.requests, [])

    def test_recover_missing_record_returns_not_found(self) -> None:
        response = self.client.post("/api/v1/deployment-records/99999/recover")

        self.assertEqual(response.status_code, 404)
        self.assertEqual(self.recover_operation.requests, [])

    def test_recover_no_change_reuses_existing_commit_and_record(self) -> None:
        deployment = self.create_deployment()
        existing_commit = "b" * 40
        self.assertEqual(
            self.client.patch(
                f"/api/v1/deployment-records/{deployment['id']}",
                json={
                    "commit_sha": existing_commit,
                    "gitops_manifest_path": "gitops/workloads/devdeploy-apps/apps/payments-api",
                    "desired_state": "pending",
                },
            ).status_code,
            200,
        )
        self.recover_operation.result = DeployWorkloadOperationResult(
            status="no_changes",
            app_name="payments-api",
            source_path="gitops/workloads/devdeploy-apps",
            expected_paths=(),
            committed=False,
            pushed=False,
            commit_sha=None,
            message="No changes.",
        )

        response = self.client.post(
            f"/api/v1/deployment-records/{deployment['id']}/recover"
        )

        self.assertEqual(response.status_code, 202)
        self.assertEqual(response.json()["status"], "no_changes_waiting_for_argocd")
        self.assertEqual(response.json()["commit_sha"], existing_commit)
        self.assertEqual(
            len(self.client.get("/api/v1/deployment-records", params={"archive_filter": "all"}).json()),
            1,
        )

    def test_recover_failure_returns_sanitized_git_message(self) -> None:
        deployment = self.create_deployment()
        self.recover_operation.result = DeployWorkloadOperationResult(
            status="push_failed",
            app_name="payments-api",
            source_path="gitops/workloads/devdeploy-apps",
            expected_paths=(),
            committed=True,
            pushed=False,
            commit_sha="d" * 40,
            message="fatal: https://user:super-secret@example.invalid/repository.git",
            error_code="git_push_failed",
        )

        response = self.client.post(
            f"/api/v1/deployment-records/{deployment['id']}/recover"
        )

        self.assertEqual(response.status_code, 502)
        self.assertNotIn("user:super-secret", response.text)
        self.assertIn("<redacted>", response.json()["message"])

    def test_owner_can_reconcile_active_record_without_duplicate_product_records(self) -> None:
        service = self.create_service("payments-api")
        deployment = self.create_deployment(service["id"])

        response = self.client.post(
            f"/api/v1/deployment-records/{deployment['id']}/reconcile"
        )

        self.assertEqual(response.status_code, 202, response.text)
        body = response.json()
        self.assertEqual(body["status"], "pushed_waiting_for_argocd")
        self.assertEqual(body["deployment_id"], deployment["id"])
        self.assertEqual(body["commit_sha"], "c" * 40)
        self.assertEqual(
            body["manifest_path"],
            "gitops/workloads/devdeploy-apps/apps/payments-api",
        )
        self.assertEqual(
            len(self.client.get("/api/v1/deployment-records", params={"archive_filter": "all"}).json()),
            1,
        )
        self.assertEqual(
            len(self.client.get("/api/v1/services", params={"archive_filter": "all"}).json()),
            1,
        )
        updated = self.client.get(f"/api/v1/deployment-records/{deployment['id']}").json()
        self.assertEqual(updated["commit_sha"], "c" * 40)
        self.assertEqual(updated["desired_state"], "pending")
        self.assertEqual(updated["status_summary"], "GitOps manifests published")
        operation_request = self.recover_operation.requests[0]
        self.assertEqual(operation_request.write_mode, "reconcile")
        self.assertEqual(operation_request.app_name, deployment["app_name"])
        self.assertEqual(operation_request.image, deployment["image"])

    def test_archived_cross_owner_and_missing_records_cannot_be_reconciled(self) -> None:
        deployment = self.create_deployment()
        self.assertEqual(
            self.client.post(f"/api/v1/deployment-records/{deployment['id']}/archive").status_code,
            200,
        )
        archived = self.client.post(
            f"/api/v1/deployment-records/{deployment['id']}/reconcile"
        )
        self.assertEqual(archived.status_code, 409)
        self.assertEqual(self.recover_operation.requests, [])

        self.current_user = self.user_b
        denied = self.client.post(
            f"/api/v1/deployment-records/{deployment['id']}/reconcile"
        )
        self.assertEqual(denied.status_code, 403)
        self.assertEqual(self.recover_operation.requests, [])

        self.current_user = self.user_a
        missing = self.client.post("/api/v1/deployment-records/99999/reconcile")
        self.assertEqual(missing.status_code, 404)
        self.assertEqual(self.recover_operation.requests, [])

    def test_reconcile_no_change_reuses_existing_commit_without_duplicate_record(self) -> None:
        deployment = self.create_deployment()
        existing_commit = "b" * 40
        self.assertEqual(
            self.client.patch(
                f"/api/v1/deployment-records/{deployment['id']}",
                json={
                    "commit_sha": existing_commit,
                    "gitops_manifest_path": "gitops/workloads/devdeploy-apps/apps/payments-api",
                    "desired_state": "pending",
                },
            ).status_code,
            200,
        )
        self.recover_operation.result = DeployWorkloadOperationResult(
            status="no_changes",
            app_name="payments-api",
            source_path="gitops/workloads/devdeploy-apps",
            expected_paths=(),
            committed=False,
            pushed=False,
            commit_sha=None,
            message="No changes.",
        )

        response = self.client.post(
            f"/api/v1/deployment-records/{deployment['id']}/reconcile"
        )

        self.assertEqual(response.status_code, 202)
        self.assertEqual(response.json()["status"], "no_changes")
        self.assertEqual(response.json()["commit_sha"], existing_commit)
        self.assertIn("already aligned", response.json()["message"])
        self.assertEqual(
            len(self.client.get("/api/v1/deployment-records", params={"archive_filter": "all"}).json()),
            1,
        )

    def test_owner_can_destroy_active_record_without_deleting_service_definition(self) -> None:
        service = self.create_service("payments-api")
        deployment = self.create_deployment(service["id"])
        self.assertEqual(
            self.client.patch(
                f"/api/v1/deployment-records/{deployment['id']}",
                json={
                    "desired_state": "pending",
                    "gitops_manifest_path": "gitops/workloads/devdeploy-apps/apps/payments-api",
                    "commit_sha": "a" * 40,
                },
            ).status_code,
            200,
        )

        response = self.client.post(
            f"/api/v1/deployment-records/{deployment['id']}/destroy",
            json={
                "app_name": "../other-app",
                "namespace": "kube-system",
                "manifest_path": "../../outside",
            },
        )

        self.assertEqual(response.status_code, 202, response.text)
        body = response.json()
        self.assertEqual(body["status"], "destroyed")
        self.assertEqual(body["deployment_id"], deployment["id"])
        self.assertEqual(body["commit_sha"], "e" * 40)
        self.assertEqual(body["runtime_cleanup"]["status"], "completed")
        self.assertEqual(
            body["manifest_path"],
            "gitops/workloads/devdeploy-apps/apps/payments-api",
        )
        updated = self.client.get(f"/api/v1/deployment-records/{deployment['id']}").json()
        self.assertEqual(updated["desired_state"], "destroyed")
        self.assertIsNotNone(updated["archived_at"])
        self.assertEqual(self.client.get("/api/v1/deployment-records").json(), [])
        self.assertEqual(
            len(self.client.get("/api/v1/deployment-records", params={"archive_filter": "all"}).json()),
            1,
        )
        active_services = self.client.get("/api/v1/services").json()
        archived_services = self.client.get("/api/v1/services", params={"archive_filter": "archived"}).json()
        all_services = self.client.get("/api/v1/services", params={"archive_filter": "all"}).json()
        self.assertEqual(active_services, [])
        self.assertEqual([item["id"] for item in archived_services], [service["id"]])
        self.assertIsNotNone(archived_services[0]["archived_at"])
        self.assertEqual(len(all_services), 1)
        self.assertEqual(
            self.destroy_cleanup.calls,
            [{"app_name": "payments-api", "namespace": "devdeploy-apps", "destroy_commit_sha": "e" * 40}],
        )
        operation_request = self.destroy_operation.requests[0]
        self.assertEqual(operation_request.app_name, "payments-api")
        self.assertEqual(operation_request.source_root_relative, "gitops/workloads/devdeploy-apps")

    def test_destroying_one_of_multiple_active_records_keeps_shared_service_active(self) -> None:
        service = self.create_service("payments-api")
        first = self.create_deployment(service["id"])
        second_response = self.client.post(
            "/api/v1/deployment-records",
            json={**self.deployment_payload(service["id"]), "app_name": "payments-worker"},
        )
        self.assertEqual(second_response.status_code, 201, second_response.text)

        response = self.client.post(f"/api/v1/deployment-records/{first['id']}/destroy")

        self.assertEqual(response.status_code, 202, response.text)
        active_services = self.client.get("/api/v1/services").json()
        archived_services = self.client.get("/api/v1/services", params={"archive_filter": "archived"}).json()
        active_deployments = self.client.get("/api/v1/deployment-records").json()
        self.assertEqual([item["id"] for item in active_services], [service["id"]])
        self.assertEqual(archived_services, [])
        self.assertEqual([item["app_name"] for item in active_deployments], ["payments-worker"])

    def test_destroy_no_changes_archives_record_without_empty_commit(self) -> None:
        deployment = self.create_deployment()
        self.destroy_operation.result = DestroyWorkloadOperationResult(
            status="no_changes",
            app_name="payments-api",
            source_path="gitops/workloads/devdeploy-apps",
            expected_paths=(),
            committed=False,
            pushed=False,
            commit_sha="f" * 40,
            message="Already absent.",
        )
        self.destroy_cleanup.result = DeploymentRuntimeCleanupResult(
            status="not_required",
            deployment_deleted=False,
            service_deleted=False,
            message="No runtime resources.",
            checked_at=self.fixed_datetime(),
        )

        response = self.client.post(
            f"/api/v1/deployment-records/{deployment['id']}/destroy"
        )

        self.assertEqual(response.status_code, 202)
        self.assertEqual(response.json()["status"], "no_changes")
        updated = self.client.get(f"/api/v1/deployment-records/{deployment['id']}").json()
        self.assertEqual(updated["desired_state"], "destroyed")
        self.assertEqual(updated["commit_sha"], "f" * 40)
        self.assertIsNotNone(updated["archived_at"])
        self.assertEqual(
            self.destroy_cleanup.calls,
            [{"app_name": "payments-api", "namespace": "devdeploy-apps", "destroy_commit_sha": "f" * 40}],
        )

    def test_destroy_reports_runtime_cleanup_pending_but_preserves_destroyed_record(self) -> None:
        deployment = self.create_deployment()
        self.destroy_cleanup.result = DeploymentRuntimeCleanupResult(
            status="unavailable",
            deployment_deleted=False,
            service_deleted=False,
            message="Runtime cleanup unavailable.",
            checked_at=self.fixed_datetime(),
        )

        response = self.client.post(
            f"/api/v1/deployment-records/{deployment['id']}/destroy"
        )

        self.assertEqual(response.status_code, 202)
        self.assertEqual(response.json()["status"], "runtime_cleanup_pending")
        self.assertEqual(response.json()["runtime_cleanup"]["status"], "unavailable")
        updated = self.client.get(f"/api/v1/deployment-records/{deployment['id']}").json()
        self.assertEqual(updated["desired_state"], "destroyed")
        self.assertIsNotNone(updated["archived_at"])

    def test_destroyed_archived_record_can_retry_pending_runtime_cleanup(self) -> None:
        service = self.create_service("payments-api")
        deployment = self.create_deployment(service["id"])
        response = self.client.post(f"/api/v1/deployment-records/{deployment['id']}/destroy")
        self.assertEqual(response.status_code, 202)
        archived_services = self.client.get("/api/v1/services", params={"archive_filter": "archived"}).json()
        self.assertEqual([item["id"] for item in archived_services], [service["id"]])
        self.destroy_operation.requests.clear()
        self.destroy_cleanup.calls.clear()
        self.destroy_cleanup.result = DeploymentRuntimeCleanupResult(
            status="completed",
            deployment_deleted=True,
            service_deleted=True,
            message="Runtime cleanup completed.",
            checked_at=self.fixed_datetime(),
        )

        retry = self.client.post(f"/api/v1/deployment-records/{deployment['id']}/destroy")

        self.assertEqual(retry.status_code, 202)
        self.assertEqual(retry.json()["status"], "destroyed")
        self.assertEqual(self.destroy_operation.requests, [])
        archived_after_retry = self.client.get("/api/v1/services", params={"archive_filter": "archived"}).json()
        self.assertEqual([item["id"] for item in archived_after_retry], [service["id"]])
        self.assertEqual(
            self.destroy_cleanup.calls,
            [{"app_name": "payments-api", "namespace": "devdeploy-apps", "destroy_commit_sha": "e" * 40}],
        )

    def test_destroy_failure_does_not_update_record_or_run_runtime_cleanup(self) -> None:
        deployment = self.create_deployment()
        self.destroy_operation.result = DestroyWorkloadOperationResult(
            status="push_failed",
            app_name="payments-api",
            source_path="gitops/workloads/devdeploy-apps",
            expected_paths=(),
            committed=True,
            pushed=False,
            commit_sha="d" * 40,
            message="fatal: https://user:super-secret@example.invalid/repository.git",
            error_code="git_push_failed",
        )

        response = self.client.post(
            f"/api/v1/deployment-records/{deployment['id']}/destroy"
        )

        self.assertEqual(response.status_code, 502)
        self.assertIn("<redacted>", response.json()["message"])
        self.assertEqual(self.destroy_cleanup.calls, [])
        updated = self.client.get(f"/api/v1/deployment-records/{deployment['id']}").json()
        self.assertEqual(updated["desired_state"], "draft")
        self.assertIsNone(updated["archived_at"])

    def test_archived_cross_owner_and_missing_records_cannot_be_destroyed(self) -> None:
        deployment = self.create_deployment()
        self.assertEqual(
            self.client.post(f"/api/v1/deployment-records/{deployment['id']}/archive").status_code,
            200,
        )
        archived = self.client.post(
            f"/api/v1/deployment-records/{deployment['id']}/destroy"
        )
        self.assertEqual(archived.status_code, 409)
        self.assertEqual(self.destroy_operation.requests, [])

        self.current_user = self.user_b
        denied = self.client.post(
            f"/api/v1/deployment-records/{deployment['id']}/destroy"
        )
        self.assertEqual(denied.status_code, 403)
        self.assertEqual(self.destroy_operation.requests, [])

        self.current_user = self.user_a
        missing = self.client.post("/api/v1/deployment-records/99999/destroy")
        self.assertEqual(missing.status_code, 404)
        self.assertEqual(self.destroy_operation.requests, [])

    def test_service_list_filters_active_archived_and_all_with_owner_isolation(self) -> None:
        archived_service = self.create_service("Archived Service")
        active_service = self.create_service("Active Service")
        self.assertEqual(
            self.client.post(f"/api/v1/services/{archived_service['id']}/archive").status_code,
            200,
        )

        active = self.client.get("/api/v1/services")
        archived = self.client.get("/api/v1/services", params={"archive_filter": "archived"})
        all_records = self.client.get("/api/v1/services", params={"archive_filter": "all"})

        self.assertEqual([item["id"] for item in active.json()], [active_service["id"]])
        self.assertEqual([item["id"] for item in archived.json()], [archived_service["id"]])
        self.assertEqual(
            {item["id"] for item in all_records.json()},
            {active_service["id"], archived_service["id"]},
        )
        self.assertIsNone(active.json()[0]["archived_at"])
        self.assertIsNotNone(archived.json()[0]["archived_at"])

        self.user_b.role = "admin"
        self.db.commit()
        self.current_user = self.user_b
        for archive_filter in ("active", "archived", "all"):
            response = self.client.get(
                "/api/v1/services",
                params={"archive_filter": archive_filter},
            )
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.json(), [])

    def test_deployment_list_filters_active_archived_and_all_with_owner_isolation(self) -> None:
        archived_deployment = self.create_deployment()
        active_deployment = self.create_deployment()
        self.assertEqual(
            self.client.post(
                f"/api/v1/deployment-records/{archived_deployment['id']}/archive"
            ).status_code,
            200,
        )

        active = self.client.get("/api/v1/deployment-records")
        archived = self.client.get(
            "/api/v1/deployment-records",
            params={"archive_filter": "archived"},
        )
        all_records = self.client.get(
            "/api/v1/deployment-records",
            params={"archive_filter": "all"},
        )

        self.assertEqual([item["id"] for item in active.json()], [active_deployment["id"]])
        self.assertEqual(
            [item["id"] for item in archived.json()],
            [archived_deployment["id"]],
        )
        self.assertEqual(
            {item["id"] for item in all_records.json()},
            {active_deployment["id"], archived_deployment["id"]},
        )
        self.assertIsNone(active.json()[0]["archived_at"])
        self.assertIsNotNone(archived.json()[0]["archived_at"])

        self.current_user = self.user_b
        for archive_filter in ("active", "archived", "all"):
            response = self.client.get(
                "/api/v1/deployment-records",
                params={"archive_filter": archive_filter},
            )
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.json(), [])

    def test_invalid_archive_filter_is_rejected(self) -> None:
        services_response = self.client.get(
            "/api/v1/services",
            params={"archive_filter": "deleted"},
        )
        deployments_response = self.client.get(
            "/api/v1/deployment-records",
            params={"archive_filter": "deleted"},
        )

        self.assertEqual(services_response.status_code, 422)
        self.assertEqual(deployments_response.status_code, 422)

    def test_owner_can_delete_active_and_archived_deployment_records(self) -> None:
        active = self.create_deployment()
        archived = self.create_deployment()
        self.assertEqual(
            self.client.post(f"/api/v1/deployment-records/{archived['id']}/archive").status_code,
            200,
        )

        self.assertEqual(
            self.client.delete(f"/api/v1/deployment-records/{active['id']}").status_code,
            204,
        )
        self.assertEqual(
            self.client.delete(f"/api/v1/deployment-records/{archived['id']}").status_code,
            204,
        )

        for archive_filter in ("active", "archived", "all"):
            response = self.client.get(
                "/api/v1/deployment-records",
                params={"archive_filter": archive_filter},
            )
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.json(), [])
        self.assertEqual(
            self.client.get(f"/api/v1/deployment-records/{active['id']}").status_code,
            404,
        )
        self.assertEqual(self.client.delete("/api/v1/deployment-records/99999").status_code, 404)

    def test_user_cannot_delete_another_users_deployment_record(self) -> None:
        deployment = self.create_deployment()
        self.current_user = self.user_b

        denied = self.client.delete(f"/api/v1/deployment-records/{deployment['id']}")

        self.assertEqual(denied.status_code, 403)
        self.current_user = self.user_a
        self.assertEqual(
            self.client.get(f"/api/v1/deployment-records/{deployment['id']}").status_code,
            200,
        )

    def test_owner_can_delete_unreferenced_active_and_archived_services(self) -> None:
        active = self.create_service("Active Service")
        archived = self.create_service("Archived Service")
        self.assertEqual(
            self.client.post(f"/api/v1/services/{archived['id']}/archive").status_code,
            200,
        )

        self.assertEqual(self.client.delete(f"/api/v1/services/{active['id']}").status_code, 204)
        self.assertEqual(self.client.delete(f"/api/v1/services/{archived['id']}").status_code, 204)
        self.assertEqual(
            self.client.get("/api/v1/services", params={"archive_filter": "all"}).json(),
            [],
        )

    def test_service_delete_is_blocked_while_any_deployment_record_references_it(self) -> None:
        service = self.create_service()
        deployment = self.create_deployment(service["id"])
        self.assertEqual(
            self.client.post(f"/api/v1/deployment-records/{deployment['id']}/archive").status_code,
            200,
        )

        response = self.client.delete(f"/api/v1/services/{service['id']}")

        self.assertEqual(response.status_code, 409)
        self.assertEqual(response.json()["detail"], "Service definition is still used by deployment records.")
        self.assertEqual(self.client.get(f"/api/v1/services/{service['id']}").status_code, 200)

    def test_user_cannot_delete_another_users_service(self) -> None:
        service = self.create_service()
        self.current_user = self.user_b

        denied = self.client.delete(f"/api/v1/services/{service['id']}")

        self.assertEqual(denied.status_code, 403)
        self.current_user = self.user_a
        self.assertEqual(self.client.get(f"/api/v1/services/{service['id']}").status_code, 200)

    def test_cross_owner_service_link_is_denied(self) -> None:
        service = self.create_service()
        self.current_user = self.user_b

        response = self.client.post(
            "/api/v1/deployment-records",
            json=self.deployment_payload(service["id"]),
        )

        self.assertEqual(response.status_code, 403)

    def test_invalid_domain_inputs_are_rejected(self) -> None:
        invalid_service = self.client.post(
            "/api/v1/services",
            json=self.service_payload("  "),
        )
        invalid_app = self.client.post(
            "/api/v1/deployment-records",
            json={**self.deployment_payload(), "app_name": "Invalid_Name"},
        )
        unsafe_path = self.client.post(
            "/api/v1/deployment-records",
            json={**self.deployment_payload(), "gitops_manifest_path": "../outside"},
        )

        self.assertEqual(invalid_service.status_code, 422)
        self.assertEqual(invalid_app.status_code, 422)
        self.assertEqual(unsafe_path.status_code, 422)

    def test_routes_require_authentication(self) -> None:
        self.app.dependency_overrides.pop(get_current_user)

        self.assertEqual(self.client.get("/api/v1/services").status_code, 401)
        self.assertEqual(self.client.get("/api/v1/deployment-records").status_code, 401)
        self.assertEqual(self.client.post("/api/v1/services/1/archive").status_code, 401)
        self.assertEqual(self.client.post("/api/v1/deployment-records/1/archive").status_code, 401)
        self.assertEqual(self.client.post("/api/v1/deployment-records/1/recover").status_code, 401)
        self.assertEqual(self.client.post("/api/v1/deployment-records/1/reconcile").status_code, 401)
        self.assertEqual(self.client.get("/api/v1/deployment-records/1/access").status_code, 401)
        self.assertEqual(self.client.delete("/api/v1/services/1").status_code, 401)
        self.assertEqual(self.client.delete("/api/v1/deployment-records/1").status_code, 401)

    def test_deployment_record_list_and_get_include_running_runtime_status(self) -> None:
        service = self.create_service("payments-api")
        deployment = self.create_deployment(service["id"])
        self.runtime_reader.snapshots[("devdeploy-apps", "payments-api")] = WorkloadSnapshot(
            deployment_exists=True,
            service_exists=True,
            deployment_image="ghcr.io/example/payments:v1",
            container_port=8080,
            desired_replicas=2,
            ready_replicas=2,
            available_replicas=2,
            updated_replicas=2,
            expected_service_port_exists=True,
            pod_count=2,
            running_pod_count=2,
            ready_pod_count=2,
            service_type="ClusterIP",
            service_cluster_ip="10.96.0.10",
            service_ports=(ServicePortSnapshot("http", 80, "http", "TCP"),),
        )

        listed = self.client.get("/api/v1/deployment-records")
        fetched = self.client.get(f"/api/v1/deployment-records/{deployment['id']}")

        self.assertEqual(listed.status_code, 200)
        self.assertEqual(fetched.status_code, 200)
        self.assertEqual(len(listed.json()), 1)
        for runtime in (listed.json()[0]["runtime_status"], fetched.json()["runtime_status"]):
            self.assertEqual(runtime["display_status"], "running")
            self.assertTrue(runtime["deployment_found"])
            self.assertEqual(runtime["ready_replicas"], 2)
            self.assertEqual(runtime["available_replicas"], 2)
            self.assertEqual(runtime["pod_ready_count"], 2)
            self.assertEqual(runtime["service_cluster_ip"], "10.96.0.10")
        for drift in (listed.json()[0]["drift_status"], fetched.json()["drift_status"]):
            self.assertEqual(drift["status"], "gitops_missing")
            self.assertEqual(drift["db_to_gitops"]["status"], "missing")
            self.assertEqual(drift["db_to_runtime"]["status"], "aligned")

        listed_again = self.client.get("/api/v1/deployment-records")
        self.assertEqual(listed_again.status_code, 200)
        self.assertEqual(len(listed_again.json()), 1)

    def test_product_lists_include_safe_not_found_runtime_status(self) -> None:
        service = self.create_service("payments-api")
        self.create_deployment(service["id"])

        deployment_runtime = self.client.get("/api/v1/deployment-records").json()[0]["runtime_status"]
        service_runtime = self.client.get("/api/v1/services").json()[0]["runtime_status"]

        self.assertEqual(deployment_runtime["display_status"], "not_found")
        self.assertFalse(deployment_runtime["deployment_found"])
        self.assertEqual(service_runtime["display_status"], "not_found")
        self.assertFalse(service_runtime["service_found"])

    def test_product_lists_handle_runtime_reader_failure_without_500(self) -> None:
        service = self.create_service("payments-api")
        self.create_deployment(service["id"])
        self.runtime_reader.error = RuntimeError("raw kubeconfig and credential detail")

        deployments_response = self.client.get("/api/v1/deployment-records")
        services_response = self.client.get("/api/v1/services")

        self.assertEqual(deployments_response.status_code, 200)
        self.assertEqual(services_response.status_code, 200)
        deployment_runtime = deployments_response.json()[0]["runtime_status"]
        deployment_drift = deployments_response.json()[0]["drift_status"]
        service_runtime = services_response.json()[0]["runtime_status"]
        self.assertEqual(deployment_runtime["display_status"], "unknown")
        self.assertEqual(service_runtime["display_status"], "unknown")
        self.assertEqual(deployment_drift["status"], "unknown")
        self.assertEqual(deployment_drift["db_to_runtime"]["status"], "unknown")
        self.assertNotIn("kubeconfig", str(deployment_runtime).lower())
        self.assertNotIn("kubeconfig", str(deployment_drift).lower())
        self.assertNotIn("credential", str(service_runtime).lower())

    def test_service_list_includes_ready_runtime_details(self) -> None:
        self.create_service("payments-api")
        self.runtime_reader.snapshots[("devdeploy-apps", "payments-api")] = WorkloadSnapshot(
            deployment_exists=True,
            service_exists=True,
            desired_replicas=1,
            ready_replicas=1,
            available_replicas=1,
            pod_count=1,
            ready_pod_count=1,
            expected_service_port_exists=True,
            service_type="ClusterIP",
            service_cluster_ip="10.96.0.20",
            service_ports=(ServicePortSnapshot("http", 80, "http", "TCP"),),
        )

        response = self.client.get("/api/v1/services")

        self.assertEqual(response.status_code, 200)
        runtime = response.json()[0]["runtime_status"]
        self.assertEqual(runtime["display_status"], "ready")
        self.assertEqual(runtime["namespace"], "devdeploy-apps")
        self.assertEqual(runtime["service_type"], "ClusterIP")
        self.assertEqual(runtime["cluster_ip"], "10.96.0.20")
        self.assertEqual(runtime["ports"][0]["port"], 80)
        self.assertTrue(runtime["related_deployment_found"])
        self.assertEqual(runtime["related_deployment_status"], "running")

    @staticmethod
    def discovered_workload(name: str) -> NamedWorkloadSnapshot:
        return NamedWorkloadSnapshot(
            name=name,
            workload=WorkloadSnapshot(
                deployment_exists=True,
                service_exists=True,
                desired_replicas=1,
                ready_replicas=1,
                available_replicas=1,
                updated_replicas=1,
                expected_service_port_exists=True,
                pod_count=1,
                running_pod_count=1,
                ready_pod_count=1,
                service_type="ClusterIP",
                service_cluster_ip="10.96.0.30",
                service_ports=(ServicePortSnapshot("http", 80, "http", "TCP"),),
            ),
        )

    def test_untracked_endpoints_exclude_current_users_managed_resources(self) -> None:
        service = self.create_service("payments-api")
        self.create_deployment(service["id"])
        self.runtime_reader.discovered = (
            self.discovered_workload("payments-api"),
            self.discovered_workload("legacy-api"),
        )

        deployments_response = self.client.get("/api/v1/deployment-records/untracked")
        services_response = self.client.get("/api/v1/services/untracked")

        self.assertEqual(deployments_response.status_code, 200)
        self.assertEqual(services_response.status_code, 200)
        self.assertEqual(
            [item["name"] for item in deployments_response.json()["items"]],
            ["legacy-api"],
        )
        self.assertEqual(
            [item["name"] for item in services_response.json()["items"]],
            ["legacy-api"],
        )
        deployment = deployments_response.json()["items"][0]
        self.assertEqual(deployment["tracking_status"], "untracked")
        self.assertEqual(deployment["display_status"], "running")
        self.assertEqual(deployment["pod_ready_count"], 1)
        service_runtime = services_response.json()["items"][0]
        self.assertEqual(service_runtime["tracking_status"], "untracked")
        self.assertEqual(service_runtime["display_status"], "ready")
        self.assertEqual(service_runtime["cluster_ip"], "10.96.0.30")

    def test_runtime_resource_is_untracked_for_user_without_owned_record(self) -> None:
        service = self.create_service("payments-api")
        self.create_deployment(service["id"])
        self.runtime_reader.discovered = (self.discovered_workload("payments-api"),)
        self.current_user = self.user_b

        deployments_response = self.client.get("/api/v1/deployment-records/untracked")
        services_response = self.client.get("/api/v1/services/untracked")

        self.assertEqual([item["name"] for item in deployments_response.json()["items"]], ["payments-api"])
        self.assertEqual([item["name"] for item in services_response.json()["items"]], ["payments-api"])
        self.assertNotIn("owner_id", str(deployments_response.json()))
        self.assertNotIn("owner_id", str(services_response.json()))

    def test_untracked_reader_failure_returns_safe_empty_responses(self) -> None:
        self.runtime_reader.error = RuntimeError("raw kubeconfig credential detail")

        deployments_response = self.client.get("/api/v1/deployment-records/untracked")
        services_response = self.client.get("/api/v1/services/untracked")

        self.assertEqual(deployments_response.status_code, 200)
        self.assertEqual(services_response.status_code, 200)
        for body in (deployments_response.json(), services_response.json()):
            self.assertFalse(body["runtime_available"])
            self.assertEqual(body["items"], [])
            self.assertNotIn("kubeconfig", str(body).lower())
            self.assertNotIn("credential", str(body).lower())

    def test_owner_can_check_ready_app_access_without_cluster_ip_exposure(self) -> None:
        deployment = self.create_deployment()
        self.runtime_reader.snapshots[("devdeploy-apps", "payments-api")] = (
            self.ready_workload_snapshot()
        )

        response = self.client.get(f"/api/v1/deployment-records/{deployment['id']}/access")

        self.assertEqual(response.status_code, 200, response.text)
        body = response.json()
        self.assertTrue(body["available"])
        self.assertEqual(body["status"], "available")
        self.assertEqual(
            body["preview_url"],
            f"/api/v1/deployment-records/{deployment['id']}/preview/",
        )
        self.assertEqual(body["service"]["port"], 80)
        self.assertEqual(body["service"]["service_type"], "ClusterIP")
        self.assertNotIn("cluster_ip", body["service"])
        self.assertNotIn("10.96.0.99", str(body))
        self.assertNotIn("token", body["preview_url"].lower())
        cookie = response.headers["set-cookie"]
        self.assertIn("HttpOnly", cookie)
        self.assertIn("Max-Age=120", cookie)
        self.assertIn("SameSite=none", cookie)
        self.assertIn("Secure", cookie)
        self.assertIn(
            f"Path=/api/v1/deployment-records/{deployment['id']}/preview/",
            cookie,
        )

    def test_preview_cookie_is_always_secure_for_sandboxed_subresource_auth(self) -> None:
        deployment = self.create_deployment()
        self.runtime_reader.snapshots[("devdeploy-apps", "payments-api")] = (
            self.ready_workload_snapshot()
        )

        with patch(
            "app.api.v1.endpoints.deployment_records.settings.preview_cookie_secure",
            False,
        ):
            response = self.client.get(
                f"/api/v1/deployment-records/{deployment['id']}/access"
            )

        self.assertIn("Secure", response.headers["set-cookie"])

    def test_owner_can_preview_ready_app_with_safe_browser_headers_only(self) -> None:
        deployment = self.create_deployment()
        self.runtime_reader.snapshots[("devdeploy-apps", "payments-api")] = (
            self.ready_workload_snapshot()
        )
        self.preview_proxy.response = ServiceProxyResponse(
            status_code=200,
            body=b'<html><head><script src="/app.js"></script></head><body>preview</body></html>',
            headers={"Content-Type": "text/html; charset=utf-8"},
        )
        access = self.client.get(f"/api/v1/deployment-records/{deployment['id']}/access")
        self.client.cookies.set("browser_session", "browser-secret", path="/")

        response = self.client.get(
            access.json()["preview_url"],
            headers={
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                "Accept-Language": "tr-TR,tr;q=0.9",
                "User-Agent": "Mozilla/5.0 DevDeployPreview",
                "Authorization": "Bearer browser-secret",
                "Host": "attacker.example",
                "Connection": "keep-alive",
                "X-Forwarded-Host": "attacker.example",
                "Proxy-Authorization": "Basic proxy-secret",
            },
        )

        self.assertEqual(response.status_code, 200, response.text)
        base_tag = f'<base href="/api/v1/deployment-records/{deployment["id"]}/preview/">'
        self.assertIn(base_tag, response.text)
        self.assertIn("devdeploy-preview-routing", response.text)
        self.assertIn(PREVIEW_RUNTIME_AUTH_HEADER, response.text)
        self.assertIn("withPreviewAuth", response.text)
        self.assertIn("headers.set(previewSessionHeader, previewSessionToken)", response.text)
        self.assertNotIn("browser-secret", response.text)
        self.assertIn(f'src="/api/v1/deployment-records/{deployment["id"]}/preview/app.js"', response.text)
        self.assertLess(response.text.index(base_tag), response.text.index("devdeploy-preview-routing"))
        self.assertLess(response.text.index("devdeploy-preview-routing"), response.text.index("/preview/app.js"))
        self.assertEqual(
            self.preview_proxy.calls,
            [
                {
                    "service_name": "payments-api",
                    "namespace": "devdeploy-apps",
                    "port": 80,
                    "path": "",
                    "method": "GET",
                    "body": None,
                    "request_headers": {
                        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                        "Accept-Language": "tr-TR,tr;q=0.9",
                        "User-Agent": "Mozilla/5.0 DevDeployPreview",
                    },
                }
            ],
        )
        self.assertNotIn("set-cookie", response.headers)
        self.assertNotIn("connection", response.headers)
        self.assertNotIn("server", response.headers)
        self.assertIn("sandbox", response.headers["content-security-policy"])
        self.assertIn("script-src", response.headers["content-security-policy"])
        self.assertIn("'unsafe-inline'", response.headers["content-security-policy"])
        self.assertIn("https:", response.headers["content-security-policy"])
        self.assertIn("http:", response.headers["content-security-policy"])
        self.assertEqual(response.headers["x-content-type-options"], "nosniff")
        self.assertEqual(response.headers["x-devdeploy-preview-transport"], "port-forward")
        self.assertEqual(response.headers["x-devdeploy-preview-injected"], "true")
        self.assertEqual(response.headers["x-devdeploy-preview-path"], "/")

    def test_actual_preview_endpoint_uses_browser_default_for_generic_accept(self) -> None:
        deployment = self.create_deployment(preview_path="/")
        self.runtime_reader.snapshots[("devdeploy-apps", "payments-api")] = (
            self.ready_workload_snapshot()
        )
        self.preview_proxy = NegotiatingWorkloadServiceProxy()
        access = self.client.get(f"/api/v1/deployment-records/{deployment['id']}/access")

        response = self.client.get(access.json()["preview_url"], headers={"Accept": "*/*"})

        self.assertEqual(response.status_code, 200, response.text)
        self.assertIn("<html><body>podinfo ui</body></html>", response.text)
        self.assertEqual(response.headers["content-type"], "text/html; charset=utf-8")
        self.assertEqual(self.preview_proxy.calls[-1]["path"], "")
        self.assertIn("text/html", self.preview_proxy.calls[-1]["request_headers"]["Accept"])

    def test_actual_preview_endpoint_uses_browser_default_for_json_accept(self) -> None:
        deployment = self.create_deployment(preview_path="/")
        self.runtime_reader.snapshots[("devdeploy-apps", "payments-api")] = (
            self.ready_workload_snapshot()
        )
        self.preview_proxy = NegotiatingWorkloadServiceProxy()
        access = self.client.get(f"/api/v1/deployment-records/{deployment['id']}/access")

        response = self.client.get(
            access.json()["preview_url"],
            headers={"Accept": "application/json"},
        )

        self.assertEqual(response.status_code, 200, response.text)
        self.assertIn("<html><body>podinfo ui</body></html>", response.text)
        self.assertEqual(response.headers["content-type"], "text/html; charset=utf-8")
        self.assertIn("text/html", self.preview_proxy.calls[-1]["request_headers"]["Accept"])

    def test_nested_preview_runtime_api_path_maps_to_upstream_json(self) -> None:
        deployment = self.create_deployment(preview_path="/")
        self.runtime_reader.snapshots[("devdeploy-apps", "payments-api")] = (
            self.ready_workload_snapshot()
        )
        self.preview_proxy.response = ServiceProxyResponse(
            status_code=200,
            body=b'<html><head><script src="/app.js"></script></head><body>preview</body></html>',
            headers={"Content-Type": "text/html; charset=utf-8"},
        )
        access = self.client.get(f"/api/v1/deployment-records/{deployment['id']}/access")
        runtime_token = create_preview_session_token(
            user_id=self.user_a.id,
            deployment_id=deployment["id"],
        )
        self.client.cookies.clear()
        self.preview_proxy.response = ServiceProxyResponse(
            status_code=200,
            body=b'{"version":"1.0.0","hostname":"podinfo"}',
            headers={"Content-Type": "application/json"},
        )

        response = self.client.get(
            f"/api/v1/deployment-records/{deployment['id']}/preview/api/info",
            headers={
                "Origin": "null",
                "Accept": "application/json",
                PREVIEW_RUNTIME_AUTH_HEADER: runtime_token,
            },
        )

        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.headers["content-type"], "application/json")
        self.assertEqual(response.headers["access-control-allow-origin"], "null")
        self.assertEqual(response.headers["access-control-allow-credentials"], "true")
        self.assertEqual(response.headers["x-devdeploy-preview-transport"], "port-forward")
        self.assertEqual(response.headers["x-devdeploy-preview-injected"], "false")
        self.assertEqual(response.headers["x-devdeploy-preview-path"], "/api/info")
        self.assertEqual(response.json()["hostname"], "podinfo")
        self.assertEqual(self.preview_proxy.calls[-1]["path"], "api/info")
        self.assertEqual(access.status_code, 200, access.text)
        forwarded = self.preview_proxy.calls[-1]["request_headers"]
        self.assertIn("text/html", forwarded["Accept"])
        self.assertNotIn(PREVIEW_RUNTIME_AUTH_HEADER, forwarded)
        self.assertNotIn("Cookie", forwarded)
        self.assertNotIn("Authorization", forwarded)

    def test_configured_preview_path_is_used_for_access_and_preview(self) -> None:
        deployment = self.create_deployment(preview_path="ui")
        self.runtime_reader.snapshots[("devdeploy-apps", "payments-api")] = (
            self.ready_workload_snapshot()
        )
        self.preview_proxy.response = ServiceProxyResponse(
            status_code=200,
            body=b'<html><head><script src="/app.js"></script></head><body>preview</body></html>',
            headers={"Content-Type": "text/html; charset=utf-8"},
        )
        access = self.client.get(f"/api/v1/deployment-records/{deployment['id']}/access")

        self.assertEqual(access.status_code, 200, access.text)
        self.assertEqual(deployment["preview_path"], "/ui")
        self.assertEqual(
            access.json()["preview_url"],
            f"/api/v1/deployment-records/{deployment['id']}/preview/ui",
        )
        self.assertIn(
            f"Path=/api/v1/deployment-records/{deployment['id']}/preview/",
            access.headers["set-cookie"],
        )

        response = self.client.get(access.json()["preview_url"])

        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(self.preview_proxy.calls[-1]["path"], "ui")

    def test_configured_preview_path_surfaces_upstream_not_found(self) -> None:
        deployment = self.create_deployment(preview_path="ui")
        self.runtime_reader.snapshots[("devdeploy-apps", "payments-api")] = (
            self.ready_workload_snapshot()
        )
        self.preview_proxy.response = ServiceProxyResponse(
            status_code=200,
            body=b'<html><head><script src="/app.js"></script></head><body>preview</body></html>',
            headers={"Content-Type": "text/html; charset=utf-8"},
        )
        access = self.client.get(f"/api/v1/deployment-records/{deployment['id']}/access")
        self.preview_proxy.response = ServiceProxyResponse(
            status_code=404,
            body=b"not found",
            headers={"Content-Type": "text/plain"},
        )

        response = self.client.get(access.json()["preview_url"])

        self.assertEqual(response.status_code, 404, response.text)
        self.assertEqual(self.preview_proxy.calls[-1]["path"], "ui")

    def test_preview_path_validation_rejects_unsafe_values(self) -> None:
        unsafe_values = (
            "http://attacker.example",
            "https://attacker.example",
            "//attacker.example",
            "../secret",
            "/../secret",
            "folder\\secret",
            "?target=/ui",
            "#fragment",
        )

        for value in unsafe_values:
            with self.subTest(value=value):
                response = self.client.post(
                    "/api/v1/deployment-records",
                    json={**self.deployment_payload(), "preview_path": value},
                )
                self.assertEqual(response.status_code, 422, response.text)

    def test_preview_requires_scoped_session_for_upstream_requests(self) -> None:
        deployment = self.create_deployment()
        self.runtime_reader.snapshots[("devdeploy-apps", "payments-api")] = (
            self.ready_workload_snapshot()
        )
        preview_url = f"/api/v1/deployment-records/{deployment['id']}/preview/"

        missing_session = self.client.get(preview_url, headers={"Origin": "null"})
        external_origin = self.client.get(
            preview_url,
            headers={"Origin": "https://attacker.example"},
        )
        wrong_deployment = self.client.get(
            preview_url,
            headers={
                PREVIEW_RUNTIME_AUTH_HEADER: create_preview_session_token(
                    user_id=self.user_a.id,
                    deployment_id=deployment["id"] + 1,
                )
            },
        )
        invalid_session = self.client.get(
            preview_url,
            headers={PREVIEW_RUNTIME_AUTH_HEADER: "invalid-preview-session"},
        )

        self.assertEqual(missing_session.status_code, 401)
        self.assertEqual(missing_session.headers["access-control-allow-origin"], "null")
        self.assertEqual(missing_session.headers["access-control-allow-credentials"], "true")
        self.assertEqual(external_origin.status_code, 401)
        self.assertEqual(external_origin.headers["access-control-allow-origin"], "null")
        self.assertNotEqual(external_origin.headers["access-control-allow-origin"], "https://attacker.example")
        self.assertEqual(wrong_deployment.status_code, 403)
        self.assertEqual(invalid_session.status_code, 401)
        self.assertEqual(self.preview_proxy.calls, [])

    def test_preview_preflight_is_local_and_does_not_require_session_cookie(self) -> None:
        deployment = self.create_deployment()
        preview_url = f"/api/v1/deployment-records/{deployment['id']}/preview/api/echo"

        response = self.client.options(
            preview_url,
            headers={
                "Origin": "null",
                "Access-Control-Request-Method": "POST",
                "Access-Control-Request-Headers": (
                    f"Content-Type, X-APP, {PREVIEW_RUNTIME_AUTH_HEADER}, "
                    "Authorization, Cookie, X-Forwarded-Host"
                ),
            },
        )

        self.assertEqual(response.status_code, 204, response.text)
        self.assertEqual(response.headers["access-control-allow-origin"], "null")
        self.assertEqual(response.headers["access-control-allow-credentials"], "true")
        self.assertIn("POST", response.headers["access-control-allow-methods"])
        self.assertIn("Content-Type", response.headers["access-control-allow-headers"])
        self.assertIn("X-APP", response.headers["access-control-allow-headers"])
        self.assertIn(PREVIEW_RUNTIME_AUTH_HEADER, response.headers["access-control-allow-headers"])
        self.assertNotIn("Authorization", response.headers["access-control-allow-headers"])
        self.assertNotIn("Cookie", response.headers["access-control-allow-headers"])
        self.assertNotIn("X-Forwarded-Host", response.headers["access-control-allow-headers"])
        self.assertEqual(self.preview_proxy.calls, [])

    def test_preview_runtime_post_forwards_body_and_safe_headers(self) -> None:
        deployment = self.create_deployment(preview_path="/")
        self.runtime_reader.snapshots[("devdeploy-apps", "payments-api")] = (
            self.ready_workload_snapshot()
        )
        runtime_token = create_preview_session_token(
            user_id=self.user_a.id,
            deployment_id=deployment["id"],
        )
        self.client.cookies.clear()
        self.client.cookies.set("browser_session", "browser-secret", path="/")
        self.preview_proxy.response = ServiceProxyResponse(
            status_code=200,
            body=b'{"message":"pong"}',
            headers={"Content-Type": "application/json"},
        )

        response = self.client.post(
            f"/api/v1/deployment-records/{deployment['id']}/preview/api/echo",
            content=b'{"message":"ping"}',
            headers={
                "Origin": "null",
                "Accept": "application/json",
                "Content-Type": "application/json; charset=UTF-8",
                "X-APP": "preview-test",
                PREVIEW_RUNTIME_AUTH_HEADER: runtime_token,
                "Authorization": "Bearer browser-secret",
                "Host": "attacker.example",
                "Connection": "keep-alive",
                "X-Forwarded-Host": "attacker.example",
            },
        )

        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.headers["content-type"], "application/json")
        self.assertEqual(response.headers["access-control-allow-origin"], "null")
        self.assertEqual(self.preview_proxy.calls[-1]["method"], "POST")
        self.assertEqual(self.preview_proxy.calls[-1]["path"], "api/echo")
        self.assertEqual(self.preview_proxy.calls[-1]["body"], b'{"message":"ping"}')
        forwarded = self.preview_proxy.calls[-1]["request_headers"]
        self.assertIn("text/html", forwarded["Accept"])
        self.assertEqual(forwarded["Content-Type"], "application/json; charset=UTF-8")
        self.assertEqual(forwarded["X-APP"], "preview-test")
        for blocked_header in (
            "Authorization",
            "Cookie",
            "Host",
            "Connection",
            "X-Forwarded-Host",
            PREVIEW_RUNTIME_AUTH_HEADER,
        ):
            self.assertNotIn(blocked_header, forwarded)

    def test_preview_is_owner_scoped_and_blocks_missing_or_archived_records(self) -> None:
        deployment = self.create_deployment()
        self.runtime_reader.snapshots[("devdeploy-apps", "payments-api")] = (
            self.ready_workload_snapshot()
        )

        self.set_preview_cookie(user_id=self.user_b.id, deployment_id=deployment["id"])
        denied = self.client.get(
            f"/api/v1/deployment-records/{deployment['id']}/preview/"
        )

        self.set_preview_cookie(user_id=self.user_a.id, deployment_id=99999)
        missing = self.client.get("/api/v1/deployment-records/99999/preview/")

        archived = self.client.post(
            f"/api/v1/deployment-records/{deployment['id']}/archive"
        )
        self.set_preview_cookie(user_id=self.user_a.id, deployment_id=deployment["id"])
        blocked = self.client.get(
            f"/api/v1/deployment-records/{deployment['id']}/preview/"
        )

        self.assertEqual(denied.status_code, 403)
        self.assertEqual(missing.status_code, 404)
        self.assertEqual(archived.status_code, 200)
        self.assertEqual(blocked.status_code, 409)

    def test_preview_blocks_unready_missing_service_and_runtime_unavailable(self) -> None:
        deployment = self.create_deployment()
        key = ("devdeploy-apps", "payments-api")
        self.set_preview_cookie(user_id=self.user_a.id, deployment_id=deployment["id"])
        preview_url = f"/api/v1/deployment-records/{deployment['id']}/preview/"

        self.runtime_reader.snapshots[key] = WorkloadSnapshot(
            deployment_exists=True,
            service_exists=True,
            desired_replicas=2,
            ready_replicas=1,
            available_replicas=1,
            pod_count=2,
            ready_pod_count=1,
            service_type="ClusterIP",
            service_ports=(ServicePortSnapshot("http", 80, "http", "TCP"),),
        )
        not_ready = self.client.get(preview_url)

        self.runtime_reader.snapshots[key] = WorkloadSnapshot(
            deployment_exists=True,
            service_exists=False,
            desired_replicas=2,
            ready_replicas=2,
            available_replicas=2,
            pod_count=2,
            ready_pod_count=2,
        )
        missing_service = self.client.get(preview_url)

        self.runtime_reader.error = RuntimeError(
            "raw kubeconfig C:/private/workload.yaml token=secret"
        )
        unavailable = self.client.get(preview_url)

        self.assertEqual(not_ready.status_code, 409)
        self.assertEqual(missing_service.status_code, 409)
        self.assertEqual(unavailable.status_code, 503)
        self.assertEqual(self.preview_proxy.calls, [])
        for forbidden in ("kubeconfig", "workload.yaml", "token=secret"):
            self.assertNotIn(forbidden, unavailable.text.lower())

    def test_preview_rejects_query_redirect_timeout_and_raw_upstream_errors(self) -> None:
        deployment = self.create_deployment()
        self.runtime_reader.snapshots[("devdeploy-apps", "payments-api")] = (
            self.ready_workload_snapshot()
        )
        self.set_preview_cookie(user_id=self.user_a.id, deployment_id=deployment["id"])
        preview_url = f"/api/v1/deployment-records/{deployment['id']}/preview/"

        query = self.client.get(
            f"{preview_url}?target=https://attacker.example&host=attacker.example"
            "&port=443&namespace=kube-system&service=kubernetes"
        )

        self.preview_proxy.response = ServiceProxyResponse(
            status_code=302,
            body=b"redirect",
            headers={
                "Content-Type": "text/plain",
                "Location": "https://internal-service.example/secret",
            },
        )
        redirect = self.client.get(preview_url)

        self.preview_proxy.error = PreviewTimeoutError("raw timeout target detail")
        timed_out = self.client.get(preview_url)

        self.preview_proxy.error = PreviewUpstreamError(
            "https://devdeploy-workload-control-plane:6443 raw certificate"
        )
        unavailable = self.client.get(preview_url)

        self.assertEqual(query.status_code, 400)
        self.assertEqual(redirect.status_code, 502)
        self.assertNotIn("location", redirect.headers)
        self.assertNotIn("internal-service", redirect.text)
        self.assertEqual(timed_out.status_code, 504)
        self.assertNotIn("raw timeout", timed_out.text)
        self.assertEqual(unavailable.status_code, 502)
        self.assertNotIn("control-plane", unavailable.text)
        self.assertNotIn("certificate", unavailable.text)

    def test_preview_distinguishes_rbac_denial_and_service_unavailability(self) -> None:
        deployment = self.create_deployment()
        self.runtime_reader.snapshots[("devdeploy-apps", "payments-api")] = (
            self.ready_workload_snapshot()
        )
        self.preview_proxy.response = ServiceProxyResponse(
            status_code=200,
            body=b'<html><head><script src="/app.js"></script></head><body>preview</body></html>',
            headers={"Content-Type": "text/html; charset=utf-8"},
        )
        access = self.client.get(f"/api/v1/deployment-records/{deployment['id']}/access")
        preview_url = access.json()["preview_url"]

        self.preview_proxy.error = PreviewForbiddenError("raw RBAC detail")
        forbidden = self.client.get(preview_url)

        self.preview_proxy.error = PreviewServiceUnavailableError("raw endpoint detail")
        unavailable = self.client.get(preview_url)

        self.assertEqual(forbidden.status_code, 403)
        self.assertEqual(forbidden.json()["detail"], "Workload preview access is denied.")
        self.assertNotIn("raw RBAC", forbidden.text)
        self.assertEqual(unavailable.status_code, 503)
        self.assertEqual(unavailable.json()["detail"], "The app preview service is unavailable.")
        self.assertNotIn("raw endpoint", unavailable.text)

    def test_preview_rejects_records_outside_managed_workload_namespace(self) -> None:
        payload = self.deployment_payload()
        payload["namespace"] = "other-namespace"
        deployment = self.client.post("/api/v1/deployment-records", json=payload).json()
        self.runtime_reader.snapshots[("other-namespace", "payments-api")] = (
            self.ready_workload_snapshot()
        )
        self.set_preview_cookie(user_id=self.user_a.id, deployment_id=deployment["id"])

        response = self.client.get(
            f"/api/v1/deployment-records/{deployment['id']}/preview/"
        )

        self.assertEqual(response.status_code, 409)
        self.assertEqual(self.preview_proxy.calls, [])

    def test_app_access_is_owner_scoped_and_archived_records_are_blocked(self) -> None:
        deployment = self.create_deployment()

        self.current_user = self.user_b
        denied = self.client.get(f"/api/v1/deployment-records/{deployment['id']}/access")
        self.current_user = self.user_a
        archived = self.client.post(f"/api/v1/deployment-records/{deployment['id']}/archive")
        blocked = self.client.get(f"/api/v1/deployment-records/{deployment['id']}/access")
        missing = self.client.get("/api/v1/deployment-records/99999/access")

        self.assertEqual(denied.status_code, 403)
        self.assertEqual(archived.status_code, 200)
        self.assertEqual(blocked.status_code, 409)
        self.assertEqual(missing.status_code, 404)

    def test_app_access_reports_missing_service_and_not_ready_runtime(self) -> None:
        deployment = self.create_deployment()
        key = ("devdeploy-apps", "payments-api")
        self.runtime_reader.snapshots[key] = WorkloadSnapshot(
            deployment_exists=True,
            service_exists=False,
            desired_replicas=2,
            ready_replicas=2,
            available_replicas=2,
            pod_count=2,
            ready_pod_count=2,
        )
        missing_service = self.client.get(
            f"/api/v1/deployment-records/{deployment['id']}/access"
        )

        self.runtime_reader.snapshots[key] = WorkloadSnapshot(
            deployment_exists=True,
            service_exists=True,
            desired_replicas=2,
            ready_replicas=1,
            available_replicas=1,
            pod_count=2,
            ready_pod_count=1,
            service_type="ClusterIP",
            service_ports=(ServicePortSnapshot("http", 80, "http", "TCP"),),
        )
        not_ready = self.client.get(f"/api/v1/deployment-records/{deployment['id']}/access")

        self.assertEqual(missing_service.status_code, 200)
        self.assertEqual(missing_service.json()["status"], "service_missing")
        self.assertEqual(not_ready.status_code, 200)
        self.assertEqual(not_ready.json()["status"], "not_ready")

    def test_app_access_reports_unsupported_port_and_runtime_failure_safely(self) -> None:
        deployment = self.create_deployment()
        key = ("devdeploy-apps", "payments-api")
        self.runtime_reader.snapshots[key] = WorkloadSnapshot(
            deployment_exists=True,
            service_exists=True,
            desired_replicas=2,
            ready_replicas=2,
            available_replicas=2,
            pod_count=2,
            ready_pod_count=2,
            service_type="ClusterIP",
            service_ports=(ServicePortSnapshot("metrics", 9090, "metrics", "TCP"),),
        )
        unsupported = self.client.get(f"/api/v1/deployment-records/{deployment['id']}/access")

        self.runtime_reader.error = RuntimeError(
            "raw kubeconfig C:/sensitive/client.yaml token=secret-value"
        )
        unavailable = self.client.get(f"/api/v1/deployment-records/{deployment['id']}/access")

        self.assertEqual(unsupported.status_code, 200)
        self.assertEqual(unsupported.json()["status"], "unsupported")
        self.assertEqual(unavailable.status_code, 200)
        self.assertEqual(unavailable.json()["status"], "runtime_unavailable")
        response_text = str(unavailable.json()).lower()
        for forbidden in ("kubeconfig", "sensitive", "secret-value", "client.yaml"):
            self.assertNotIn(forbidden, response_text)


if __name__ == "__main__":
    unittest.main()
