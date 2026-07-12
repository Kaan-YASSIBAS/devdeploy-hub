import unittest
from unittest.mock import patch

from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.api.v1.endpoints import auth, settings
from app.core.deps import get_db
from app.core.security import create_access_token
from app.db.database import Base
from app.models.user import User


class LocalAdminMigrationTestCase(unittest.TestCase):
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
            email="kaan@example.com",
            username="kaan",
            hashed_password="test-only",
            role="developer",
            is_active=True,
        )
        self.db.add(self.user)
        self.db.commit()
        self.db.refresh(self.user)

        self.app = FastAPI()
        self.app.include_router(auth.router, prefix="/api/v1")
        self.app.include_router(settings.router, prefix="/api/v1")

        def override_get_db():
            yield self.db

        self.app.dependency_overrides[get_db] = override_get_db
        self.client = TestClient(self.app, raise_server_exceptions=False)

    def tearDown(self) -> None:
        self.client.close()
        self.db.close()
        Base.metadata.drop_all(self.engine)
        self.engine.dispose()

    def _auth_headers(self) -> dict[str, str]:
        token = create_access_token(self.user.id)
        return {"Authorization": f"Bearer {token}"}

    def test_existing_local_developer_user_is_persisted_as_admin_without_new_account(self) -> None:
        with patch("app.core.deps.settings.environment", "development"):
            response = self.client.get("/api/v1/auth/me", headers=self._auth_headers())

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["role"], "admin")

        self.db.refresh(self.user)
        self.assertEqual(self.user.role, "admin")
        self.assertEqual(self.db.query(User).count(), 1)

    def test_settings_profile_uses_persisted_admin_role_after_local_migration(self) -> None:
        headers = self._auth_headers()

        with patch("app.core.deps.settings.environment", "development"):
            self.client.get("/api/v1/auth/me", headers=headers)
            response = self.client.get("/api/v1/settings/profile", headers=headers)

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["role"], "admin")

    def test_existing_developer_user_remains_strict_outside_local_development(self) -> None:
        with patch("app.core.deps.settings.environment", "production"):
            response = self.client.get("/api/v1/auth/me", headers=self._auth_headers())

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["role"], "developer")

        self.db.refresh(self.user)
        self.assertEqual(self.user.role, "developer")

    def test_auth_me_remains_unauthenticated_401(self) -> None:
        response = self.client.get("/api/v1/auth/me")

        self.assertEqual(response.status_code, 401)


if __name__ == "__main__":
    unittest.main()
