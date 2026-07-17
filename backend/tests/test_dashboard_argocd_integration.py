import unittest
from unittest.mock import MagicMock

from app.core.config import settings
from app.services.dashboard_service import DashboardService
from app.services.gitops.status_reader import GitOpsStatusError, RootApplicationSnapshot
from app.services.settings_service import SettingsService


class StaticRootApplicationReader:
    def __init__(self, snapshot=None, error=None):
        self.snapshot = snapshot
        self.error = error
        self.requests = []

    def read_root_application(self, request):
        self.requests.append(request)
        if self.error is not None:
            raise self.error
        return self.snapshot


class DashboardArgoCDIntegrationTestCase(unittest.TestCase):
    def _states(self, reader):
        settings_result = SettingsService._argocd_status(reader)
        dashboard_result = DashboardService(
            MagicMock(), root_application_reader=reader
        )._argocd_health()
        return settings_result, dashboard_result

    def test_dashboard_and_settings_share_healthy_root_application_state(self) -> None:
        reader = StaticRootApplicationReader(
            RootApplicationSnapshot(
                exists=True,
                observed_revision="a" * 40,
                sync_status="Synced",
                health_status="Healthy",
            )
        )

        settings_result, dashboard_result = self._states(reader)

        self.assertEqual(settings_result.status, "connected")
        self.assertEqual(dashboard_result.status, "healthy")
        self.assertEqual(settings_result.detail, dashboard_result.detail)
        for request in reader.requests:
            self.assertEqual(request.root_application_namespace, settings.argocd_namespace)
            self.assertEqual(request.root_application_name, settings.argocd_root_application_name)

    def test_dashboard_and_settings_share_degraded_state(self) -> None:
        settings_result, dashboard_result = self._states(
            StaticRootApplicationReader(
                RootApplicationSnapshot(
                    exists=True,
                    sync_status="OutOfSync",
                    health_status="Degraded",
                )
            )
        )

        self.assertEqual(settings_result.status, "degraded")
        self.assertEqual(dashboard_result.status, "degraded")
        self.assertEqual(settings_result.detail, dashboard_result.detail)

    def test_dashboard_and_settings_share_not_configured_state(self) -> None:
        settings_result, dashboard_result = self._states(
            StaticRootApplicationReader(RootApplicationSnapshot(exists=False))
        )

        self.assertEqual(settings_result.status, "not_configured")
        self.assertEqual(dashboard_result.status, "not_configured")

    def test_dashboard_and_settings_share_unavailable_state(self) -> None:
        settings_result, dashboard_result = self._states(
            StaticRootApplicationReader(
                error=GitOpsStatusError("status_reader_unavailable", "private detail")
            )
        )

        self.assertEqual(settings_result.status, "unavailable")
        self.assertEqual(dashboard_result.status, "unavailable")
        self.assertNotIn("private detail", dashboard_result.detail)


if __name__ == "__main__":
    unittest.main()
