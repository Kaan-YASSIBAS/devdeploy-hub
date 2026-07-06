from functools import lru_cache

from fastapi import APIRouter, Depends

from app.core.config import settings
from app.core.deps import get_current_user
from app.models.user import User
from app.schemas.platform import PlatformClusterHealthResponse
from app.services.platform_cluster_health import PlatformClusterHealthService


router = APIRouter(prefix="/platform", tags=["platform"])


@lru_cache(maxsize=1)
def get_platform_cluster_health_service() -> PlatformClusterHealthService:
    return PlatformClusterHealthService.from_server_config(
        management_kubeconfig=settings.management_kubeconfig,
        management_kubeconfig_context=settings.management_kubeconfig_context,
        workload_kubeconfig=settings.workload_kubeconfig,
        workload_kubeconfig_context=settings.workload_kubeconfig_context,
        use_in_cluster_management=settings.kubernetes_in_cluster,
    )


@router.get("/cluster-health", response_model=PlatformClusterHealthResponse)
def get_platform_cluster_health(
    current_user: User = Depends(get_current_user),
    health_service: PlatformClusterHealthService = Depends(get_platform_cluster_health_service),
) -> PlatformClusterHealthResponse:
    _ = current_user
    return health_service.read_health()
