from fastapi import APIRouter, Depends, Response, status
from sqlalchemy.orm import Session

from app.core.deps import get_current_user, get_db
from app.models.user import User
from app.schemas.settings import (
    ApiTokenCreateRequest,
    ApiTokenCreateResponse,
    ApiTokenResponse,
    IntegrationStatusResponse,
    ProfileSettingsResponse,
    ProfileSettingsUpdate,
    WorkspaceSettingsResponse,
    WorkspaceSettingsUpdate,
)
from app.services.settings_service import SettingsService
from app.api.v1.runtime_status import get_management_root_application_reader
from app.services.deployment_destroy_service import RootApplicationObservationReader


router = APIRouter(prefix="/settings", tags=["settings"])


@router.get("/profile", response_model=ProfileSettingsResponse)
def get_profile(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> ProfileSettingsResponse:
    return SettingsService(db).get_profile(current_user)


@router.put("/profile", response_model=ProfileSettingsResponse)
def update_profile(
    payload: ProfileSettingsUpdate,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> ProfileSettingsResponse:
    return SettingsService(db).update_profile(current_user, payload.display_name)


@router.get("/workspace", response_model=WorkspaceSettingsResponse)
def get_workspace(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> WorkspaceSettingsResponse:
    _ = current_user
    return SettingsService(db).get_workspace()


@router.put("/workspace", response_model=WorkspaceSettingsResponse)
def update_workspace(
    payload: WorkspaceSettingsUpdate,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> WorkspaceSettingsResponse:
    _ = current_user
    return SettingsService(db).update_workspace(payload.name)


@router.get("/api-tokens", response_model=list[ApiTokenResponse])
def list_api_tokens(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[ApiTokenResponse]:
    return SettingsService(db).list_api_tokens(current_user)


@router.post("/api-tokens", response_model=ApiTokenCreateResponse, status_code=status.HTTP_201_CREATED)
def create_api_token(
    payload: ApiTokenCreateRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> ApiTokenCreateResponse:
    raw_token, token = SettingsService(db).create_api_token(current_user, payload.name)
    return ApiTokenCreateResponse(token=raw_token, item=token)


@router.post("/api-tokens/{token_id}/revoke", status_code=status.HTTP_204_NO_CONTENT)
def revoke_api_token(
    token_id: int,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> Response:
    SettingsService(db).revoke_api_token(token_id, current_user)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.delete("/api-tokens/{token_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_api_token(
    token_id: int,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> Response:
    SettingsService(db).delete_api_token(token_id, current_user)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/integrations", response_model=list[IntegrationStatusResponse])
def list_integrations(
    current_user: User = Depends(get_current_user),
    root_application_reader: RootApplicationObservationReader | None = Depends(
        get_management_root_application_reader
    ),
) -> list[IntegrationStatusResponse]:
    _ = current_user
    return SettingsService.list_integrations(root_application_reader)
