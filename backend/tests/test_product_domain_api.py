import unittest
from unittest.mock import patch

from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.api.v1.endpoints import deployment_records, services
from app.core.deps import get_current_user, get_db
from app.db.database import Base
from app.models.user import User


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

        self.app = FastAPI()
        self.app.include_router(services.router, prefix="/api/v1")
        self.app.include_router(deployment_records.router, prefix="/api/v1")

        def override_get_db():
            yield self.db

        self.app.dependency_overrides[get_db] = override_get_db
        self.app.dependency_overrides[get_current_user] = lambda: self.current_user
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


if __name__ == "__main__":
    unittest.main()
