from dataclasses import dataclass
from typing import Literal

from app.core.config import settings
from app.services.gitops.status_reader import (
    GitOpsStatusError,
    GitOpsStatusRequest,
    RootApplicationSnapshot,
)


ArgoCDIntegrationState = Literal[
    "connected",
    "degraded",
    "not_configured",
    "unavailable",
]


@dataclass(frozen=True)
class ArgoCDIntegrationStatus:
    status: ArgoCDIntegrationState
    detail: str


def read_argocd_integration_status(root_application_reader=None) -> ArgoCDIntegrationStatus:
    if root_application_reader is None:
        return ArgoCDIntegrationStatus(
            status="unavailable",
            detail="Argo CD Root Application status is temporarily unavailable.",
        )

    try:
        request = GitOpsStatusRequest(
            app_name="integration-check",
            commit_sha="0" * 40,
            namespace=settings.workload_namespace,
            root_application_name=settings.argocd_root_application_name,
            root_application_namespace=settings.argocd_namespace,
        )
        root: RootApplicationSnapshot = root_application_reader.read_root_application(request)
    except (GitOpsStatusError, OSError, TimeoutError):
        return ArgoCDIntegrationStatus(
            status="unavailable",
            detail="Argo CD Root Application status is temporarily unavailable.",
        )

    if not root.exists:
        return ArgoCDIntegrationStatus(
            status="not_configured",
            detail=(
                f"The configured Root Application {settings.argocd_namespace}/"
                f"{settings.argocd_root_application_name} was not found."
            ),
        )
    if root.failure_detected or root.sync_status != "Synced" or root.health_status != "Healthy":
        return ArgoCDIntegrationStatus(
            status="degraded",
            detail=(
                f"Root Application {settings.argocd_root_application_name} is "
                f"{root.sync_status or 'Unknown'} / {root.health_status or 'Unknown'}."
            ),
        )
    return ArgoCDIntegrationStatus(
        status="connected",
        detail=f"Root Application {settings.argocd_root_application_name} is Synced and Healthy.",
    )
