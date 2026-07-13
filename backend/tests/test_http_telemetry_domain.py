import tempfile
import unittest
import os
import importlib.util
from pathlib import Path

import yaml
from alembic.migration import MigrationContext
from alembic.operations import Operations
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import Column, DateTime, ForeignKey, Integer, MetaData, String, Table, Text, create_engine, inspect, text
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

os.environ.setdefault("DATABASE_URL", "sqlite:///test-http-telemetry.db")

from app.api.v1.endpoints import deployment_records, services
from app.core.deps import get_current_user, get_db
from app.db.database import Base
from app.models.deployment_record import DeploymentRecord
from app.models.service_definition import ServiceDefinition
from app.models.user import User
from app.services.gitops.manifests import generate_workload_manifests
from app.services.gitops.models import WorkloadWriteRequest


MANAGED_PROXY_TELEMETRY = {
    "enabled": True,
    "mode": "managed_http_proxy",
    "application_protocol": "http",
    "application_container_port": 8080,
    "service_port": 80,
}


class HttpTelemetryDomainApiTestCase(unittest.TestCase):
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
            email="owner@example.test",
            username="owner",
            hashed_password="test-only",
            role="developer",
            is_active=True,
        )
        self.other_user = User(
            email="other@example.test",
            username="other",
            hashed_password="test-only",
            role="developer",
            is_active=True,
        )
        self.db.add_all([self.user, self.other_user])
        self.db.commit()
        self.db.refresh(self.user)
        self.db.refresh(self.other_user)
        self.current_user = self.user

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

    def create_service(self, **overrides) -> dict:
        payload = {
            "name": "payment-api",
            "default_image": "ghcr.io/example/payment-api:v1",
            "default_replicas": 1,
            "default_port": 80,
            **overrides,
        }
        response = self.client.post("/api/v1/services", json=payload)
        self.assertEqual(response.status_code, 201, response.text)
        return response.json()

    def create_deployment(self, service_id: int | None = None, **overrides) -> dict:
        payload = {
            "service_definition_id": service_id,
            "app_name": "payment-api",
            "image": "ghcr.io/example/payment-api:v1",
            "replicas": 1,
            "container_port": 8080,
            "service_port": 80,
            "service_type": "ClusterIP",
            **overrides,
        }
        response = self.client.post("/api/v1/deployment-records", json=payload)
        self.assertEqual(response.status_code, 201, response.text)
        return response.json()

    def test_old_service_payload_defaults_to_disabled_telemetry(self) -> None:
        service = self.create_service()

        self.assertEqual(
            service["telemetry"],
            {
                "enabled": False,
                "mode": "disabled",
                "application_protocol": "http",
                "application_container_port": None,
                "service_port": None,
                "proxy_listener_port": None,
                "admin_port": None,
            },
        )

    def test_old_database_rows_load_as_disabled_telemetry(self) -> None:
        service = ServiceDefinition(
            owner_id=self.user.id,
            name="legacy-nginx",
            default_image="nginx:latest",
            default_replicas=1,
            default_port=80,
        )
        self.db.add(service)
        self.db.commit()

        response = self.client.get("/api/v1/services")

        self.assertEqual(response.status_code, 200, response.text)
        item = response.json()[0]
        self.assertEqual(item["name"], "legacy-nginx")
        self.assertFalse(item["telemetry"]["enabled"])
        self.assertEqual(item["telemetry"]["mode"], "disabled")

    def test_http_service_can_enable_managed_proxy_telemetry(self) -> None:
        service = self.create_service(telemetry=MANAGED_PROXY_TELEMETRY)

        self.assertTrue(service["telemetry"]["enabled"])
        self.assertEqual(service["telemetry"]["mode"], "managed_http_proxy")
        self.assertEqual(service["telemetry"]["application_container_port"], 8080)
        self.assertEqual(service["telemetry"]["service_port"], 80)
        self.assertEqual(service["telemetry"]["proxy_listener_port"], 18080)
        self.assertEqual(service["telemetry"]["admin_port"], 19090)

    def test_tcp_service_cannot_enable_managed_proxy_telemetry(self) -> None:
        response = self.client.post(
            "/api/v1/services",
            json={
                "name": "tcp-api",
                "telemetry": {
                    **MANAGED_PROXY_TELEMETRY,
                    "application_protocol": "tcp",
                },
            },
        )

        self.assertEqual(response.status_code, 422)
        self.assertIn("managed_http_proxy requires application_protocol=http", response.text)

    def test_conflicting_runtime_ports_are_rejected(self) -> None:
        response = self.client.post(
            "/api/v1/services",
            json={
                "name": "bad-ports",
                "telemetry": {
                    **MANAGED_PROXY_TELEMETRY,
                    "proxy_listener_port": 8080,
                },
            },
        )

        self.assertEqual(response.status_code, 422)
        self.assertIn("must be distinct", response.text)

    def test_telemetry_service_port_must_match_default_port(self) -> None:
        response = self.client.post(
            "/api/v1/services",
            json={
                "name": "mismatched-service-port",
                "default_port": 8081,
                "telemetry": MANAGED_PROXY_TELEMETRY,
            },
        )

        self.assertEqual(response.status_code, 422)
        self.assertIn("telemetry.service_port must match", response.text)

    def test_telemetry_service_port_reuses_default_port_source_of_truth(self) -> None:
        service = self.create_service(default_port=80, telemetry=MANAGED_PROXY_TELEMETRY)

        self.assertEqual(service["default_port"], 80)
        self.assertEqual(service["telemetry"]["service_port"], service["default_port"])

    def test_application_native_is_accepted_and_non_operative(self) -> None:
        service = self.create_service(
            telemetry={
                "enabled": True,
                "mode": "application_native",
                "application_protocol": "http",
                "application_container_port": 8080,
                "service_port": 80,
                "proxy_listener_port": 18080,
                "admin_port": 19090,
            }
        )

        self.assertTrue(service["telemetry"]["enabled"])
        self.assertEqual(service["telemetry"]["mode"], "application_native")
        self.assertIsNone(service["telemetry"]["proxy_listener_port"])
        self.assertIsNone(service["telemetry"]["admin_port"])

    def test_disabling_telemetry_normalizes_optional_fields(self) -> None:
        service = self.create_service(telemetry=MANAGED_PROXY_TELEMETRY)

        response = self.client.patch(
            f"/api/v1/services/{service['id']}",
            json={
                "telemetry": {
                    **MANAGED_PROXY_TELEMETRY,
                    "enabled": False,
                }
            },
        )

        self.assertEqual(response.status_code, 200, response.text)
        telemetry = response.json()["telemetry"]
        self.assertFalse(telemetry["enabled"])
        self.assertEqual(telemetry["mode"], "disabled")
        self.assertIsNone(telemetry["application_container_port"])
        self.assertIsNone(telemetry["service_port"])
        self.assertIsNone(telemetry["proxy_listener_port"])
        self.assertIsNone(telemetry["admin_port"])

    def test_deployment_round_trip_exposes_linked_service_telemetry(self) -> None:
        service = self.create_service(telemetry=MANAGED_PROXY_TELEMETRY)
        deployment = self.create_deployment(service_id=service["id"])

        response = self.client.get(f"/api/v1/deployment-records/{deployment['id']}")

        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["telemetry"]["mode"], "managed_http_proxy")

    def test_deployment_update_cannot_silently_alter_service_telemetry(self) -> None:
        service = self.create_service()
        deployment = self.create_deployment(service_id=service["id"])

        response = self.client.patch(
            f"/api/v1/deployment-records/{deployment['id']}",
            json={"telemetry": MANAGED_PROXY_TELEMETRY},
        )

        self.assertEqual(response.status_code, 422)
        service_response = self.client.get(f"/api/v1/services/{service['id']}")
        self.assertEqual(service_response.json()["telemetry"]["mode"], "disabled")

    def test_service_update_is_the_canonical_telemetry_write_path(self) -> None:
        service = self.create_service()
        deployment = self.create_deployment(service_id=service["id"])

        response = self.client.patch(
            f"/api/v1/services/{service['id']}",
            json={"telemetry": MANAGED_PROXY_TELEMETRY},
        )

        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["telemetry"]["mode"], "managed_http_proxy")
        deployment_response = self.client.get(f"/api/v1/deployment-records/{deployment['id']}")
        self.assertEqual(deployment_response.json()["telemetry"]["mode"], "managed_http_proxy")

    def test_unlinked_deployment_cannot_enable_telemetry(self) -> None:
        response = self.client.post(
            "/api/v1/deployment-records",
            json={
                "app_name": "orphan-nginx",
                "image": "nginx:latest",
                "telemetry": MANAGED_PROXY_TELEMETRY,
            },
        )

        self.assertEqual(response.status_code, 422)

    def test_unlinked_deployment_reads_disabled_telemetry(self) -> None:
        deployment = self.create_deployment(app_name="orphan-nginx")

        response = self.client.get(f"/api/v1/deployment-records/{deployment['id']}")

        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["telemetry"]["mode"], "disabled")

    def test_owner_isolation_remains_intact_for_telemetry_updates(self) -> None:
        service = self.create_service()
        self.current_user = self.other_user

        response = self.client.patch(
            f"/api/v1/services/{service['id']}",
            json={"telemetry": MANAGED_PROXY_TELEMETRY},
        )

        self.assertEqual(response.status_code, 403)

    def test_archived_records_keep_telemetry_but_remain_archive_filtered(self) -> None:
        service = self.create_service(telemetry=MANAGED_PROXY_TELEMETRY)
        archive_response = self.client.post(f"/api/v1/services/{service['id']}/archive")
        self.assertEqual(archive_response.status_code, 200, archive_response.text)

        active_response = self.client.get("/api/v1/services")
        archived_response = self.client.get("/api/v1/services?archive_filter=archived")

        self.assertEqual(active_response.json(), [])
        self.assertEqual(archived_response.json()[0]["telemetry"]["mode"], "managed_http_proxy")

    def test_telemetry_foundation_does_not_change_generated_manifests(self) -> None:
        request = WorkloadWriteRequest(
            app_name="payment-api",
            image="ghcr.io/example/payment-api:v1",
            replicas=1,
            container_port=8080,
            service_port=80,
            service_type="ClusterIP",
            namespace="devdeploy-apps",
        )

        manifests = generate_workload_manifests(request)
        deployment = yaml.safe_load(manifests.files["deployment.yaml"])
        service = yaml.safe_load(manifests.files["service.yaml"])

        self.assertEqual(len(deployment["spec"]["template"]["spec"]["containers"]), 1)
        self.assertEqual(deployment["spec"]["template"]["spec"]["containers"][0]["name"], "payment-api")
        self.assertNotIn("envoy", str(deployment).lower())
        self.assertEqual(service["spec"]["ports"][0]["targetPort"], "http")


class HttpTelemetryMigrationTestCase(unittest.TestCase):
    def test_alembic_head_adds_telemetry_columns_with_disabled_defaults(self) -> None:
        backend_root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as temp_dir:
            database_path = Path(temp_dir) / "migration-test.db"
            engine = create_engine(f"sqlite:///{database_path.as_posix()}")
            metadata = MetaData()
            Table(
                "users",
                metadata,
                Column("id", Integer, primary_key=True),
            )
            Table(
                "service_definitions",
                metadata,
                Column("id", Integer, primary_key=True),
                Column("owner_id", Integer, ForeignKey("users.id"), nullable=False),
                Column("name", String(120), nullable=False),
                Column("description", Text, nullable=True),
                Column("default_image", String(512), nullable=True),
                Column("default_replicas", Integer, nullable=False),
                Column("default_port", Integer, nullable=True),
                Column("archived_at", DateTime(timezone=True), nullable=True),
                Column("created_at", DateTime(timezone=True), nullable=True),
                Column("updated_at", DateTime(timezone=True), nullable=True),
            )
            metadata.create_all(engine)
            try:
                with engine.begin() as connection:
                    connection.execute(text("INSERT INTO users (id) VALUES (1)"))
                    connection.execute(
                        text(
                            "INSERT INTO service_definitions "
                            "(id, owner_id, name, default_replicas, default_port) "
                            "VALUES (1, 1, 'legacy-nginx', 1, 80)"
                        )
                    )
                    context = MigrationContext.configure(connection)
                    operations = Operations(context)
                    migration_path = (
                        backend_root
                        / "alembic"
                        / "versions"
                        / "20260713_0009_service_http_telemetry.py"
                    )
                    spec = importlib.util.spec_from_file_location(
                        "service_http_telemetry_migration",
                        migration_path,
                    )
                    self.assertIsNotNone(spec)
                    self.assertIsNotNone(spec.loader)
                    migration = importlib.util.module_from_spec(spec)
                    spec.loader.exec_module(migration)
                    migration.op = operations
                    migration.upgrade()
                columns = {
                    column["name"]: column for column in inspect(engine).get_columns("service_definitions")
                }
                with engine.connect() as connection:
                    row = connection.execute(
                        text(
                            "SELECT telemetry_enabled, telemetry_mode, application_protocol "
                            "FROM service_definitions WHERE id = 1"
                        )
                    ).mappings().one()
            finally:
                engine.dispose()

        self.assertIn("telemetry_enabled", columns)
        self.assertIn("telemetry_mode", columns)
        self.assertIn("application_protocol", columns)
        self.assertIn("application_container_port", columns)
        self.assertIn("telemetry_proxy_listener_port", columns)
        self.assertIn("telemetry_admin_port", columns)
        self.assertFalse(bool(row["telemetry_enabled"]))
        self.assertEqual(row["telemetry_mode"], "disabled")
        self.assertEqual(row["application_protocol"], "http")

    def test_migration_downgrade_removes_telemetry_columns(self) -> None:
        backend_root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as temp_dir:
            database_path = Path(temp_dir) / "migration-test.db"
            engine = create_engine(f"sqlite:///{database_path.as_posix()}")
            metadata = MetaData()
            Table(
                "users",
                metadata,
                Column("id", Integer, primary_key=True),
            )
            Table(
                "service_definitions",
                metadata,
                Column("id", Integer, primary_key=True),
                Column("owner_id", Integer, ForeignKey("users.id"), nullable=False),
                Column("name", String(120), nullable=False),
                Column("description", Text, nullable=True),
                Column("default_image", String(512), nullable=True),
                Column("default_replicas", Integer, nullable=False),
                Column("default_port", Integer, nullable=True),
                Column("archived_at", DateTime(timezone=True), nullable=True),
                Column("created_at", DateTime(timezone=True), nullable=True),
                Column("updated_at", DateTime(timezone=True), nullable=True),
            )
            metadata.create_all(engine)
            try:
                with engine.begin() as connection:
                    context = MigrationContext.configure(connection)
                    operations = Operations(context)
                    migration_path = (
                        backend_root
                        / "alembic"
                        / "versions"
                        / "20260713_0009_service_http_telemetry.py"
                    )
                    spec = importlib.util.spec_from_file_location(
                        "service_http_telemetry_migration_downgrade",
                        migration_path,
                    )
                    self.assertIsNotNone(spec)
                    self.assertIsNotNone(spec.loader)
                    migration = importlib.util.module_from_spec(spec)
                    spec.loader.exec_module(migration)
                    migration.op = operations
                    migration.upgrade()
                    migration.downgrade()
                columns = {
                    column["name"]: column for column in inspect(engine).get_columns("service_definitions")
                }
            finally:
                engine.dispose()

        self.assertNotIn("telemetry_enabled", columns)
        self.assertNotIn("telemetry_mode", columns)
        self.assertNotIn("application_container_port", columns)


if __name__ == "__main__":
    unittest.main()
