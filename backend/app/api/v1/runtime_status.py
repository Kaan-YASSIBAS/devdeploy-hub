from functools import lru_cache

from app.core.config import settings
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
