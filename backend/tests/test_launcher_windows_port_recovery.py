import json
import re
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
LAUNCHER = REPO_ROOT / "scripts" / "launcher" / "devdeploy-launcher.ps1"
DOCS = REPO_ROOT / "docs" / "operations" / "devdeploy-launcher.md"


class LauncherWindowsPortRecoveryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.script = LAUNCHER.read_text(encoding="utf-8")
        cls.docs = DOCS.read_text(encoding="utf-8")

    def function_body(self, name: str) -> str:
        marker = f"function {name} {{"
        start = self.script.index(marker)
        next_function = self.script.find("\nfunction ", start + len(marker))
        if next_function == -1:
            return self.script[start:]
        return self.script[start:next_function]

    def run_port_safety(
        self,
        *,
        port: int,
        owner: str,
        expected_container: str,
        excluded: bool = False,
    ) -> dict:
        ranges = "@([ordered]@{ start = %d; end = %d })" % (port, port) if excluded else "@()"
        script = "\n".join(
            (
                self.function_body("Test-PortInExcludedRanges"),
                "function Test-HostPortBindAvailable { param([int]$Port) return [ordered]@{ available = $false; error = 'already bound' } }",
                self.function_body("Test-HostPortSafety"),
                f"$owners = @([ordered]@{{ host_port = {port}; container_port = 443; container_name = '{owner}' }})",
                (
                    f"Test-HostPortSafety -Port {port} -ExcludedRanges {ranges} "
                    f"-DockerPortOwnership $owners -ExpectedControlPlaneContainer '{expected_container}' "
                    "-AllowExpectedContainerOwnership $true | ConvertTo-Json -Compress -Depth 8"
                ),
            )
        )
        result = subprocess.run(
            ["powershell", "-NoProfile", "-NonInteractive", "-Command", script],
            check=True,
            capture_output=True,
            text=True,
        )
        return json.loads(result.stdout.strip().splitlines()[-1])

    def run_check_reconciliation(self) -> dict:
        script = "\n".join(
            (
                "function Get-Timestamp { return [DateTime]::UtcNow.ToString('o') }",
                "function Write-LauncherLog { param([string]$Message) }",
                self.function_body("Set-CheckResult"),
                self.function_body("Get-NamedObjectValue"),
                self.function_body("ConvertTo-PlainHostPublicationDetails"),
                self.function_body("New-ManagementIntegrityCheckDetails"),
                "$Checks = New-Object System.Collections.Generic.List[object]",
                "$Checks.Add([ordered]@{ id = 'kind_integrity_devdeploy-mgmt'; status = 'warning'; message = 'old'; details = @{}; checked_at = 'old' }) | Out-Null",
                "$publications = @([pscustomobject]@{ container_port = 443; expected_host_port = 9443; configured_host_port = 9443; published_host_port = 9443; docker_port_host_port = 9443; configured = $true; published = $true; publication_consistent = $true; healthy = $true }, [ordered]@{ container_port = 80; expected_host_port = 8080; configured_host_port = $null; published_host_port = $null; docker_port_host_port = $null; configured = $false; published = $false; publication_consistent = $false; healthy = $false })",
                "$details = New-ManagementIntegrityCheckDetails -Required $true -IntegrityStatus 'ok' -InternalClusterReady $null -HostAccessHealthy $true -RecreationRequired $false -RequiredHostPublications $publications",
                "$updated = Set-CheckResult -Id 'kind_integrity_devdeploy-mgmt' -Status 'ok' -Message 'healthy' -Details $details",
                "$stored = $Checks[0]['details']",
                "[pscustomobject]@{ updated = $updated; check_status = $Checks[0]['status']; check_message = $Checks[0]['message']; details_type = $stored.GetType().FullName; publications_type = $stored['required_host_publications'].GetType().FullName; publication_count = @($stored['required_host_publications']).Count; first_type = $stored['required_host_publications'][0].GetType().FullName; second_configured_port_is_null = $null -eq $stored['required_host_publications'][1]['configured_host_port']; internal_ready_is_null = $null -eq $stored['internal_cluster_ready']; recreation_required = $stored['recreation_required'] } | ConvertTo-Json -Compress -Depth 8",
            )
        )
        result = subprocess.run(
            ["powershell", "-NoProfile", "-NonInteractive", "-Command", script],
            check=True,
            capture_output=True,
            text=True,
        )
        return json.loads(result.stdout.strip().splitlines()[-1])

    def run_ensure_secret_dispatch(self, scenario: str) -> tuple[subprocess.CompletedProcess[str], dict, bool, int]:
        main_marker = "New-LocalDirectory -Path $StatusDir"
        injection = r'''
$script:MockScenario = $env:DEVDEPLOY_TEST_SCENARIO
$script:MockSecretApplied = $false
$script:MockManagementSnapshotCalls = 0
$script:OriginalManagementSnapshot = ${function:New-ManagementClusterStatusSnapshot}

function New-ManagementClusterStatusSnapshot {
    param([bool]$KindAvailable, [bool]$KubectlAvailable)
    $script:MockManagementSnapshotCalls++
    return & $script:OriginalManagementSnapshot -KindAvailable $KindAvailable -KubectlAvailable $KubectlAvailable
}

function Test-CommandAvailable {
    param([string]$Name, [string]$Label, [bool]$Required)
    Add-Check -Id ("tool_{0}" -f $Name) -Label $Label -Status "ok" -Message ("{0} is available in the test harness." -f $Label) -Details @{ required = $Required }
    return $true
}

function Test-DockerDaemon {
    param([bool]$DockerCliAvailable)
    Add-Check -Id "docker_daemon" -Label "Docker daemon" -Status "ok" -Message "Docker daemon is reachable in the test harness." -Details @{ required = $true }
    return $true
}

function Get-KindClusterNames {
    param([bool]$KindAvailable)
    return [ordered]@{ success = $true; clusters = @("devdeploy-mgmt", "devdeploy-workload"); error = "" }
}

function Get-WindowsExcludedTcpPortRanges {
    if ($script:MockScenario -eq "excluded") {
        return @([ordered]@{ start = 8443; end = 8443 })
    }
    return @()
}

function Get-DockerPublishedPortOwnership {
    param([bool]$DockerAvailable, [bool]$DockerDaemonReachable)
    $ports = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @(@(58080, 6443), @(8080, 80))) {
        $ports.Add([ordered]@{ host_port = [int]$entry[0]; container_port = [int]$entry[1]; container_name = "devdeploy-mgmt-control-plane" }) | Out-Null
    }
    if ($script:MockScenario -eq "healthy") {
        $ports.Add([ordered]@{ host_port = 9443; container_port = 443; container_name = "devdeploy-mgmt-control-plane" }) | Out-Null
    }
    elseif ($script:MockScenario -eq "excluded") {
        $ports.Add([ordered]@{ host_port = 8443; container_port = 443; container_name = "devdeploy-mgmt-control-plane" }) | Out-Null
    }
    return @($ports | ForEach-Object { $_ })
}

function Get-DockerContainerPortBindingState {
    param([string]$ContainerName, [int]$ContainerPort, [bool]$DockerAvailable, [bool]$DockerDaemonReachable)
    $hostPort = $null
    if ($ContainerName -eq "devdeploy-mgmt-control-plane") {
        if ($ContainerPort -eq 6443) { $hostPort = 58080 }
        elseif ($ContainerPort -eq 80) { $hostPort = 8080 }
        elseif ($ContainerPort -eq 443 -and $script:MockScenario -eq "healthy") { $hostPort = 9443 }
        elseif ($ContainerPort -eq 443 -and $script:MockScenario -eq "excluded") { $hostPort = 8443 }
    }
    $present = $null -ne $hostPort
    return [ordered]@{
        container_port = $ContainerPort
        configured_host_port = $hostPort
        published_host_port = $hostPort
        docker_port_host_port = $hostPort
        configured = $present
        published = $present
        docker_port_reported = $present
        publication_consistent = $present
        inspect_succeeded = $true
    }
}

function Test-HostPortBindAvailable {
    param([int]$Port)
    $published = @((Get-DockerPublishedPortOwnership -DockerAvailable $true -DockerDaemonReachable $true) | ForEach-Object { [int]$_['host_port'] })
    return [ordered]@{ available = [bool]($published -notcontains $Port); error = "" }
}

function Get-KindClusterIntegrity {
    param([string]$ClusterName, [string]$Context, [string]$ControlPlaneContainer, [int]$ExpectedApiPort, [bool]$ClusterExists, [bool]$KubectlAvailable, [bool]$Required)
    $result = [ordered]@{
        cluster_name = $ClusterName; context = $Context; control_plane_container = $ControlPlaneContainer
        container_running = $true; api_port_published = $true; expected_api_port = $ExpectedApiPort
        actual_api_port = $ExpectedApiPort; restart_policy_name = "unless-stopped"
        restart_policy_maximum_retry_count = 0; restart_policy_healthy = $true
        restart_policy_reconciliation_needed = $false; kubeconfig_reachable = $true
        integrity_status = "ok"; message = "Mocked kind integrity is healthy."
        recommended_action = ""; checked_at = [string](Get-Timestamp)
    }
    Add-Check -Id ("kind_integrity_{0}" -f $ClusterName) -Label ("{0} kind integrity" -f $ClusterName) -Status "ok" -Message ([string]$result['message']) -Details @{ required = $Required; integrity_status = "ok" }
    return $result
}

function Get-KindContainerInternalReadiness {
    param([string]$ControlPlaneContainer, [bool]$DockerAvailable, [bool]$DockerDaemonReachable, [bool]$ContainerRunning)
    return [ordered]@{ internal_cluster_ready = $true; ready_nodes = 1; total_nodes = 1; message = "Mocked internal readiness is healthy." }
}

function New-WorkloadClusterStatus {
    param([bool]$KindAvailable, [bool]$KubectlAvailable)
    Add-Check -Id "workload_cluster_recreation_required" -Label "Workload cluster recovery" -Status "warning" -Message "Mocked workload degradation remains non-blocking." -Details @{ required = $false; recreation_required = $true }
    return [ordered]@{ name = "devdeploy-workload"; context = "kind-devdeploy-workload"; exists = $true; status = "degraded"; integrity_status = "workload_cluster_recreation_required"; message = "Mocked workload degradation remains non-blocking."; checked_at = [string](Get-Timestamp) }
}

function Test-LocalPortAvailable { param([int]$Port, [bool]$Required, [bool]$AllowBusyAsOk, [string]$ExpectedCluster, [bool]$ExistingClusterDetected) }
function Test-KindClusters { param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Remaining) }
function Test-KubectlContext { param([bool]$KubectlAvailable) }

function Invoke-ReadOnlyCommand {
    param([string]$FileName, [string[]]$Arguments, [int]$TimeoutSeconds, [bool]$PreserveStandardOutput)
    $joined = [string]($Arguments -join " ")
    if ($joined -match "get nodes") { return [ordered]@{ exit_code = 0; timed_out = $false; stdout = "devdeploy-mgmt-control-plane Ready control-plane 1d v1"; stderr = "" } }
    if ($joined -match "get namespace devdeploy") { return [ordered]@{ exit_code = 0; timed_out = $false; stdout = "namespace/devdeploy"; stderr = "" } }
    if ($joined -match "get secret --selector") { return [ordered]@{ exit_code = 0; timed_out = $false; stdout = "secret/devdeploy-postgresql"; stderr = "" } }
    if ($joined -match "get secret devdeploy-backend-secret" -and -not $script:MockSecretApplied) { return [ordered]@{ exit_code = 1; timed_out = $false; stdout = ""; stderr = "not found" } }
    return [ordered]@{ exit_code = 0; timed_out = $false; stdout = ""; stderr = "" }
}

function Get-SecretKeyNames {
    param([string]$SecretName)
    if ($SecretName -eq "devdeploy-backend-secret") {
        return [ordered]@{ success = $true; keys = @("DATABASE_URL", "JWT_SECRET_KEY", "GITHUB_WORKFLOW_TOKEN"); error = "" }
    }
    return [ordered]@{ success = $true; keys = @("password"); error = "" }
}

function Get-DecodedSecretValue {
    param([string]$SecretName, [string]$Key)
    if ($SecretName -ne "devdeploy-backend-secret") { return [ordered]@{ success = $true; value = "mock-postgres-value"; error = "" } }
    if ($Key -eq "DATABASE_URL") { return [ordered]@{ success = $true; value = "postgresql://devdeploy:mock@devdeploy-postgres-postgresql.devdeploy.svc.cluster.local:5432/devdeploy"; error = "" } }
    if ($Key -eq "JWT_SECRET_KEY") { return [ordered]@{ success = $true; value = "mock-jwt-value-with-at-least-thirty-two-characters"; error = "" } }
    return [ordered]@{ success = $true; value = ""; error = "" }
}

function Invoke-SanitizedInputCommand {
    param([string]$FileName, [string[]]$Arguments, [string]$StandardInput, [int]$TimeoutSeconds)
    $script:MockSecretApplied = $true
    Set-Content -LiteralPath (Join-Path $RepoRoot "mock-secret-applied.txt") -Value ([string]$script:MockManagementSnapshotCalls) -Encoding ASCII
    return [ordered]@{ exit_code = 0; timed_out = $false; stdout = "secret/devdeploy-backend-secret configured"; stderr = "" }
}
'''
        with tempfile.TemporaryDirectory() as temporary_directory:
            repo_root = Path(temporary_directory) / "repo with spaces"
            launcher_directory = repo_root / "scripts" / "launcher"
            launcher_directory.mkdir(parents=True)
            test_launcher = launcher_directory / "devdeploy-launcher.ps1"
            test_launcher.write_text(self.script.replace(main_marker, injection + "\n" + main_marker, 1), encoding="utf-8")

            environment = {**dict(__import__("os").environ), "DEVDEPLOY_TEST_SCENARIO": scenario}
            result = subprocess.run(
                ["powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(test_launcher), "-EnsureManagementBackendSecret", "-Quiet"],
                cwd=repo_root,
                capture_output=True,
                text=True,
                env=environment,
            )
            status_path = repo_root / ".devdeploy" / "local" / "status" / "launcher-status.json"
            status = json.loads(status_path.read_text(encoding="utf-8-sig"))
            marker = repo_root / "mock-secret-applied.txt"
            snapshot_count = int(marker.read_text(encoding="ascii").strip()) if marker.exists() else 0
            return result, status, marker.exists(), snapshot_count

    def test_management_and_workload_https_use_deterministic_candidate_lists(self) -> None:
        self.assertIn("$ManagementHttpsCandidatePorts = @(8443, 9443, 10443", self.script)
        self.assertIn("$WorkloadHttpsCandidatePorts = @(8444, 9444, 10444", self.script)
        self.assertIn("deterministic_safe_fallback", self.script)
        self.assertIn("no_safe_candidate", self.script)

        for variable in ("ManagementHttpsCandidatePorts", "WorkloadHttpsCandidatePorts"):
            match = re.search(rf"\${variable} = @\(([^)]+)\)", self.script)
            self.assertIsNotNone(match)
            candidates = [int(value.strip()) for value in match.group(1).split(",")]
            self.assertEqual(candidates, list(dict.fromkeys(candidates)))

    def test_candidate_evaluation_is_unique_and_deterministic(self) -> None:
        body = self.function_body("Resolve-HttpsPortSelection")

        self.assertIn("Select-Object -Unique", body)
        self.assertIn("$evaluatedPorts", body)
        self.assertIn("if (@($evaluatedPorts) -contains [int]$candidate)", body)
        self.assertIn("continue", body)

    def test_windows_excluded_port_ranges_are_rejected(self) -> None:
        body = self.function_body("Get-WindowsExcludedTcpPortRanges")
        safety = self.function_body("Test-HostPortSafety")

        self.assertIn("netsh", body)
        self.assertIn("excludedportrange", body)
        self.assertIn("protocol=tcp", body)
        self.assertIn("excluded_by_windows", safety)
        self.assertIn("-not $excluded", safety)

    def test_bind_listeners_and_docker_published_ports_are_rejected(self) -> None:
        bind_body = self.function_body("Test-HostPortBindAvailable")
        docker_body = self.function_body("Get-DockerPublishedPortOwnership")
        safety = self.function_body("Test-HostPortSafety")

        self.assertIn("System.Net.Sockets.TcpListener", bind_body)
        self.assertIn('"docker"', docker_body)
        self.assertIn('"ps", "--format", "{{.Names}}|{{.Ports}}"', docker_body)
        self.assertIn("docker_published", safety)
        self.assertIn("docker_port_owner", safety)
        self.assertIn("bind_available", safety)
        self.assertIn("collides_with_devdeploy_port", safety)
        self.assertIn("$expectedOwnershipAccepted", safety)

    def test_expected_management_container_owns_9443_and_is_preserved(self) -> None:
        result = self.run_port_safety(
            port=9443,
            owner="devdeploy-mgmt-control-plane",
            expected_container="devdeploy-mgmt-control-plane",
        )

        self.assertTrue(result["safe"])
        self.assertTrue(result["docker_published"])
        self.assertFalse(result["bind_available"])
        self.assertEqual(result["docker_port_owner"], "devdeploy-mgmt-control-plane")
        self.assertTrue(result["owned_by_expected_cluster"])

    def test_expected_workload_container_owns_9444_and_is_preserved(self) -> None:
        result = self.run_port_safety(
            port=9444,
            owner="devdeploy-workload-control-plane",
            expected_container="devdeploy-workload-control-plane",
        )

        self.assertTrue(result["safe"])
        self.assertFalse(result["bind_available"])
        self.assertTrue(result["owned_by_expected_cluster"])

    def test_unrelated_container_ownership_is_rejected(self) -> None:
        result = self.run_port_safety(
            port=9443,
            owner="unrelated-container",
            expected_container="devdeploy-mgmt-control-plane",
        )

        self.assertFalse(result["safe"])
        self.assertTrue(result["owned_by_unrelated_container"])
        self.assertFalse(result["owned_by_expected_cluster"])

    def test_other_devdeploy_cluster_ownership_is_rejected(self) -> None:
        result = self.run_port_safety(
            port=9443,
            owner="devdeploy-workload-control-plane",
            expected_container="devdeploy-mgmt-control-plane",
        )

        self.assertFalse(result["safe"])
        self.assertTrue(result["owned_by_other_devdeploy_cluster"])
        self.assertFalse(result["owned_by_expected_cluster"])

    def test_expected_owner_does_not_override_windows_exclusion(self) -> None:
        result = self.run_port_safety(
            port=8443,
            owner="devdeploy-mgmt-control-plane",
            expected_container="devdeploy-mgmt-control-plane",
            excluded=True,
        )

        self.assertFalse(result["safe"])
        self.assertTrue(result["excluded_by_windows"])

    def test_kind_config_generation_uses_selected_https_ports(self) -> None:
        management_create = re.search(
            r'if \(\$CreateManagementCluster\) \{\s+Write-KindConfigPreview -Id "management_kind_config"(?P<body>[\s\S]+?)\n\}',
            self.script,
        )
        create_branch = re.search(
            r'elseif \(\$CreateWorkloadCluster\) \{\s+Write-KindConfigPreview -Id "workload_kind_config"(?P<body>[\s\S]+?)\n\}',
            self.script,
        )
        preview_branch = re.search(
            r'elseif \(\$GenerateKindConfigs\) \{\s+Write-KindConfigPreview -Id "kind_config_mgmt_preview"(?P<body>[\s\S]+?)\n\}',
            self.script,
        )
        self.assertIsNotNone(management_create)
        self.assertIsNotNone(create_branch)
        self.assertIsNotNone(preview_branch)
        self.assertIn('[int]$PortPlan["management_https"]', management_create.group("body"))
        self.assertIn('[int]$PortPlan["workload_https"]', create_branch.group("body"))
        self.assertIn('[int]$PortPlan["management_https"]', preview_branch.group("body"))
        self.assertIn('[int]$PortPlan["workload_https"]', preview_branch.group("body"))
        self.assertNotIn("-HttpsHostPort 8443", management_create.group("body"))
        self.assertNotIn("-HttpsHostPort 8444", create_branch.group("body"))
        self.assertNotIn("-HttpsHostPort 8443", preview_branch.group("body"))
        self.assertNotIn("-HttpsHostPort 8444", preview_branch.group("body"))

    def test_selected_ports_are_persisted_in_status_contract(self) -> None:
        self.assertIn("port_selection   = $PortSelection", self.script)
        self.assertIn("ports            = $PortPlan", self.script)
        self.assertIn("selected_port", self.script)
        self.assertIn("selection_reason", self.script)
        self.assertIn("management_https = $managementSelection", self.script)
        self.assertIn("workload_https   = $workloadSelection", self.script)

    def test_existing_cluster_published_port_uses_actual_network_publication(self) -> None:
        binding = self.function_body("Get-DockerContainerPortBindingState")
        selection = self.function_body("Resolve-HttpsPortSelection")

        self.assertIn(".HostConfig.PortBindings", binding)
        self.assertIn(".NetworkSettings.Ports", binding)
        self.assertIn('-FileName "docker" -Arguments @("port"', binding)
        self.assertIn('publication_consistent', binding)
        self.assertIn('$existingBindingState["published_host_port"]', selection)
        self.assertIn('existing_cluster_published_port', selection)
        self.assertIn('existing_cluster_binding', selection)

    def test_read_only_docker_metadata_does_not_trust_stale_daemon_probe(self) -> None:
        for name in (
            "Get-DockerPublishedPortOwnership",
            "Get-DockerContainerPortBindingState",
            "Get-DockerContainerRestartPolicy",
            "Get-KindContainerInternalReadiness",
        ):
            body = self.function_body(name)
            self.assertNotIn("-not $DockerAvailable -or -not $DockerDaemonReachable", body)

    def test_selected_management_and_workload_ports_never_collide(self) -> None:
        body = self.function_body("Resolve-LauncherPortPlan")

        self.assertIn('$reservedPorts.Add([int]$PortPlan["management_https"])', body)
        self.assertIn("-ReservedDevDeployPorts", body)
        self.assertIn("ManagementHttpsCandidatePorts", body)
        self.assertIn("WorkloadHttpsCandidatePorts", body)

    def test_stopped_unusable_workload_binding_is_reported_explicitly(self) -> None:
        body = self.function_body("Get-WorkloadClusterRecreationRequirement")
        generic_body = self.function_body("Get-ClusterHttpsPortRecreationRequirement")
        status_body = self.function_body("New-WorkloadClusterStatus")

        self.assertIn('"devdeploy-workload-control-plane"', body)
        self.assertIn("foreach ($containerPort in @(6443, 80, 443))", generic_body)
        self.assertIn("-ContainerPort $containerPort", generic_body)
        self.assertIn("missingHostPublications", generic_body)
        self.assertIn("bindingUnsafe", generic_body)
        self.assertIn("workload_cluster_recreation_required", generic_body)
        self.assertIn("management_cluster_targeted = $false", status_body)

    def test_internally_ready_management_with_missing_publications_requires_recreation(self) -> None:
        diagnosis = self.function_body("Get-ClusterHttpsPortRecreationRequirement")
        status = self.function_body("New-ManagementClusterStatusSnapshot")

        self.assertIn(".HostConfig.PortBindings", self.script)
        self.assertIn(".NetworkSettings.Ports", self.script)
        self.assertIn('$missingHostPublications.Count -gt 0', diagnosis)
        self.assertIn('$bindingUnsafe -or $publicationMismatch -or $missingHostPublications.Count -gt 0', diagnosis)
        self.assertNotIn('$containerStopped -and', diagnosis)
        self.assertIn('"missing_host_publication"', diagnosis)
        self.assertIn('internal_cluster_ready', status)
        self.assertIn('host_access_healthy', status)
        self.assertIn('recreation_required', status)

    def test_internally_ready_management_with_excluded_https_requires_recreation(self) -> None:
        diagnosis = self.function_body("Get-ClusterHttpsPortRecreationRequirement")
        status = self.function_body("New-ManagementClusterStatusSnapshot")

        self.assertIn('$safety["excluded_by_windows"]', diagnosis)
        self.assertIn('"unusable_immutable_host_binding"', diagnosis)
        self.assertIn('management_cluster_recreation_required', status)
        self.assertIn('may be internally Ready', status)

    def test_healthy_internal_state_and_host_bindings_do_not_require_recreation(self) -> None:
        diagnosis = self.function_body("Get-ClusterHttpsPortRecreationRequirement")
        status = self.function_body("New-ManagementClusterStatusSnapshot")

        self.assertIn('$httpsPublished', diagnosis)
        self.assertIn('-not $httpsPublished', diagnosis)
        self.assertIn('host_access_healthy', diagnosis)
        self.assertIn('-not $recreationRequired', diagnosis)
        self.assertIn('Set-CheckResult -Id "kind_integrity_devdeploy-mgmt"', status)
        self.assertIn('management_cluster_recreation_required', status)

    def test_check_reconciliation_is_windows_powershell_compatible(self) -> None:
        result = self.run_check_reconciliation()

        self.assertTrue(result["updated"])
        self.assertEqual(result["check_status"], "ok")
        self.assertEqual(result["check_message"], "healthy")
        self.assertEqual(result["details_type"], "System.Collections.Hashtable")
        self.assertEqual(result["publication_count"], 2)
        self.assertEqual(result["first_type"], "System.Collections.Hashtable")
        self.assertTrue(result["second_configured_port_is_null"])
        self.assertTrue(result["internal_ready_is_null"])
        self.assertFalse(result["recreation_required"])

    def test_set_check_result_avoids_generic_list_array_coercion(self) -> None:
        body = self.function_body("Set-CheckResult")

        self.assertNotIn("@($Checks)", body)
        self.assertIn("$checkIndex -lt $Checks.Count", body)
        self.assertIn("$check = $Checks[$checkIndex]", body)

    def test_internal_readiness_probe_is_read_only(self) -> None:
        body = self.function_body("Get-KindContainerInternalReadiness")

        self.assertIn('"docker"', body)
        self.assertIn('@("exec", $ControlPlaneContainer, "kubectl", "get", "nodes", "--no-headers")', body)
        for forbidden in ('"apply"', '"delete"', '"create"', '"patch"', '"update"'):
            self.assertNotIn(forbidden, body)

    def test_recovery_is_explicit_plan_only_and_never_targets_management(self) -> None:
        self.assertIn("[switch]$PlanWorkloadPortRecovery", self.script)
        self.assertIn("workload_port_recovery_plan", self.script)
        self.assertIn("destructive_commands_executed   = $false", self.script)
        self.assertIn("management_preserved            = $true", self.script)
        self.assertIn("kind delete cluster --name devdeploy-workload", self.script)
        self.assertNotIn("kind delete cluster --name devdeploy-mgmt", self.script)

    def test_management_recovery_plan_is_read_only_and_requires_backup_verification(self) -> None:
        self.assertIn("[switch]$PlanManagementPortRecovery", self.script)
        self.assertIn("management_port_recovery_plan", self.script)
        body = self.function_body("New-ManagementPortRecoveryPlan")

        self.assertIn("destructive_commands_executed   = $false", body)
        self.assertIn("automatic_recreation_available  = $false", body)
        self.assertIn("backup_verification_required    = $true", body)
        self.assertIn("selected_management_https_port", body)
        self.assertIn("verified PostgreSQL backup", body)
        self.assertIn("internal_cluster_ready", body)
        self.assertIn("host_access_healthy", body)
        self.assertIn("recreation_required", body)
        self.assertNotIn("kind delete cluster --name devdeploy-mgmt", body)

    def test_management_recreation_is_never_automatically_executed(self) -> None:
        self.assertNotIn("Invoke-ManagementPortRecovery", self.script)
        self.assertNotIn("kind delete cluster --name devdeploy-mgmt", self.script)
        self.assertIn("no automatic management delete or recreate action exists", self.script)

    def test_recovery_plan_recreates_registration_and_observability_with_new_endpoint(self) -> None:
        self.assertIn("-DiscoverWorkloadClusterEndpoint", self.script)
        self.assertIn("-RegisterWorkloadClusterWithArgoCD", self.script)
        self.assertIn("-GrantWorkloadDeployPermissions", self.script)
        self.assertIn("-BootstrapGitOpsRootApplication", self.script)
        self.assertIn("-BootstrapWorkloadObservability", self.script)
        self.assertIn("selected_workload_https_port", self.script)

    def test_docs_explain_dynamic_workload_https_and_safe_recovery(self) -> None:
        self.assertIn("workload HTTPS host port", self.docs)
        self.assertIn("-PlanWorkloadPortRecovery", self.docs)
        self.assertIn("-PlanManagementPortRecovery", self.docs)
        self.assertIn("Windows excluded TCP port ranges", self.docs)
        self.assertIn("does not delete", self.docs)
        self.assertIn("verified PostgreSQL backup", self.docs)

    def test_dynamic_post_validation_does_not_embed_stale_fixed_https_ports(self) -> None:
        workload_plan = self.function_body("New-WorkloadRebootstrapPlan")
        management_plan = self.function_body("New-ManagementPortRecoveryPlan")

        self.assertIn('[int]$PortPlan["workload_https"]', workload_plan)
        self.assertIn('[int]$PortPlan["management_https"]', management_plan)
        self.assertNotIn("127.0.0.1:8444", workload_plan)
        self.assertNotIn("127.0.0.1:8443", management_plan)

    def test_successful_workload_cluster_creation_reconciles_only_workload_restart_policy(self) -> None:
        body = self.function_body("Invoke-WorkloadClusterCreate")

        self.assertIn("Invoke-KindRestartPolicyReconcile", body)
        self.assertIn('-ClusterName "devdeploy-workload"', body)
        self.assertIn('-ControlPlaneContainer "devdeploy-workload-control-plane"', body)
        self.assertNotIn("devdeploy-mgmt-control-plane", body)

    def test_successful_management_cluster_creation_reconciles_only_management_restart_policy(self) -> None:
        body = self.function_body("Invoke-ManagementClusterCreate")

        self.assertIn("Invoke-KindRestartPolicyReconcile", body)
        self.assertIn('-ClusterName "devdeploy-mgmt"', body)
        self.assertIn('-ControlPlaneContainer "devdeploy-mgmt-control-plane"', body)
        self.assertNotIn("devdeploy-workload-control-plane", body)

    def test_default_preflight_and_plan_only_modes_do_not_repair_restart_policy(self) -> None:
        preflight_body = re.search(
            r'\$launcherMode = "preflight"(?P<body>[\s\S]+?)\$managementCluster = \$null',
            self.script,
        )
        self.assertIsNotNone(preflight_body)
        self.assertNotIn("Invoke-DevDeployKindRestartPolicyRepair", preflight_body.group("body"))
        self.assertIn("[switch]$PlanWorkloadPortRecovery", self.script)
        self.assertNotIn("-PlanWorkloadPortRecovery) {\n    Invoke-DevDeployKindRestartPolicyRepair", self.script)

    def test_management_backend_secret_mode_uses_management_integrity_only(self) -> None:
        management_required = self.function_body("Test-ManagementClusterIntegrityRequired")
        workload_required = self.function_body("Test-WorkloadClusterIntegrityRequired")

        self.assertNotIn("$EnsureManagementBackendSecret", management_required)
        self.assertIn("$EnsureManagementBackendSecret", workload_required)
        self.assertIn("-or $EnsureManagementBackendSecret", self.script)

    def test_management_status_is_canonical_and_cached_per_launcher_run(self) -> None:
        wrapper = self.function_body("New-ManagementClusterStatus")
        snapshot = self.function_body("New-ManagementClusterStatusSnapshot")

        self.assertIn("$script:ManagementClusterStatusCache", wrapper)
        self.assertIn("New-ManagementClusterStatusSnapshot", wrapper)
        self.assertIn("selected_https_port", snapshot)
        self.assertIn("host_config_https_port", snapshot)
        self.assertIn("network_settings_https_port", snapshot)
        self.assertIn("docker_port_https_port", snapshot)
        self.assertIn("docker_port_owner", snapshot)
        self.assertIn("api_publication", snapshot)
        self.assertIn("http_publication", snapshot)
        self.assertIn("https_publication", snapshot)

    def test_real_ensure_dispatch_allows_healthy_management_with_degraded_workload(self) -> None:
        result, status, secret_applied, snapshot_count = self.run_ensure_secret_dispatch("healthy")

        self.assertEqual(result.returncode, 0, msg=result.stderr or result.stdout)
        self.assertTrue(secret_applied)
        self.assertEqual(snapshot_count, 1)
        management = status["management_cluster"]
        self.assertEqual(management["integrity_status"], "ok")
        self.assertEqual(management["selected_https_port"], 9443)
        self.assertEqual(management["host_config_https_port"], 9443)
        self.assertEqual(management["network_settings_https_port"], 9443)
        self.assertEqual(management["docker_port_https_port"], 9443)
        self.assertEqual(management["docker_port_owner"], "devdeploy-mgmt-control-plane")
        self.assertTrue(management["host_access_healthy"])
        self.assertFalse(management["recreation_required"])
        self.assertEqual(status["workload_cluster"]["status"], "degraded")
        workload_checks = [check for check in status["checks"] if check["id"] == "workload_cluster_recreation_required"]
        self.assertEqual(len(workload_checks), 1)
        self.assertEqual(workload_checks[0]["status"], "warning")
        self.assertFalse(workload_checks[0]["details"]["required"])
        self.assertFalse(any(check["id"] == "management_cluster_recreation_required" for check in status["checks"]))

    def test_real_ensure_dispatch_blocks_missing_management_publication(self) -> None:
        result, status, secret_applied, _ = self.run_ensure_secret_dispatch("missing")

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(secret_applied)
        management = status["management_cluster"]
        self.assertTrue(management["recreation_required"])
        self.assertEqual(management["recreation_reason"], "missing_host_publication")
        self.assertFalse(management["host_access_healthy"])

    def test_real_ensure_dispatch_blocks_excluded_management_binding(self) -> None:
        result, status, secret_applied, _ = self.run_ensure_secret_dispatch("excluded")

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(secret_applied)
        management = status["management_cluster"]
        self.assertTrue(management["recreation_required"])
        self.assertEqual(management["recreation_reason"], "unusable_immutable_host_binding")
        self.assertEqual(management["configured_https_port"], 8443)

    def test_ensure_dispatch_does_not_contain_cluster_lifecycle_mutation(self) -> None:
        dispatches = re.finditer(
            r'elseif \(\$EnsureManagementBackendSecret\) \{(?P<body>[\s\S]+?)\n\}',
            self.script,
        )
        dispatch = next((match for match in dispatches if "Invoke-EnsureManagementBackendSecret" in match.group("body")), None)
        self.assertIsNotNone(dispatch)
        for forbidden in ("kind delete", "kind create", "docker update", "docker stop", "docker restart"):
            self.assertNotIn(forbidden, dispatch.group("body"))

    def test_explicit_restart_policy_repair_targets_only_expected_devdeploy_containers(self) -> None:
        self.assertIn("[switch]$RepairDevDeployKindRestartPolicies", self.script)
        repair_body = self.function_body("Invoke-DevDeployKindRestartPolicyRepair")

        self.assertIn('"devdeploy-mgmt-control-plane"', repair_body)
        self.assertIn('"devdeploy-workload-control-plane"', repair_body)
        self.assertIn("ValidateSet(\"devdeploy-mgmt-control-plane\", \"devdeploy-workload-control-plane\")", self.script)
        self.assertNotIn("docker ps", repair_body)
        self.assertNotIn("ForEach-Object", repair_body)

    def test_unless_stopped_is_healthy_and_on_failure_is_reported(self) -> None:
        policy_body = self.function_body("Get-DockerContainerRestartPolicy")
        check_body = self.function_body("Add-KindRestartPolicyCheck")

        self.assertIn('$ExpectedKindRestartPolicy = "unless-stopped"', self.script)
        self.assertIn("$policyName -eq $ExpectedKindRestartPolicy", policy_body)
        self.assertIn("reconciliation_needed", policy_body)
        self.assertIn("MaximumRetryCount", policy_body)
        self.assertIn("warning", check_body)
        self.assertIn("reconcile it to unless-stopped", check_body)

    def test_docker_update_failure_fails_safely_without_cluster_delete(self) -> None:
        body = self.function_body("Invoke-KindRestartPolicyReconcile")

        self.assertIn('"docker"', body)
        self.assertIn('"update", "--restart", $ExpectedKindRestartPolicy, $ControlPlaneContainer', body)
        self.assertIn("No cluster deletion or cleanup was performed", body)
        self.assertIn("deletes_cluster         = $false", body)
        self.assertNotIn("kind delete", body)
        self.assertNotIn("docker rm", body)


if __name__ == "__main__":
    unittest.main()
