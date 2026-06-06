<#
.SYNOPSIS
  DevDeploy Hub Launcher skeleton for read-only host preflight checks.

.DESCRIPTION
  This Phase 2B launcher contract performs safe local checks and writes
  structured status for future backend/Setup Wizard integration. It does not
  create clusters, install charts, apply manifests, or deploy workloads.
#>

[CmdletBinding()]
param(
    [switch]$GenerateKindConfigs,

    [switch]$CreateManagementCluster,

    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LauncherVersion = "0.1.0"
$RequiredPorts = @(58080, 8080, 8443, 58081, 8081, 8444)
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..")).Path
$LocalRoot = Join-Path $RepoRoot ".devdeploy\local"
$StatusDir = Join-Path $LocalRoot "status"
$LogsDir = Join-Path $LocalRoot "logs"
$KindDir = Join-Path $LocalRoot "kind"
$StatusPath = Join-Path $StatusDir "launcher-status.json"
$LogPath = Join-Path $LogsDir "devdeploy-launcher.log"
$MgmtKindConfigPath = Join-Path $KindDir "devdeploy-mgmt.yaml"
$WorkloadKindConfigPath = Join-Path $KindDir "devdeploy-workload.yaml"
$Checks = New-Object System.Collections.Generic.List[object]

$PortPlan = [ordered]@{
    management_api   = 58080
    management_http  = 8080
    management_https = 8443
    workload_api     = 58081
    workload_http    = 8081
    workload_https   = 8444
}

function New-LocalDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Get-Timestamp {
    return [DateTime]::UtcNow.ToString("o", [System.Globalization.CultureInfo]::InvariantCulture)
}

function Protect-LogText {
    param(
        [AllowNull()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }

    $value = $Text -replace "(?i)(token|password|secret|authorization|bearer)\s*[:=]\s*\S+", '$1=<redacted>'
    $value = $value -replace "[\r\n]+", " "
    if ($value.Length -gt 500) {
        return $value.Substring(0, 500) + "..."
    }

    return $value
}

function Write-LauncherLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $line = "{0} {1}" -f (Get-Timestamp), (Protect-LogText $Message)
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Add-Check {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,

        [Parameter(Mandatory = $true)]
        [string]$Label,

        [Parameter(Mandatory = $true)]
        [ValidateSet("ok", "warning", "failed", "skipped")]
        [string]$Status,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [hashtable]$Details = @{}
    )

    $check = [ordered]@{
        id         = $Id
        label      = $Label
        status     = $Status
        message    = $Message
        details    = $Details
        checked_at = [string](Get-Timestamp)
    }

    $Checks.Add($check) | Out-Null
    Write-LauncherLog ("{0}: {1} - {2}" -f $Id, $Status, $Message)
}

function Get-CheckRequired {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Check
    )

    try {
        if ($null -ne $Check.details -and $Check.details.Contains("required")) {
            return [bool]$Check.details["required"]
        }
    }
    catch {
        return $false
    }

    return $false
}

function New-LauncherSummary {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$StableChecks
    )

    $totalChecks = @($StableChecks).Count
    $okChecks = @($StableChecks | Where-Object { $_.status -eq "ok" }).Count
    $warningChecks = @($StableChecks | Where-Object { $_.status -eq "warning" }).Count
    $failedChecks = @($StableChecks | Where-Object { $_.status -eq "failed" }).Count
    $requiredFailedChecks = @($StableChecks | Where-Object { $_.status -eq "failed" -and (Get-CheckRequired -Check $_) }).Count
    $optionalFailedChecks = @($StableChecks | Where-Object { $_.status -eq "failed" -and -not (Get-CheckRequired -Check $_) }).Count
    $blocking = $requiredFailedChecks -gt 0

    $message = "All required launcher preflight checks passed."
    if ($blocking) {
        $message = "One or more required launcher preflight checks failed."
    }
    elseif ($warningChecks -gt 0 -or $optionalFailedChecks -gt 0) {
        $message = "Required launcher preflight checks passed, but warnings need review."
    }

    return [ordered]@{
        total_checks           = [int]$totalChecks
        ok_checks              = [int]$okChecks
        warning_checks         = [int]$warningChecks
        failed_checks          = [int]$failedChecks
        required_failed_checks = [int]$requiredFailedChecks
        optional_failed_checks = [int]$optionalFailedChecks
        blocking               = [bool]$blocking
        message                = [string]$message
    }
}

function Get-OverallStatus {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$StableChecks
    )

    $requiredFailedChecks = @($StableChecks | Where-Object { $_.status -eq "failed" -and (Get-CheckRequired -Check $_) }).Count
    if ($requiredFailedChecks -gt 0) {
        return "failed"
    }

    $optionalProblems = @($StableChecks | Where-Object { $_.status -eq "warning" -or ($_.status -eq "failed" -and -not (Get-CheckRequired -Check $_)) }).Count
    if ($optionalProblems -gt 0) {
        return "warning"
    }

    return "ok"
}

function New-LauncherArtifacts {
    param(
        [bool]$IncludeManagementKindConfig,

        [bool]$IncludeWorkloadKindConfig
    )

    $artifacts = [ordered]@{
        status_path           = [string]$StatusPath
        log_path              = [string]$LogPath
        kind_config_directory = [string]$KindDir
    }

    if ($IncludeManagementKindConfig) {
        $artifacts["management_kind_config"] = [string]$MgmtKindConfigPath
    }

    if ($IncludeWorkloadKindConfig) {
        $artifacts["workload_kind_config"] = [string]$WorkloadKindConfigPath
    }

    return $artifacts
}

function New-NextActions {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$StableChecks,

        [Parameter(Mandatory = $true)]
        [string]$LauncherMode,

        [Parameter(Mandatory = $true)]
        [string]$OverallStatus
    )

    $actions = New-Object System.Collections.Generic.List[string]

    foreach ($check in @($StableChecks | Where-Object { $_.id -like "port_*" -and $_.status -eq "failed" })) {
        $port = $null
        try {
            if ($null -ne $check.details -and $check.details.Contains("port")) {
                $port = $check.details["port"]
            }
        }
        catch {
            $port = $null
        }

        if ($null -ne $port) {
            $actions.Add(("Free port {0} on 127.0.0.1 before creating DevDeploy local clusters." -f $port)) | Out-Null
        }
    }

    if ($OverallStatus -eq "ok" -and $LauncherMode -eq "preflight") {
        $actions.Add("Run the launcher with -GenerateKindConfigs to preview deterministic kind cluster configuration.") | Out-Null
    }
    elseif ($OverallStatus -eq "ok" -and $LauncherMode -eq "kind_config_preview") {
        $actions.Add("Kind config previews are ready. Proceed to the future cluster creation step when Phase 2C/2D implementation is available.") | Out-Null
    }
    elseif ($OverallStatus -eq "ok" -and $LauncherMode -eq "management_cluster_create") {
        $actions.Add("devdeploy-mgmt is created or verified. Proceed to the future platform component bootstrap step when available.") | Out-Null
    }
    elseif ($OverallStatus -eq "warning") {
        $actions.Add("Review warning checks before continuing. Warnings are not currently blocking, but later setup steps may need attention.") | Out-Null
    }

    if ($actions.Count -eq 0) {
        $actions.Add("Review failed required checks and rerun the launcher after resolving them.") | Out-Null
    }

    return @($actions | ForEach-Object { [string]$_ })
}

function Test-CommandAvailable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Label,

        [bool]$Required = $true
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        $status = if ($Required) { "failed" } else { "warning" }
        $message = if ($Required) {
            "$Label was not found on PATH. Install $Name before creating local DevDeploy clusters."
        }
        else {
            "$Label was not found on PATH. This is not blocking for the read-only preflight, but later setup steps may need it."
        }

        Add-Check -Id ("tool_{0}" -f $Name) -Label $Label -Status $status -Message $message -Details @{
            command  = $Name
            required = $Required
        }
        return $false
    }

    Add-Check -Id ("tool_{0}" -f $Name) -Label $Label -Status "ok" -Message "$Label is available on PATH." -Details @{
        command  = $Name
        required = $Required
    }
    return $true
}

function Invoke-ReadOnlyCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName,

        [string[]]$Arguments = @(),

        [int]$TimeoutSeconds = 8
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FileName
    $psi.Arguments = ($Arguments | ForEach-Object {
            if ($_ -match "\s") {
                '"' + ($_ -replace '"', '\"') + '"'
            }
            else {
                $_
            }
        }) -join " "
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    try {
        [void]$process.Start()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try {
                $process.Kill()
            }
            catch {
                Write-LauncherLog ("Failed to terminate timed out command {0}: {1}" -f $FileName, $_.Exception.Message)
            }

            return [ordered]@{
                exit_code = $null
                timed_out = $true
                stdout    = ""
                stderr    = "Command timed out."
            }
        }

        return [ordered]@{
            exit_code = $process.ExitCode
            timed_out = $false
            stdout    = Protect-LogText $process.StandardOutput.ReadToEnd()
            stderr    = Protect-LogText $process.StandardError.ReadToEnd()
        }
    }
    catch {
        return [ordered]@{
            exit_code = $null
            timed_out = $false
            stdout    = ""
            stderr    = Protect-LogText $_.Exception.Message
        }
    }
    finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}

function Test-DockerDaemon {
    param(
        [bool]$DockerCliAvailable
    )

    if (-not $DockerCliAvailable) {
        Add-Check -Id "docker_daemon" -Label "Docker daemon" -Status "skipped" -Message "Docker daemon check was skipped because Docker CLI is missing." -Details @{
            required = $true
        }
        return
    }

    $result = Invoke-ReadOnlyCommand -FileName "docker" -Arguments @("info", "--format", "{{json .ServerVersion}}") -TimeoutSeconds 10
    if ($result.exit_code -eq 0 -and -not $result.timed_out) {
        Add-Check -Id "docker_daemon" -Label "Docker daemon" -Status "ok" -Message "Docker daemon is reachable." -Details @{
            required = $true
        }
        return
    }

    $message = "Docker daemon is not reachable. Start Docker Desktop and rerun the launcher preflight."
    if ($result.timed_out) {
        $message = "Docker daemon check timed out. Start Docker Desktop or verify Docker is responsive, then rerun the launcher preflight."
    }

    Add-Check -Id "docker_daemon" -Label "Docker daemon" -Status "failed" -Message $message -Details @{
        required = $true
        error    = $result.stderr
    }
}

function Test-LocalPortAvailable {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port,

        [bool]$Required = $true,

        [bool]$AllowBusyAsOk = $false,

        [string]$ExpectedCluster = "",

        [bool]$ExistingClusterDetected = $false
    )

    $listener = $null
    try {
        $endpoint = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse("127.0.0.1")), $Port
        $listener = New-Object System.Net.Sockets.TcpListener $endpoint
        $listener.Start()
        Add-Check -Id ("port_{0}" -f $Port) -Label ("Port {0}" -f $Port) -Status "ok" -Message ("Port {0} is available on 127.0.0.1." -f $Port) -Details @{
            port                      = $Port
            address                   = "127.0.0.1"
            required                  = $Required
            expected_cluster          = $ExpectedCluster
            existing_cluster_detected = $ExistingClusterDetected
            blocking                  = $false
        }
    }
    catch {
        $status = if ($AllowBusyAsOk) { "ok" } elseif ($Required) { "failed" } else { "warning" }
        $message = if ($AllowBusyAsOk) {
            "Port {0} is in use and {1} exists; treating this as expected for the cluster." -f $Port, $ExpectedCluster
        }
        elseif ($Required) {
            "Port {0} is already in use. Free this port before creating DevDeploy local clusters." -f $Port
        }
        else {
            "Port {0} is already in use. This is not blocking for the current mode, but review it before later setup steps." -f $Port
        }

        Add-Check -Id ("port_{0}" -f $Port) -Label ("Port {0}" -f $Port) -Status $status -Message $message -Details @{
            port                      = $Port
            address                   = "127.0.0.1"
            required                  = $Required
            expected_cluster          = $ExpectedCluster
            existing_cluster_detected = $ExistingClusterDetected
            blocking                  = [bool]($Required -and -not $AllowBusyAsOk)
            busy_ok                   = $AllowBusyAsOk
            error                     = Protect-LogText $_.Exception.Message
        }
    }
    finally {
        if ($null -ne $listener) {
            $listener.Stop()
        }
    }
}

function Test-KindClusters {
    param(
        [bool]$KindAvailable,

        [bool]$ManagementCreateMode = $false
    )

    if (-not $KindAvailable) {
        Add-Check -Id "kind_clusters" -Label "Existing kind clusters" -Status "skipped" -Message "Existing kind cluster detection was skipped because kind is missing." -Details @{
            required = $false
        }
        return
    }

    $result = Invoke-ReadOnlyCommand -FileName "kind" -Arguments @("get", "clusters") -TimeoutSeconds 8
    if ($result.exit_code -ne 0 -or $result.timed_out) {
        Add-Check -Id "kind_clusters" -Label "Existing kind clusters" -Status "warning" -Message "Could not list existing kind clusters. Later setup may need manual verification." -Details @{
            required = $false
            error    = $result.stderr
        }
        return
    }

    $clusters = @()
    if (-not [string]::IsNullOrWhiteSpace($result.stdout)) {
        $clusters = @($result.stdout -split "\s+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    $mgmtExists = $clusters -contains "devdeploy-mgmt"
    $workloadExists = $clusters -contains "devdeploy-workload"
    $status = if ($mgmtExists -or $workloadExists) { "warning" } else { "ok" }
    $message = if ($mgmtExists -or $workloadExists) {
        "Existing DevDeploy kind cluster names were detected. Future setup should verify them instead of recreating blindly."
    }
    else {
        "No existing DevDeploy kind cluster names were detected."
    }

    if ($ManagementCreateMode -and $mgmtExists -and -not $workloadExists) {
        $status = "ok"
        $message = "devdeploy-mgmt already exists and will be verified instead of recreated."
    }
    elseif ($ManagementCreateMode -and $workloadExists) {
        $status = "warning"
        $message = "An existing devdeploy-workload cluster was detected. This mode will not create, modify, or delete it."
    }

    Add-Check -Id "kind_clusters" -Label "Existing kind clusters" -Status $status -Message $message -Details @{
        required                   = $false
        clusters                   = $clusters
        devdeploy_mgmt_exists      = $mgmtExists
        devdeploy_workload_exists  = $workloadExists
    }
}

function Test-KubectlContext {
    param(
        [bool]$KubectlAvailable
    )

    if (-not $KubectlAvailable) {
        Add-Check -Id "kubectl_context" -Label "kubectl current context" -Status "skipped" -Message "kubectl context check was skipped because kubectl is missing." -Details @{
            required = $false
        }
        return
    }

    $result = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("config", "current-context") -TimeoutSeconds 8
    if ($result.exit_code -ne 0 -or $result.timed_out -or [string]::IsNullOrWhiteSpace($result.stdout)) {
        Add-Check -Id "kubectl_context" -Label "kubectl current context" -Status "warning" -Message "kubectl is available, but no current context could be read." -Details @{
            required = $false
            error    = $result.stderr
        }
        return
    }

    Add-Check -Id "kubectl_context" -Label "kubectl current context" -Status "ok" -Message "kubectl current context was detected." -Details @{
        required        = $false
        current_context = $result.stdout.Trim()
    }
}

function New-KindConfigContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClusterName,

        [Parameter(Mandatory = $true)]
        [int]$ApiServerPort,

        [Parameter(Mandatory = $true)]
        [int]$HttpHostPort,

        [Parameter(Mandatory = $true)]
        [int]$HttpsHostPort
    )

    $lines = @(
        "kind: Cluster",
        "apiVersion: kind.x-k8s.io/v1alpha4",
        "name: $ClusterName",
        "networking:",
        "  apiServerAddress: `"127.0.0.1`"",
        "  apiServerPort: $ApiServerPort",
        "nodes:",
        "  - role: control-plane",
        "    extraPortMappings:",
        "      - containerPort: 80",
        "        hostPort: $HttpHostPort",
        "        listenAddress: `"127.0.0.1`"",
        "        protocol: TCP",
        "      - containerPort: 443",
        "        hostPort: $HttpsHostPort",
        "        listenAddress: `"127.0.0.1`"",
        "        protocol: TCP"
    )

    return [string]($lines -join [Environment]::NewLine)
}

function Write-KindConfigPreview {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,

        [Parameter(Mandatory = $true)]
        [string]$Label,

        [Parameter(Mandatory = $true)]
        [string]$ClusterName,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [int]$ApiServerPort,

        [Parameter(Mandatory = $true)]
        [int]$HttpHostPort,

        [Parameter(Mandatory = $true)]
        [int]$HttpsHostPort
    )

    try {
        $content = New-KindConfigContent -ClusterName $ClusterName -ApiServerPort $ApiServerPort -HttpHostPort $HttpHostPort -HttpsHostPort $HttpsHostPort
        Set-Content -LiteralPath $Path -Value $content -Encoding UTF8

        Add-Check -Id $Id -Label $Label -Status "ok" -Message ("Generated deterministic kind config preview for {0}." -f $ClusterName) -Details @{
            required           = $true
            generated_path     = $Path
            cluster_name       = $ClusterName
            api_server_address = "127.0.0.1"
            api_server_port    = $ApiServerPort
            http_host_port     = $HttpHostPort
            https_host_port    = $HttpsHostPort
            creates_cluster    = $false
        }
    }
    catch {
        Add-Check -Id $Id -Label $Label -Status "failed" -Message ("Could not write kind config preview for {0}." -f $ClusterName) -Details @{
            required       = $true
            generated_path = $Path
            cluster_name   = $ClusterName
            error          = Protect-LogText $_.Exception.Message
        }
    }
}

function Get-KindClusterNames {
    param(
        [bool]$KindAvailable
    )

    if (-not $KindAvailable) {
        return [ordered]@{
            success  = $false
            clusters = @()
            error    = "kind CLI is missing."
        }
    }

    $result = Invoke-ReadOnlyCommand -FileName "kind" -Arguments @("get", "clusters") -TimeoutSeconds 8
    if ($result.exit_code -ne 0 -or $result.timed_out) {
        return [ordered]@{
            success  = $false
            clusters = @()
            error    = $result.stderr
        }
    }

    $clusters = @()
    if (-not [string]::IsNullOrWhiteSpace($result.stdout)) {
        $clusters = @($result.stdout -split "\s+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    return [ordered]@{
        success  = $true
        clusters = $clusters
        error    = ""
    }
}

function Test-ManagementClusterExists {
    param(
        [bool]$KindAvailable
    )

    $clusterResult = Get-KindClusterNames -KindAvailable $KindAvailable
    if (-not $clusterResult.success) {
        Add-Check -Id "management_cluster_exists" -Label "Management cluster exists" -Status "failed" -Message "Could not verify whether devdeploy-mgmt exists." -Details @{
            required     = $true
            cluster_name = "devdeploy-mgmt"
            error        = Protect-LogText $clusterResult.error
        }
        return $false
    }

    $exists = @($clusterResult.clusters) -contains "devdeploy-mgmt"
    if ($exists) {
        Add-Check -Id "management_cluster_exists" -Label "Management cluster exists" -Status "ok" -Message "devdeploy-mgmt already exists." -Details @{
            required     = $true
            cluster_name = "devdeploy-mgmt"
            exists       = $true
        }
        return $true
    }

    Add-Check -Id "management_cluster_exists" -Label "Management cluster exists" -Status "ok" -Message "devdeploy-mgmt does not exist yet and can be created by this explicit mode." -Details @{
        required     = $true
        cluster_name = "devdeploy-mgmt"
        exists       = $false
    }
    return $false
}

function Invoke-ManagementClusterCreate {
    param(
        [bool]$AlreadyExists
    )

    if ($AlreadyExists) {
        Add-Check -Id "management_cluster_create" -Label "Management cluster create" -Status "skipped" -Message "devdeploy-mgmt already exists, so creation was skipped." -Details @{
            required     = $false
            cluster_name = "devdeploy-mgmt"
            created      = $false
            skipped      = "already_exists"
        }
        return $true
    }

    Write-LauncherLog "Creating devdeploy-mgmt with kind. No Kubernetes manifests or Helm charts will be installed."
    $result = Invoke-ReadOnlyCommand -FileName "kind" -Arguments @("create", "cluster", "--config", $MgmtKindConfigPath) -TimeoutSeconds 300
    if ($result.exit_code -eq 0 -and -not $result.timed_out) {
        Add-Check -Id "management_cluster_create" -Label "Management cluster create" -Status "ok" -Message "Created devdeploy-mgmt with kind." -Details @{
            required     = $true
            cluster_name = "devdeploy-mgmt"
            config_path  = $MgmtKindConfigPath
            created      = $true
        }
        return $true
    }

    $message = "kind failed to create devdeploy-mgmt. No automatic cleanup was performed."
    if ($result.timed_out) {
        $message = "kind create cluster timed out for devdeploy-mgmt. No automatic cleanup was performed."
    }

    Add-Check -Id "management_cluster_create" -Label "Management cluster create" -Status "failed" -Message $message -Details @{
        required     = $true
        cluster_name = "devdeploy-mgmt"
        config_path  = $MgmtKindConfigPath
        error        = $result.stderr
    }
    return $false
}

function Test-ManagementClusterVerify {
    param(
        [bool]$KindAvailable,

        [bool]$KubectlAvailable
    )

    $clusterResult = Get-KindClusterNames -KindAvailable $KindAvailable
    if (-not $clusterResult.success -or -not (@($clusterResult.clusters) -contains "devdeploy-mgmt")) {
        Add-Check -Id "management_cluster_verify" -Label "Management cluster verify" -Status "failed" -Message "devdeploy-mgmt could not be found during verification." -Details @{
            required     = $true
            cluster_name = "devdeploy-mgmt"
            error        = Protect-LogText $clusterResult.error
        }
        return
    }

    if (-not $KubectlAvailable) {
        Add-Check -Id "management_cluster_verify" -Label "Management cluster verify" -Status "failed" -Message "kubectl is required to verify devdeploy-mgmt nodes." -Details @{
            required     = $true
            cluster_name = "devdeploy-mgmt"
            context      = "kind-devdeploy-mgmt"
        }
        return
    }

    $contextResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("config", "get-contexts", "kind-devdeploy-mgmt", "--no-headers") -TimeoutSeconds 8
    if ($contextResult.exit_code -ne 0 -or $contextResult.timed_out -or [string]::IsNullOrWhiteSpace($contextResult.stdout)) {
        Add-Check -Id "management_cluster_verify" -Label "Management cluster verify" -Status "failed" -Message "kubectl context kind-devdeploy-mgmt is not usable." -Details @{
            required     = $true
            cluster_name = "devdeploy-mgmt"
            context      = "kind-devdeploy-mgmt"
            error        = $contextResult.stderr
        }
        return
    }

    $lastError = ""
    $lastNodeCount = 0
    $lastReadyCount = 0

    for ($attempt = 1; $attempt -le 12; $attempt++) {
        $nodesResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "get", "nodes", "--no-headers") -TimeoutSeconds 20
        if ($nodesResult.exit_code -eq 0 -and -not $nodesResult.timed_out -and -not [string]::IsNullOrWhiteSpace($nodesResult.stdout)) {
            try {
                $nodes = @($nodesResult.stdout -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                $readyNodes = @($nodes | Where-Object {
                        $columns = @($_ -split "\s+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                        $columns.Count -ge 2 -and $columns[1] -eq "Ready"
                    })

                $lastNodeCount = [int]$nodes.Count
                $lastReadyCount = [int]$readyNodes.Count

                if ($lastNodeCount -gt 0 -and $lastReadyCount -eq $lastNodeCount) {
                    Add-Check -Id "management_cluster_verify" -Label "Management cluster verify" -Status "ok" -Message "devdeploy-mgmt exists and all nodes are Ready." -Details @{
                        required     = $true
                        cluster_name = "devdeploy-mgmt"
                        context      = "kind-devdeploy-mgmt"
                        node_count   = [int]$lastNodeCount
                        ready_nodes  = [int]$lastReadyCount
                    }
                    return
                }
            }
            catch {
                $lastError = Protect-LogText $_.Exception.Message
            }
        }
        else {
            $lastError = $nodesResult.stderr
        }

        if ($attempt -lt 12) {
            Start-Sleep -Seconds 5
        }
    }

    if ($lastNodeCount -gt 0) {
        Add-Check -Id "management_cluster_verify" -Label "Management cluster verify" -Status "warning" -Message "devdeploy-mgmt exists, but not all nodes are Ready yet." -Details @{
            required     = $true
            cluster_name = "devdeploy-mgmt"
            context      = "kind-devdeploy-mgmt"
            node_count   = [int]$lastNodeCount
            ready_nodes  = [int]$lastReadyCount
        }
        return
    }

    Add-Check -Id "management_cluster_verify" -Label "Management cluster verify" -Status "failed" -Message "kubectl could not read nodes from devdeploy-mgmt." -Details @{
        required     = $true
        cluster_name = "devdeploy-mgmt"
        context      = "kind-devdeploy-mgmt"
        error        = Protect-LogText $lastError
    }
}

function Add-SkippedManagementClusterStages {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Reason
    )

    Add-Check -Id "management_cluster_exists" -Label "Management cluster exists" -Status "skipped" -Message $Reason -Details @{
        required     = $true
        cluster_name = "devdeploy-mgmt"
    }
    Add-Check -Id "management_cluster_create" -Label "Management cluster create" -Status "skipped" -Message $Reason -Details @{
        required     = $true
        cluster_name = "devdeploy-mgmt"
    }
    Add-Check -Id "management_cluster_verify" -Label "Management cluster verify" -Status "skipped" -Message $Reason -Details @{
        required     = $true
        cluster_name = "devdeploy-mgmt"
    }
}

New-LocalDirectory -Path $StatusDir
New-LocalDirectory -Path $LogsDir
New-LocalDirectory -Path $KindDir

if ($CreateManagementCluster) {
    Write-LauncherLog "Starting DevDeploy Launcher guarded management cluster create mode."
}
elseif ($GenerateKindConfigs) {
    Write-LauncherLog "Starting DevDeploy Launcher read-only preflight with kind config preview generation."
}
else {
    Write-LauncherLog "Starting DevDeploy Launcher read-only preflight."
}

$dockerAvailable = Test-CommandAvailable -Name "docker" -Label "Docker CLI" -Required $true
$kindAvailable = Test-CommandAvailable -Name "kind" -Label "kind CLI" -Required $true
$kubectlAvailable = Test-CommandAvailable -Name "kubectl" -Label "kubectl CLI" -Required $true
[void](Test-CommandAvailable -Name "git" -Label "git CLI" -Required $false)
[void](Test-CommandAvailable -Name "helm" -Label "Helm CLI" -Required $false)

Test-DockerDaemon -DockerCliAvailable $dockerAvailable

$existingKindClusters = @()
$managementClusterExistsBeforePortCheck = $false
$workloadClusterExistsBeforePortCheck = $false
if ($kindAvailable) {
    $earlyClusterResult = Get-KindClusterNames -KindAvailable $kindAvailable
    if ($earlyClusterResult.success) {
        $existingKindClusters = @($earlyClusterResult.clusters)
        $managementClusterExistsBeforePortCheck = $existingKindClusters -contains "devdeploy-mgmt"
        $workloadClusterExistsBeforePortCheck = $existingKindClusters -contains "devdeploy-workload"
    }
}

foreach ($entry in $PortPlan.GetEnumerator()) {
    $portKey = [string]$entry.Key
    $isManagementPort = $portKey -in @("management_api", "management_http", "management_https")
    $isWorkloadPort = $portKey -in @("workload_api", "workload_http", "workload_https")
    $expectedCluster = if ($isManagementPort) { "devdeploy-mgmt" } elseif ($isWorkloadPort) { "devdeploy-workload" } else { "" }
    $existingClusterDetected = [bool](($isManagementPort -and $managementClusterExistsBeforePortCheck) -or ($isWorkloadPort -and $workloadClusterExistsBeforePortCheck))
    $portRequired = [bool](-not $existingClusterDetected)
    $allowBusyAsOk = [bool]$existingClusterDetected

    Test-LocalPortAvailable -Port ([int]$entry.Value) -Required $portRequired -AllowBusyAsOk $allowBusyAsOk -ExpectedCluster $expectedCluster -ExistingClusterDetected $existingClusterDetected
}

if ($workloadClusterExistsBeforePortCheck) {
    Add-Check -Id "workload_cluster_detected" -Label "Workload cluster detected" -Status "warning" -Message "devdeploy-workload already exists. This launcher mode will not create, modify, or delete it." -Details @{
        required     = $false
        cluster_name = "devdeploy-workload"
        exists       = $true
    }
}

Test-KindClusters -KindAvailable $kindAvailable -ManagementCreateMode ([bool]$CreateManagementCluster)
Test-KubectlContext -KubectlAvailable $kubectlAvailable

$launcherMode = "preflight"
if ($CreateManagementCluster) {
    $launcherMode = "management_cluster_create"
}
elseif ($GenerateKindConfigs) {
    $launcherMode = "kind_config_preview"
}

if ($CreateManagementCluster) {
    Write-KindConfigPreview -Id "management_kind_config" -Label "Management kind config" -ClusterName "devdeploy-mgmt" -Path $MgmtKindConfigPath -ApiServerPort 58080 -HttpHostPort 8080 -HttpsHostPort 8443

    $preCreateChecks = @($Checks | ForEach-Object { $_ })
    $preCreateStatus = [string](Get-OverallStatus -StableChecks $preCreateChecks)
    if ($preCreateStatus -eq "failed") {
        Add-SkippedManagementClusterStages -Reason "Management cluster create was skipped because required preflight or kind config checks failed."
    }
    else {
        $managementClusterExists = Test-ManagementClusterExists -KindAvailable $kindAvailable
        $managementClusterCreatedOrPresent = Invoke-ManagementClusterCreate -AlreadyExists $managementClusterExists
        if ($managementClusterCreatedOrPresent) {
            Test-ManagementClusterVerify -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable
        }
        else {
            Add-Check -Id "management_cluster_verify" -Label "Management cluster verify" -Status "skipped" -Message "Management cluster verification was skipped because creation failed." -Details @{
                required     = $true
                cluster_name = "devdeploy-mgmt"
            }
        }
    }
}
elseif ($GenerateKindConfigs) {
    Write-KindConfigPreview -Id "kind_config_mgmt_preview" -Label "Management kind config preview" -ClusterName "devdeploy-mgmt" -Path $MgmtKindConfigPath -ApiServerPort 58080 -HttpHostPort 8080 -HttpsHostPort 8443
    Write-KindConfigPreview -Id "kind_config_workload_preview" -Label "Workload kind config preview" -ClusterName "devdeploy-workload" -Path $WorkloadKindConfigPath -ApiServerPort 58081 -HttpHostPort 8081 -HttpsHostPort 8444
}

$stableChecks = @($Checks | ForEach-Object { $_ })
$overallStatus = [string](Get-OverallStatus -StableChecks $stableChecks)
$summary = New-LauncherSummary -StableChecks $stableChecks
$artifacts = New-LauncherArtifacts -IncludeManagementKindConfig ([bool]($GenerateKindConfigs -or $CreateManagementCluster)) -IncludeWorkloadKindConfig ([bool]($GenerateKindConfigs -and -not $CreateManagementCluster))
$nextActions = @(New-NextActions -StableChecks $stableChecks -LauncherMode $launcherMode -OverallStatus $overallStatus)

$statusDocument = [ordered]@{
    schema_version   = "1"
    contract         = "devdeploy-launcher-status"
    mode             = [string]$launcherMode
    generated_at     = [string](Get-Timestamp)
    launcher_version = $LauncherVersion
    host_os          = [string]([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)
    shell            = [string]("{0} {1}" -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion.ToString())
    repo_root        = [string]$RepoRoot
    status           = $overallStatus
    summary          = $summary
    checks           = $stableChecks
    artifacts        = $artifacts
    ports            = $PortPlan
    next_actions     = [string[]]$nextActions
}

$statusDocument | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $StatusPath -Encoding UTF8
Write-LauncherLog ("Wrote launcher status to {0}" -f $StatusPath)

if (-not $Quiet) {
    Write-Host ("DevDeploy Launcher preflight status: {0}" -f $overallStatus)
    if ($CreateManagementCluster) {
        Write-Host ("Management kind config: {0}" -f $MgmtKindConfigPath)
    }
    elseif ($GenerateKindConfigs) {
        Write-Host ("Management kind config: {0}" -f $MgmtKindConfigPath)
        Write-Host ("Workload kind config: {0}" -f $WorkloadKindConfigPath)
    }
    Write-Host ("Status: {0}" -f $StatusPath)
    Write-Host ("Log: {0}" -f $LogPath)
}

if ($overallStatus -eq "failed") {
    exit 1
}

exit 0
