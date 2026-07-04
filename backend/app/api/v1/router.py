from fastapi import APIRouter

from app.api.v1 import observability
from app.api.v1.endpoints import (
    applications,
    auth,
    dashboard,
    debug,
    deployment_records,
    deployments,
    gitops,
    services,
    settings,
    setup,
    users,
)


api_router = APIRouter()


@api_router.get("/health", tags=["health"])
def health_check() -> dict[str, str]:
    return {"status": "ok", "service": "devdeploy-backend"}


api_router.include_router(auth.router)
api_router.include_router(users.router)
api_router.include_router(applications.router)
api_router.include_router(services.router)
api_router.include_router(deployments.router)
api_router.include_router(deployment_records.router)
api_router.include_router(gitops.router)
api_router.include_router(dashboard.router)
api_router.include_router(observability.router)
api_router.include_router(settings.router)
api_router.include_router(setup.router)
api_router.include_router(debug.router)
