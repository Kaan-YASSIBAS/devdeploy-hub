from datetime import datetime, timedelta, timezone
import unittest

import jwt

from app.core.config import settings
from app.core.security import get_jwt_algorithm
from app.services.preview_session import (
    PREVIEW_SESSION_AUDIENCE,
    PREVIEW_SESSION_PURPOSE,
    create_preview_session_token,
    decode_preview_session_token,
)


class PreviewSessionTestCase(unittest.TestCase):
    def test_preview_session_is_owner_and_deployment_scoped(self) -> None:
        session = decode_preview_session_token(
            create_preview_session_token(user_id=42, deployment_id=7)
        )

        self.assertIsNotNone(session)
        self.assertEqual(session.user_id, 42)
        self.assertEqual(session.deployment_id, 7)

    def test_preview_session_expiry_is_enforced(self) -> None:
        now = datetime.now(timezone.utc)
        token = jwt.encode(
            {
                "sub": "42",
                "deployment_id": 7,
                "purpose": PREVIEW_SESSION_PURPOSE,
                "aud": PREVIEW_SESSION_AUDIENCE,
                "iat": now - timedelta(minutes=5),
                "exp": now - timedelta(seconds=1),
            },
            settings.jwt_secret_key,
            algorithm=get_jwt_algorithm(),
        )

        self.assertIsNone(decode_preview_session_token(token))

    def test_preview_session_rejects_wrong_purpose(self) -> None:
        now = datetime.now(timezone.utc)
        token = jwt.encode(
            {
                "sub": "42",
                "deployment_id": 7,
                "purpose": "api-auth",
                "aud": PREVIEW_SESSION_AUDIENCE,
                "iat": now,
                "exp": now + timedelta(minutes=1),
            },
            settings.jwt_secret_key,
            algorithm=get_jwt_algorithm(),
        )

        self.assertIsNone(decode_preview_session_token(token))


if __name__ == "__main__":
    unittest.main()
