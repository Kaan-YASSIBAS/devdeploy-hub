import unittest
from datetime import datetime, timezone

from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.api.v1.endpoints import dashboard, deployment_records, services
from app.api.v1.runtime_status import get_deployment_drift_service, get_product_runtime_status_service
from app.core.deps import get_current_user, get_db
from app.db.database import Base
from app.models.deployment_record import DeploymentRecord
from app.models.service_definition import ServiceDefinition
from app.models.user import User
from app.schemas.deployment_drift import DeploymentDriftStatusRead, DriftComparisonRead
from app.schemas.runtime_status import DeploymentRuntimeStatusRead, ServiceRuntimeStatusRead
from app.services.gitops.product_records import PUBLISHED_STATUS_SUMMARY


class FakeRuntimeStatusService:
    def __init__(self) -> None:
        self.deployment_statuses: dict[str, DeploymentRuntimeStatusRead] = {}
        self.service_statuses: dict[str, ServiceRuntimeStatusRead] = {}

    def deployment_status(self, deployment: DeploymentRecord) -> DeploymentRuntimeStatusRead:
        return self.deployment_statuses.get(
            deployment.app_name,
            DeploymentRuntimeStatusRead(
                display_status="unknown",
                deployment_found=False,
                service_found=False,
                message="Runtime status is temporarily unavailable.",
            ),
        )

    def service_status(self, service: ServiceDefinition) -> ServiceRuntimeStatusRead:
        return self.service_statuses.get(
            service.name,
            ServiceRuntimeStatusRead(
                display_status="unknown",
                service_found=False,
                namespace="devdeploy-apps",
                message="Runtime status is temporarily unavailable.",
            ),
        )


class FakeDriftService:
    def __init__(self) -> None:
        self.statuses: dict[str, str] = {}

    def evaluate(self, deployment: DeploymentRecord) -> DeploymentDriftStatusRead:
        status = self.statuses.get(deployment.app_name, "aligned")
        return DeploymentDriftStatusRead(
            status=status,  # type: ignore[arg-type]
            db_to_gitops=DriftComparisonRead(status="aligned"),
            db_to_runtime=DriftComparisonRead(status="aligned"),
            checked_at=datetime.now(timezone.utc),
            message=f"Drift status is {status}.",
        )


class DashboardDomainCountsTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.engine = create_engine(
            "sqlite://",
            connect_args={"check_same_thread": False},
            poolclass=StaticPool,
        )
        self.session_factory = sessionmaker(autocommit=False, autoflush=False, bind=self.engine)
        Base.metadata.create_all(self.engine)
        self.db = self.session_factory()
        self.user = User(
            email="owner@example.com",
            username="owner",
            hashed_password="test-only",
            role="admin",
            is_active=True,
        )
        self.other_user = User(
            email="other@example.com",
            username="other",
            hashed_password="test-only",
            role="developer",
            is_active=True,
        )
        self.db.add_all([self.user, self.other_user])
        self.db.commit()
        self.db.refresh(self.user)
        self.db.refresh(self.other_user)
        self.runtime = FakeRuntimeStatusService()
        self.drift = FakeDriftService()

        self.app = FastAPI()
        self.app.include_router(dashboard.router, prefix="/api/v1")
        self.app.include_router(services.router, prefix="/api/v1")
        self.app.include_router(deployment_records.router, prefix="/api/v1")

        def override_get_db():
            yield self.db

        self.app.dependency_overrides[get_db] = override_get_db
        self.app.dependency_overrides[get_current_user] = lambda: self.user
        self.app.dependency_overrides[get_product_runtime_status_service] = lambda: self.runtime
        self.app.dependency_overrides[get_deployment_drift_service] = lambda: self.drift
        self.client = TestClient(self.app, raise_server_exceptions=False)

    def tearDown(self) -> None:
        self.client.close()
        self.db.close()
        Base.metadata.drop_all(self.engine)
        self.engine.dispose()

    def create_service(
        self,
        name: str = "recover-nginx",
        *,
        owner_id: int | None = None,
        archived: bool = False,
    ) -> ServiceDefinition:
        service = ServiceDefinition(
            owner_id=owner_id or self.user.id,
            name=name,
            default_image="nginx:latest",
            default_replicas=1,
            default_port=80,
            archived_at=datetime.now(timezone.utc) if archived else None,
        )
        self.db.add(service)
        self.db.commit()
        self.db.refresh(service)
        return service

    def create_deployment(
        self,
        app_name: str = "recover-nginx",
        *,
        service: ServiceDefinition | None = None,
        owner_id: int | None = None,
        desired_state: str = "pending",
        commit_sha: str | None = "a" * 40,
        status_summary: str | None = PUBLISHED_STATUS_SUMMARY,
        archived: bool = False,
    ) -> DeploymentRecord:
        deployment = DeploymentRecord(
            owner_id=owner_id or self.user.id,
            service_definition_id=service.id if service else None,
            app_name=app_name,
            image="nginx:latest",
            replicas=1,
            container_port=80,
            service_port=80,
            service_type="ClusterIP",
            namespace="devdeploy-apps",
            gitops_manifest_path=f"gitops/workloads/devdeploy-apps/apps/{app_name}",
            commit_sha=commit_sha,
            desired_state=desired_state,
            status_summary=status_summary,
            archived_at=datetime.now(timezone.utc) if archived else None,
        )
        self.db.add(deployment)
        self.db.commit()
        self.db.refresh(deployment)
        return deployment

    def set_runtime(
        self,
        app_name: str,
        status: str,
        *,
        deployment_found: bool = True,
        service_found: bool = True,
    ) -> None:
        desired = 1 if status == "running" else None
        ready = 1 if status == "running" else 0
        self.runtime.deployment_statuses[app_name] = DeploymentRuntimeStatusRead(
            display_status=status,  # type: ignore[arg-type]
            deployment_found=deployment_found,
            service_found=service_found,
            desired_replicas=desired,
            ready_replicas=ready,
            available_replicas=ready,
            updated_replicas=ready,
            pod_ready_count=ready,
            pod_total_count=ready,
        )

    def summary(self) -> dict:
        response = self.client.get("/api/v1/dashboard/summary")
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()

    def test_one_active_service_counts_as_total_service(self) -> None:
        self.create_service()

        summary = self.summary()

        self.assertEqual(summary["application_count"], 1)

    def test_one_active_healthy_deployment_counts_as_total_and_running(self) -> None:
        service = self.create_service()
        self.create_deployment(service=service)
        self.set_runtime("recover-nginx", "running")

        summary = self.summary()

        self.assertEqual(summary["deployment_count"], 1)
        self.assertEqual(summary["running_deployment_count"], 1)

    def test_successful_count_requires_completed_operation_and_healthy_runtime(self) -> None:
        service = self.create_service()
        self.create_deployment(service=service, app_name="published-nginx")
        self.create_deployment(
            service=service,
            app_name="draft-nginx",
            desired_state="draft",
            commit_sha=None,
            status_summary=None,
        )
        self.set_runtime("published-nginx", "running")
        self.set_runtime("draft-nginx", "running")

        summary = self.summary()

        self.assertEqual(summary["running_deployment_count"], 2)
        self.assertEqual(summary["successful_deployment_count"], 1)

    def test_archived_records_are_excluded_from_dashboard_and_list_pages(self) -> None:
        active_service = self.create_service("active-nginx")
        self.create_service("archived-nginx", archived=True)
        self.create_deployment(app_name="active-nginx", service=active_service)
        self.create_deployment(app_name="archived-nginx", archived=True)
        self.set_runtime("active-nginx", "running")
        self.set_runtime("archived-nginx", "running")

        summary = self.summary()
        services_response = self.client.get("/api/v1/services")
        deployments_response = self.client.get("/api/v1/deployment-records")

        self.assertEqual(summary["application_count"], len(services_response.json()))
        self.assertEqual(summary["deployment_count"], len(deployments_response.json()))
        self.assertEqual(summary["application_count"], 1)
        self.assertEqual(summary["deployment_count"], 1)

    def test_runtime_only_untracked_resources_do_not_inflate_managed_counts(self) -> None:
        self.set_runtime("runtime-only-nginx", "running")

        summary = self.summary()

        self.assertEqual(summary["application_count"], 0)
        self.assertEqual(summary["deployment_count"], 0)
        self.assertEqual(summary["running_deployment_count"], 0)

    def test_pending_failed_and_unknown_runtime_semantics(self) -> None:
        self.create_deployment(app_name="pending-nginx", commit_sha=None, status_summary=None)
        self.create_deployment(app_name="failed-nginx")
        self.create_deployment(app_name="unknown-nginx")
        self.set_runtime("pending-nginx", "progressing")
        self.set_runtime("failed-nginx", "not_found", deployment_found=False, service_found=False)

        summary = self.summary()

        self.assertEqual(summary["pending_deployment_count"], 2)
        self.assertEqual(summary["failed_deployment_count"], 1)

    def test_drift_runtime_missing_is_failed_but_unknown_runtime_is_not_failed(self) -> None:
        self.create_deployment(app_name="drift-nginx")
        self.create_deployment(app_name="unknown-nginx")
        self.set_runtime("drift-nginx", "running")
        self.drift.statuses["drift-nginx"] = "runtime_missing"

        summary = self.summary()

        self.assertEqual(summary["failed_deployment_count"], 1)
        self.assertEqual(summary["pending_deployment_count"], 1)

    def test_other_users_records_do_not_count_even_for_local_admin_page_consistency(self) -> None:
        self.create_service("owned-nginx")
        self.create_service("other-nginx", owner_id=self.other_user.id)
        self.create_deployment("owned-nginx")
        self.create_deployment("other-nginx", owner_id=self.other_user.id)
        self.set_runtime("owned-nginx", "running")
        self.set_runtime("other-nginx", "running")

        summary = self.summary()
        services_response = self.client.get("/api/v1/services")
        deployments_response = self.client.get("/api/v1/deployment-records")

        self.assertEqual(summary["application_count"], len(services_response.json()))
        self.assertEqual(summary["deployment_count"], len(deployments_response.json()))
        self.assertEqual(summary["application_count"], 1)
        self.assertEqual(summary["deployment_count"], 1)


if __name__ == "__main__":
    unittest.main()
