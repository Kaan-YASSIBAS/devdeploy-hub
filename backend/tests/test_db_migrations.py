import logging
import os
import unittest
from unittest.mock import MagicMock, patch

from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy.exc import OperationalError

from app.api.v1.router import api_router
from app.db.migrate import run_migrations
from app.db.migration_status import (
    get_database_migration_status,
    inspect_database_migration_status,
)
from app.schemas.health import DatabaseMigrationStatusRead


class DatabaseMigrationStatusTestCase(unittest.TestCase):
    @staticmethod
    def _status(current: tuple[str, ...], heads: tuple[str, ...]):
        engine = MagicMock()
        connection = engine.connect.return_value.__enter__.return_value
        migration_context = MagicMock()
        migration_context.get_current_heads.return_value = current
        script = MagicMock()
        script.get_heads.return_value = heads
        return engine, connection, migration_context, script

    def test_status_is_up_to_date_when_current_revision_matches_head(self) -> None:
        engine, connection, migration_context, script = self._status(
            ("20260705_0007",),
            ("20260705_0007",),
        )
        with (
            patch("app.db.migration_status.create_engine", return_value=engine),
            patch("app.db.migration_status.MigrationContext.configure", return_value=migration_context),
            patch("app.db.migration_status.ScriptDirectory.from_config", return_value=script),
        ):
            result = inspect_database_migration_status("postgresql://user:secret@db/app")

        self.assertEqual(result.status, "up_to_date")
        self.assertEqual(result.current_revisions, ["20260705_0007"])
        self.assertEqual(result.head_revisions, ["20260705_0007"])
        engine.connect.assert_called_once_with()
        engine.dispose.assert_called_once_with()
        self.assertIsNotNone(connection)

    def test_status_is_pending_when_current_revision_is_behind(self) -> None:
        engine, _, migration_context, script = self._status(
            ("20260704_0006",),
            ("20260705_0007",),
        )
        with (
            patch("app.db.migration_status.create_engine", return_value=engine),
            patch("app.db.migration_status.MigrationContext.configure", return_value=migration_context),
            patch("app.db.migration_status.ScriptDirectory.from_config", return_value=script),
        ):
            result = inspect_database_migration_status("postgresql://user:secret@db/app")

        self.assertEqual(result.status, "pending")
        self.assertEqual(result.current_revisions, ["20260704_0006"])
        self.assertNotIn("secret", result.message)

    def test_unavailable_and_metadata_errors_are_sanitized(self) -> None:
        script = MagicMock()
        script.get_heads.return_value = ("20260705_0007",)
        database_error = OperationalError(
            "connect",
            {},
            RuntimeError("postgresql://user:raw-password@db/app"),
        )
        with (
            patch("app.db.migration_status.ScriptDirectory.from_config", return_value=script),
            patch("app.db.migration_status.create_engine", side_effect=database_error),
        ):
            unavailable = inspect_database_migration_status(
                "postgresql://user:raw-password@db/app"
            )
        with patch(
            "app.db.migration_status.ScriptDirectory.from_config",
            side_effect=ValueError("raw migration path"),
        ):
            error = inspect_database_migration_status(
                "postgresql://user:raw-password@db/app"
            )

        self.assertEqual(unavailable.status, "unavailable")
        self.assertEqual(error.status, "error")
        self.assertNotIn("raw-password", unavailable.model_dump_json())
        self.assertNotIn("raw migration path", error.model_dump_json())


class DatabaseMigrationRunnerTestCase(unittest.TestCase):
    def test_runner_upgrades_to_head_and_logs_no_database_credentials(self) -> None:
        pending = DatabaseMigrationStatusRead(
            status="pending",
            current_revisions=["20260704_0006"],
            head_revisions=["20260705_0007"],
            message="Database migrations are pending.",
        )
        current = DatabaseMigrationStatusRead(
            status="up_to_date",
            current_revisions=["20260705_0007"],
            head_revisions=["20260705_0007"],
            message="Database migrations are up to date.",
        )
        with (
            patch.dict(
                os.environ,
                {"DATABASE_URL": "postgresql://user:raw-password@db/app"},
                clear=False,
            ),
            patch("app.db.migrate.load_dotenv"),
            patch(
                "app.db.migrate.inspect_database_migration_status",
                side_effect=[pending, current],
            ),
            patch("app.db.migrate.create_alembic_config", return_value=MagicMock()) as config,
            patch("app.db.migrate.command.upgrade") as upgrade,
            self.assertLogs("devdeploy.database_migrations", level=logging.INFO) as logs,
        ):
            exit_code = run_migrations()

        self.assertEqual(exit_code, 0)
        upgrade.assert_called_once_with(config.return_value, "head")
        self.assertNotIn("raw-password", " ".join(logs.output))
        self.assertNotIn("postgresql://", " ".join(logs.output))

    def test_runner_returns_nonzero_and_sanitizes_upgrade_failure(self) -> None:
        pending = DatabaseMigrationStatusRead(
            status="pending",
            head_revisions=["20260705_0007"],
            message="Database migrations are pending.",
        )
        with (
            patch.dict(
                os.environ,
                {"DATABASE_URL": "postgresql://user:raw-password@db/app"},
                clear=False,
            ),
            patch("app.db.migrate.load_dotenv"),
            patch("app.db.migrate.inspect_database_migration_status", return_value=pending),
            patch("app.db.migrate.create_alembic_config", return_value=MagicMock()),
            patch(
                "app.db.migrate.command.upgrade",
                side_effect=RuntimeError("postgresql://user:raw-password@db/app"),
            ),
            self.assertLogs("devdeploy.database_migrations", level=logging.ERROR) as logs,
        ):
            exit_code = run_migrations()

        self.assertEqual(exit_code, 1)
        self.assertNotIn("raw-password", " ".join(logs.output))
        self.assertNotIn("postgresql://", " ".join(logs.output))


class BackendReadinessTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.app = FastAPI()
        self.app.include_router(api_router, prefix="/api/v1")
        self.client = TestClient(self.app)

    def tearDown(self) -> None:
        self.client.close()

    def test_readiness_is_ready_only_when_migrations_are_current(self) -> None:
        self.app.dependency_overrides[get_database_migration_status] = lambda: (
            DatabaseMigrationStatusRead(
                status="up_to_date",
                current_revisions=["head"],
                head_revisions=["head"],
                message="Database migrations are up to date.",
            )
        )

        response = self.client.get("/api/v1/health/ready")

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["status"], "ready")
        self.assertEqual(response.json()["database_migrations"]["status"], "up_to_date")

    def test_pending_or_unavailable_migrations_make_readiness_degraded(self) -> None:
        for migration_state in ("pending", "unavailable", "error"):
            with self.subTest(migration_state=migration_state):
                self.app.dependency_overrides[get_database_migration_status] = lambda: (
                    DatabaseMigrationStatusRead(
                        status=migration_state,
                        message="Database migration readiness is not confirmed.",
                    )
                )
                response = self.client.get("/api/v1/health/ready")
                self.assertEqual(response.status_code, 503)
                self.assertEqual(response.json()["status"], "not_ready")
                self.assertEqual(
                    response.json()["database_migrations"]["status"],
                    migration_state,
                )


if __name__ == "__main__":
    unittest.main()
