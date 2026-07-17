import unittest

from app.core.config import settings
from app.services.gitops.status_reader import GitOpsStatusError, RootApplicationSnapshot
from app.services.settings_service import SettingsService


class StaticRootApplicationReader:
    def __init__(
        self,
        snapshot: RootApplicationSnapshot | None = None,
        error: Exception | None = None,
    ):
        self.snapshot = snapshot
        self.error = error
        self.requests = []

    def read_root_application(self, request):
        self.requests.append(request)
        if self.error is not None:
            raise self.error
        if self.snapshot is None:
            raise AssertionError("Root Application snapshot is not configured")
        return self.snapshot


class SettingsArgoCDIntegrationTestCase(unittest.TestCase):
    def test_healthy_root_application_is_connected(self) -> None:
        reader = StaticRootApplicationReader(
            RootApplicationSnapshot(
                exists=True,
                observed_revision="a" * 40,
                sync_status="Synced",
                health_status="Healthy",
            )
        )

        result = SettingsService._argocd_status(reader)

        self.assertEqual(result.status, "connected")
        self.assertIn("Synced and Healthy", result.detail)
        self.assertEqual(reader.requests[0].root_application_namespace, settings.argocd_namespace)
        self.assertEqual(reader.requests[0].root_application_name, settings.argocd_root_application_name)

    def test_degraded_root_application_is_configured_but_degraded(self) -> None:
        reader = StaticRootApplicationReader(
            RootApplicationSnapshot(
                exists=True,
                sync_status="OutOfSync",
                health_status="Degraded",
            )
        )

        result = SettingsService._argocd_status(reader)

        self.assertEqual(result.status, "degraded")
        self.assertIn("OutOfSync / Degraded", result.detail)

    def test_missing_namespace_or_root_application_is_not_configured(self) -> None:
        result = SettingsService._argocd_status(
            StaticRootApplicationReader(RootApplicationSnapshot(exists=False))
        )

        self.assertEqual(result.status, "not_configured")
        self.assertIn(settings.argocd_root_application_name, result.detail)

    def test_unreachable_api_is_unavailable_not_not_configured(self) -> None:
        result = SettingsService._argocd_status(
            StaticRootApplicationReader(
                error=GitOpsStatusError(
                    "status_reader_unavailable",
                    "raw connection detail must not escape",
                )
            )
        )

        self.assertEqual(result.status, "unavailable")
        self.assertNotIn("raw connection detail", result.detail)


if __name__ == "__main__":
    unittest.main()
