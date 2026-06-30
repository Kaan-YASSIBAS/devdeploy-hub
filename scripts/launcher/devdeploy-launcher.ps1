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

    [switch]$CreateWorkloadCluster,

    [switch]$BootstrapManagementIngress,

    [switch]$BootstrapManagementPostgres,

    [switch]$BuildManagementBackendImage,

    [switch]$LoadManagementBackendImage,

    [switch]$EnsureManagementBackendSecret,

    [switch]$VerifyManagementBackendSecret,

    [switch]$BootstrapManagementBackend,

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
$IngressNginxChartVersion = "4.15.1"
$IngressNginxNamespace = "ingress-nginx"
$IngressNginxRelease = "ingress-nginx"
$PostgresChartVersion = "18.7.6"
$PostgresNamespace = "devdeploy"
$PostgresRelease = "devdeploy-postgres"
$PostgresDatabase = "devdeploy"
$PostgresUsername = "devdeploy"
$PostgresPassword = "local-devdeploy-password"
$BackendImage = "devdeploy-backend:local"
$BackendContextPath = Join-Path $RepoRoot "backend"
$BackendDockerfilePath = Join-Path $BackendContextPath "Dockerfile"
$BackendRequirementsPath = Join-Path $BackendContextPath "requirements.txt"
$BackendConstraintsPath = Join-Path $BackendContextPath "constraints.txt"
$BackendSecretName = "devdeploy-backend-secret"
$PostgresServiceHost = "devdeploy-postgres-postgresql.devdeploy.svc.cluster.local"
$BackendManifestRelativePath = "platform/management/backend"
$BackendManifestPath = Join-Path $RepoRoot "platform\management\backend"

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
        [string]$OverallStatus,

        [Parameter(Mandatory = $true)]
        [object]$ManagementCluster,

        [Parameter(Mandatory = $true)]
        [object]$WorkloadCluster,

        [Parameter(Mandatory = $true)]
        [object]$PlatformBootstrap
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

    $managementClusterStatus = [string]$ManagementCluster["status"]
    $workloadClusterStatus = [string]$WorkloadCluster["status"]

    if ($managementClusterStatus -eq "missing") {
        $actions.Add("Run the launcher with -CreateManagementCluster to create devdeploy-mgmt when you are ready.") | Out-Null
    }
    elseif ($managementClusterStatus -eq "ready") {
        if ($workloadClusterStatus -eq "missing") {
            $actions.Add("devdeploy-mgmt is ready. Run the launcher with -CreateWorkloadCluster to create devdeploy-workload when you are ready.") | Out-Null
        }
        elseif ($workloadClusterStatus -eq "ready") {
            $actions.Add("devdeploy-mgmt and devdeploy-workload are ready. Proceed to the future Argo CD and platform bootstrap step when available.") | Out-Null
        }
        elseif ($workloadClusterStatus -eq "degraded") {
            $actions.Add("Check the launcher log and rerun -CreateWorkloadCluster to verify devdeploy-workload after resolving the issue.") | Out-Null
        }
        elseif ($workloadClusterStatus -eq "unknown") {
            $actions.Add("Review launcher status and logs; workload cluster status could not be determined safely.") | Out-Null
        }
    }
    elseif ($managementClusterStatus -eq "degraded") {
        $actions.Add("Check the launcher log and rerun -CreateManagementCluster to verify devdeploy-mgmt after resolving the issue.") | Out-Null
    }
    elseif ($managementClusterStatus -eq "unknown") {
        $actions.Add("Review launcher status and logs; management cluster status could not be determined safely.") | Out-Null
    }

    $ingressStatus = "not_started"
    try {
        if ($null -ne $PlatformBootstrap["components"] -and $null -ne $PlatformBootstrap["components"]["ingress_nginx"]) {
            $ingressStatus = [string]$PlatformBootstrap["components"]["ingress_nginx"]["status"]
        }
    }
    catch {
        $ingressStatus = "unknown"
    }

    if ($LauncherMode -eq "management_ingress_bootstrap") {
        if ($managementClusterStatus -eq "missing" -or $managementClusterStatus -eq "degraded") {
            $actions.Add("Run the launcher with -CreateManagementCluster before retrying -BootstrapManagementIngress.") | Out-Null
        }
        elseif ($ingressStatus -eq "ready") {
            $actions.Add("Management ingress-nginx is ready. Proceed to future PostgreSQL, backend, frontend, and Argo CD bootstrap phases when available.") | Out-Null
        }
        elseif ($ingressStatus -eq "failed" -or $ingressStatus -eq "degraded" -or $ingressStatus -eq "unknown") {
            $actions.Add("Check the launcher log and rerun -BootstrapManagementIngress after resolving the ingress-nginx issue.") | Out-Null
        }
    }

    $postgresStatus = "not_started"
    try {
        if ($null -ne $PlatformBootstrap["components"] -and $null -ne $PlatformBootstrap["components"]["postgres"]) {
            $postgresStatus = [string]$PlatformBootstrap["components"]["postgres"]["status"]
        }
    }
    catch {
        $postgresStatus = "unknown"
    }

    if ($LauncherMode -eq "management_postgres_bootstrap") {
        if ($managementClusterStatus -eq "missing" -or $managementClusterStatus -eq "degraded") {
            $actions.Add("Run the launcher with -CreateManagementCluster before retrying -BootstrapManagementPostgres.") | Out-Null
        }
        elseif ($ingressStatus -ne "ready") {
            $actions.Add("Management ingress-nginx is not Ready. Run -BootstrapManagementIngress when you are ready; PostgreSQL does not strictly depend on it.") | Out-Null
        }

        if ($postgresStatus -eq "ready") {
            $actions.Add("PostgreSQL is ready. Proceed to future backend and frontend bootstrap phases when available.") | Out-Null
        }
        elseif ($postgresStatus -eq "failed" -or $postgresStatus -eq "degraded" -or $postgresStatus -eq "unknown") {
            $actions.Add("Check the launcher log and rerun -BootstrapManagementPostgres after resolving the PostgreSQL issue.") | Out-Null
        }
    }

    $backendImageStatus = "not_checked"
    try {
        if ($null -ne $PlatformBootstrap["components"] -and $null -ne $PlatformBootstrap["components"]["backend_image"]) {
            $backendImageStatus = [string]$PlatformBootstrap["components"]["backend_image"]["status"]
        }
    }
    catch {
        $backendImageStatus = "unknown"
    }

    if ($LauncherMode -eq "management_backend_image_build") {
        if ($backendImageStatus -eq "ready") {
            $actions.Add("The management backend image is ready locally. Proceed to the future explicit image-load step when available.") | Out-Null
        }
        elseif ($backendImageStatus -eq "error" -or $backendImageStatus -eq "unknown") {
            $actions.Add("Review the sanitized launcher log, resolve the Docker or backend build input issue, and rerun -BuildManagementBackendImage.") | Out-Null
        }
    }
    elseif ($LauncherMode -eq "management_backend_image_load") {
        $localImagePresent = $false
        $loadedToManagementCluster = $false
        try {
            $localImagePresent = [bool]$PlatformBootstrap["components"]["backend_image"]["local_image_present"]
            $loadedToManagementCluster = [bool]$PlatformBootstrap["components"]["backend_image"]["loaded_to_management_cluster"]
        }
        catch {
            $localImagePresent = $false
            $loadedToManagementCluster = $false
        }

        if ($backendImageStatus -eq "ready" -and $loadedToManagementCluster) {
            $actions.Add("The management backend image is loaded into devdeploy-mgmt. Proceed to the future explicit backend Secret and bootstrap steps when available.") | Out-Null
        }
        elseif (-not $localImagePresent) {
            $actions.Add("Run -BuildManagementBackendImage before retrying -LoadManagementBackendImage.") | Out-Null
        }
        elseif ($managementClusterStatus -ne "ready") {
            $actions.Add("Create or repair devdeploy-mgmt, then rerun -LoadManagementBackendImage.") | Out-Null
        }
        else {
            $actions.Add("Review the sanitized launcher log and rerun -LoadManagementBackendImage after resolving the kind image-load issue.") | Out-Null
        }
    }

    $backendSecretStatus = "not_checked"
    try {
        if ($null -ne $PlatformBootstrap["components"] -and $null -ne $PlatformBootstrap["components"]["backend_secret"]) {
            $backendSecretStatus = [string]$PlatformBootstrap["components"]["backend_secret"]["status"]
        }
    }
    catch {
        $backendSecretStatus = "unknown"
    }

    if ($LauncherMode -eq "management_backend_secret_ensure") {
        if ($backendSecretStatus -eq "ready") {
            $actions.Add("The management backend runtime Secret is ready. Proceed to the future explicit backend bootstrap step when available.") | Out-Null
        }
        elseif ($managementClusterStatus -ne "ready") {
            $actions.Add("Create or repair devdeploy-mgmt, then rerun -EnsureManagementBackendSecret.") | Out-Null
        }
        elseif ($postgresStatus -ne "ready") {
            $actions.Add("Run -BootstrapManagementPostgres before retrying -EnsureManagementBackendSecret.") | Out-Null
        }
        else {
            $actions.Add("Review the sanitized launcher log and rerun -EnsureManagementBackendSecret after resolving the Secret verification issue.") | Out-Null
        }
    }
    elseif ($LauncherMode -eq "management_backend_secret_verify") {
        if ($backendSecretStatus -eq "ready") {
            $actions.Add("The management backend runtime Secret passed read-only verification.") | Out-Null
        }
        elseif ($managementClusterStatus -ne "ready") {
            $actions.Add("Create or repair devdeploy-mgmt, then rerun -VerifyManagementBackendSecret.") | Out-Null
        }
        else {
            $actions.Add("Review the sanitized status and run -EnsureManagementBackendSecret only when you intend to reconcile the Secret.") | Out-Null
        }
    }

    $backendStatus = "not_checked"
    try {
        if ($null -ne $PlatformBootstrap["components"] -and $null -ne $PlatformBootstrap["components"]["backend"]) {
            $backendStatus = [string]$PlatformBootstrap["components"]["backend"]["status"]
        }
    }
    catch {
        $backendStatus = "unknown"
    }

    if ($LauncherMode -eq "management_backend_bootstrap") {
        if ($backendStatus -eq "ready") {
            $actions.Add("The management backend is ready. Proceed to the future frontend and Argo CD bootstrap steps when available.") | Out-Null
        }
        elseif ($backendStatus -eq "warning") {
            $actions.Add("The backend rollout is ready, but health verification needs review. Check the sanitized launcher log and rerun -BootstrapManagementBackend.") | Out-Null
        }
        else {
            $actions.Add("Review failed backend prerequisite or rollout checks and rerun -BootstrapManagementBackend after resolving them.") | Out-Null
        }
    }

    if ($OverallStatus -eq "ok" -and $LauncherMode -eq "preflight") {
        $actions.Add("Run the launcher with -GenerateKindConfigs to preview deterministic kind cluster configuration.") | Out-Null
    }
    elseif ($OverallStatus -eq "ok" -and $LauncherMode -eq "kind_config_preview") {
        $actions.Add("Kind config previews are ready. Proceed to the future cluster creation step when Phase 2C/2D implementation is available.") | Out-Null
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

        [int]$TimeoutSeconds = 8,

        [string]$WorkingDirectory = ""
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
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $psi.WorkingDirectory = $WorkingDirectory
    }

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

function Invoke-SanitizedInputCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName,

        [string[]]$Arguments = @(),

        [Parameter(Mandatory = $true)]
        [string]$StandardInput,

        [int]$TimeoutSeconds = 30
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
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    try {
        [void]$process.Start()
        $process.StandardInput.Write($StandardInput)
        $process.StandardInput.Close()

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
        return $false
    }

    $result = Invoke-ReadOnlyCommand -FileName "docker" -Arguments @("info", "--format", "{{json .ServerVersion}}") -TimeoutSeconds 10
    if ($result.exit_code -eq 0 -and -not $result.timed_out) {
        Add-Check -Id "docker_daemon" -Label "Docker daemon" -Status "ok" -Message "Docker daemon is reachable." -Details @{
            required = $true
        }
        return $true
    }

    $message = "Docker daemon is not reachable. Start Docker Desktop and rerun the launcher preflight."
    if ($result.timed_out) {
        $message = "Docker daemon check timed out. Start Docker Desktop or verify Docker is responsive, then rerun the launcher preflight."
    }

    Add-Check -Id "docker_daemon" -Label "Docker daemon" -Status "failed" -Message $message -Details @{
        required = $true
        error    = $result.stderr
    }
    return $false
}

function New-ManagementBackendImageStatus {
    return [ordered]@{
        image                        = $BackendImage
        dockerfile                   = "backend/Dockerfile"
        context                      = "backend"
        local_image_present          = $false
        build_attempted              = $false
        build_succeeded              = $false
        load_attempted               = $false
        load_succeeded               = $false
        loaded_to_management_cluster = $false
        target_cluster               = "devdeploy-mgmt"
        status                       = "not_checked"
        message                      = "Backend image build has not been requested."
        checked_at                   = [string](Get-Timestamp)
    }
}

function Test-ManagementBackendImagePresent {
    param(
        [bool]$DockerCliAvailable,

        [bool]$DockerDaemonReachable
    )

    if (-not $DockerCliAvailable -or -not $DockerDaemonReachable) {
        return $false
    }

    $result = Invoke-ReadOnlyCommand -FileName "docker" -Arguments @("image", "inspect", "--format", "{{.Id}}", $BackendImage) -TimeoutSeconds 30
    return [bool]($result.exit_code -eq 0 -and -not $result.timed_out -and -not [string]::IsNullOrWhiteSpace($result.stdout))
}

function Invoke-ManagementBackendImageBuild {
    param(
        [bool]$DockerCliAvailable,

        [bool]$DockerDaemonReachable
    )

    $status = New-ManagementBackendImageStatus

    if (-not $DockerCliAvailable -or -not $DockerDaemonReachable) {
        $status["status"] = "error"
        $status["message"] = "Backend image build requires an available Docker CLI and reachable Docker daemon."
        $status["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "backend_image_build" -Label "Management backend image build" -Status "skipped" -Message ([string]$status["message"]) -Details @{
            required = $true
            image    = $BackendImage
        }
        return $status
    }

    $requiredPaths = @(
        [ordered]@{ id = "backend_build_context"; label = "Backend build context"; path = $BackendContextPath; relative_path = "backend"; path_type = "Container" },
        [ordered]@{ id = "backend_dockerfile"; label = "Backend Dockerfile"; path = $BackendDockerfilePath; relative_path = "backend/Dockerfile"; path_type = "Leaf" },
        [ordered]@{ id = "backend_requirements"; label = "Backend requirements"; path = $BackendRequirementsPath; relative_path = "backend/requirements.txt"; path_type = "Leaf" },
        [ordered]@{ id = "backend_constraints"; label = "Backend constraints"; path = $BackendConstraintsPath; relative_path = "backend/constraints.txt"; path_type = "Leaf" }
    )

    $missingPath = $false
    foreach ($pathCheck in $requiredPaths) {
        $exists = Test-Path -LiteralPath ([string]$pathCheck["path"]) -PathType ([string]$pathCheck["path_type"])
        if ($exists) {
            Add-Check -Id ([string]$pathCheck["id"]) -Label ([string]$pathCheck["label"]) -Status "ok" -Message ("Required path {0} exists." -f [string]$pathCheck["relative_path"]) -Details @{
                required      = $true
                relative_path = [string]$pathCheck["relative_path"]
            }
        }
        else {
            $missingPath = $true
            Add-Check -Id ([string]$pathCheck["id"]) -Label ([string]$pathCheck["label"]) -Status "failed" -Message ("Required path {0} was not found." -f [string]$pathCheck["relative_path"]) -Details @{
                required      = $true
                relative_path = [string]$pathCheck["relative_path"]
            }
        }
    }

    if ($missingPath) {
        $status["status"] = "error"
        $status["message"] = "Backend image build was not attempted because one or more required repository paths are missing."
        $status["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "backend_image_build" -Label "Management backend image build" -Status "skipped" -Message ([string]$status["message"]) -Details @{
            required = $true
            image    = $BackendImage
        }
        return $status
    }

    $status["build_attempted"] = $true
    Write-LauncherLog ("Building management backend image {0} from backend build context." -f $BackendImage)
    if (-not $Quiet) {
        Write-Host ("Building management backend image {0}..." -f $BackendImage)
    }

    # Quiet build output keeps launcher logs/status concise and avoids leaking build environment details.
    $buildResult = Invoke-ReadOnlyCommand -FileName "docker" -Arguments @("build", "--quiet", "--tag", $BackendImage, "backend") -TimeoutSeconds 1200 -WorkingDirectory $RepoRoot
    if ($buildResult.exit_code -ne 0 -or $buildResult.timed_out) {
        $status["local_image_present"] = Test-ManagementBackendImagePresent -DockerCliAvailable $DockerCliAvailable -DockerDaemonReachable $DockerDaemonReachable
        $status["status"] = "error"
        $status["message"] = if ($buildResult.timed_out) {
            "Backend image build timed out. Review Docker availability and the sanitized launcher log before retrying."
        }
        else {
            "Backend image build failed. Review the sanitized launcher log and retry the explicit build mode."
        }
        $status["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "backend_image_build" -Label "Management backend image build" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required = $true
            image    = $BackendImage
            error    = $buildResult.stderr
        }
        return $status
    }

    $status["build_succeeded"] = $true
    Add-Check -Id "backend_image_build" -Label "Management backend image build" -Status "ok" -Message "Management backend image build completed successfully." -Details @{
        required = $true
        image    = $BackendImage
        context  = "backend"
    }

    $imagePresent = Test-ManagementBackendImagePresent -DockerCliAvailable $DockerCliAvailable -DockerDaemonReachable $DockerDaemonReachable
    $status["local_image_present"] = $imagePresent
    if (-not $imagePresent) {
        $status["status"] = "error"
        $status["message"] = "Docker reported a successful build, but devdeploy-backend:local could not be verified locally."
        $status["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "backend_image_verify" -Label "Management backend image verification" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required = $true
            image    = $BackendImage
        }
        return $status
    }

    $status["status"] = "ready"
    $status["message"] = "Backend image devdeploy-backend:local was built and verified in the local Docker daemon."
    $status["checked_at"] = [string](Get-Timestamp)
    Add-Check -Id "backend_image_verify" -Label "Management backend image verification" -Status "ok" -Message ([string]$status["message"]) -Details @{
        required = $true
        image    = $BackendImage
    }
    return $status
}

function Invoke-ManagementBackendImageLoad {
    param(
        [bool]$DockerCliAvailable,

        [bool]$DockerDaemonReachable,

        [bool]$KindAvailable,

        [Parameter(Mandatory = $true)]
        [object]$ManagementCluster
    )

    $status = New-ManagementBackendImageStatus

    if (-not $DockerCliAvailable -or -not $DockerDaemonReachable) {
        $status["status"] = "error"
        $status["message"] = "Backend image load requires an available Docker CLI and reachable Docker daemon."
        $status["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "backend_image_load" -Label "Management backend image load" -Status "skipped" -Message ([string]$status["message"]) -Details @{
            required       = $true
            image          = $BackendImage
            target_cluster = "devdeploy-mgmt"
        }
        return $status
    }

    $imagePresent = Test-ManagementBackendImagePresent -DockerCliAvailable $DockerCliAvailable -DockerDaemonReachable $DockerDaemonReachable
    $status["local_image_present"] = $imagePresent
    if (-not $imagePresent) {
        $status["status"] = "error"
        $status["message"] = "Local image devdeploy-backend:local was not found. Run -BuildManagementBackendImage before loading it into devdeploy-mgmt."
        $status["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "backend_image_local" -Label "Local management backend image" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required = $true
            image    = $BackendImage
        }
        Add-Check -Id "backend_image_load" -Label "Management backend image load" -Status "skipped" -Message "Backend image load was skipped because the local image is missing." -Details @{
            required       = $true
            image          = $BackendImage
            target_cluster = "devdeploy-mgmt"
        }
        return $status
    }

    Add-Check -Id "backend_image_local" -Label "Local management backend image" -Status "ok" -Message "Local image devdeploy-backend:local exists." -Details @{
        required = $true
        image    = $BackendImage
    }

    if (-not $KindAvailable) {
        $status["status"] = "error"
        $status["message"] = "kind CLI is required to load devdeploy-backend:local into devdeploy-mgmt."
        $status["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "backend_image_load" -Label "Management backend image load" -Status "skipped" -Message ([string]$status["message"]) -Details @{
            required       = $true
            image          = $BackendImage
            target_cluster = "devdeploy-mgmt"
        }
        return $status
    }

    if ([string]$ManagementCluster["status"] -ne "ready") {
        $status["status"] = "error"
        $status["message"] = "devdeploy-mgmt must exist, be API-reachable, and have a Ready node before loading the backend image."
        $status["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "backend_image_load" -Label "Management backend image load" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required           = $true
            image              = $BackendImage
            target_cluster     = "devdeploy-mgmt"
            management_status  = [string]$ManagementCluster["status"]
            api_reachable      = $ManagementCluster["api_reachable"]
            ready_nodes        = [int]$ManagementCluster["ready_nodes"]
        }
        return $status
    }

    $status["load_attempted"] = $true
    Write-LauncherLog ("Loading management backend image {0} into devdeploy-mgmt." -f $BackendImage)
    if (-not $Quiet) {
        Write-Host ("Loading management backend image {0} into devdeploy-mgmt..." -f $BackendImage)
    }

    $loadResult = Invoke-ReadOnlyCommand -FileName "kind" -Arguments @("load", "docker-image", $BackendImage, "--name", "devdeploy-mgmt") -TimeoutSeconds 600
    if ($loadResult.exit_code -ne 0 -or $loadResult.timed_out) {
        $status["status"] = "error"
        $status["message"] = if ($loadResult.timed_out) {
            "Loading devdeploy-backend:local into devdeploy-mgmt timed out. Review the sanitized launcher log and retry."
        }
        else {
            "kind failed to load devdeploy-backend:local into devdeploy-mgmt. Review the sanitized launcher log and retry."
        }
        $status["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "backend_image_load" -Label "Management backend image load" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required       = $true
            image          = $BackendImage
            target_cluster = "devdeploy-mgmt"
            error          = $loadResult.stderr
        }
        return $status
    }

    $status["load_succeeded"] = $true
    $status["loaded_to_management_cluster"] = $true
    $status["status"] = "ready"
    $status["message"] = "Backend image devdeploy-backend:local was loaded into devdeploy-mgmt."
    $status["checked_at"] = [string](Get-Timestamp)
    Add-Check -Id "backend_image_load" -Label "Management backend image load" -Status "ok" -Message ([string]$status["message"]) -Details @{
        required       = $true
        image          = $BackendImage
        target_cluster = "devdeploy-mgmt"
    }
    return $status
}

function New-ManagementBackendSecretStatus {
    return [ordered]@{
        exists                           = $false
        ready                            = $false
        namespace                        = $PostgresNamespace
        secret_name                      = $BackendSecretName
        required_keys_present            = $false
        database_url_configured          = $false
        jwt_secret_configured            = $false
        github_workflow_token_configured = $false
        mode                             = "not_checked"
        status                           = "not_checked"
        message                          = "Backend runtime Secret has not been checked."
        checked_at                       = [string](Get-Timestamp)
    }
}

function New-ManagementBackendStatus {
    return [ordered]@{
        deployed               = $false
        ready                  = $false
        namespace              = $PostgresNamespace
        deployment             = "devdeploy-backend"
        service                = "devdeploy-backend"
        ingress                = "devdeploy-backend"
        image                  = $BackendImage
        manifests_path         = $BackendManifestRelativePath
        rollout_succeeded      = $false
        health_check_succeeded = $false
        status                 = "not_checked"
        message                = "Backend bootstrap has not been requested."
        checked_at             = [string](Get-Timestamp)
    }
}

function Get-SecretKeyNames {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SecretName
    )

    $template = '{{range $key, $value := .data}}{{$key}}{{"\n"}}{{end}}'
    $result = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $PostgresNamespace, "get", "secret", $SecretName, "--output", "go-template=$template") -TimeoutSeconds 20
    if ($result.exit_code -ne 0 -or $result.timed_out) {
        return [ordered]@{
            success = $false
            keys    = @()
            error   = $result.stderr
        }
    }

    $keys = @($result.stdout -split "\s+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    return [ordered]@{
        success = $true
        keys    = $keys
        error   = ""
    }
}

function Get-DecodedSecretValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SecretName,

        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    $jsonPath = "{.data.$Key}"
    $result = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $PostgresNamespace, "get", "secret", $SecretName, "--output", "jsonpath=$jsonPath") -TimeoutSeconds 20
    if ($result.exit_code -ne 0 -or $result.timed_out) {
        return [ordered]@{
            success = $false
            value   = ""
            error   = $result.stderr
        }
    }

    try {
        $encodedValue = [string]$result.stdout
        $decodedValue = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($encodedValue.Trim()))
        return [ordered]@{
            success = $true
            value   = $decodedValue
            error   = ""
        }
    }
    catch {
        return [ordered]@{
            success = $false
            value   = ""
            error   = "Secret value could not be decoded safely."
        }
    }
}

function New-CryptographicJwtSecret {
    $bytes = New-Object byte[] 48
    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $generator.GetBytes($bytes)
        return [System.Convert]::ToBase64String($bytes)
    }
    finally {
        $generator.Dispose()
    }
}

function Invoke-EnsureManagementBackendSecret {
    param(
        [bool]$KubectlAvailable,

        [Parameter(Mandatory = $true)]
        [object]$ManagementCluster
    )

    $status = New-ManagementBackendSecretStatus
    $status["mode"] = "ensure"

    if (-not $KubectlAvailable) {
        $status["status"] = "error"
        $status["message"] = "kubectl CLI is required to ensure the management backend Secret."
        $status["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "backend_secret_ensure" -Label "Management backend Secret" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required    = $true
            namespace   = $PostgresNamespace
            secret_name = $BackendSecretName
        }
        return $status
    }

    if ([string]$ManagementCluster["status"] -ne "ready") {
        $status["status"] = "error"
        $status["message"] = "devdeploy-mgmt must exist, be API-reachable, and have a Ready node before ensuring the backend Secret."
        $status["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "backend_secret_ensure" -Label "Management backend Secret" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required          = $true
            namespace         = $PostgresNamespace
            secret_name       = $BackendSecretName
            management_status = [string]$ManagementCluster["status"]
        }
        return $status
    }

    $namespaceResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "get", "namespace", $PostgresNamespace, "--output", "name") -TimeoutSeconds 20
    if ($namespaceResult.exit_code -ne 0 -or $namespaceResult.timed_out) {
        $status["status"] = "error"
        $status["message"] = "Namespace devdeploy was not found in devdeploy-mgmt. Run -BootstrapManagementPostgres first."
        $status["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "backend_secret_namespace" -Label "Backend Secret namespace" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required  = $true
            namespace = $PostgresNamespace
        }
        return $status
    }

    Add-Check -Id "backend_secret_namespace" -Label "Backend Secret namespace" -Status "ok" -Message "Namespace devdeploy exists in devdeploy-mgmt." -Details @{
        required  = $true
        namespace = $PostgresNamespace
    }

    $postgresSecretCandidates = New-Object System.Collections.Generic.List[string]
    $postgresSecretCandidates.Add("$PostgresRelease-postgresql") | Out-Null
    $postgresSecretsResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $PostgresNamespace, "get", "secret", "--selector", "app.kubernetes.io/instance=$PostgresRelease", "--output", "name") -TimeoutSeconds 20
    if ($postgresSecretsResult.exit_code -eq 0 -and -not $postgresSecretsResult.timed_out) {
        foreach ($secretReference in @($postgresSecretsResult.stdout -split "\s+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            $candidateName = ([string]$secretReference) -replace '^secret/', ''
            if (-not [string]::IsNullOrWhiteSpace($candidateName) -and -not $postgresSecretCandidates.Contains($candidateName)) {
                $postgresSecretCandidates.Add($candidateName) | Out-Null
            }
        }
    }

    $postgresPassword = ""
    $postgresSecretName = ""
    $postgresPasswordKey = ""
    foreach ($candidateName in $postgresSecretCandidates) {
        $keyResult = Get-SecretKeyNames -SecretName $candidateName
        if (-not $keyResult.success) {
            continue
        }

        foreach ($candidateKey in @("password", "postgres-password")) {
            if (@($keyResult.keys) -contains $candidateKey) {
                $passwordResult = Get-DecodedSecretValue -SecretName $candidateName -Key $candidateKey
                if ($passwordResult.success -and -not [string]::IsNullOrWhiteSpace([string]$passwordResult.value)) {
                    $postgresPassword = [string]$passwordResult.value
                    $postgresSecretName = [string]$candidateName
                    $postgresPasswordKey = [string]$candidateKey
                    break
                }
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($postgresPassword)) {
            break
        }
    }

    if ([string]::IsNullOrWhiteSpace($postgresPassword)) {
        $status["status"] = "error"
        $status["message"] = "The PostgreSQL runtime Secret or a supported password key could not be verified. Run -BootstrapManagementPostgres and retry."
        $status["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "backend_secret_postgres_source" -Label "PostgreSQL Secret source" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required  = $true
            namespace = $PostgresNamespace
            release   = $PostgresRelease
        }
        return $status
    }

    Add-Check -Id "backend_secret_postgres_source" -Label "PostgreSQL Secret source" -Status "ok" -Message "PostgreSQL runtime Secret and password key were verified without exposing their value." -Details @{
        required       = $true
        namespace      = $PostgresNamespace
        secret_name    = $postgresSecretName
        password_key   = $postgresPasswordKey
    }

    $backendSecretExistsResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $PostgresNamespace, "get", "secret", $BackendSecretName, "--output", "name") -TimeoutSeconds 20
    $backendSecretExists = [bool]($backendSecretExistsResult.exit_code -eq 0 -and -not $backendSecretExistsResult.timed_out)
    $jwtSecret = ""
    $githubWorkflowToken = ""

    if ($backendSecretExists) {
        $existingKeysResult = Get-SecretKeyNames -SecretName $BackendSecretName
        if (-not $existingKeysResult.success) {
            $status["status"] = "error"
            $status["message"] = "Existing devdeploy-backend-secret could not be read safely; no Secret changes were made."
            $status["checked_at"] = [string](Get-Timestamp)
            Add-Check -Id "backend_secret_existing" -Label "Existing backend Secret" -Status "failed" -Message ([string]$status["message"]) -Details @{
                required    = $true
                namespace   = $PostgresNamespace
                secret_name = $BackendSecretName
            }
            return $status
        }

        if (@($existingKeysResult.keys) -contains "JWT_SECRET_KEY") {
            $jwtResult = Get-DecodedSecretValue -SecretName $BackendSecretName -Key "JWT_SECRET_KEY"
            if (-not $jwtResult.success) {
                $status["status"] = "error"
                $status["message"] = "Existing JWT_SECRET_KEY could not be read safely; no Secret changes were made."
                $status["checked_at"] = [string](Get-Timestamp)
                Add-Check -Id "backend_secret_existing" -Label "Existing backend Secret" -Status "failed" -Message ([string]$status["message"]) -Details @{
                    required    = $true
                    namespace   = $PostgresNamespace
                    secret_name = $BackendSecretName
                }
                return $status
            }
            $jwtSecret = [string]$jwtResult.value
        }

        if (@($existingKeysResult.keys) -contains "GITHUB_WORKFLOW_TOKEN") {
            $tokenResult = Get-DecodedSecretValue -SecretName $BackendSecretName -Key "GITHUB_WORKFLOW_TOKEN"
            if (-not $tokenResult.success) {
                $status["status"] = "error"
                $status["message"] = "Existing GITHUB_WORKFLOW_TOKEN could not be read safely; no Secret changes were made."
                $status["checked_at"] = [string](Get-Timestamp)
                Add-Check -Id "backend_secret_existing" -Label "Existing backend Secret" -Status "failed" -Message ([string]$status["message"]) -Details @{
                    required    = $true
                    namespace   = $PostgresNamespace
                    secret_name = $BackendSecretName
                }
                return $status
            }
            $githubWorkflowToken = [string]$tokenResult.value
        }
    }

    if ([string]::IsNullOrWhiteSpace($jwtSecret) -or $jwtSecret.Length -lt 32) {
        $jwtSecret = New-CryptographicJwtSecret
    }

    $encodedPassword = [System.Uri]::EscapeDataString($postgresPassword)
    $databaseUrl = "postgresql://{0}:{1}@{2}:5432/{3}" -f $PostgresUsername, $encodedPassword, $PostgresServiceHost, $PostgresDatabase
    $secretDocument = [ordered]@{
        apiVersion = "v1"
        kind       = "Secret"
        metadata   = [ordered]@{
            name      = $BackendSecretName
            namespace = $PostgresNamespace
        }
        type       = "Opaque"
        stringData = [ordered]@{
            DATABASE_URL          = $databaseUrl
            JWT_SECRET_KEY        = $jwtSecret
            GITHUB_WORKFLOW_TOKEN = $githubWorkflowToken
        }
    }

    Write-LauncherLog "Creating or reconciling devdeploy-backend-secret in devdeploy-mgmt without logging Secret values."
    if (-not $Quiet) {
        Write-Host "Ensuring management backend runtime Secret in devdeploy-mgmt/devdeploy..."
    }

    $secretJson = $secretDocument | ConvertTo-Json -Depth 6 -Compress
    $applyResult = Invoke-SanitizedInputCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "apply", "--filename", "-") -StandardInput $secretJson -TimeoutSeconds 30
    $secretJson = $null
    $secretDocument = $null
    $postgresPassword = $null
    $databaseUrl = $null
    $jwtSecret = $null
    $githubWorkflowToken = $null

    if ($applyResult.exit_code -ne 0 -or $applyResult.timed_out) {
        $status["status"] = "error"
        $status["message"] = "devdeploy-backend-secret could not be reconciled. Review the sanitized launcher log and retry."
        $status["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "backend_secret_ensure" -Label "Management backend Secret" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required    = $true
            namespace   = $PostgresNamespace
            secret_name = $BackendSecretName
            error       = $applyResult.stderr
        }
        return $status
    }

    $finalKeysResult = Get-SecretKeyNames -SecretName $BackendSecretName
    $requiredKeys = @("DATABASE_URL", "JWT_SECRET_KEY", "GITHUB_WORKFLOW_TOKEN")
    $requiredKeysPresent = [bool]($finalKeysResult.success -and @($requiredKeys | Where-Object { @($finalKeysResult.keys) -notcontains $_ }).Count -eq 0)
    $finalDatabaseResult = Get-DecodedSecretValue -SecretName $BackendSecretName -Key "DATABASE_URL"
    $finalJwtResult = Get-DecodedSecretValue -SecretName $BackendSecretName -Key "JWT_SECRET_KEY"
    $finalTokenResult = Get-DecodedSecretValue -SecretName $BackendSecretName -Key "GITHUB_WORKFLOW_TOKEN"
    $expectedDatabasePrefix = "postgresql://{0}:" -f $PostgresUsername
    $expectedDatabaseSuffix = "@{0}:5432/{1}" -f $PostgresServiceHost, $PostgresDatabase
    $databaseConfigured = [bool]($finalDatabaseResult.success -and ([string]$finalDatabaseResult.value).StartsWith($expectedDatabasePrefix) -and ([string]$finalDatabaseResult.value).EndsWith($expectedDatabaseSuffix))
    $jwtConfigured = [bool]($finalJwtResult.success -and ([string]$finalJwtResult.value).Length -ge 32)
    $githubTokenConfigured = [bool]($finalTokenResult.success -and -not [string]::IsNullOrWhiteSpace([string]$finalTokenResult.value))

    $status["exists"] = $true
    $status["required_keys_present"] = $requiredKeysPresent
    $status["database_url_configured"] = $databaseConfigured
    $status["jwt_secret_configured"] = $jwtConfigured
    $status["github_workflow_token_configured"] = $githubTokenConfigured
    $status["ready"] = [bool]($requiredKeysPresent -and $databaseConfigured -and $jwtConfigured -and $finalTokenResult.success)
    $status["checked_at"] = [string](Get-Timestamp)

    if ($status["ready"]) {
        $status["status"] = "ready"
        $status["message"] = "Backend runtime Secret exists and required configuration is valid. GitHub workflow token may remain empty for V1."
        Add-Check -Id "backend_secret_ensure" -Label "Management backend Secret" -Status "ok" -Message ([string]$status["message"]) -Details @{
            required                         = $true
            namespace                        = $PostgresNamespace
            secret_name                      = $BackendSecretName
            required_keys_present            = $requiredKeysPresent
            database_url_configured          = $databaseConfigured
            jwt_secret_configured            = $jwtConfigured
            github_workflow_token_configured = $githubTokenConfigured
        }
    }
    else {
        $status["status"] = "error"
        $status["message"] = "Backend runtime Secret was applied, but required key or configuration verification failed."
        Add-Check -Id "backend_secret_ensure" -Label "Management backend Secret" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required                         = $true
            namespace                        = $PostgresNamespace
            secret_name                      = $BackendSecretName
            required_keys_present            = $requiredKeysPresent
            database_url_configured          = $databaseConfigured
            jwt_secret_configured            = $jwtConfigured
            github_workflow_token_configured = $githubTokenConfigured
        }
    }

    $finalDatabaseResult = $null
    $finalJwtResult = $null
    $finalTokenResult = $null
    return $status
}

function Invoke-VerifyManagementBackendSecret {
    param(
        [bool]$KubectlAvailable,

        [Parameter(Mandatory = $true)]
        [object]$ManagementCluster
    )

    $status = New-ManagementBackendSecretStatus
    $status["mode"] = "verify"

    if (-not $KubectlAvailable) {
        $status["status"] = "error"
        $status["message"] = "kubectl CLI is required to verify the management backend Secret."
        $status["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "backend_secret_verify" -Label "Management backend Secret verification" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required    = $true
            namespace   = $PostgresNamespace
            secret_name = $BackendSecretName
            read_only   = $true
        }
        return $status
    }

    if ([string]$ManagementCluster["status"] -ne "ready") {
        $status["status"] = "error"
        $status["message"] = "devdeploy-mgmt must exist, be API-reachable, and have a Ready node before verifying the backend Secret."
        $status["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "backend_secret_verify" -Label "Management backend Secret verification" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required          = $true
            namespace         = $PostgresNamespace
            secret_name       = $BackendSecretName
            management_status = [string]$ManagementCluster["status"]
            read_only         = $true
        }
        return $status
    }

    $namespaceResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "get", "namespace", $PostgresNamespace, "--output", "name") -TimeoutSeconds 20
    if ($namespaceResult.exit_code -ne 0 -or $namespaceResult.timed_out) {
        $status["status"] = "error"
        $status["message"] = "Namespace devdeploy was not found in devdeploy-mgmt."
        $status["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "backend_secret_namespace" -Label "Backend Secret namespace" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required  = $true
            namespace = $PostgresNamespace
            read_only = $true
        }
        return $status
    }

    Add-Check -Id "backend_secret_namespace" -Label "Backend Secret namespace" -Status "ok" -Message "Namespace devdeploy exists in devdeploy-mgmt." -Details @{
        required  = $true
        namespace = $PostgresNamespace
        read_only = $true
    }

    $secretResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $PostgresNamespace, "get", "secret", $BackendSecretName, "--output", "name") -TimeoutSeconds 20
    if ($secretResult.exit_code -ne 0 -or $secretResult.timed_out) {
        $status["status"] = "error"
        $status["message"] = "devdeploy-backend-secret does not exist. Run -EnsureManagementBackendSecret first."
        $status["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "backend_secret_verify" -Label "Management backend Secret verification" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required    = $true
            namespace   = $PostgresNamespace
            secret_name = $BackendSecretName
            read_only   = $true
        }
        return $status
    }

    $status["exists"] = $true
    $keysResult = Get-SecretKeyNames -SecretName $BackendSecretName
    $requiredKeys = @("DATABASE_URL", "JWT_SECRET_KEY", "GITHUB_WORKFLOW_TOKEN")
    $requiredKeysPresent = [bool]($keysResult.success -and @($requiredKeys | Where-Object { @($keysResult.keys) -notcontains $_ }).Count -eq 0)

    $databaseResult = [ordered]@{ success = $false; value = "" }
    $jwtResult = [ordered]@{ success = $false; value = "" }
    $tokenResult = [ordered]@{ success = $false; value = "" }

    if ($keysResult.success -and @($keysResult.keys) -contains "DATABASE_URL") {
        $databaseResult = Get-DecodedSecretValue -SecretName $BackendSecretName -Key "DATABASE_URL"
    }
    if ($keysResult.success -and @($keysResult.keys) -contains "JWT_SECRET_KEY") {
        $jwtResult = Get-DecodedSecretValue -SecretName $BackendSecretName -Key "JWT_SECRET_KEY"
    }
    if ($keysResult.success -and @($keysResult.keys) -contains "GITHUB_WORKFLOW_TOKEN") {
        $tokenResult = Get-DecodedSecretValue -SecretName $BackendSecretName -Key "GITHUB_WORKFLOW_TOKEN"
    }

    $expectedDatabasePrefix = "postgresql://{0}:" -f $PostgresUsername
    $expectedDatabaseSuffix = "@{0}:5432/{1}" -f $PostgresServiceHost, $PostgresDatabase
    $databaseConfigured = [bool]($databaseResult.success -and ([string]$databaseResult.value).StartsWith($expectedDatabasePrefix) -and ([string]$databaseResult.value).EndsWith($expectedDatabaseSuffix))
    $jwtConfigured = [bool]($jwtResult.success -and ([string]$jwtResult.value).Length -ge 32)
    $githubTokenConfigured = [bool]($tokenResult.success -and -not [string]::IsNullOrWhiteSpace([string]$tokenResult.value))
    $ready = [bool]($requiredKeysPresent -and $databaseConfigured -and $jwtConfigured -and $tokenResult.success)

    $status["required_keys_present"] = $requiredKeysPresent
    $status["database_url_configured"] = $databaseConfigured
    $status["jwt_secret_configured"] = $jwtConfigured
    $status["github_workflow_token_configured"] = $githubTokenConfigured
    $status["ready"] = $ready
    $status["checked_at"] = [string](Get-Timestamp)

    if ($ready) {
        $status["status"] = "ready"
        $status["message"] = "Backend runtime Secret exists and required configuration is valid. GitHub workflow token may remain empty for V1."
        Add-Check -Id "backend_secret_verify" -Label "Management backend Secret verification" -Status "ok" -Message ([string]$status["message"]) -Details @{
            required                         = $true
            namespace                        = $PostgresNamespace
            secret_name                      = $BackendSecretName
            required_keys_present            = $requiredKeysPresent
            database_url_configured          = $databaseConfigured
            jwt_secret_configured            = $jwtConfigured
            github_workflow_token_configured = $githubTokenConfigured
            read_only                        = $true
        }
    }
    else {
        $status["status"] = "error"
        $status["message"] = "Backend runtime Secret verification failed. Run -EnsureManagementBackendSecret to reconcile it after reviewing the sanitized status."
        Add-Check -Id "backend_secret_verify" -Label "Management backend Secret verification" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required                         = $true
            namespace                        = $PostgresNamespace
            secret_name                      = $BackendSecretName
            required_keys_present            = $requiredKeysPresent
            database_url_configured          = $databaseConfigured
            jwt_secret_configured            = $jwtConfigured
            github_workflow_token_configured = $githubTokenConfigured
            read_only                        = $true
        }
    }

    $databaseResult = $null
    $jwtResult = $null
    $tokenResult = $null
    return $status
}

function New-ManagementBackendBootstrapResult {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Backend,

        [Parameter(Mandatory = $true)]
        [object]$BackendImage,

        [Parameter(Mandatory = $true)]
        [object]$BackendSecret,

        [Parameter(Mandatory = $true)]
        [object]$Ingress,

        [Parameter(Mandatory = $true)]
        [object]$Postgres
    )

    return [ordered]@{
        backend        = $Backend
        backend_image  = $BackendImage
        backend_secret = $BackendSecret
        ingress        = $Ingress
        postgres       = $Postgres
    }
}

function Test-ManagementBackendHealth {
    param(
        [bool]$KubectlAvailable
    )

    if (-not $KubectlAvailable) {
        return [ordered]@{
            success = $false
            message = "kubectl is unavailable, so the backend health endpoint could not be checked."
        }
    }

    $listener = $null
    $portForward = $null
    try {
        $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback), 0
        $listener.Start()
        $localPort = [int]($listener.LocalEndpoint).Port
        $listener.Stop()
        $listener = $null

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "kubectl"
        $psi.Arguments = "--context kind-devdeploy-mgmt --namespace devdeploy port-forward service/devdeploy-backend {0}:8000 --address 127.0.0.1" -f $localPort
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true

        $portForward = New-Object System.Diagnostics.Process
        $portForward.StartInfo = $psi
        [void]$portForward.Start()

        $lastError = "Backend health endpoint did not become reachable before timeout."
        for ($attempt = 1; $attempt -le 20; $attempt++) {
            if ($portForward.HasExited) {
                $lastError = "kubectl port-forward exited before the backend health check completed."
                break
            }

            try {
                $response = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/api/v1/health" -f $localPort) -UseBasicParsing -TimeoutSec 3
                if ([int]$response.StatusCode -eq 200) {
                    $payload = $response.Content | ConvertFrom-Json
                    if ([string]$payload.status -eq "ok" -and [string]$payload.service -eq "devdeploy-backend") {
                        return [ordered]@{
                            success = $true
                            message = "Backend health endpoint returned the expected service status."
                        }
                    }
                    $lastError = "Backend health endpoint returned an unexpected response shape."
                }
            }
            catch {
                $lastError = "Backend health endpoint is not reachable yet."
            }

            Start-Sleep -Seconds 2
        }

        return [ordered]@{
            success = $false
            message = $lastError
        }
    }
    catch {
        return [ordered]@{
            success = $false
            message = "Backend health port-forward could not be started safely."
        }
    }
    finally {
        if ($null -ne $listener) {
            try { $listener.Stop() } catch { }
        }
        if ($null -ne $portForward) {
            try {
                if (-not $portForward.HasExited) {
                    $portForward.Kill()
                    [void]$portForward.WaitForExit(5000)
                }
            }
            catch {
                Write-LauncherLog "Backend health port-forward cleanup requires manual process verification."
            }
            finally {
                $portForward.Dispose()
            }
        }
    }
}

function Invoke-BootstrapManagementBackend {
    param(
        [bool]$KubectlAvailable,

        [bool]$DockerCliAvailable,

        [bool]$DockerDaemonReachable,

        [Parameter(Mandatory = $true)]
        [object]$ManagementCluster
    )

    $backend = New-ManagementBackendStatus
    $backendImage = New-ManagementBackendImageStatus
    $backendSecret = New-ManagementBackendSecretStatus
    $ingress = New-PlatformComponentStatus -Installed $null -Ready $null -Namespace $IngressNginxNamespace -Release $IngressNginxRelease -Status "unknown" -Message "Management ingress status has not been checked."
    $postgres = New-PlatformComponentStatus -Installed $null -Ready $null -Namespace $PostgresNamespace -Release $PostgresRelease -Status "unknown" -Message "PostgreSQL status has not been checked."

    if (-not $KubectlAvailable -or [string]$ManagementCluster["status"] -ne "ready") {
        $backend["status"] = "error"
        $backend["message"] = "kubectl and a Ready devdeploy-mgmt cluster are required before bootstrapping the backend."
        $backend["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_backend_prerequisites" -Label "Management backend prerequisites" -Status "failed" -Message ([string]$backend["message"]) -Details @{
            required          = $true
            target_cluster    = "devdeploy-mgmt"
            management_status = [string]$ManagementCluster["status"]
        }
        return New-ManagementBackendBootstrapResult -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
    }

    $namespaceResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "get", "namespace", $PostgresNamespace, "--output", "name") -TimeoutSeconds 20
    if ($namespaceResult.exit_code -ne 0 -or $namespaceResult.timed_out) {
        $backend["status"] = "error"
        $backend["message"] = "Namespace devdeploy does not exist. Run -BootstrapManagementPostgres first."
        $backend["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_backend_namespace" -Label "Management backend namespace" -Status "failed" -Message ([string]$backend["message"]) -Details @{
            required  = $true
            namespace = $PostgresNamespace
        }
        return New-ManagementBackendBootstrapResult -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
    }

    Add-Check -Id "management_backend_namespace" -Label "Management backend namespace" -Status "ok" -Message "Namespace devdeploy exists in devdeploy-mgmt." -Details @{
        required  = $true
        namespace = $PostgresNamespace
    }

    $ingressResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $IngressNginxNamespace, "get", "deployment", "ingress-nginx-controller", "--output", "jsonpath={.status.availableReplicas}") -TimeoutSeconds 20
    $ingressReady = [bool]($ingressResult.exit_code -eq 0 -and -not $ingressResult.timed_out -and [int]([string]$ingressResult.stdout) -ge 1)
    if (-not $ingressReady) {
        $ingress = New-PlatformComponentStatus -Installed $null -Ready $false -Namespace $IngressNginxNamespace -Release $IngressNginxRelease -Status "degraded" -Message "Management ingress-nginx controller is not Ready."
        $backend["status"] = "error"
        $backend["message"] = "Management ingress-nginx must be Ready before bootstrapping backend ingress."
        $backend["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_backend_ingress_prerequisite" -Label "Management ingress prerequisite" -Status "failed" -Message ([string]$backend["message"]) -Details @{
            required  = $true
            namespace = $IngressNginxNamespace
        }
        return New-ManagementBackendBootstrapResult -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
    }

    $ingress = New-PlatformComponentStatus -Installed $true -Ready $true -Namespace $IngressNginxNamespace -Release $IngressNginxRelease -Status "ready" -Message "Management ingress-nginx controller is Ready."
    Add-Check -Id "management_backend_ingress_prerequisite" -Label "Management ingress prerequisite" -Status "ok" -Message ([string]$ingress["message"]) -Details @{
        required  = $true
        namespace = $IngressNginxNamespace
    }

    $postgresStatefulSet = "$PostgresRelease-postgresql"
    $postgresResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $PostgresNamespace, "get", "statefulset", $postgresStatefulSet, "--output", "jsonpath={.status.readyReplicas}") -TimeoutSeconds 20
    $postgresServiceResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $PostgresNamespace, "get", "service", $postgresStatefulSet, "--output", "name") -TimeoutSeconds 20
    $postgresReady = [bool]($postgresResult.exit_code -eq 0 -and -not $postgresResult.timed_out -and [int]([string]$postgresResult.stdout) -ge 1 -and $postgresServiceResult.exit_code -eq 0 -and -not $postgresServiceResult.timed_out)
    if (-not $postgresReady) {
        $postgres = New-PlatformComponentStatus -Installed $null -Ready $false -Namespace $PostgresNamespace -Release $PostgresRelease -Status "degraded" -Message "Management PostgreSQL is not Ready."
        $backend["status"] = "error"
        $backend["message"] = "PostgreSQL must be Ready before bootstrapping the backend."
        $backend["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_backend_postgres_prerequisite" -Label "Management PostgreSQL prerequisite" -Status "failed" -Message ([string]$backend["message"]) -Details @{
            required  = $true
            namespace = $PostgresNamespace
            release   = $PostgresRelease
        }
        return New-ManagementBackendBootstrapResult -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
    }

    $postgres = New-PlatformComponentStatus -Installed $true -Ready $true -Namespace $PostgresNamespace -Release $PostgresRelease -Status "ready" -Message "Management PostgreSQL is Ready."
    Add-Check -Id "management_backend_postgres_prerequisite" -Label "Management PostgreSQL prerequisite" -Status "ok" -Message ([string]$postgres["message"]) -Details @{
        required  = $true
        namespace = $PostgresNamespace
        release   = $PostgresRelease
    }

    $backendSecret = Invoke-VerifyManagementBackendSecret -KubectlAvailable $KubectlAvailable -ManagementCluster $ManagementCluster
    if ([string]$backendSecret["status"] -ne "ready") {
        $backend["status"] = "error"
        $backend["message"] = "Backend runtime Secret must pass verification before backend manifests are applied."
        $backend["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_backend_secret_prerequisite" -Label "Management backend Secret prerequisite" -Status "failed" -Message ([string]$backend["message"]) -Details @{
            required    = $true
            namespace   = $PostgresNamespace
            secret_name = $BackendSecretName
        }
        return New-ManagementBackendBootstrapResult -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
    }

    Add-Check -Id "management_backend_secret_prerequisite" -Label "Management backend Secret prerequisite" -Status "ok" -Message "Backend runtime Secret passed read-only verification." -Details @{
        required    = $true
        namespace   = $PostgresNamespace
        secret_name = $BackendSecretName
    }

    $localImagePresent = Test-ManagementBackendImagePresent -DockerCliAvailable $DockerCliAvailable -DockerDaemonReachable $DockerDaemonReachable
    $backendImage["local_image_present"] = $localImagePresent
    Add-Check -Id "management_backend_image_prerequisite" -Label "Management backend image prerequisite" -Status $(if ($localImagePresent) { "ok" } else { "warning" }) -Message $(if ($localImagePresent) { "Local image devdeploy-backend:local exists; rollout readiness will verify cluster availability." } else { "Local image could not be verified; rollout readiness will determine whether the image is available in devdeploy-mgmt." }) -Details @{
        required = $false
        image    = $BackendImage
    }

    $kustomizationPath = Join-Path $BackendManifestPath "kustomization.yaml"
    if (-not (Test-Path -LiteralPath $BackendManifestPath -PathType Container) -or -not (Test-Path -LiteralPath $kustomizationPath -PathType Leaf)) {
        $backend["status"] = "error"
        $backend["message"] = "Backend manifest directory or kustomization.yaml is missing."
        $backend["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_backend_render" -Label "Management backend manifest render" -Status "failed" -Message ([string]$backend["message"]) -Details @{
            required       = $true
            manifests_path = $BackendManifestRelativePath
        }
        return New-ManagementBackendBootstrapResult -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
    }

    $kustomizationContent = Get-Content -Raw -LiteralPath $kustomizationPath
    if ($kustomizationContent -match '(?im)^\s*-\s*secret\.example\.yaml\s*$') {
        $backend["status"] = "error"
        $backend["message"] = "Backend kustomization includes secret.example.yaml; refusing to render or apply."
        $backend["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_backend_render" -Label "Management backend manifest render" -Status "failed" -Message ([string]$backend["message"]) -Details @{
            required       = $true
            manifests_path = $BackendManifestRelativePath
        }
        return New-ManagementBackendBootstrapResult -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
    }

    $renderResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("kustomize", $BackendManifestPath) -TimeoutSeconds 30
    if ($renderResult.exit_code -ne 0 -or $renderResult.timed_out) {
        $backend["status"] = "error"
        $backend["message"] = "Backend Kustomize render failed; no backend manifests were applied."
        $backend["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_backend_render" -Label "Management backend manifest render" -Status "failed" -Message ([string]$backend["message"]) -Details @{
            required       = $true
            manifests_path = $BackendManifestRelativePath
            error          = $renderResult.stderr
        }
        return New-ManagementBackendBootstrapResult -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
    }

    Add-Check -Id "management_backend_render" -Label "Management backend manifest render" -Status "ok" -Message "Backend manifests rendered successfully and secret.example.yaml is excluded." -Details @{
        required       = $true
        manifests_path = $BackendManifestRelativePath
    }

    Write-LauncherLog "Applying only platform/management/backend to devdeploy-mgmt."
    if (-not $Quiet) {
        Write-Host "Applying management backend manifests to devdeploy-mgmt..."
    }
    $applyResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "apply", "--kustomize", $BackendManifestPath) -TimeoutSeconds 60
    if ($applyResult.exit_code -ne 0 -or $applyResult.timed_out) {
        $backend["status"] = "error"
        $backend["message"] = "Backend manifest apply failed. No automatic cleanup was performed."
        $backend["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_backend_apply" -Label "Management backend manifest apply" -Status "failed" -Message ([string]$backend["message"]) -Details @{
            required       = $true
            manifests_path = $BackendManifestRelativePath
            target_cluster = "devdeploy-mgmt"
            error          = $applyResult.stderr
        }
        return New-ManagementBackendBootstrapResult -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
    }

    $backend["deployed"] = $true
    Add-Check -Id "management_backend_apply" -Label "Management backend manifest apply" -Status "ok" -Message "Applied only the management backend Kustomize resources to devdeploy-mgmt." -Details @{
        required       = $true
        manifests_path = $BackendManifestRelativePath
        target_cluster = "devdeploy-mgmt"
    }

    $rolloutResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $PostgresNamespace, "rollout", "status", "deployment/devdeploy-backend", "--timeout=240s") -TimeoutSeconds 270
    if ($rolloutResult.exit_code -ne 0 -or $rolloutResult.timed_out) {
        $backend["status"] = "error"
        $backend["message"] = "Backend Deployment did not become Available before timeout."
        $backend["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_backend_rollout" -Label "Management backend rollout" -Status "failed" -Message ([string]$backend["message"]) -Details @{
            required   = $true
            namespace  = $PostgresNamespace
            deployment = "devdeploy-backend"
            error      = $rolloutResult.stderr
        }
        return New-ManagementBackendBootstrapResult -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
    }

    $backend["rollout_succeeded"] = $true
    $backendImage["loaded_to_management_cluster"] = $true
    $backendImage["target_cluster"] = "devdeploy-mgmt"
    $backendImage["status"] = "ready"
    $backendImage["message"] = "Backend Deployment rollout verified devdeploy-backend:local availability in devdeploy-mgmt."
    $backendImage["checked_at"] = [string](Get-Timestamp)
    Add-Check -Id "management_backend_rollout" -Label "Management backend rollout" -Status "ok" -Message "Backend Deployment became Available." -Details @{
        required   = $true
        namespace  = $PostgresNamespace
        deployment = "devdeploy-backend"
        image      = $BackendImage
    }

    $serviceResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $PostgresNamespace, "get", "service", "devdeploy-backend", "--output", "name") -TimeoutSeconds 20
    $ingressResourceResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $PostgresNamespace, "get", "ingress", "devdeploy-backend", "--output", "name") -TimeoutSeconds 20
    if ($serviceResult.exit_code -ne 0 -or $serviceResult.timed_out -or $ingressResourceResult.exit_code -ne 0 -or $ingressResourceResult.timed_out) {
        $backend["status"] = "error"
        $backend["message"] = "Backend rollout succeeded, but Service or Ingress verification failed."
        $backend["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_backend_resources" -Label "Management backend resources" -Status "failed" -Message ([string]$backend["message"]) -Details @{
            required        = $true
            namespace       = $PostgresNamespace
            service_exists  = [bool]($serviceResult.exit_code -eq 0 -and -not $serviceResult.timed_out)
            ingress_exists  = [bool]($ingressResourceResult.exit_code -eq 0 -and -not $ingressResourceResult.timed_out)
        }
        return New-ManagementBackendBootstrapResult -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
    }

    Add-Check -Id "management_backend_resources" -Label "Management backend resources" -Status "ok" -Message "Backend Service and Ingress exist in namespace devdeploy." -Details @{
        required  = $true
        namespace = $PostgresNamespace
        service   = "devdeploy-backend"
        ingress   = "devdeploy-backend"
    }

    $healthResult = Test-ManagementBackendHealth -KubectlAvailable $KubectlAvailable
    $backend["health_check_succeeded"] = [bool]$healthResult.success
    $backend["ready"] = $true
    $backend["checked_at"] = [string](Get-Timestamp)
    if ($healthResult.success) {
        $backend["status"] = "ready"
        $backend["message"] = "DevDeploy backend is deployed, Available, and healthy in devdeploy-mgmt."
        Add-Check -Id "management_backend_health" -Label "Management backend health" -Status "ok" -Message ([string]$healthResult.message) -Details @{
            required = $false
            endpoint = "/api/v1/health"
            method   = "temporary_port_forward"
        }
    }
    else {
        $backend["status"] = "warning"
        $backend["message"] = "DevDeploy backend is Available, but the temporary port-forward health check did not succeed."
        Add-Check -Id "management_backend_health" -Label "Management backend health" -Status "warning" -Message ([string]$healthResult.message) -Details @{
            required = $false
            endpoint = "/api/v1/health"
            method   = "temporary_port_forward"
        }
    }

    return New-ManagementBackendBootstrapResult -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
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

        [bool]$ManagementCreateMode = $false,

        [bool]$WorkloadCreateMode = $false,

        [bool]$ManagementIngressBootstrapMode = $false,

        [bool]$ManagementPostgresBootstrapMode = $false,

        [bool]$ManagementBackendImageBuildMode = $false,

        [bool]$ManagementBackendImageLoadMode = $false,

        [bool]$ManagementBackendSecretEnsureMode = $false,

        [bool]$ManagementBackendSecretVerifyMode = $false,

        [bool]$ManagementBackendBootstrapMode = $false
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
    elseif ($WorkloadCreateMode -and $workloadExists) {
        $status = "ok"
        $message = "devdeploy-workload already exists and will be verified instead of recreated."
    }
    elseif ($WorkloadCreateMode -and $mgmtExists) {
        $status = "ok"
        $message = "devdeploy-mgmt already exists. This mode will create or verify only devdeploy-workload."
    }
    elseif ($ManagementIngressBootstrapMode -and $mgmtExists) {
        $status = "ok"
        $message = "devdeploy-mgmt already exists. This mode will install or verify only management ingress-nginx."
    }
    elseif ($ManagementPostgresBootstrapMode -and $mgmtExists) {
        $status = "ok"
        $message = "devdeploy-mgmt already exists. This mode will install or verify only management PostgreSQL."
    }
    elseif ($ManagementBackendImageBuildMode -and ($mgmtExists -or $workloadExists)) {
        $status = "ok"
        $message = "Existing DevDeploy clusters were detected. Backend image build mode does not use, modify, or delete them."
    }
    elseif ($ManagementBackendImageLoadMode -and $mgmtExists) {
        $status = "ok"
        $message = "devdeploy-mgmt exists. Backend image load mode targets only this management cluster."
    }
    elseif ($ManagementBackendSecretEnsureMode -and $mgmtExists) {
        $status = "ok"
        $message = "devdeploy-mgmt exists. Backend Secret ensure mode targets only this management cluster."
    }
    elseif ($ManagementBackendSecretVerifyMode -and $mgmtExists) {
        $status = "ok"
        $message = "devdeploy-mgmt exists. Backend Secret verify mode performs read-only checks only in this management cluster."
    }
    elseif ($ManagementBackendBootstrapMode -and $mgmtExists) {
        $status = "ok"
        $message = "devdeploy-mgmt exists. Backend bootstrap mode applies only management backend platform manifests to this cluster."
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

function Test-WorkloadClusterExists {
    param(
        [bool]$KindAvailable
    )

    $clusterResult = Get-KindClusterNames -KindAvailable $KindAvailable
    if (-not $clusterResult.success) {
        Add-Check -Id "workload_cluster_exists" -Label "Workload cluster exists" -Status "failed" -Message "Could not verify whether devdeploy-workload exists." -Details @{
            required     = $true
            cluster_name = "devdeploy-workload"
            error        = Protect-LogText $clusterResult.error
        }
        return $false
    }

    $exists = @($clusterResult.clusters) -contains "devdeploy-workload"
    if ($exists) {
        Add-Check -Id "workload_cluster_exists" -Label "Workload cluster exists" -Status "ok" -Message "devdeploy-workload already exists." -Details @{
            required     = $true
            cluster_name = "devdeploy-workload"
            exists       = $true
        }
        return $true
    }

    Add-Check -Id "workload_cluster_exists" -Label "Workload cluster exists" -Status "ok" -Message "devdeploy-workload does not exist yet and can be created by this explicit mode." -Details @{
        required     = $true
        cluster_name = "devdeploy-workload"
        exists       = $false
    }
    return $false
}

function Invoke-WorkloadClusterCreate {
    param(
        [bool]$AlreadyExists
    )

    if ($AlreadyExists) {
        Add-Check -Id "workload_cluster_create" -Label "Workload cluster create" -Status "skipped" -Message "devdeploy-workload already exists, so creation was skipped." -Details @{
            required     = $false
            cluster_name = "devdeploy-workload"
            created      = $false
            skipped      = "already_exists"
        }
        return $true
    }

    Write-LauncherLog "Creating devdeploy-workload with kind. No Kubernetes manifests or Helm charts will be installed."
    $result = Invoke-ReadOnlyCommand -FileName "kind" -Arguments @("create", "cluster", "--config", $WorkloadKindConfigPath) -TimeoutSeconds 300
    if ($result.exit_code -eq 0 -and -not $result.timed_out) {
        Add-Check -Id "workload_cluster_create" -Label "Workload cluster create" -Status "ok" -Message "Created devdeploy-workload with kind." -Details @{
            required     = $true
            cluster_name = "devdeploy-workload"
            config_path  = $WorkloadKindConfigPath
            created      = $true
        }
        return $true
    }

    $message = "kind failed to create devdeploy-workload. No automatic cleanup was performed."
    if ($result.timed_out) {
        $message = "kind create cluster timed out for devdeploy-workload. No automatic cleanup was performed."
    }

    Add-Check -Id "workload_cluster_create" -Label "Workload cluster create" -Status "failed" -Message $message -Details @{
        required     = $true
        cluster_name = "devdeploy-workload"
        config_path  = $WorkloadKindConfigPath
        error        = $result.stderr
    }
    return $false
}

function Test-WorkloadClusterVerify {
    param(
        [bool]$KindAvailable,

        [bool]$KubectlAvailable
    )

    $clusterResult = Get-KindClusterNames -KindAvailable $KindAvailable
    if (-not $clusterResult.success -or -not (@($clusterResult.clusters) -contains "devdeploy-workload")) {
        Add-Check -Id "workload_cluster_verify" -Label "Workload cluster verify" -Status "failed" -Message "devdeploy-workload could not be found during verification." -Details @{
            required     = $true
            cluster_name = "devdeploy-workload"
            error        = Protect-LogText $clusterResult.error
        }
        return
    }

    if (-not $KubectlAvailable) {
        Add-Check -Id "workload_cluster_verify" -Label "Workload cluster verify" -Status "failed" -Message "kubectl is required to verify devdeploy-workload nodes." -Details @{
            required     = $true
            cluster_name = "devdeploy-workload"
            context      = "kind-devdeploy-workload"
        }
        return
    }

    $contextResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("config", "get-contexts", "kind-devdeploy-workload", "--no-headers") -TimeoutSeconds 8
    if ($contextResult.exit_code -ne 0 -or $contextResult.timed_out -or [string]::IsNullOrWhiteSpace($contextResult.stdout)) {
        Add-Check -Id "workload_cluster_verify" -Label "Workload cluster verify" -Status "failed" -Message "kubectl context kind-devdeploy-workload is not usable." -Details @{
            required     = $true
            cluster_name = "devdeploy-workload"
            context      = "kind-devdeploy-workload"
            error        = $contextResult.stderr
        }
        return
    }

    $lastError = ""
    $lastNodeCount = 0
    $lastReadyCount = 0

    for ($attempt = 1; $attempt -le 12; $attempt++) {
        $nodesResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "get", "nodes", "--no-headers") -TimeoutSeconds 20
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
                    Add-Check -Id "workload_cluster_verify" -Label "Workload cluster verify" -Status "ok" -Message "devdeploy-workload exists and all nodes are Ready." -Details @{
                        required     = $true
                        cluster_name = "devdeploy-workload"
                        context      = "kind-devdeploy-workload"
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
        Add-Check -Id "workload_cluster_verify" -Label "Workload cluster verify" -Status "warning" -Message "devdeploy-workload exists, but not all nodes are Ready yet." -Details @{
            required     = $true
            cluster_name = "devdeploy-workload"
            context      = "kind-devdeploy-workload"
            node_count   = [int]$lastNodeCount
            ready_nodes  = [int]$lastReadyCount
        }
        return
    }

    Add-Check -Id "workload_cluster_verify" -Label "Workload cluster verify" -Status "failed" -Message "kubectl could not read nodes from devdeploy-workload." -Details @{
        required     = $true
        cluster_name = "devdeploy-workload"
        context      = "kind-devdeploy-workload"
        error        = Protect-LogText $lastError
    }
}

function Add-SkippedWorkloadClusterStages {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Reason
    )

    Add-Check -Id "workload_cluster_exists" -Label "Workload cluster exists" -Status "skipped" -Message $Reason -Details @{
        required     = $true
        cluster_name = "devdeploy-workload"
    }
    Add-Check -Id "workload_cluster_create" -Label "Workload cluster create" -Status "skipped" -Message $Reason -Details @{
        required     = $true
        cluster_name = "devdeploy-workload"
    }
    Add-Check -Id "workload_cluster_verify" -Label "Workload cluster verify" -Status "skipped" -Message $Reason -Details @{
        required     = $true
        cluster_name = "devdeploy-workload"
    }
}

function New-ManagementClusterStatus {
    param(
        [bool]$KindAvailable,

        [bool]$KubectlAvailable
    )

    $checkedAt = [string](Get-Timestamp)
    $base = [ordered]@{
        name          = "devdeploy-mgmt"
        context       = "kind-devdeploy-mgmt"
        exists        = $false
        api_reachable = $null
        node_ready    = $null
        ready_nodes   = 0
        total_nodes   = 0
        status        = "unknown"
        message       = "Management cluster status could not be determined safely."
        checked_at    = $checkedAt
    }

    if (-not $KindAvailable) {
        $base["message"] = "kind CLI is not available, so management cluster status could not be determined."
        Add-Check -Id "management_cluster_status" -Label "Management cluster status" -Status "warning" -Message ([string]$base["message"]) -Details @{
            required     = $false
            cluster_name = "devdeploy-mgmt"
            status       = "unknown"
        }
        return $base
    }

    $clusterResult = Get-KindClusterNames -KindAvailable $KindAvailable
    if (-not $clusterResult.success) {
        $base["message"] = "Could not list kind clusters, so management cluster status is unknown."
        Add-Check -Id "management_cluster_status" -Label "Management cluster status" -Status "warning" -Message ([string]$base["message"]) -Details @{
            required     = $false
            cluster_name = "devdeploy-mgmt"
            status       = "unknown"
            error        = Protect-LogText $clusterResult.error
        }
        return $base
    }

    $exists = @($clusterResult.clusters) -contains "devdeploy-mgmt"
    if (-not $exists) {
        $base["status"] = "missing"
        $base["message"] = "Management cluster devdeploy-mgmt does not exist yet."
        Add-Check -Id "management_cluster_status" -Label "Management cluster status" -Status "warning" -Message ([string]$base["message"]) -Details @{
            required     = $false
            cluster_name = "devdeploy-mgmt"
            status       = "missing"
        }
        return $base
    }

    $base["exists"] = $true

    if (-not $KubectlAvailable) {
        $base["api_reachable"] = $false
        $base["node_ready"] = $null
        $base["status"] = "degraded"
        $base["message"] = "devdeploy-mgmt exists, but kubectl is not available for API and node verification."
        Add-Check -Id "management_cluster_status" -Label "Management cluster status" -Status "warning" -Message ([string]$base["message"]) -Details @{
            required     = $false
            cluster_name = "devdeploy-mgmt"
            context      = "kind-devdeploy-mgmt"
            status       = "degraded"
        }
        return $base
    }

    $nodesResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "get", "nodes", "--no-headers") -TimeoutSeconds 20
    if ($nodesResult.exit_code -ne 0 -or $nodesResult.timed_out -or [string]::IsNullOrWhiteSpace($nodesResult.stdout)) {
        $base["api_reachable"] = $false
        $base["node_ready"] = $false
        $base["status"] = "degraded"
        $base["message"] = "devdeploy-mgmt exists, but kubectl could not read nodes from the cluster."
        Add-Check -Id "management_cluster_status" -Label "Management cluster status" -Status "warning" -Message ([string]$base["message"]) -Details @{
            required     = $false
            cluster_name = "devdeploy-mgmt"
            context      = "kind-devdeploy-mgmt"
            status       = "degraded"
            error        = $nodesResult.stderr
        }
        return $base
    }

    try {
        $nodes = @($nodesResult.stdout -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $readyNodes = @($nodes | Where-Object {
                $columns = @($_ -split "\s+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                $columns.Count -ge 2 -and $columns[1] -eq "Ready"
            })

        $base["api_reachable"] = $true
        $base["ready_nodes"] = [int]$readyNodes.Count
        $base["total_nodes"] = [int]$nodes.Count
        $base["node_ready"] = [bool]($readyNodes.Count -gt 0)

        if ($nodes.Count -gt 0 -and $readyNodes.Count -gt 0) {
            $base["status"] = "ready"
            $base["message"] = "Management cluster devdeploy-mgmt is reachable and has Ready node capacity."
            Add-Check -Id "management_cluster_status" -Label "Management cluster status" -Status "ok" -Message ([string]$base["message"]) -Details @{
                required     = $false
                cluster_name = "devdeploy-mgmt"
                context      = "kind-devdeploy-mgmt"
                status       = "ready"
                ready_nodes  = [int]$readyNodes.Count
                total_nodes  = [int]$nodes.Count
            }
            return $base
        }

        $base["status"] = "degraded"
        $base["message"] = "devdeploy-mgmt is reachable, but no nodes are Ready."
        Add-Check -Id "management_cluster_status" -Label "Management cluster status" -Status "warning" -Message ([string]$base["message"]) -Details @{
            required     = $false
            cluster_name = "devdeploy-mgmt"
            context      = "kind-devdeploy-mgmt"
            status       = "degraded"
            ready_nodes  = [int]$readyNodes.Count
            total_nodes  = [int]$nodes.Count
        }
        return $base
    }
    catch {
        $base["api_reachable"] = $true
        $base["node_ready"] = $null
        $base["status"] = "unknown"
        $base["message"] = "devdeploy-mgmt API is reachable, but node readiness could not be parsed safely."
        Add-Check -Id "management_cluster_status" -Label "Management cluster status" -Status "warning" -Message ([string]$base["message"]) -Details @{
            required     = $false
            cluster_name = "devdeploy-mgmt"
            context      = "kind-devdeploy-mgmt"
            status       = "unknown"
            error        = Protect-LogText $_.Exception.Message
        }
        return $base
    }
}

function New-WorkloadClusterStatus {
    param(
        [bool]$KindAvailable,

        [bool]$KubectlAvailable
    )

    $checkedAt = [string](Get-Timestamp)
    $base = [ordered]@{
        name          = "devdeploy-workload"
        context       = "kind-devdeploy-workload"
        exists        = $false
        api_reachable = $null
        node_ready    = $null
        ready_nodes   = 0
        total_nodes   = 0
        status        = "unknown"
        message       = "Workload cluster status could not be determined safely."
        checked_at    = $checkedAt
    }

    if (-not $KindAvailable) {
        $base["message"] = "kind CLI is not available, so workload cluster status could not be determined."
        Add-Check -Id "workload_cluster_status" -Label "Workload cluster status" -Status "warning" -Message ([string]$base["message"]) -Details @{
            required     = $false
            cluster_name = "devdeploy-workload"
            status       = "unknown"
        }
        return $base
    }

    $clusterResult = Get-KindClusterNames -KindAvailable $KindAvailable
    if (-not $clusterResult.success) {
        $base["message"] = "Could not list kind clusters, so workload cluster status is unknown."
        Add-Check -Id "workload_cluster_status" -Label "Workload cluster status" -Status "warning" -Message ([string]$base["message"]) -Details @{
            required     = $false
            cluster_name = "devdeploy-workload"
            status       = "unknown"
            error        = Protect-LogText $clusterResult.error
        }
        return $base
    }

    $exists = @($clusterResult.clusters) -contains "devdeploy-workload"
    if (-not $exists) {
        $base["status"] = "missing"
        $base["message"] = "Workload cluster devdeploy-workload does not exist yet."
        Add-Check -Id "workload_cluster_status" -Label "Workload cluster status" -Status "warning" -Message ([string]$base["message"]) -Details @{
            required     = $false
            cluster_name = "devdeploy-workload"
            status       = "missing"
        }
        return $base
    }

    $base["exists"] = $true

    if (-not $KubectlAvailable) {
        $base["api_reachable"] = $false
        $base["node_ready"] = $null
        $base["status"] = "degraded"
        $base["message"] = "devdeploy-workload exists, but kubectl is not available for API and node verification."
        Add-Check -Id "workload_cluster_status" -Label "Workload cluster status" -Status "warning" -Message ([string]$base["message"]) -Details @{
            required     = $false
            cluster_name = "devdeploy-workload"
            context      = "kind-devdeploy-workload"
            status       = "degraded"
        }
        return $base
    }

    $nodesResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "get", "nodes", "--no-headers") -TimeoutSeconds 20
    if ($nodesResult.exit_code -ne 0 -or $nodesResult.timed_out -or [string]::IsNullOrWhiteSpace($nodesResult.stdout)) {
        $base["api_reachable"] = $false
        $base["node_ready"] = $false
        $base["status"] = "degraded"
        $base["message"] = "devdeploy-workload exists, but kubectl could not read nodes from the cluster."
        Add-Check -Id "workload_cluster_status" -Label "Workload cluster status" -Status "warning" -Message ([string]$base["message"]) -Details @{
            required     = $false
            cluster_name = "devdeploy-workload"
            context      = "kind-devdeploy-workload"
            status       = "degraded"
            error        = $nodesResult.stderr
        }
        return $base
    }

    try {
        $nodes = @($nodesResult.stdout -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $readyNodes = @($nodes | Where-Object {
                $columns = @($_ -split "\s+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                $columns.Count -ge 2 -and $columns[1] -eq "Ready"
            })

        $base["api_reachable"] = $true
        $base["ready_nodes"] = [int]$readyNodes.Count
        $base["total_nodes"] = [int]$nodes.Count
        $base["node_ready"] = [bool]($readyNodes.Count -gt 0)

        if ($nodes.Count -gt 0 -and $readyNodes.Count -gt 0) {
            $base["status"] = "ready"
            $base["message"] = "Workload cluster devdeploy-workload is reachable and has Ready node capacity."
            Add-Check -Id "workload_cluster_status" -Label "Workload cluster status" -Status "ok" -Message ([string]$base["message"]) -Details @{
                required     = $false
                cluster_name = "devdeploy-workload"
                context      = "kind-devdeploy-workload"
                status       = "ready"
                ready_nodes  = [int]$readyNodes.Count
                total_nodes  = [int]$nodes.Count
            }
            return $base
        }

        $base["status"] = "degraded"
        $base["message"] = "devdeploy-workload is reachable, but no nodes are Ready."
        Add-Check -Id "workload_cluster_status" -Label "Workload cluster status" -Status "warning" -Message ([string]$base["message"]) -Details @{
            required     = $false
            cluster_name = "devdeploy-workload"
            context      = "kind-devdeploy-workload"
            status       = "degraded"
            ready_nodes  = [int]$readyNodes.Count
            total_nodes  = [int]$nodes.Count
        }
        return $base
    }
    catch {
        $base["api_reachable"] = $true
        $base["node_ready"] = $null
        $base["status"] = "unknown"
        $base["message"] = "devdeploy-workload API is reachable, but node readiness could not be parsed safely."
        Add-Check -Id "workload_cluster_status" -Label "Workload cluster status" -Status "warning" -Message ([string]$base["message"]) -Details @{
            required     = $false
            cluster_name = "devdeploy-workload"
            context      = "kind-devdeploy-workload"
            status       = "unknown"
            error        = Protect-LogText $_.Exception.Message
        }
        return $base
    }
}

function New-PlatformComponentStatus {
    param(
        [AllowNull()]
        [object]$Installed,

        [AllowNull()]
        [object]$Ready,

        [Parameter(Mandatory = $true)]
        [string]$Namespace,

        [Parameter(Mandatory = $true)]
        [string]$Status,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [string]$Release = ""
    )

    $component = [ordered]@{
        installed = $Installed
        ready     = $Ready
        namespace = $Namespace
        status    = $Status
        message   = $Message
    }

    if (-not [string]::IsNullOrWhiteSpace($Release)) {
        $component["release"] = $Release
    }

    return $component
}

function New-NotStartedPlatformComponent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Namespace,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    return New-PlatformComponentStatus -Installed $null -Ready $null -Namespace $Namespace -Status "not_started" -Message $Message
}

function Get-ManagementIngressStatus {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ManagementCluster,

        [bool]$HelmAvailable,

        [bool]$KubectlAvailable
    )

    if ([string]$ManagementCluster["status"] -ne "ready") {
        return New-PlatformComponentStatus -Installed $null -Ready $null -Namespace $IngressNginxNamespace -Release $IngressNginxRelease -Status "unknown" -Message "Management ingress status cannot be determined until devdeploy-mgmt is ready."
    }

    if (-not $HelmAvailable -or -not $KubectlAvailable) {
        return New-PlatformComponentStatus -Installed $null -Ready $null -Namespace $IngressNginxNamespace -Release $IngressNginxRelease -Status "unknown" -Message "Management ingress status requires Helm and kubectl."
    }

    $releaseResult = Invoke-ReadOnlyCommand -FileName "helm" -Arguments @("--kube-context", "kind-devdeploy-mgmt", "list", "--namespace", $IngressNginxNamespace, "--filter", "^$IngressNginxRelease$", "--deployed", "--short") -TimeoutSeconds 20
    if ($releaseResult.exit_code -ne 0 -or $releaseResult.timed_out -or [string]::IsNullOrWhiteSpace($releaseResult.stdout)) {
        return New-PlatformComponentStatus -Installed $false -Ready $false -Namespace $IngressNginxNamespace -Release $IngressNginxRelease -Status "not_started" -Message "Management ingress-nginx Helm release is not installed yet."
    }

    $podsResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "get", "pods", "--namespace", $IngressNginxNamespace, "-l", "app.kubernetes.io/component=controller", "--no-headers") -TimeoutSeconds 20
    if ($podsResult.exit_code -ne 0 -or $podsResult.timed_out -or [string]::IsNullOrWhiteSpace($podsResult.stdout)) {
        return New-PlatformComponentStatus -Installed $true -Ready $false -Namespace $IngressNginxNamespace -Release $IngressNginxRelease -Status "degraded" -Message "Management ingress-nginx release exists, but controller pods are not readable."
    }

    try {
        $pods = @($podsResult.stdout -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $readyPods = @($pods | Where-Object {
                $columns = @($_ -split "\s+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                $columns.Count -ge 3 -and $columns[1] -match "^(\d+)/\1$" -and $columns[2] -eq "Running"
            })

        if ($readyPods.Count -gt 0) {
            return New-PlatformComponentStatus -Installed $true -Ready $true -Namespace $IngressNginxNamespace -Release $IngressNginxRelease -Status "ready" -Message "Management ingress-nginx is installed and controller pods are Ready."
        }

        return New-PlatformComponentStatus -Installed $true -Ready $false -Namespace $IngressNginxNamespace -Release $IngressNginxRelease -Status "degraded" -Message "Management ingress-nginx is installed, but controller pods are not Ready yet."
    }
    catch {
        return New-PlatformComponentStatus -Installed $true -Ready $null -Namespace $IngressNginxNamespace -Release $IngressNginxRelease -Status "unknown" -Message "Management ingress-nginx pod readiness could not be parsed safely."
    }
}

function Get-DevDeployNamespaceStatus {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ManagementCluster,

        [bool]$KubectlAvailable
    )

    $base = [ordered]@{
        exists  = $false
        status  = "unknown"
        message = "DevDeploy namespace status could not be determined safely."
    }

    if ([string]$ManagementCluster["status"] -ne "ready") {
        $base["message"] = "DevDeploy namespace status cannot be determined until devdeploy-mgmt is ready."
        return $base
    }

    if (-not $KubectlAvailable) {
        $base["message"] = "kubectl is required to verify the devdeploy namespace."
        return $base
    }

    $namespaceResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "get", "namespace", $PostgresNamespace) -TimeoutSeconds 20
    if ($namespaceResult.exit_code -eq 0 -and -not $namespaceResult.timed_out) {
        $base["exists"] = $true
        $base["status"] = "ready"
        $base["message"] = "Namespace devdeploy exists in devdeploy-mgmt."
        return $base
    }

    $base["status"] = "missing"
    $base["message"] = "Namespace devdeploy does not exist yet."
    return $base
}

function Get-ManagementPostgresStatus {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ManagementCluster,

        [bool]$HelmAvailable,

        [bool]$KubectlAvailable
    )

    if ([string]$ManagementCluster["status"] -ne "ready") {
        return New-PlatformComponentStatus -Installed $null -Ready $null -Namespace $PostgresNamespace -Release $PostgresRelease -Status "unknown" -Message "PostgreSQL status cannot be determined until devdeploy-mgmt is ready."
    }

    if (-not $HelmAvailable -or -not $KubectlAvailable) {
        return New-PlatformComponentStatus -Installed $null -Ready $null -Namespace $PostgresNamespace -Release $PostgresRelease -Status "unknown" -Message "PostgreSQL status requires Helm and kubectl."
    }

    $releaseResult = Invoke-ReadOnlyCommand -FileName "helm" -Arguments @("--kube-context", "kind-devdeploy-mgmt", "list", "--namespace", $PostgresNamespace, "--filter", "^$PostgresRelease$", "--deployed", "--short") -TimeoutSeconds 20
    if ($releaseResult.exit_code -ne 0 -or $releaseResult.timed_out -or [string]::IsNullOrWhiteSpace($releaseResult.stdout)) {
        return New-PlatformComponentStatus -Installed $false -Ready $false -Namespace $PostgresNamespace -Release $PostgresRelease -Status "not_started" -Message "PostgreSQL Helm release is not installed yet."
    }

    $podsResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "get", "pods", "--namespace", $PostgresNamespace, "-l", "app.kubernetes.io/instance=$PostgresRelease", "--no-headers") -TimeoutSeconds 20
    if ($podsResult.exit_code -ne 0 -or $podsResult.timed_out -or [string]::IsNullOrWhiteSpace($podsResult.stdout)) {
        return New-PlatformComponentStatus -Installed $true -Ready $false -Namespace $PostgresNamespace -Release $PostgresRelease -Status "degraded" -Message "PostgreSQL release exists, but pods are not readable."
    }

    $serviceResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "get", "svc", "--namespace", $PostgresNamespace, "-l", "app.kubernetes.io/instance=$PostgresRelease") -TimeoutSeconds 20
    if ($serviceResult.exit_code -ne 0 -or $serviceResult.timed_out) {
        return New-PlatformComponentStatus -Installed $true -Ready $false -Namespace $PostgresNamespace -Release $PostgresRelease -Status "degraded" -Message "PostgreSQL release exists, but service verification failed."
    }

    try {
        $pods = @($podsResult.stdout -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $readyPods = @($pods | Where-Object {
                $columns = @($_ -split "\s+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                $columns.Count -ge 3 -and $columns[1] -match "^(\d+)/\1$" -and $columns[2] -eq "Running"
            })

        if ($readyPods.Count -gt 0) {
            return New-PlatformComponentStatus -Installed $true -Ready $true -Namespace $PostgresNamespace -Release $PostgresRelease -Status "ready" -Message "PostgreSQL is installed and pod readiness is verified."
        }

        return New-PlatformComponentStatus -Installed $true -Ready $false -Namespace $PostgresNamespace -Release $PostgresRelease -Status "degraded" -Message "PostgreSQL is installed, but pods are not Ready yet."
    }
    catch {
        return New-PlatformComponentStatus -Installed $true -Ready $null -Namespace $PostgresNamespace -Release $PostgresRelease -Status "unknown" -Message "PostgreSQL pod readiness could not be parsed safely."
    }
}

function New-PlatformBootstrapStatus {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ManagementCluster,

        [bool]$HelmAvailable,

        [bool]$KubectlAvailable,

        [Parameter(Mandatory = $true)]
        [object]$BackendImageStatus,

        [Parameter(Mandatory = $true)]
        [object]$BackendSecretStatus,

        [Parameter(Mandatory = $true)]
        [object]$BackendStatus,

        [AllowNull()]
        [object]$IngressStatusOverride = $null,

        [AllowNull()]
        [object]$PostgresStatusOverride = $null
    )

    $ingress = if ($null -ne $IngressStatusOverride) { $IngressStatusOverride } else { Get-ManagementIngressStatus -ManagementCluster $ManagementCluster -HelmAvailable $HelmAvailable -KubectlAvailable $KubectlAvailable }
    $postgres = if ($null -ne $PostgresStatusOverride) { $PostgresStatusOverride } else { Get-ManagementPostgresStatus -ManagementCluster $ManagementCluster -HelmAvailable $HelmAvailable -KubectlAvailable $KubectlAvailable }
    $devdeployNamespace = Get-DevDeployNamespaceStatus -ManagementCluster $ManagementCluster -KubectlAvailable $KubectlAvailable
    $status = "not_started"
    $message = "Management platform bootstrap has not started yet."

    $ingressFailedChecks = @($Checks | Where-Object { $_.id -like "management_ingress_*" -and $_.status -eq "failed" }).Count
    $postgresFailedChecks = @($Checks | Where-Object { $_.id -like "management_postgres_*" -and $_.status -eq "failed" }).Count
    $backendFailedChecks = @($Checks | Where-Object { $_.id -like "management_backend_*" -and $_.status -eq "failed" }).Count

    if ($ingressFailedChecks -gt 0 -and [string]$ingress["status"] -ne "ready") {
        $ingress["status"] = "failed"
        $ingress["installed"] = $null
        $ingress["ready"] = $false
        $ingress["message"] = "Management ingress-nginx bootstrap failed. Check launcher logs and rerun the explicit bootstrap mode after resolving the issue."
        $status = "failed"
        $message = "Management ingress-nginx bootstrap failed."
    }
    elseif ($postgresFailedChecks -gt 0 -and [string]$postgres["status"] -ne "ready") {
        $postgres["status"] = "failed"
        $postgres["installed"] = $null
        $postgres["ready"] = $false
        $postgres["message"] = "PostgreSQL bootstrap failed. Check launcher logs and rerun the explicit bootstrap mode after resolving the issue."
        $status = "failed"
        $message = "PostgreSQL bootstrap failed."
    }
    elseif ($backendFailedChecks -gt 0 -and [string]$BackendStatus["status"] -ne "ready") {
        $status = "failed"
        $message = "Management backend bootstrap failed."
    }
    elseif ([string]$ingress["status"] -eq "ready" -and [string]$postgres["status"] -eq "ready" -and [string]$BackendStatus["status"] -in @("ready", "warning")) {
        $status = "partial"
        $message = "Management ingress, PostgreSQL, and backend are ready. Frontend and Argo CD are not installed yet."
    }
    elseif ([string]$ingress["status"] -eq "ready" -or [string]$postgres["status"] -eq "ready") {
        $status = "partial"
        $message = "Management platform bootstrap is partially ready. Frontend and Argo CD are not installed yet."
    }
    elseif ([string]$ingress["status"] -eq "degraded" -or [string]$postgres["status"] -eq "degraded") {
        $status = "degraded"
        $message = "One or more management platform components exist but are not fully ready."
    }
    elseif ([string]$ingress["status"] -eq "failed" -or [string]$postgres["status"] -eq "failed") {
        $status = "failed"
        $message = "Management platform bootstrap failed."
    }
    elseif ([string]$ingress["status"] -eq "unknown" -or [string]$postgres["status"] -eq "unknown") {
        $status = "unknown"
        $message = "Management platform bootstrap status could not be determined safely."
    }

    $platform = [ordered]@{
        status     = $status
        checked_at = [string](Get-Timestamp)
        message    = $message
        devdeploy_namespace = $devdeployNamespace
        components = [ordered]@{
            ingress_nginx = $ingress
            postgres      = $postgres
            backend_image = $BackendImageStatus
            backend_secret = $BackendSecretStatus
            backend       = $BackendStatus
            frontend      = New-NotStartedPlatformComponent -Namespace "devdeploy" -Message "Frontend bootstrap is not implemented yet."
            argocd        = New-NotStartedPlatformComponent -Namespace "argocd" -Message "Argo CD bootstrap is not implemented yet."
        }
    }

    $checkStatus = "warning"
    if ($status -eq "partial") {
        $checkStatus = "ok"
    }
    elseif ($status -eq "failed") {
        $checkStatus = "failed"
    }

    Add-Check -Id "platform_bootstrap_status" -Label "Platform bootstrap status" -Status $checkStatus -Message $message -Details @{
        required       = $false
        status         = $status
        ingress_status = [string]$ingress["status"]
        postgres_status = [string]$postgres["status"]
        backend_image_status = [string]$BackendImageStatus["status"]
        backend_secret_status = [string]$BackendSecretStatus["status"]
        backend_status = [string]$BackendStatus["status"]
    }

    return $platform
}

function Add-SkippedManagementIngressStages {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Reason
    )

    Add-Check -Id "management_ingress_helm_available" -Label "Management ingress Helm availability" -Status "skipped" -Message $Reason -Details @{
        required = $true
    }
    Add-Check -Id "management_ingress_namespace" -Label "Management ingress namespace" -Status "skipped" -Message $Reason -Details @{
        required  = $true
        namespace = $IngressNginxNamespace
    }
    Add-Check -Id "management_ingress_release" -Label "Management ingress release" -Status "skipped" -Message $Reason -Details @{
        required  = $true
        namespace = $IngressNginxNamespace
        release   = $IngressNginxRelease
    }
    Add-Check -Id "management_ingress_ready" -Label "Management ingress readiness" -Status "skipped" -Message $Reason -Details @{
        required  = $true
        namespace = $IngressNginxNamespace
        release   = $IngressNginxRelease
    }
}

function Invoke-ManagementIngressBootstrap {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ManagementCluster,

        [bool]$HelmAvailable,

        [bool]$KubectlAvailable
    )

    if ([string]$ManagementCluster["status"] -ne "ready") {
        Add-Check -Id "management_ingress_helm_available" -Label "Management ingress Helm availability" -Status "skipped" -Message "Helm check skipped because devdeploy-mgmt is not ready." -Details @{
            required = $true
        }
        Add-Check -Id "management_ingress_namespace" -Label "Management ingress namespace" -Status "skipped" -Message "Namespace check skipped because devdeploy-mgmt is not ready." -Details @{
            required  = $true
            namespace = $IngressNginxNamespace
        }
        Add-Check -Id "management_ingress_release" -Label "Management ingress release" -Status "failed" -Message "devdeploy-mgmt must be ready before installing management ingress-nginx." -Details @{
            required     = $true
            cluster_name = "devdeploy-mgmt"
            status       = [string]$ManagementCluster["status"]
        }
        Add-Check -Id "management_ingress_ready" -Label "Management ingress readiness" -Status "skipped" -Message "Readiness check skipped because ingress-nginx was not installed." -Details @{
            required = $true
        }
        return
    }

    if (-not $HelmAvailable) {
        Add-Check -Id "management_ingress_helm_available" -Label "Management ingress Helm availability" -Status "failed" -Message "Helm CLI is required for -BootstrapManagementIngress." -Details @{
            required = $true
            command  = "helm"
        }
        Add-Check -Id "management_ingress_release" -Label "Management ingress release" -Status "skipped" -Message "Helm release step skipped because Helm CLI is missing." -Details @{
            required = $true
        }
        Add-Check -Id "management_ingress_ready" -Label "Management ingress readiness" -Status "skipped" -Message "Readiness check skipped because Helm CLI is missing." -Details @{
            required = $true
        }
        return
    }

    if (-not $KubectlAvailable) {
        Add-Check -Id "management_ingress_helm_available" -Label "Management ingress Helm availability" -Status "ok" -Message "Helm CLI is available." -Details @{
            required = $true
            command  = "helm"
        }
        Add-Check -Id "management_ingress_release" -Label "Management ingress release" -Status "failed" -Message "kubectl is required to verify management ingress-nginx after Helm install." -Details @{
            required = $true
        }
        Add-Check -Id "management_ingress_ready" -Label "Management ingress readiness" -Status "skipped" -Message "Readiness check skipped because kubectl is missing." -Details @{
            required = $true
        }
        return
    }

    Add-Check -Id "management_ingress_helm_available" -Label "Management ingress Helm availability" -Status "ok" -Message "Helm CLI is available for explicit management ingress bootstrap." -Details @{
        required = $true
        command  = "helm"
    }

    $repoAdd = Invoke-ReadOnlyCommand -FileName "helm" -Arguments @("repo", "add", "ingress-nginx", "https://kubernetes.github.io/ingress-nginx") -TimeoutSeconds 60
    if ($repoAdd.exit_code -ne 0 -or $repoAdd.timed_out) {
        Add-Check -Id "management_ingress_release" -Label "Management ingress release" -Status "failed" -Message "Could not add or verify the ingress-nginx Helm repository." -Details @{
            required = $true
            error    = $repoAdd.stderr
        }
        Add-Check -Id "management_ingress_ready" -Label "Management ingress readiness" -Status "skipped" -Message "Readiness check skipped because Helm repository setup failed." -Details @{
            required = $true
        }
        return
    }

    $repoUpdate = Invoke-ReadOnlyCommand -FileName "helm" -Arguments @("repo", "update", "ingress-nginx") -TimeoutSeconds 120
    if ($repoUpdate.exit_code -ne 0 -or $repoUpdate.timed_out) {
        Add-Check -Id "management_ingress_release" -Label "Management ingress release" -Status "failed" -Message "Could not update the ingress-nginx Helm repository." -Details @{
            required = $true
            error    = $repoUpdate.stderr
        }
        Add-Check -Id "management_ingress_ready" -Label "Management ingress readiness" -Status "skipped" -Message "Readiness check skipped because Helm repository update failed." -Details @{
            required = $true
        }
        return
    }

    $helmArgs = @(
        "upgrade", "--install", $IngressNginxRelease, "ingress-nginx/ingress-nginx",
        "--version", $IngressNginxChartVersion,
        "--namespace", $IngressNginxNamespace,
        "--create-namespace",
        "--kube-context", "kind-devdeploy-mgmt",
        "--wait",
        "--timeout", "5m",
        "--set", "controller.hostPort.enabled=true",
        "--set", "controller.service.type=NodePort",
        "--set", "controller.ingressClassResource.default=true",
        "--set", "controller.watchIngressWithoutClass=true",
        "--set", "controller.admissionWebhooks.enabled=false"
    )

    Write-LauncherLog "Installing or verifying management ingress-nginx in devdeploy-mgmt with Helm."
    $installResult = Invoke-ReadOnlyCommand -FileName "helm" -Arguments $helmArgs -TimeoutSeconds 420
    if ($installResult.exit_code -ne 0 -or $installResult.timed_out) {
        $message = "Helm failed to install or upgrade management ingress-nginx. No automatic cleanup was performed."
        if ($installResult.timed_out) {
            $message = "Helm timed out while installing or upgrading management ingress-nginx. No automatic cleanup was performed."
        }

        Add-Check -Id "management_ingress_release" -Label "Management ingress release" -Status "failed" -Message $message -Details @{
            required      = $true
            namespace     = $IngressNginxNamespace
            release       = $IngressNginxRelease
            chart         = "ingress-nginx/ingress-nginx"
            chart_version = $IngressNginxChartVersion
            error         = $installResult.stderr
        }
        Add-Check -Id "management_ingress_ready" -Label "Management ingress readiness" -Status "skipped" -Message "Readiness check skipped because Helm install or upgrade failed." -Details @{
            required = $true
        }
        return
    }

    Add-Check -Id "management_ingress_release" -Label "Management ingress release" -Status "ok" -Message "ingress-nginx Helm release is installed or reconciled in devdeploy-mgmt." -Details @{
        required      = $true
        namespace     = $IngressNginxNamespace
        release       = $IngressNginxRelease
        chart         = "ingress-nginx/ingress-nginx"
        chart_version = $IngressNginxChartVersion
    }

    $namespaceResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "get", "namespace", $IngressNginxNamespace) -TimeoutSeconds 20
    if ($namespaceResult.exit_code -eq 0 -and -not $namespaceResult.timed_out) {
        Add-Check -Id "management_ingress_namespace" -Label "Management ingress namespace" -Status "ok" -Message "ingress-nginx namespace exists in devdeploy-mgmt." -Details @{
            required  = $true
            namespace = $IngressNginxNamespace
        }
    }
    else {
        Add-Check -Id "management_ingress_namespace" -Label "Management ingress namespace" -Status "failed" -Message "ingress-nginx namespace could not be verified in devdeploy-mgmt." -Details @{
            required  = $true
            namespace = $IngressNginxNamespace
            error     = $namespaceResult.stderr
        }
        Add-Check -Id "management_ingress_ready" -Label "Management ingress readiness" -Status "skipped" -Message "Readiness check skipped because namespace verification failed." -Details @{
            required = $true
        }
        return
    }

    $rolloutResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "rollout", "status", "deployment/ingress-nginx-controller", "--namespace", $IngressNginxNamespace, "--timeout=180s") -TimeoutSeconds 210
    if ($rolloutResult.exit_code -eq 0 -and -not $rolloutResult.timed_out) {
        Add-Check -Id "management_ingress_ready" -Label "Management ingress readiness" -Status "ok" -Message "ingress-nginx controller is Ready in devdeploy-mgmt." -Details @{
            required  = $true
            namespace = $IngressNginxNamespace
            release   = $IngressNginxRelease
        }
        return
    }

    Add-Check -Id "management_ingress_ready" -Label "Management ingress readiness" -Status "failed" -Message "ingress-nginx controller did not become Ready in devdeploy-mgmt." -Details @{
        required  = $true
        namespace = $IngressNginxNamespace
        release   = $IngressNginxRelease
        error     = $rolloutResult.stderr
    }
}

function Add-SkippedManagementPostgresStages {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Reason
    )

    Add-Check -Id "management_postgres_helm_available" -Label "Management PostgreSQL Helm availability" -Status "skipped" -Message $Reason -Details @{
        required = $true
    }
    Add-Check -Id "management_devdeploy_namespace" -Label "DevDeploy namespace" -Status "skipped" -Message $Reason -Details @{
        required  = $true
        namespace = $PostgresNamespace
    }
    Add-Check -Id "management_postgres_release" -Label "Management PostgreSQL release" -Status "skipped" -Message $Reason -Details @{
        required  = $true
        namespace = $PostgresNamespace
        release   = $PostgresRelease
    }
    Add-Check -Id "management_postgres_ready" -Label "Management PostgreSQL readiness" -Status "skipped" -Message $Reason -Details @{
        required  = $true
        namespace = $PostgresNamespace
        release   = $PostgresRelease
    }
}

function Invoke-ManagementPostgresBootstrap {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ManagementCluster,

        [bool]$HelmAvailable,

        [bool]$KubectlAvailable
    )

    if ([string]$ManagementCluster["status"] -ne "ready") {
        Add-SkippedManagementPostgresStages -Reason "PostgreSQL bootstrap skipped because devdeploy-mgmt is not ready."
        return
    }

    if (-not $HelmAvailable) {
        Add-Check -Id "management_postgres_helm_available" -Label "Management PostgreSQL Helm availability" -Status "failed" -Message "Helm CLI is required for -BootstrapManagementPostgres." -Details @{
            required = $true
            command  = "helm"
        }
        Add-Check -Id "management_devdeploy_namespace" -Label "DevDeploy namespace" -Status "skipped" -Message "PostgreSQL bootstrap skipped because Helm CLI is missing." -Details @{
            required  = $true
            namespace = $PostgresNamespace
        }
        Add-Check -Id "management_postgres_release" -Label "Management PostgreSQL release" -Status "skipped" -Message "PostgreSQL bootstrap skipped because Helm CLI is missing." -Details @{
            required  = $true
            namespace = $PostgresNamespace
            release   = $PostgresRelease
        }
        Add-Check -Id "management_postgres_ready" -Label "Management PostgreSQL readiness" -Status "skipped" -Message "PostgreSQL bootstrap skipped because Helm CLI is missing." -Details @{
            required  = $true
            namespace = $PostgresNamespace
            release   = $PostgresRelease
        }
        return
    }

    if (-not $KubectlAvailable) {
        Add-Check -Id "management_postgres_helm_available" -Label "Management PostgreSQL Helm availability" -Status "ok" -Message "Helm CLI is available." -Details @{
            required = $true
            command  = "helm"
        }
        Add-Check -Id "management_devdeploy_namespace" -Label "DevDeploy namespace" -Status "failed" -Message "kubectl is required to create or verify the devdeploy namespace." -Details @{
            required  = $true
            namespace = $PostgresNamespace
        }
        Add-Check -Id "management_postgres_release" -Label "Management PostgreSQL release" -Status "skipped" -Message "PostgreSQL bootstrap skipped because kubectl is missing." -Details @{
            required  = $true
            namespace = $PostgresNamespace
            release   = $PostgresRelease
        }
        Add-Check -Id "management_postgres_ready" -Label "Management PostgreSQL readiness" -Status "skipped" -Message "PostgreSQL bootstrap skipped because kubectl is missing." -Details @{
            required  = $true
            namespace = $PostgresNamespace
            release   = $PostgresRelease
        }
        return
    }

    Add-Check -Id "management_postgres_helm_available" -Label "Management PostgreSQL Helm availability" -Status "ok" -Message "Helm CLI is available for explicit management PostgreSQL bootstrap." -Details @{
        required = $true
        command  = "helm"
    }

    $namespaceResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "get", "namespace", $PostgresNamespace) -TimeoutSeconds 20
    if ($namespaceResult.exit_code -eq 0 -and -not $namespaceResult.timed_out) {
        Add-Check -Id "management_devdeploy_namespace" -Label "DevDeploy namespace" -Status "ok" -Message "Namespace devdeploy already exists in devdeploy-mgmt." -Details @{
            required  = $true
            namespace = $PostgresNamespace
            created   = $false
        }
    }
    else {
        $createNamespace = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "create", "namespace", $PostgresNamespace) -TimeoutSeconds 30
        if ($createNamespace.exit_code -eq 0 -and -not $createNamespace.timed_out) {
            Add-Check -Id "management_devdeploy_namespace" -Label "DevDeploy namespace" -Status "ok" -Message "Created namespace devdeploy in devdeploy-mgmt." -Details @{
                required  = $true
                namespace = $PostgresNamespace
                created   = $true
            }
        }
        else {
            Add-Check -Id "management_devdeploy_namespace" -Label "DevDeploy namespace" -Status "failed" -Message "Could not create namespace devdeploy in devdeploy-mgmt." -Details @{
                required  = $true
                namespace = $PostgresNamespace
                error     = $createNamespace.stderr
            }
            Add-Check -Id "management_postgres_release" -Label "Management PostgreSQL release" -Status "skipped" -Message "PostgreSQL release skipped because namespace creation failed." -Details @{
                required = $true
            }
            Add-Check -Id "management_postgres_ready" -Label "Management PostgreSQL readiness" -Status "skipped" -Message "Readiness check skipped because namespace creation failed." -Details @{
                required = $true
            }
            return
        }
    }

    $repoAdd = Invoke-ReadOnlyCommand -FileName "helm" -Arguments @("repo", "add", "bitnami", "https://charts.bitnami.com/bitnami", "--force-update") -TimeoutSeconds 60
    if ($repoAdd.exit_code -ne 0 -or $repoAdd.timed_out) {
        Add-Check -Id "management_postgres_release" -Label "Management PostgreSQL release" -Status "failed" -Message "Could not add or verify the Bitnami Helm repository." -Details @{
            required = $true
            error    = $repoAdd.stderr
        }
        Add-Check -Id "management_postgres_ready" -Label "Management PostgreSQL readiness" -Status "skipped" -Message "Readiness check skipped because Helm repository setup failed." -Details @{
            required = $true
        }
        return
    }

    $repoUpdate = Invoke-ReadOnlyCommand -FileName "helm" -Arguments @("repo", "update", "bitnami") -TimeoutSeconds 120
    if ($repoUpdate.exit_code -ne 0 -or $repoUpdate.timed_out) {
        Add-Check -Id "management_postgres_release" -Label "Management PostgreSQL release" -Status "failed" -Message "Could not update the Bitnami Helm repository." -Details @{
            required = $true
            error    = $repoUpdate.stderr
        }
        Add-Check -Id "management_postgres_ready" -Label "Management PostgreSQL readiness" -Status "skipped" -Message "Readiness check skipped because Helm repository update failed." -Details @{
            required = $true
        }
        return
    }

    $helmArgs = @(
        "upgrade", "--install", $PostgresRelease, "bitnami/postgresql",
        "--version", $PostgresChartVersion,
        "--namespace", $PostgresNamespace,
        "--kube-context", "kind-devdeploy-mgmt",
        "--wait",
        "--timeout", "5m",
        "--set", "auth.database=$PostgresDatabase",
        "--set", "auth.username=$PostgresUsername",
        "--set-string", "auth.password=$PostgresPassword",
        "--set", "primary.persistence.enabled=false"
    )

    Write-LauncherLog "Installing or verifying management PostgreSQL in devdeploy-mgmt with Helm."
    $installResult = Invoke-ReadOnlyCommand -FileName "helm" -Arguments $helmArgs -TimeoutSeconds 420
    if ($installResult.exit_code -ne 0 -or $installResult.timed_out) {
        $message = "Helm failed to install or upgrade management PostgreSQL. No automatic cleanup was performed."
        if ($installResult.timed_out) {
            $message = "Helm timed out while installing or upgrading management PostgreSQL. No automatic cleanup was performed."
        }

        Add-Check -Id "management_postgres_release" -Label "Management PostgreSQL release" -Status "failed" -Message $message -Details @{
            required      = $true
            namespace     = $PostgresNamespace
            release       = $PostgresRelease
            chart         = "bitnami/postgresql"
            chart_version = $PostgresChartVersion
            error         = $installResult.stderr
        }
        Add-Check -Id "management_postgres_ready" -Label "Management PostgreSQL readiness" -Status "skipped" -Message "Readiness check skipped because Helm install or upgrade failed." -Details @{
            required = $true
        }
        return
    }

    Add-Check -Id "management_postgres_release" -Label "Management PostgreSQL release" -Status "ok" -Message "PostgreSQL Helm release is installed or reconciled in devdeploy-mgmt." -Details @{
        required      = $true
        namespace     = $PostgresNamespace
        release       = $PostgresRelease
        chart         = "bitnami/postgresql"
        chart_version = $PostgresChartVersion
        database      = $PostgresDatabase
        username      = $PostgresUsername
        persistence   = "disabled"
    }

    $rolloutResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "rollout", "status", "statefulset/$PostgresRelease-postgresql", "--namespace", $PostgresNamespace, "--timeout=180s") -TimeoutSeconds 210
    if ($rolloutResult.exit_code -ne 0 -or $rolloutResult.timed_out) {
        Add-Check -Id "management_postgres_ready" -Label "Management PostgreSQL readiness" -Status "failed" -Message "PostgreSQL StatefulSet did not become Ready in devdeploy-mgmt." -Details @{
            required  = $true
            namespace = $PostgresNamespace
            release   = $PostgresRelease
            error     = $rolloutResult.stderr
        }
        return
    }

    $serviceResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "get", "svc", "--namespace", $PostgresNamespace, "-l", "app.kubernetes.io/instance=$PostgresRelease") -TimeoutSeconds 20
    if ($serviceResult.exit_code -ne 0 -or $serviceResult.timed_out) {
        Add-Check -Id "management_postgres_ready" -Label "Management PostgreSQL readiness" -Status "failed" -Message "PostgreSQL service could not be verified in devdeploy-mgmt." -Details @{
            required  = $true
            namespace = $PostgresNamespace
            release   = $PostgresRelease
            error     = $serviceResult.stderr
        }
        return
    }

    Add-Check -Id "management_postgres_ready" -Label "Management PostgreSQL readiness" -Status "ok" -Message "PostgreSQL is Ready and service exists in devdeploy-mgmt." -Details @{
        required  = $true
        namespace = $PostgresNamespace
        release   = $PostgresRelease
    }
}

New-LocalDirectory -Path $StatusDir
New-LocalDirectory -Path $LogsDir
New-LocalDirectory -Path $KindDir

if ($CreateManagementCluster) {
    Write-LauncherLog "Starting DevDeploy Launcher guarded management cluster create mode."
}
elseif ($CreateWorkloadCluster) {
    Write-LauncherLog "Starting DevDeploy Launcher guarded workload cluster create mode."
}
elseif ($BootstrapManagementIngress) {
    Write-LauncherLog "Starting DevDeploy Launcher explicit management ingress bootstrap mode."
}
elseif ($BootstrapManagementPostgres) {
    Write-LauncherLog "Starting DevDeploy Launcher explicit management PostgreSQL bootstrap mode."
}
elseif ($BuildManagementBackendImage) {
    Write-LauncherLog "Starting DevDeploy Launcher explicit management backend image build mode."
}
elseif ($LoadManagementBackendImage) {
    Write-LauncherLog "Starting DevDeploy Launcher explicit management backend image load mode."
}
elseif ($EnsureManagementBackendSecret) {
    Write-LauncherLog "Starting DevDeploy Launcher explicit management backend Secret ensure mode."
}
elseif ($VerifyManagementBackendSecret) {
    Write-LauncherLog "Starting DevDeploy Launcher read-only management backend Secret verify mode."
}
elseif ($BootstrapManagementBackend) {
    Write-LauncherLog "Starting DevDeploy Launcher explicit management backend bootstrap mode."
}
elseif ($GenerateKindConfigs) {
    Write-LauncherLog "Starting DevDeploy Launcher read-only preflight with kind config preview generation."
}
else {
    Write-LauncherLog "Starting DevDeploy Launcher read-only preflight."
}

$dockerAvailable = Test-CommandAvailable -Name "docker" -Label "Docker CLI" -Required ([bool](-not ($EnsureManagementBackendSecret -or $VerifyManagementBackendSecret)))
$kindAvailable = Test-CommandAvailable -Name "kind" -Label "kind CLI" -Required ([bool](-not $BuildManagementBackendImage))
$kubectlAvailable = Test-CommandAvailable -Name "kubectl" -Label "kubectl CLI" -Required ([bool](-not $BuildManagementBackendImage))
[void](Test-CommandAvailable -Name "git" -Label "git CLI" -Required $false)
$helmAvailable = Test-CommandAvailable -Name "helm" -Label "Helm CLI" -Required ([bool]($BootstrapManagementIngress -or $BootstrapManagementPostgres))

if ($EnsureManagementBackendSecret -or $VerifyManagementBackendSecret) {
    $dockerDaemonReachable = $false
    Add-Check -Id "docker_daemon" -Label "Docker daemon" -Status "skipped" -Message "Docker daemon check is not required for backend Secret ensure or verify mode." -Details @{
        required = $false
    }
}
else {
    $dockerDaemonReachable = Test-DockerDaemon -DockerCliAvailable $dockerAvailable
}

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
    if (($BootstrapManagementIngress -or $BootstrapManagementPostgres) -and $isWorkloadPort) {
        $portRequired = $false
    }
    if ($BuildManagementBackendImage -or $LoadManagementBackendImage -or $EnsureManagementBackendSecret -or $VerifyManagementBackendSecret -or $BootstrapManagementBackend) {
        $portRequired = $false
    }
    $allowBusyAsOk = [bool]$existingClusterDetected

    Test-LocalPortAvailable -Port ([int]$entry.Value) -Required $portRequired -AllowBusyAsOk $allowBusyAsOk -ExpectedCluster $expectedCluster -ExistingClusterDetected $existingClusterDetected
}

if ($workloadClusterExistsBeforePortCheck) {
    $detectedStatus = if ($CreateWorkloadCluster -or $BootstrapManagementIngress -or $BootstrapManagementPostgres -or $BuildManagementBackendImage -or $LoadManagementBackendImage -or $EnsureManagementBackendSecret -or $VerifyManagementBackendSecret -or $BootstrapManagementBackend) { "ok" } else { "warning" }
    $detectedMessage = if ($CreateWorkloadCluster) {
        "devdeploy-workload already exists. This launcher mode will verify it instead of recreating it."
    }
    elseif ($BootstrapManagementIngress) {
        "devdeploy-workload already exists. This launcher mode does not use, modify, or delete it."
    }
    elseif ($BootstrapManagementPostgres) {
        "devdeploy-workload already exists. This launcher mode does not use, modify, or delete it."
    }
    elseif ($BuildManagementBackendImage) {
        "devdeploy-workload already exists. Backend image build mode does not use, modify, or delete it."
    }
    elseif ($LoadManagementBackendImage) {
        "devdeploy-workload already exists. Backend image load mode targets only devdeploy-mgmt and does not modify devdeploy-workload."
    }
    elseif ($EnsureManagementBackendSecret) {
        "devdeploy-workload already exists. Backend Secret ensure mode targets only devdeploy-mgmt and does not modify devdeploy-workload."
    }
    elseif ($VerifyManagementBackendSecret) {
        "devdeploy-workload already exists. Backend Secret verify mode is read-only and targets only devdeploy-mgmt."
    }
    elseif ($BootstrapManagementBackend) {
        "devdeploy-workload already exists. Backend bootstrap mode targets only devdeploy-mgmt and does not modify devdeploy-workload."
    }
    else {
        "devdeploy-workload already exists. This launcher mode will not create, modify, or delete it."
    }

    Add-Check -Id "workload_cluster_detected" -Label "Workload cluster detected" -Status $detectedStatus -Message $detectedMessage -Details @{
        required     = $false
        cluster_name = "devdeploy-workload"
        exists       = $true
    }
}

Test-KindClusters -KindAvailable $kindAvailable -ManagementCreateMode ([bool]$CreateManagementCluster) -WorkloadCreateMode ([bool]$CreateWorkloadCluster) -ManagementIngressBootstrapMode ([bool]$BootstrapManagementIngress) -ManagementPostgresBootstrapMode ([bool]$BootstrapManagementPostgres) -ManagementBackendImageBuildMode ([bool]$BuildManagementBackendImage) -ManagementBackendImageLoadMode ([bool]$LoadManagementBackendImage) -ManagementBackendSecretEnsureMode ([bool]$EnsureManagementBackendSecret) -ManagementBackendSecretVerifyMode ([bool]$VerifyManagementBackendSecret) -ManagementBackendBootstrapMode ([bool]$BootstrapManagementBackend)
Test-KubectlContext -KubectlAvailable $kubectlAvailable

$launcherMode = "preflight"
if ($CreateManagementCluster) {
    $launcherMode = "management_cluster_create"
}
elseif ($CreateWorkloadCluster) {
    $launcherMode = "workload_cluster_create"
}
elseif ($BootstrapManagementIngress) {
    $launcherMode = "management_ingress_bootstrap"
}
elseif ($BootstrapManagementPostgres) {
    $launcherMode = "management_postgres_bootstrap"
}
elseif ($BuildManagementBackendImage) {
    $launcherMode = "management_backend_image_build"
}
elseif ($LoadManagementBackendImage) {
    $launcherMode = "management_backend_image_load"
}
elseif ($EnsureManagementBackendSecret) {
    $launcherMode = "management_backend_secret_ensure"
}
elseif ($VerifyManagementBackendSecret) {
    $launcherMode = "management_backend_secret_verify"
}
elseif ($BootstrapManagementBackend) {
    $launcherMode = "management_backend_bootstrap"
}
elseif ($GenerateKindConfigs) {
    $launcherMode = "kind_config_preview"
}

$managementCluster = $null
$workloadCluster = $null
$backendImageStatus = New-ManagementBackendImageStatus
$backendSecretStatus = New-ManagementBackendSecretStatus
$backendStatus = New-ManagementBackendStatus
$platformIngressOverride = $null
$platformPostgresOverride = $null

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
elseif ($CreateWorkloadCluster) {
    Write-KindConfigPreview -Id "workload_kind_config" -Label "Workload kind config" -ClusterName "devdeploy-workload" -Path $WorkloadKindConfigPath -ApiServerPort 58081 -HttpHostPort 8081 -HttpsHostPort 8444

    $preCreateChecks = @($Checks | ForEach-Object { $_ })
    $preCreateStatus = [string](Get-OverallStatus -StableChecks $preCreateChecks)
    if ($preCreateStatus -eq "failed") {
        Add-SkippedWorkloadClusterStages -Reason "Workload cluster create was skipped because required preflight or kind config checks failed."
    }
    else {
        $workloadClusterExists = Test-WorkloadClusterExists -KindAvailable $kindAvailable
        $workloadClusterCreatedOrPresent = Invoke-WorkloadClusterCreate -AlreadyExists $workloadClusterExists
        if ($workloadClusterCreatedOrPresent) {
            Test-WorkloadClusterVerify -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable
        }
        else {
            Add-Check -Id "workload_cluster_verify" -Label "Workload cluster verify" -Status "skipped" -Message "Workload cluster verification was skipped because creation failed." -Details @{
                required     = $true
                cluster_name = "devdeploy-workload"
            }
        }
    }
}
elseif ($BootstrapManagementIngress) {
    $managementCluster = New-ManagementClusterStatus -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable
    $preBootstrapChecks = @($Checks | ForEach-Object { $_ })
    $preBootstrapStatus = [string](Get-OverallStatus -StableChecks $preBootstrapChecks)
    if ($preBootstrapStatus -eq "failed" -and [string]$managementCluster["status"] -eq "ready") {
        Add-SkippedManagementIngressStages -Reason "Management ingress bootstrap was skipped because required preflight checks failed."
    }
    else {
        Invoke-ManagementIngressBootstrap -ManagementCluster $managementCluster -HelmAvailable $helmAvailable -KubectlAvailable $kubectlAvailable
    }
}
elseif ($BootstrapManagementPostgres) {
    $managementCluster = New-ManagementClusterStatus -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable
    $preBootstrapChecks = @($Checks | ForEach-Object { $_ })
    $preBootstrapStatus = [string](Get-OverallStatus -StableChecks $preBootstrapChecks)
    if ($preBootstrapStatus -eq "failed" -and [string]$managementCluster["status"] -eq "ready") {
        Add-SkippedManagementPostgresStages -Reason "PostgreSQL bootstrap was skipped because required preflight checks failed."
    }
    else {
        Invoke-ManagementPostgresBootstrap -ManagementCluster $managementCluster -HelmAvailable $helmAvailable -KubectlAvailable $kubectlAvailable
    }
}
elseif ($BuildManagementBackendImage) {
    $backendImageStatus = Invoke-ManagementBackendImageBuild -DockerCliAvailable $dockerAvailable -DockerDaemonReachable $dockerDaemonReachable
}
elseif ($LoadManagementBackendImage) {
    $managementCluster = New-ManagementClusterStatus -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable
    $backendImageStatus = Invoke-ManagementBackendImageLoad -DockerCliAvailable $dockerAvailable -DockerDaemonReachable $dockerDaemonReachable -KindAvailable $kindAvailable -ManagementCluster $managementCluster
}
elseif ($EnsureManagementBackendSecret) {
    $managementCluster = New-ManagementClusterStatus -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable
    $backendSecretStatus = Invoke-EnsureManagementBackendSecret -KubectlAvailable $kubectlAvailable -ManagementCluster $managementCluster
}
elseif ($VerifyManagementBackendSecret) {
    $managementCluster = New-ManagementClusterStatus -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable
    $backendSecretStatus = Invoke-VerifyManagementBackendSecret -KubectlAvailable $kubectlAvailable -ManagementCluster $managementCluster
}
elseif ($BootstrapManagementBackend) {
    $managementCluster = New-ManagementClusterStatus -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable
    $backendBootstrapResult = Invoke-BootstrapManagementBackend -KubectlAvailable $kubectlAvailable -DockerCliAvailable $dockerAvailable -DockerDaemonReachable $dockerDaemonReachable -ManagementCluster $managementCluster
    $backendStatus = $backendBootstrapResult["backend"]
    $backendImageStatus = $backendBootstrapResult["backend_image"]
    $backendSecretStatus = $backendBootstrapResult["backend_secret"]
    $platformIngressOverride = $backendBootstrapResult["ingress"]
    $platformPostgresOverride = $backendBootstrapResult["postgres"]
}
elseif ($GenerateKindConfigs) {
    Write-KindConfigPreview -Id "kind_config_mgmt_preview" -Label "Management kind config preview" -ClusterName "devdeploy-mgmt" -Path $MgmtKindConfigPath -ApiServerPort 58080 -HttpHostPort 8080 -HttpsHostPort 8443
    Write-KindConfigPreview -Id "kind_config_workload_preview" -Label "Workload kind config preview" -ClusterName "devdeploy-workload" -Path $WorkloadKindConfigPath -ApiServerPort 58081 -HttpHostPort 8081 -HttpsHostPort 8444
}

if ($null -eq $managementCluster) {
    $managementCluster = New-ManagementClusterStatus -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable
}
if ($null -eq $workloadCluster) {
    $workloadCluster = New-WorkloadClusterStatus -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable
}
$platformHelmAvailable = [bool]($helmAvailable -and -not $BuildManagementBackendImage -and -not $LoadManagementBackendImage -and -not $EnsureManagementBackendSecret -and -not $VerifyManagementBackendSecret -and -not $BootstrapManagementBackend)
$platformBootstrap = New-PlatformBootstrapStatus -ManagementCluster $managementCluster -HelmAvailable $platformHelmAvailable -KubectlAvailable $kubectlAvailable -BackendImageStatus $backendImageStatus -BackendSecretStatus $backendSecretStatus -BackendStatus $backendStatus -IngressStatusOverride $platformIngressOverride -PostgresStatusOverride $platformPostgresOverride
$stableChecks = @($Checks | ForEach-Object { $_ })
$overallStatus = [string](Get-OverallStatus -StableChecks $stableChecks)
$summary = New-LauncherSummary -StableChecks $stableChecks
$artifacts = New-LauncherArtifacts -IncludeManagementKindConfig ([bool]($GenerateKindConfigs -or $CreateManagementCluster)) -IncludeWorkloadKindConfig ([bool]($GenerateKindConfigs -or $CreateWorkloadCluster))
$nextActions = @(New-NextActions -StableChecks $stableChecks -LauncherMode $launcherMode -OverallStatus $overallStatus -ManagementCluster $managementCluster -WorkloadCluster $workloadCluster -PlatformBootstrap $platformBootstrap)

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
    management_cluster = $managementCluster
    workload_cluster = $workloadCluster
    platform_bootstrap = $platformBootstrap
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
    elseif ($CreateWorkloadCluster) {
        Write-Host ("Workload kind config: {0}" -f $WorkloadKindConfigPath)
    }
    elseif ($BootstrapManagementIngress) {
        Write-Host ("Management ingress release: {0}/{1}" -f $IngressNginxNamespace, $IngressNginxRelease)
    }
    elseif ($BootstrapManagementPostgres) {
        Write-Host ("Management PostgreSQL release: {0}/{1}" -f $PostgresNamespace, $PostgresRelease)
    }
    elseif ($BuildManagementBackendImage) {
        Write-Host ("Management backend image: {0}" -f $BackendImage)
    }
    elseif ($LoadManagementBackendImage) {
        Write-Host ("Management backend image target: {0} -> devdeploy-mgmt" -f $BackendImage)
    }
    elseif ($EnsureManagementBackendSecret) {
        Write-Host ("Management backend Secret: {0}/{1}" -f $PostgresNamespace, $BackendSecretName)
    }
    elseif ($VerifyManagementBackendSecret) {
        Write-Host ("Verified management backend Secret: {0}/{1}" -f $PostgresNamespace, $BackendSecretName)
    }
    elseif ($BootstrapManagementBackend) {
        Write-Host ("Management backend deployment: {0}/devdeploy-backend" -f $PostgresNamespace)
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
