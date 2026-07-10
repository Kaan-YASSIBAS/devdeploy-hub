from functools import lru_cache
import logging
from pathlib import Path

from fastapi import Depends

from app.core.config import settings
from app.services.deployment_drift import (
    DeploymentDriftService,
    GitOpsManifestReader,
    UnavailableGitOpsManifestReader,
)
from app.services.deployment_preview_service import (
    KubernetesServiceProxyClient,
    WorkloadServiceProxy,
)
from app.services.gitops.kubernetes_status_reader import KubernetesGitOpsStatusReader
from app.services.product_runtime_status import ProductRuntimeStatusService, WorkloadRuntimeReader


logger = logging.getLogger(__name__)


@lru_cache(maxsize=1)
def get_workload_runtime_reader() -> WorkloadRuntimeReader | None:
    if settings.status_reader_mode != "kubernetes":
        return None
    try:
        return KubernetesGitOpsStatusReader.from_workload_server_config(
            workload_kubeconfig=settings.workload_kubeconfig,
            workload_kubeconfig_context=settings.workload_kubeconfig_context,
        )
    except Exception as error:
        logger.warning(
            "Workload runtime reader construction failed: %s.",
            error.__class__.__name__,
        )
        return None


def get_product_runtime_status_service() -> ProductRuntimeStatusService:
    return ProductRuntimeStatusService(
        reader=get_workload_runtime_reader(),
        workload_namespace=settings.workload_namespace,
    )


@lru_cache(maxsize=1)
def get_workload_service_proxy_client() -> WorkloadServiceProxy | None:
    if settings.status_reader_mode != "kubernetes":
        return None
    try:
        return KubernetesServiceProxyClient.from_server_config(
            workload_kubeconfig=settings.workload_kubeconfig,
            workload_kubeconfig_context=settings.workload_kubeconfig_context,
        )
    except Exception as error:
        logger.warning(
            "Workload Service proxy client construction failed: %s.",
            error.__class__.__name__,
        )
        return None


def get_deployment_drift_service(
    runtime_service: ProductRuntimeStatusService = Depends(get_product_runtime_status_service),
) -> DeploymentDriftService:
    manifest_reader = UnavailableGitOpsManifestReader()
    if settings.gitops_repo_root:
        try:
            manifest_reader = GitOpsManifestReader(
                Path(settings.gitops_repo_root),
                settings.gitops_source_root,
            )
        except (OSError, RuntimeError, ValueError):
            pass
    return DeploymentDriftService(
        manifest_reader=manifest_reader,
        runtime_service=runtime_service,
    )
