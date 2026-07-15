import json
import shutil
import subprocess
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
LAUNCHER_PATH = REPOSITORY_ROOT / "scripts" / "launcher" / "devdeploy-launcher.ps1"


class LauncherStaleEvidenceReconciliationTestCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.launcher_text = LAUNCHER_PATH.read_text(encoding="utf-8-sig")
        cls.powershell = shutil.which("powershell")

    def function_body(self, name: str) -> str:
        marker = f"function {name}"
        start = self.launcher_text.index(marker)
        end = self.launcher_text.find("\nfunction ", start + len(marker))
        return self.launcher_text[start:] if end == -1 else self.launcher_text[start:end]

    def run_reconciliation(self, *, follow_up_succeeds: bool) -> dict:
        if self.powershell is None:
            self.skipTest("Windows PowerShell is not available")

        command_result = (
            '@{ exit_code = 0; timed_out = $false; stdout = "25.0.0"; stderr = "" }'
            if follow_up_succeeds
            else '@{ exit_code = $null; timed_out = $true; stdout = ""; stderr = "Command timed out." }'
        )
        script = "\n\n".join(
            [
                'function Get-Timestamp { "2026-01-01T00:00:00Z" }',
                "function Write-LauncherLog { param([string]$Message) }",
                f"function Invoke-ReadOnlyCommand {{ return {command_result} }}",
                self.function_body("Set-CheckResult"),
                self.function_body("Set-DockerDaemonCheckFromEvidence"),
                self.function_body("Test-DockerDaemonFollowUp"),
                "$Checks = New-Object System.Collections.ArrayList",
                "$null = $Checks.Add([ordered]@{ id = 'docker_daemon'; label = 'Docker daemon'; status = 'failed'; message = 'Docker daemon check timed out.'; details = @{ required = $true; error = 'Command timed out.' }; checked_at = 'earlier' })",
                "$reachable = Test-DockerDaemonFollowUp -DockerCliAvailable $true",
                "[ordered]@{ reachable = $reachable; check = $Checks[0] } | ConvertTo-Json -Depth 8",
            ]
        )
        completed = subprocess.run(
            [self.powershell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script],
            check=True,
            capture_output=True,
            text=True,
        )
        return json.loads(completed.stdout)

    def test_later_docker_evidence_supersedes_timed_out_probe(self) -> None:
        result = self.run_reconciliation(follow_up_succeeds=True)

        self.assertTrue(result["reachable"])
        self.assertEqual(result["check"]["status"], "ok")
        self.assertEqual(result["check"]["details"]["initial_probe_status"], "timed_out")
        self.assertEqual(result["check"]["details"]["evidence"], "docker_version_read_only")
        self.assertTrue(result["check"]["details"]["superseded"])

    def test_failed_follow_up_preserves_blocking_docker_failure(self) -> None:
        result = self.run_reconciliation(follow_up_succeeds=False)

        self.assertFalse(result["reachable"])
        self.assertEqual(result["check"]["status"], "failed")
        self.assertTrue(result["check"]["details"]["required"])

    def test_frontend_and_observability_dispatch_use_later_evidence(self) -> None:
        self.assertIn(
            'Set-DockerDaemonCheckFromEvidence -Evidence "management_kind_integrity_and_frontend_rollout"',
            self.launcher_text,
        )
        self.assertIn(
            'Set-DockerDaemonCheckFromEvidence -Evidence "workload_kind_integrity_and_observability_readiness"',
            self.launcher_text,
        )
        self.assertIn("Test-DockerDaemonFollowUp -DockerCliAvailable $dockerAvailable", self.launcher_text)

    def test_mutating_image_modes_still_require_reachable_docker(self) -> None:
        for function_name in (
            "Invoke-ManagementFrontendImageBuild",
            "Invoke-ManagementFrontendImageLoad",
        ):
            body = self.function_body(function_name)
            self.assertIn("-not $DockerCliAvailable -or -not $DockerDaemonReachable", body)
            self.assertLess(
                body.index("-not $DockerCliAvailable -or -not $DockerDaemonReachable"),
                body.index('Invoke-ReadOnlyCommand -FileName "docker"')
                if 'Invoke-ReadOnlyCommand -FileName "docker"' in body
                else body.index('Invoke-ReadOnlyCommand -FileName "kind"'),
            )


if __name__ == "__main__":
    unittest.main()
