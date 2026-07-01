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

    [switch]$VerifyManagementBackend,

    [switch]$BuildManagementFrontendImage,

    [switch]$LoadManagementFrontendImage,

    [switch]$BootstrapManagementFrontend,

    [switch]$VerifyManagementFrontend,

    [switch]$BootstrapManagementArgoCD,

    [switch]$InitializeManagementBackendDatabase,

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
$BackendAlembicConfigPath = "/app/alembic.ini"
$BackendAlembicScriptPath = "/app/alembic"
$FrontendImage = "devdeploy-frontend:local"
$FrontendBuildApiBaseUrl = "/api/v1"
$FrontendContextPath = Join-Path $RepoRoot "frontend"
$FrontendDockerfilePath = Join-Path $FrontendContextPath "Dockerfile"
$FrontendPackagePath = Join-Path $FrontendContextPath "package.json"
$FrontendPackageLockPath = Join-Path $FrontendContextPath "package-lock.json"
$FrontendManifestRelativePath = "platform/management/frontend"
$FrontendManifestPath = Join-Path $RepoRoot "platform\management\frontend"
$FrontendKustomizationPath = Join-Path $FrontendManifestPath "kustomization.yaml"
$ArgoCDChartVersion = "10.1.0"
$ArgoCDNamespace = "argocd"
$ArgoCDRelease = "argocd"
$ArgoCDChart = "argo/argo-cd"
$ArgoCDIngressHost = "argocd.localhost"
$ArgoCDUiAccess = "http://argocd.localhost:8080/"

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
    $value = $value -replace '(?i)(postgres(?:ql)?(?:\+\w+)?://[^:\s]+:)[^@\s]+@', '$1<redacted>@'
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

    $frontendImageStatus = "not_checked"
    try {
        if ($null -ne $PlatformBootstrap["components"] -and $null -ne $PlatformBootstrap["components"]["frontend_image"]) {
            $frontendImageStatus = [string]$PlatformBootstrap["components"]["frontend_image"]["status"]
        }
    }
    catch {
        $frontendImageStatus = "unknown"
    }

    if ($LauncherMode -eq "management_frontend_image_build") {
        if ($frontendImageStatus -eq "ready") {
            $actions.Add("The management frontend image is ready locally. Proceed to the future explicit image-load step when available.") | Out-Null
        }
        elseif ($frontendImageStatus -eq "error" -or $frontendImageStatus -eq "unknown") {
            $actions.Add("Review the sanitized launcher log, resolve the Docker or frontend build input issue, and rerun -BuildManagementFrontendImage.") | Out-Null
        }
    }
    elseif ($LauncherMode -eq "management_frontend_image_load") {
        $localImagePresent = $false
        $loadedToManagementCluster = $false
        try {
            $localImagePresent = [bool]$PlatformBootstrap["components"]["frontend_image"]["local_image_present"]
            $loadedToManagementCluster = [bool]$PlatformBootstrap["components"]["frontend_image"]["loaded_to_management_cluster"]
        }
        catch {
            $localImagePresent = $false
            $loadedToManagementCluster = $false
        }

        if ($frontendImageStatus -eq "ready" -and $loadedToManagementCluster) {
            $actions.Add("The management frontend image is loaded into devdeploy-mgmt. Proceed to the future explicit frontend bootstrap step when available.") | Out-Null
        }
        elseif (-not $localImagePresent) {
            $actions.Add("Run -BuildManagementFrontendImage before retrying -LoadManagementFrontendImage.") | Out-Null
        }
        elseif ($managementClusterStatus -ne "ready") {
            $actions.Add("Create or repair devdeploy-mgmt, then rerun -LoadManagementFrontendImage.") | Out-Null
        }
        else {
            $actions.Add("Review the sanitized launcher log and rerun -LoadManagementFrontendImage after resolving the kind image-load issue.") | Out-Null
        }
    }

    $frontendStatus = "not_started"
    try {
        if ($null -ne $PlatformBootstrap["components"] -and $null -ne $PlatformBootstrap["components"]["frontend"]) {
            $frontendStatus = [string]$PlatformBootstrap["components"]["frontend"]["status"]
        }
    }
    catch {
        $frontendStatus = "unknown"
    }

    if ($LauncherMode -eq "management_frontend_bootstrap") {
        if ($frontendStatus -eq "ready") {
            $actions.Add("The management frontend is ready. Proceed to the future Argo CD bootstrap phase when available.") | Out-Null
        }
        elseif ($frontendStatus -eq "warning") {
            $actions.Add("The frontend rollout is ready, but page or ingress verification needs review. Check the sanitized launcher log and rerun -BootstrapManagementFrontend.") | Out-Null
        }
        else {
            $actions.Add("Review failed frontend prerequisite, render, apply, or rollout checks and rerun -BootstrapManagementFrontend after resolving them.") | Out-Null
        }
    }
    elseif ($LauncherMode -eq "management_frontend_verify") {
        if ($frontendStatus -eq "ready") {
            $actions.Add("The management frontend passed read-only verification. Proceed to the future Argo CD bootstrap phase when available.") | Out-Null
        }
        elseif ($frontendStatus -eq "warning") {
            $actions.Add("Frontend resources are Ready, but page or ingress checks need review. Rerun -VerifyManagementFrontend after checking local routing.") | Out-Null
        }
        else {
            $actions.Add("Review failed read-only frontend checks. Run -BootstrapManagementFrontend only when you intend to reconcile frontend resources.") | Out-Null
        }
    }

    $backendDatabaseStatus = "not_started"
    try {
        if ($null -ne $PlatformBootstrap["components"] -and $null -ne $PlatformBootstrap["components"]["backend_database"]) {
            $backendDatabaseStatus = [string]$PlatformBootstrap["components"]["backend_database"]["status"]
        }
    }
    catch {
        $backendDatabaseStatus = "unknown"
    }

    if ($LauncherMode -eq "management_backend_database_initialize") {
        if ($backendDatabaseStatus -eq "ready") {
            $actions.Add("The management backend database schema is current. Continue using the frontend authentication flow.") | Out-Null
        }
        else {
            $actions.Add("Review the sanitized Alembic and database verification checks, then rerun -InitializeManagementBackendDatabase after resolving the issue.") | Out-Null
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
    elseif ($LauncherMode -eq "management_backend_verify") {
        if ($backendStatus -eq "ready") {
            $actions.Add("The management backend passed read-only verification.") | Out-Null
        }
        elseif ($backendStatus -eq "warning") {
            $actions.Add("Backend resources are ready, but health verification needs review. Check the sanitized launcher log and rerun -VerifyManagementBackend.") | Out-Null
        }
        else {
            $actions.Add("Review failed read-only backend checks. Run -BootstrapManagementBackend only when you intend to reconcile backend resources.") | Out-Null
        }
    }

    $argocdStatus = "not_started"
    try {
        if ($null -ne $PlatformBootstrap["components"] -and $null -ne $PlatformBootstrap["components"]["argocd"]) {
            $argocdStatus = [string]$PlatformBootstrap["components"]["argocd"]["status"]
        }
    }
    catch {
        $argocdStatus = "unknown"
    }

    if ($LauncherMode -eq "management_argocd_bootstrap") {
        if ($argocdStatus -eq "ready") {
            $actions.Add("Management Argo CD is ready. Workload cluster registration and GitOps Application creation remain separate future steps.") | Out-Null
        }
        elseif ($managementClusterStatus -ne "ready") {
            $actions.Add("Create or repair devdeploy-mgmt, then rerun -BootstrapManagementArgoCD.") | Out-Null
        }
        elseif ($ingressStatus -ne "ready") {
            $actions.Add("Run -BootstrapManagementIngress before retrying -BootstrapManagementArgoCD.") | Out-Null
        }
        else {
            $actions.Add("Review the sanitized launcher log and rerun -BootstrapManagementArgoCD after resolving the Argo CD bootstrap issue.") | Out-Null
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

        [string]$WorkingDirectory = "",

        [bool]$PreserveStandardOutput = $false
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

        $standardOutput = $process.StandardOutput.ReadToEnd()
        return [ordered]@{
            exit_code = $process.ExitCode
            timed_out = $false
            stdout    = if ($PreserveStandardOutput) { $standardOutput } else { Protect-LogText $standardOutput }
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
        image                        = [string]$script:BackendImage
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

function New-ManagementFrontendImageStatus {
    return [ordered]@{
        image                        = [string]$script:FrontendImage
        dockerfile                   = "frontend/Dockerfile"
        context                      = "frontend"
        build_api_base_url           = $FrontendBuildApiBaseUrl
        local_image_present          = $false
        build_attempted              = $false
        build_succeeded              = $false
        load_attempted               = $false
        load_succeeded               = $false
        loaded_to_management_cluster = $false
        target_cluster               = "devdeploy-mgmt"
        status                       = "not_checked"
        message                      = "Frontend image build has not been requested."
        checked_at                   = [string](Get-Timestamp)
    }
}

function Test-ManagementFrontendImagePresent {
    param(
        [bool]$DockerCliAvailable,

        [bool]$DockerDaemonReachable
    )

    if (-not $DockerCliAvailable -or -not $DockerDaemonReachable) {
        return $false
    }

    $result = Invoke-ReadOnlyCommand -FileName "docker" -Arguments @("image", "inspect", "--format", "{{.Id}}", $FrontendImage) -TimeoutSeconds 30
    return [bool]($result.exit_code -eq 0 -and -not $result.timed_out -and -not [string]::IsNullOrWhiteSpace($result.stdout))
}

function Invoke-ManagementFrontendImageBuild {
    param(
        [bool]$DockerCliAvailable,

        [bool]$DockerDaemonReachable
    )

    $status = New-ManagementFrontendImageStatus

    if (-not $DockerCliAvailable -or -not $DockerDaemonReachable) {
        $status["status"] = "error"
        $status["message"] = "Frontend image build requires an available Docker CLI and reachable Docker daemon."
        $status["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "frontend_image_build" -Label "Management frontend image build" -Status "skipped" -Message ([string]$status["message"]) -Details @{
            required = $true
            image    = $FrontendImage
        }
        return $status
    }

    $requiredPaths = @(
        [ordered]@{ id = "frontend_build_context"; label = "Frontend build context"; path = $FrontendContextPath; relative_path = "frontend"; path_type = "Container" },
        [ordered]@{ id = "frontend_dockerfile"; label = "Frontend Dockerfile"; path = $FrontendDockerfilePath; relative_path = "frontend/Dockerfile"; path_type = "Leaf" },
        [ordered]@{ id = "frontend_package"; label = "Frontend package manifest"; path = $FrontendPackagePath; relative_path = "frontend/package.json"; path_type = "Leaf" },
        [ordered]@{ id = "frontend_package_lock"; label = "Frontend package lock"; path = $FrontendPackageLockPath; relative_path = "frontend/package-lock.json"; path_type = "Leaf" },
        [ordered]@{ id = "frontend_platform_kustomization"; label = "Frontend platform kustomization"; path = $FrontendKustomizationPath; relative_path = "platform/management/frontend/kustomization.yaml"; path_type = "Leaf" }
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
        $status["message"] = "Frontend image build was not attempted because one or more required repository paths are missing."
        $status["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "frontend_image_build" -Label "Management frontend image build" -Status "skipped" -Message ([string]$status["message"]) -Details @{
            required = $true
            image    = $FrontendImage
        }
        return $status
    }

    $status["build_attempted"] = $true
    Write-LauncherLog ("Building management frontend image {0} with VITE_API_BASE_URL={1}." -f $FrontendImage, $FrontendBuildApiBaseUrl)
    if (-not $Quiet) {
        Write-Host ("Building management frontend image {0}..." -f $FrontendImage)
    }

    # Quiet build output keeps launcher logs/status concise; the API base URL is a non-secret build setting.
    $buildResult = Invoke-ReadOnlyCommand -FileName "docker" -Arguments @("build", "--quiet", "--build-arg", "VITE_API_BASE_URL=$FrontendBuildApiBaseUrl", "--tag", $FrontendImage, "frontend") -TimeoutSeconds 1200 -WorkingDirectory $RepoRoot
    if ($buildResult.exit_code -ne 0 -or $buildResult.timed_out) {
        $status["local_image_present"] = Test-ManagementFrontendImagePresent -DockerCliAvailable $DockerCliAvailable -DockerDaemonReachable $DockerDaemonReachable
        $status["status"] = "error"
        $status["message"] = if ($buildResult.timed_out) {
            "Frontend image build timed out. Review Docker availability and the sanitized launcher log before retrying."
        }
        else {
            "Frontend image build failed. Review the sanitized launcher log and retry the explicit build mode."
        }
        $status["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "frontend_image_build" -Label "Management frontend image build" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required           = $true
            image              = $FrontendImage
            build_api_base_url = $FrontendBuildApiBaseUrl
            error              = $buildResult.stderr
        }
        return $status
    }

    $status["build_succeeded"] = $true
    Add-Check -Id "frontend_image_build" -Label "Management frontend image build" -Status "ok" -Message "Management frontend image build completed successfully." -Details @{
        required           = $true
        image              = $FrontendImage
        context            = "frontend"
        build_api_base_url = $FrontendBuildApiBaseUrl
    }

    $imagePresent = Test-ManagementFrontendImagePresent -DockerCliAvailable $DockerCliAvailable -DockerDaemonReachable $DockerDaemonReachable
    $status["local_image_present"] = $imagePresent
    if (-not $imagePresent) {
        $status["status"] = "error"
        $status["message"] = "Docker reported a successful build, but devdeploy-frontend:local could not be verified locally."
        $status["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "frontend_image_verify" -Label "Management frontend image verification" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required = $true
            image    = $FrontendImage
        }
        return $status
    }

    $status["status"] = "ready"
    $status["message"] = "Frontend image devdeploy-frontend:local was built with /api/v1 and verified in the local Docker daemon."
    $status["checked_at"] = [string](Get-Timestamp)
    Add-Check -Id "frontend_image_verify" -Label "Management frontend image verification" -Status "ok" -Message ([string]$status["message"]) -Details @{
        required           = $true
        image              = $FrontendImage
        build_api_base_url = $FrontendBuildApiBaseUrl
    }
    return $status
}

function Invoke-ManagementFrontendImageLoad {
    param(
        [bool]$DockerCliAvailable,

        [bool]$DockerDaemonReachable,

        [bool]$KindAvailable,

        [Parameter(Mandatory = $true)]
        [object]$ManagementCluster
    )

    $status = New-ManagementFrontendImageStatus

    if (-not $DockerCliAvailable -or -not $DockerDaemonReachable) {
        $status["status"] = "error"
        $status["message"] = "Frontend image load requires an available Docker CLI and reachable Docker daemon."
        $status["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "frontend_image_load" -Label "Management frontend image load" -Status "skipped" -Message ([string]$status["message"]) -Details @{
            required       = $true
            image          = $FrontendImage
            target_cluster = "devdeploy-mgmt"
        }
        return $status
    }

    $imagePresent = Test-ManagementFrontendImagePresent -DockerCliAvailable $DockerCliAvailable -DockerDaemonReachable $DockerDaemonReachable
    $status["local_image_present"] = $imagePresent
    if (-not $imagePresent) {
        $status["status"] = "error"
        $status["message"] = "Local image devdeploy-frontend:local was not found. Run -BuildManagementFrontendImage before loading it into devdeploy-mgmt."
        $status["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "frontend_image_local" -Label "Local management frontend image" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required = $true
            image    = $FrontendImage
        }
        Add-Check -Id "frontend_image_load" -Label "Management frontend image load" -Status "skipped" -Message "Frontend image load was skipped because the local image is missing." -Details @{
            required       = $true
            image          = $FrontendImage
            target_cluster = "devdeploy-mgmt"
        }
        return $status
    }

    Add-Check -Id "frontend_image_local" -Label "Local management frontend image" -Status "ok" -Message "Local image devdeploy-frontend:local exists." -Details @{
        required = $true
        image    = $FrontendImage
    }

    if (-not $KindAvailable) {
        $status["status"] = "error"
        $status["message"] = "kind CLI is required to load devdeploy-frontend:local into devdeploy-mgmt."
        $status["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "frontend_image_load" -Label "Management frontend image load" -Status "skipped" -Message ([string]$status["message"]) -Details @{
            required       = $true
            image          = $FrontendImage
            target_cluster = "devdeploy-mgmt"
        }
        return $status
    }

    if ([string]$ManagementCluster["status"] -ne "ready") {
        $status["status"] = "error"
        $status["message"] = "devdeploy-mgmt must exist, be API-reachable, and have a Ready node before loading the frontend image."
        $status["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "frontend_image_load" -Label "Management frontend image load" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required          = $true
            image             = $FrontendImage
            target_cluster    = "devdeploy-mgmt"
            management_status = [string]$ManagementCluster["status"]
            api_reachable     = $ManagementCluster["api_reachable"]
            ready_nodes       = [int]$ManagementCluster["ready_nodes"]
        }
        return $status
    }

    $status["load_attempted"] = $true
    Write-LauncherLog ("Loading management frontend image {0} into devdeploy-mgmt." -f $FrontendImage)
    if (-not $Quiet) {
        Write-Host ("Loading management frontend image {0} into devdeploy-mgmt..." -f $FrontendImage)
    }

    $loadResult = Invoke-ReadOnlyCommand -FileName "kind" -Arguments @("load", "docker-image", $FrontendImage, "--name", "devdeploy-mgmt") -TimeoutSeconds 600
    if ($loadResult.exit_code -ne 0 -or $loadResult.timed_out) {
        $status["status"] = "error"
        $status["message"] = if ($loadResult.timed_out) {
            "Loading devdeploy-frontend:local into devdeploy-mgmt timed out. Review the sanitized launcher log and retry."
        }
        else {
            "kind failed to load devdeploy-frontend:local into devdeploy-mgmt. Review the sanitized launcher log and retry."
        }
        $status["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "frontend_image_load" -Label "Management frontend image load" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required       = $true
            image          = $FrontendImage
            target_cluster = "devdeploy-mgmt"
            error          = $loadResult.stderr
        }
        return $status
    }

    $status["load_succeeded"] = $true
    $status["loaded_to_management_cluster"] = $true
    $status["status"] = "ready"
    $status["message"] = "Frontend image devdeploy-frontend:local was loaded into devdeploy-mgmt."
    $status["checked_at"] = [string](Get-Timestamp)
    Add-Check -Id "frontend_image_load" -Label "Management frontend image load" -Status "ok" -Message ([string]$status["message"]) -Details @{
        required       = $true
        image          = $FrontendImage
        target_cluster = "devdeploy-mgmt"
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
        image                  = [string]$script:BackendImage
        manifests_path         = $BackendManifestRelativePath
        rollout_succeeded      = $false
        health_check_succeeded = $false
        mode                   = "not_checked"
        status                 = "not_checked"
        message                = "Backend bootstrap has not been requested."
        checked_at             = [string](Get-Timestamp)
    }
}

function New-ManagementBackendDatabaseStatus {
    return [ordered]@{
        initialized               = $false
        ready                     = $false
        namespace                 = $PostgresNamespace
        target_cluster            = "devdeploy-mgmt"
        migration_tool            = "alembic"
        migration_command         = "alembic upgrade head"
        current_revision_detected = $false
        users_table_present       = $false
        status                    = "not_started"
        message                   = "Backend database initialization has not been requested."
        checked_at                = [string](Get-Timestamp)
    }
}

function New-ManagementFrontendStatus {
    return [ordered]@{
        deployed                         = $false
        ready                            = $false
        namespace                        = $PostgresNamespace
        deployment                       = "devdeploy-frontend"
        service                          = "devdeploy-frontend"
        ingress                          = "devdeploy-frontend"
        image                            = [string]$script:FrontendImage
        manifests_path                   = $FrontendManifestRelativePath
        rollout_succeeded                = $false
        page_check_succeeded              = $false
        ingress_page_check_succeeded      = $false
        backend_api_route_check_succeeded = $false
        mode                             = "not_checked"
        status                           = "not_started"
        message                          = "Frontend bootstrap has not been requested."
        checked_at                       = [string](Get-Timestamp)
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
    $backend["mode"] = "bootstrap"
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

function Invoke-VerifyManagementBackend {
    param(
        [bool]$KubectlAvailable,

        [Parameter(Mandatory = $true)]
        [object]$ManagementCluster
    )

    $backend = New-ManagementBackendStatus
    $backend["mode"] = "verify"
    $backendImage = New-ManagementBackendImageStatus
    $backendSecret = New-ManagementBackendSecretStatus
    $ingress = New-PlatformComponentStatus -Installed $null -Ready $null -Namespace $IngressNginxNamespace -Release $IngressNginxRelease -Status "unknown" -Message "Management ingress status has not been checked."
    $postgres = New-PlatformComponentStatus -Installed $null -Ready $null -Namespace $PostgresNamespace -Release $PostgresRelease -Status "unknown" -Message "PostgreSQL status has not been checked."

    if (-not $KubectlAvailable -or [string]$ManagementCluster["status"] -ne "ready") {
        $backend["status"] = "error"
        $backend["message"] = "kubectl and a Ready devdeploy-mgmt cluster are required to verify the backend."
        $backend["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_backend_verify_prerequisites" -Label "Management backend verify prerequisites" -Status "failed" -Message ([string]$backend["message"]) -Details @{
            required          = $true
            target_cluster    = "devdeploy-mgmt"
            management_status = [string]$ManagementCluster["status"]
            read_only         = $true
        }
        return New-ManagementBackendBootstrapResult -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
    }

    $namespaceResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "get", "namespace", $PostgresNamespace, "--output", "name") -TimeoutSeconds 20
    if ($namespaceResult.exit_code -ne 0 -or $namespaceResult.timed_out) {
        $backend["status"] = "error"
        $backend["message"] = "Namespace devdeploy does not exist in devdeploy-mgmt."
        $backend["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_backend_verify_namespace" -Label "Management backend namespace verification" -Status "failed" -Message ([string]$backend["message"]) -Details @{
            required  = $true
            namespace = $PostgresNamespace
            read_only = $true
        }
        return New-ManagementBackendBootstrapResult -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
    }

    Add-Check -Id "management_backend_verify_namespace" -Label "Management backend namespace verification" -Status "ok" -Message "Namespace devdeploy exists in devdeploy-mgmt." -Details @{
        required  = $true
        namespace = $PostgresNamespace
        read_only = $true
    }

    $ingressControllerResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $IngressNginxNamespace, "get", "deployment", "ingress-nginx-controller", "--output", "jsonpath={.status.availableReplicas}") -TimeoutSeconds 20
    $ingressAvailable = 0
    [void][int]::TryParse(([string]$ingressControllerResult.stdout).Trim(), [ref]$ingressAvailable)
    if ($ingressControllerResult.exit_code -eq 0 -and -not $ingressControllerResult.timed_out -and $ingressAvailable -ge 1) {
        $ingress = New-PlatformComponentStatus -Installed $true -Ready $true -Namespace $IngressNginxNamespace -Release $IngressNginxRelease -Status "ready" -Message "Management ingress-nginx controller is Ready."
    }
    else {
        $ingress = New-PlatformComponentStatus -Installed $null -Ready $false -Namespace $IngressNginxNamespace -Release $IngressNginxRelease -Status "degraded" -Message "Management ingress-nginx controller is not Ready."
    }

    $postgresStatefulSet = "$PostgresRelease-postgresql"
    $postgresResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $PostgresNamespace, "get", "statefulset", $postgresStatefulSet, "--output", "jsonpath={.status.readyReplicas}") -TimeoutSeconds 20
    $postgresServiceResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $PostgresNamespace, "get", "service", $postgresStatefulSet, "--output", "name") -TimeoutSeconds 20
    $postgresReadyReplicas = 0
    [void][int]::TryParse(([string]$postgresResult.stdout).Trim(), [ref]$postgresReadyReplicas)
    if ($postgresResult.exit_code -eq 0 -and -not $postgresResult.timed_out -and $postgresReadyReplicas -ge 1 -and $postgresServiceResult.exit_code -eq 0 -and -not $postgresServiceResult.timed_out) {
        $postgres = New-PlatformComponentStatus -Installed $true -Ready $true -Namespace $PostgresNamespace -Release $PostgresRelease -Status "ready" -Message "Management PostgreSQL is Ready."
    }
    else {
        $postgres = New-PlatformComponentStatus -Installed $null -Ready $false -Namespace $PostgresNamespace -Release $PostgresRelease -Status "degraded" -Message "Management PostgreSQL is not Ready."
    }

    $backendSecret = Invoke-VerifyManagementBackendSecret -KubectlAvailable $KubectlAvailable -ManagementCluster $ManagementCluster
    if ([string]$backendSecret["status"] -ne "ready") {
        $backend["status"] = "error"
        $backend["message"] = "Backend runtime Secret did not pass read-only verification."
        $backend["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_backend_verify_secret" -Label "Management backend Secret verification" -Status "failed" -Message ([string]$backend["message"]) -Details @{
            required    = $true
            namespace   = $PostgresNamespace
            secret_name = $BackendSecretName
            read_only   = $true
        }
        return New-ManagementBackendBootstrapResult -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
    }

    Add-Check -Id "management_backend_verify_secret" -Label "Management backend Secret verification" -Status "ok" -Message "Backend runtime Secret passed read-only verification." -Details @{
        required    = $true
        namespace   = $PostgresNamespace
        secret_name = $BackendSecretName
        read_only   = $true
    }

    $deploymentJsonPath = "{.spec.replicas}|{.status.readyReplicas}|{.status.availableReplicas}|{.spec.template.spec.containers[0].image}"
    $deploymentResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $PostgresNamespace, "get", "deployment", "devdeploy-backend", "--output", "jsonpath=$deploymentJsonPath") -TimeoutSeconds 20
    if ($deploymentResult.exit_code -ne 0 -or $deploymentResult.timed_out -or [string]::IsNullOrWhiteSpace($deploymentResult.stdout)) {
        $backend["status"] = "error"
        $backend["message"] = "Deployment devdeploy-backend does not exist or could not be read."
        $backend["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_backend_verify_deployment" -Label "Management backend Deployment verification" -Status "failed" -Message ([string]$backend["message"]) -Details @{
            required   = $true
            namespace  = $PostgresNamespace
            deployment = "devdeploy-backend"
            read_only  = $true
        }
        return New-ManagementBackendBootstrapResult -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
    }

    $deploymentParts = @(([string]$deploymentResult.stdout).Split('|'))
    $desiredReplicas = 0
    $readyReplicas = 0
    $availableReplicas = 0
    if ($deploymentParts.Count -ge 4) {
        [void][int]::TryParse($deploymentParts[0], [ref]$desiredReplicas)
        [void][int]::TryParse($deploymentParts[1], [ref]$readyReplicas)
        [void][int]::TryParse($deploymentParts[2], [ref]$availableReplicas)
    }
    $deployedImage = if ($deploymentParts.Count -ge 4) { ([string]$deploymentParts[3]).Trim() } else { "" }
    $deploymentReady = [bool]($desiredReplicas -ge 1 -and $readyReplicas -eq $desiredReplicas -and $availableReplicas -eq $desiredReplicas)
    $imageMatches = [bool]($deployedImage -eq ([string]$backendImage["image"]).Trim())
    $backend["deployed"] = $true
    $backend["rollout_succeeded"] = $deploymentReady

    if (-not $deploymentReady -or -not $imageMatches) {
        $backend["status"] = "error"
        $backend["message"] = if (-not $imageMatches) { "Backend Deployment image does not match devdeploy-backend:local." } else { "Backend Deployment is not fully Available." }
        $backend["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_backend_verify_deployment" -Label "Management backend Deployment verification" -Status "failed" -Message ([string]$backend["message"]) -Details @{
            required           = $true
            namespace          = $PostgresNamespace
            deployment         = "devdeploy-backend"
            desired_replicas   = $desiredReplicas
            ready_replicas     = $readyReplicas
            available_replicas = $availableReplicas
            deployed_image     = $deployedImage
            image_matches      = $imageMatches
            read_only          = $true
        }
        return New-ManagementBackendBootstrapResult -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
    }

    $backendImage["loaded_to_management_cluster"] = $true
    $backendImage["target_cluster"] = "devdeploy-mgmt"
    $backendImage["status"] = "ready"
    $backendImage["message"] = "The running backend Deployment uses devdeploy-backend:local in devdeploy-mgmt."
    $backendImage["checked_at"] = [string](Get-Timestamp)
    Add-Check -Id "management_backend_verify_deployment" -Label "Management backend Deployment verification" -Status "ok" -Message "Backend Deployment is Available and uses devdeploy-backend:local." -Details @{
        required           = $true
        namespace          = $PostgresNamespace
        deployment         = "devdeploy-backend"
        desired_replicas   = $desiredReplicas
        ready_replicas     = $readyReplicas
        available_replicas = $availableReplicas
        image_matches      = $true
        read_only          = $true
    }

    $podJsonPath = '{range .items[*]}{.metadata.name}|{.status.phase}|{.status.containerStatuses[0].ready}|{.status.containerStatuses[0].restartCount};{end}'
    $podsResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $PostgresNamespace, "get", "pods", "--selector", "app.kubernetes.io/name=devdeploy-backend,app.kubernetes.io/component=backend", "--output", "jsonpath=$podJsonPath") -TimeoutSeconds 20
    $podSummaries = New-Object System.Collections.Generic.List[object]
    if ($podsResult.exit_code -eq 0 -and -not $podsResult.timed_out) {
        foreach ($podRecord in @(([string]$podsResult.stdout).Split(';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            $podParts = @(([string]$podRecord).Split('|'))
            if ($podParts.Count -ge 4) {
                $restartCount = 0
                [void][int]::TryParse($podParts[3], [ref]$restartCount)
                $podSummaries.Add([ordered]@{
                        name          = [string]$podParts[0]
                        phase         = [string]$podParts[1]
                        ready         = [bool]([string]$podParts[2] -eq "true")
                        restart_count = $restartCount
                    }) | Out-Null
            }
        }
    }
    $readyPods = @($podSummaries | Where-Object { $_["phase"] -eq "Running" -and $_["ready"] })
    if ($readyPods.Count -lt 1) {
        $backend["status"] = "error"
        $backend["message"] = "No Running and Ready backend Pod was found."
        $backend["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_backend_verify_pods" -Label "Management backend Pod verification" -Status "failed" -Message ([string]$backend["message"]) -Details @{
            required  = $true
            namespace = $PostgresNamespace
            pods      = @($podSummaries | ForEach-Object { $_ })
            read_only = $true
        }
        return New-ManagementBackendBootstrapResult -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
    }

    Add-Check -Id "management_backend_verify_pods" -Label "Management backend Pod verification" -Status "ok" -Message "At least one backend Pod is Running and Ready." -Details @{
        required  = $true
        namespace = $PostgresNamespace
        pods      = @($podSummaries | ForEach-Object { $_ })
        read_only = $true
    }

    $serviceResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $PostgresNamespace, "get", "service", "devdeploy-backend", "--output", "jsonpath={.spec.ports[0].port}") -TimeoutSeconds 20
    $servicePort = 0
    [void][int]::TryParse(([string]$serviceResult.stdout).Trim(), [ref]$servicePort)
    if ($serviceResult.exit_code -ne 0 -or $serviceResult.timed_out -or $servicePort -ne 8000) {
        $backend["status"] = "error"
        $backend["message"] = "Backend Service is missing or does not expose port 8000."
        $backend["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_backend_verify_service" -Label "Management backend Service verification" -Status "failed" -Message ([string]$backend["message"]) -Details @{
            required     = $true
            namespace    = $PostgresNamespace
            service      = "devdeploy-backend"
            service_port = $servicePort
            read_only    = $true
        }
        return New-ManagementBackendBootstrapResult -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
    }

    Add-Check -Id "management_backend_verify_service" -Label "Management backend Service verification" -Status "ok" -Message "Backend Service exists and exposes port 8000." -Details @{
        required     = $true
        namespace    = $PostgresNamespace
        service      = "devdeploy-backend"
        service_port = $servicePort
        read_only    = $true
    }

    $ingressJsonPath = "{.spec.ingressClassName}|{.spec.rules[0].http.paths[0].path}"
    $ingressResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $PostgresNamespace, "get", "ingress", "devdeploy-backend", "--output", "jsonpath=$ingressJsonPath") -TimeoutSeconds 20
    $ingressParts = if ($ingressResult.exit_code -eq 0 -and -not $ingressResult.timed_out) { @(([string]$ingressResult.stdout).Split('|')) } else { @() }
    $ingressClassValid = [bool]($ingressParts.Count -ge 2 -and ([string]$ingressParts[0]).Trim() -eq "nginx")
    $ingressPathValid = [bool]($ingressParts.Count -ge 2 -and ([string]$ingressParts[1]).Trim() -eq "/api")
    if (-not $ingressClassValid -or -not $ingressPathValid) {
        $backend["status"] = "error"
        $backend["message"] = "Backend Ingress is missing or its class/path does not match nginx and /api."
        $backend["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_backend_verify_ingress" -Label "Management backend Ingress verification" -Status "failed" -Message ([string]$backend["message"]) -Details @{
            required            = $true
            namespace           = $PostgresNamespace
            ingress             = "devdeploy-backend"
            ingress_class_valid = $ingressClassValid
            ingress_path_valid  = $ingressPathValid
            read_only           = $true
        }
        return New-ManagementBackendBootstrapResult -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
    }

    Add-Check -Id "management_backend_verify_ingress" -Label "Management backend Ingress verification" -Status "ok" -Message "Backend Ingress uses class nginx and routes /api." -Details @{
        required      = $true
        namespace     = $PostgresNamespace
        ingress       = "devdeploy-backend"
        ingress_class = "nginx"
        path          = "/api"
        read_only     = $true
    }

    $healthResult = Test-ManagementBackendHealth -KubectlAvailable $KubectlAvailable
    $backend["health_check_succeeded"] = [bool]$healthResult.success
    $backend["ready"] = $true
    $backend["checked_at"] = [string](Get-Timestamp)
    if ($healthResult.success) {
        $backend["status"] = "ready"
        $backend["message"] = "DevDeploy backend passed read-only deployment, Pod, networking, Secret, and health verification."
        Add-Check -Id "management_backend_verify_health" -Label "Management backend health verification" -Status "ok" -Message ([string]$healthResult.message) -Details @{
            required  = $false
            endpoint  = "/api/v1/health"
            method    = "temporary_port_forward"
            read_only = $true
        }
    }
    else {
        $backend["status"] = "warning"
        $backend["message"] = "Backend resources are ready, but the read-only health endpoint check did not succeed."
        Add-Check -Id "management_backend_verify_health" -Label "Management backend health verification" -Status "warning" -Message ([string]$healthResult.message) -Details @{
            required  = $false
            endpoint  = "/api/v1/health"
            method    = "temporary_port_forward"
            read_only = $true
        }
    }

    return New-ManagementBackendBootstrapResult -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
}

function New-ManagementFrontendBootstrapResult {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Frontend,

        [Parameter(Mandatory = $true)]
        [object]$FrontendImage,

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
        frontend       = $Frontend
        frontend_image = $FrontendImage
        backend        = $Backend
        backend_image  = $BackendImage
        backend_secret = $BackendSecret
        ingress        = $Ingress
        postgres       = $Postgres
    }
}

function Test-ManagementFrontendPage {
    param(
        [bool]$KubectlAvailable
    )

    if (-not $KubectlAvailable) {
        return [ordered]@{
            success = $false
            message = "kubectl is unavailable, so the frontend page could not be checked."
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
        $psi.Arguments = "--context kind-devdeploy-mgmt --namespace devdeploy port-forward service/devdeploy-frontend {0}:80 --address 127.0.0.1" -f $localPort
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true

        $portForward = New-Object System.Diagnostics.Process
        $portForward.StartInfo = $psi
        [void]$portForward.Start()

        $lastError = "Frontend page did not become reachable before timeout."
        for ($attempt = 1; $attempt -le 20; $attempt++) {
            if ($portForward.HasExited) {
                $lastError = "kubectl port-forward exited before the frontend page check completed."
                break
            }

            try {
                $response = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/" -f $localPort) -UseBasicParsing -TimeoutSec 3
                $content = [string]$response.Content
                if ([int]$response.StatusCode -eq 200 -and ($content -match '(?i)<!doctype\s+html|<html')) {
                    return [ordered]@{
                        success = $true
                        message = "Frontend service returned HTTP 200 with HTML content."
                    }
                }
                $lastError = "Frontend service returned an unexpected response."
            }
            catch {
                $lastError = "Frontend page is not reachable yet."
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
            message = "Frontend page port-forward could not be started safely."
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
                Write-LauncherLog "Frontend page port-forward cleanup requires manual process verification."
            }
            finally {
                $portForward.Dispose()
            }
        }
    }
}

function Test-ManagementIngressRoutes {
    $frontendSucceeded = $false
    $backendSucceeded = $false
    $frontendMessage = "Management frontend ingress route did not return the expected page."
    $backendMessage = "Management backend ingress route did not return the expected health response."

    try {
        $frontendResponse = Invoke-WebRequest -Uri "http://localhost:8080/" -UseBasicParsing -TimeoutSec 5
        $frontendContent = [string]$frontendResponse.Content
        if ([int]$frontendResponse.StatusCode -eq 200 -and ($frontendContent -match '(?i)<!doctype\s+html|<html')) {
            $frontendSucceeded = $true
            $frontendMessage = "Management ingress returned the frontend page."
        }
    }
    catch {
        $frontendMessage = "Management frontend ingress route is not reachable from the host."
    }

    try {
        $backendResponse = Invoke-WebRequest -Uri "http://localhost:8080/api/v1/health" -UseBasicParsing -TimeoutSec 5
        if ([int]$backendResponse.StatusCode -eq 200) {
            $payload = $backendResponse.Content | ConvertFrom-Json
            if ([string]$payload.status -eq "ok" -and [string]$payload.service -eq "devdeploy-backend") {
                $backendSucceeded = $true
                $backendMessage = "Management ingress returned the backend health response."
            }
        }
    }
    catch {
        $backendMessage = "Management backend ingress route is not reachable from the host."
    }

    return [ordered]@{
        frontend_success = $frontendSucceeded
        frontend_message = $frontendMessage
        backend_success  = $backendSucceeded
        backend_message  = $backendMessage
    }
}

function Invoke-BootstrapManagementFrontend {
    param(
        [bool]$KubectlAvailable,

        [Parameter(Mandatory = $true)]
        [object]$ManagementCluster
    )

    $frontend = New-ManagementFrontendStatus
    $frontend["mode"] = "bootstrap"
    $frontendImageStatus = New-ManagementFrontendImageStatus
    $backend = New-ManagementBackendStatus
    $backendImage = New-ManagementBackendImageStatus
    $backendSecret = New-ManagementBackendSecretStatus
    $ingress = New-PlatformComponentStatus -Installed $null -Ready $null -Namespace $IngressNginxNamespace -Release $IngressNginxRelease -Status "unknown" -Message "Management ingress status has not been checked."
    $postgres = New-PlatformComponentStatus -Installed $null -Ready $null -Namespace $PostgresNamespace -Release $PostgresRelease -Status "unknown" -Message "PostgreSQL status has not been checked."

    if (-not $KubectlAvailable -or [string]$ManagementCluster["status"] -ne "ready") {
        $frontend["status"] = "error"
        $frontend["message"] = "kubectl and a Ready devdeploy-mgmt cluster are required before bootstrapping the frontend."
        $frontend["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_frontend_prerequisites" -Label "Management frontend prerequisites" -Status "failed" -Message ([string]$frontend["message"]) -Details @{
            required          = $true
            target_cluster    = "devdeploy-mgmt"
            management_status = [string]$ManagementCluster["status"]
        }
        return New-ManagementFrontendBootstrapResult -Frontend $frontend -FrontendImage $frontendImageStatus -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
    }

    $namespaceResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "get", "namespace", $PostgresNamespace, "--output", "name") -TimeoutSeconds 20
    if ($namespaceResult.exit_code -ne 0 -or $namespaceResult.timed_out) {
        $frontend["status"] = "error"
        $frontend["message"] = "Namespace devdeploy does not exist. Run -BootstrapManagementPostgres first."
        $frontend["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_frontend_namespace" -Label "Management frontend namespace" -Status "failed" -Message ([string]$frontend["message"]) -Details @{
            required  = $true
            namespace = $PostgresNamespace
        }
        return New-ManagementFrontendBootstrapResult -Frontend $frontend -FrontendImage $frontendImageStatus -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
    }

    Add-Check -Id "management_frontend_namespace" -Label "Management frontend namespace" -Status "ok" -Message "Namespace devdeploy exists in devdeploy-mgmt." -Details @{
        required  = $true
        namespace = $PostgresNamespace
    }

    $backendVerification = Invoke-VerifyManagementBackend -KubectlAvailable $KubectlAvailable -ManagementCluster $ManagementCluster
    $backend = $backendVerification["backend"]
    $backendImage = $backendVerification["backend_image"]
    $backendSecret = $backendVerification["backend_secret"]
    $ingress = $backendVerification["ingress"]
    $postgres = $backendVerification["postgres"]
    if ([string]$ingress["status"] -ne "ready") {
        $frontend["status"] = "error"
        $frontend["message"] = "Management ingress-nginx must be Ready before bootstrapping the frontend."
        $frontend["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_frontend_ingress_prerequisite" -Label "Management frontend ingress prerequisite" -Status "failed" -Message ([string]$frontend["message"]) -Details @{
            required       = $true
            ingress_status = [string]$ingress["status"]
        }
        return New-ManagementFrontendBootstrapResult -Frontend $frontend -FrontendImage $frontendImageStatus -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
    }

    Add-Check -Id "management_frontend_ingress_prerequisite" -Label "Management frontend ingress prerequisite" -Status "ok" -Message "Management ingress-nginx is Ready." -Details @{
        required = $true
    }

    if ([string]$backend["status"] -ne "ready" -or -not [bool]$backend["health_check_succeeded"]) {
        $frontend["status"] = "error"
        $frontend["message"] = "The management backend must be Ready and healthy before bootstrapping the frontend."
        $frontend["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_frontend_backend_prerequisite" -Label "Management frontend backend prerequisite" -Status "failed" -Message ([string]$frontend["message"]) -Details @{
            required               = $true
            backend_status         = [string]$backend["status"]
            backend_health_succeeded = [bool]$backend["health_check_succeeded"]
        }
        return New-ManagementFrontendBootstrapResult -Frontend $frontend -FrontendImage $frontendImageStatus -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
    }

    Add-Check -Id "management_frontend_backend_prerequisite" -Label "Management frontend backend prerequisite" -Status "ok" -Message "The management backend is Ready and healthy." -Details @{
        required = $true
        endpoint = "/api/v1/health"
    }

    Add-Check -Id "management_frontend_image_prerequisite" -Label "Management frontend image prerequisite" -Status "ok" -Message "Frontend image availability in devdeploy-mgmt will be verified by Deployment rollout readiness." -Details @{
        required = $true
        image    = $FrontendImage
    }

    if (-not (Test-Path -LiteralPath $FrontendManifestPath -PathType Container) -or -not (Test-Path -LiteralPath $FrontendKustomizationPath -PathType Leaf)) {
        $frontend["status"] = "error"
        $frontend["message"] = "Frontend manifest directory or kustomization.yaml is missing."
        $frontend["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_frontend_render" -Label "Management frontend manifest render" -Status "failed" -Message ([string]$frontend["message"]) -Details @{
            required       = $true
            manifests_path = $FrontendManifestRelativePath
        }
        return New-ManagementFrontendBootstrapResult -Frontend $frontend -FrontendImage $frontendImageStatus -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
    }

    # Preserve render output only in memory for kind validation; it is never logged or written to status.
    $renderResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("kustomize", $FrontendManifestPath) -TimeoutSeconds 30 -PreserveStandardOutput $true
    if ($renderResult.exit_code -ne 0 -or $renderResult.timed_out) {
        $frontend["status"] = "error"
        $frontend["message"] = "Frontend Kustomize render failed; no frontend manifests were applied."
        $frontend["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_frontend_render" -Label "Management frontend manifest render" -Status "failed" -Message ([string]$frontend["message"]) -Details @{
            required       = $true
            manifests_path = $FrontendManifestRelativePath
            error          = $renderResult.stderr
        }
        return New-ManagementFrontendBootstrapResult -Frontend $frontend -FrontendImage $frontendImageStatus -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
    }

    $renderedKinds = @([regex]::Matches([string]$renderResult.stdout, '(?m)^kind:[ \t]*([A-Za-z0-9]+)[ \t]*\r?$') | ForEach-Object { [string]$_.Groups[1].Value })
    $expectedKinds = @("Deployment", "Ingress", "Service")
    $unexpectedKinds = @($renderedKinds | Where-Object { $_ -notin $expectedKinds })
    $kindSetValid = [bool]($renderedKinds.Count -eq 3 -and $unexpectedKinds.Count -eq 0)
    foreach ($expectedKind in $expectedKinds) {
        if (@($renderedKinds | Where-Object { $_ -eq $expectedKind }).Count -ne 1) {
            $kindSetValid = $false
        }
    }

    if (-not $kindSetValid) {
        $frontend["status"] = "error"
        $frontend["message"] = "Frontend render must contain exactly one Service, Deployment, and Ingress, with no Secret or ConfigMap."
        $frontend["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_frontend_render" -Label "Management frontend manifest render" -Status "failed" -Message ([string]$frontend["message"]) -Details @{
            required       = $true
            manifests_path = $FrontendManifestRelativePath
            rendered_kinds = $renderedKinds
        }
        return New-ManagementFrontendBootstrapResult -Frontend $frontend -FrontendImage $frontendImageStatus -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
    }

    Add-Check -Id "management_frontend_render" -Label "Management frontend manifest render" -Status "ok" -Message "Frontend manifests rendered with only Service, Deployment, and Ingress resources." -Details @{
        required       = $true
        manifests_path = $FrontendManifestRelativePath
        rendered_kinds = $renderedKinds
    }

    Write-LauncherLog "Applying only platform/management/frontend to devdeploy-mgmt."
    if (-not $Quiet) {
        Write-Host "Applying management frontend manifests to devdeploy-mgmt..."
    }
    $applyResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "apply", "--kustomize", $FrontendManifestPath) -TimeoutSeconds 60
    if ($applyResult.exit_code -ne 0 -or $applyResult.timed_out) {
        $frontend["status"] = "error"
        $frontend["message"] = "Frontend manifest apply failed. No automatic cleanup was performed."
        $frontend["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_frontend_apply" -Label "Management frontend manifest apply" -Status "failed" -Message ([string]$frontend["message"]) -Details @{
            required       = $true
            manifests_path = $FrontendManifestRelativePath
            target_cluster = "devdeploy-mgmt"
            error          = $applyResult.stderr
        }
        return New-ManagementFrontendBootstrapResult -Frontend $frontend -FrontendImage $frontendImageStatus -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
    }

    $frontend["deployed"] = $true
    Add-Check -Id "management_frontend_apply" -Label "Management frontend manifest apply" -Status "ok" -Message "Applied only the management frontend Kustomize resources to devdeploy-mgmt." -Details @{
        required       = $true
        manifests_path = $FrontendManifestRelativePath
        target_cluster = "devdeploy-mgmt"
    }

    $rolloutResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $PostgresNamespace, "rollout", "status", "deployment/devdeploy-frontend", "--timeout=240s") -TimeoutSeconds 270
    if ($rolloutResult.exit_code -ne 0 -or $rolloutResult.timed_out) {
        $frontend["status"] = "error"
        $frontend["message"] = "Frontend Deployment did not become Available before timeout."
        $frontend["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_frontend_rollout" -Label "Management frontend rollout" -Status "failed" -Message ([string]$frontend["message"]) -Details @{
            required   = $true
            namespace  = $PostgresNamespace
            deployment = "devdeploy-frontend"
            error      = $rolloutResult.stderr
        }
        return New-ManagementFrontendBootstrapResult -Frontend $frontend -FrontendImage $frontendImageStatus -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
    }

    $frontend["rollout_succeeded"] = $true
    $frontendImageStatus["loaded_to_management_cluster"] = $true
    $frontendImageStatus["target_cluster"] = "devdeploy-mgmt"
    $frontendImageStatus["status"] = "ready"
    $frontendImageStatus["message"] = "Frontend Deployment rollout verified devdeploy-frontend:local availability in devdeploy-mgmt."
    $frontendImageStatus["checked_at"] = [string](Get-Timestamp)
    Add-Check -Id "management_frontend_rollout" -Label "Management frontend rollout" -Status "ok" -Message "Frontend Deployment became Available." -Details @{
        required   = $true
        namespace  = $PostgresNamespace
        deployment = "devdeploy-frontend"
        image      = $FrontendImage
    }

    $deploymentJsonPath = "{.spec.template.spec.containers[0].image}|{.spec.template.spec.containers[0].ports[0].name}|{.spec.template.spec.containers[0].ports[0].containerPort}"
    $deploymentResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $PostgresNamespace, "get", "deployment", "devdeploy-frontend", "--output", "jsonpath=$deploymentJsonPath") -TimeoutSeconds 20
    $deploymentParts = if ($deploymentResult.exit_code -eq 0 -and -not $deploymentResult.timed_out) { @(([string]$deploymentResult.stdout).Split('|')) } else { @() }
    $deploymentValid = [bool]($deploymentParts.Count -ge 3 -and ([string]$deploymentParts[0]).Trim() -eq $FrontendImage -and ([string]$deploymentParts[1]).Trim() -eq "http" -and ([string]$deploymentParts[2]).Trim() -eq "8080")

    $serviceJsonPath = "{.spec.ports[0].port}|{.spec.ports[0].targetPort}"
    $serviceResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $PostgresNamespace, "get", "service", "devdeploy-frontend", "--output", "jsonpath=$serviceJsonPath") -TimeoutSeconds 20
    $serviceParts = if ($serviceResult.exit_code -eq 0 -and -not $serviceResult.timed_out) { @(([string]$serviceResult.stdout).Split('|')) } else { @() }
    $serviceValid = [bool]($serviceParts.Count -ge 2 -and ([string]$serviceParts[0]).Trim() -eq "80" -and ([string]$serviceParts[1]).Trim() -eq "http")

    $ingressJsonPath = "{.spec.ingressClassName}|{.spec.rules[0].host}|{.spec.rules[0].http.paths[0].path}"
    $ingressResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $PostgresNamespace, "get", "ingress", "devdeploy-frontend", "--output", "jsonpath=$ingressJsonPath") -TimeoutSeconds 20
    $ingressParts = if ($ingressResult.exit_code -eq 0 -and -not $ingressResult.timed_out) { @(([string]$ingressResult.stdout).Split('|')) } else { @() }
    $ingressValid = [bool]($ingressParts.Count -ge 3 -and ([string]$ingressParts[0]).Trim() -eq "nginx" -and [string]::IsNullOrWhiteSpace([string]$ingressParts[1]) -and ([string]$ingressParts[2]).Trim() -eq "/")

    if (-not $deploymentValid -or -not $serviceValid -or -not $ingressValid) {
        $frontend["status"] = "error"
        $frontend["message"] = "Frontend Deployment, Service, or Ingress does not match the expected management contract."
        $frontend["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_frontend_resources" -Label "Management frontend resources" -Status "failed" -Message ([string]$frontend["message"]) -Details @{
            required         = $true
            deployment_valid = $deploymentValid
            service_valid    = $serviceValid
            ingress_valid    = $ingressValid
        }
        return New-ManagementFrontendBootstrapResult -Frontend $frontend -FrontendImage $frontendImageStatus -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
    }

    Add-Check -Id "management_frontend_resources" -Label "Management frontend resources" -Status "ok" -Message "Frontend Deployment, Service, and hostless Ingress match the expected contract." -Details @{
        required              = $true
        namespace             = $PostgresNamespace
        image                 = $FrontendImage
        container_port        = 8080
        service_port          = 80
        service_target_port   = "http"
        ingress_class         = "nginx"
        ingress_hostless      = $true
        ingress_path          = "/"
    }

    $pageResult = Test-ManagementFrontendPage -KubectlAvailable $KubectlAvailable
    $frontend["page_check_succeeded"] = [bool]$pageResult.success
    Add-Check -Id "management_frontend_page" -Label "Management frontend page" -Status $(if ($pageResult.success) { "ok" } else { "warning" }) -Message ([string]$pageResult.message) -Details @{
        required = $false
        endpoint = "/"
        method   = "temporary_port_forward"
    }

    $ingressRoutes = Test-ManagementIngressRoutes
    $frontend["ingress_page_check_succeeded"] = [bool]$ingressRoutes.frontend_success
    $frontend["backend_api_route_check_succeeded"] = [bool]$ingressRoutes.backend_success
    Add-Check -Id "management_frontend_ingress_page" -Label "Management frontend ingress page" -Status $(if ($ingressRoutes.frontend_success) { "ok" } else { "warning" }) -Message ([string]$ingressRoutes.frontend_message) -Details @{
        required = $false
        endpoint = "http://localhost:8080/"
    }
    Add-Check -Id "management_frontend_backend_route" -Label "Management backend ingress route" -Status $(if ($ingressRoutes.backend_success) { "ok" } else { "warning" }) -Message ([string]$ingressRoutes.backend_message) -Details @{
        required = $false
        endpoint = "http://localhost:8080/api/v1/health"
    }

    $frontend["ready"] = $true
    $frontend["checked_at"] = [string](Get-Timestamp)
    if ($pageResult.success -and $ingressRoutes.frontend_success -and $ingressRoutes.backend_success) {
        $frontend["status"] = "ready"
        $frontend["message"] = "DevDeploy frontend is deployed, Available, and reachable through management ingress."
    }
    else {
        $frontend["status"] = "warning"
        $frontend["message"] = "DevDeploy frontend is deployed and Available, but one or more page or ingress route checks need review."
    }

    return New-ManagementFrontendBootstrapResult -Frontend $frontend -FrontendImage $frontendImageStatus -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
}

function Get-ManagementFrontendRuntimeStatus {
    param(
        [bool]$KubectlAvailable,

        [Parameter(Mandatory = $true)]
        [object]$ManagementCluster
    )

    $status = New-ManagementFrontendStatus
    $status["mode"] = "verify"

    if (-not $KubectlAvailable -or [string]$ManagementCluster["status"] -ne "ready") {
        $status["status"] = "unknown"
        $status["message"] = "Frontend runtime status could not be checked without kubectl and a Ready management cluster."
        $status["checked_at"] = [string](Get-Timestamp)
        return $status
    }

    $deploymentJsonPath = "{.spec.replicas}|{.status.readyReplicas}|{.status.availableReplicas}|{.spec.template.spec.containers[0].image}"
    $deploymentResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $PostgresNamespace, "get", "deployment", "devdeploy-frontend", "--output", "jsonpath=$deploymentJsonPath") -TimeoutSeconds 20
    $deploymentParts = if ($deploymentResult.exit_code -eq 0 -and -not $deploymentResult.timed_out) { @(([string]$deploymentResult.stdout).Split('|')) } else { @() }
    $desiredReplicas = 0
    $readyReplicas = 0
    $availableReplicas = 0
    if ($deploymentParts.Count -ge 4) {
        [void][int]::TryParse(([string]$deploymentParts[0]).Trim(), [ref]$desiredReplicas)
        [void][int]::TryParse(([string]$deploymentParts[1]).Trim(), [ref]$readyReplicas)
        [void][int]::TryParse(([string]$deploymentParts[2]).Trim(), [ref]$availableReplicas)
    }
    $deployedImage = if ($deploymentParts.Count -ge 4) { ([string]$deploymentParts[3]).Trim() } else { "" }
    $deploymentReady = [bool]($desiredReplicas -ge 1 -and $readyReplicas -eq $desiredReplicas -and $availableReplicas -eq $desiredReplicas -and $deployedImage -eq ([string]$script:FrontendImage))

    $serviceResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $PostgresNamespace, "get", "service", "devdeploy-frontend", "--output", "name") -TimeoutSeconds 20
    $ingressResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $PostgresNamespace, "get", "ingress", "devdeploy-frontend", "--output", "name") -TimeoutSeconds 20
    $resourcesReady = [bool]($deploymentReady -and $serviceResult.exit_code -eq 0 -and -not $serviceResult.timed_out -and $ingressResult.exit_code -eq 0 -and -not $ingressResult.timed_out)

    if (-not $resourcesReady) {
        $status["status"] = "not_started"
        $status["message"] = "Management frontend resources are missing or not fully Ready."
        $status["checked_at"] = [string](Get-Timestamp)
        return $status
    }

    $status["deployed"] = $true
    $status["ready"] = $true
    $status["rollout_succeeded"] = $true
    $pageResult = Test-ManagementFrontendPage -KubectlAvailable $KubectlAvailable
    $ingressRoutes = Test-ManagementIngressRoutes
    $status["page_check_succeeded"] = [bool]$pageResult.success
    $status["ingress_page_check_succeeded"] = [bool]$ingressRoutes.frontend_success
    $status["backend_api_route_check_succeeded"] = [bool]$ingressRoutes.backend_success
    $status["checked_at"] = [string](Get-Timestamp)
    if ($pageResult.success -and $ingressRoutes.frontend_success -and $ingressRoutes.backend_success) {
        $status["status"] = "ready"
        $status["message"] = "Management frontend runtime resources and routes are Ready."
    }
    else {
        $status["status"] = "warning"
        $status["message"] = "Management frontend resources are Ready, but one or more page or ingress checks need review."
    }

    return $status
}

function Invoke-VerifyManagementFrontend {
    param(
        [bool]$KubectlAvailable,

        [Parameter(Mandatory = $true)]
        [object]$ManagementCluster
    )

    $frontend = New-ManagementFrontendStatus
    $frontend["mode"] = "verify"
    $frontendImageStatus = New-ManagementFrontendImageStatus
    $backend = New-ManagementBackendStatus
    $backendImage = New-ManagementBackendImageStatus
    $backendSecret = New-ManagementBackendSecretStatus
    $ingress = New-PlatformComponentStatus -Installed $null -Ready $null -Namespace $IngressNginxNamespace -Release $IngressNginxRelease -Status "unknown" -Message "Management ingress status has not been checked."
    $postgres = New-PlatformComponentStatus -Installed $null -Ready $null -Namespace $PostgresNamespace -Release $PostgresRelease -Status "unknown" -Message "PostgreSQL status has not been checked."

    if (-not $KubectlAvailable -or [string]$ManagementCluster["status"] -ne "ready") {
        $frontend["status"] = "error"
        $frontend["message"] = "kubectl and a Ready devdeploy-mgmt cluster are required to verify the frontend."
        $frontend["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_frontend_verify_prerequisites" -Label "Management frontend verify prerequisites" -Status "failed" -Message ([string]$frontend["message"]) -Details @{
            required          = $true
            target_cluster    = "devdeploy-mgmt"
            management_status = [string]$ManagementCluster["status"]
            read_only         = $true
        }
        return New-ManagementFrontendBootstrapResult -Frontend $frontend -FrontendImage $frontendImageStatus -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
    }

    $namespaceResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "get", "namespace", $PostgresNamespace, "--output", "name") -TimeoutSeconds 20
    if ($namespaceResult.exit_code -ne 0 -or $namespaceResult.timed_out) {
        $frontend["status"] = "error"
        $frontend["message"] = "Namespace devdeploy does not exist in devdeploy-mgmt."
        $frontend["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_frontend_verify_namespace" -Label "Management frontend namespace verification" -Status "failed" -Message ([string]$frontend["message"]) -Details @{
            required  = $true
            namespace = $PostgresNamespace
            read_only = $true
        }
        return New-ManagementFrontendBootstrapResult -Frontend $frontend -FrontendImage $frontendImageStatus -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
    }

    Add-Check -Id "management_frontend_verify_namespace" -Label "Management frontend namespace verification" -Status "ok" -Message "Namespace devdeploy exists in devdeploy-mgmt." -Details @{
        required  = $true
        namespace = $PostgresNamespace
        read_only = $true
    }

    $backendVerification = Invoke-VerifyManagementBackend -KubectlAvailable $KubectlAvailable -ManagementCluster $ManagementCluster
    $backend = $backendVerification["backend"]
    $backendImage = $backendVerification["backend_image"]
    $backendSecret = $backendVerification["backend_secret"]
    $ingress = $backendVerification["ingress"]
    $postgres = $backendVerification["postgres"]

    if ([string]$ingress["status"] -ne "ready") {
        $frontend["status"] = "error"
        $frontend["message"] = "Management ingress-nginx is not Ready."
        $frontend["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_frontend_verify_ingress_controller" -Label "Management frontend ingress controller verification" -Status "failed" -Message ([string]$frontend["message"]) -Details @{
            required       = $true
            ingress_status = [string]$ingress["status"]
            read_only      = $true
        }
        return New-ManagementFrontendBootstrapResult -Frontend $frontend -FrontendImage $frontendImageStatus -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
    }

    Add-Check -Id "management_frontend_verify_ingress_controller" -Label "Management frontend ingress controller verification" -Status "ok" -Message "Management ingress-nginx controller is Ready." -Details @{
        required  = $true
        read_only = $true
    }

    if ([string]$backend["status"] -ne "ready" -or -not [bool]$backend["health_check_succeeded"]) {
        $frontend["status"] = "error"
        $frontend["message"] = "Management backend availability and health verification failed."
        $frontend["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_frontend_verify_backend" -Label "Management frontend backend verification" -Status "failed" -Message ([string]$frontend["message"]) -Details @{
            required                 = $true
            backend_status           = [string]$backend["status"]
            backend_health_succeeded = [bool]$backend["health_check_succeeded"]
            read_only                = $true
        }
        return New-ManagementFrontendBootstrapResult -Frontend $frontend -FrontendImage $frontendImageStatus -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
    }

    Add-Check -Id "management_frontend_verify_backend" -Label "Management frontend backend verification" -Status "ok" -Message "Management backend Deployment and health endpoint are Ready." -Details @{
        required  = $true
        endpoint  = "/api/v1/health"
        read_only = $true
    }

    $deploymentJsonPath = "{.spec.replicas}|{.status.readyReplicas}|{.status.availableReplicas}|{.spec.template.spec.containers[0].image}|{.spec.template.spec.containers[0].ports[0].name}|{.spec.template.spec.containers[0].ports[0].containerPort}"
    $deploymentResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $PostgresNamespace, "get", "deployment", "devdeploy-frontend", "--output", "jsonpath=$deploymentJsonPath") -TimeoutSeconds 20
    if ($deploymentResult.exit_code -ne 0 -or $deploymentResult.timed_out -or [string]::IsNullOrWhiteSpace([string]$deploymentResult.stdout)) {
        $frontend["status"] = "error"
        $frontend["message"] = "Deployment devdeploy-frontend does not exist or could not be read."
        $frontend["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_frontend_verify_deployment" -Label "Management frontend Deployment verification" -Status "failed" -Message ([string]$frontend["message"]) -Details @{
            required   = $true
            namespace  = $PostgresNamespace
            deployment = "devdeploy-frontend"
            read_only  = $true
        }
        return New-ManagementFrontendBootstrapResult -Frontend $frontend -FrontendImage $frontendImageStatus -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
    }

    $deploymentParts = @(([string]$deploymentResult.stdout).Split('|'))
    $desiredReplicas = 0
    $readyReplicas = 0
    $availableReplicas = 0
    if ($deploymentParts.Count -ge 6) {
        [void][int]::TryParse(([string]$deploymentParts[0]).Trim(), [ref]$desiredReplicas)
        [void][int]::TryParse(([string]$deploymentParts[1]).Trim(), [ref]$readyReplicas)
        [void][int]::TryParse(([string]$deploymentParts[2]).Trim(), [ref]$availableReplicas)
    }
    $deployedImage = if ($deploymentParts.Count -ge 6) { ([string]$deploymentParts[3]).Trim() } else { "" }
    $containerPortName = if ($deploymentParts.Count -ge 6) { ([string]$deploymentParts[4]).Trim() } else { "" }
    $containerPort = 0
    if ($deploymentParts.Count -ge 6) {
        [void][int]::TryParse(([string]$deploymentParts[5]).Trim(), [ref]$containerPort)
    }
    $replicasReady = [bool]($desiredReplicas -ge 1 -and $readyReplicas -eq $desiredReplicas -and $availableReplicas -eq $desiredReplicas)
    $imageMatches = [bool]($deployedImage -eq ([string]$script:FrontendImage))
    $portMatches = [bool]($containerPortName -eq "http" -and $containerPort -eq 8080)
    $frontend["deployed"] = $true
    $frontend["rollout_succeeded"] = $replicasReady

    if (-not $replicasReady -or -not $imageMatches -or -not $portMatches) {
        $frontend["status"] = "error"
        $frontend["message"] = "Frontend Deployment is not fully Available or does not match the expected image and port contract."
        $frontend["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_frontend_verify_deployment" -Label "Management frontend Deployment verification" -Status "failed" -Message ([string]$frontend["message"]) -Details @{
            required           = $true
            desired_replicas   = $desiredReplicas
            ready_replicas     = $readyReplicas
            available_replicas = $availableReplicas
            deployed_image     = $deployedImage
            image_matches      = $imageMatches
            container_port     = $containerPort
            port_matches       = $portMatches
            read_only          = $true
        }
        return New-ManagementFrontendBootstrapResult -Frontend $frontend -FrontendImage $frontendImageStatus -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
    }

    $frontendImageStatus["loaded_to_management_cluster"] = $true
    $frontendImageStatus["target_cluster"] = "devdeploy-mgmt"
    $frontendImageStatus["status"] = "ready"
    $frontendImageStatus["message"] = "The running frontend Deployment uses devdeploy-frontend:local in devdeploy-mgmt."
    $frontendImageStatus["checked_at"] = [string](Get-Timestamp)
    Add-Check -Id "management_frontend_verify_deployment" -Label "Management frontend Deployment verification" -Status "ok" -Message "Frontend Deployment is Available and matches the expected image and port contract." -Details @{
        required           = $true
        desired_replicas   = $desiredReplicas
        ready_replicas     = $readyReplicas
        available_replicas = $availableReplicas
        image              = $deployedImage
        container_port     = $containerPort
        read_only          = $true
    }

    $podJsonPath = '{range .items[*]}{.metadata.name}|{.status.phase}|{.status.containerStatuses[0].ready}|{.status.containerStatuses[0].restartCount};{end}'
    $podsResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $PostgresNamespace, "get", "pods", "--selector", "app.kubernetes.io/name=devdeploy-frontend,app.kubernetes.io/component=frontend", "--output", "jsonpath=$podJsonPath") -TimeoutSeconds 20
    $podSummaries = New-Object System.Collections.Generic.List[object]
    if ($podsResult.exit_code -eq 0 -and -not $podsResult.timed_out) {
        foreach ($podRecord in @(([string]$podsResult.stdout).Split(';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            $podParts = @(([string]$podRecord).Split('|'))
            if ($podParts.Count -ge 4) {
                $restartCount = 0
                [void][int]::TryParse(([string]$podParts[3]).Trim(), [ref]$restartCount)
                $podSummaries.Add([ordered]@{
                        name          = ([string]$podParts[0]).Trim()
                        phase         = ([string]$podParts[1]).Trim()
                        ready         = [bool](([string]$podParts[2]).Trim() -eq "true")
                        restart_count = $restartCount
                    }) | Out-Null
            }
        }
    }
    $readyPods = @($podSummaries | Where-Object { $_["phase"] -eq "Running" -and $_["ready"] })
    if ($readyPods.Count -lt 1) {
        $frontend["status"] = "error"
        $frontend["message"] = "No Running and Ready frontend Pod was found."
        $frontend["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_frontend_verify_pods" -Label "Management frontend Pod verification" -Status "failed" -Message ([string]$frontend["message"]) -Details @{
            required  = $true
            namespace = $PostgresNamespace
            pods      = @($podSummaries | ForEach-Object { $_ })
            read_only = $true
        }
        return New-ManagementFrontendBootstrapResult -Frontend $frontend -FrontendImage $frontendImageStatus -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
    }

    Add-Check -Id "management_frontend_verify_pods" -Label "Management frontend Pod verification" -Status "ok" -Message "At least one frontend Pod is Running and Ready." -Details @{
        required  = $true
        namespace = $PostgresNamespace
        pods      = @($podSummaries | ForEach-Object { $_ })
        read_only = $true
    }

    $serviceJsonPath = "{.spec.ports[0].port}|{.spec.ports[0].targetPort}"
    $serviceResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $PostgresNamespace, "get", "service", "devdeploy-frontend", "--output", "jsonpath=$serviceJsonPath") -TimeoutSeconds 20
    $serviceParts = if ($serviceResult.exit_code -eq 0 -and -not $serviceResult.timed_out) { @(([string]$serviceResult.stdout).Split('|')) } else { @() }
    $serviceValid = [bool]($serviceParts.Count -ge 2 -and ([string]$serviceParts[0]).Trim() -eq "80" -and ([string]$serviceParts[1]).Trim() -eq "http")
    if (-not $serviceValid) {
        $frontend["status"] = "error"
        $frontend["message"] = "Frontend Service is missing or does not expose port 80 with targetPort http."
        $frontend["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_frontend_verify_service" -Label "Management frontend Service verification" -Status "failed" -Message ([string]$frontend["message"]) -Details @{
            required  = $true
            namespace = $PostgresNamespace
            service   = "devdeploy-frontend"
            read_only = $true
        }
        return New-ManagementFrontendBootstrapResult -Frontend $frontend -FrontendImage $frontendImageStatus -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
    }

    Add-Check -Id "management_frontend_verify_service" -Label "Management frontend Service verification" -Status "ok" -Message "Frontend Service exposes port 80 with targetPort http." -Details @{
        required    = $true
        namespace   = $PostgresNamespace
        service     = "devdeploy-frontend"
        service_port = 80
        target_port = "http"
        read_only   = $true
    }

    $ingressJsonPath = "{.spec.ingressClassName}|{.spec.rules[0].host}|{.spec.rules[0].http.paths[0].path}"
    $ingressResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $PostgresNamespace, "get", "ingress", "devdeploy-frontend", "--output", "jsonpath=$ingressJsonPath") -TimeoutSeconds 20
    $ingressParts = if ($ingressResult.exit_code -eq 0 -and -not $ingressResult.timed_out) { @(([string]$ingressResult.stdout).Split('|')) } else { @() }
    $ingressValid = [bool]($ingressParts.Count -ge 3 -and ([string]$ingressParts[0]).Trim() -eq "nginx" -and [string]::IsNullOrWhiteSpace([string]$ingressParts[1]) -and ([string]$ingressParts[2]).Trim() -eq "/")
    if (-not $ingressValid) {
        $frontend["status"] = "error"
        $frontend["message"] = "Frontend Ingress is missing or does not match the hostless nginx / contract."
        $frontend["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_frontend_verify_ingress" -Label "Management frontend Ingress verification" -Status "failed" -Message ([string]$frontend["message"]) -Details @{
            required  = $true
            namespace = $PostgresNamespace
            ingress   = "devdeploy-frontend"
            read_only = $true
        }
        return New-ManagementFrontendBootstrapResult -Frontend $frontend -FrontendImage $frontendImageStatus -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
    }

    Add-Check -Id "management_frontend_verify_ingress" -Label "Management frontend Ingress verification" -Status "ok" -Message "Frontend Ingress is hostless, uses class nginx, and routes /." -Details @{
        required      = $true
        namespace     = $PostgresNamespace
        ingress       = "devdeploy-frontend"
        ingress_class = "nginx"
        hostless      = $true
        path          = "/"
        read_only     = $true
    }

    $pageResult = Test-ManagementFrontendPage -KubectlAvailable $KubectlAvailable
    $frontend["page_check_succeeded"] = [bool]$pageResult.success
    Add-Check -Id "management_frontend_verify_page" -Label "Management frontend page verification" -Status $(if ($pageResult.success) { "ok" } else { "warning" }) -Message ([string]$pageResult.message) -Details @{
        required  = $false
        endpoint  = "/"
        method    = "temporary_port_forward"
        read_only = $true
    }

    $ingressRoutes = Test-ManagementIngressRoutes
    $frontend["ingress_page_check_succeeded"] = [bool]$ingressRoutes.frontend_success
    $frontend["backend_api_route_check_succeeded"] = [bool]$ingressRoutes.backend_success
    Add-Check -Id "management_frontend_verify_ingress_page" -Label "Management frontend ingress page verification" -Status $(if ($ingressRoutes.frontend_success) { "ok" } else { "warning" }) -Message ([string]$ingressRoutes.frontend_message) -Details @{
        required  = $false
        endpoint  = "http://localhost:8080/"
        read_only = $true
    }
    Add-Check -Id "management_frontend_verify_backend_route" -Label "Management backend ingress route verification" -Status $(if ($ingressRoutes.backend_success) { "ok" } else { "warning" }) -Message ([string]$ingressRoutes.backend_message) -Details @{
        required  = $false
        endpoint  = "http://localhost:8080/api/v1/health"
        read_only = $true
    }

    $frontend["ready"] = $true
    $frontend["checked_at"] = [string](Get-Timestamp)
    if ($pageResult.success -and $ingressRoutes.frontend_success -and $ingressRoutes.backend_success) {
        $frontend["status"] = "ready"
        $frontend["message"] = "DevDeploy frontend passed read-only Deployment, Pod, Service, Ingress, page, and route verification."
    }
    else {
        $frontend["status"] = "warning"
        $frontend["message"] = "Frontend resources are Ready, but one or more read-only page or ingress route checks need review."
    }

    return New-ManagementFrontendBootstrapResult -Frontend $frontend -FrontendImage $frontendImageStatus -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Ingress $ingress -Postgres $postgres
}

function New-ManagementBackendDatabaseResult {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Database,

        [Parameter(Mandatory = $true)]
        [object]$Backend,

        [Parameter(Mandatory = $true)]
        [object]$BackendImage,

        [Parameter(Mandatory = $true)]
        [object]$BackendSecret,

        [Parameter(Mandatory = $true)]
        [object]$Frontend,

        [Parameter(Mandatory = $true)]
        [object]$Ingress,

        [Parameter(Mandatory = $true)]
        [object]$Postgres
    )

    return [ordered]@{
        backend_database = $Database
        backend          = $Backend
        backend_image    = $BackendImage
        backend_secret   = $BackendSecret
        frontend         = $Frontend
        ingress          = $Ingress
        postgres         = $Postgres
    }
}

function Invoke-InitializeManagementBackendDatabase {
    param(
        [bool]$KubectlAvailable,

        [Parameter(Mandatory = $true)]
        [object]$ManagementCluster
    )

    $database = New-ManagementBackendDatabaseStatus
    $backend = New-ManagementBackendStatus
    $backendImage = New-ManagementBackendImageStatus
    $backendSecret = New-ManagementBackendSecretStatus
    $frontend = New-ManagementFrontendStatus
    $ingress = New-PlatformComponentStatus -Installed $null -Ready $null -Namespace $IngressNginxNamespace -Release $IngressNginxRelease -Status "unknown" -Message "Management ingress status has not been checked."
    $postgres = New-PlatformComponentStatus -Installed $null -Ready $null -Namespace $PostgresNamespace -Release $PostgresRelease -Status "unknown" -Message "PostgreSQL status has not been checked."

    if (-not $KubectlAvailable -or [string]$ManagementCluster["status"] -ne "ready") {
        $database["status"] = "error"
        $database["message"] = "kubectl and a Ready devdeploy-mgmt cluster are required before initializing the backend database."
        $database["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_backend_database_prerequisites" -Label "Management backend database prerequisites" -Status "failed" -Message ([string]$database["message"]) -Details @{
            required          = $true
            target_cluster    = "devdeploy-mgmt"
            management_status = [string]$ManagementCluster["status"]
        }
        return New-ManagementBackendDatabaseResult -Database $database -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Frontend $frontend -Ingress $ingress -Postgres $postgres
    }

    $backendVerification = Invoke-VerifyManagementBackend -KubectlAvailable $KubectlAvailable -ManagementCluster $ManagementCluster
    $backend = $backendVerification["backend"]
    $backendImage = $backendVerification["backend_image"]
    $backendSecret = $backendVerification["backend_secret"]
    $ingress = $backendVerification["ingress"]
    $postgres = $backendVerification["postgres"]
    $frontend = Get-ManagementFrontendRuntimeStatus -KubectlAvailable $KubectlAvailable -ManagementCluster $ManagementCluster

    if ([string]$postgres["status"] -ne "ready") {
        $database["status"] = "error"
        $database["message"] = "Management PostgreSQL must be Ready before running Alembic migrations."
        $database["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_backend_database_postgres" -Label "Management backend database PostgreSQL" -Status "failed" -Message ([string]$database["message"]) -Details @{
            required        = $true
            postgres_status = [string]$postgres["status"]
        }
        return New-ManagementBackendDatabaseResult -Database $database -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Frontend $frontend -Ingress $ingress -Postgres $postgres
    }

    Add-Check -Id "management_backend_database_postgres" -Label "Management backend database PostgreSQL" -Status "ok" -Message "Management PostgreSQL is Ready." -Details @{
        required  = $true
        namespace = $PostgresNamespace
    }

    if ([string]$backend["status"] -ne "ready" -or -not [bool]$backend["health_check_succeeded"]) {
        $database["status"] = "error"
        $database["message"] = "The backend Deployment and health endpoint must be Ready before running Alembic migrations."
        $database["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_backend_database_backend" -Label "Management backend database runtime" -Status "failed" -Message ([string]$database["message"]) -Details @{
            required                 = $true
            backend_status           = [string]$backend["status"]
            backend_health_succeeded = [bool]$backend["health_check_succeeded"]
        }
        return New-ManagementBackendDatabaseResult -Database $database -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Frontend $frontend -Ingress $ingress -Postgres $postgres
    }

    Add-Check -Id "management_backend_database_backend" -Label "Management backend database runtime" -Status "ok" -Message "The backend Deployment has a Ready Pod and its health endpoint is available." -Details @{
        required   = $true
        deployment = "devdeploy-backend"
        namespace  = $PostgresNamespace
    }

    if ([string]$backendSecret["status"] -ne "ready" -or -not [bool]$backendSecret["required_keys_present"]) {
        $database["status"] = "error"
        $database["message"] = "The backend runtime Secret must pass sanitized verification before running migrations."
        $database["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_backend_database_secret" -Label "Management backend database Secret" -Status "failed" -Message ([string]$database["message"]) -Details @{
            required              = $true
            secret_name           = $BackendSecretName
            required_keys_present = [bool]$backendSecret["required_keys_present"]
        }
        return New-ManagementBackendDatabaseResult -Database $database -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Frontend $frontend -Ingress $ingress -Postgres $postgres
    }

    Add-Check -Id "management_backend_database_secret" -Label "Management backend database Secret" -Status "ok" -Message "Backend runtime Secret keys and non-secret configuration properties passed verification." -Details @{
        required                         = $true
        secret_name                      = $BackendSecretName
        database_url_configured          = [bool]$backendSecret["database_url_configured"]
        jwt_secret_configured            = [bool]$backendSecret["jwt_secret_configured"]
        github_workflow_token_configured = [bool]$backendSecret["github_workflow_token_configured"]
    }

    $podJsonPath = '{range .items[*]}{.metadata.name}|{.status.phase}|{.status.containerStatuses[0].ready};{end}'
    $podsResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $PostgresNamespace, "get", "pods", "--selector", "app.kubernetes.io/name=devdeploy-backend,app.kubernetes.io/component=backend", "--output", "jsonpath=$podJsonPath") -TimeoutSeconds 20
    $backendPodName = ""
    if ($podsResult.exit_code -eq 0 -and -not $podsResult.timed_out) {
        foreach ($podRecord in @(([string]$podsResult.stdout).Split(';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            $podParts = @(([string]$podRecord).Split('|'))
            if ($podParts.Count -ge 3 -and ([string]$podParts[1]).Trim() -eq "Running" -and ([string]$podParts[2]).Trim() -eq "true") {
                $backendPodName = ([string]$podParts[0]).Trim()
                break
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($backendPodName)) {
        $database["status"] = "error"
        $database["message"] = "No Running and Ready backend Pod was found for Alembic execution."
        $database["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_backend_database_pod" -Label "Management backend database Pod" -Status "failed" -Message ([string]$database["message"]) -Details @{
            required  = $true
            namespace = $PostgresNamespace
        }
        return New-ManagementBackendDatabaseResult -Database $database -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Frontend $frontend -Ingress $ingress -Postgres $postgres
    }

    Add-Check -Id "management_backend_database_pod" -Label "Management backend database Pod" -Status "ok" -Message "A Running and Ready backend Pod is available for Alembic execution." -Details @{
        required  = $true
        namespace = $PostgresNamespace
        pod        = $backendPodName
        container  = "backend"
    }

    $alembicPathCheck = "from pathlib import Path; import sys; sys.exit(0 if Path('$BackendAlembicConfigPath').is_file() and Path('$BackendAlembicScriptPath').is_dir() else 1)"
    $alembicFilesResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $PostgresNamespace, "exec", $backendPodName, "--container", "backend", "--", "python", "-c", $alembicPathCheck) -TimeoutSeconds 30
    if ($alembicFilesResult.exit_code -ne 0 -or $alembicFilesResult.timed_out) {
        $database["status"] = "error"
        $database["message"] = "Alembic configuration or migration scripts are not available at the expected backend image paths."
        $database["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_backend_database_alembic_files" -Label "Management backend Alembic files" -Status "failed" -Message ([string]$database["message"]) -Details @{
            required    = $true
            config_path = $BackendAlembicConfigPath
            script_path = $BackendAlembicScriptPath
        }
        return New-ManagementBackendDatabaseResult -Database $database -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Frontend $frontend -Ingress $ingress -Postgres $postgres
    }

    Add-Check -Id "management_backend_database_alembic_files" -Label "Management backend Alembic files" -Status "ok" -Message "Alembic configuration and migration scripts exist in the backend container." -Details @{
        required    = $true
        config_path = $BackendAlembicConfigPath
        script_path = $BackendAlembicScriptPath
    }

    Write-LauncherLog "Running Alembic upgrade head inside the management backend Pod."
    if (-not $Quiet) {
        Write-Host "Initializing management backend database with Alembic..."
    }
    $migrationResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $PostgresNamespace, "exec", $backendPodName, "--container", "backend", "--", "alembic", "-c", $BackendAlembicConfigPath, "upgrade", "head") -TimeoutSeconds 300
    if ($migrationResult.exit_code -ne 0 -or $migrationResult.timed_out) {
        $database["status"] = "error"
        $database["message"] = "Alembic upgrade head failed. No reset, rollback, or cleanup was attempted."
        $database["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_backend_database_migrate" -Label "Management backend Alembic migration" -Status "failed" -Message ([string]$database["message"]) -Details @{
            required = $true
            tool     = "alembic"
            error    = if ($migrationResult.timed_out) { "Alembic command timed out." } else { "Alembic command exited unsuccessfully." }
        }
        return New-ManagementBackendDatabaseResult -Database $database -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Frontend $frontend -Ingress $ingress -Postgres $postgres
    }

    $database["initialized"] = $true
    Add-Check -Id "management_backend_database_migrate" -Label "Management backend Alembic migration" -Status "ok" -Message "Alembic upgrade head completed successfully." -Details @{
        required = $true
        tool     = "alembic"
        command  = "alembic upgrade head"
    }

    $currentResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $PostgresNamespace, "exec", $backendPodName, "--container", "backend", "--", "alembic", "-c", $BackendAlembicConfigPath, "current") -TimeoutSeconds 60
    $currentRevisionDetected = [bool]($currentResult.exit_code -eq 0 -and -not $currentResult.timed_out -and -not [string]::IsNullOrWhiteSpace([string]$currentResult.stdout))
    $database["current_revision_detected"] = $currentRevisionDetected

    $usersTableCheck = "from app.db.session import engine; from sqlalchemy import inspect; raise SystemExit(0 if 'users' in inspect(engine).get_table_names() else 1)"
    $usersTableResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $PostgresNamespace, "exec", $backendPodName, "--container", "backend", "--", "python", "-c", $usersTableCheck) -TimeoutSeconds 60
    $usersTablePresent = [bool]($usersTableResult.exit_code -eq 0 -and -not $usersTableResult.timed_out)
    $database["users_table_present"] = $usersTablePresent

    if (-not $currentRevisionDetected -or -not $usersTablePresent) {
        $database["status"] = "error"
        $database["message"] = "Alembic completed, but revision or users table verification failed."
        $database["checked_at"] = [string](Get-Timestamp)
        Add-Check -Id "management_backend_database_verify" -Label "Management backend database verification" -Status "failed" -Message ([string]$database["message"]) -Details @{
            required                  = $true
            current_revision_detected = $currentRevisionDetected
            users_table_present       = $usersTablePresent
        }
        return New-ManagementBackendDatabaseResult -Database $database -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Frontend $frontend -Ingress $ingress -Postgres $postgres
    }

    $database["ready"] = $true
    $database["status"] = "ready"
    $database["message"] = "Alembic migrations are current and the users table exists in the management backend database."
    $database["checked_at"] = [string](Get-Timestamp)
    Add-Check -Id "management_backend_database_verify" -Label "Management backend database verification" -Status "ok" -Message ([string]$database["message"]) -Details @{
        required                  = $true
        current_revision_detected = $true
        users_table_present       = $true
    }

    return New-ManagementBackendDatabaseResult -Database $database -Backend $backend -BackendImage $backendImage -BackendSecret $backendSecret -Frontend $frontend -Ingress $ingress -Postgres $postgres
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

        [bool]$ManagementBackendBootstrapMode = $false,

        [bool]$ManagementBackendVerifyMode = $false,

        [bool]$ManagementFrontendImageBuildMode = $false,

        [bool]$ManagementFrontendImageLoadMode = $false,

        [bool]$ManagementFrontendBootstrapMode = $false,

        [bool]$ManagementBackendDatabaseInitializeMode = $false,

        [bool]$ManagementFrontendVerifyMode = $false,

        [bool]$ManagementArgoCDBootstrapMode = $false
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
    elseif ($ManagementBackendVerifyMode -and $mgmtExists) {
        $status = "ok"
        $message = "devdeploy-mgmt exists. Backend verify mode performs read-only checks only in this management cluster."
    }
    elseif ($ManagementFrontendImageBuildMode -and ($mgmtExists -or $workloadExists)) {
        $status = "ok"
        $message = "Existing DevDeploy clusters were detected. Frontend image build mode does not use, modify, or delete them."
    }
    elseif ($ManagementFrontendImageLoadMode -and $mgmtExists) {
        $status = "ok"
        $message = "devdeploy-mgmt exists. Frontend image load mode targets only this management cluster."
    }
    elseif ($ManagementFrontendBootstrapMode -and $mgmtExists) {
        $status = "ok"
        $message = "devdeploy-mgmt exists. Frontend bootstrap mode applies only management frontend platform manifests to this cluster."
    }
    elseif ($ManagementBackendDatabaseInitializeMode -and $mgmtExists) {
        $status = "ok"
        $message = "devdeploy-mgmt exists. Backend database initialization mode runs Alembic only in the management backend Pod."
    }
    elseif ($ManagementFrontendVerifyMode -and $mgmtExists) {
        $status = "ok"
        $message = "devdeploy-mgmt exists. Frontend verify mode performs read-only checks only in this management cluster."
    }
    elseif ($ManagementArgoCDBootstrapMode -and $mgmtExists) {
        $status = "ok"
        $message = "devdeploy-mgmt exists. Argo CD bootstrap mode targets only the management cluster and does not register or modify devdeploy-workload."
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

function New-ManagementArgoCDStatus {
    return [ordered]@{
        installed                           = $false
        ready                               = $false
        namespace                           = $ArgoCDNamespace
        release                             = $ArgoCDRelease
        chart                               = $ArgoCDChart
        chart_version                       = $ArgoCDChartVersion
        server_deployment                   = "argocd-server"
        repo_server_deployment              = "argocd-repo-server"
        application_controller_statefulset  = "argocd-application-controller"
        ingress_enabled                     = $false
        ingress_host                        = $ArgoCDIngressHost
        ui_access                           = $ArgoCDUiAccess
        admin_secret_present                = $false
        status                              = "not_started"
        message                             = "Management Argo CD is not installed yet."
        checked_at                          = [string](Get-Timestamp)
    }
}

function Test-ArgoCDResourceReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Kind,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $jsonPath = if ($Kind -eq "statefulset") { "{.status.readyReplicas}" } else { "{.status.availableReplicas}" }
    $result = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", $Kind, $Name, "--output", "jsonpath=$jsonPath") -TimeoutSeconds 20
    $readyReplicas = 0
    [void][int]::TryParse(([string]$result.stdout).Trim(), [ref]$readyReplicas)
    return [bool]($result.exit_code -eq 0 -and -not $result.timed_out -and $readyReplicas -ge 1)
}

function Test-ManagementArgoCDUi {
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        try {
            $response = Invoke-WebRequest -Uri $ArgoCDUiAccess -UseBasicParsing -TimeoutSec 5
            $content = [string]$response.Content
            if ([int]$response.StatusCode -eq 200 -and $content -match '(?i)<!doctype\s+html|<html|argo\s*cd') {
                return $true
            }
        }
        catch {
            # Some Windows PowerShell/.NET combinations do not resolve *.localhost.
        }

        try {
            $fallbackResponse = Invoke-WebRequest -Uri "http://localhost:8080/" -Headers @{ Host = $ArgoCDIngressHost } -UseBasicParsing -TimeoutSec 5
            $fallbackContent = [string]$fallbackResponse.Content
            if ([int]$fallbackResponse.StatusCode -eq 200 -and $fallbackContent -match '(?i)<!doctype\s+html|<html|argo\s*cd') {
                return $true
            }
        }
        catch {
            # The ingress route may need a short period after the Helm rollout.
        }

        if ($attempt -lt 20) {
            Start-Sleep -Seconds 2
        }
    }

    return $false
}

function Get-ManagementArgoCDStatus {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ManagementCluster,

        [bool]$HelmAvailable,

        [bool]$KubectlAvailable
    )

    $status = New-ManagementArgoCDStatus
    if ([string]$ManagementCluster["status"] -ne "ready") {
        $status["status"] = "unknown"
        $status["message"] = "Management Argo CD status cannot be determined until devdeploy-mgmt is ready."
        return $status
    }

    if (-not $HelmAvailable -or -not $KubectlAvailable) {
        $status["status"] = "unknown"
        $status["message"] = "Management Argo CD status requires Helm and kubectl."
        return $status
    }

    $releaseResult = Invoke-ReadOnlyCommand -FileName "helm" -Arguments @("--kube-context", "kind-devdeploy-mgmt", "list", "--namespace", $ArgoCDNamespace, "--filter", "^$ArgoCDRelease$", "--deployed", "--short") -TimeoutSeconds 20
    if ($releaseResult.exit_code -ne 0 -or $releaseResult.timed_out -or [string]::IsNullOrWhiteSpace($releaseResult.stdout)) {
        return $status
    }

    $status["installed"] = $true
    $serverReady = Test-ArgoCDResourceReady -Kind "deployment" -Name "argocd-server"
    $repoServerReady = Test-ArgoCDResourceReady -Kind "deployment" -Name "argocd-repo-server"
    $controllerReady = Test-ArgoCDResourceReady -Kind "statefulset" -Name "argocd-application-controller"

    $serviceResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", "service", "argocd-server", "--output", "name") -TimeoutSeconds 20
    $serviceReady = [bool]($serviceResult.exit_code -eq 0 -and -not $serviceResult.timed_out)

    $ingressJsonPath = "{.spec.ingressClassName}|{.spec.rules[0].host}"
    $ingressResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", "ingress", "argocd-server", "--output", "jsonpath=$ingressJsonPath") -TimeoutSeconds 20
    $ingressParts = if ($ingressResult.exit_code -eq 0 -and -not $ingressResult.timed_out) { @(([string]$ingressResult.stdout).Split('|')) } else { @() }
    $ingressReady = [bool]($ingressParts.Count -ge 2 -and ([string]$ingressParts[0]).Trim() -eq "nginx" -and ([string]$ingressParts[1]).Trim() -eq $ArgoCDIngressHost)
    $status["ingress_enabled"] = $ingressReady

    $adminSecretResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", "secret", "argocd-initial-admin-secret", "--output", "name") -TimeoutSeconds 20
    $status["admin_secret_present"] = [bool]($adminSecretResult.exit_code -eq 0 -and -not $adminSecretResult.timed_out)

    if ($serverReady -and $repoServerReady -and $controllerReady -and $serviceReady -and $ingressReady) {
        $uiReady = Test-ManagementArgoCDUi
        $status["ready"] = $uiReady
        if ($uiReady -and [bool]$status["admin_secret_present"]) {
            $status["status"] = "ready"
            $status["message"] = "Management Argo CD is installed, Ready, and reachable through its local ingress."
        }
        else {
            $status["status"] = "warning"
            $status["message"] = "Management Argo CD workloads are Ready, but local UI or initial admin Secret verification needs review."
        }
    }
    else {
        $status["status"] = "error"
        $status["message"] = "Management Argo CD release exists, but one or more core resources are not Ready."
    }

    $status["checked_at"] = [string](Get-Timestamp)
    return $status
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

        [Parameter(Mandatory = $true)]
        [object]$BackendDatabaseStatus,

        [Parameter(Mandatory = $true)]
        [object]$FrontendImageStatus,

        [Parameter(Mandatory = $true)]
        [object]$FrontendStatus,

        [AllowNull()]
        [object]$IngressStatusOverride = $null,

        [AllowNull()]
        [object]$PostgresStatusOverride = $null,

        [AllowNull()]
        [object]$ArgoCDStatusOverride = $null
    )

    $ingress = if ($null -ne $IngressStatusOverride) { $IngressStatusOverride } else { Get-ManagementIngressStatus -ManagementCluster $ManagementCluster -HelmAvailable $HelmAvailable -KubectlAvailable $KubectlAvailable }
    $postgres = if ($null -ne $PostgresStatusOverride) { $PostgresStatusOverride } else { Get-ManagementPostgresStatus -ManagementCluster $ManagementCluster -HelmAvailable $HelmAvailable -KubectlAvailable $KubectlAvailable }
    $argocd = if ($null -ne $ArgoCDStatusOverride) { $ArgoCDStatusOverride } else { Get-ManagementArgoCDStatus -ManagementCluster $ManagementCluster -HelmAvailable $HelmAvailable -KubectlAvailable $KubectlAvailable }
    $devdeployNamespace = Get-DevDeployNamespaceStatus -ManagementCluster $ManagementCluster -KubectlAvailable $KubectlAvailable
    $status = "not_started"
    $message = "Management platform bootstrap has not started yet."

    $ingressFailedChecks = @($Checks | Where-Object { $_.id -like "management_ingress_*" -and $_.status -eq "failed" }).Count
    $postgresFailedChecks = @($Checks | Where-Object { $_.id -like "management_postgres_*" -and $_.status -eq "failed" }).Count
    $backendFailedChecks = @($Checks | Where-Object { $_.id -like "management_backend_*" -and $_.id -notlike "management_backend_database_*" -and $_.status -eq "failed" }).Count
    $backendDatabaseFailedChecks = @($Checks | Where-Object { $_.id -like "management_backend_database_*" -and $_.status -eq "failed" }).Count
    $frontendFailedChecks = @($Checks | Where-Object { $_.id -like "management_frontend_*" -and $_.status -eq "failed" }).Count
    $argocdFailedChecks = @($Checks | Where-Object { $_.id -like "management_argocd_*" -and $_.status -eq "failed" }).Count

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
    elseif ($backendDatabaseFailedChecks -gt 0 -and [string]$BackendDatabaseStatus["status"] -ne "ready") {
        $status = "failed"
        $message = "Management backend database initialization failed."
    }
    elseif ($frontendFailedChecks -gt 0 -and [string]$FrontendStatus["status"] -notin @("ready", "warning")) {
        $status = "failed"
        $message = "Management frontend bootstrap failed."
    }
    elseif ($argocdFailedChecks -gt 0 -and [string]$argocd["status"] -ne "ready") {
        $status = "failed"
        $message = "Management Argo CD bootstrap failed."
    }
    elseif ([string]$ingress["status"] -eq "ready" -and [string]$postgres["status"] -eq "ready" -and [string]$BackendStatus["status"] -in @("ready", "warning") -and [string]$BackendDatabaseStatus["status"] -eq "ready" -and [string]$FrontendStatus["status"] -in @("ready", "warning") -and [string]$argocd["status"] -eq "ready") {
        $status = "partial"
        $message = "Management platform components and Argo CD are ready. Workload registration and the GitOps Application model are not configured yet."
    }
    elseif ([string]$ingress["status"] -eq "ready" -and [string]$postgres["status"] -eq "ready" -and [string]$BackendStatus["status"] -in @("ready", "warning") -and [string]$BackendDatabaseStatus["status"] -eq "ready" -and [string]$FrontendStatus["status"] -in @("ready", "warning")) {
        $status = "partial"
        $message = "Management ingress, PostgreSQL, backend database, backend, and frontend are ready. Argo CD is not installed yet."
    }
    elseif ([string]$ingress["status"] -eq "ready" -and [string]$postgres["status"] -eq "ready" -and [string]$BackendStatus["status"] -in @("ready", "warning") -and [string]$FrontendStatus["status"] -in @("ready", "warning")) {
        $status = "partial"
        $message = "Management ingress, PostgreSQL, backend, and frontend are ready. Argo CD is not installed yet."
    }
    elseif ([string]$ingress["status"] -eq "ready" -and [string]$postgres["status"] -eq "ready" -and [string]$BackendStatus["status"] -in @("ready", "warning")) {
        $status = "partial"
        $message = "Management ingress, PostgreSQL, and backend are ready. Frontend and Argo CD are not installed yet."
    }
    elseif ([string]$argocd["status"] -in @("ready", "warning")) {
        $status = "partial"
        $message = "Management Argo CD is ready. Workload registration and the GitOps Application model are not configured yet."
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
            backend_database = $BackendDatabaseStatus
            frontend_image = $FrontendImageStatus
            frontend      = $FrontendStatus
            argocd        = $argocd
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
        backend_database_status = [string]$BackendDatabaseStatus["status"]
        frontend_image_status = [string]$FrontendImageStatus["status"]
        frontend_status = [string]$FrontendStatus["status"]
        argocd_status = [string]$argocd["status"]
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

function Invoke-ArgoCDRolloutCheck {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,

        [Parameter(Mandatory = $true)]
        [string]$Label,

        [Parameter(Mandatory = $true)]
        [string]$Kind,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [bool]$Required = $true
    )

    $result = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "rollout", "status", "$Kind/$Name", "--timeout=300s") -TimeoutSeconds 330
    if ($result.exit_code -eq 0 -and -not $result.timed_out) {
        Add-Check -Id $Id -Label $Label -Status "ok" -Message "$Name is Ready in devdeploy-mgmt/$ArgoCDNamespace." -Details @{
            required  = $Required
            namespace = $ArgoCDNamespace
            kind      = $Kind
            name      = $Name
        }
        return $true
    }

    Add-Check -Id $Id -Label $Label -Status $(if ($Required) { "failed" } else { "warning" }) -Message "$Name did not become Ready in devdeploy-mgmt/$ArgoCDNamespace." -Details @{
        required  = $Required
        namespace = $ArgoCDNamespace
        kind      = $Kind
        name      = $Name
        error     = $result.stderr
    }
    return $false
}

function Invoke-BootstrapManagementArgoCD {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ManagementCluster,

        [bool]$HelmAvailable,

        [bool]$KubectlAvailable
    )

    $status = New-ManagementArgoCDStatus

    if ([string]$ManagementCluster["status"] -ne "ready") {
        $status["status"] = "error"
        $status["message"] = "devdeploy-mgmt must be Ready before bootstrapping Argo CD."
        Add-Check -Id "management_argocd_cluster_prerequisite" -Label "Management Argo CD cluster prerequisite" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required       = $true
            cluster_name   = "devdeploy-mgmt"
            cluster_status = [string]$ManagementCluster["status"]
        }
        return $status
    }

    Add-Check -Id "management_argocd_cluster_prerequisite" -Label "Management Argo CD cluster prerequisite" -Status "ok" -Message "devdeploy-mgmt is reachable and has Ready node capacity." -Details @{
        required     = $true
        cluster_name = "devdeploy-mgmt"
        context      = "kind-devdeploy-mgmt"
    }

    if (-not $HelmAvailable -or -not $KubectlAvailable) {
        $missingTool = if (-not $HelmAvailable) { "Helm" } else { "kubectl" }
        $status["status"] = "error"
        $status["message"] = "$missingTool CLI is required for -BootstrapManagementArgoCD."
        Add-Check -Id "management_argocd_tools" -Label "Management Argo CD tools" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required          = $true
            helm_available    = $HelmAvailable
            kubectl_available = $KubectlAvailable
        }
        return $status
    }

    Add-Check -Id "management_argocd_tools" -Label "Management Argo CD tools" -Status "ok" -Message "Helm and kubectl are available for explicit Argo CD bootstrap." -Details @{
        required          = $true
        helm_available    = $true
        kubectl_available = $true
    }

    $ingress = Get-ManagementIngressStatus -ManagementCluster $ManagementCluster -HelmAvailable $HelmAvailable -KubectlAvailable $KubectlAvailable
    if ([string]$ingress["status"] -ne "ready") {
        $status["status"] = "error"
        $status["message"] = "Management ingress-nginx must be Ready before bootstrapping Argo CD ingress."
        Add-Check -Id "management_argocd_ingress_prerequisite" -Label "Management Argo CD ingress prerequisite" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required       = $true
            ingress_status = [string]$ingress["status"]
        }
        return $status
    }

    Add-Check -Id "management_argocd_ingress_prerequisite" -Label "Management Argo CD ingress prerequisite" -Status "ok" -Message "Management ingress-nginx is Ready." -Details @{
        required = $true
    }

    $repoAdd = Invoke-ReadOnlyCommand -FileName "helm" -Arguments @("repo", "add", "argo", "https://argoproj.github.io/argo-helm", "--force-update") -TimeoutSeconds 60
    if ($repoAdd.exit_code -ne 0 -or $repoAdd.timed_out) {
        $status["status"] = "error"
        $status["message"] = "Could not add or update the official Argo Helm repository."
        Add-Check -Id "management_argocd_repository" -Label "Management Argo CD Helm repository" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required = $true
            repository = "https://argoproj.github.io/argo-helm"
            error = $repoAdd.stderr
        }
        return $status
    }

    $repoUpdate = Invoke-ReadOnlyCommand -FileName "helm" -Arguments @("repo", "update", "argo") -TimeoutSeconds 120
    if ($repoUpdate.exit_code -ne 0 -or $repoUpdate.timed_out) {
        $status["status"] = "error"
        $status["message"] = "Could not refresh the official Argo Helm repository."
        Add-Check -Id "management_argocd_repository" -Label "Management Argo CD Helm repository" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required = $true
            repository = "https://argoproj.github.io/argo-helm"
            error = $repoUpdate.stderr
        }
        return $status
    }

    Add-Check -Id "management_argocd_repository" -Label "Management Argo CD Helm repository" -Status "ok" -Message "The official Argo Helm repository is configured and refreshed." -Details @{
        required   = $true
        repository = "https://argoproj.github.io/argo-helm"
    }

    $helmArgs = @(
        "upgrade", "--install", $ArgoCDRelease, $ArgoCDChart,
        "--version", $ArgoCDChartVersion,
        "--namespace", $ArgoCDNamespace,
        "--create-namespace",
        "--kube-context", "kind-devdeploy-mgmt",
        "--wait",
        "--timeout", "10m",
        "--set", "server.ingress.enabled=true",
        "--set", "server.ingress.ingressClassName=nginx",
        "--set", "server.ingress.hostname=$ArgoCDIngressHost",
        "--set", "server.ingress.path=/",
        "--set", "server.ingress.pathType=Prefix",
        "--set", "server.ingress.tls=false",
        "--set", "configs.params.server\.insecure=true"
    )

    Write-LauncherLog "Installing or upgrading management Argo CD in devdeploy-mgmt/argocd with the pinned official Helm chart."
    $installResult = Invoke-ReadOnlyCommand -FileName "helm" -Arguments $helmArgs -TimeoutSeconds 660
    if ($installResult.exit_code -ne 0 -or $installResult.timed_out) {
        $status["status"] = "error"
        $status["message"] = if ($installResult.timed_out) { "Helm timed out while installing or upgrading management Argo CD. No automatic cleanup was performed." } else { "Helm failed to install or upgrade management Argo CD. No automatic cleanup was performed." }
        Add-Check -Id "management_argocd_release" -Label "Management Argo CD Helm release" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required      = $true
            namespace     = $ArgoCDNamespace
            release       = $ArgoCDRelease
            chart         = $ArgoCDChart
            chart_version = $ArgoCDChartVersion
            error         = $installResult.stderr
        }
        return $status
    }

    $status["installed"] = $true
    Add-Check -Id "management_argocd_release" -Label "Management Argo CD Helm release" -Status "ok" -Message "Argo CD Helm release is installed or reconciled in devdeploy-mgmt/argocd." -Details @{
        required      = $true
        namespace     = $ArgoCDNamespace
        release       = $ArgoCDRelease
        chart         = $ArgoCDChart
        chart_version = $ArgoCDChartVersion
    }

    $namespaceResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "get", "namespace", $ArgoCDNamespace, "--output", "name") -TimeoutSeconds 20
    $namespaceReady = [bool]($namespaceResult.exit_code -eq 0 -and -not $namespaceResult.timed_out)
    Add-Check -Id "management_argocd_namespace" -Label "Management Argo CD namespace" -Status $(if ($namespaceReady) { "ok" } else { "failed" }) -Message $(if ($namespaceReady) { "Namespace argocd exists in devdeploy-mgmt." } else { "Namespace argocd could not be verified in devdeploy-mgmt." }) -Details @{
        required  = $true
        namespace = $ArgoCDNamespace
    }

    $serverReady = Invoke-ArgoCDRolloutCheck -Id "management_argocd_server_ready" -Label "Argo CD server readiness" -Kind "deployment" -Name "argocd-server"
    $repoServerReady = Invoke-ArgoCDRolloutCheck -Id "management_argocd_repo_server_ready" -Label "Argo CD repo-server readiness" -Kind "deployment" -Name "argocd-repo-server"
    $controllerReady = Invoke-ArgoCDRolloutCheck -Id "management_argocd_application_controller_ready" -Label "Argo CD application-controller readiness" -Kind "statefulset" -Name "argocd-application-controller"

    $applicationSetExistsResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", "deployment", "argocd-applicationset-controller", "--output", "name") -TimeoutSeconds 20
    $applicationSetReady = $true
    if ($applicationSetExistsResult.exit_code -eq 0 -and -not $applicationSetExistsResult.timed_out) {
        $applicationSetReady = Invoke-ArgoCDRolloutCheck -Id "management_argocd_applicationset_ready" -Label "Argo CD ApplicationSet readiness" -Kind "deployment" -Name "argocd-applicationset-controller"
    }
    else {
        Add-Check -Id "management_argocd_applicationset_ready" -Label "Argo CD ApplicationSet readiness" -Status "skipped" -Message "ApplicationSet controller is not enabled by the pinned chart configuration." -Details @{
            required = $false
        }
    }

    $redisDeploymentResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", "deployment", "argocd-redis", "--output", "name") -TimeoutSeconds 20
    if ($redisDeploymentResult.exit_code -eq 0 -and -not $redisDeploymentResult.timed_out) {
        $redisReady = Invoke-ArgoCDRolloutCheck -Id "management_argocd_redis_ready" -Label "Argo CD Redis readiness" -Kind "deployment" -Name "argocd-redis"
    }
    else {
        $redisReady = Invoke-ArgoCDRolloutCheck -Id "management_argocd_redis_ready" -Label "Argo CD Redis readiness" -Kind "statefulset" -Name "argocd-redis"
    }

    $serviceResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", "service", "argocd-server", "--output", "name") -TimeoutSeconds 20
    $serviceReady = [bool]($serviceResult.exit_code -eq 0 -and -not $serviceResult.timed_out)
    Add-Check -Id "management_argocd_server_service" -Label "Argo CD server Service" -Status $(if ($serviceReady) { "ok" } else { "failed" }) -Message $(if ($serviceReady) { "argocd-server Service exists." } else { "argocd-server Service could not be verified." }) -Details @{
        required  = $true
        namespace = $ArgoCDNamespace
        service   = "argocd-server"
    }

    $ingressJsonPath = "{.spec.ingressClassName}|{.spec.rules[0].host}"
    $ingressResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", "ingress", "argocd-server", "--output", "jsonpath=$ingressJsonPath") -TimeoutSeconds 20
    $ingressParts = if ($ingressResult.exit_code -eq 0 -and -not $ingressResult.timed_out) { @(([string]$ingressResult.stdout).Split('|')) } else { @() }
    $ingressReady = [bool]($ingressParts.Count -ge 2 -and ([string]$ingressParts[0]).Trim() -eq "nginx" -and ([string]$ingressParts[1]).Trim() -eq $ArgoCDIngressHost)
    $status["ingress_enabled"] = $ingressReady
    Add-Check -Id "management_argocd_ingress" -Label "Argo CD Ingress" -Status $(if ($ingressReady) { "ok" } else { "failed" }) -Message $(if ($ingressReady) { "Argo CD Ingress routes argocd.localhost through ingress class nginx." } else { "Argo CD Ingress host or ingress class verification failed." }) -Details @{
        required      = $true
        namespace     = $ArgoCDNamespace
        ingress       = "argocd-server"
        ingress_class = "nginx"
        host           = $ArgoCDIngressHost
    }

    $adminSecretResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", "secret", "argocd-initial-admin-secret", "--output", "name") -TimeoutSeconds 20
    $adminSecretReady = [bool]($adminSecretResult.exit_code -eq 0 -and -not $adminSecretResult.timed_out)
    $status["admin_secret_present"] = $adminSecretReady
    Add-Check -Id "management_argocd_admin_secret" -Label "Argo CD initial admin Secret" -Status $(if ($adminSecretReady) { "ok" } else { "warning" }) -Message $(if ($adminSecretReady) { "Argo CD initial admin credential Secret exists; its value was not read or printed." } else { "Argo CD initial admin credential Secret was not found. No Secret data was read." }) -Details @{
        required    = $false
        namespace   = $ArgoCDNamespace
        secret_name = "argocd-initial-admin-secret"
        value_read  = $false
    }

    $uiReady = Test-ManagementArgoCDUi
    Add-Check -Id "management_argocd_ui" -Label "Argo CD local UI" -Status $(if ($uiReady) { "ok" } else { "failed" }) -Message $(if ($uiReady) { "Argo CD UI is reachable through http://argocd.localhost:8080/." } else { "Argo CD UI is not reachable through http://argocd.localhost:8080/." }) -Details @{
        required = $true
        url      = $ArgoCDUiAccess
    }

    $allReady = [bool]($namespaceReady -and $serverReady -and $repoServerReady -and $controllerReady -and $applicationSetReady -and $redisReady -and $serviceReady -and $ingressReady -and $uiReady)
    $status["ready"] = $allReady
    $status["checked_at"] = [string](Get-Timestamp)
    if ($allReady) {
        $status["status"] = if ($adminSecretReady) { "ready" } else { "warning" }
        $status["message"] = if ($adminSecretReady) { "Management Argo CD is installed, Ready, and reachable through its local ingress." } else { "Management Argo CD is Ready, but the initial admin Secret was not found."
        }
    }
    else {
        $status["status"] = "error"
        $status["message"] = "Management Argo CD bootstrap completed with failed readiness or ingress verification. No automatic cleanup was performed."
    }

    Add-Check -Id "management_argocd_ready" -Label "Management Argo CD readiness" -Status $(if ($allReady) { "ok" } else { "failed" }) -Message ([string]$status["message"]) -Details @{
        required      = $true
        namespace     = $ArgoCDNamespace
        release       = $ArgoCDRelease
        chart_version = $ArgoCDChartVersion
        workload_cluster_registered = $false
        gitops_application_created   = $false
    }

    return $status
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
elseif ($BuildManagementFrontendImage) {
    Write-LauncherLog "Starting DevDeploy Launcher explicit management frontend image build mode."
}
elseif ($LoadManagementFrontendImage) {
    Write-LauncherLog "Starting DevDeploy Launcher explicit management frontend image load mode."
}
elseif ($BootstrapManagementFrontend) {
    Write-LauncherLog "Starting DevDeploy Launcher explicit management frontend bootstrap mode."
}
elseif ($VerifyManagementFrontend) {
    Write-LauncherLog "Starting DevDeploy Launcher read-only management frontend verify mode."
}
elseif ($BootstrapManagementArgoCD) {
    Write-LauncherLog "Starting DevDeploy Launcher explicit management Argo CD bootstrap mode."
}
elseif ($InitializeManagementBackendDatabase) {
    Write-LauncherLog "Starting DevDeploy Launcher explicit management backend database initialization mode."
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
elseif ($VerifyManagementBackend) {
    Write-LauncherLog "Starting DevDeploy Launcher read-only management backend verify mode."
}
elseif ($GenerateKindConfigs) {
    Write-LauncherLog "Starting DevDeploy Launcher read-only preflight with kind config preview generation."
}
else {
    Write-LauncherLog "Starting DevDeploy Launcher read-only preflight."
}

$dockerAvailable = Test-CommandAvailable -Name "docker" -Label "Docker CLI" -Required ([bool](-not ($EnsureManagementBackendSecret -or $VerifyManagementBackendSecret -or $VerifyManagementBackend -or $BootstrapManagementFrontend -or $VerifyManagementFrontend -or $BootstrapManagementArgoCD -or $InitializeManagementBackendDatabase)))
$kindAvailable = Test-CommandAvailable -Name "kind" -Label "kind CLI" -Required ([bool](-not ($BuildManagementBackendImage -or $BuildManagementFrontendImage)))
$kubectlAvailable = Test-CommandAvailable -Name "kubectl" -Label "kubectl CLI" -Required ([bool](-not ($BuildManagementBackendImage -or $BuildManagementFrontendImage)))
[void](Test-CommandAvailable -Name "git" -Label "git CLI" -Required $false)
$helmAvailable = Test-CommandAvailable -Name "helm" -Label "Helm CLI" -Required ([bool]($BootstrapManagementIngress -or $BootstrapManagementPostgres -or $BootstrapManagementArgoCD))

if ($EnsureManagementBackendSecret -or $VerifyManagementBackendSecret -or $VerifyManagementBackend -or $BootstrapManagementFrontend -or $VerifyManagementFrontend -or $BootstrapManagementArgoCD -or $InitializeManagementBackendDatabase) {
    $dockerDaemonReachable = $false
    Add-Check -Id "docker_daemon" -Label "Docker daemon" -Status "skipped" -Message "Docker daemon check is not required for this Secret, verification, or frontend bootstrap mode." -Details @{
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
    if (($BootstrapManagementIngress -or $BootstrapManagementPostgres -or $BootstrapManagementArgoCD) -and $isWorkloadPort) {
        $portRequired = $false
    }
    if ($BuildManagementBackendImage -or $BuildManagementFrontendImage -or $LoadManagementFrontendImage -or $BootstrapManagementFrontend -or $VerifyManagementFrontend -or $BootstrapManagementArgoCD -or $InitializeManagementBackendDatabase -or $LoadManagementBackendImage -or $EnsureManagementBackendSecret -or $VerifyManagementBackendSecret -or $BootstrapManagementBackend -or $VerifyManagementBackend) {
        $portRequired = $false
    }
    $allowBusyAsOk = [bool]$existingClusterDetected

    Test-LocalPortAvailable -Port ([int]$entry.Value) -Required $portRequired -AllowBusyAsOk $allowBusyAsOk -ExpectedCluster $expectedCluster -ExistingClusterDetected $existingClusterDetected
}

if ($workloadClusterExistsBeforePortCheck) {
    $detectedStatus = if ($CreateWorkloadCluster -or $BootstrapManagementIngress -or $BootstrapManagementPostgres -or $BuildManagementBackendImage -or $BuildManagementFrontendImage -or $LoadManagementFrontendImage -or $BootstrapManagementFrontend -or $VerifyManagementFrontend -or $BootstrapManagementArgoCD -or $InitializeManagementBackendDatabase -or $LoadManagementBackendImage -or $EnsureManagementBackendSecret -or $VerifyManagementBackendSecret -or $BootstrapManagementBackend -or $VerifyManagementBackend) { "ok" } else { "warning" }
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
    elseif ($BuildManagementFrontendImage) {
        "devdeploy-workload already exists. Frontend image build mode does not use, modify, or delete it."
    }
    elseif ($LoadManagementFrontendImage) {
        "devdeploy-workload already exists. Frontend image load mode targets only devdeploy-mgmt and does not modify devdeploy-workload."
    }
    elseif ($BootstrapManagementFrontend) {
        "devdeploy-workload already exists. Frontend bootstrap mode targets only devdeploy-mgmt and does not modify devdeploy-workload."
    }
    elseif ($VerifyManagementFrontend) {
        "devdeploy-workload already exists. Frontend verify mode is read-only and targets only devdeploy-mgmt."
    }
    elseif ($BootstrapManagementArgoCD) {
        "devdeploy-workload already exists. Argo CD bootstrap mode targets only devdeploy-mgmt and does not register or modify devdeploy-workload."
    }
    elseif ($InitializeManagementBackendDatabase) {
        "devdeploy-workload already exists. Backend database initialization mode targets only the backend database in devdeploy-mgmt."
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
    elseif ($VerifyManagementBackend) {
        "devdeploy-workload already exists. Backend verify mode is read-only and targets only devdeploy-mgmt."
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

Test-KindClusters -KindAvailable $kindAvailable -ManagementCreateMode ([bool]$CreateManagementCluster) -WorkloadCreateMode ([bool]$CreateWorkloadCluster) -ManagementIngressBootstrapMode ([bool]$BootstrapManagementIngress) -ManagementPostgresBootstrapMode ([bool]$BootstrapManagementPostgres) -ManagementBackendImageBuildMode ([bool]$BuildManagementBackendImage) -ManagementBackendImageLoadMode ([bool]$LoadManagementBackendImage) -ManagementBackendSecretEnsureMode ([bool]$EnsureManagementBackendSecret) -ManagementBackendSecretVerifyMode ([bool]$VerifyManagementBackendSecret) -ManagementBackendBootstrapMode ([bool]$BootstrapManagementBackend) -ManagementBackendVerifyMode ([bool]$VerifyManagementBackend) -ManagementFrontendImageBuildMode ([bool]$BuildManagementFrontendImage) -ManagementFrontendImageLoadMode ([bool]$LoadManagementFrontendImage) -ManagementFrontendBootstrapMode ([bool]$BootstrapManagementFrontend) -ManagementBackendDatabaseInitializeMode ([bool]$InitializeManagementBackendDatabase) -ManagementFrontendVerifyMode ([bool]$VerifyManagementFrontend) -ManagementArgoCDBootstrapMode ([bool]$BootstrapManagementArgoCD)
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
elseif ($BuildManagementFrontendImage) {
    $launcherMode = "management_frontend_image_build"
}
elseif ($LoadManagementFrontendImage) {
    $launcherMode = "management_frontend_image_load"
}
elseif ($BootstrapManagementFrontend) {
    $launcherMode = "management_frontend_bootstrap"
}
elseif ($VerifyManagementFrontend) {
    $launcherMode = "management_frontend_verify"
}
elseif ($BootstrapManagementArgoCD) {
    $launcherMode = "management_argocd_bootstrap"
}
elseif ($InitializeManagementBackendDatabase) {
    $launcherMode = "management_backend_database_initialize"
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
elseif ($VerifyManagementBackend) {
    $launcherMode = "management_backend_verify"
}
elseif ($GenerateKindConfigs) {
    $launcherMode = "kind_config_preview"
}

$managementCluster = $null
$workloadCluster = $null
$backendImageStatus = New-ManagementBackendImageStatus
$backendSecretStatus = New-ManagementBackendSecretStatus
$backendStatus = New-ManagementBackendStatus
$backendDatabaseStatus = New-ManagementBackendDatabaseStatus
$frontendImageStatus = New-ManagementFrontendImageStatus
$frontendStatus = New-ManagementFrontendStatus
$platformIngressOverride = $null
$platformPostgresOverride = $null
$platformArgoCDOverride = $null

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
elseif ($BuildManagementFrontendImage) {
    $frontendImageStatus = Invoke-ManagementFrontendImageBuild -DockerCliAvailable $dockerAvailable -DockerDaemonReachable $dockerDaemonReachable
}
elseif ($LoadManagementFrontendImage) {
    $managementCluster = New-ManagementClusterStatus -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable
    $frontendImageStatus = Invoke-ManagementFrontendImageLoad -DockerCliAvailable $dockerAvailable -DockerDaemonReachable $dockerDaemonReachable -KindAvailable $kindAvailable -ManagementCluster $managementCluster
}
elseif ($BootstrapManagementFrontend) {
    $managementCluster = New-ManagementClusterStatus -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable
    $frontendBootstrapResult = Invoke-BootstrapManagementFrontend -KubectlAvailable $kubectlAvailable -ManagementCluster $managementCluster
    $frontendStatus = $frontendBootstrapResult["frontend"]
    $frontendImageStatus = $frontendBootstrapResult["frontend_image"]
    $backendStatus = $frontendBootstrapResult["backend"]
    $backendImageStatus = $frontendBootstrapResult["backend_image"]
    $backendSecretStatus = $frontendBootstrapResult["backend_secret"]
    $platformIngressOverride = $frontendBootstrapResult["ingress"]
    $platformPostgresOverride = $frontendBootstrapResult["postgres"]
}
elseif ($VerifyManagementFrontend) {
    $managementCluster = New-ManagementClusterStatus -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable
    $frontendVerifyResult = Invoke-VerifyManagementFrontend -KubectlAvailable $kubectlAvailable -ManagementCluster $managementCluster
    $frontendStatus = $frontendVerifyResult["frontend"]
    $frontendImageStatus = $frontendVerifyResult["frontend_image"]
    $backendStatus = $frontendVerifyResult["backend"]
    $backendImageStatus = $frontendVerifyResult["backend_image"]
    $backendSecretStatus = $frontendVerifyResult["backend_secret"]
    $platformIngressOverride = $frontendVerifyResult["ingress"]
    $platformPostgresOverride = $frontendVerifyResult["postgres"]
}
elseif ($BootstrapManagementArgoCD) {
    $managementCluster = New-ManagementClusterStatus -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable
    $platformArgoCDOverride = Invoke-BootstrapManagementArgoCD -ManagementCluster $managementCluster -HelmAvailable $helmAvailable -KubectlAvailable $kubectlAvailable
}
elseif ($InitializeManagementBackendDatabase) {
    $managementCluster = New-ManagementClusterStatus -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable
    $databaseResult = Invoke-InitializeManagementBackendDatabase -KubectlAvailable $kubectlAvailable -ManagementCluster $managementCluster
    $backendDatabaseStatus = $databaseResult["backend_database"]
    $backendStatus = $databaseResult["backend"]
    $backendImageStatus = $databaseResult["backend_image"]
    $backendSecretStatus = $databaseResult["backend_secret"]
    $frontendStatus = $databaseResult["frontend"]
    $platformIngressOverride = $databaseResult["ingress"]
    $platformPostgresOverride = $databaseResult["postgres"]
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
elseif ($VerifyManagementBackend) {
    $managementCluster = New-ManagementClusterStatus -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable
    $backendVerifyResult = Invoke-VerifyManagementBackend -KubectlAvailable $kubectlAvailable -ManagementCluster $managementCluster
    $backendStatus = $backendVerifyResult["backend"]
    $backendImageStatus = $backendVerifyResult["backend_image"]
    $backendSecretStatus = $backendVerifyResult["backend_secret"]
    $platformIngressOverride = $backendVerifyResult["ingress"]
    $platformPostgresOverride = $backendVerifyResult["postgres"]
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
$platformHelmAvailable = [bool]($helmAvailable -and -not $BuildManagementBackendImage -and -not $BuildManagementFrontendImage -and -not $LoadManagementFrontendImage -and -not $BootstrapManagementFrontend -and -not $VerifyManagementFrontend -and -not $InitializeManagementBackendDatabase -and -not $LoadManagementBackendImage -and -not $EnsureManagementBackendSecret -and -not $VerifyManagementBackendSecret -and -not $BootstrapManagementBackend -and -not $VerifyManagementBackend)
$platformBootstrap = New-PlatformBootstrapStatus -ManagementCluster $managementCluster -HelmAvailable $platformHelmAvailable -KubectlAvailable $kubectlAvailable -BackendImageStatus $backendImageStatus -BackendSecretStatus $backendSecretStatus -BackendStatus $backendStatus -BackendDatabaseStatus $backendDatabaseStatus -FrontendImageStatus $frontendImageStatus -FrontendStatus $frontendStatus -IngressStatusOverride $platformIngressOverride -PostgresStatusOverride $platformPostgresOverride -ArgoCDStatusOverride $platformArgoCDOverride
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
    elseif ($BuildManagementFrontendImage) {
        Write-Host ("Management frontend image: {0}" -f $FrontendImage)
    }
    elseif ($LoadManagementFrontendImage) {
        Write-Host ("Management frontend image target: {0} -> devdeploy-mgmt" -f $FrontendImage)
    }
    elseif ($BootstrapManagementFrontend) {
        Write-Host ("Management frontend deployment: {0}/devdeploy-frontend" -f $PostgresNamespace)
    }
    elseif ($VerifyManagementFrontend) {
        Write-Host ("Verified management frontend deployment: {0}/devdeploy-frontend" -f $PostgresNamespace)
    }
    elseif ($BootstrapManagementArgoCD) {
        Write-Host ("Management Argo CD release: {0}/{1} ({2} {3})" -f $ArgoCDNamespace, $ArgoCDRelease, $ArgoCDChart, $ArgoCDChartVersion)
        Write-Host ("Management Argo CD UI: {0}" -f $ArgoCDUiAccess)
    }
    elseif ($InitializeManagementBackendDatabase) {
        Write-Host ("Management backend database: {0}/devdeploy" -f $PostgresNamespace)
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
    elseif ($VerifyManagementBackend) {
        Write-Host ("Verified management backend deployment: {0}/devdeploy-backend" -f $PostgresNamespace)
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
