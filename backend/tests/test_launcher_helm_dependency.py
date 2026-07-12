import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
LAUNCHER = REPO_ROOT / "scripts" / "launcher" / "devdeploy-launcher.ps1"


class LauncherHelmDependencyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.script = LAUNCHER.read_text(encoding="utf-8")

    def test_bootstrap_can_prepare_pinned_official_helm(self):
        self.assertIn('$HelmPinnedVersion = "v3.18.6"', self.script)
        self.assertIn('$HelmDownloadBaseUrl = "https://get.helm.sh"', self.script)
        self.assertIn("$HelmChecksumUrl = \"$HelmArchiveUrl.sha256sum\"", self.script)
        self.assertIn("Invoke-PrepareManagedHelm", self.script)
        self.assertIn("Invoke-WebRequest -Uri $HelmChecksumUrl", self.script)
        self.assertIn("Invoke-WebRequest -Uri $HelmArchiveUrl", self.script)
        self.assertIn("Get-FileHash -LiteralPath $HelmManagedArchivePath -Algorithm SHA256", self.script)
        self.assertIn("Expand-Archive -LiteralPath $HelmManagedArchivePath", self.script)

    def test_checksum_mismatch_fails_closed(self):
        self.assertIn("checksum mismatch; refusing to use the downloaded binary", self.script)
        self.assertRegex(
            self.script,
            r"if \(\$actualHash\.ToLowerInvariant\(\) -ne \$expectedHash\.ToLowerInvariant\(\)\) \{[\s\S]+?return \$result",
        )

    def test_verify_mode_does_not_install_helm(self):
        verify_only_branch = re.search(
            r"if \(-not \$BootstrapMode\) \{(?P<body>[\s\S]+?)\n    \}\n\n    \$prepared = Invoke-PrepareManagedHelm",
            self.script,
        )
        self.assertIsNotNone(verify_only_branch)
        self.assertIn("installs_dependency = $false", verify_only_branch.group("body"))
        self.assertIn("return [ordered]@", verify_only_branch.group("body"))

    def test_workload_observability_reuses_existing_compatible_helm(self):
        resolver = re.search(
            r"function Resolve-WorkloadObservabilityHelm \{(?P<body>[\s\S]+?)\n\}\n\nfunction Invoke-SanitizedInputCommand",
            self.script,
        )
        self.assertIsNotNone(resolver)
        body = resolver.group("body")
        self.assertIn('Get-Command "helm"', body)
        self.assertIn('source = "path"', body)
        self.assertIn('A compatible Helm v3 CLI is available on PATH.', body)
        self.assertLess(body.index('Get-Command "helm"'), body.index("Invoke-PrepareManagedHelm"))

    def test_managed_helm_is_kept_under_devdeploy_local_tools(self):
        self.assertIn('$ToolsDir = Join-Path $LocalRoot "tools"', self.script)
        self.assertIn('$HelmManagedDir = Join-Path $ToolsDir ("helm\\{0}" -f $HelmPinnedVersion)', self.script)
        self.assertIn("New-LocalDirectory -Path $ToolsDir", self.script)
        self.assertNotIn("setx ", self.script.lower())
        self.assertNotIn("[environment]::setenvironmentvariable", self.script.lower())

    def test_workload_observability_uses_resolved_helm_command(self):
        self.assertIn("Resolve-WorkloadObservabilityHelm -BootstrapMode ([bool]$BootstrapWorkloadObservability)", self.script)
        self.assertIn("-HelmCommand $workloadObservabilityHelmCommand", self.script)
        self.assertIn('Invoke-ReadOnlyCommand -FileName $HelmCommand -Arguments @("repo", "add"', self.script)
        self.assertIn('Invoke-ReadOnlyCommand -FileName $HelmCommand -Arguments @("repo", "update"', self.script)
        self.assertIn("Invoke-ReadOnlyCommand -FileName $HelmCommand -Arguments $helmArgs", self.script)

    def test_no_download_token_or_secret_shape_in_helm_urls(self):
        helm_constant_lines = [
            line for line in self.script.splitlines()
            if line.startswith("$Helm") and ("Url" in line or "BaseUrl" in line)
        ]
        joined = "\n".join(helm_constant_lines).lower()
        self.assertIn("https://get.helm.sh", joined)
        self.assertNotIn("token", joined)
        self.assertNotIn("password", joined)
        self.assertNotIn("secret", joined)

    def test_grafana_password_rng_is_windows_powershell_51_compatible(self):
        self.assertNotIn("RandomNumberGenerator]::Fill", self.script)
        manifest_function = re.search(
            r"function New-GrafanaCredentialSecretManifest \{(?P<body>[\s\S]+?)\n\}",
            self.script,
        )
        self.assertIsNotNone(manifest_function)
        body = manifest_function.group("body")
        self.assertIn("[System.Security.Cryptography.RandomNumberGenerator]::Create()", body)
        self.assertIn("$generator.GetBytes($passwordBytes)", body)
        self.assertIn("[Array]::Clear($passwordBytes, 0, $passwordBytes.Length)", body)
        self.assertIn("$generator.Dispose()", body)
        self.assertNotIn("System.Random", body)

    def test_workload_observability_stops_on_pending_helm_release(self):
        self.assertIn('"pending-install", "pending-upgrade", "pending-rollback"', self.script)
        self.assertIn("Helm release {0} is stuck in {1}", self.script)
        self.assertIn("history {1}", self.script)
        self.assertIn("deletes_resources = $false", self.script)


if __name__ == "__main__":
    unittest.main()
