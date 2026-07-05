import unittest
from unittest.mock import patch

from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.api.v1.endpoints import deployment_records, services
from app.api.v1.runtime_status import get_product_runtime_status_service
from app.core.deps import get_current_user, get_db
from app.db.database import Base
from app.models.user import User
from app.services.gitops.status_reader import (
    NamedWorkloadSnapshot,
    ServicePortSnapshot,
    WorkloadSnapshot,
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
        self.client = TestClient(self.app, raise_server_exceptions=False)

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

    def create_service(self, name: str = "Payments API") -> dict:
        response = self.client.post("/api/v1/services", json=self.service_payload(name))
        self.assertEqual(response.status_code, 201, response.text)
        return response.json()

    def create_deployment(self, service_id: int | None = None) -> dict:
        response = self.client.post(
            "/api/v1/deployment-records",
            json=self.deployment_payload(service_id),
        )
        self.assertEqual(response.status_code, 201, response.text)
        return response.json()

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
        self.assertEqual(archived_again.status_code, 200)
        self.assertEqual(archived_again.json()["archived_at"], archived.json()["archived_at"])

        self.current_user = self.user_b
        denied = self.client.post(f"/api/v1/services/{service['id']}/archive")
        self.assertEqual(denied.status_code, 403)

    def test_deployment_archive_is_owner_scoped_idempotent_and_hidden_from_list(self) -> None:
        deployment = self.create_deployment()

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
        self.assertEqual(archived_again.status_code, 200)
        self.assertEqual(archived_again.json()["archived_at"], archived.json()["archived_at"])

        self.current_user = self.user_b
        denied = self.client.post(
            f"/api/v1/deployment-records/{deployment['id']}/archive"
        )
        self.assertEqual(denied.status_code, 403)

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
        self.assertEqual(self.client.delete("/api/v1/services/1").status_code, 401)
        self.assertEqual(self.client.delete("/api/v1/deployment-records/1").status_code, 401)

    def test_deployment_record_list_and_get_include_running_runtime_status(self) -> None:
        service = self.create_service("payments-api")
        deployment = self.create_deployment(service["id"])
        self.runtime_reader.snapshots[("devdeploy-apps", "payments-api")] = WorkloadSnapshot(
            deployment_exists=True,
            service_exists=True,
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
        for runtime in (listed.json()[0]["runtime_status"], fetched.json()["runtime_status"]):
            self.assertEqual(runtime["display_status"], "running")
            self.assertTrue(runtime["deployment_found"])
            self.assertEqual(runtime["ready_replicas"], 2)
            self.assertEqual(runtime["available_replicas"], 2)
            self.assertEqual(runtime["pod_ready_count"], 2)
            self.assertEqual(runtime["service_cluster_ip"], "10.96.0.10")

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
        service_runtime = services_response.json()[0]["runtime_status"]
        self.assertEqual(deployment_runtime["display_status"], "unknown")
        self.assertEqual(service_runtime["display_status"], "unknown")
        self.assertNotIn("kubeconfig", str(deployment_runtime).lower())
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


if __name__ == "__main__":
    unittest.main()
