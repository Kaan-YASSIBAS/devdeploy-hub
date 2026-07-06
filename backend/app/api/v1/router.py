from fastapi import APIRouter, Depends, Response, status

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
from app.db.migration_status import get_database_migration_status
from app.schemas.health import BackendReadinessResponse, DatabaseMigrationStatusRead


api_router = APIRouter()


@api_router.get("/health", tags=["health"])
def health_check() -> dict[str, str]:
    return {"status": "ok", "service": "devdeploy-backend"}


@api_router.get("/health/ready", tags=["health"], response_model=BackendReadinessResponse)
def readiness_check(
    response: Response,
    migration_status: DatabaseMigrationStatusRead = Depends(get_database_migration_status),
) -> BackendReadinessResponse:
    ready = migration_status.status == "up_to_date"
    if not ready:
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
    return BackendReadinessResponse(
        status="ready" if ready else "not_ready",
        database_migrations=migration_status,
    )


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
