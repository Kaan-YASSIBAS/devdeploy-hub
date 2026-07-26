import unittest

from fastapi.testclient import TestClient

from app.main import PREVIEW_RUNTIME_AUTH_HEADER, app


class PreviewPreflightMiddlewareTestCase(unittest.TestCase):
    def test_preview_preflight_null_origin_bypasses_global_cors(self) -> None:
        with TestClient(app, raise_server_exceptions=False) as client:
            response = client.options(
                "/api/v1/deployment-records/23/preview/api/echo",
                headers={
                    "Origin": "null",
                    "Access-Control-Request-Method": "POST",
                    "Access-Control-Request-Headers": (
                        f"Content-Type, X-APP, {PREVIEW_RUNTIME_AUTH_HEADER}, Authorization, Cookie, X-Forwarded-Host"
                    ),
                },
            )

        self.assertEqual(response.status_code, 204, response.text)
        self.assertEqual(response.headers["access-control-allow-origin"], "null")
        self.assertEqual(response.headers["access-control-allow-credentials"], "true")
        self.assertIn("POST", response.headers["access-control-allow-methods"])
        self.assertIn("Content-Type", response.headers["access-control-allow-headers"])
        self.assertIn("X-APP", response.headers["access-control-allow-headers"])
        self.assertIn(PREVIEW_RUNTIME_AUTH_HEADER, response.headers["access-control-allow-headers"])
        self.assertNotIn("Authorization", response.headers["access-control-allow-headers"])
        self.assertNotIn("Cookie", response.headers["access-control-allow-headers"])
        self.assertNotIn("X-Forwarded-Host", response.headers["access-control-allow-headers"])

    def test_non_preview_preflight_still_uses_global_cors_policy(self) -> None:
        with TestClient(app, raise_server_exceptions=False) as client:
            response = client.options(
                "/api/v1/auth/me",
                headers={
                    "Origin": "null",
                    "Access-Control-Request-Method": "GET",
                },
            )

        self.assertEqual(response.status_code, 400)
        self.assertIn("Disallowed CORS origin", response.text)


if __name__ == "__main__":
    unittest.main()
