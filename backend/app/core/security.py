from datetime import datetime, timedelta, timezone
import hashlib
from typing import Any

import jwt
from passlib.context import CryptContext

from app.core.config import settings


pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
ALLOWED_JWT_ALGORITHMS = {"HS256", "HS384", "HS512"}


def verify_password(plain_password: str, hashed_password: str) -> bool:
    return pwd_context.verify(plain_password, hashed_password)


def get_password_hash(password: str) -> str:
    return pwd_context.hash(password)


def hash_api_token(raw_token: str) -> str:
    return hashlib.sha256(raw_token.encode("utf-8")).hexdigest()


def get_jwt_algorithm() -> str:
    algorithm = settings.jwt_algorithm
    if algorithm not in ALLOWED_JWT_ALGORITHMS:
        raise ValueError("Unsupported JWT algorithm")
    return algorithm


def create_access_token(subject: str | int, expires_delta: timedelta | None = None) -> str:
    expire = datetime.now(timezone.utc) + (
        expires_delta or timedelta(minutes=settings.access_token_expire_minutes)
    )
    payload: dict[str, Any] = {"sub": str(subject), "exp": expire}
    return jwt.encode(payload, settings.jwt_secret_key, algorithm=get_jwt_algorithm())
