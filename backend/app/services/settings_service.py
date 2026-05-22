from datetime import datetime, timezone
import hashlib
import secrets
from collections.abc import Callable
from typing import Literal

import httpx
from kubernetes.client import ApiException
from sqlalchemy.orm import Session

from app.core.config import settings
from app.models.settings import ApiToken, WorkspaceSettings
from app.models.user import User
from app.schemas.settings import (
    ApiTokenResponse,
    IntegrationStatusResponse,
    ProfileSettingsResponse,
)
from app.services.kubernetes_service import KubernetesService
from app.services.observability_errors import ObservabilityUnavailableError


DEFAULT_WORKSPACE_NAME = "DevDeploy Hub Workspace"
DEFAULT_WORKSPACE_PLAN = "Local"
TOKEN_PREFIX = "ddh_live"


class SettingsService:
    def __init__(self, db: Session):
        self.db = db

    def get_profile(self, user: User) -> ProfileSettingsResponse:
        return ProfileSettingsResponse(
            id=user.id,
            display_name=self._display_name(user),
            email=user.email,
            role=user.role,
        )

    def update_profile(self, user: User, display_name: str) -> ProfileSettingsResponse:
        user.display_name = display_name.strip()
        self.db.commit()
        self.db.refresh(user)
        return self.get_profile(user)

    def get_workspace(self) -> WorkspaceSettings:
        workspace = self.db.query(WorkspaceSettings).order_by(WorkspaceSettings.id.asc()).first()
        if workspace is not None:
            return workspace

        workspace = WorkspaceSettings(name=DEFAULT_WORKSPACE_NAME, plan=DEFAULT_WORKSPACE_PLAN)
        self.db.add(workspace)
        self.db.commit()
        self.db.refresh(workspace)
        return workspace

    def update_workspace(self, name: str) -> WorkspaceSettings:
        workspace = self.get_workspace()
        workspace.name = name.strip()
        self.db.commit()
        self.db.refresh(workspace)
        return workspace

    def list_api_tokens(self, user: User) -> list[ApiTokenResponse]:
        tokens = (
            self.db.query(ApiToken)
            .filter(ApiToken.user_id == user.id)
            .order_by(ApiToken.created_at.desc())
            .all()
        )
        return [self._token_response(token) for token in tokens]

    def create_api_token(self, user: User, name: str) -> tuple[str, ApiTokenResponse]:
        raw_token = f"{TOKEN_PREFIX}_{secrets.token_urlsafe(32)}"
        token = ApiToken(
            user_id=user.id,
            name=name.strip(),
            token_hash=self._hash_token(raw_token),
            prefix=raw_token[:16],
            last_four=raw_token[-4:],
        )
        self.db.add(token)
        self.db.commit()
        self.db.refresh(token)
        return raw_token, self._token_response(token)

    def revoke_api_token(self, token_id: int, user: User) -> None:
        query = self.db.query(ApiToken).filter(ApiToken.id == token_id)
        if user.role != "admin":
            query = query.filter(ApiToken.user_id == user.id)
        token = query.first()
        if token is None:
            return
        token.revoked_at = datetime.now(timezone.utc)
        self.db.commit()

    @staticmethod
    def list_integrations() -> list[IntegrationStatusResponse]:
        return [
            SettingsService._safe_integration_status("github", "GitHub", SettingsService._github_status),
            SettingsService._safe_integration_status("argocd", "Argo CD", SettingsService._argocd_status),
            SettingsService._safe_integration_status("kubernetes", "Kubernetes", SettingsService._kubernetes_status),
            SettingsService._safe_integration_status("grafana", "Grafana", SettingsService._grafana_status),
        ]

    @staticmethod
    def _safe_integration_status(
        key: Literal["github", "argocd", "kubernetes", "grafana"],
        name: str,
        check: Callable[[], IntegrationStatusResponse],
    ) -> IntegrationStatusResponse:
        try:
            return check()
        except Exception as exc:
            return IntegrationStatusResponse(
                key=key,
                name=name,
                status="error",
                detail=f"{name} integration check failed: {exc.__class__.__name__}",
            )

    @staticmethod
    def _display_name(user: User) -> str:
        if user.display_name:
            return user.display_name
        local_part = user.email.split("@", 1)[0]
        return user.username or local_part

    @staticmethod
    def _hash_token(raw_token: str) -> str:
        return hashlib.sha256(raw_token.encode("utf-8")).hexdigest()

    @staticmethod
    def _token_response(token: ApiToken) -> ApiTokenResponse:
        return ApiTokenResponse(
            id=token.id,
            name=token.name,
            prefix=token.prefix,
            last_four=token.last_four,
            created_at=token.created_at,
            last_used_at=token.last_used_at,
            revoked_at=token.revoked_at,
            active=token.revoked_at is None,
        )

    @staticmethod
    def _github_status() -> IntegrationStatusResponse:
        if not settings.github_workflow_token or not settings.github_owner or not settings.github_repo:
            return IntegrationStatusResponse(
                key="github",
                name="GitHub",
                status="not_configured",
                detail="GitHub workflow token or repository settings are missing.",
            )

        url = (
            f"https://api.github.com/repos/{settings.github_owner}/{settings.github_repo}"
            f"/actions/workflows/{settings.gitops_workflow_file}"
        )
        headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {settings.github_workflow_token}",
            "X-GitHub-Api-Version": "2022-11-28",
        }
        try:
            response = httpx.get(url, headers=headers, timeout=8.0)
            response.raise_for_status()
        except httpx.HTTPError as exc:
            return IntegrationStatusResponse(
                key="github",
                name="GitHub",
                status="error",
                detail=f"GitHub workflow API check failed: {exc.__class__.__name__}",
            )
        return IntegrationStatusResponse(
            key="github",
            name="GitHub",
            status="connected",
            detail="Workflow dispatch API is reachable.",
        )

    @staticmethod
    def _kubernetes_status() -> IntegrationStatusResponse:
        try:
            KubernetesService().check_health()
        except ObservabilityUnavailableError as exc:
            return IntegrationStatusResponse(
                key="kubernetes",
                name="Kubernetes",
                status="not_configured",
                detail=str(exc),
            )
        except ApiException as exc:
            return IntegrationStatusResponse(
                key="kubernetes",
                name="Kubernetes",
                status="error",
                detail=f"Kubernetes API request failed: {exc.reason or exc.status}",
            )
        return IntegrationStatusResponse(
            key="kubernetes",
            name="Kubernetes",
            status="connected",
            detail="Read-only Kubernetes API access is available.",
        )

    @staticmethod
    def _argocd_status() -> IntegrationStatusResponse:
        service = KubernetesService()
        try:
            if not service.namespace_exists("argocd"):
                return IntegrationStatusResponse(
                    key="argocd",
                    name="Argo CD",
                    status="not_configured",
                    detail="The argocd namespace was not found.",
                )
            if not service.argocd_application_exists("devdeploy-hub-release"):
                return IntegrationStatusResponse(
                    key="argocd",
                    name="Argo CD",
                    status="not_configured",
                    detail="The devdeploy-hub-release Application was not found.",
                )
        except ObservabilityUnavailableError as exc:
            return IntegrationStatusResponse(
                key="argocd",
                name="Argo CD",
                status="not_configured",
                detail=str(exc),
            )
        except ApiException as exc:
            return IntegrationStatusResponse(
                key="argocd",
                name="Argo CD",
                status="error",
                detail=f"Argo CD Application check failed: {exc.reason or exc.status}",
            )
        return IntegrationStatusResponse(
            key="argocd",
            name="Argo CD",
            status="connected",
            detail="The devdeploy-hub-release Application is visible.",
        )

    @staticmethod
    def _grafana_status() -> IntegrationStatusResponse:
        if not settings.grafana_base_url:
            return IntegrationStatusResponse(
                key="grafana",
                name="Grafana",
                status="not_configured",
                detail="GRAFANA_BASE_URL is not configured.",
            )

        base_url = settings.grafana_base_url.rstrip("/")
        try:
            response = httpx.get(f"{base_url}/api/health", timeout=8.0)
            response.raise_for_status()
        except httpx.HTTPError as exc:
            return IntegrationStatusResponse(
                key="grafana",
                name="Grafana",
                status="error",
                detail=f"Grafana health check failed: {exc.__class__.__name__}",
            )
        return IntegrationStatusResponse(
            key="grafana",
            name="Grafana",
            status="connected",
            detail="Grafana health endpoint is reachable.",
        )
