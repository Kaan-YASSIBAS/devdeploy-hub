from functools import lru_cache
from pathlib import Path

from fastapi import Depends

from app.core.config import settings
from app.services.deployment_drift import (
    DeploymentDriftService,
    GitOpsManifestReader,
    UnavailableGitOpsManifestReader,
)
from app.services.gitops.kubernetes_status_reader import KubernetesGitOpsStatusReader
from app.services.gitops.status_reader import GitOpsStatusError
from app.services.product_runtime_status import ProductRuntimeStatusService, WorkloadRuntimeReader


@lru_cache(maxsize=1)
def get_workload_runtime_reader() -> WorkloadRuntimeReader | None:
    if settings.status_reader_mode != "kubernetes":
        return None
    try:
        return KubernetesGitOpsStatusReader.from_workload_server_config(
            workload_kubeconfig=settings.workload_kubeconfig,
            workload_kubeconfig_context=settings.workload_kubeconfig_context,
        )
    except GitOpsStatusError:
        return None


def get_product_runtime_status_service() -> ProductRuntimeStatusService:
    return ProductRuntimeStatusService(
        reader=get_workload_runtime_reader(),
        workload_namespace=settings.workload_namespace,
    )


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
