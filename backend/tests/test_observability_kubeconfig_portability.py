import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from app.core.config import Settings
from app.services.observability_service_proxy import KubernetesServiceProxyTransport


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]


class ObservabilityKubeconfigPortabilityTestCase(unittest.TestCase):
    def launcher_text(self) -> str:
        return (REPOSITORY_ROOT / "scripts" / "launcher" / "devdeploy-launcher.ps1").read_text(
            encoding="utf-8-sig"
        )

    def launcher_function_body(self, name: str) -> str:
        text = self.launcher_text()
        marker = f"function {name}"
        start = text.index(marker)
        next_function = text.find("\nfunction ", start + len(marker))
        if next_function == -1:
            return text[start:]
        return text[start:next_function]

    def run_launcher_kubeconfig_parser(self, payload: dict) -> dict:
        powershell = shutil.which("powershell")
        if powershell is None:
            self.skipTest("Windows PowerShell is not available")

        functions = "\n\n".join(
            [
                self.launcher_function_body("Get-JsonPropertyValue"),
                self.launcher_function_body("Convert-HostWorkloadKubeconfigJson"),
            ]
        )
        with tempfile.TemporaryDirectory() as tmpdir:
            json_path = Path(tmpdir) / "kubeconfig-view.json"
            script_path = Path(tmpdir) / "parse.ps1"
            json_path.write_text(json.dumps(payload), encoding="utf-8")
            script_path.write_text(
                "\n".join(
                    [
                        functions,
                        f"$json = Get-Content -LiteralPath '{json_path}' -Raw",
                        "$result = Convert-HostWorkloadKubeconfigJson -Json $json",
                        "$result | ConvertTo-Json -Depth 10",
                    ]
                ),
                encoding="utf-8",
            )

            completed = subprocess.run(
                [powershell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script_path)],
                check=True,
                capture_output=True,
                text=True,
            )

        return json.loads(completed.stdout)

    def run_launcher_managed_selection(self, managed_path: Path) -> dict:
        powershell = shutil.which("powershell")
        if powershell is None:
            self.skipTest("Windows PowerShell is not available")

        script = "\n".join(
            [
                f"$ObservabilityLocalKubeconfigPath = '{managed_path}'",
                '$ObservabilityKubeconfigContext = "devdeploy-workload-observability"',
                self.launcher_function_body("Get-LauncherWorkloadKubeconfigSelection"),
                "Get-LauncherWorkloadKubeconfigSelection | ConvertTo-Json -Depth 5",
            ]
        )
        completed = subprocess.run(
            [powershell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script],
            check=True,
            capture_output=True,
            text=True,
        )
        return json.loads(completed.stdout)

    def test_example_and_assets_do_not_use_machine_specific_paths(self) -> None:
        checked_paths = [
            REPOSITORY_ROOT / "backend" / ".env.example",
            REPOSITORY_ROOT / "platform" / "management" / "backend" / "configmap.yaml",
            REPOSITORY_ROOT / "platform" / "management" / "backend" / "deployment.yaml",
            REPOSITORY_ROOT / "scripts" / "launcher" / "devdeploy-launcher.ps1",
        ]

        for path in checked_paths:
            text = path.read_text(encoding="utf-8")
            self.assertNotIn("C:\\Users\\", text)
            self.assertNotIn("C:\\Users\\kyass", text)
            self.assertNotIn("Desktop\\devdeploy-hub", text)

    def test_managed_relative_observability_path_resolves_from_runtime_root(self) -> None:
        with tempfile.TemporaryDirectory() as runtime_root:
            settings = Settings(
                _env_file=None,
                DATABASE_URL="postgresql://devdeploy:devdeploy@localhost:5432/devdeploy",
                JWT_SECRET_KEY="x" * 32,
                DEVDEPLOY_RUNTIME_ROOT=runtime_root,
                DEVDEPLOY_OBSERVABILITY_WORKLOAD_KUBECONFIG=(
                    "../.devdeploy/local/kubeconfig/observability-workload-kubeconfig.yaml"
                ),
            )

            self.assertEqual(
                settings.resolved_observability_workload_kubeconfig,
                str(Path(runtime_root) / ".devdeploy/local/kubeconfig/observability-workload-kubeconfig.yaml"),
            )

    def test_observability_and_normal_workload_kubeconfigs_are_isolated(self) -> None:
        settings = Settings(
            _env_file=None,
            DATABASE_URL="postgresql://devdeploy:devdeploy@localhost:5432/devdeploy",
            JWT_SECRET_KEY="x" * 32,
            DEVDEPLOY_RUNTIME_ROOT="D:/other/devdeploy-hub",
            DEVDEPLOY_WORKLOAD_KUBECONFIG="~/.kube/config",
            DEVDEPLOY_WORKLOAD_KUBECONFIG_CONTEXT="kind-devdeploy-workload",
            DEVDEPLOY_OBSERVABILITY_WORKLOAD_KUBECONFIG=(
                "../.devdeploy/local/kubeconfig/observability-workload-kubeconfig.yaml"
            ),
            DEVDEPLOY_OBSERVABILITY_WORKLOAD_KUBECONFIG_CONTEXT="devdeploy-workload-observability",
        )

        self.assertEqual(settings.workload_kubeconfig, "~/.kube/config")
        self.assertEqual(settings.workload_kubeconfig_context, "kind-devdeploy-workload")
        self.assertNotEqual(
            settings.workload_kubeconfig,
            settings.resolved_observability_workload_kubeconfig,
        )
        self.assertEqual(
            settings.observability_workload_kubeconfig_context,
            "devdeploy-workload-observability",
        )

    def test_normal_workload_kubeconfig_does_not_fall_back_to_observability(self) -> None:
        settings = Settings(
            _env_file=None,
            DATABASE_URL="postgresql://devdeploy:devdeploy@localhost:5432/devdeploy",
            JWT_SECRET_KEY="x" * 32,
            DEVDEPLOY_RUNTIME_ROOT="D:/portable/devdeploy-hub",
            DEVDEPLOY_WORKLOAD_KUBECONFIG="",
            DEVDEPLOY_WORKLOAD_KUBECONFIG_CONTEXT="",
            DEVDEPLOY_OBSERVABILITY_WORKLOAD_KUBECONFIG=(
                "../.devdeploy/local/kubeconfig/observability-workload-kubeconfig.yaml"
            ),
            DEVDEPLOY_OBSERVABILITY_WORKLOAD_KUBECONFIG_CONTEXT="devdeploy-workload-observability",
        )

        self.assertIsNone(settings.resolved_workload_kubeconfig)
        self.assertIsNone(settings.resolved_workload_kubeconfig_context)
        self.assertEqual(
            settings.resolved_observability_workload_kubeconfig,
            "D:\\portable\\devdeploy-hub\\.devdeploy\\local\\kubeconfig"
            "\\observability-workload-kubeconfig.yaml",
        )

    def test_service_proxy_loads_observability_kubeconfig_not_normal_workload(self) -> None:
        fake_settings = SimpleNamespace(
            resolved_observability_workload_kubeconfig=(
                "D:/other/devdeploy-hub/.devdeploy/local/kubeconfig/observability-workload-kubeconfig.yaml"
            ),
            observability_workload_kubeconfig_context="devdeploy-workload-observability",
            workload_kubeconfig="~/.kube/config",
        )
        with (
            patch("app.services.observability_service_proxy.settings", fake_settings),
            patch("app.services.observability_service_proxy.config.load_kube_config") as load_kube_config,
            patch("app.services.observability_service_proxy.client.ApiClient", return_value="api-client"),
        ):
            api_client = KubernetesServiceProxyTransport._build_workload_api_client()

        self.assertEqual(api_client, "api-client")
        self.assertEqual(
            load_kube_config.call_args.kwargs["config_file"],
            "D:/other/devdeploy-hub/.devdeploy/local/kubeconfig/observability-workload-kubeconfig.yaml",
        )
        self.assertEqual(
            load_kube_config.call_args.kwargs["context"],
            "devdeploy-workload-observability",
        )

    def test_launcher_resolves_host_local_endpoint_from_selected_workload_context(self) -> None:
        selection_body = self.launcher_function_body("Get-LauncherWorkloadKubeconfigSelection")
        body = self.launcher_function_body("Get-HostWorkloadKubeconfigCluster")

        self.assertIn("DEVDEPLOY_WORKLOAD_KUBECONFIG", selection_body)
        self.assertIn("DEVDEPLOY_WORKLOAD_KUBECONFIG_CONTEXT", selection_body)
        self.assertIn('$args = @("config", "view")', body)
        self.assertIn('$args += @("--kubeconfig", [string]$selection["kubeconfig_path"])', body)
        self.assertIn('"--context", [string]$selection["context"], "--minify", "--raw", "--output=json"', body)
        self.assertIn("Convert-HostWorkloadKubeconfigJson -Json $stdoutText", body)
        self.assertNotIn("58081", body)
        self.assertNotIn("devdeploy-workload-control-plane", body)
        self.assertIn('Get-CommandResultField -Result $viewResult -Name "exit_code"', body)
        self.assertIn('Get-CommandResultField -Result $viewResult -Name "stdout"', body)
        self.assertIn('Get-CommandResultField -Result $viewResult -Name "stderr"', body)
        self.assertIn("Convert-CommandStdoutToString -Stdout $stdoutValue", body)
        self.assertIn("Convert-HostWorkloadKubeconfigJson -Json $stdoutText", body)

    def test_launcher_prefers_existing_managed_kubeconfig_and_context(self) -> None:
        test_root = REPOSITORY_ROOT / ".devdeploy" / "local" / "test-temp"
        test_root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=test_root, prefix="managed kubeconfig ") as tmpdir:
            managed_path = Path(tmpdir) / "observability-workload-kubeconfig.yaml"
            managed_path.write_text("{}", encoding="utf-8")

            selection = self.run_launcher_managed_selection(managed_path)

        self.assertEqual(Path(selection["kubeconfig_path"]), managed_path)
        self.assertEqual(selection["context"], "devdeploy-workload-observability")
        self.assertEqual(selection["source"], "launcher_managed_observability_kubeconfig")

    def test_launcher_passes_windows_kubeconfig_path_as_single_argument(self) -> None:
        body = self.launcher_function_body("Get-HostWorkloadKubeconfigCluster")

        self.assertIn('$args += @("--kubeconfig", [string]$selection["kubeconfig_path"])', body)
        self.assertNotIn('"--kubeconfig {0}"', body)
        self.assertNotIn("Invoke-Expression", body)
        self.assertNotIn("cmd /c", body)

    def test_launcher_runtime_path_resolution_supports_spaces_and_windows_paths(self) -> None:
        body = self.launcher_function_body("Resolve-LauncherRuntimePath")

        self.assertIn("[System.IO.Path]::IsPathRooted", body)
        self.assertIn("Join-Path $RepoRoot", body)
        self.assertNotIn("-split", body)
        self.assertNotIn(".Split(", body)

    def test_launcher_accepts_crlf_json_output_for_kubeconfig_parsing(self) -> None:
        stdout_body = self.launcher_function_body("Convert-CommandStdoutToString")
        parser_body = self.launcher_function_body("Convert-HostWorkloadKubeconfigJson")

        self.assertIn('join "`n"', stdout_body)
        self.assertIn("TrimStart([char]0xFEFF).Trim()", stdout_body)
        self.assertIn("$parsed = $Json | ConvertFrom-Json", parser_body)
        self.assertIn('$result["server"] = $server', parser_body)
        self.assertIn('$result["certificate_authority_data"] = $caData', parser_body)

    def test_launcher_command_helper_return_shape_is_accessed_explicitly(self) -> None:
        helper_body = self.launcher_function_body("Invoke-ReadOnlyCommand")
        field_body = self.launcher_function_body("Get-CommandResultField")
        resolver_body = self.launcher_function_body("Get-HostWorkloadKubeconfigCluster")

        for field in ("exit_code", "timed_out", "stdout", "stderr"):
            self.assertIn(field, helper_body)
            self.assertIn(f'-Name "{field}"', resolver_body)
        self.assertIn("System.Collections.IDictionary", field_body)
        self.assertIn("Result[$Name]", field_body)

    def test_launcher_stderr_warning_does_not_corrupt_valid_stdout_json(self) -> None:
        body = self.launcher_function_body("Get-HostWorkloadKubeconfigCluster")

        self.assertIn("Convert-HostWorkloadKubeconfigJson -Json $stdoutText", body)
        self.assertNotIn("$stderrValue | ConvertFrom-Json", body)
        self.assertNotIn("$stdoutText + $stderrValue", body)
        self.assertIn('kubectl_error"] = if ($exitCode -ne 0 -or $timedOut)', body)

    def test_launcher_reports_malformed_json_and_missing_fields_safely(self) -> None:
        body = self.launcher_function_body("Get-HostWorkloadKubeconfigCluster")
        parser_body = self.launcher_function_body("Convert-HostWorkloadKubeconfigJson")
        diagnostic_body = self.launcher_function_body("Write-HostWorkloadKubeconfigDiagnostic")

        self.assertIn('"malformed_json"', parser_body)
        self.assertIn('"missing_clusters_property"', parser_body)
        self.assertIn('"empty_clusters"', parser_body)
        self.assertIn('"missing_cluster_property"', parser_body)
        self.assertIn('"missing_server"', parser_body)
        self.assertIn('"missing_ca"', parser_body)
        self.assertIn('Write-HostWorkloadKubeconfigDiagnostic -Category ([string]$parsedCluster["error_category"])', body)
        self.assertIn("server_found", diagnostic_body)
        self.assertIn("ca_found", diagnostic_body)
        self.assertNotIn("stdoutText", diagnostic_body)
        self.assertNotIn("stderrValue", diagnostic_body)
        self.assertNotIn("certificate-authority-data", diagnostic_body)

    def test_powershell_parser_accepts_pscustomobject_cluster_array_shape(self) -> None:
        result = self.run_launcher_kubeconfig_parser(
            {
                "clusters": [
                    {
                        "name": "kind-devdeploy-workload",
                        "cluster": {
                            "server": "https://127.0.0.1:58081",
                            "certificate-authority-data": "ca-data",
                        },
                    }
                ]
            }
        )

        self.assertTrue(result["ok"])
        self.assertEqual(result["server"], "https://127.0.0.1:58081")
        self.assertEqual(result["certificate_authority_data"], "ca-data")
        self.assertTrue(result["server_found"])
        self.assertTrue(result["certificate_authority_found"])

    def test_powershell_parser_accepts_single_cluster_object_shape(self) -> None:
        result = self.run_launcher_kubeconfig_parser(
            {
                "clusters": {
                    "name": "kind-devdeploy-workload",
                    "cluster": {
                        "server": "https://127.0.0.1:58081",
                        "certificate-authority-data": "ca-data",
                    },
                }
            }
        )

        self.assertTrue(result["ok"])
        self.assertEqual(result["server"], "https://127.0.0.1:58081")
        self.assertEqual(result["certificate_authority_data"], "ca-data")

    def test_powershell_parser_fails_missing_clusters_property_safely(self) -> None:
        result = self.run_launcher_kubeconfig_parser({"contexts": []})

        self.assertFalse(result["ok"])
        self.assertEqual(result["error_category"], "missing_clusters_property")

    def test_powershell_parser_fails_empty_clusters_safely(self) -> None:
        result = self.run_launcher_kubeconfig_parser({"clusters": []})

        self.assertFalse(result["ok"])
        self.assertEqual(result["error_category"], "empty_clusters")

    def test_powershell_parser_fails_missing_nested_cluster_safely(self) -> None:
        result = self.run_launcher_kubeconfig_parser({"clusters": [{"name": "kind-devdeploy-workload"}]})

        self.assertFalse(result["ok"])
        self.assertEqual(result["error_category"], "missing_cluster_property")

    def test_powershell_parser_fails_missing_server_safely(self) -> None:
        result = self.run_launcher_kubeconfig_parser(
            {"clusters": [{"cluster": {"certificate-authority-data": "ca-data"}}]}
        )

        self.assertFalse(result["ok"])
        self.assertEqual(result["error_category"], "missing_server")
        self.assertFalse(result["server_found"])
        self.assertTrue(result["certificate_authority_found"])

    def test_powershell_parser_fails_missing_ca_safely(self) -> None:
        result = self.run_launcher_kubeconfig_parser(
            {"clusters": [{"cluster": {"server": "https://127.0.0.1:58081"}}]}
        )

        self.assertFalse(result["ok"])
        self.assertEqual(result["error_category"], "missing_ca")
        self.assertTrue(result["server_found"])
        self.assertFalse(result["certificate_authority_found"])

    def test_launcher_writes_separate_local_and_incluster_observability_kubeconfigs(self) -> None:
        body = self.launcher_function_body("Invoke-EnsureManagementBackendWorkloadKubeconfigSecret")

        self.assertIn("$localKubeconfig", body)
        self.assertIn("$backendKubeconfig", body)
        self.assertIn('server = [string]$hostCluster["server"]', body)
        self.assertIn("server = $ExpectedWorkloadArgoCDEndpoint", body)
        self.assertIn("Set-ContentAtomicUtf8 -Path $ObservabilityLocalKubeconfigPath -Value $localKubeconfigJson", body)
        self.assertIn("kubeconfig = $backendKubeconfigJson", body)
        self.assertIn("$ObservabilityReaderServiceAccountName", body)
        self.assertIn("normal_workload_kubeconfig_modified = $false", body)
        self.assertIn('token = $readerToken', body)

    def test_launcher_preserves_normal_workload_credentials(self) -> None:
        body = self.launcher_function_body("Set-LauncherManagedObservabilityBackendEnv")

        self.assertNotIn(
            'Set-LauncherManagedBackendEnvValue -Key "DEVDEPLOY_WORKLOAD_KUBECONFIG"',
            body,
        )
        self.assertNotIn(
            'Set-LauncherManagedBackendEnvValue -Key "DEVDEPLOY_WORKLOAD_KUBECONFIG_CONTEXT"',
            body,
        )
        self.assertIn("normal_workload_kubeconfig_modified = $false", body)

    def test_launcher_local_kubeconfig_does_not_hardcode_internal_endpoint_or_port(self) -> None:
        body = self.launcher_function_body("Invoke-EnsureManagementBackendWorkloadKubeconfigSecret")
        local_start = body.index("$localKubeconfig =")
        backend_start = body.index("$backendKubeconfig =")
        local_block = body[local_start:backend_start]

        self.assertNotIn("devdeploy-workload-control-plane", local_block)
        self.assertNotIn("58081", local_block)
        self.assertIn('[string]$hostCluster["certificate_authority_data"]', local_block)
        self.assertNotIn("insecure-skip-tls-verify", local_block)

    def test_launcher_rerun_rewrites_managed_local_kubeconfig_idempotently(self) -> None:
        body = self.launcher_function_body("Invoke-EnsureManagementBackendWorkloadKubeconfigSecret")

        self.assertIn("Set-ContentAtomicUtf8 -Path $ObservabilityLocalKubeconfigPath", body)
        self.assertNotIn("Add-Content -LiteralPath $ObservabilityLocalKubeconfigPath", body)
        self.assertIn('endpoint_source = [string]$hostCluster["source"]', body)

    def test_launcher_uses_atomic_replace_and_does_not_overwrite_on_failed_resolution(self) -> None:
        atomic_body = self.launcher_function_body("Set-ContentAtomicUtf8")
        generation_body = self.launcher_function_body("Invoke-EnsureManagementBackendWorkloadKubeconfigSecret")

        self.assertIn("Set-Content -LiteralPath $temporaryPath", atomic_body)
        self.assertIn("Move-Item -LiteralPath $temporaryPath -Destination $Path -Force", atomic_body)
        self.assertIn("Set-ContentAtomicUtf8 -Path $ObservabilityLocalKubeconfigPath", generation_body)
        failure_index = generation_body.index('if (-not [bool]$hostCluster["ok"])')
        write_index = generation_body.index("Set-ContentAtomicUtf8 -Path $ObservabilityLocalKubeconfigPath")
        self.assertLess(failure_index, write_index)
        self.assertIn("return $result", generation_body[failure_index:write_index])


if __name__ == "__main__":
    unittest.main()
