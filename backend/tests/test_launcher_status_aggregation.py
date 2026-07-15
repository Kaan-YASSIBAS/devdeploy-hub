import json
import shutil
import subprocess
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
LAUNCHER_PATH = REPOSITORY_ROOT / "scripts" / "launcher" / "devdeploy-launcher.ps1"


class LauncherStatusAggregationTestCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.launcher_text = LAUNCHER_PATH.read_text(encoding="utf-8-sig")
        cls.powershell = shutil.which("powershell")

    def function_body(self, name: str) -> str:
        marker = f"function {name}"
        start = self.launcher_text.index(marker)
        end = self.launcher_text.find("\nfunction ", start + len(marker))
        return self.launcher_text[start:] if end == -1 else self.launcher_text[start:end]

    def resolve_component(
        self,
        *,
        current: dict,
        persisted: dict | None,
        inspected: bool,
        source: str = "current_run",
    ) -> dict:
        if self.powershell is None:
            self.skipTest("Windows PowerShell is not available")

        current_json = json.dumps(current, separators=(",", ":"))
        persisted_json = "null" if persisted is None else json.dumps(persisted, separators=(",", ":"))
        script = "\n\n".join(
            [
                'function Get-Timestamp { "2026-01-01T00:00:00Z" }',
                self.function_body("Get-NamedObjectValue"),
                self.function_body("ConvertTo-PlatformStatusValue"),
                self.function_body("Test-PersistedPlatformComponentVerified"),
                self.function_body("Resolve-PlatformComponentStatus"),
                f"$current = '{current_json}' | ConvertFrom-Json",
                f"$persisted = '{persisted_json}' | ConvertFrom-Json",
                (
                    "$result = Resolve-PlatformComponentStatus -Current $current "
                    "-Persisted $persisted -Name 'Test component' "
                    "-LauncherMode 'management_frontend_bootstrap' "
                    f"-CurrentInspected ${str(inspected).lower()} -CurrentSource '{source}'"
                ),
                "$result | ConvertTo-Json -Depth 12",
            ]
        )
        completed = subprocess.run(
            [self.powershell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script],
            check=True,
            capture_output=True,
            text=True,
        )
        return json.loads(completed.stdout)

    def test_frontend_bootstrap_preserves_prior_verified_observability(self) -> None:
        result = self.resolve_component(
            current={
                "installed": False,
                "ready": False,
                "mode": "not_started",
                "status": "not_started",
                "message": "Workload observability bootstrap has not started.",
            },
            persisted={
                "installed": True,
                "ready": True,
                "mode": "verify",
                "status": "ready",
                "message": "Workload observability passed verification.",
                "checked_at": "2025-12-31T23:59:00Z",
            },
            inspected=False,
        )

        self.assertEqual(result["status"], "ready")
        self.assertTrue(result["installed"])
        self.assertTrue(result["ready"])
        self.assertEqual(result["status_source"], "persisted_prior_verified_state")
        self.assertTrue(result["carried_forward"])

    def test_frontend_only_mode_keeps_current_live_argocd_state(self) -> None:
        result = self.resolve_component(
            current={"installed": True, "ready": True, "status": "ready"},
            persisted={"installed": False, "ready": False, "status": "absent"},
            inspected=True,
            source="current_live_discovery",
        )

        self.assertEqual(result["status"], "ready")
        self.assertTrue(result["installed"])
        self.assertEqual(result["status_source"], "current_live_discovery")
        self.assertFalse(result["carried_forward"])

    def test_unrelated_component_without_verified_history_is_not_checked(self) -> None:
        result = self.resolve_component(
            current={
                "installed": False,
                "ready": False,
                "mode": "not_started",
                "status": "not_started",
            },
            persisted=None,
            inspected=False,
        )

        self.assertEqual(result["status"], "not_checked")
        self.assertEqual(result["mode"], "not_checked")
        self.assertIsNone(result["installed"])
        self.assertIsNone(result["ready"])
        self.assertNotEqual(result["status"], "absent")

    def test_genuine_live_absence_overrides_persisted_success(self) -> None:
        result = self.resolve_component(
            current={"installed": False, "ready": False, "status": "absent"},
            persisted={"installed": True, "ready": True, "status": "ready"},
            inspected=True,
            source="current_live_discovery",
        )

        self.assertEqual(result["status"], "absent")
        self.assertFalse(result["installed"])
        self.assertFalse(result["ready"])

    def test_current_live_failure_overrides_stale_persisted_success(self) -> None:
        result = self.resolve_component(
            current={"installed": True, "ready": False, "status": "degraded"},
            persisted={"installed": True, "ready": True, "status": "ready"},
            inspected=True,
            source="current_live_discovery",
        )

        self.assertEqual(result["status"], "degraded")
        self.assertFalse(result["ready"])
        self.assertEqual(result["status_source"], "current_live_discovery")

    def test_carried_component_keeps_existing_contract_fields(self) -> None:
        result = self.resolve_component(
            current={"status": "not_started"},
            persisted={
                "installed": True,
                "ready": True,
                "status": "ready",
                "release": "argocd",
                "service_proxy_paths_allowlisted": ["/api/v1/query", "/api/health"],
                "nested": {"value": 1},
            },
            inspected=False,
        )

        self.assertEqual(result["release"], "argocd")
        self.assertEqual(result["service_proxy_paths_allowlisted"], ["/api/v1/query", "/api/health"])
        self.assertEqual(result["nested"], {"value": 1})

    def test_platform_assembly_uses_live_and_persisted_sources(self) -> None:
        body = self.function_body("New-PlatformBootstrapStatus")

        self.assertIn("Get-ManagementArgoCDRuntimeStatus", body)
        self.assertIn("Get-GitOpsRootApplicationRuntimeStatus", body)
        self.assertIn("Get-PersistedPlatformComponent", body)
        self.assertIn('workload_cluster = $workloadClusterComponent', body)
        self.assertIn('workload_observability_status = [string]$workloadObservability["status"]', body)
        self.assertIn("one or more unrelated components were not checked", body)

    def test_status_document_loads_prior_snapshot_before_dispatch(self) -> None:
        prior_load = "$priorPlatformBootstrap = Get-PersistedPlatformBootstrapStatus"
        assembly = "-PriorPlatformBootstrap $priorPlatformBootstrap -LauncherMode $launcherMode"

        self.assertIn(prior_load, self.launcher_text)
        self.assertIn(assembly, self.launcher_text)
        self.assertLess(self.launcher_text.index(prior_load), self.launcher_text.index(assembly))


if __name__ == "__main__":
    unittest.main()
