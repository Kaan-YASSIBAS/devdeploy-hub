from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

import jwt
from jwt import InvalidTokenError

from app.core.config import settings
from app.core.security import get_jwt_algorithm


PREVIEW_SESSION_COOKIE = "devdeploy_preview_session"
PREVIEW_SESSION_AUDIENCE = "devdeploy-app-preview"
PREVIEW_SESSION_PURPOSE = "deployment-preview"
PREVIEW_SESSION_TTL_SECONDS = 120


@dataclass(frozen=True, slots=True)
class PreviewSession:
    user_id: int
    deployment_id: int


def create_preview_session_token(*, user_id: int, deployment_id: int) -> str:
    now = datetime.now(timezone.utc)
    payload = {
        "sub": str(user_id),
        "deployment_id": deployment_id,
        "purpose": PREVIEW_SESSION_PURPOSE,
        "aud": PREVIEW_SESSION_AUDIENCE,
        "iat": now,
        "exp": now + timedelta(seconds=PREVIEW_SESSION_TTL_SECONDS),
    }
    return jwt.encode(
        payload,
        settings.jwt_secret_key,
        algorithm=get_jwt_algorithm(),
    )


def decode_preview_session_token(token: str) -> PreviewSession | None:
    try:
        payload = jwt.decode(
            token,
            settings.jwt_secret_key,
            algorithms=[get_jwt_algorithm()],
            audience=PREVIEW_SESSION_AUDIENCE,
            options={"require": ["aud", "deployment_id", "exp", "purpose", "sub"]},
        )
        if payload.get("purpose") != PREVIEW_SESSION_PURPOSE:
            return None
        user_id = int(payload["sub"])
        deployment_id = int(payload["deployment_id"])
        if user_id <= 0 or deployment_id <= 0:
            return None
        return PreviewSession(user_id=user_id, deployment_id=deployment_id)
    except (InvalidTokenError, KeyError, TypeError, ValueError):
        return None
