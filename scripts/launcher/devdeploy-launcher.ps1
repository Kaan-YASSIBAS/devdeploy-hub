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

    [switch]$PlanWorkloadRebootstrap,

    [switch]$PlanWorkloadPortRecovery,

    [switch]$PlanManagementPortRecovery,

    [switch]$RepairDevDeployKindRestartPolicies,

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

    [switch]$VerifyManagementArgoCD,

    [switch]$DiscoverWorkloadClusterEndpoint,

    [switch]$RegisterWorkloadClusterWithArgoCD,

    [switch]$VerifyWorkloadClusterRegistration,

    [switch]$GrantWorkloadDeployPermissions,

    [switch]$VerifyWorkloadDeployPermissions,

    [switch]$ConfigureGitOpsRepository,

    [switch]$BootstrapGitOpsRootApplication,

    [switch]$VerifyGitOpsRootApplication,

    [switch]$BootstrapWorkloadObservability,

    [switch]$VerifyWorkloadObservability,

    [string]$GitOpsRepoPath = "",

    [string]$GitOpsRepoUrl = "",

    [string]$GitOpsBranch = "",

    [switch]$InitializeManagementBackendDatabase,

    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (($PlanWorkloadRebootstrap -or $PlanWorkloadPortRecovery -or $PlanManagementPortRecovery) -and (
        $GenerateKindConfigs -or
        $CreateManagementCluster -or
        $CreateWorkloadCluster -or
        (@(@($PlanWorkloadRebootstrap, $PlanWorkloadPortRecovery, $PlanManagementPortRecovery) | Where-Object { $_ }).Count -gt 1) -or
        $RepairDevDeployKindRestartPolicies -or
        $BootstrapManagementIngress -or
        $BootstrapManagementPostgres -or
        $BuildManagementBackendImage -or
        $LoadManagementBackendImage -or
        $EnsureManagementBackendSecret -or
        $VerifyManagementBackendSecret -or
        $BootstrapManagementBackend -or
        $VerifyManagementBackend -or
        $BuildManagementFrontendImage -or
        $LoadManagementFrontendImage -or
        $BootstrapManagementFrontend -or
        $VerifyManagementFrontend -or
        $BootstrapManagementArgoCD -or
        $VerifyManagementArgoCD -or
        $DiscoverWorkloadClusterEndpoint -or
        $RegisterWorkloadClusterWithArgoCD -or
        $VerifyWorkloadClusterRegistration -or
        $GrantWorkloadDeployPermissions -or
        $VerifyWorkloadDeployPermissions -or
        $ConfigureGitOpsRepository -or
        $BootstrapGitOpsRootApplication -or
        $VerifyGitOpsRootApplication -or
        $BootstrapWorkloadObservability -or
        $VerifyWorkloadObservability -or
        $InitializeManagementBackendDatabase
    )) {
    throw "Workload recovery planning modes are plan-only and cannot be combined with launcher execution or preview modes."
}

if ($RepairDevDeployKindRestartPolicies -and (
        $GenerateKindConfigs -or
        $CreateManagementCluster -or
        $CreateWorkloadCluster -or
        $PlanWorkloadRebootstrap -or
        $PlanWorkloadPortRecovery -or
        $PlanManagementPortRecovery -or
        $BootstrapManagementIngress -or
        $BootstrapManagementPostgres -or
        $BuildManagementBackendImage -or
        $LoadManagementBackendImage -or
        $EnsureManagementBackendSecret -or
        $VerifyManagementBackendSecret -or
        $BootstrapManagementBackend -or
        $VerifyManagementBackend -or
        $BuildManagementFrontendImage -or
        $LoadManagementFrontendImage -or
        $BootstrapManagementFrontend -or
        $VerifyManagementFrontend -or
        $BootstrapManagementArgoCD -or
        $VerifyManagementArgoCD -or
        $DiscoverWorkloadClusterEndpoint -or
        $RegisterWorkloadClusterWithArgoCD -or
        $VerifyWorkloadClusterRegistration -or
        $GrantWorkloadDeployPermissions -or
        $VerifyWorkloadDeployPermissions -or
        $ConfigureGitOpsRepository -or
        $BootstrapGitOpsRootApplication -or
        $VerifyGitOpsRootApplication -or
        $BootstrapWorkloadObservability -or
        $VerifyWorkloadObservability -or
        $InitializeManagementBackendDatabase
    )) {
    throw "-RepairDevDeployKindRestartPolicies cannot be combined with other launcher modes."
}

$LauncherVersion = "0.1.0"
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..")).Path
$LocalRoot = Join-Path $RepoRoot ".devdeploy\local"
$StatusDir = Join-Path $LocalRoot "status"
$LogsDir = Join-Path $LocalRoot "logs"
$KindDir = Join-Path $LocalRoot "kind"
$ToolsDir = Join-Path $LocalRoot "tools"
$KubeconfigDir = Join-Path $LocalRoot "kubeconfig"
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
$ArgoCDIngressHost = ""
$ArgoCDIngressPath = "/argocd"
$ArgoCDUiAccess = "http://localhost:8080/argocd"
$WorkloadEndpointProbeNamespace = "devdeploy"
$WorkloadEndpointProbeName = "devdeploy-endpoint-probe"
$WorkloadEndpointProbeImage = $BackendImage
$ArgoCDWorkloadServiceAccountNamespace = "kube-system"
$ArgoCDWorkloadServiceAccountName = "devdeploy-argocd-manager"
$ArgoCDWorkloadTokenSecretName = "devdeploy-argocd-manager-token"
$ArgoCDWorkloadClusterRoleName = "devdeploy-argocd-registration-observer"
$ArgoCDWorkloadClusterRoleBindingName = "devdeploy-argocd-registration-observer"
$ArgoCDWorkloadClusterSecretName = "argocd-cluster-devdeploy-workload"
$ExpectedWorkloadArgoCDEndpoint = "https://devdeploy-workload-control-plane:6443"
$WorkloadManagedNamespace = "devdeploy-apps"
$WorkloadDeployRoleName = "devdeploy-argocd-deployer"
$WorkloadDeployRoleBindingName = "devdeploy-argocd-deployer"
$GitOpsSourcePath = "gitops/workloads/devdeploy-apps"
$GitOpsSourceRelativeWindowsPath = "gitops\workloads\devdeploy-apps"
$GitOpsRootApplicationName = "devdeploy-workloads-root"
$GitOpsExpectedRepositoryUrl = "https://github.com/Kaan-YASSIBAS/devdeploy-hub.git"
$GitOpsTargetRevision = "main"
$ObservabilityNamespace = "monitoring"
$ObservabilityPrometheusRelease = "kube-prometheus-stack"
$ObservabilityPrometheusRepoName = "prometheus-community"
$ObservabilityPrometheusRepoUrl = "https://prometheus-community.github.io/helm-charts"
$ObservabilityPrometheusChart = "prometheus-community/kube-prometheus-stack"
$ObservabilityPrometheusChartVersion = "80.3.1"
$ObservabilityLokiRelease = "loki"
$ObservabilityGrafanaRepoName = "grafana"
$ObservabilityGrafanaRepoUrl = "https://grafana.github.io/helm-charts"
$ObservabilityLokiChart = "grafana/loki"
$ObservabilityLokiChartVersion = "6.46.0"
$ObservabilityAlloyRelease = "alloy"
$ObservabilityAlloyChart = "grafana/alloy"
$ObservabilityAlloyChartVersion = "1.3.0"
$ObservabilityManifestRelativePath = "platform/workload/observability"
$ObservabilityManifestPath = Join-Path $RepoRoot "platform\workload\observability"
$ObservabilityPrometheusValuesPath = Join-Path $ObservabilityManifestPath "kube-prometheus-stack-values.yaml"
$ObservabilityLokiValuesPath = Join-Path $ObservabilityManifestPath "loki-values.yaml"
$ObservabilityAlloyValuesPath = Join-Path $ObservabilityManifestPath "alloy-values.yaml"
$ObservabilityGrafanaDatasourcesPath = Join-Path $ObservabilityManifestPath "grafana-datasources.yaml"
$ObservabilityReaderRbacPath = Join-Path $ObservabilityManifestPath "backend-service-proxy-reader.yaml"
$ObservabilityGrafanaAdminSecretName = "devdeploy-grafana-admin"
$BackendWorkloadKubeconfigSecretName = "devdeploy-backend-workload-kubeconfig"
$ObservabilityReaderServiceAccountName = "devdeploy-observability-reader"
$ObservabilityReaderRoleName = "devdeploy-observability-service-proxy-reader"
$ObservabilityReaderRoleBindingName = "devdeploy-observability-service-proxy-reader"
$ObservabilityReaderTokenSecretName = "devdeploy-observability-reader-token"
$BackendEnvPath = Join-Path $RepoRoot "backend\.env"
$ObservabilityLocalKubeconfigRelativePath = "..\.devdeploy\local\kubeconfig\observability-workload-kubeconfig.yaml"
$ObservabilityLocalKubeconfigPath = Join-Path $KubeconfigDir "observability-workload-kubeconfig.yaml"
$ObservabilityKubeconfigContext = "devdeploy-workload-observability"
$ObservabilityBackendMountDirectory = "/var/run/devdeploy/workload-observability"
$ObservabilityBackendMountPath = "$ObservabilityBackendMountDirectory/kubeconfig"
$HelmPinnedVersion = "v3.18.6"
$HelmPlatform = "windows-amd64"
$HelmArchiveName = "helm-$HelmPinnedVersion-$HelmPlatform.zip"
$HelmDownloadBaseUrl = "https://get.helm.sh"
$HelmArchiveUrl = "$HelmDownloadBaseUrl/$HelmArchiveName"
$HelmChecksumUrl = "$HelmArchiveUrl.sha256sum"
$HelmManagedDir = Join-Path $ToolsDir ("helm\{0}" -f $HelmPinnedVersion)
$HelmManagedArchivePath = Join-Path $HelmManagedDir $HelmArchiveName
$HelmManagedChecksumPath = Join-Path $HelmManagedDir "$HelmArchiveName.sha256sum"
$HelmManagedExePath = Join-Path $HelmManagedDir "$HelmPlatform\helm.exe"
$HelmManagedVerificationPath = Join-Path $HelmManagedDir "devdeploy-helm-verification.json"

$DefaultPortPlan = [ordered]@{
    management_api   = 58080
    management_http  = 8080
    management_https = 8443
    workload_api     = 58081
    workload_http    = 8081
    workload_https   = 8444
}
$WorkloadHttpsCandidatePorts = @(8444, 9444, 10444, 11444, 12444, 13444, 18444, 20444, 21444, 22444, 23444, 24444)
$ManagementHttpsCandidatePorts = @(8443, 9443, 10443, 11443, 12443, 13443, 18443, 20443, 21443, 22443, 23443, 24443)
$ExpectedKindRestartPolicy = "unless-stopped"
$PortPlan = [ordered]@{
    management_api   = [int]$DefaultPortPlan["management_api"]
    management_http  = [int]$DefaultPortPlan["management_http"]
    management_https = [int]$DefaultPortPlan["management_https"]
    workload_api     = [int]$DefaultPortPlan["workload_api"]
    workload_http    = [int]$DefaultPortPlan["workload_http"]
    workload_https   = [int]$DefaultPortPlan["workload_https"]
}
$PortSelection = [ordered]@{}
$ManagementClusterStatusCache = $null

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

function Set-CheckResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,

        [Parameter(Mandatory = $true)]
        [ValidateSet("ok", "warning", "failed", "skipped")]
        [string]$Status,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [hashtable]$Details = @{}
    )

    for ($checkIndex = 0; $checkIndex -lt $Checks.Count; $checkIndex++) {
        $check = $Checks[$checkIndex]
        if ([string]$check["id"] -ne $Id) {
            continue
        }
        $check["status"] = $Status
        $check["message"] = $Message
        $check["details"] = $Details
        $check["checked_at"] = [string](Get-Timestamp)
        Write-LauncherLog ("{0}: reconciled to {1} - {2}" -f $Id, $Status, $Message)
        return $true
    }
    return $false
}

function Get-NamedObjectValue {
    param(
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        return $InputObject[$Name]
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function ConvertTo-PlainHostPublicationDetails {
    param(
        [object]$Publications
    )

    $items = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Publications) {
        return ,([object[]]$items.ToArray())
    }

    foreach ($publication in $Publications) {
        if ($null -eq $publication) {
            continue
        }
        $plain = @{}
        foreach ($field in @("container_port", "expected_host_port", "configured_host_port", "published_host_port", "docker_port_host_port")) {
            $value = Get-NamedObjectValue -InputObject $publication -Name $field
            $plain[$field] = if ($null -eq $value) { $null } else { [int]$value }
        }
        foreach ($field in @("docker_port_owner")) {
            $value = Get-NamedObjectValue -InputObject $publication -Name $field
            $plain[$field] = if ($null -eq $value) { "" } else { [string]$value }
        }
        foreach ($field in @("configured", "published", "publication_consistent", "healthy")) {
            $value = Get-NamedObjectValue -InputObject $publication -Name $field
            $plain[$field] = if ($null -eq $value) { $null } else { [bool]$value }
        }
        $items.Add($plain) | Out-Null
    }

    return ,([object[]]$items.ToArray())
}

function New-ManagementIntegrityCheckDetails {
    param(
        [bool]$Required,

        [Parameter(Mandatory = $true)]
        [string]$IntegrityStatus,

        [object]$InternalClusterReady,

        [bool]$HostAccessHealthy,

        [bool]$RecreationRequired,

        [string]$RecreationReason = "",

        [object]$RequiredHostPublications
    )

    $plainPublications = ConvertTo-PlainHostPublicationDetails -Publications $RequiredHostPublications
    return @{
        required                   = [bool]$Required
        cluster_name               = [string]"devdeploy-mgmt"
        integrity_status           = [string]$IntegrityStatus
        internal_cluster_ready     = if ($null -eq $InternalClusterReady) { $null } else { [bool]$InternalClusterReady }
        host_access_healthy        = [bool]$HostAccessHealthy
        recreation_required        = [bool]$RecreationRequired
        recreation_reason          = [string]$RecreationReason
        required_host_publications = $plainPublications
    }
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

    foreach ($cluster in @($ManagementCluster, $WorkloadCluster)) {
        $integrityStatus = [string]$cluster["integrity_status"]
        $recommendedAction = [string]$cluster["recommended_action"]
        if ($integrityStatus -notin @("ok", "cluster_missing", "unknown") -and -not [string]::IsNullOrWhiteSpace($recommendedAction) -and -not $actions.Contains($recommendedAction)) {
            $actions.Add($recommendedAction) | Out-Null
        }
    }

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
    elseif ($LauncherMode -eq "management_argocd_verify") {
        if ($argocdStatus -eq "ready") {
            $actions.Add("Management Argo CD passed read-only verification. Workload registration and GitOps Application creation remain separate future steps.") | Out-Null
        }
        elseif ($argocdStatus -eq "warning") {
            $actions.Add("Management Argo CD core resources are Ready, but one or more optional verification checks need review.") | Out-Null
        }
        else {
            $actions.Add("Review the sanitized launcher status and logs. Run -BootstrapManagementArgoCD only when you intend to reconcile Argo CD resources.") | Out-Null
        }
    }

    if ($LauncherMode -eq "workload_cluster_endpoint_discovery") {
        $endpointStatus = "not_started"
        try {
            $endpointStatus = [string]$PlatformBootstrap["components"]["workload_cluster_endpoint"]["status"]
        }
        catch {
            $endpointStatus = "unknown"
        }

        if ($endpointStatus -eq "ready") {
            $actions.Add("A workload API endpoint was discovered and verified. Registration with Argo CD remains a separate future step.") | Out-Null
        }
        elseif ($endpointStatus -eq "warning") {
            $actions.Add("Endpoint discovery succeeded, but probe cleanup or an optional check needs review before registration work begins.") | Out-Null
        }
        else {
            $actions.Add("Review the sanitized endpoint probe checks and logs, then rerun -DiscoverWorkloadClusterEndpoint after resolving connectivity or TLS issues.") | Out-Null
        }
    }

    if ($LauncherMode -eq "workload_cluster_argocd_registration") {
        $registrationStatus = "not_started"
        try {
            $registrationStatus = [string]$PlatformBootstrap["components"]["argocd_workload_cluster"]["status"]
        }
        catch {
            $registrationStatus = "unknown"
        }

        if ($registrationStatus -in @("ready", "warning")) {
            $actions.Add("devdeploy-workload is registered with management Argo CD. Proceed to the future GitOps parent Application step when available.") | Out-Null
        }
        else {
            $actions.Add("Review the sanitized registration checks and rerun -DiscoverWorkloadClusterEndpoint before retrying -RegisterWorkloadClusterWithArgoCD if endpoint verification is stale or invalid.") | Out-Null
        }
    }

    if ($LauncherMode -eq "workload_cluster_argocd_registration_verify") {
        $registrationStatus = "not_started"
        try {
            $registrationStatus = [string]$PlatformBootstrap["components"]["argocd_workload_cluster"]["status"]
        }
        catch {
            $registrationStatus = "unknown"
        }

        if ($registrationStatus -in @("ready", "warning")) {
            $actions.Add("Workload cluster registration passed read-only verification. Workload write RBAC and the GitOps parent Application remain future steps.") | Out-Null
        }
        else {
            $actions.Add("Review the sanitized verification checks. Use -RegisterWorkloadClusterWithArgoCD only when you explicitly intend to reconcile registration resources.") | Out-Null
        }
    }

    if ($LauncherMode -eq "workload_deploy_permissions_grant") {
        $permissionStatus = "not_started"
        try {
            $permissionStatus = [string]$PlatformBootstrap["components"]["workload_deploy_permissions"]["status"]
        }
        catch {
            $permissionStatus = "unknown"
        }

        if ($permissionStatus -eq "ready") {
            $actions.Add("Namespace-scoped workload permissions are ready. Configure the GitOps source and parent Application in a separately reviewed future step.") | Out-Null
        }
        else {
            $actions.Add("Review the sanitized workload permission checks and rerun -GrantWorkloadDeployPermissions after resolving the namespace or RBAC issue.") | Out-Null
        }
    }

    if ($LauncherMode -eq "workload_deploy_permissions_verify") {
        $permissionStatus = "not_started"
        try {
            $permissionStatus = [string]$PlatformBootstrap["components"]["workload_deploy_permissions"]["status"]
        }
        catch {
            $permissionStatus = "unknown"
        }

        if ($permissionStatus -eq "ready") {
            $actions.Add("Namespace-scoped workload permissions passed read-only verification. The GitOps parent Application remains a separate future step.") | Out-Null
        }
        else {
            $actions.Add("Review the sanitized permission verification checks. Use -GrantWorkloadDeployPermissions only when you explicitly intend to reconcile the permission resources.") | Out-Null
        }
    }

    if ($LauncherMode -eq "gitops_repository_configure") {
        $gitOpsRepositoryStatus = "not_started"
        try {
            $gitOpsRepositoryStatus = [string]$PlatformBootstrap["components"]["gitops_repository"]["status"]
        }
        catch {
            $gitOpsRepositoryStatus = "unknown"
        }

        if ($gitOpsRepositoryStatus -eq "ready") {
            $actions.Add("The local GitOps repository path is ready. Root Application bootstrap remains a separate future step.") | Out-Null
        }
        else {
            $actions.Add("Review the GitOps repository checks and rerun -ConfigureGitOpsRepository after resolving the local path or Git worktree issue.") | Out-Null
        }
    }

    if ($LauncherMode -eq "gitops_root_application_bootstrap") {
        $rootStatus = "not_started"
        try {
            $rootStatus = [string]$PlatformBootstrap["components"]["gitops_root_application"]["status"]
        }
        catch {
            $rootStatus = "unknown"
        }

        if ($rootStatus -eq "ready") {
            $actions.Add("The GitOps Root Application is ready. Proceed to the future explicit demo workload phase when available.") | Out-Null
        }
        elseif ($rootStatus -eq "warning") {
            $actions.Add("The Root Application exists, but repository access, sync, or health needs review. No user workload was created by this mode.") | Out-Null
        }
        else {
            $actions.Add("Review Root Application prerequisite and verification checks, then rerun -BootstrapGitOpsRootApplication after resolving the issue.") | Out-Null
        }
    }

    if ($LauncherMode -eq "gitops_root_application_verify") {
        $rootStatus = "not_started"
        try {
            $rootStatus = [string]$PlatformBootstrap["components"]["gitops_root_application"]["status"]
        }
        catch {
            $rootStatus = "unknown"
        }

        if ($rootStatus -eq "ready") {
            $actions.Add("The GitOps Root Application passed strict read-only verification. Continue with the future explicit demo workload phase when available.") | Out-Null
        }
        else {
            $actions.Add("Review the sanitized Root Application verification checks. Use -BootstrapGitOpsRootApplication only when you explicitly intend to reconcile the Application.") | Out-Null
        }
    }

    if ($LauncherMode -eq "workload_observability_bootstrap" -or $LauncherMode -eq "workload_observability_verify") {
        $observabilityStatus = "not_started"
        try {
            $observabilityStatus = [string]$PlatformBootstrap["components"]["workload_observability"]["status"]
        }
        catch {
            $observabilityStatus = "unknown"
        }

        if ($observabilityStatus -eq "ready") {
            $actions.Add("Workload observability is ready. Verify backend /api/v1/observability/status after the backend rollout has the service-proxy configuration.") | Out-Null
        }
        elseif ($observabilityStatus -eq "warning") {
            $actions.Add("Workload metrics/logs transport is ready, but optional Grafana readiness needs review.") | Out-Null
        }
        else {
            $actions.Add("Review sanitized workload observability checks and rerun the explicit observability mode after resolving the issue.") | Out-Null
        }
    }

    if ($LauncherMode -eq "management_port_recovery_plan") {
        $actions.Add("Review the plan-only management port recovery steps and verify the PostgreSQL backup before any future management recreation. No command has been executed.") | Out-Null
    }

    if ($LauncherMode -in @("workload_rebootstrap_plan", "workload_port_recovery_plan")) {
        if ($managementClusterStatus -eq "ready") {
            $actions.Add("Review the plan-only workload rebootstrap steps. No command has been executed and user confirmation remains required before manual recreation.") | Out-Null
        }
        else {
            $actions.Add("Restore or verify devdeploy-mgmt before relying on workload rebootstrap validation; the plan does not modify either cluster.") | Out-Null
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

function Join-NativeArguments {
    param(
        [string[]]$Arguments = @()
    )

    $escapedArguments = foreach ($argument in $Arguments) {
        $value = [string]$argument
        if ($value -notmatch '[\s"]' -and $value.Length -gt 0) {
            $value
            continue
        }

        $builder = New-Object System.Text.StringBuilder
        [void]$builder.Append('"')
        $backslashCount = 0
        foreach ($character in $value.ToCharArray()) {
            if ($character -eq '\') {
                $backslashCount += 1
                continue
            }

            if ($character -eq '"') {
                [void]$builder.Append('\', ($backslashCount * 2) + 1)
                [void]$builder.Append('"')
                $backslashCount = 0
                continue
            }

            if ($backslashCount -gt 0) {
                [void]$builder.Append('\', $backslashCount)
                $backslashCount = 0
            }
            [void]$builder.Append($character)
        }

        if ($backslashCount -gt 0) {
            [void]$builder.Append('\', $backslashCount * 2)
        }
        [void]$builder.Append('"')
        $builder.ToString()
    }

    return [string]($escapedArguments -join " ")
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
    $argumentListProperty = $psi.GetType().GetProperty("ArgumentList")
    if ($null -ne $argumentListProperty) {
        foreach ($argument in $Arguments) {
            [void]$psi.ArgumentList.Add([string]$argument)
        }
    }
    else {
        $psi.Arguments = Join-NativeArguments -Arguments $Arguments
    }
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
        $standardOutputTask = $process.StandardOutput.ReadToEndAsync()
        $standardErrorTask = $process.StandardError.ReadToEndAsync()
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
                stdout    = if ($PreserveStandardOutput -and $null -ne $standardOutputTask -and $standardOutputTask.IsCompleted) { $standardOutputTask.Result } else { "" }
                stderr    = "Command timed out."
            }
        }

        $standardOutput = $standardOutputTask.Result
        $standardError = $standardErrorTask.Result
        return [ordered]@{
            exit_code = $process.ExitCode
            timed_out = $false
            stdout    = if ($PreserveStandardOutput) { $standardOutput } else { Protect-LogText $standardOutput }
            stderr    = Protect-LogText $standardError
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

function Set-LauncherManagedBackendEnvValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key,

        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $lines = @()
    if (Test-Path -LiteralPath $BackendEnvPath -PathType Leaf) {
        $lines = @(Get-Content -LiteralPath $BackendEnvPath)
    }

    $updated = $false
    $prefix = "$Key="
    $nextLines = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        if ([string]$line -like "$prefix*") {
            $nextLines.Add("$prefix$Value") | Out-Null
            $updated = $true
        }
        else {
            $nextLines.Add([string]$line) | Out-Null
        }
    }

    if (-not $updated) {
        if ($nextLines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($nextLines[$nextLines.Count - 1])) {
            $nextLines.Add("") | Out-Null
        }
        $nextLines.Add("$prefix$Value") | Out-Null
    }

    Set-Content -LiteralPath $BackendEnvPath -Value @($nextLines | ForEach-Object { [string]$_ }) -Encoding UTF8
}

function Get-LauncherBackendEnvValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    if (-not (Test-Path -LiteralPath $BackendEnvPath -PathType Leaf)) {
        return ""
    }

    $pattern = "^\s*{0}\s*=\s*(.*)\s*$" -f [System.Text.RegularExpressions.Regex]::Escape($Key)
    foreach ($line in @(Get-Content -LiteralPath $BackendEnvPath)) {
        $match = [System.Text.RegularExpressions.Regex]::Match([string]$line, $pattern)
        if ($match.Success) {
            $value = [string]$match.Groups[1].Value
            $value = $value.Trim()
            if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            return $value
        }
    }

    return ""
}

function Resolve-LauncherRuntimePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PathValue
    )

    $expanded = [System.Environment]::ExpandEnvironmentVariables($PathValue.Trim())
    if ($expanded.StartsWith("~")) {
        $home = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
        if ($expanded -eq "~") {
            $expanded = $home
        }
        elseif ($expanded.StartsWith("~/") -or $expanded.StartsWith("~\")) {
            $expanded = Join-Path $home $expanded.Substring(2)
        }
    }

    if ([System.IO.Path]::IsPathRooted($expanded)) {
        return [string]$expanded
    }

    return [string](Join-Path $RepoRoot $expanded)
}

function Set-ContentAtomicUtf8 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-LocalDirectory -Path $directory
    }

    $temporaryPath = Join-Path $directory (".{0}.{1}.tmp" -f (Split-Path -Leaf $Path), [System.Guid]::NewGuid().ToString("N"))
    try {
        Set-Content -LiteralPath $temporaryPath -Value $Value -Encoding UTF8
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Get-LauncherWorkloadKubeconfigSelection {
    if (Test-Path -LiteralPath $ObservabilityLocalKubeconfigPath -PathType Leaf) {
        return [ordered]@{
            kubeconfig_path = [string]$ObservabilityLocalKubeconfigPath
            context = [string]$ObservabilityKubeconfigContext
            source = "launcher_managed_observability_kubeconfig"
        }
    }

    $path = [string]$env:DEVDEPLOY_WORKLOAD_KUBECONFIG
    $source = "process_environment"
    if ([string]::IsNullOrWhiteSpace($path)) {
        $path = [string](Get-LauncherBackendEnvValue -Key "DEVDEPLOY_WORKLOAD_KUBECONFIG")
        $source = "backend_environment"
    }

    $context = [string]$env:DEVDEPLOY_WORKLOAD_KUBECONFIG_CONTEXT
    if ([string]::IsNullOrWhiteSpace($context)) {
        $context = [string](Get-LauncherBackendEnvValue -Key "DEVDEPLOY_WORKLOAD_KUBECONFIG_CONTEXT")
    }
    if ([string]::IsNullOrWhiteSpace($context)) {
        $context = "kind-devdeploy-workload"
    }

    $resolvedPath = ""
    if (-not [string]::IsNullOrWhiteSpace($path)) {
        $resolvedPath = Resolve-LauncherRuntimePath -PathValue $path
    }

    return [ordered]@{
        kubeconfig_path = $resolvedPath
        context = $context.Trim()
        source = $source
    }
}

function Get-CommandResultField {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Result,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($Result -is [System.Collections.IDictionary] -and $Result.Contains($Name)) {
        return $Result[$Name]
    }

    $property = $Result.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return $property.Value
    }

    return $null
}

function Convert-CommandStdoutToString {
    param(
        [AllowNull()]
        [object]$Stdout
    )

    if ($null -eq $Stdout) {
        return ""
    }

    if ($Stdout -is [string]) {
        $text = [string]$Stdout
    }
    elseif ($Stdout -is [System.Array]) {
        $text = [string](@($Stdout | ForEach-Object { [string]$_ }) -join "`n")
    }
    else {
        $valueProperty = $Stdout.PSObject.Properties["stdout"]
        if ($null -ne $valueProperty) {
            return Convert-CommandStdoutToString -Stdout $valueProperty.Value
        }
        $text = [string]$Stdout
    }

    return [string]$text.TrimStart([char]0xFEFF).Trim()
}

function Get-SafeTypeName {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return "null"
    }
    return [string]$Value.GetType().FullName
}

function Write-HostWorkloadKubeconfigDiagnostic {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Category,

        [AllowNull()]
        [object]$ExitCode,

        [bool]$StdoutEmpty,

        [string]$StdoutType,

        [bool]$ServerFound = $false,

        [bool]$CertificateAuthorityFound = $false
    )

    Write-LauncherLog ("Host workload kubeconfig endpoint resolution failed: category={0}; exit_code={1}; stdout_empty={2}; stdout_type={3}; server_found={4}; ca_found={5}" -f $Category, [string]$ExitCode, [string]$StdoutEmpty, $StdoutType, [string]$ServerFound, [string]$CertificateAuthorityFound)
}

function Get-JsonPropertyValue {
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return ,$property.Value
}

function Convert-HostWorkloadKubeconfigJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Json
    )

    $result = [ordered]@{
        ok = $false
        server = ""
        certificate_authority_data = ""
        server_found = $false
        certificate_authority_found = $false
        insecure_skip_tls_verify = $false
        error_category = ""
    }

    try {
        $parsed = $Json | ConvertFrom-Json
    }
    catch {
        $result["error_category"] = "malformed_json"
        return $result
    }

    $clustersValue = Get-JsonPropertyValue -Object $parsed -Name "clusters"
    if ($null -eq $clustersValue) {
        $result["error_category"] = "missing_clusters_property"
        return $result
    }

    $clusters = @($clustersValue)
    if ($clusters.Count -lt 1 -or $null -eq $clusters[0]) {
        $result["error_category"] = "empty_clusters"
        return $result
    }

    $clusterEntry = $clusters[0]
    $clusterData = Get-JsonPropertyValue -Object $clusterEntry -Name "cluster"
    if ($null -eq $clusterData) {
        $result["error_category"] = "missing_cluster_property"
        return $result
    }

    $server = [string](Get-JsonPropertyValue -Object $clusterData -Name "server")
    $caData = [string](Get-JsonPropertyValue -Object $clusterData -Name "certificate-authority-data")
    $insecure = Get-JsonPropertyValue -Object $clusterData -Name "insecure-skip-tls-verify"

    $result["server_found"] = -not [string]::IsNullOrWhiteSpace($server)
    $result["certificate_authority_found"] = -not [string]::IsNullOrWhiteSpace($caData)
    $result["insecure_skip_tls_verify"] = ($insecure -eq $true)

    if (-not [bool]$result["server_found"]) {
        $result["error_category"] = "missing_server"
        return $result
    }
    if (-not [bool]$result["certificate_authority_found"]) {
        $result["error_category"] = "missing_ca"
        return $result
    }
    if ([bool]$result["insecure_skip_tls_verify"]) {
        $result["error_category"] = "insecure_skip_tls_verify"
        return $result
    }

    $result["ok"] = $true
    $result["server"] = $server
    $result["certificate_authority_data"] = $caData
    return $result
}

function Get-HostWorkloadKubeconfigCluster {
    param(
        [bool]$KubectlAvailable
    )

    $selection = Get-LauncherWorkloadKubeconfigSelection
    $result = [ordered]@{
        ok = $false
        context = [string]$selection["context"]
        source = [string]$selection["source"]
        kubeconfig_path_set = -not [string]::IsNullOrWhiteSpace([string]$selection["kubeconfig_path"])
        server = ""
        certificate_authority_data_present = $false
        message = "The host workload kubeconfig endpoint could not be resolved."
    }

    if (-not $KubectlAvailable) {
        $result["message"] = "kubectl is required to read the selected workload kubeconfig endpoint."
        return $result
    }

    $args = @("config", "view")
    if ($result["kubeconfig_path_set"]) {
        $args += @("--kubeconfig", [string]$selection["kubeconfig_path"])
    }
    $args += @("--context", [string]$selection["context"], "--minify", "--raw", "--output=json")

    $viewResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments $args -TimeoutSeconds 20 -PreserveStandardOutput $true
    $exitCode = Get-CommandResultField -Result $viewResult -Name "exit_code"
    $timedOut = [bool](Get-CommandResultField -Result $viewResult -Name "timed_out")
    $stdoutValue = Get-CommandResultField -Result $viewResult -Name "stdout"
    $stderrValue = Get-CommandResultField -Result $viewResult -Name "stderr"
    $stdoutText = Convert-CommandStdoutToString -Stdout $stdoutValue
    $stdoutEmpty = [string]::IsNullOrWhiteSpace($stdoutText)
    $stdoutType = Get-SafeTypeName -Value $stdoutValue

    if ($exitCode -ne 0 -or $timedOut -or $stdoutEmpty) {
        $result["message"] = "The selected workload kubeconfig context could not be read safely."
        $result["kubectl_exit_code"] = $exitCode
        $result["kubectl_timed_out"] = $timedOut
        $result["kubectl_error"] = if ($exitCode -ne 0 -or $timedOut) { [string]$stderrValue } else { "" }
        $result["stdout_empty"] = $stdoutEmpty
        $result["stdout_type"] = $stdoutType
        Write-HostWorkloadKubeconfigDiagnostic -Category "command_failed_or_empty_stdout" -ExitCode $exitCode -StdoutEmpty $stdoutEmpty -StdoutType $stdoutType
        return $result
    }

    $parsedCluster = Convert-HostWorkloadKubeconfigJson -Json $stdoutText
    if (-not [bool]$parsedCluster["ok"]) {
        $result["message"] = "The selected workload kubeconfig context could not be parsed safely."
        $result["parse_error"] = [string]$parsedCluster["error_category"]
        Write-HostWorkloadKubeconfigDiagnostic -Category ([string]$parsedCluster["error_category"]) -ExitCode $exitCode -StdoutEmpty $stdoutEmpty -StdoutType $stdoutType -ServerFound ([bool]$parsedCluster["server_found"]) -CertificateAuthorityFound ([bool]$parsedCluster["certificate_authority_found"])
        return $result
    }

    $result["ok"] = $true
    $result["server"] = [string]$parsedCluster["server"]
    $result["certificate_authority_data"] = [string]$parsedCluster["certificate_authority_data"]
    $result["certificate_authority_data_present"] = $true
    $result["message"] = "The host-reachable workload API endpoint was resolved from the selected workload kubeconfig context."
    return $result
}

function Set-LauncherManagedObservabilityBackendEnv {
    Set-LauncherManagedBackendEnvValue -Key "DEVDEPLOY_OBSERVABILITY_ACCESS_MODE" -Value "kubernetes_service_proxy"
    Set-LauncherManagedBackendEnvValue -Key "DEVDEPLOY_OBSERVABILITY_WORKLOAD_KUBECONFIG" -Value $ObservabilityLocalKubeconfigRelativePath
    Set-LauncherManagedBackendEnvValue -Key "DEVDEPLOY_OBSERVABILITY_WORKLOAD_KUBECONFIG_CONTEXT" -Value $ObservabilityKubeconfigContext

    Add-Check -Id "workload_observability_local_backend_env" -Label "Local backend workload environment" -Status "ok" -Message "Local backend read-only workload and observability readers were configured with the launcher-managed kubeconfig; normal workload credentials were preserved separately." -Details @{
        required = $false
        env_file = "backend/.env"
        kubeconfig_path = $ObservabilityLocalKubeconfigRelativePath
        context = $ObservabilityKubeconfigContext
        normal_workload_kubeconfig_modified = $false
        secret_values_written = $false
    }
}

function Test-HelmCommandCompatible {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [bool]$RequirePinnedVersion = $false
    )

    $result = Invoke-ReadOnlyCommand -FileName $Command -Arguments @("version", "--template", "{{.Version}}") -TimeoutSeconds 20 -PreserveStandardOutput $true
    $version = [string]$result.stdout
    $version = $version.Trim()
    $compatible = [bool]($result.exit_code -eq 0 -and -not $result.timed_out -and $version -match "^v3\.")
    if ($RequirePinnedVersion) {
        $compatible = [bool]($compatible -and $version -eq $HelmPinnedVersion)
    }

    return [ordered]@{
        compatible = [bool]$compatible
        version    = [string]$version
        error      = [string]$result.stderr
    }
}

function Test-ManagedHelmVerified {
    if (-not (Test-Path -LiteralPath $HelmManagedExePath -PathType Leaf)) {
        return $false
    }
    if (-not (Test-Path -LiteralPath $HelmManagedVerificationPath -PathType Leaf)) {
        return $false
    }

    try {
        $verification = Get-Content -LiteralPath $HelmManagedVerificationPath -Raw | ConvertFrom-Json
        $expectedExeHash = [string]$verification.exe_sha256
        if ([string]::IsNullOrWhiteSpace($expectedExeHash)) {
            return $false
        }
        $actualExeHash = [string](Get-FileHash -LiteralPath $HelmManagedExePath -Algorithm SHA256).Hash
        return [bool]($actualExeHash.ToLowerInvariant() -eq $expectedExeHash.ToLowerInvariant())
    }
    catch {
        Write-LauncherLog ("Managed Helm verification failed: {0}" -f $_.Exception.Message)
        return $false
    }
}

function Invoke-PrepareManagedHelm {
    $result = [ordered]@{
        available = $false
        command   = ""
        source    = "managed"
        version   = $HelmPinnedVersion
        message   = ""
    }

    try {
        New-LocalDirectory -Path $ToolsDir
        New-LocalDirectory -Path $HelmManagedDir

        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $HelmChecksumUrl -OutFile $HelmManagedChecksumPath -UseBasicParsing -TimeoutSec 120
        Invoke-WebRequest -Uri $HelmArchiveUrl -OutFile $HelmManagedArchivePath -UseBasicParsing -TimeoutSec 300

        $checksumText = [string](Get-Content -LiteralPath $HelmManagedChecksumPath -Raw)
        $expectedHash = ""
        if ($checksumText -match "([a-fA-F0-9]{64})") {
            $expectedHash = $Matches[1]
        }
        if ([string]::IsNullOrWhiteSpace($expectedHash)) {
            $result["message"] = "Official Helm checksum file did not contain a SHA256 checksum."
            return $result
        }

        $actualHash = [string](Get-FileHash -LiteralPath $HelmManagedArchivePath -Algorithm SHA256).Hash
        if ($actualHash.ToLowerInvariant() -ne $expectedHash.ToLowerInvariant()) {
            $result["message"] = "Helm archive checksum mismatch; refusing to use the downloaded binary."
            return $result
        }

        Expand-Archive -LiteralPath $HelmManagedArchivePath -DestinationPath $HelmManagedDir -Force
        if (-not (Test-Path -LiteralPath $HelmManagedExePath -PathType Leaf)) {
            $result["message"] = "Verified Helm archive did not contain the expected helm.exe path."
            return $result
        }

        $versionCheck = Test-HelmCommandCompatible -Command $HelmManagedExePath -RequirePinnedVersion $true
        if (-not [bool]$versionCheck["compatible"]) {
            $result["message"] = "Managed Helm binary did not report the pinned Helm version."
            return $result
        }

        $exeHash = [string](Get-FileHash -LiteralPath $HelmManagedExePath -Algorithm SHA256).Hash
        $verification = [ordered]@{
            version             = $HelmPinnedVersion
            platform            = $HelmPlatform
            archive_sha256      = $actualHash
            exe_sha256          = $exeHash
            checksum_source_url = $HelmChecksumUrl
            archive_source_url  = $HelmArchiveUrl
            verified_at         = [string](Get-Timestamp)
        }
        $verification | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $HelmManagedVerificationPath -Encoding UTF8

        $result["available"] = $true
        $result["command"] = [string]$HelmManagedExePath
        $result["message"] = "Pinned Helm $HelmPinnedVersion was downloaded from the official Helm release source and checksum verified."
        return $result
    }
    catch {
        $result["message"] = Protect-LogText $_.Exception.Message
        return $result
    }
}

function Resolve-WorkloadObservabilityHelm {
    param(
        [bool]$BootstrapMode = $false
    )

    $pathCommand = Get-Command "helm" -ErrorAction SilentlyContinue
    if ($null -ne $pathCommand) {
        $pathHelm = Test-HelmCommandCompatible -Command "helm"
        if ([bool]$pathHelm["compatible"]) {
            Add-Check -Id "workload_observability_helm_dependency" -Label "Workload observability Helm dependency" -Status "ok" -Message "A compatible Helm v3 CLI is available on PATH." -Details @{
                required = $true
                source = "path"
                command = "helm"
                version = [string]$pathHelm["version"]
                installs_dependency = $false
            }
            return [ordered]@{
                available = $true
                command   = "helm"
                source    = "path"
                version   = [string]$pathHelm["version"]
            }
        }
    }

    if (Test-ManagedHelmVerified) {
        $managedHelm = Test-HelmCommandCompatible -Command $HelmManagedExePath -RequirePinnedVersion $true
        if ([bool]$managedHelm["compatible"]) {
            Add-Check -Id "workload_observability_helm_dependency" -Label "Workload observability Helm dependency" -Status "ok" -Message "Using DevDeploy-managed pinned Helm." -Details @{
                required = $true
                source = "managed"
                command = $HelmManagedExePath
                version = [string]$managedHelm["version"]
                installs_dependency = $false
            }
            return [ordered]@{
                available = $true
                command   = [string]$HelmManagedExePath
                source    = "managed"
                version   = [string]$managedHelm["version"]
            }
        }
    }

    if (-not $BootstrapMode) {
        Add-Check -Id "workload_observability_helm_dependency" -Label "Workload observability Helm dependency" -Status "failed" -Message "Helm is required for read-only workload observability verification, but no compatible verified Helm CLI is available." -Details @{
            required = $true
            source = "none"
            pinned_version = $HelmPinnedVersion
            installs_dependency = $false
        }
        return [ordered]@{
            available = $false
            command   = ""
            source    = "none"
            version   = ""
        }
    }

    $prepared = Invoke-PrepareManagedHelm
    $preparedOk = [bool]$prepared["available"]
    Add-Check -Id "workload_observability_helm_dependency" -Label "Workload observability Helm dependency" -Status $(if ($preparedOk) { "ok" } else { "failed" }) -Message ([string]$prepared["message"]) -Details @{
        required = $true
        source = "managed"
        command = $HelmManagedExePath
        pinned_version = $HelmPinnedVersion
        checksum_source = $HelmChecksumUrl
        archive_source = $HelmArchiveUrl
        installs_dependency = $true
        checksum_verified = $preparedOk
    }
    return $prepared
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

function Set-DockerDaemonCheckFromEvidence {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Evidence
    )

    foreach ($check in $Checks) {
        if ([string]$check["id"] -ne "docker_daemon" -or [string]$check["status"] -ne "failed") {
            continue
        }

        $initialMessage = [string]$check["message"]
        $initialTimedOut = [bool]($initialMessage -match "timed out")
        return (Set-CheckResult -Id "docker_daemon" -Status "ok" -Message "Docker daemon reachability was confirmed by later successful read-only evidence." -Details @{
                required = $true
                evidence = $Evidence
                initial_probe_status = $(if ($initialTimedOut) { "timed_out" } else { "failed" })
                initial_probe_recorded = $true
                superseded = $true
            })
    }

    return $false
}

function Test-DockerDaemonFollowUp {
    param(
        [bool]$DockerCliAvailable
    )

    if (-not $DockerCliAvailable) {
        return $false
    }

    $result = Invoke-ReadOnlyCommand -FileName "docker" -Arguments @("version", "--format", "{{json .Server.Version}}") -TimeoutSeconds 20
    if ($result.exit_code -ne 0 -or $result.timed_out -or [string]::IsNullOrWhiteSpace([string]$result.stdout)) {
        return $false
    }

    Set-DockerDaemonCheckFromEvidence -Evidence "docker_version_read_only" | Out-Null
    return $true
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

function Get-WindowsExcludedTcpPortRanges {
    $ranges = New-Object System.Collections.Generic.List[object]
    if (-not [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
        return @($ranges | ForEach-Object { $_ })
    }

    $result = Invoke-ReadOnlyCommand -FileName "netsh" -Arguments @("interface", "ipv4", "show", "excludedportrange", "protocol=tcp") -TimeoutSeconds 10 -PreserveStandardOutput $true
    if ($result.exit_code -ne 0 -or $result.timed_out -or [string]::IsNullOrWhiteSpace($result.stdout)) {
        Write-LauncherLog "Windows excluded TCP port range query was unavailable; bind checks will still be used."
        return @($ranges | ForEach-Object { $_ })
    }

    foreach ($line in @(([string]$result.stdout) -split "\r?\n")) {
        $match = [System.Text.RegularExpressions.Regex]::Match([string]$line, '^\s*(\d+)\s+(\d+)\s*$')
        if ($match.Success) {
            $ranges.Add([ordered]@{
                    start = [int]$match.Groups[1].Value
                    end   = [int]$match.Groups[2].Value
                }) | Out-Null
        }
    }

    return @($ranges | ForEach-Object { $_ })
}

function Test-PortInExcludedRanges {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port,

        [object[]]$Ranges = @()
    )

    foreach ($range in @($Ranges)) {
        if ($null -eq $range) {
            continue
        }

        $start = [int]$range["start"]
        $end = [int]$range["end"]
        if ($Port -ge $start -and $Port -le $end) {
            return $true
        }
    }

    return $false
}

function Test-HostPortBindAvailable {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    $listener = $null
    try {
        $endpoint = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse("127.0.0.1")), $Port
        $listener = New-Object System.Net.Sockets.TcpListener $endpoint
        $listener.Start()
        return [ordered]@{
            available = $true
            error     = ""
        }
    }
    catch {
        return [ordered]@{
            available = $false
            error     = Protect-LogText $_.Exception.Message
        }
    }
    finally {
        if ($null -ne $listener) {
            $listener.Stop()
        }
    }
}

function Get-DockerPublishedHostPorts {
    param(
        [bool]$DockerAvailable,

        [bool]$DockerDaemonReachable
    )

    return @(
        Get-DockerPublishedPortOwnership -DockerAvailable $DockerAvailable -DockerDaemonReachable $DockerDaemonReachable |
            ForEach-Object { [int]$_['host_port'] } |
            Select-Object -Unique
    )
}

function Get-DockerPublishedPortOwnership {
    param(
        [bool]$DockerAvailable,

        [bool]$DockerDaemonReachable
    )

    $ownership = New-Object System.Collections.Generic.List[object]
    if (-not $DockerAvailable) {
        return @($ownership | ForEach-Object { $_ })
    }

    $result = Invoke-ReadOnlyCommand -FileName "docker" -Arguments @("ps", "--format", "{{.Names}}|{{.Ports}}") -TimeoutSeconds 10 -PreserveStandardOutput $true
    if ($result.exit_code -ne 0 -or $result.timed_out -or [string]::IsNullOrWhiteSpace($result.stdout)) {
        return @($ownership | ForEach-Object { $_ })
    }

    foreach ($line in @(([string]$result.stdout) -split "\r?\n")) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line -notmatch '^([^|]+)\|(.*)$') {
            continue
        }
        $containerName = [string]$Matches[1]
        $portsText = [string]$Matches[2]
        foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($portsText, '(?:(?:127\.0\.0\.1|0\.0\.0\.0|\[::\]|::):)?(\d+)->(\d+)\/tcp')) {
            $ownership.Add([ordered]@{
                    host_port      = [int]$match.Groups[1].Value
                    container_port = [int]$match.Groups[2].Value
                    container_name = $containerName
                }) | Out-Null
        }
    }

    return @($ownership | ForEach-Object { $_ })
}

function Get-DockerContainerPublishedHostPort {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ContainerName,

        [Parameter(Mandatory = $true)]
        [int]$ContainerPort,

        [bool]$DockerAvailable,

        [bool]$DockerDaemonReachable
    )

    $bindingState = Get-DockerContainerPortBindingState -ContainerName $ContainerName -ContainerPort $ContainerPort -DockerAvailable $DockerAvailable -DockerDaemonReachable $DockerDaemonReachable
    if ($null -ne $bindingState["published_host_port"]) {
        return [int]$bindingState["published_host_port"]
    }
    return $null
}

function Get-DockerContainerPortBindingState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ContainerName,

        [Parameter(Mandatory = $true)]
        [int]$ContainerPort,

        [bool]$DockerAvailable,

        [bool]$DockerDaemonReachable
    )

    $state = [ordered]@{
        container_port        = $ContainerPort
        configured_host_port  = $null
        published_host_port   = $null
        docker_port_host_port = $null
        configured            = $false
        published             = $false
        docker_port_reported  = $false
        publication_consistent = $false
        inspect_succeeded     = $false
    }
    if (-not $DockerAvailable) {
        return $state
    }

    $portKey = "{0}/tcp" -f $ContainerPort
    foreach ($inspection in @(
            @{ field = "configured_host_port"; source = ".HostConfig.PortBindings" },
            @{ field = "published_host_port"; source = ".NetworkSettings.Ports" }
        )) {
        $inspectResult = Invoke-ReadOnlyCommand -FileName "docker" -Arguments @("inspect", "--format", ("{{{{json {0}}}}}" -f [string]$inspection.source), $ContainerName) -TimeoutSeconds 10 -PreserveStandardOutput $true
        if ($inspectResult.exit_code -ne 0 -or $inspectResult.timed_out -or [string]::IsNullOrWhiteSpace($inspectResult.stdout)) {
            continue
        }

        try {
            $parsed = ([string]$inspectResult.stdout).Trim() | ConvertFrom-Json
            $bindingProperty = $parsed.PSObject.Properties[$portKey]
            if ($null -eq $bindingProperty -or $null -eq $bindingProperty.Value) {
                continue
            }
            foreach ($binding in @($bindingProperty.Value)) {
                if ($null -eq $binding) {
                    continue
                }
                $hostPortProperty = $binding.PSObject.Properties["HostPort"]
                if ($null -ne $hostPortProperty -and -not [string]::IsNullOrWhiteSpace([string]$hostPortProperty.Value)) {
                    $state[[string]$inspection.field] = [int]$hostPortProperty.Value
                    break
                }
            }
            $state["inspect_succeeded"] = $true
        }
        catch {
            Write-LauncherLog ("Could not parse sanitized Docker {0} port metadata for {1}:{2}." -f [string]$inspection.field, $ContainerName, $ContainerPort)
        }
    }

    $portResult = Invoke-ReadOnlyCommand -FileName "docker" -Arguments @("port", $ContainerName, $portKey) -TimeoutSeconds 10 -PreserveStandardOutput $true
    if ($portResult.exit_code -eq 0 -and -not $portResult.timed_out -and -not [string]::IsNullOrWhiteSpace($portResult.stdout)) {
        $portMatch = [System.Text.RegularExpressions.Regex]::Match([string]$portResult.stdout, ':(\d+)\s*$')
        if ($portMatch.Success) {
            $state["docker_port_host_port"] = [int]$portMatch.Groups[1].Value
        }
    }

    $state["configured"] = [bool]($null -ne $state["configured_host_port"])
    $state["published"] = [bool]($null -ne $state["published_host_port"])
    $state["docker_port_reported"] = [bool]($null -ne $state["docker_port_host_port"])
    $state["publication_consistent"] = [bool](
        $state["configured"] -and
        $state["published"] -and
        $state["docker_port_reported"] -and
        [int]$state["configured_host_port"] -eq [int]$state["published_host_port"] -and
        [int]$state["published_host_port"] -eq [int]$state["docker_port_host_port"]
    )
    return $state
}

function Get-DockerContainerRestartPolicy {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("devdeploy-mgmt", "devdeploy-workload")]
        [string]$ClusterName,

        [Parameter(Mandatory = $true)]
        [ValidateSet("devdeploy-mgmt-control-plane", "devdeploy-workload-control-plane")]
        [string]$ControlPlaneContainer,

        [bool]$DockerAvailable,

        [bool]$DockerDaemonReachable
    )

    if (-not $DockerAvailable) {
        return [ordered]@{
            known                 = $false
            policy_name           = ""
            maximum_retry_count   = $null
            healthy               = $false
            reconciliation_needed = $null
            error                 = "Docker is unavailable."
        }
    }

    $result = Invoke-ReadOnlyCommand -FileName "docker" -Arguments @("inspect", "--format", "{{json .HostConfig.RestartPolicy}}", $ControlPlaneContainer) -TimeoutSeconds 10 -PreserveStandardOutput $true
    if ($result.exit_code -ne 0 -or $result.timed_out -or [string]::IsNullOrWhiteSpace($result.stdout)) {
        return [ordered]@{
            known                 = $false
            policy_name           = ""
            maximum_retry_count   = $null
            healthy               = $false
            reconciliation_needed = $null
            error                 = if ($result.timed_out) { "Docker inspect timed out." } else { Protect-LogText $result.stderr }
        }
    }

    try {
        $parsed = ([string]$result.stdout).Trim() | ConvertFrom-Json
        $nameProperty = $parsed.PSObject.Properties["Name"]
        $retryProperty = $parsed.PSObject.Properties["MaximumRetryCount"]
        $policyName = if ($null -ne $nameProperty) { [string]$nameProperty.Value } else { "" }
        $maximumRetryCount = if ($null -ne $retryProperty -and $null -ne $retryProperty.Value) { [int]$retryProperty.Value } else { $null }
        $healthy = [bool]($policyName -eq $ExpectedKindRestartPolicy)

        return [ordered]@{
            known                 = $true
            policy_name           = $policyName
            maximum_retry_count   = $maximumRetryCount
            healthy               = $healthy
            reconciliation_needed = [bool](-not $healthy)
            error                 = ""
        }
    }
    catch {
        return [ordered]@{
            known                 = $false
            policy_name           = ""
            maximum_retry_count   = $null
            healthy               = $false
            reconciliation_needed = $null
            error                 = Protect-LogText $_.Exception.Message
        }
    }
}

function Add-KindRestartPolicyCheck {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClusterName,

        [Parameter(Mandatory = $true)]
        [string]$ControlPlaneContainer,

        [Parameter(Mandatory = $true)]
        [object]$RestartPolicy
    )

    $checkId = "kind_restart_policy_{0}" -f $ClusterName
    if (-not [bool]$RestartPolicy["known"]) {
        Add-Check -Id $checkId -Label ("{0} Docker restart policy" -f $ClusterName) -Status "warning" -Message ("Could not verify Docker restart policy for {0}." -f $ControlPlaneContainer) -Details @{
            required                = $false
            cluster_name            = $ClusterName
            control_plane_container = $ControlPlaneContainer
            expected_policy         = $ExpectedKindRestartPolicy
            restart_policy_known    = $false
            reconciliation_needed   = $null
            error                   = [string]$RestartPolicy["error"]
        }
        return
    }

    $healthy = [bool]$RestartPolicy["healthy"]
    $message = if ($healthy) {
        "Docker restart policy is unless-stopped for {0}." -f $ControlPlaneContainer
    }
    else {
        "Docker restart policy for {0} is {1}; reconcile it to unless-stopped with an explicit launcher repair or create mode." -f $ControlPlaneContainer, [string]$RestartPolicy["policy_name"]
    }

    Add-Check -Id $checkId -Label ("{0} Docker restart policy" -f $ClusterName) -Status $(if ($healthy) { "ok" } else { "warning" }) -Message $message -Details @{
        required                = $false
        cluster_name            = $ClusterName
        control_plane_container = $ControlPlaneContainer
        expected_policy         = $ExpectedKindRestartPolicy
        policy_name             = [string]$RestartPolicy["policy_name"]
        maximum_retry_count     = $RestartPolicy["maximum_retry_count"]
        restart_policy_healthy  = $healthy
        reconciliation_needed   = [bool]$RestartPolicy["reconciliation_needed"]
    }
}

function Invoke-KindRestartPolicyReconcile {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("devdeploy-mgmt", "devdeploy-workload")]
        [string]$ClusterName,

        [Parameter(Mandatory = $true)]
        [ValidateSet("devdeploy-mgmt-control-plane", "devdeploy-workload-control-plane")]
        [string]$ControlPlaneContainer,

        [bool]$DockerAvailable,

        [bool]$DockerDaemonReachable
    )

    if (-not $DockerAvailable -or -not $DockerDaemonReachable) {
        Add-Check -Id ("kind_restart_policy_reconcile_{0}" -f $ClusterName) -Label ("{0} restart policy reconcile" -f $ClusterName) -Status "failed" -Message "Docker is required to reconcile the kind node restart policy." -Details @{
            required                = $true
            cluster_name            = $ClusterName
            control_plane_container = $ControlPlaneContainer
            expected_policy         = $ExpectedKindRestartPolicy
        }
        return $false
    }

    $before = Get-DockerContainerRestartPolicy -ClusterName $ClusterName -ControlPlaneContainer $ControlPlaneContainer -DockerAvailable $DockerAvailable -DockerDaemonReachable $DockerDaemonReachable
    if ([bool]$before["known"] -and [bool]$before["healthy"]) {
        Add-Check -Id ("kind_restart_policy_reconcile_{0}" -f $ClusterName) -Label ("{0} restart policy reconcile" -f $ClusterName) -Status "ok" -Message ("Docker restart policy is already unless-stopped for {0}." -f $ControlPlaneContainer) -Details @{
            required                = $true
            cluster_name            = $ClusterName
            control_plane_container = $ControlPlaneContainer
            expected_policy         = $ExpectedKindRestartPolicy
            policy_name             = [string]$before["policy_name"]
            updated                 = $false
        }
        return $true
    }

    $updateResult = Invoke-ReadOnlyCommand -FileName "docker" -Arguments @("update", "--restart", $ExpectedKindRestartPolicy, $ControlPlaneContainer) -TimeoutSeconds 30
    if ($updateResult.exit_code -ne 0 -or $updateResult.timed_out) {
        Add-Check -Id ("kind_restart_policy_reconcile_{0}" -f $ClusterName) -Label ("{0} restart policy reconcile" -f $ClusterName) -Status "failed" -Message ("Could not reconcile Docker restart policy for {0}. No cluster deletion or cleanup was performed." -f $ControlPlaneContainer) -Details @{
            required                = $true
            cluster_name            = $ClusterName
            control_plane_container = $ControlPlaneContainer
            expected_policy         = $ExpectedKindRestartPolicy
            previous_policy         = if ([bool]$before["known"]) { [string]$before["policy_name"] } else { "" }
            error                   = if ($updateResult.timed_out) { "Docker update timed out." } else { [string]$updateResult.stderr }
            deletes_cluster         = $false
        }
        return $false
    }

    $after = Get-DockerContainerRestartPolicy -ClusterName $ClusterName -ControlPlaneContainer $ControlPlaneContainer -DockerAvailable $DockerAvailable -DockerDaemonReachable $DockerDaemonReachable
    if (-not [bool]$after["known"] -or -not [bool]$after["healthy"]) {
        Add-Check -Id ("kind_restart_policy_reconcile_{0}" -f $ClusterName) -Label ("{0} restart policy reconcile" -f $ClusterName) -Status "failed" -Message ("Docker accepted restart policy update for {0}, but verification did not confirm unless-stopped." -f $ControlPlaneContainer) -Details @{
            required                = $true
            cluster_name            = $ClusterName
            control_plane_container = $ControlPlaneContainer
            expected_policy         = $ExpectedKindRestartPolicy
            verified_policy         = if ([bool]$after["known"]) { [string]$after["policy_name"] } else { "" }
            deletes_cluster         = $false
        }
        return $false
    }

    Add-Check -Id ("kind_restart_policy_reconcile_{0}" -f $ClusterName) -Label ("{0} restart policy reconcile" -f $ClusterName) -Status "ok" -Message ("Docker restart policy was reconciled to unless-stopped for {0}." -f $ControlPlaneContainer) -Details @{
        required                = $true
        cluster_name            = $ClusterName
        control_plane_container = $ControlPlaneContainer
        expected_policy         = $ExpectedKindRestartPolicy
        previous_policy         = if ([bool]$before["known"]) { [string]$before["policy_name"] } else { "" }
        policy_name             = [string]$after["policy_name"]
        updated                 = $true
        deletes_cluster         = $false
    }
    return $true
}

function Invoke-DevDeployKindRestartPolicyRepair {
    param(
        [bool]$DockerAvailable,

        [bool]$DockerDaemonReachable
    )

    $managementReady = Invoke-KindRestartPolicyReconcile -ClusterName "devdeploy-mgmt" -ControlPlaneContainer "devdeploy-mgmt-control-plane" -DockerAvailable $DockerAvailable -DockerDaemonReachable $DockerDaemonReachable
    $workloadReady = Invoke-KindRestartPolicyReconcile -ClusterName "devdeploy-workload" -ControlPlaneContainer "devdeploy-workload-control-plane" -DockerAvailable $DockerAvailable -DockerDaemonReachable $DockerDaemonReachable

    return [bool]($managementReady -and $workloadReady)
}

function Test-HostPortSafety {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port,

        [object[]]$ExcludedRanges = @(),

        [int[]]$DockerPublishedPorts = @(),

        [object[]]$DockerPortOwnership = @(),

        [string]$ExpectedControlPlaneContainer = "",

        [bool]$AllowExpectedContainerOwnership = $false,

        [int[]]$ReservedDevDeployPorts = @()
    )

    $excluded = [bool](Test-PortInExcludedRanges -Port $Port -Ranges $ExcludedRanges)
    $owners = @(
        $DockerPortOwnership |
            Where-Object { [int]$_['host_port'] -eq $Port } |
            ForEach-Object { [string]$_['container_name'] } |
            Select-Object -Unique
    )
    $dockerPublished = [bool]($owners.Count -gt 0 -or @($DockerPublishedPorts) -contains $Port)
    $ownedByExpectedCluster = [bool](
        -not [string]::IsNullOrWhiteSpace($ExpectedControlPlaneContainer) -and
        $owners -contains $ExpectedControlPlaneContainer
    )
    $knownDevDeployContainers = @("devdeploy-mgmt-control-plane", "devdeploy-workload-control-plane")
    $ownedByOtherDevDeployCluster = [bool](@($owners | Where-Object { $_ -in $knownDevDeployContainers -and $_ -ne $ExpectedControlPlaneContainer }).Count -gt 0)
    $ownedByUnrelatedContainer = [bool](@($owners | Where-Object { $_ -notin $knownDevDeployContainers }).Count -gt 0)
    $expectedOwnershipAccepted = [bool](
        $AllowExpectedContainerOwnership -and
        $ownedByExpectedCluster -and
        -not $ownedByOtherDevDeployCluster -and
        -not $ownedByUnrelatedContainer
    )
    $reservedCollision = [bool](@($ReservedDevDeployPorts) -contains $Port)
    $bindResult = Test-HostPortBindAvailable -Port $Port
    $bindAvailable = [bool]$bindResult["available"]
    $dockerOwnershipSafe = [bool](-not $dockerPublished -or $expectedOwnershipAccepted)
    $bindSafe = [bool]($bindAvailable -or $expectedOwnershipAccepted)
    $safe = [bool](-not $excluded -and $dockerOwnershipSafe -and -not $reservedCollision -and $bindSafe)

    return [ordered]@{
        port                  = $Port
        address               = "127.0.0.1"
        safe                  = $safe
        excluded_by_windows   = $excluded
        docker_published      = $dockerPublished
        docker_port_owner     = if ($owners.Count -eq 1) { [string]$owners[0] } elseif ($owners.Count -gt 1) { [string]($owners -join ",") } else { "" }
        docker_port_owners    = [string[]]@($owners)
        owned_by_expected_cluster       = $ownedByExpectedCluster
        owned_by_other_devdeploy_cluster = $ownedByOtherDevDeployCluster
        owned_by_unrelated_container    = $ownedByUnrelatedContainer
        collides_with_devdeploy_port = $reservedCollision
        bind_available        = $bindAvailable
        bind_error            = [string]$bindResult["error"]
    }
}

function Resolve-HttpsPortSelection {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PortKey,

        [Parameter(Mandatory = $true)]
        [string]$ClusterName,

        [Parameter(Mandatory = $true)]
        [string]$ControlPlaneContainer,

        [int[]]$CandidatePorts = @(),

        [object[]]$ExcludedRanges = @(),

        [int[]]$DockerPublishedPorts = @(),

        [object[]]$DockerPortOwnership = @(),

        [int[]]$ReservedDevDeployPorts = @(),

        [bool]$DockerAvailable,

        [bool]$DockerDaemonReachable,

        [bool]$ClusterExists
    )

    $uniqueCandidatePorts = [int[]]@($CandidatePorts | ForEach-Object { [int]$_ } | Select-Object -Unique)
    $selectedPort = [int]$DefaultPortPlan[$PortKey]
    $selectionReason = "default_safe"
    $candidateResults = New-Object System.Collections.Generic.List[object]
    $evaluatedPorts = New-Object System.Collections.Generic.List[int]
    $existingClusterPublishedHttps = $null
    $existingClusterConfiguredHttps = $null
    $selectedSafe = $false

    if ($ClusterExists) {
        $existingBindingState = Get-DockerContainerPortBindingState -ContainerName $ControlPlaneContainer -ContainerPort 443 -DockerAvailable $DockerAvailable -DockerDaemonReachable $DockerDaemonReachable
        $existingClusterConfiguredHttps = $existingBindingState["configured_host_port"]
        $existingClusterPublishedHttps = $existingBindingState["published_host_port"]
        if ($null -ne $existingClusterPublishedHttps) {
            $existingSafety = Test-HostPortSafety -Port ([int]$existingClusterPublishedHttps) -ExcludedRanges $ExcludedRanges -DockerPublishedPorts $DockerPublishedPorts -DockerPortOwnership $DockerPortOwnership -ExpectedControlPlaneContainer $ControlPlaneContainer -AllowExpectedContainerOwnership $true -ReservedDevDeployPorts $ReservedDevDeployPorts
            $existingSafety["existing_binding_consistent"] = [bool]$existingBindingState["publication_consistent"]
            $candidateResults.Add($existingSafety) | Out-Null
            $evaluatedPorts.Add([int]$existingClusterPublishedHttps) | Out-Null
            if ([bool]$existingSafety["safe"] -and [bool]$existingBindingState["publication_consistent"]) {
                $selectedPort = [int]$existingClusterPublishedHttps
                $selectionReason = "existing_cluster_binding"
                $selectedSafe = $true
            }
        }
    }

    if (-not $selectedSafe) {
        foreach ($candidate in @($uniqueCandidatePorts)) {
            if (@($evaluatedPorts) -contains [int]$candidate) {
                continue
            }
            $safety = Test-HostPortSafety -Port ([int]$candidate) -ExcludedRanges $ExcludedRanges -DockerPublishedPorts $DockerPublishedPorts -DockerPortOwnership $DockerPortOwnership -ExpectedControlPlaneContainer $ControlPlaneContainer -AllowExpectedContainerOwnership $false -ReservedDevDeployPorts $ReservedDevDeployPorts
            $candidateResults.Add($safety) | Out-Null
            $evaluatedPorts.Add([int]$candidate) | Out-Null
            if ([bool]$safety["safe"]) {
                $selectedPort = [int]$candidate
                $selectedSafe = $true
                if ($selectedPort -ne [int]$DefaultPortPlan[$PortKey]) {
                    $selectionReason = "deterministic_safe_fallback"
                }
                break
            }
        }
        if (-not $selectedSafe) {
            $selectionReason = "no_safe_candidate"
        }
    }

    $PortPlan[$PortKey] = [int]$selectedPort

    $selection = [ordered]@{
        default_port                     = [int]$DefaultPortPlan[$PortKey]
        selected_port                    = [int]$selectedPort
        selected_safe                    = $selectedSafe
        candidate_ports                  = [int[]]@($uniqueCandidatePorts)
        selection_reason                 = $selectionReason
        existing_cluster                 = $ClusterExists
        existing_cluster_configured_port = $existingClusterConfiguredHttps
        existing_cluster_published_port  = $existingClusterPublishedHttps
        windows_excluded_ranges_detected = @($ExcludedRanges)
        candidates                       = @($candidateResults | ForEach-Object { $_ })
    }

    $selectionStatus = if ($selectedSafe) { "ok" } else { "failed" }
    $selectionMessage = if ($selectedSafe) {
        "Selected {0} HTTPS host port {1}." -f $ClusterName, $selectedPort
    }
    else {
        "No safe HTTPS host port candidate is available for {0}. Free one candidate port before creating or recreating the cluster." -f $ClusterName
    }
    Add-Check -Id ("{0}_port_selection" -f $PortKey) -Label ("{0} HTTPS port selection" -f $ClusterName) -Status $selectionStatus -Message $selectionMessage -Details @{
        required        = $true
        default_port    = [int]$DefaultPortPlan[$PortKey]
        selected_port   = [int]$selectedPort
        selected_safe   = $selectedSafe
        selection_reason = $selectionReason
        candidate_ports = [int[]]@($uniqueCandidatePorts)
        cluster_name    = $ClusterName
    }

    return $selection
}

function Resolve-LauncherPortPlan {
    param(
        [bool]$DockerAvailable,

        [bool]$DockerDaemonReachable,

        [bool]$ManagementClusterExists,

        [bool]$WorkloadClusterExists
    )

    $excludedRanges = @(Get-WindowsExcludedTcpPortRanges)
    $dockerPortOwnership = @(Get-DockerPublishedPortOwnership -DockerAvailable $DockerAvailable -DockerDaemonReachable $DockerDaemonReachable)
    $dockerPublishedPorts = @($dockerPortOwnership | ForEach-Object { [int]$_['host_port'] } | Select-Object -Unique)
    $reservedPorts = New-Object System.Collections.Generic.List[int]
    foreach ($port in @($PortPlan["management_api"], $PortPlan["management_http"], $PortPlan["workload_api"], $PortPlan["workload_http"])) {
        $reservedPorts.Add([int]$port) | Out-Null
    }

    $managementSelection = Resolve-HttpsPortSelection -PortKey "management_https" -ClusterName "devdeploy-mgmt" -ControlPlaneContainer "devdeploy-mgmt-control-plane" -CandidatePorts ([int[]]$ManagementHttpsCandidatePorts) -ExcludedRanges $excludedRanges -DockerPublishedPorts $dockerPublishedPorts -DockerPortOwnership $dockerPortOwnership -ReservedDevDeployPorts ([int[]]@($reservedPorts)) -DockerAvailable $DockerAvailable -DockerDaemonReachable $DockerDaemonReachable -ClusterExists $ManagementClusterExists
    $reservedPorts.Add([int]$PortPlan["management_https"]) | Out-Null

    $workloadSelection = Resolve-HttpsPortSelection -PortKey "workload_https" -ClusterName "devdeploy-workload" -ControlPlaneContainer "devdeploy-workload-control-plane" -CandidatePorts ([int[]]$WorkloadHttpsCandidatePorts) -ExcludedRanges $excludedRanges -DockerPublishedPorts $dockerPublishedPorts -DockerPortOwnership $dockerPortOwnership -ReservedDevDeployPorts ([int[]]@($reservedPorts)) -DockerAvailable $DockerAvailable -DockerDaemonReachable $DockerDaemonReachable -ClusterExists $WorkloadClusterExists

    return [ordered]@{
        management_https = $managementSelection
        workload_https   = $workloadSelection
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

    $excludedRanges = @()
    if ($PortSelection.Contains("management_https")) {
        $excludedRanges = @($PortSelection["management_https"]["windows_excluded_ranges_detected"])
    }
    $dockerPublishedPorts = @(Get-DockerPublishedHostPorts -DockerAvailable $dockerAvailable -DockerDaemonReachable $dockerDaemonReachable)
    $safety = Test-HostPortSafety -Port $Port -ExcludedRanges $excludedRanges -DockerPublishedPorts $dockerPublishedPorts
    if ([bool]$safety["safe"]) {
        Add-Check -Id ("port_{0}" -f $Port) -Label ("Port {0}" -f $Port) -Status "ok" -Message ("Port {0} is available on 127.0.0.1." -f $Port) -Details @{
            port                      = $Port
            address                   = "127.0.0.1"
            required                  = $Required
            expected_cluster          = $ExpectedCluster
            existing_cluster_detected = $ExistingClusterDetected
            blocking                  = $false
            excluded_by_windows       = [bool]$safety["excluded_by_windows"]
            docker_published          = [bool]$safety["docker_published"]
            bind_available            = [bool]$safety["bind_available"]
        }
        return
    }

    $status = if ($AllowBusyAsOk) { "ok" } elseif ($Required) { "failed" } else { "warning" }
    $message = if ($AllowBusyAsOk) {
        "Port {0} is in use and {1} exists; treating this as expected for the cluster." -f $Port, $ExpectedCluster
    }
    elseif ([bool]$safety["excluded_by_windows"]) {
        "Port {0} is reserved by Windows excluded TCP port ranges. Use a safe fallback before creating DevDeploy local clusters." -f $Port
    }
    elseif ($Required) {
        "Port {0} is unavailable. Free this port before creating DevDeploy local clusters." -f $Port
    }
    else {
        "Port {0} is unavailable. This is not blocking for the current mode, but review it before later setup steps." -f $Port
    }

    Add-Check -Id ("port_{0}" -f $Port) -Label ("Port {0}" -f $Port) -Status $status -Message $message -Details @{
        port                      = $Port
        address                   = "127.0.0.1"
        required                  = $Required
        expected_cluster          = $ExpectedCluster
        existing_cluster_detected = $ExistingClusterDetected
        blocking                  = [bool]($Required -and -not $AllowBusyAsOk)
        busy_ok                   = $AllowBusyAsOk
        excluded_by_windows       = [bool]$safety["excluded_by_windows"]
        docker_published          = [bool]$safety["docker_published"]
        bind_available            = [bool]$safety["bind_available"]
        error                     = [string]$safety["bind_error"]
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

        [bool]$ManagementArgoCDBootstrapMode = $false,

        [bool]$ManagementArgoCDVerifyMode = $false,

        [bool]$WorkloadEndpointDiscoveryMode = $false,

        [bool]$WorkloadArgoCDRegistrationMode = $false,

        [bool]$WorkloadArgoCDVerificationMode = $false,

        [bool]$WorkloadDeployPermissionGrantMode = $false,

        [bool]$WorkloadDeployPermissionVerifyMode = $false,

        [bool]$GitOpsRepositoryConfigureMode = $false,

        [bool]$GitOpsRootApplicationBootstrapMode = $false,

        [bool]$GitOpsRootApplicationVerifyMode = $false
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
    elseif ($ManagementArgoCDVerifyMode -and $mgmtExists) {
        $status = "ok"
        $message = "devdeploy-mgmt exists. Argo CD verify mode performs read-only checks only in this management cluster."
    }
    elseif ($WorkloadEndpointDiscoveryMode -and $mgmtExists -and $workloadExists) {
        $status = "ok"
        $message = "Both DevDeploy clusters exist. Endpoint discovery may create only its deterministic temporary probe Pod in devdeploy-mgmt."
    }
    elseif ($WorkloadArgoCDRegistrationMode -and $mgmtExists -and $workloadExists) {
        $status = "ok"
        $message = "Both DevDeploy clusters exist. This explicit mode registers devdeploy-workload with management Argo CD without creating an Application."
    }
    elseif ($WorkloadArgoCDVerificationMode -and $mgmtExists -and $workloadExists) {
        $status = "ok"
        $message = "Both DevDeploy clusters exist. This mode verifies workload registration without mutating either cluster."
    }
    elseif ($WorkloadDeployPermissionGrantMode -and $mgmtExists -and $workloadExists) {
        $status = "ok"
        $message = "Both DevDeploy clusters exist. This explicit mode reconciles only devdeploy-apps and its namespaced deploy authorization boundary."
    }
    elseif ($WorkloadDeployPermissionVerifyMode -and $mgmtExists -and $workloadExists) {
        $status = "ok"
        $message = "Both DevDeploy clusters exist. This mode verifies devdeploy-apps permissions without mutating either cluster."
    }
    elseif ($GitOpsRepositoryConfigureMode -and ($mgmtExists -or $workloadExists)) {
        $status = "ok"
        $message = "Existing DevDeploy clusters were detected. Local GitOps repository configuration does not use, modify, or delete them."
    }
    elseif ($GitOpsRootApplicationBootstrapMode -and $mgmtExists -and $workloadExists) {
        $status = "ok"
        $message = "Both DevDeploy clusters exist. Root Application bootstrap may reconcile only argocd/devdeploy-workloads-root in devdeploy-mgmt."
    }
    elseif ($GitOpsRootApplicationVerifyMode -and $mgmtExists -and $workloadExists) {
        $status = "ok"
        $message = "Both DevDeploy clusters exist. Root Application verification reads only the Application and empty workload inventory."
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
        return (Invoke-KindRestartPolicyReconcile -ClusterName "devdeploy-mgmt" -ControlPlaneContainer "devdeploy-mgmt-control-plane" -DockerAvailable $dockerAvailable -DockerDaemonReachable $dockerDaemonReachable)
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
        return (Invoke-KindRestartPolicyReconcile -ClusterName "devdeploy-workload" -ControlPlaneContainer "devdeploy-workload-control-plane" -DockerAvailable $dockerAvailable -DockerDaemonReachable $dockerDaemonReachable)
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

function Test-ManagementClusterIntegrityRequired {
    return [bool](-not (
            $BuildManagementBackendImage -or
            $BuildManagementFrontendImage -or
            $ConfigureGitOpsRepository -or
            $PlanWorkloadRebootstrap -or
            $PlanWorkloadPortRecovery -or
            $PlanManagementPortRecovery -or
            $GenerateKindConfigs
        ))
}

function Test-WorkloadClusterIntegrityRequired {
    return [bool](-not (
            $CreateManagementCluster -or
            $BootstrapManagementIngress -or
            $BootstrapManagementPostgres -or
            $BuildManagementBackendImage -or
            $LoadManagementBackendImage -or
            $EnsureManagementBackendSecret -or
            $VerifyManagementBackendSecret -or
            $BootstrapManagementBackend -or
            $VerifyManagementBackend -or
            $InitializeManagementBackendDatabase -or
            $BuildManagementFrontendImage -or
            $LoadManagementFrontendImage -or
            $BootstrapManagementFrontend -or
            $VerifyManagementFrontend -or
            $BootstrapManagementArgoCD -or
            $VerifyManagementArgoCD -or
            $ConfigureGitOpsRepository -or
            $PlanWorkloadRebootstrap -or
            $PlanWorkloadPortRecovery -or
            $PlanManagementPortRecovery -or
            $GenerateKindConfigs
        ))
}

function Get-KindIntegrityRecommendedAction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClusterName,

        [Parameter(Mandatory = $true)]
        [string]$IntegrityStatus
    )

    $isWorkload = $ClusterName -eq "devdeploy-workload"
    switch ($IntegrityStatus) {
        "cluster_missing" {
            if ($isWorkload) {
                return "Recreate only devdeploy-workload through its explicit launcher mode, then rebootstrap workload cluster access. Do not recreate devdeploy-mgmt."
            }
            return "Management recovery requires caution because devdeploy-mgmt hosts platform data. Verify backups or accept local data loss before any manual recreation."
        }
        "container_missing" {
            if ($isWorkload) {
                return "Recreate only devdeploy-workload through its explicit launcher mode, then rebootstrap workload cluster access. Do not recreate devdeploy-mgmt."
            }
            return "Verify Docker Desktop state and management backups. Do not recreate devdeploy-mgmt unless non-destructive recovery fails and data-loss risk is accepted."
        }
        "container_stopped" {
            if ($isWorkload) {
                return "Try docker start devdeploy-workload-control-plane, rerun preflight, then restart Docker Desktop if needed. Recreate only devdeploy-workload if it remains unusable."
            }
            return "Try docker start devdeploy-mgmt-control-plane and rerun preflight. Restart Docker Desktop if needed; do not recreate management without protecting platform data."
        }
        "workload_cluster_recreation_required" {
            return "Run -PlanWorkloadPortRecovery, then recreate only devdeploy-workload after explicit user confirmation. Do not recreate devdeploy-mgmt."
        }
        "management_cluster_recreation_required" {
            return "Run -PlanManagementPortRecovery. Verify the PostgreSQL backup before any future management recreation; no automatic management recreation is available in this phase."
        }
        { $_ -in @("api_port_unpublished", "api_port_mismatch", "kubeconfig_unreachable") } {
            if ($isWorkload) {
                return "Run wsl --shutdown, fully quit and restart Docker Desktop, then rerun preflight. If the issue remains, recreate only devdeploy-workload and rebootstrap workload cluster access."
            }
            return "Run wsl --shutdown, fully quit and restart Docker Desktop, then rerun preflight. Do not recreate devdeploy-mgmt without first protecting or accepting loss of local platform data."
        }
        default {
            return "Review the sanitized launcher log and rerun preflight. No automatic recovery was performed."
        }
    }
}

function New-ClusterRecoveryPlan {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Cluster,

        [Parameter(Mandatory = $true)]
        [ValidateSet("management", "workload")]
        [string]$Role
    )

    $clusterName = [string]$Cluster["name"]
    $clusterStatus = [string]$Cluster["status"]
    $integrityStatus = [string]$Cluster["integrity_status"]
    $healthy = $clusterStatus -eq "ready" -and $integrityStatus -eq "ok"
    if ($healthy) {
        return [ordered]@{
            required                     = $false
            affected_cluster             = $clusterName
            severity                     = "none"
            summary                      = ("{0} is healthy; no recovery guidance is required." -f $clusterName)
            impact                       = [string[]]@()
            recommended_steps             = [string[]]@()
            destructive_steps_required    = $false
            automatic_recovery_performed  = $false
            checked_at                    = [string](Get-Timestamp)
        }
    }

    if ($Role -eq "workload") {
        $impact = [string[]]@(
            "Runtime status and untracked resource discovery are unavailable or unreliable.",
            "Deploy and reconcile GitOps commits may still be created, but runtime convergence cannot be verified.",
            "If the workload cluster is recreated, Kubernetes runtime resources in that cluster may be lost; DevDeploy records and GitOps manifests remain."
        )
        $steps = switch ($integrityStatus) {
            { $_ -in @("api_port_unpublished", "api_port_mismatch", "kubeconfig_unreachable", "workload_cluster_recreation_required") } {
                [string[]]@(
                    "Run wsl --shutdown.",
                    "Fully quit and restart Docker Desktop.",
                    "Rerun launcher preflight.",
                    "If the issue remains, review -PlanWorkloadPortRecovery and recreate only devdeploy-workload after explicit confirmation.",
                    "Rebootstrap workload cluster access from management and Argo CD.",
                    "Use Recover or Redeploy for managed deployments if runtime resources were lost."
                )
                break
            }
            { $_ -in @("cluster_missing", "container_missing") } {
                [string[]]@(
                    "Recreate only devdeploy-workload through its explicit launcher mode.",
                    "Rebootstrap workload cluster access from management and Argo CD.",
                    "Do not recreate devdeploy-mgmt unless management is also unhealthy.",
                    "Use Recover or Redeploy for managed deployments if runtime resources were lost."
                )
                break
            }
            "container_stopped" {
                [string[]]@(
                    "Try docker start devdeploy-workload-control-plane.",
                    "Rerun launcher preflight.",
                    "If the API port remains unavailable, fully restart Docker Desktop.",
                    "If the issue remains, recreate only devdeploy-workload through its explicit launcher mode.",
                    "Rebootstrap workload cluster access from management and Argo CD."
                )
                break
            }
            default {
                [string[]]@(
                    "Review the sanitized launcher log.",
                    "Rerun launcher preflight after Docker Desktop is healthy.",
                    "Do not recreate devdeploy-mgmt for a workload-only failure."
                )
            }
        }
        return [ordered]@{
            required                     = $true
            affected_cluster             = $clusterName
            severity                     = "blocking_runtime_features"
            summary                      = "Workload cluster API is not reachable or its integrity could not be confirmed."
            impact                       = [string[]]@($impact)
            recommended_steps             = [string[]]@($steps)
            destructive_steps_required    = $false
            automatic_recovery_performed  = $false
            checked_at                    = [string](Get-Timestamp)
        }
    }

    $managementSteps = [string[]]@(
        "Run launcher preflight and review the sanitized integrity result.",
        "Run wsl --shutdown.",
        "Fully quit and restart Docker Desktop.",
        "Rerun launcher preflight.",
        "Do not recreate devdeploy-mgmt unless platform data is backed up or local data loss is accepted."
    )
    if ($integrityStatus -eq "container_stopped") {
        $managementSteps = [string[]]@(
            "Try docker start devdeploy-mgmt-control-plane.",
            "Rerun launcher preflight.",
            "If needed, fully restart Docker Desktop and rerun preflight.",
            "Do not recreate devdeploy-mgmt unless platform data is backed up or local data loss is accepted."
        )
    }
    return [ordered]@{
        required                     = $true
        affected_cluster             = $clusterName
        severity                     = "blocking_platform"
        summary                      = if ($integrityStatus -eq "management_cluster_recreation_required") { "Management cluster host port recovery may require future explicit recreation after backup verification." } else { "Management cluster health is degraded or unknown. Platform services may be unavailable." }
        impact                       = [string[]]@(
            "DevDeploy backend, frontend, PostgreSQL, and Argo CD may be unavailable.",
            "Recreating the management cluster may remove local platform data, including the platform database."
        )
        recommended_steps             = [string[]]@($managementSteps)
        destructive_steps_required    = $false
        automatic_recovery_performed  = $false
        checked_at                    = [string](Get-Timestamp)
    }
}

function New-WorkloadRebootstrapPlan {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ManagementCluster,

        [Parameter(Mandatory = $true)]
        [object]$WorkloadCluster
    )

    $managementStatus = [string]$ManagementCluster["status"]
    $managementIntegrity = [string]$ManagementCluster["integrity_status"]
    $workloadStatus = [string]$WorkloadCluster["status"]
    $workloadIntegrity = [string]$WorkloadCluster["integrity_status"]
    $managementHealthy = [bool]($managementStatus -eq "ready" -and $managementIntegrity -eq "ok")
    $diagnosis = "Workload cluster status is $workloadStatus with integrity status $workloadIntegrity."
    if ($workloadStatus -eq "ready" -and $workloadIntegrity -eq "ok") {
        $diagnosis = "devdeploy-workload is currently ready. This plan is available for review but rebootstrap is not indicated by current diagnostics."
    }

    $managementWarning = ""
    if (-not $managementHealthy) {
        $managementWarning = "devdeploy-mgmt is not healthy. Workload-only rebootstrap may not be sufficient; restore management access before relying on platform or Argo CD verification."
    }

    return [ordered]@{
        available                       = $true
        mode                            = "plan_only"
        affected_cluster                = "devdeploy-workload"
        management_preserved            = $true
        platform_database_preserved     = $true
        gitops_repository_preserved     = $true
        destructive_commands_executed   = $false
        kubernetes_mutation_executed    = $false
        gitops_mutation_executed        = $false
        requires_user_confirmation      = $true
        diagnosis                       = $diagnosis
        diagnosis_reason                = $workloadIntegrity
        workload_status                 = $workloadStatus
        selected_workload_https_port    = [int]$PortPlan["workload_https"]
        workload_https_selection_reason = [string]$PortSelection["workload_https"]["selection_reason"]
        management_status               = $managementStatus
        management_healthy              = $managementHealthy
        management_warning              = $managementWarning
        impact                          = [string[]]@(
            "devdeploy-mgmt is not touched by this plan.",
            "PostgreSQL data and managed DeploymentRecords in devdeploy-mgmt are preserved.",
            "Argo CD in devdeploy-mgmt and the GitOps repository are preserved.",
            "Kubernetes runtime resources in devdeploy-workload may be lost if the user confirms manual recreation.",
            "Managed apps can use Recover, Redeploy, or Reconcile after workload access is healthy."
        )
        non_destructive_steps            = [string[]]@(
            "Run wsl --shutdown.",
            "Fully quit Docker Desktop.",
            "Restart Docker Desktop and wait for the engine to become ready.",
            "Rerun .\scripts\launcher\devdeploy-launcher.ps1 and review workload integrity."
        )
        planned_rebootstrap_steps        = [string[]]@(
            "USER CONFIRMATION REQUIRED: kind delete cluster --name devdeploy-workload",
            "Run .\scripts\launcher\devdeploy-launcher.ps1 -GenerateKindConfigs to write a workload kind config with the selected safe HTTPS port.",
            "Run .\scripts\launcher\devdeploy-launcher.ps1 -CreateWorkloadCluster.",
            "Run .\scripts\launcher\devdeploy-launcher.ps1 -GrantWorkloadDeployPermissions to recreate devdeploy-apps and namespace-scoped deploy access.",
            "Run .\scripts\launcher\devdeploy-launcher.ps1 -DiscoverWorkloadClusterEndpoint.",
            "Run .\scripts\launcher\devdeploy-launcher.ps1 -RegisterWorkloadClusterWithArgoCD.",
            "Run .\scripts\launcher\devdeploy-launcher.ps1 -BootstrapGitOpsRootApplication.",
            "Run .\scripts\launcher\devdeploy-launcher.ps1 -BootstrapWorkloadObservability to restore workload telemetry transport and regenerate the host-local narrow observability kubeconfig."
        )
        post_rebootstrap_validation      = [string[]]@(
            "Verify docker port devdeploy-workload-control-plane 6443/tcp reports 127.0.0.1:58081.",
            ("Verify docker port devdeploy-workload-control-plane 443/tcp reports 127.0.0.1:{0}." -f [int]$PortPlan["workload_https"]),
            "Verify kubectl --context kind-devdeploy-workload get nodes reports a Ready node.",
            "Run .\scripts\launcher\devdeploy-launcher.ps1 -VerifyWorkloadClusterRegistration.",
            "Run .\scripts\launcher\devdeploy-launcher.ps1 -VerifyWorkloadDeployPermissions.",
            "Run .\scripts\launcher\devdeploy-launcher.ps1 -VerifyGitOpsRootApplication.",
            "Run .\scripts\launcher\devdeploy-launcher.ps1 -VerifyWorkloadObservability.",
            "Wait for Argo CD workloads to converge, then use Recover, Redeploy, or Reconcile where runtime resources remain missing."
        )
        checked_at                       = [string](Get-Timestamp)
    }
}

function New-ManagementPortRecoveryPlan {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ManagementCluster
    )

    $managementStatus = [string]$ManagementCluster["status"]
    $managementIntegrity = [string]$ManagementCluster["integrity_status"]
    $recreationRequired = [bool]($ManagementCluster["recreation_required"] -eq $true -or $ManagementCluster["management_cluster_recreation_required"] -eq $true)
    $diagnosis = "Management cluster status is $managementStatus with integrity status $managementIntegrity."
    if ($recreationRequired) {
        $diagnosis = "devdeploy-mgmt may be internally Ready, but host access is unhealthy. Management recreation is required after the verified PostgreSQL backup prerequisite is confirmed."
    }
    elseif ($managementStatus -eq "ready" -and $managementIntegrity -eq "ok") {
        $diagnosis = "devdeploy-mgmt is currently ready. This plan is available for review but management recreation is not indicated by current diagnostics."
    }

    return [ordered]@{
        available                       = $true
        mode                            = "plan_only"
        affected_cluster                = "devdeploy-mgmt"
        management_preserved            = $true
        workload_cluster_preserved      = $true
        destructive_commands_executed   = $false
        docker_update_executed          = $false
        kubernetes_mutation_executed    = $false
        gitops_mutation_executed        = $false
        automatic_recreation_available  = $false
        requires_user_confirmation      = $true
        backup_verification_required    = $true
        selected_management_https_port  = [int]$PortPlan["management_https"]
        management_https_selection_reason = [string]$PortSelection["management_https"]["selection_reason"]
        diagnosis                       = $diagnosis
        diagnosis_reason                = $managementIntegrity
        management_status               = $managementStatus
        internal_cluster_ready          = $ManagementCluster["internal_cluster_ready"]
        host_access_healthy             = [bool]($ManagementCluster["host_access_healthy"] -eq $true)
        recreation_required             = $recreationRequired
        recreation_reason               = [string]$ManagementCluster["recreation_reason"]
        impact                          = [string[]]@(
            "devdeploy-mgmt hosts PostgreSQL, backend, frontend, and Argo CD.",
            "Future management recreation can remove local platform data unless a verified backup is restored.",
            "A verified PostgreSQL backup must be confirmed before any destructive management recovery is attempted.",
            "This plan does not delete, recreate, start, stop, or update Docker containers."
        )
        non_destructive_steps            = [string[]]@(
            "Review launcher-status.json for management_cluster_recreation_required and selected_management_https_port.",
            "Verify the existing PostgreSQL backup outside the cluster.",
            "Rerun .\scripts\launcher\devdeploy-launcher.ps1 -GenerateKindConfigs to preview config with the selected management HTTPS port.",
            "Do not recreate devdeploy-mgmt until the backup is verified and explicit user confirmation is given in a future recovery phase."
        )
        planned_future_recovery_steps    = [string[]]@(
            "FUTURE USER CONFIRMATION REQUIRED: delete only devdeploy-mgmt after backup verification.",
            "Recreate devdeploy-mgmt from generated kind config using the selected safe management HTTPS port.",
            "Restore PostgreSQL data from the verified backup.",
            "Reinstall platform components and reconnect Argo CD to devdeploy-workload.",
            "Verify backend, frontend, PostgreSQL, Argo CD, Root Application, and workload observability."
        )
        post_recovery_validation          = [string[]]@(
            ("Verify docker port devdeploy-mgmt-control-plane 443/tcp reports 127.0.0.1:{0}." -f [int]$PortPlan["management_https"]),
            "Verify kubectl --context kind-devdeploy-mgmt get nodes reports a Ready node.",
            "Verify PostgreSQL restore before allowing product operations.",
            "Run read-only platform verification modes after the future recovery is complete."
        )
        checked_at                       = [string](Get-Timestamp)
    }
}

function Write-WorkloadRebootstrapPlanConsole {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Plan
    )

    Write-Host "PLAN ONLY - no commands were executed."
    Write-Host ("Diagnosis: {0}" -f [string]$Plan["diagnosis"])
    if (-not [string]::IsNullOrWhiteSpace([string]$Plan["management_warning"])) {
        Write-Host ("Management warning: {0}" -f [string]$Plan["management_warning"])
    }

    foreach ($section in @(
            @{ label = "Impact"; field = "impact" },
            @{ label = "Non-destructive first steps"; field = "non_destructive_steps" },
            @{ label = "Planned rebootstrap steps"; field = "planned_rebootstrap_steps" },
            @{ label = "Post-rebootstrap validation"; field = "post_rebootstrap_validation" }
        )) {
        Write-Host ("{0}:" -f [string]$section.label)
        $fieldName = [string]$section.field
        $stepNumber = 1
        foreach ($item in @($Plan[$fieldName])) {
            Write-Host ("  {0}. {1}" -f $stepNumber, [string]$item)
            $stepNumber++
        }
    }

    Write-Host "Management preservation: devdeploy-mgmt, PostgreSQL, Argo CD, and GitOps source are not changed by this plan."
    Write-Host "Runtime impact: a user-confirmed workload cluster recreation may remove runtime resources in devdeploy-workload."
}

function Write-ManagementPortRecoveryPlanConsole {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Plan
    )

    Write-Host "PLAN ONLY - no commands were executed."
    Write-Host ("Diagnosis: {0}" -f [string]$Plan["diagnosis"])
    Write-Host ("Selected management HTTPS port: {0}" -f [string]$Plan["selected_management_https_port"])
    Write-Host "Backup requirement: verify the PostgreSQL backup before any future management recreation."

    foreach ($section in @(
            @{ label = "Impact"; field = "impact" },
            @{ label = "Non-destructive first steps"; field = "non_destructive_steps" },
            @{ label = "Future recovery outline"; field = "planned_future_recovery_steps" },
            @{ label = "Post-recovery validation"; field = "post_recovery_validation" }
        )) {
        Write-Host ("{0}:" -f [string]$section.label)
        $fieldName = [string]$section.field
        $stepNumber = 1
        foreach ($item in @($Plan[$fieldName])) {
            Write-Host ("  {0}. {1}" -f $stepNumber, [string]$item)
            $stepNumber++
        }
    }

    Write-Host "No automatic management delete or recreate action exists in this phase."
}

function Get-KindClusterIntegrity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClusterName,

        [Parameter(Mandatory = $true)]
        [string]$Context,

        [Parameter(Mandatory = $true)]
        [string]$ControlPlaneContainer,

        [Parameter(Mandatory = $true)]
        [int]$ExpectedApiPort,

        [bool]$ClusterExists,

        [bool]$KubectlAvailable,

        [bool]$Required
    )

    $recommendedAction = Get-KindIntegrityRecommendedAction -ClusterName $ClusterName -IntegrityStatus "api_port_unpublished"
    $result = [ordered]@{
        cluster_name            = $ClusterName
        context                 = $Context
        control_plane_container = $ControlPlaneContainer
        container_running       = $null
        api_port_published      = $null
        expected_api_port       = $ExpectedApiPort
        actual_api_port         = $null
        restart_policy_name     = ""
        restart_policy_maximum_retry_count = $null
        restart_policy_healthy  = $null
        restart_policy_reconciliation_needed = $null
        expected_https_port     = [int]$PortPlan["management_https"]
        actual_https_port       = $null
        management_cluster_recreation_required = $false
        management_cluster_recreation_reason   = ""
        kubeconfig_reachable    = $null
        integrity_status        = "unknown"
        message                 = "kind cluster integrity could not be determined safely."
        recommended_action      = "Review the sanitized launcher log and rerun preflight."
        checked_at              = [string](Get-Timestamp)
    }

    if (-not $ClusterExists) {
        $result["integrity_status"] = "cluster_missing"
        $result["message"] = "kind cluster $ClusterName does not exist yet."
        $result["recommended_action"] = Get-KindIntegrityRecommendedAction -ClusterName $ClusterName -IntegrityStatus "cluster_missing"
        Add-Check -Id ("kind_integrity_{0}" -f $ClusterName) -Label ("{0} kind integrity" -f $ClusterName) -Status "warning" -Message ([string]$result["message"]) -Details @{
            required                = $false
            cluster_name            = $ClusterName
            integrity_status        = "cluster_missing"
            control_plane_container = $ControlPlaneContainer
            expected_api_port       = $ExpectedApiPort
        }
        return $result
    }

    if (-not $dockerAvailable) {
        $result["integrity_status"] = "docker_unavailable"
        $result["message"] = "Docker CLI is unavailable, so the kind control-plane container and API port mapping cannot be verified."
        $result["recommended_action"] = "Install or restore Docker CLI access, then rerun preflight."
        Add-Check -Id ("kind_integrity_{0}" -f $ClusterName) -Label ("{0} kind integrity" -f $ClusterName) -Status $(if ($Required) { "failed" } else { "warning" }) -Message ([string]$result["message"]) -Details @{
            required                = $Required
            cluster_name            = $ClusterName
            integrity_status        = "docker_unavailable"
            control_plane_container = $ControlPlaneContainer
            expected_api_port       = $ExpectedApiPort
        }
        return $result
    }

    $dockerInfo = Invoke-ReadOnlyCommand -FileName "docker" -Arguments @("info", "--format", "{{json .ServerVersion}}") -TimeoutSeconds 10
    if ($dockerInfo.exit_code -ne 0 -or $dockerInfo.timed_out) {
        $result["integrity_status"] = "docker_unavailable"
        $result["message"] = "Docker daemon is unavailable, so kind cluster integrity cannot be verified."
        $result["recommended_action"] = "Start or restart Docker Desktop, then rerun preflight."
        Add-Check -Id ("kind_integrity_{0}" -f $ClusterName) -Label ("{0} kind integrity" -f $ClusterName) -Status $(if ($Required) { "failed" } else { "warning" }) -Message ([string]$result["message"]) -Details @{
            required                = $Required
            cluster_name            = $ClusterName
            integrity_status        = "docker_unavailable"
            control_plane_container = $ControlPlaneContainer
            expected_api_port       = $ExpectedApiPort
        }
        return $result
    }

    $containerResult = Invoke-ReadOnlyCommand -FileName "docker" -Arguments @("ps", "-a", "--filter", ("name=^/{0}$" -f $ControlPlaneContainer), "--format", "{{.Names}}") -TimeoutSeconds 10
    $containerPresent = [bool]($containerResult.exit_code -eq 0 -and -not $containerResult.timed_out -and (([string]$containerResult.stdout).Trim() -eq $ControlPlaneContainer))
    if (-not $containerPresent) {
        $result["container_running"] = $false
        $result["integrity_status"] = "container_missing"
        $result["message"] = "The expected kind control-plane container $ControlPlaneContainer was not found."
        $result["recommended_action"] = Get-KindIntegrityRecommendedAction -ClusterName $ClusterName -IntegrityStatus "container_missing"
        Add-Check -Id ("kind_integrity_{0}" -f $ClusterName) -Label ("{0} kind integrity" -f $ClusterName) -Status $(if ($Required) { "failed" } else { "warning" }) -Message ([string]$result["message"]) -Details @{
            required                = $Required
            cluster_name            = $ClusterName
            integrity_status        = "container_missing"
            control_plane_container = $ControlPlaneContainer
            expected_api_port       = $ExpectedApiPort
        }
        return $result
    }

    $restartPolicy = Get-DockerContainerRestartPolicy -ClusterName $ClusterName -ControlPlaneContainer $ControlPlaneContainer -DockerAvailable $dockerAvailable -DockerDaemonReachable $dockerDaemonReachable
    $result["restart_policy_name"] = [string]$restartPolicy["policy_name"]
    $result["restart_policy_maximum_retry_count"] = $restartPolicy["maximum_retry_count"]
    $result["restart_policy_healthy"] = if ([bool]$restartPolicy["known"]) { [bool]$restartPolicy["healthy"] } else { $null }
    $result["restart_policy_reconciliation_needed"] = $restartPolicy["reconciliation_needed"]
    Add-KindRestartPolicyCheck -ClusterName $ClusterName -ControlPlaneContainer $ControlPlaneContainer -RestartPolicy $restartPolicy

    $runningResult = Invoke-ReadOnlyCommand -FileName "docker" -Arguments @("inspect", "--format={{.State.Running}}", $ControlPlaneContainer) -TimeoutSeconds 10
    $containerRunning = [bool]($runningResult.exit_code -eq 0 -and -not $runningResult.timed_out -and (([string]$runningResult.stdout).Trim().ToLowerInvariant() -eq "true"))
    $result["container_running"] = $containerRunning
    if (-not $containerRunning) {
        $result["api_port_published"] = $false
        $result["integrity_status"] = "container_stopped"
        $result["message"] = "The kind control-plane container $ControlPlaneContainer exists but is not running."
        $result["recommended_action"] = Get-KindIntegrityRecommendedAction -ClusterName $ClusterName -IntegrityStatus "container_stopped"
        Add-Check -Id ("kind_integrity_{0}" -f $ClusterName) -Label ("{0} kind integrity" -f $ClusterName) -Status $(if ($Required) { "failed" } else { "warning" }) -Message ([string]$result["message"]) -Details @{
            required                = $Required
            cluster_name            = $ClusterName
            integrity_status        = "container_stopped"
            control_plane_container = $ControlPlaneContainer
            container_running       = $false
            expected_api_port       = $ExpectedApiPort
            restart_policy_name     = [string]$result["restart_policy_name"]
            restart_policy_reconciliation_needed = $result["restart_policy_reconciliation_needed"]
        }
        return $result
    }

    $portResult = Invoke-ReadOnlyCommand -FileName "docker" -Arguments @("port", $ControlPlaneContainer, "6443/tcp") -TimeoutSeconds 10 -PreserveStandardOutput $true
    $publishedPorts = @()
    if ($portResult.exit_code -eq 0 -and -not $portResult.timed_out -and -not [string]::IsNullOrWhiteSpace($portResult.stdout)) {
        $publishedPorts = @(
            ([string]$portResult.stdout) -split "\r?\n" |
                ForEach-Object {
                    if ($_ -match ':(\d+)\s*$') { [int]$Matches[1] }
                } |
                Where-Object { $null -ne $_ } |
                Select-Object -Unique
        )
    }
    $result["api_port_published"] = [bool]($publishedPorts.Count -gt 0)
    if ($publishedPorts.Count -gt 0) {
        $result["actual_api_port"] = [int]$publishedPorts[0]
    }
    if ($publishedPorts.Count -eq 0) {
        $result["integrity_status"] = "api_port_unpublished"
        $result["message"] = "The kind control-plane container is running, but 6443/tcp is not published to the host. Docker Desktop/WSL port mapping may be corrupted."
        $result["recommended_action"] = $recommendedAction
        Add-Check -Id ("kind_integrity_{0}" -f $ClusterName) -Label ("{0} kind API port integrity" -f $ClusterName) -Status $(if ($Required) { "failed" } else { "warning" }) -Message ([string]$result["message"]) -Details @{
            required                = $Required
            cluster_name            = $ClusterName
            integrity_status        = "api_port_unpublished"
            control_plane_container = $ControlPlaneContainer
            container_running       = $true
            api_port_published      = $false
            expected_api_port       = $ExpectedApiPort
            actual_api_port         = $null
            recommended_action      = $recommendedAction
        }
        return $result
    }

    if ($publishedPorts -notcontains $ExpectedApiPort) {
        $result["integrity_status"] = "api_port_mismatch"
        $result["message"] = "The kind control-plane API is published on an unexpected host port."
        $result["recommended_action"] = $recommendedAction
        Add-Check -Id ("kind_integrity_{0}" -f $ClusterName) -Label ("{0} kind API port integrity" -f $ClusterName) -Status $(if ($Required) { "failed" } else { "warning" }) -Message ([string]$result["message"]) -Details @{
            required                = $Required
            cluster_name            = $ClusterName
            integrity_status        = "api_port_mismatch"
            control_plane_container = $ControlPlaneContainer
            container_running       = $true
            api_port_published      = $true
            expected_api_port       = $ExpectedApiPort
            actual_api_port         = $result["actual_api_port"]
            recommended_action      = $recommendedAction
        }
        return $result
    }

    if (-not $KubectlAvailable) {
        $result["integrity_status"] = "kubeconfig_unreachable"
        $result["message"] = "The expected kind API port is published, but kubectl is unavailable for kubeconfig and API verification."
        $result["recommended_action"] = Get-KindIntegrityRecommendedAction -ClusterName $ClusterName -IntegrityStatus "kubeconfig_unreachable"
        Add-Check -Id ("kind_integrity_{0}" -f $ClusterName) -Label ("{0} kubeconfig integrity" -f $ClusterName) -Status $(if ($Required) { "failed" } else { "warning" }) -Message ([string]$result["message"]) -Details @{
            required                = $Required
            cluster_name            = $ClusterName
            integrity_status        = "kubeconfig_unreachable"
            control_plane_container = $ControlPlaneContainer
            container_running       = $true
            api_port_published      = $true
            expected_api_port       = $ExpectedApiPort
            actual_api_port         = $result["actual_api_port"]
        }
        return $result
    }

    $serverResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", $Context, "config", "view", "--minify", "--output=jsonpath={.clusters[0].cluster.server}") -TimeoutSeconds 10 -PreserveStandardOutput $true
    $kubeconfigPort = $null
    if ($serverResult.exit_code -eq 0 -and -not $serverResult.timed_out -and -not [string]::IsNullOrWhiteSpace($serverResult.stdout)) {
        try {
            $serverUri = [Uri](([string]$serverResult.stdout).Trim())
            $kubeconfigPort = [int]$serverUri.Port
        }
        catch {
            $kubeconfigPort = $null
        }
    }
    if ($null -eq $kubeconfigPort) {
        $result["kubeconfig_reachable"] = $false
        $result["integrity_status"] = "kubeconfig_unreachable"
        $result["message"] = "The kubeconfig context could not be read safely for the expected kind cluster."
        $result["recommended_action"] = Get-KindIntegrityRecommendedAction -ClusterName $ClusterName -IntegrityStatus "kubeconfig_unreachable"
        Add-Check -Id ("kind_integrity_{0}" -f $ClusterName) -Label ("{0} kubeconfig integrity" -f $ClusterName) -Status $(if ($Required) { "failed" } else { "warning" }) -Message ([string]$result["message"]) -Details @{
            required                = $Required
            cluster_name            = $ClusterName
            integrity_status        = "kubeconfig_unreachable"
            context                 = $Context
            expected_api_port       = $ExpectedApiPort
            actual_api_port         = $result["actual_api_port"]
        }
        return $result
    }

    if ($kubeconfigPort -ne $ExpectedApiPort) {
        $result["kubeconfig_reachable"] = $false
        $result["integrity_status"] = "api_port_mismatch"
        $result["message"] = "The kubeconfig server port does not match the expected published kind API port."
        $result["recommended_action"] = $recommendedAction
        Add-Check -Id ("kind_integrity_{0}" -f $ClusterName) -Label ("{0} kubeconfig API port integrity" -f $ClusterName) -Status $(if ($Required) { "failed" } else { "warning" }) -Message ([string]$result["message"]) -Details @{
            required                = $Required
            cluster_name            = $ClusterName
            integrity_status        = "api_port_mismatch"
            context                 = $Context
            expected_api_port       = $ExpectedApiPort
            actual_api_port         = $result["actual_api_port"]
            kubeconfig_api_port     = $kubeconfigPort
            recommended_action      = $recommendedAction
        }
        return $result
    }

    $readyResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", $Context, "get", "--raw=/readyz") -TimeoutSeconds 15
    if ($readyResult.exit_code -ne 0 -or $readyResult.timed_out) {
        $result["kubeconfig_reachable"] = $false
        $result["integrity_status"] = "kubeconfig_unreachable"
        $result["message"] = "The kind API port and kubeconfig match, but the Kubernetes API is not reachable."
        $result["recommended_action"] = $recommendedAction
        Add-Check -Id ("kind_integrity_{0}" -f $ClusterName) -Label ("{0} Kubernetes API integrity" -f $ClusterName) -Status $(if ($Required) { "failed" } else { "warning" }) -Message ([string]$result["message"]) -Details @{
            required                = $Required
            cluster_name            = $ClusterName
            integrity_status        = "kubeconfig_unreachable"
            context                 = $Context
            control_plane_container = $ControlPlaneContainer
            container_running       = $true
            api_port_published      = $true
            expected_api_port       = $ExpectedApiPort
            actual_api_port         = $result["actual_api_port"]
            recommended_action      = $recommendedAction
        }
        return $result
    }

    $result["kubeconfig_reachable"] = $true
    $result["integrity_status"] = "ok"
    $result["message"] = "The kind control-plane container, published API port, kubeconfig context, and Kubernetes readiness endpoint are consistent."
    $result["recommended_action"] = ""
    Add-Check -Id ("kind_integrity_{0}" -f $ClusterName) -Label ("{0} kind integrity" -f $ClusterName) -Status "ok" -Message ([string]$result["message"]) -Details @{
        required                = $Required
        cluster_name            = $ClusterName
        integrity_status        = "ok"
        context                 = $Context
        control_plane_container = $ControlPlaneContainer
        container_running       = $true
        api_port_published      = $true
        expected_api_port       = $ExpectedApiPort
        actual_api_port         = $result["actual_api_port"]
        kubeconfig_reachable    = $true
    }
    return $result
}

function Set-KindIntegrityFields {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ClusterStatus,

        [Parameter(Mandatory = $true)]
        [object]$Integrity
    )

    foreach ($field in @("control_plane_container", "container_running", "api_port_published", "expected_api_port", "actual_api_port", "kubeconfig_reachable", "integrity_status", "recommended_action")) {
        $ClusterStatus[$field] = $Integrity[$field]
    }
    foreach ($field in @("restart_policy_name", "restart_policy_maximum_retry_count", "restart_policy_healthy", "restart_policy_reconciliation_needed")) {
        $ClusterStatus[$field] = $Integrity[$field]
    }
}

function Get-ClusterHttpsPortRecreationRequirement {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClusterName,

        [Parameter(Mandatory = $true)]
        [string]$ControlPlaneContainer,

        [Parameter(Mandatory = $true)]
        [string]$PortKey,

        [Parameter(Mandatory = $true)]
        [string]$RecreationReason,

        [Parameter(Mandatory = $true)]
        [object]$Integrity,

        [bool]$DockerAvailable,

        [bool]$DockerDaemonReachable
    )

    $requiredHostPorts = if ($ClusterName -eq "devdeploy-mgmt") {
        [ordered]@{ "6443" = [int]$PortPlan["management_api"]; "80" = [int]$PortPlan["management_http"]; "443" = $null }
    }
    else {
        [ordered]@{ "6443" = [int]$PortPlan["workload_api"]; "80" = [int]$PortPlan["workload_http"]; "443" = $null }
    }
    $bindingStates = New-Object System.Collections.Generic.List[object]
    foreach ($containerPort in @(6443, 80, 443)) {
        $bindingState = Get-DockerContainerPortBindingState -ContainerName $ControlPlaneContainer -ContainerPort $containerPort -DockerAvailable $DockerAvailable -DockerDaemonReachable $DockerDaemonReachable
        if ($containerPort -eq 443 -and $null -ne $bindingState["configured_host_port"]) {
            $requiredHostPorts["443"] = [int]$bindingState["configured_host_port"]
        }
        $expectedHostPort = $requiredHostPorts[[string]$containerPort]
        $configuredMatches = [bool]($bindingState["configured"] -and $null -ne $expectedHostPort -and [int]$bindingState["configured_host_port"] -eq [int]$expectedHostPort)
        $publicationHealthy = [bool]($bindingState["publication_consistent"] -and $configuredMatches)
        $bindingStates.Add([ordered]@{
                container_port       = $containerPort
                expected_host_port   = $expectedHostPort
                configured_host_port = $bindingState["configured_host_port"]
                published_host_port  = $bindingState["published_host_port"]
                docker_port_host_port = $bindingState["docker_port_host_port"]
                docker_port_owner    = if ($null -ne $bindingState["docker_port_host_port"]) { [string]$ControlPlaneContainer } else { "" }
                configured           = [bool]$bindingState["configured"]
                published            = [bool]$bindingState["published"]
                publication_consistent = [bool]$bindingState["publication_consistent"]
                healthy              = $publicationHealthy
            }) | Out-Null
    }

    $httpsBinding = @($bindingStates | Where-Object { [int]$_['container_port'] -eq 443 } | Select-Object -First 1)
    $apiBinding = @($bindingStates | Where-Object { [int]$_['container_port'] -eq 6443 } | Select-Object -First 1)
    $httpBinding = @($bindingStates | Where-Object { [int]$_['container_port'] -eq 80 } | Select-Object -First 1)
    $actualHttpsPort = if ($httpsBinding.Count -gt 0) { $httpsBinding[0]["configured_host_port"] } else { $null }
    $excludedRanges = @()
    if ($PortSelection.Contains($PortKey)) {
        $excludedRanges = @($PortSelection[$PortKey]["windows_excluded_ranges_detected"])
    }
    $safety = $null
    if ($null -ne $actualHttpsPort) {
        $safety = Test-HostPortSafety -Port ([int]$actualHttpsPort) -ExcludedRanges $excludedRanges
    }

    $missingHostPublications = @($bindingStates | Where-Object { -not [bool]$_['published'] })
    $mismatchedHostPublications = @($bindingStates | Where-Object {
            ([bool]$_['configured'] -or [bool]$_['published'] -or $null -ne $_['docker_port_host_port']) -and
            -not [bool]$_['healthy']
        })
    $httpsPublished = [bool]($httpsBinding.Count -gt 0 -and [bool]$httpsBinding[0]["healthy"])
    $bindingUnsafe = [bool](
        $null -ne $safety -and (
            [bool]$safety["excluded_by_windows"] -or
            (-not $httpsPublished -and -not [bool]$safety["bind_available"])
        )
    )
    $publicationMismatch = [bool]($mismatchedHostPublications.Count -gt 0)
    $recreationRequired = [bool]($bindingUnsafe -or $publicationMismatch -or $missingHostPublications.Count -gt 0)
    $diagnosisReason = if ($bindingUnsafe) { "unusable_immutable_host_binding" } elseif ($publicationMismatch) { "host_publication_mismatch" } elseif ($missingHostPublications.Count -gt 0) { "missing_host_publication" } else { "" }
    $workloadRecreationRequired = [bool]($recreationRequired -and $ClusterName -eq "devdeploy-workload")
    $managementRecreationRequired = [bool]($recreationRequired -and $ClusterName -eq "devdeploy-mgmt")

    return [ordered]@{
        selected_https_port                    = [int]$PortPlan[$PortKey]
        configured_https_port                  = $actualHttpsPort
        host_config_https_port                 = if ($httpsBinding.Count -gt 0) { $httpsBinding[0]["configured_host_port"] } else { $null }
        network_settings_https_port            = if ($httpsBinding.Count -gt 0) { $httpsBinding[0]["published_host_port"] } else { $null }
        docker_port_https_port                 = if ($httpsBinding.Count -gt 0) { $httpsBinding[0]["docker_port_host_port"] } else { $null }
        docker_port_owner                      = if ($httpsBinding.Count -gt 0) { [string]$httpsBinding[0]["docker_port_owner"] } else { "" }
        api_publication                        = [bool]($apiBinding.Count -gt 0 -and [bool]$apiBinding[0]["healthy"])
        http_publication                       = [bool]($httpBinding.Count -gt 0 -and [bool]$httpBinding[0]["healthy"])
        https_publication                      = $httpsPublished
        actual_https_port                      = $actualHttpsPort
        published_https_port                   = if ($httpsBinding.Count -gt 0) { $httpsBinding[0]["published_host_port"] } else { $null }
        expected_https_port                    = [int]$PortPlan[$PortKey]
        https_port_safe_for_new_cluster        = if ($null -eq $safety) { $null } else { [bool]$safety["safe"] }
        https_port_excluded_by_windows         = if ($null -eq $safety) { $null } else { [bool]$safety["excluded_by_windows"] }
        https_port_docker_published            = $httpsPublished
        https_port_bind_available              = if ($null -eq $safety) { $null } else { [bool]$safety["bind_available"] }
        required_host_publications             = @($bindingStates | ForEach-Object { $_ })
        missing_host_publication                = [bool]($missingHostPublications.Count -gt 0)
        host_publication_mismatch               = $publicationMismatch
        host_access_healthy                     = [bool](-not $recreationRequired -and [string]$Integrity["integrity_status"] -eq "ok")
        recreation_required                     = $recreationRequired
        recreation_reason                       = $diagnosisReason
        workload_cluster_recreation_required   = $workloadRecreationRequired
        workload_cluster_recreation_reason     = if ($workloadRecreationRequired) { $diagnosisReason } else { "" }
        management_cluster_recreation_required = $managementRecreationRequired
        management_cluster_recreation_reason   = if ($managementRecreationRequired) { $diagnosisReason } else { "" }
    }
}

function Get-KindContainerInternalReadiness {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("devdeploy-mgmt-control-plane", "devdeploy-workload-control-plane")]
        [string]$ControlPlaneContainer,

        [bool]$DockerAvailable,

        [bool]$DockerDaemonReachable,

        [bool]$ContainerRunning
    )

    $result = [ordered]@{
        internal_cluster_ready = $null
        ready_nodes            = 0
        total_nodes            = 0
        message                = "Internal Kubernetes readiness could not be determined safely."
    }
    if (-not $DockerAvailable -or -not $ContainerRunning) {
        return $result
    }

    $nodesResult = Invoke-ReadOnlyCommand -FileName "docker" -Arguments @("exec", $ControlPlaneContainer, "kubectl", "get", "nodes", "--no-headers") -TimeoutSeconds 20 -PreserveStandardOutput $true
    if ($nodesResult.exit_code -ne 0 -or $nodesResult.timed_out -or [string]::IsNullOrWhiteSpace($nodesResult.stdout)) {
        $result["internal_cluster_ready"] = $false
        $result["message"] = "The internal Kubernetes node readiness check did not succeed."
        return $result
    }

    $nodes = @(([string]$nodesResult.stdout) -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $readyNodes = @($nodes | Where-Object {
            $columns = @($_ -split "\s+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $columns.Count -ge 2 -and $columns[1] -eq "Ready"
        })
    $result["ready_nodes"] = [int]$readyNodes.Count
    $result["total_nodes"] = [int]$nodes.Count
    $result["internal_cluster_ready"] = [bool]($nodes.Count -gt 0 -and $readyNodes.Count -gt 0)
    $result["message"] = if ([bool]$result["internal_cluster_ready"]) {
        "Kubernetes is internally Ready inside the kind control-plane container."
    }
    else {
        "The kind control-plane container is running, but no internal Kubernetes node is Ready."
    }
    return $result
}

function Get-WorkloadClusterRecreationRequirement {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Integrity,

        [bool]$DockerAvailable,

        [bool]$DockerDaemonReachable
    )

    return Get-ClusterHttpsPortRecreationRequirement -ClusterName "devdeploy-workload" -ControlPlaneContainer "devdeploy-workload-control-plane" -PortKey "workload_https" -RecreationReason "workload_cluster_recreation_required" -Integrity $Integrity -DockerAvailable $DockerAvailable -DockerDaemonReachable $DockerDaemonReachable
}

function Get-ManagementClusterRecreationRequirement {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Integrity,

        [bool]$DockerAvailable,

        [bool]$DockerDaemonReachable
    )

    return Get-ClusterHttpsPortRecreationRequirement -ClusterName "devdeploy-mgmt" -ControlPlaneContainer "devdeploy-mgmt-control-plane" -PortKey "management_https" -RecreationReason "management_cluster_recreation_required" -Integrity $Integrity -DockerAvailable $DockerAvailable -DockerDaemonReachable $DockerDaemonReachable
}

function Write-KindIntegrityConsole {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Cluster,

        [bool]$Required
    )

    $integrityStatus = [string]$Cluster["integrity_status"]
    if ($integrityStatus -in @("ok", "cluster_missing", "unknown")) {
        return
    }

    $level = if ($Required) { "ERROR" } else { "WARNING" }
    Write-Host ("[{0}] {1} kind integrity: {2}" -f $level, [string]$Cluster["name"], [string]$Cluster["message"])
    Write-Host ("        Container: {0}; running: {1}" -f [string]$Cluster["control_plane_container"], [string]$Cluster["container_running"])
    Write-Host ("        Expected: 127.0.0.1:{0} -> 6443/tcp" -f [string]$Cluster["expected_api_port"])
    $actual = if ($null -eq $Cluster["actual_api_port"]) { "no 6443/tcp published port found" } else { "host port {0}" -f [string]$Cluster["actual_api_port"] }
    Write-Host ("        Actual: {0}." -f $actual)
    Write-Host ("        Suggested fix: {0}" -f [string]$Cluster["recommended_action"])
}

function Write-ClusterRecoveryPlanConsole {
    param(
        [Parameter(Mandatory = $true)]
        [object]$RecoveryPlan
    )

    if (-not [bool]$RecoveryPlan["required"]) {
        return
    }

    Write-Host ("[RECOVERY] {0}" -f [string]$RecoveryPlan["summary"])
    $stepNumber = 1
    foreach ($step in @($RecoveryPlan["recommended_steps"])) {
        Write-Host ("           {0}. {1}" -f $stepNumber, [string]$step)
        $stepNumber++
    }
    Write-Host "           Guidance only: no automatic recovery or destructive action was performed."
}

function New-ManagementClusterStatusSnapshot {
    param(
        [bool]$KindAvailable,

        [bool]$KubectlAvailable
    )

    $checkedAt = [string](Get-Timestamp)
    $base = [ordered]@{
        name                    = "devdeploy-mgmt"
        context                 = "kind-devdeploy-mgmt"
        exists                  = $false
        api_reachable           = $null
        node_ready              = $null
        internal_cluster_ready  = $null
        host_access_healthy     = $false
        recreation_required     = $false
        recreation_reason       = ""
        selected_https_port     = [int]$PortPlan["management_https"]
        configured_https_port   = $null
        host_config_https_port  = $null
        network_settings_https_port = $null
        docker_port_https_port  = $null
        docker_port_owner       = ""
        api_publication         = $false
        http_publication        = $false
        https_publication       = $false
        ready_nodes             = 0
        total_nodes             = 0
        control_plane_container = "devdeploy-mgmt-control-plane"
        container_running       = $null
        api_port_published      = $null
        expected_api_port       = 58080
        actual_api_port         = $null
        restart_policy_name     = ""
        restart_policy_maximum_retry_count = $null
        restart_policy_healthy  = $null
        restart_policy_reconciliation_needed = $null
        kubeconfig_reachable    = $null
        integrity_status        = "unknown"
        recommended_action      = "Review the sanitized launcher log and rerun preflight."
        status                  = "unknown"
        message                 = "Management cluster status could not be determined safely."
        checked_at              = $checkedAt
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
    $integrity = Get-KindClusterIntegrity -ClusterName "devdeploy-mgmt" -Context "kind-devdeploy-mgmt" -ControlPlaneContainer "devdeploy-mgmt-control-plane" -ExpectedApiPort 58080 -ClusterExists $exists -KubectlAvailable $KubectlAvailable -Required (Test-ManagementClusterIntegrityRequired)
    Set-KindIntegrityFields -ClusterStatus $base -Integrity $integrity
    $internalReadiness = Get-KindContainerInternalReadiness -ControlPlaneContainer "devdeploy-mgmt-control-plane" -DockerAvailable $dockerAvailable -DockerDaemonReachable $dockerDaemonReachable -ContainerRunning ([bool]($integrity["container_running"] -eq $true))
    $base["internal_cluster_ready"] = $internalReadiness["internal_cluster_ready"]
    $base["ready_nodes"] = [int]$internalReadiness["ready_nodes"]
    $base["total_nodes"] = [int]$internalReadiness["total_nodes"]
    $base["node_ready"] = $internalReadiness["internal_cluster_ready"]
    $recreationRequirement = Get-ManagementClusterRecreationRequirement -Integrity $integrity -DockerAvailable $dockerAvailable -DockerDaemonReachable $dockerDaemonReachable
    foreach ($field in @("selected_https_port", "configured_https_port", "host_config_https_port", "network_settings_https_port", "docker_port_https_port", "docker_port_owner", "api_publication", "http_publication", "https_publication", "expected_https_port", "actual_https_port", "published_https_port", "required_host_publications", "missing_host_publication", "host_publication_mismatch", "host_access_healthy", "recreation_required", "recreation_reason", "management_cluster_recreation_required", "management_cluster_recreation_reason")) {
        $base[$field] = $recreationRequirement[$field]
    }
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

    if ([bool]$recreationRequirement["management_cluster_recreation_required"]) {
        $base["api_reachable"] = $false
        $base["status"] = "degraded"
        $base["integrity_status"] = "management_cluster_recreation_required"
        $base["message"] = switch ([string]$recreationRequirement["recreation_reason"]) {
            "unusable_immutable_host_binding" {
                "devdeploy-mgmt may be internally Ready, but its immutable HTTPS host binding is unusable and host access is unhealthy. Management cluster recreation is required after backup verification."
                break
            }
            "host_publication_mismatch" {
                "devdeploy-mgmt may be internally Ready, but its configured and published Docker host ports do not agree. Management cluster recreation is required after backup verification."
                break
            }
            default {
                "devdeploy-mgmt may be internally Ready, but one or more required host ports are not published. Management cluster recreation is required after backup verification."
            }
        }
        $base["recommended_action"] = "Review -PlanManagementPortRecovery. Verify the PostgreSQL backup before any future management recreation; no automatic management delete or recreate action exists in this phase."
        $integrityCheckRequired = [bool](Test-ManagementClusterIntegrityRequired)
        $integrityCheckStatus = if ($integrityCheckRequired) { "failed" } else { "warning" }
        $integrityCheckDetails = New-ManagementIntegrityCheckDetails -Required $integrityCheckRequired -IntegrityStatus "management_cluster_recreation_required" -InternalClusterReady $base["internal_cluster_ready"] -HostAccessHealthy $false -RecreationRequired $true -RecreationReason ([string]$recreationRequirement["recreation_reason"]) -RequiredHostPublications $recreationRequirement["required_host_publications"]
        Set-CheckResult -Id "kind_integrity_devdeploy-mgmt" -Status $integrityCheckStatus -Message ([string]$base["message"]) -Details $integrityCheckDetails | Out-Null

        $recreationCheckDetails = New-ManagementIntegrityCheckDetails -Required $integrityCheckRequired -IntegrityStatus "management_cluster_recreation_required" -InternalClusterReady $base["internal_cluster_ready"] -HostAccessHealthy $false -RecreationRequired $true -RecreationReason ([string]$recreationRequirement["recreation_reason"]) -RequiredHostPublications $recreationRequirement["required_host_publications"]
        $recreationCheckDetails["control_plane_container"] = [string]"devdeploy-mgmt-control-plane"
        $recreationCheckDetails["expected_https_port"] = [int]$recreationRequirement["expected_https_port"]
        $recreationCheckDetails["actual_https_port"] = if ($null -eq $recreationRequirement["actual_https_port"]) { $null } else { [int]$recreationRequirement["actual_https_port"] }
        $recreationCheckDetails["excluded_by_windows"] = if ($null -eq $recreationRequirement["https_port_excluded_by_windows"]) { $null } else { [bool]$recreationRequirement["https_port_excluded_by_windows"] }
        $recreationCheckDetails["bind_available"] = if ($null -eq $recreationRequirement["https_port_bind_available"]) { $null } else { [bool]$recreationRequirement["https_port_bind_available"] }
        $recreationCheckDetails["backup_verification_required"] = $true
        Add-Check -Id "management_cluster_recreation_required" -Label "Management cluster port recovery required" -Status $integrityCheckStatus -Message ([string]$base["message"]) -Details $recreationCheckDetails
        return $base
    }

    if ([string]$base["integrity_status"] -eq "ok") {
        $healthyIntegrityDetails = New-ManagementIntegrityCheckDetails -Required (Test-ManagementClusterIntegrityRequired) -IntegrityStatus "ok" -InternalClusterReady $base["internal_cluster_ready"] -HostAccessHealthy ([bool]$base["host_access_healthy"]) -RecreationRequired $false -RecreationReason "" -RequiredHostPublications $recreationRequirement["required_host_publications"]
        Set-CheckResult -Id "kind_integrity_devdeploy-mgmt" -Status "ok" -Message ([string]$integrity["message"]) -Details $healthyIntegrityDetails | Out-Null
    }

    if ([string]$base["integrity_status"] -ne "ok") {
        $base["api_reachable"] = if ($base["kubeconfig_reachable"] -eq $true) { $true } else { $false }
        $base["status"] = "degraded"
        $base["message"] = [string]$integrity["message"]
        Add-Check -Id "management_cluster_status" -Label "Management cluster status" -Status "warning" -Message ([string]$base["message"]) -Details @{
            required          = $false
            cluster_name      = "devdeploy-mgmt"
            context           = "kind-devdeploy-mgmt"
            status            = "degraded"
            integrity_status  = [string]$base["integrity_status"]
            expected_api_port = 58080
            actual_api_port   = $base["actual_api_port"]
        }
        return $base
    }

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
        $base["host_access_healthy"] = $true
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

function New-ManagementClusterStatus {
    param(
        [bool]$KindAvailable,

        [bool]$KubectlAvailable
    )

    if ($null -eq $script:ManagementClusterStatusCache) {
        $script:ManagementClusterStatusCache = New-ManagementClusterStatusSnapshot -KindAvailable $KindAvailable -KubectlAvailable $KubectlAvailable
    }
    return $script:ManagementClusterStatusCache
}

function Reset-CanonicalManagementClusterStatus {
    $script:ManagementClusterStatusCache = $null
}

function New-WorkloadClusterStatus {
    param(
        [bool]$KindAvailable,

        [bool]$KubectlAvailable
    )

    $checkedAt = [string](Get-Timestamp)
    $base = [ordered]@{
        name                    = "devdeploy-workload"
        context                 = "kind-devdeploy-workload"
        exists                  = $false
        api_reachable           = $null
        node_ready              = $null
        ready_nodes             = 0
        total_nodes             = 0
        control_plane_container = "devdeploy-workload-control-plane"
        container_running       = $null
        api_port_published      = $null
        expected_api_port       = 58081
        actual_api_port         = $null
        restart_policy_name     = ""
        restart_policy_maximum_retry_count = $null
        restart_policy_healthy  = $null
        restart_policy_reconciliation_needed = $null
        expected_https_port     = [int]$PortPlan["workload_https"]
        actual_https_port       = $null
        workload_cluster_recreation_required = $false
        workload_cluster_recreation_reason   = ""
        kubeconfig_reachable    = $null
        integrity_status        = "unknown"
        recommended_action      = "Review the sanitized launcher log and rerun preflight."
        status                  = "unknown"
        message                 = "Workload cluster status could not be determined safely."
        checked_at              = $checkedAt
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
    $integrity = Get-KindClusterIntegrity -ClusterName "devdeploy-workload" -Context "kind-devdeploy-workload" -ControlPlaneContainer "devdeploy-workload-control-plane" -ExpectedApiPort 58081 -ClusterExists $exists -KubectlAvailable $KubectlAvailable -Required (Test-WorkloadClusterIntegrityRequired)
    Set-KindIntegrityFields -ClusterStatus $base -Integrity $integrity
    $recreationRequirement = Get-WorkloadClusterRecreationRequirement -Integrity $integrity -DockerAvailable $dockerAvailable -DockerDaemonReachable $dockerDaemonReachable
    foreach ($field in @("expected_https_port", "actual_https_port", "workload_cluster_recreation_required", "workload_cluster_recreation_reason")) {
        $base[$field] = $recreationRequirement[$field]
    }
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

    if ([bool]$recreationRequirement["workload_cluster_recreation_required"]) {
        $base["api_reachable"] = $false
        $base["node_ready"] = $null
        $base["status"] = "degraded"
        $base["integrity_status"] = "workload_cluster_recreation_required"
        $base["message"] = "devdeploy-workload is stopped and its immutable HTTPS host port binding is no longer usable on this Windows host."
        $base["recommended_action"] = "Review -PlanWorkloadPortRecovery. Recreate only devdeploy-workload after explicit user confirmation; never recreate devdeploy-mgmt for this workload-only port issue."
        Add-Check -Id "workload_cluster_recreation_required" -Label "Workload cluster port recovery required" -Status $(if (Test-WorkloadClusterIntegrityRequired) { "failed" } else { "warning" }) -Message ([string]$base["message"]) -Details @{
            required                    = (Test-WorkloadClusterIntegrityRequired)
            cluster_name                = "devdeploy-workload"
            integrity_status            = "workload_cluster_recreation_required"
            control_plane_container     = "devdeploy-workload-control-plane"
            expected_https_port         = [int]$recreationRequirement["expected_https_port"]
            actual_https_port           = $recreationRequirement["actual_https_port"]
            excluded_by_windows         = $recreationRequirement["https_port_excluded_by_windows"]
            bind_available              = $recreationRequirement["https_port_bind_available"]
            management_cluster_targeted = $false
        }
        return $base
    }

    if ([string]$base["integrity_status"] -ne "ok") {
        $base["api_reachable"] = if ($base["kubeconfig_reachable"] -eq $true) { $true } else { $false }
        $base["node_ready"] = $null
        $base["status"] = "degraded"
        $base["message"] = [string]$integrity["message"]
        Add-Check -Id "workload_cluster_status" -Label "Workload cluster status" -Status "warning" -Message ([string]$base["message"]) -Details @{
            required          = $false
            cluster_name      = "devdeploy-workload"
            context           = "kind-devdeploy-workload"
            status            = "degraded"
            integrity_status  = [string]$base["integrity_status"]
            expected_api_port = 58081
            actual_api_port   = $base["actual_api_port"]
        }
        return $base
    }

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
        ingress_path                        = $ArgoCDIngressPath
        ui_access                           = $ArgoCDUiAccess
        admin_secret_present                = $false
        application_count                   = $null
        mode                                = "status"
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

    $ingressJsonPath = "{.spec.ingressClassName}|{.spec.rules[0].host}|{.spec.rules[0].http.paths[0].path}"
    $ingressResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", "ingress", "argocd-server", "--output", "jsonpath=$ingressJsonPath") -TimeoutSeconds 20
    $ingressParts = if ($ingressResult.exit_code -eq 0 -and -not $ingressResult.timed_out) { @(([string]$ingressResult.stdout).Split('|')) } else { @() }
    $ingressReady = [bool]($ingressParts.Count -ge 3 -and ([string]$ingressParts[0]).Trim() -eq "nginx" -and [string]::IsNullOrWhiteSpace(([string]$ingressParts[1]).Trim()) -and ([string]$ingressParts[2]).Trim() -eq $ArgoCDIngressPath)
    $status["ingress_enabled"] = $ingressReady

    $adminSecretResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", "secret", "argocd-initial-admin-secret", "--output", "name") -TimeoutSeconds 20
    $status["admin_secret_present"] = [bool]($adminSecretResult.exit_code -eq 0 -and -not $adminSecretResult.timed_out)

    $applicationsResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", "applications.argoproj.io", "--output", "jsonpath={.items[*].metadata.name}") -TimeoutSeconds 20
    if ($applicationsResult.exit_code -eq 0 -and -not $applicationsResult.timed_out) {
        $applicationNames = @(([string]$applicationsResult.stdout) -split "\s+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $status["application_count"] = [int]$applicationNames.Count
    }

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

function Get-ManagementArgoCDRuntimeStatus {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ManagementCluster,

        [bool]$KubectlAvailable
    )

    $status = New-ManagementArgoCDStatus
    $status["mode"] = "runtime_verify"
    if ([string]$ManagementCluster["status"] -ne "ready" -or -not $KubectlAvailable) {
        $status["status"] = "unknown"
        $status["message"] = "Management Argo CD runtime status requires a Ready management cluster and kubectl."
        return $status
    }

    $namespaceResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "get", "namespace", $ArgoCDNamespace, "--output", "name") -TimeoutSeconds 20
    if ($namespaceResult.exit_code -ne 0 -or $namespaceResult.timed_out) {
        $status["status"] = "absent"
        $status["message"] = "Management Argo CD namespace is absent."
        return $status
    }

    $status["installed"] = $true
    $serverReady = Test-ArgoCDResourceReady -Kind "deployment" -Name "argocd-server"
    $repoServerReady = Test-ArgoCDResourceReady -Kind "deployment" -Name "argocd-repo-server"
    $controllerReady = Test-ArgoCDResourceReady -Kind "statefulset" -Name "argocd-application-controller"
    $serviceResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", "service", "argocd-server", "--output", "name") -TimeoutSeconds 20
    $serviceReady = [bool]($serviceResult.exit_code -eq 0 -and -not $serviceResult.timed_out)

    $status["ready"] = [bool]($serverReady -and $repoServerReady -and $controllerReady -and $serviceReady)
    if ([bool]$status["ready"]) {
        $status["status"] = "ready"
        $status["message"] = "Management Argo CD core runtime resources are Ready."
    }
    else {
        $status["status"] = "error"
        $status["message"] = "Management Argo CD exists, but one or more core runtime resources are not Ready."
    }
    $status["checked_at"] = [string](Get-Timestamp)
    return $status
}

function New-WorkloadClusterEndpointStatus {
    return [ordered]@{
        discovered             = $false
        ready                  = $false
        source_cluster         = "devdeploy-mgmt"
        source_context         = "kind-devdeploy-mgmt"
        target_cluster         = "devdeploy-workload"
        target_context         = "kind-devdeploy-workload"
        rejected_host_endpoint = $null
        selected_endpoint      = $null
        selected_strategy      = "not_selected"
        candidates             = @()
        probe_namespace        = $WorkloadEndpointProbeNamespace
        probe_resource_name    = $WorkloadEndpointProbeName
        cleanup_succeeded      = $null
        status                 = "not_started"
        message                = "Workload cluster endpoint discovery has not been requested."
        checked_at             = [string](Get-Timestamp)
    }
}

function Get-DockerContainerNetworkInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ContainerName
    )

    $result = Invoke-ReadOnlyCommand -FileName "docker" -Arguments @("inspect", $ContainerName, "--format", "{{json .NetworkSettings.Networks}}") -TimeoutSeconds 20 -PreserveStandardOutput $true
    if ($result.exit_code -ne 0 -or $result.timed_out -or [string]::IsNullOrWhiteSpace($result.stdout)) {
        return [ordered]@{
            success  = $false
            networks = @()
            error    = "Docker network metadata could not be read for the expected kind control-plane container."
        }
    }

    try {
        $parsed = ([string]$result.stdout | ConvertFrom-Json)
        $networks = New-Object System.Collections.Generic.List[object]
        foreach ($property in @($parsed.PSObject.Properties)) {
            $networks.Add([ordered]@{
                    name       = [string]$property.Name
                    gateway    = [string]$property.Value.Gateway
                    ip_address = [string]$property.Value.IPAddress
                }) | Out-Null
        }

        return [ordered]@{
            success  = $true
            networks = @($networks | ForEach-Object { $_ })
            error    = ""
        }
    }
    catch {
        return [ordered]@{
            success  = $false
            networks = @()
            error    = "Docker network metadata could not be parsed safely."
        }
    }
}

function Remove-WorkloadEndpointProbePod {
    param(
        [bool]$KubectlAvailable
    )

    if (-not $KubectlAvailable) {
        return $false
    }

    $result = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $WorkloadEndpointProbeNamespace, "delete", "pod", $WorkloadEndpointProbeName, "--ignore-not-found=true", "--wait=true", "--timeout=30s") -TimeoutSeconds 45
    return [bool]($result.exit_code -eq 0 -and -not $result.timed_out)
}

function Invoke-DiscoverWorkloadClusterEndpoint {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ManagementCluster,

        [Parameter(Mandatory = $true)]
        [object]$WorkloadCluster,

        [bool]$DockerAvailable,

        [bool]$DockerDaemonReachable,

        [bool]$KindAvailable,

        [bool]$KubectlAvailable
    )

    $status = New-WorkloadClusterEndpointStatus
    $candidateResults = New-Object System.Collections.Generic.List[object]
    $probeCreated = $false
    $cleanupSucceeded = $false

    if (-not $DockerAvailable -or -not $DockerDaemonReachable -or -not $KindAvailable -or -not $KubectlAvailable) {
        $status["status"] = "error"
        $status["message"] = "Docker, kind, kubectl, and a reachable Docker daemon are required for endpoint discovery."
        Add-Check -Id "workload_endpoint_prerequisites" -Label "Workload endpoint discovery prerequisites" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required                = $true
            docker_available        = $DockerAvailable
            docker_daemon_reachable = $DockerDaemonReachable
            kind_available          = $KindAvailable
            kubectl_available       = $KubectlAvailable
        }
        return $status
    }

    if ([string]$ManagementCluster["status"] -ne "ready" -or [string]$WorkloadCluster["status"] -ne "ready") {
        $status["status"] = "error"
        $status["message"] = "Both devdeploy-mgmt and devdeploy-workload must be Ready before endpoint discovery."
        Add-Check -Id "workload_endpoint_prerequisites" -Label "Workload endpoint discovery prerequisites" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required                  = $true
            management_cluster_status = [string]$ManagementCluster["status"]
            workload_cluster_status   = [string]$WorkloadCluster["status"]
        }
        return $status
    }

    Add-Check -Id "workload_endpoint_prerequisites" -Label "Workload endpoint discovery prerequisites" -Status "ok" -Message "Both DevDeploy clusters and required host tools are ready for endpoint discovery." -Details @{
        required = $true
    }

    $serverResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("config", "view", "--raw", "--minify", "--context", "kind-devdeploy-workload", "--output", "jsonpath={.clusters[0].cluster.server}") -TimeoutSeconds 20 -PreserveStandardOutput $true
    $caResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("config", "view", "--raw", "--minify", "--context", "kind-devdeploy-workload", "--output", "jsonpath={.clusters[0].cluster.certificate-authority-data}") -TimeoutSeconds 20 -PreserveStandardOutput $true
    $hostEndpoint = ([string]$serverResult.stdout).Trim()
    $caData = ([string]$caResult.stdout).Trim()
    if ($serverResult.exit_code -ne 0 -or $serverResult.timed_out -or [string]::IsNullOrWhiteSpace($hostEndpoint) -or $caResult.exit_code -ne 0 -or $caResult.timed_out -or [string]::IsNullOrWhiteSpace($caData)) {
        $status["status"] = "error"
        $status["message"] = "The workload kubeconfig server endpoint or CA data could not be read safely."
        Add-Check -Id "workload_endpoint_kubeconfig" -Label "Workload kubeconfig endpoint metadata" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required = $true
        }
        return $status
    }

    $status["rejected_host_endpoint"] = $hostEndpoint
    $hostOnlyRejected = [bool]($hostEndpoint -match '^https://(127\.0\.0\.1|localhost):58081/?$')
    $candidateResults.Add([ordered]@{
            strategy                  = "host_kubeconfig_loopback"
            endpoint                  = $hostEndpoint
            reachable_from_management = $false
            tls_verified              = $false
            selected                  = $false
            rejected_reason           = if ($hostOnlyRejected) { "Host loopback is not valid from inside Argo CD or management-cluster Pods." } else { "The host kubeconfig endpoint is recorded only for comparison and is not selected without Pod-network validation." }
        }) | Out-Null
    Add-Check -Id "workload_endpoint_host_loopback_rejected" -Label "Host-only workload endpoint rejection" -Status "ok" -Message "The workload kubeconfig host endpoint was classified as host-only and will not be selected for Argo CD." -Details @{
        required = $true
        endpoint = $hostEndpoint
        rejected = $true
    }

    $managementNetwork = Get-DockerContainerNetworkInfo -ContainerName "devdeploy-mgmt-control-plane"
    $workloadNetwork = Get-DockerContainerNetworkInfo -ContainerName "devdeploy-workload-control-plane"
    if (-not $managementNetwork.success -or -not $workloadNetwork.success) {
        $status["status"] = "error"
        $status["message"] = "Docker network information for both kind control planes could not be inspected safely."
        Add-Check -Id "workload_endpoint_docker_networks" -Label "Workload endpoint Docker networks" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required = $true
        }
        $status["candidates"] = @($candidateResults | ForEach-Object { $_ })
        return $status
    }

    $managementNetworkNames = @($managementNetwork.networks | ForEach-Object { [string]$_['name'] })
    $workloadNetworkNames = @($workloadNetwork.networks | ForEach-Object { [string]$_['name'] })
    $sharedNetworkNames = @($managementNetworkNames | Where-Object { $workloadNetworkNames -contains $_ })
    $probeCandidates = New-Object System.Collections.Generic.List[object]
    if ($sharedNetworkNames.Count -gt 0) {
        $probeCandidates.Add([ordered]@{
                strategy = "docker_network_control_plane"
                endpoint = "https://devdeploy-workload-control-plane:6443"
            }) | Out-Null
    }
    else {
        $candidateResults.Add([ordered]@{
                strategy                  = "docker_network_control_plane"
                endpoint                  = "https://devdeploy-workload-control-plane:6443"
                reachable_from_management = $false
                tls_verified              = $false
                selected                  = $false
                rejected_reason           = "The management and workload control-plane containers do not share a Docker network."
            }) | Out-Null
    }

    $probeCandidates.Add([ordered]@{
            strategy = "host_docker_internal"
            endpoint = "https://host.docker.internal:58081"
        }) | Out-Null

    $gateway = ""
    if ($sharedNetworkNames.Count -gt 0) {
        $sharedName = [string]$sharedNetworkNames[0]
        $sharedMetadata = @($managementNetwork.networks | Where-Object { [string]$_['name'] -eq $sharedName }) | Select-Object -First 1
        if ($null -ne $sharedMetadata) {
            $gateway = [string]$sharedMetadata["gateway"]
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($gateway)) {
        $probeCandidates.Add([ordered]@{
                strategy = "docker_gateway"
                endpoint = "https://${gateway}:58081"
            }) | Out-Null
    }

    Add-Check -Id "workload_endpoint_candidates" -Label "Workload endpoint candidates" -Status "ok" -Message "Sanitized workload API endpoint candidates were derived from Docker and kubeconfig metadata." -Details @{
        required             = $true
        shared_network_count = [int]$sharedNetworkNames.Count
        probe_candidate_count = [int]$probeCandidates.Count
    }

    $existingProbeResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $WorkloadEndpointProbeNamespace, "get", "pod", $WorkloadEndpointProbeName, "--output", "json") -TimeoutSeconds 20 -PreserveStandardOutput $true
    if ($existingProbeResult.exit_code -eq 0 -and -not $existingProbeResult.timed_out) {
        $existingOwned = $false
        try {
            $existingProbe = ([string]$existingProbeResult.stdout | ConvertFrom-Json)
            $existingOwned = [bool]([string]$existingProbe.metadata.labels.'devdeploy.io/purpose' -eq "endpoint-probe")
        }
        catch {
            $existingOwned = $false
        }

        if (-not $existingOwned) {
            $status["status"] = "error"
            $status["message"] = "A Pod named devdeploy-endpoint-probe already exists without the expected ownership label; it was not deleted."
            Add-Check -Id "workload_endpoint_probe_ownership" -Label "Workload endpoint probe ownership" -Status "failed" -Message ([string]$status["message"]) -Details @{
                required       = $true
                namespace      = $WorkloadEndpointProbeNamespace
                resource_name  = $WorkloadEndpointProbeName
            }
            $status["candidates"] = @($candidateResults | ForEach-Object { $_ })
            return $status
        }

        if (-not (Remove-WorkloadEndpointProbePod -KubectlAvailable $KubectlAvailable)) {
            $status["status"] = "error"
            $status["message"] = "A stale owned endpoint probe Pod could not be removed safely."
            Add-Check -Id "workload_endpoint_probe_ownership" -Label "Workload endpoint probe ownership" -Status "failed" -Message ([string]$status["message"]) -Details @{
                required      = $true
                namespace     = $WorkloadEndpointProbeNamespace
                resource_name = $WorkloadEndpointProbeName
            }
            $status["candidates"] = @($candidateResults | ForEach-Object { $_ })
            return $status
        }
    }

    $probeScript = @'
import base64
import json
import os
import ssl
import urllib.error
import urllib.request

ca_path = "/tmp/workload-ca.crt"
with open(ca_path, "wb") as ca_file:
    ca_file.write(base64.b64decode(os.environ["WORKLOAD_CA_B64"]))

candidates = json.loads(os.environ["PROBE_CANDIDATES_JSON"])

def request(endpoint, context):
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPSHandler(context=context),
    )
    try:
        with opener.open(endpoint.rstrip("/") + "/version", timeout=8) as response:
            return True, int(response.status)
    except urllib.error.HTTPError as error:
        return True, int(error.code)
    except Exception:
        return False, 0

verified_context = ssl.create_default_context(cafile=ca_path)
unverified_context = ssl._create_unverified_context()

for candidate in candidates:
    verified, status_code = request(candidate["endpoint"], verified_context)
    reachable = verified
    if not verified:
        reachable, fallback_code = request(candidate["endpoint"], unverified_context)
        if fallback_code:
            status_code = fallback_code
    print(json.dumps({
        "strategy": candidate["strategy"],
        "endpoint": candidate["endpoint"],
        "reachable_from_management": bool(reachable),
        "tls_verified": bool(verified),
        "http_status": int(status_code),
    }, sort_keys=True))
'@

    $probeEnvironmentCandidates = @($probeCandidates | ForEach-Object {
            [ordered]@{
                strategy = [string]$_['strategy']
                endpoint = [string]$_['endpoint']
            }
        }) | ConvertTo-Json -Compress

    $podManifest = [ordered]@{
        apiVersion = "v1"
        kind       = "Pod"
        metadata   = [ordered]@{
            name      = $WorkloadEndpointProbeName
            namespace = $WorkloadEndpointProbeNamespace
            labels    = [ordered]@{
                "app.kubernetes.io/name"       = "devdeploy-endpoint-probe"
                "app.kubernetes.io/managed-by" = "devdeploy-launcher"
                "devdeploy.io/purpose"         = "endpoint-probe"
            }
        }
        spec       = [ordered]@{
            restartPolicy                = "Never"
            automountServiceAccountToken = $false
            activeDeadlineSeconds        = 90
            securityContext              = [ordered]@{
                runAsNonRoot    = $true
                seccompProfile  = [ordered]@{ type = "RuntimeDefault" }
            }
            containers                   = @(
                [ordered]@{
                    name            = "probe"
                    image           = $WorkloadEndpointProbeImage
                    imagePullPolicy = "IfNotPresent"
                    command         = @("python", "-c", $probeScript)
                    env             = @(
                        [ordered]@{ name = "WORKLOAD_CA_B64"; value = $caData },
                        [ordered]@{ name = "PROBE_CANDIDATES_JSON"; value = $probeEnvironmentCandidates }
                    )
                    securityContext = [ordered]@{
                        allowPrivilegeEscalation = $false
                        readOnlyRootFilesystem   = $true
                        runAsNonRoot             = $true
                        runAsUser                = 10001
                        runAsGroup               = 10001
                        capabilities             = [ordered]@{ drop = @("ALL") }
                    }
                    resources       = [ordered]@{
                        requests = [ordered]@{ cpu = "10m"; memory = "32Mi" }
                        limits   = [ordered]@{ cpu = "100m"; memory = "128Mi" }
                    }
                    volumeMounts    = @(
                        [ordered]@{ name = "tmp"; mountPath = "/tmp" }
                    )
                }
            )
            volumes                      = @(
                [ordered]@{ name = "tmp"; emptyDir = [ordered]@{} }
            )
        }
    }

    try {
        $manifestJson = $podManifest | ConvertTo-Json -Depth 12 -Compress
        $createResult = Invoke-SanitizedInputCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "create", "--filename", "-") -StandardInput $manifestJson -TimeoutSeconds 45
        if ($createResult.exit_code -ne 0 -or $createResult.timed_out) {
            $status["status"] = "error"
            $status["message"] = "The temporary endpoint probe Pod could not be created safely."
            Add-Check -Id "workload_endpoint_probe_create" -Label "Workload endpoint probe creation" -Status "failed" -Message ([string]$status["message"]) -Details @{
                required      = $true
                namespace     = $WorkloadEndpointProbeNamespace
                resource_name = $WorkloadEndpointProbeName
                error         = $createResult.stderr
            }
            return $status
        }

        $probeCreated = $true
        Add-Check -Id "workload_endpoint_probe_create" -Label "Workload endpoint probe creation" -Status "ok" -Message "The deterministic temporary endpoint probe Pod was created in devdeploy-mgmt." -Details @{
            required      = $true
            namespace     = $WorkloadEndpointProbeNamespace
            resource_name = $WorkloadEndpointProbeName
            image         = $WorkloadEndpointProbeImage
        }

        $phase = ""
        for ($attempt = 1; $attempt -le 45; $attempt++) {
            $phaseResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $WorkloadEndpointProbeNamespace, "get", "pod", $WorkloadEndpointProbeName, "--output", "jsonpath={.status.phase}") -TimeoutSeconds 10
            if ($phaseResult.exit_code -eq 0 -and -not $phaseResult.timed_out) {
                $phase = ([string]$phaseResult.stdout).Trim()
            }
            if ($phase -in @("Succeeded", "Failed")) {
                break
            }
            Start-Sleep -Seconds 2
        }

        if ($phase -ne "Succeeded") {
            $status["status"] = "error"
            $status["message"] = "The temporary endpoint probe Pod did not complete successfully."
            Add-Check -Id "workload_endpoint_probe_run" -Label "Workload endpoint probe execution" -Status "failed" -Message ([string]$status["message"]) -Details @{
                required  = $true
                phase     = $phase
                namespace = $WorkloadEndpointProbeNamespace
            }
            return $status
        }

        $logsResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $WorkloadEndpointProbeNamespace, "logs", $WorkloadEndpointProbeName, "--container", "probe") -TimeoutSeconds 20 -PreserveStandardOutput $true
        if ($logsResult.exit_code -ne 0 -or $logsResult.timed_out -or [string]::IsNullOrWhiteSpace($logsResult.stdout)) {
            $status["status"] = "error"
            $status["message"] = "Endpoint probe results could not be read safely."
            Add-Check -Id "workload_endpoint_probe_run" -Label "Workload endpoint probe execution" -Status "failed" -Message ([string]$status["message"]) -Details @{
                required = $true
            }
            return $status
        }

        foreach ($line in @(([string]$logsResult.stdout) -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            try {
                $probeResult = ([string]$line | ConvertFrom-Json)
                $candidateResults.Add([ordered]@{
                        strategy                  = [string]$probeResult.strategy
                        endpoint                  = [string]$probeResult.endpoint
                        reachable_from_management = [bool]$probeResult.reachable_from_management
                        tls_verified              = [bool]$probeResult.tls_verified
                        selected                  = $false
                        rejected_reason           = if ([bool]$probeResult.tls_verified) { "" } elseif ([bool]$probeResult.reachable_from_management) { "Network reachability succeeded, but TLS verification failed." } else { "The endpoint was not reachable from the management-cluster probe Pod." }
                    }) | Out-Null
            }
            catch {
                Write-LauncherLog "Ignored an unparseable sanitized endpoint probe result line."
            }
        }

        Add-Check -Id "workload_endpoint_probe_run" -Label "Workload endpoint probe execution" -Status "ok" -Message "The temporary probe completed and returned sanitized network and TLS results." -Details @{
            required         = $true
            candidate_count  = [int]$probeCandidates.Count
            result_count     = [int]($candidateResults.Count - 1)
        }

        $selected = @($candidateResults | Where-Object { [bool]$_['reachable_from_management'] -and [bool]$_['tls_verified'] -and [string]$_['strategy'] -ne "host_kubeconfig_loopback" }) | Select-Object -First 1
        if ($null -eq $selected) {
            $status["status"] = "error"
            $status["message"] = "No workload API endpoint passed management-cluster network and TLS verification."
            Add-Check -Id "workload_endpoint_selection" -Label "Workload endpoint selection" -Status "failed" -Message ([string]$status["message"]) -Details @{
                required = $true
            }
        }
        else {
            $selected["selected"] = $true
            $selected["rejected_reason"] = ""
            $status["discovered"] = $true
            $status["ready"] = $true
            $status["selected_endpoint"] = [string]$selected["endpoint"]
            $status["selected_strategy"] = [string]$selected["strategy"]
            $status["status"] = "ready"
            $status["message"] = "A workload Kubernetes API endpoint passed management-cluster network and TLS verification. Registration was not performed."
            Add-Check -Id "workload_endpoint_selection" -Label "Workload endpoint selection" -Status "ok" -Message ([string]$status["message"]) -Details @{
                required          = $true
                selected_strategy = [string]$selected["strategy"]
                selected_endpoint = [string]$selected["endpoint"]
                registration_performed = $false
            }
        }
    }
    finally {
        $cleanupSucceeded = Remove-WorkloadEndpointProbePod -KubectlAvailable $KubectlAvailable
        $status["cleanup_succeeded"] = $cleanupSucceeded
        if ($cleanupSucceeded) {
            Add-Check -Id "workload_endpoint_probe_cleanup" -Label "Workload endpoint probe cleanup" -Status "ok" -Message "The deterministic temporary endpoint probe Pod is absent after discovery." -Details @{
                required      = $false
                namespace     = $WorkloadEndpointProbeNamespace
                resource_name = $WorkloadEndpointProbeName
            }
        }
        else {
            Add-Check -Id "workload_endpoint_probe_cleanup" -Label "Workload endpoint probe cleanup" -Status "warning" -Message "The temporary endpoint probe Pod could not be confirmed absent; remove only devdeploy-endpoint-probe after inspection." -Details @{
                required      = $false
                namespace     = $WorkloadEndpointProbeNamespace
                resource_name = $WorkloadEndpointProbeName
            }
            if ([string]$status["status"] -eq "ready") {
                $status["status"] = "warning"
                $status["message"] = "Endpoint discovery succeeded, but temporary probe cleanup needs review."
            }
        }

        $status["candidates"] = @($candidateResults | ForEach-Object { $_ })
        $status["checked_at"] = [string](Get-Timestamp)
    }

    return $status
}

function New-ArgoCDWorkloadClusterStatus {
    param(
        [ValidateSet("not_started", "register", "verify")]
        [string]$Mode = "not_started"
    )

    return [ordered]@{
        registered                  = $false
        ready                       = $false
        source_cluster              = "devdeploy-mgmt"
        source_context              = "kind-devdeploy-mgmt"
        source_namespace            = $ArgoCDNamespace
        target_cluster              = "devdeploy-workload"
        target_context              = "kind-devdeploy-workload"
        registration_method         = "launcher-managed-cluster-secret"
        endpoint_strategy           = "not_selected"
        server_endpoint             = $null
        endpoint_tls_verified       = $false
        cluster_secret_present      = $false
        cluster_secret_name         = $ArgoCDWorkloadClusterSecretName
        cluster_secret_label_present = $false
        service_account_namespace   = $ArgoCDWorkloadServiceAccountNamespace
        service_account_name        = $ArgoCDWorkloadServiceAccountName
        service_account_present     = $false
        rbac_mode                    = "scoped-read-only-registration"
        credential_lifecycle        = "local-only-long-lived-service-account-token"
        argocd_visible               = $null
        application_count            = $null
        write_rbac_configured         = $null
        mode                          = $Mode
        status                       = "not_started"
        message                      = "Workload cluster registration has not been requested."
        checked_at                   = [string](Get-Timestamp)
    }
}

function Get-PersistedWorkloadEndpointSelection {
    $result = [ordered]@{
        valid    = $false
        endpoint = ""
        strategy = "not_selected"
        message  = "Run -DiscoverWorkloadClusterEndpoint before registration."
    }

    if (-not (Test-Path -LiteralPath $StatusPath -PathType Leaf)) {
        return $result
    }

    try {
        $document = Get-Content -Raw -LiteralPath $StatusPath | ConvertFrom-Json
        $component = $document.platform_bootstrap.components.workload_cluster_endpoint
        $selectionFromRegistration = $false
        if ($null -eq $component -or -not [bool]$component.ready -or [string]$component.status -notin @("ready", "warning")) {
            $component = $document.platform_bootstrap.components.argocd_workload_cluster
            $selectionFromRegistration = $true
            if ($null -eq $component -or -not [bool]$component.registered -or -not [bool]$component.ready -or -not [bool]$component.endpoint_tls_verified -or [string]$component.status -notin @("ready", "warning")) {
                return $result
            }
        }

        $endpoint = if ($selectionFromRegistration) { [string]$component.server_endpoint } else { [string]$component.selected_endpoint }
        $strategy = if ($selectionFromRegistration) { [string]$component.endpoint_strategy } else { [string]$component.selected_strategy }
        if ([string]::IsNullOrWhiteSpace($endpoint) -or $endpoint -match '^https://(127\.0\.0\.1|localhost):58081/?$') {
            $result["message"] = "The persisted endpoint selection is missing or host-only. Rerun -DiscoverWorkloadClusterEndpoint."
            return $result
        }

        if (-not $selectionFromRegistration) {
            $selectedCandidate = @($component.candidates | Where-Object { [bool]$_.selected }) | Select-Object -First 1
            if ($null -eq $selectedCandidate -or -not [bool]$selectedCandidate.reachable_from_management -or -not [bool]$selectedCandidate.tls_verified) {
                $result["message"] = "The persisted endpoint was not recorded as network- and TLS-verified. Rerun -DiscoverWorkloadClusterEndpoint."
                return $result
            }
        }

        $checkedAt = [DateTime]::MinValue
        if (-not [DateTime]::TryParse([string]$component.checked_at, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$checkedAt)) {
            $result["message"] = "The persisted endpoint timestamp is invalid. Rerun -DiscoverWorkloadClusterEndpoint."
            return $result
        }
        if (([DateTime]::UtcNow - $checkedAt.ToUniversalTime()).TotalHours -gt 24) {
            $result["message"] = "The persisted endpoint discovery is older than 24 hours. Rerun -DiscoverWorkloadClusterEndpoint."
            return $result
        }

        $result["valid"] = $true
        $result["endpoint"] = $endpoint
        $result["strategy"] = $strategy
        $result["message"] = "A fresh, management-reachable, TLS-verified endpoint selection is available."
        return $result
    }
    catch {
        $result["message"] = "The persisted endpoint discovery status could not be parsed safely. Rerun -DiscoverWorkloadClusterEndpoint."
        return $result
    }
}

function Invoke-RegisterWorkloadClusterWithArgoCD {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ManagementCluster,

        [Parameter(Mandatory = $true)]
        [object]$WorkloadCluster,

        [bool]$KindAvailable,

        [bool]$KubectlAvailable,

        [Parameter(Mandatory = $true)]
        [object]$ArgoCDStatus
    )

    $status = New-ArgoCDWorkloadClusterStatus -Mode "register"

    if (-not $KindAvailable -or -not $KubectlAvailable -or [string]$ManagementCluster["status"] -ne "ready" -or [string]$WorkloadCluster["status"] -ne "ready") {
        $status["status"] = "error"
        $status["message"] = "kind, kubectl, devdeploy-mgmt, and devdeploy-workload must be ready before registration."
        Add-Check -Id "argocd_workload_registration_prerequisites" -Label "Argo CD workload registration prerequisites" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required                  = $true
            kind_available            = $KindAvailable
            kubectl_available         = $KubectlAvailable
            management_cluster_status = [string]$ManagementCluster["status"]
            workload_cluster_status   = [string]$WorkloadCluster["status"]
        }
        return $status
    }

    if ([string]$ArgoCDStatus["status"] -notin @("ready", "warning") -or -not [bool]$ArgoCDStatus["installed"]) {
        $status["status"] = "error"
        $status["message"] = "Management Argo CD must be installed and Ready before workload cluster registration."
        Add-Check -Id "argocd_workload_registration_prerequisites" -Label "Argo CD workload registration prerequisites" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required     = $true
            argocd_status = [string]$ArgoCDStatus["status"]
        }
        return $status
    }

    Add-Check -Id "argocd_workload_registration_prerequisites" -Label "Argo CD workload registration prerequisites" -Status "ok" -Message "Both clusters and management Argo CD are ready for explicit registration." -Details @{
        required = $true
    }

    $endpointSelection = Get-PersistedWorkloadEndpointSelection
    if (-not [bool]$endpointSelection["valid"]) {
        $status["status"] = "error"
        $status["message"] = [string]$endpointSelection["message"]
        Add-Check -Id "argocd_workload_registration_endpoint" -Label "Argo CD workload registration endpoint" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required = $true
        }
        return $status
    }

    $selectedEndpoint = [string]$endpointSelection["endpoint"]
    $selectedStrategy = [string]$endpointSelection["strategy"]
    $status["server_endpoint"] = $selectedEndpoint
    $status["endpoint_strategy"] = $selectedStrategy
    $status["endpoint_tls_verified"] = $true
    Add-Check -Id "argocd_workload_registration_endpoint" -Label "Argo CD workload registration endpoint" -Status "ok" -Message "A fresh TLS-verified endpoint selection will be used for registration." -Details @{
        required          = $true
        endpoint_strategy = $selectedStrategy
        server_endpoint   = $selectedEndpoint
        host_loopback     = $false
    }

    $workloadResources = [ordered]@{
        apiVersion = "v1"
        kind       = "List"
        items      = @(
            [ordered]@{
                apiVersion = "v1"
                kind       = "ServiceAccount"
                metadata   = [ordered]@{
                    name      = $ArgoCDWorkloadServiceAccountName
                    namespace = $ArgoCDWorkloadServiceAccountNamespace
                    labels    = [ordered]@{
                        "app.kubernetes.io/managed-by" = "devdeploy-launcher"
                        "devdeploy.io/purpose"         = "argocd-workload-registration"
                    }
                }
            },
            [ordered]@{
                apiVersion = "v1"
                kind       = "Secret"
                metadata   = [ordered]@{
                    name        = $ArgoCDWorkloadTokenSecretName
                    namespace   = $ArgoCDWorkloadServiceAccountNamespace
                    labels      = [ordered]@{
                        "app.kubernetes.io/managed-by" = "devdeploy-launcher"
                        "devdeploy.io/purpose"         = "argocd-workload-registration"
                    }
                    annotations = [ordered]@{
                        "kubernetes.io/service-account.name" = $ArgoCDWorkloadServiceAccountName
                    }
                }
                type       = "kubernetes.io/service-account-token"
            },
            [ordered]@{
                apiVersion = "rbac.authorization.k8s.io/v1"
                kind       = "ClusterRole"
                metadata   = [ordered]@{
                    name   = $ArgoCDWorkloadClusterRoleName
                    labels = [ordered]@{
                        "app.kubernetes.io/managed-by" = "devdeploy-launcher"
                        "devdeploy.io/purpose"         = "argocd-workload-registration"
                        "devdeploy.io/security-scope"  = "read-only-registration"
                    }
                }
                rules      = @(
                    [ordered]@{
                        apiGroups = @("")
                        resources = @("namespaces", "pods", "services", "configmaps", "serviceaccounts", "events")
                        verbs     = @("get", "list", "watch")
                    },
                    [ordered]@{
                        apiGroups = @("apps")
                        resources = @("deployments", "replicasets")
                        verbs     = @("get", "list", "watch")
                    },
                    [ordered]@{
                        apiGroups = @("networking.k8s.io")
                        resources = @("ingresses")
                        verbs     = @("get", "list", "watch")
                    },
                    [ordered]@{
                        apiGroups = @("authorization.k8s.io")
                        resources = @("selfsubjectaccessreviews", "selfsubjectrulesreviews")
                        verbs     = @("create")
                    }
                )
            },
            [ordered]@{
                apiVersion = "rbac.authorization.k8s.io/v1"
                kind       = "ClusterRoleBinding"
                metadata   = [ordered]@{
                    name   = $ArgoCDWorkloadClusterRoleBindingName
                    labels = [ordered]@{
                        "app.kubernetes.io/managed-by" = "devdeploy-launcher"
                        "devdeploy.io/purpose"         = "argocd-workload-registration"
                        "devdeploy.io/security-scope"  = "read-only-registration"
                    }
                }
                roleRef    = [ordered]@{
                    apiGroup = "rbac.authorization.k8s.io"
                    kind     = "ClusterRole"
                    name     = $ArgoCDWorkloadClusterRoleName
                }
                subjects   = @(
                    [ordered]@{
                        kind      = "ServiceAccount"
                        name      = $ArgoCDWorkloadServiceAccountName
                        namespace = $ArgoCDWorkloadServiceAccountNamespace
                    }
                )
            }
        )
    }

    $workloadApplyResult = Invoke-SanitizedInputCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "apply", "--filename", "-") -StandardInput ($workloadResources | ConvertTo-Json -Depth 12 -Compress) -TimeoutSeconds 60
    if ($workloadApplyResult.exit_code -ne 0 -or $workloadApplyResult.timed_out) {
        $status["status"] = "error"
        $status["message"] = "The dedicated workload registration ServiceAccount, token Secret, or RBAC could not be reconciled."
        Add-Check -Id "argocd_workload_registration_identity" -Label "Argo CD workload registration identity" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required = $true
            error    = $workloadApplyResult.stderr
        }
        return $status
    }

    Add-Check -Id "argocd_workload_registration_identity" -Label "Argo CD workload registration identity" -Status "ok" -Message "A dedicated ServiceAccount and read-only registration role were reconciled in devdeploy-workload." -Details @{
        required                  = $false
        service_account_namespace = $ArgoCDWorkloadServiceAccountNamespace
        service_account_name      = $ArgoCDWorkloadServiceAccountName
        cluster_role_name          = $ArgoCDWorkloadClusterRoleName
        rbac_mode                  = "scoped-read-only-registration"
        workload_write_access      = $false
    }
    $status["service_account_present"] = $true

    $tokenData = ""
    $caData = ""
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        $tokenResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "--namespace", $ArgoCDWorkloadServiceAccountNamespace, "get", "secret", $ArgoCDWorkloadTokenSecretName, "--output", "jsonpath={.data.token}") -TimeoutSeconds 15 -PreserveStandardOutput $true
        $caResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "--namespace", $ArgoCDWorkloadServiceAccountNamespace, "get", "secret", $ArgoCDWorkloadTokenSecretName, "--output", "jsonpath={.data.ca\.crt}") -TimeoutSeconds 15 -PreserveStandardOutput $true
        if ($tokenResult.exit_code -eq 0 -and -not $tokenResult.timed_out -and $caResult.exit_code -eq 0 -and -not $caResult.timed_out) {
            $tokenData = ([string]$tokenResult.stdout).Trim()
            $caData = ([string]$caResult.stdout).Trim()
        }
        if (-not [string]::IsNullOrWhiteSpace($tokenData) -and -not [string]::IsNullOrWhiteSpace($caData)) {
            break
        }
        Start-Sleep -Seconds 2
    }

    if ([string]::IsNullOrWhiteSpace($tokenData) -or [string]::IsNullOrWhiteSpace($caData)) {
        $status["status"] = "error"
        $status["message"] = "The local-only ServiceAccount token credential was not populated before timeout. No credential value was printed."
        Add-Check -Id "argocd_workload_registration_credential" -Label "Argo CD workload registration credential" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required = $true
            secret_name = $ArgoCDWorkloadTokenSecretName
        }
        return $status
    }

    $bearerToken = ""
    try {
        $bearerToken = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($tokenData))
    }
    catch {
        $bearerToken = ""
    }
    if ([string]::IsNullOrWhiteSpace($bearerToken)) {
        $status["status"] = "error"
        $status["message"] = "The ServiceAccount token credential could not be decoded in memory."
        Add-Check -Id "argocd_workload_registration_credential" -Label "Argo CD workload registration credential" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required = $true
        }
        return $status
    }

    Add-Check -Id "argocd_workload_registration_credential" -Label "Argo CD workload registration credential" -Status "warning" -Message "A local-only long-lived ServiceAccount token is available in memory for Argo CD registration; its value was not printed or logged." -Details @{
        required                  = $false
        credential_lifecycle      = "local-only-long-lived-service-account-token"
        future_hardening_required = $true
        token_value_logged        = $false
    }

    $configObject = [ordered]@{
        bearerToken    = $bearerToken
        tlsClientConfig = [ordered]@{
            insecure = $false
            caData   = $caData
        }
    }
    $clusterSecretManifest = [ordered]@{
        apiVersion = "v1"
        kind       = "Secret"
        metadata   = [ordered]@{
            name      = $ArgoCDWorkloadClusterSecretName
            namespace = $ArgoCDNamespace
            labels    = [ordered]@{
                "argocd.argoproj.io/secret-type" = "cluster"
                "app.kubernetes.io/managed-by"   = "devdeploy-launcher"
                "devdeploy.io/purpose"           = "workload-cluster-registration"
            }
        }
        type       = "Opaque"
        stringData = [ordered]@{
            name             = "devdeploy-workload"
            server           = $selectedEndpoint
            namespaces       = "devdeploy-workloads"
            clusterResources = "false"
            config           = ($configObject | ConvertTo-Json -Depth 6 -Compress)
        }
    }

    $clusterSecretApplyResult = Invoke-SanitizedInputCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "apply", "--filename", "-") -StandardInput ($clusterSecretManifest | ConvertTo-Json -Depth 12 -Compress) -TimeoutSeconds 60
    $bearerToken = ""
    $tokenData = ""
    $caData = ""
    $configObject = $null
    $clusterSecretManifest = $null
    if ($clusterSecretApplyResult.exit_code -ne 0 -or $clusterSecretApplyResult.timed_out) {
        $status["status"] = "error"
        $status["message"] = "The launcher-managed Argo CD workload cluster Secret could not be reconciled."
        Add-Check -Id "argocd_workload_registration_cluster_secret" -Label "Argo CD workload cluster Secret" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required = $true
            secret_name = $ArgoCDWorkloadClusterSecretName
            error = $clusterSecretApplyResult.stderr
        }
        return $status
    }

    $secretNameResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", "secret", $ArgoCDWorkloadClusterSecretName, "--output", "name") -TimeoutSeconds 20
    $secretLabelResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", "secret", $ArgoCDWorkloadClusterSecretName, "--output", "jsonpath={.metadata.labels.argocd\.argoproj\.io/secret-type}") -TimeoutSeconds 20
    $secretServerResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", "secret", $ArgoCDWorkloadClusterSecretName, "--output", "jsonpath={.data.server}") -TimeoutSeconds 20 -PreserveStandardOutput $true
    $secretPresent = [bool]($secretNameResult.exit_code -eq 0 -and -not $secretNameResult.timed_out)
    $labelPresent = [bool]($secretLabelResult.exit_code -eq 0 -and -not $secretLabelResult.timed_out -and ([string]$secretLabelResult.stdout).Trim() -eq "cluster")
    $storedServer = ""
    try {
        $storedServer = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(([string]$secretServerResult.stdout).Trim()))
    }
    catch {
        $storedServer = ""
    }
    $serverMatches = [bool]($secretServerResult.exit_code -eq 0 -and -not $secretServerResult.timed_out -and $storedServer -eq $selectedEndpoint)

    $status["cluster_secret_present"] = $secretPresent
    $status["cluster_secret_label_present"] = $labelPresent
    $status["argocd_visible"] = [bool]($secretPresent -and $labelPresent)
    Add-Check -Id "argocd_workload_registration_cluster_secret" -Label "Argo CD workload cluster Secret" -Status $(if ($secretPresent -and $labelPresent -and $serverMatches) { "ok" } else { "failed" }) -Message $(if ($secretPresent -and $labelPresent -and $serverMatches) { "The launcher-managed cluster Secret exists with the expected label and endpoint." } else { "The launcher-managed cluster Secret metadata or endpoint verification failed." }) -Details @{
        required            = $true
        secret_name         = $ArgoCDWorkloadClusterSecretName
        secret_present      = $secretPresent
        label_present       = $labelPresent
        server_matches      = $serverMatches
        sensitive_config_read = $false
    }

    $rbacReadResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "auth", "can-i", "get", "namespaces", "--as", "system:serviceaccount:${ArgoCDWorkloadServiceAccountNamespace}:${ArgoCDWorkloadServiceAccountName}") -TimeoutSeconds 20
    $rbacWriteResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "auth", "can-i", "create", "deployments.apps", "--all-namespaces", "--as", "system:serviceaccount:${ArgoCDWorkloadServiceAccountNamespace}:${ArgoCDWorkloadServiceAccountName}") -TimeoutSeconds 20
    $rbacReadReady = [bool]($rbacReadResult.exit_code -eq 0 -and -not $rbacReadResult.timed_out -and ([string]$rbacReadResult.stdout).Trim() -eq "yes")
    # kubectl auth can-i returns exit code 1 when the answer is "no".
    $rbacWriteDenied = [bool](-not $rbacWriteResult.timed_out -and ([string]$rbacWriteResult.stdout).Trim() -eq "no")
    $rbacReady = [bool]($rbacReadReady -and $rbacWriteDenied)
    Add-Check -Id "argocd_workload_registration_rbac" -Label "Argo CD workload registration RBAC" -Status $(if ($rbacReady) { "ok" } else { "failed" }) -Message $(if ($rbacReady) { "The dedicated ServiceAccount has registration read access and no workload deployment write access." } else { "The dedicated ServiceAccount did not pass the expected read-only authorization checks." }) -Details @{
        required                  = $true
        rbac_mode                  = "scoped-read-only-registration"
        registration_read_access  = $rbacReadReady
        workload_write_denied      = $rbacWriteDenied
        future_deploy_rbac_required = $true
    }

    $applicationsResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", "applications.argoproj.io", "--output", "jsonpath={.items[*].metadata.name}") -TimeoutSeconds 20
    $applicationCountKnown = [bool]($applicationsResult.exit_code -eq 0 -and -not $applicationsResult.timed_out)
    if ($applicationCountKnown) {
        $applicationNames = @(([string]$applicationsResult.stdout) -split "\s+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $status["application_count"] = [int]$applicationNames.Count
    }

    $registrationReady = [bool]($secretPresent -and $labelPresent -and $serverMatches -and $rbacReady)
    $status["registered"] = $registrationReady
    $status["ready"] = $registrationReady
    $status["write_rbac_configured"] = [bool](-not $rbacWriteDenied)
    $status["checked_at"] = [string](Get-Timestamp)
    if ($registrationReady) {
        $status["status"] = "warning"
        $status["message"] = "devdeploy-workload is registered through a launcher-managed Argo CD cluster Secret with read-only registration credentials. No Application was created; workload write RBAC remains a future step."
    }
    else {
        $status["status"] = "error"
        $status["message"] = "Workload cluster registration did not pass all required metadata and authorization checks."
    }

    Add-Check -Id "argocd_workload_registration_ready" -Label "Argo CD workload cluster registration" -Status $(if ($registrationReady) { "warning" } else { "failed" }) -Message ([string]$status["message"]) -Details @{
        required                  = [bool](-not $registrationReady)
        application_count         = $status["application_count"]
        application_created       = $false
        rbac_mode                  = "scoped-read-only-registration"
        workload_write_access      = $false
        future_deploy_rbac_required = $true
    }

    return $status
}

function Invoke-VerifyWorkloadClusterRegistration {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ManagementCluster,

        [Parameter(Mandatory = $true)]
        [object]$WorkloadCluster,

        [bool]$KindAvailable,

        [bool]$KubectlAvailable,

        [Parameter(Mandatory = $true)]
        [object]$ArgoCDStatus
    )

    $status = New-ArgoCDWorkloadClusterStatus -Mode "verify"

    if (-not $KindAvailable -or -not $KubectlAvailable -or [string]$ManagementCluster["status"] -ne "ready" -or [string]$WorkloadCluster["status"] -ne "ready") {
        $status["status"] = "error"
        $status["message"] = "kind, kubectl, devdeploy-mgmt, and devdeploy-workload must be ready for read-only registration verification."
        Add-Check -Id "argocd_workload_verify_prerequisites" -Label "Argo CD workload registration verification prerequisites" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required                  = $true
            kind_available            = $KindAvailable
            kubectl_available         = $KubectlAvailable
            management_cluster_status = [string]$ManagementCluster["status"]
            workload_cluster_status   = [string]$WorkloadCluster["status"]
            read_only                 = $true
        }
        return $status
    }

    if ([string]$ArgoCDStatus["status"] -notin @("ready", "warning") -or -not [bool]$ArgoCDStatus["installed"]) {
        $status["status"] = "error"
        $status["message"] = "Management Argo CD must be installed and Ready for registration verification."
        Add-Check -Id "argocd_workload_verify_prerequisites" -Label "Argo CD workload registration verification prerequisites" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required      = $true
            argocd_status = [string]$ArgoCDStatus["status"]
            read_only     = $true
        }
        return $status
    }

    Add-Check -Id "argocd_workload_verify_prerequisites" -Label "Argo CD workload registration verification prerequisites" -Status "ok" -Message "Both clusters and management Argo CD are ready for read-only registration verification." -Details @{
        required  = $true
        read_only = $true
    }

    $persistedEndpoint = Get-PersistedWorkloadEndpointSelection
    $endpointTlsVerified = $null
    if ([bool]$persistedEndpoint["valid"] -and [string]$persistedEndpoint["endpoint"] -eq $ExpectedWorkloadArgoCDEndpoint -and [string]$persistedEndpoint["strategy"] -eq "docker_network_control_plane") {
        $endpointTlsVerified = $true
    }

    $secretNameResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", "secret", $ArgoCDWorkloadClusterSecretName, "--output", "name") -TimeoutSeconds 20
    $secretTypeResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", "secret", $ArgoCDWorkloadClusterSecretName, "--output", "jsonpath={.type}") -TimeoutSeconds 20
    $secretLabelResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", "secret", $ArgoCDWorkloadClusterSecretName, "--output", "jsonpath={.metadata.labels.argocd\.argoproj\.io/secret-type}") -TimeoutSeconds 20
    $secretClusterNameResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", "secret", $ArgoCDWorkloadClusterSecretName, "--output", "jsonpath={.data.name}") -TimeoutSeconds 20 -PreserveStandardOutput $true
    $secretServerResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", "secret", $ArgoCDWorkloadClusterSecretName, "--output", "jsonpath={.data.server}") -TimeoutSeconds 20 -PreserveStandardOutput $true

    $secretPresent = [bool]($secretNameResult.exit_code -eq 0 -and -not $secretNameResult.timed_out)
    $secretTypeValid = [bool]($secretTypeResult.exit_code -eq 0 -and -not $secretTypeResult.timed_out -and ([string]$secretTypeResult.stdout).Trim() -eq "Opaque")
    $secretLabelPresent = [bool]($secretLabelResult.exit_code -eq 0 -and -not $secretLabelResult.timed_out -and ([string]$secretLabelResult.stdout).Trim() -eq "cluster")
    $storedClusterName = ""
    $storedServer = ""
    try {
        $storedClusterName = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(([string]$secretClusterNameResult.stdout).Trim()))
        $storedServer = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(([string]$secretServerResult.stdout).Trim()))
    }
    catch {
        $storedClusterName = ""
        $storedServer = ""
    }

    $clusterNameMatches = [bool]($secretClusterNameResult.exit_code -eq 0 -and -not $secretClusterNameResult.timed_out -and $storedClusterName -eq "devdeploy-workload")
    $endpointMatches = [bool]($secretServerResult.exit_code -eq 0 -and -not $secretServerResult.timed_out -and $storedServer -eq $ExpectedWorkloadArgoCDEndpoint)
    $endpointIsHostLoopback = [bool]($storedServer -match '^https://(127\.0\.0\.1|localhost)(:\d+)?/?$')
    $secretContractReady = [bool]($secretPresent -and $secretTypeValid -and $secretLabelPresent -and $clusterNameMatches -and $endpointMatches -and -not $endpointIsHostLoopback)

    $status["cluster_secret_present"] = $secretPresent
    $status["cluster_secret_label_present"] = $secretLabelPresent
    $status["server_endpoint"] = if ([string]::IsNullOrWhiteSpace($storedServer)) { $null } else { $storedServer }
    $status["endpoint_strategy"] = if ($endpointMatches) { "docker_network_control_plane" } else { "not_selected" }
    $status["endpoint_tls_verified"] = $endpointTlsVerified

    Add-Check -Id "argocd_workload_verify_cluster_secret" -Label "Argo CD workload cluster Secret verification" -Status $(if ($secretContractReady) { "ok" } else { "failed" }) -Message $(if ($secretContractReady) { "The launcher-managed cluster Secret has the expected public contract and non-loopback endpoint." } else { "The launcher-managed cluster Secret is missing or its public contract does not match the expected registration." }) -Details @{
        required             = $true
        secret_name          = $ArgoCDWorkloadClusterSecretName
        secret_present       = $secretPresent
        secret_type_valid    = $secretTypeValid
        label_present        = $secretLabelPresent
        cluster_name_matches = $clusterNameMatches
        endpoint_matches     = $endpointMatches
        host_loopback        = $endpointIsHostLoopback
        config_read          = $false
        read_only            = $true
    }

    Add-Check -Id "argocd_workload_verify_endpoint" -Label "Argo CD workload endpoint verification" -Status $(if ($endpointMatches -and -not $endpointIsHostLoopback) { if ($endpointTlsVerified -eq $true) { "ok" } else { "warning" } } else { "failed" }) -Message $(if (-not $endpointMatches -or $endpointIsHostLoopback) { "The registered endpoint is missing, unexpected, or host-loopback based." } elseif ($endpointTlsVerified -eq $true) { "The registered Docker-network endpoint matches fresh persisted TLS verification provenance." } else { "The registered endpoint is correct and non-loopback; current TLS provenance is unavailable without a mutating probe." }) -Details @{
        required              = [bool](-not ($endpointMatches -and -not $endpointIsHostLoopback))
        endpoint_strategy     = [string]$status["endpoint_strategy"]
        server_endpoint       = [string]$status["server_endpoint"]
        endpoint_tls_verified = $endpointTlsVerified
        read_only             = $true
    }

    $serviceAccountResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "--namespace", $ArgoCDWorkloadServiceAccountNamespace, "get", "serviceaccount", $ArgoCDWorkloadServiceAccountName, "--output", "name") -TimeoutSeconds 20
    $clusterRoleScopeResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "get", "clusterrole", $ArgoCDWorkloadClusterRoleName, "--output", "jsonpath={.metadata.labels.devdeploy\.io/security-scope}") -TimeoutSeconds 20
    $bindingRoleResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "get", "clusterrolebinding", $ArgoCDWorkloadClusterRoleBindingName, "--output", "jsonpath={.roleRef.name}") -TimeoutSeconds 20
    $bindingSubjectResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "get", "clusterrolebinding", $ArgoCDWorkloadClusterRoleBindingName, "--output", "jsonpath={.subjects[0].namespace}/{.subjects[0].name}") -TimeoutSeconds 20
    $tokenSecretTypeResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "--namespace", $ArgoCDWorkloadServiceAccountNamespace, "get", "secret", $ArgoCDWorkloadTokenSecretName, "--output", "jsonpath={.type}") -TimeoutSeconds 20

    $serviceAccountPresent = [bool]($serviceAccountResult.exit_code -eq 0 -and -not $serviceAccountResult.timed_out)
    $clusterRoleValid = [bool]($clusterRoleScopeResult.exit_code -eq 0 -and -not $clusterRoleScopeResult.timed_out -and ([string]$clusterRoleScopeResult.stdout).Trim() -eq "read-only-registration")
    $bindingValid = [bool]($bindingRoleResult.exit_code -eq 0 -and -not $bindingRoleResult.timed_out -and ([string]$bindingRoleResult.stdout).Trim() -eq $ArgoCDWorkloadClusterRoleName -and $bindingSubjectResult.exit_code -eq 0 -and -not $bindingSubjectResult.timed_out -and ([string]$bindingSubjectResult.stdout).Trim() -eq "${ArgoCDWorkloadServiceAccountNamespace}/${ArgoCDWorkloadServiceAccountName}")
    $credentialMetadataPresent = [bool]($tokenSecretTypeResult.exit_code -eq 0 -and -not $tokenSecretTypeResult.timed_out -and ([string]$tokenSecretTypeResult.stdout).Trim() -eq "kubernetes.io/service-account-token")
    $identityReady = [bool]($serviceAccountPresent -and $clusterRoleValid -and $bindingValid -and $credentialMetadataPresent)
    $status["service_account_present"] = $serviceAccountPresent

    Add-Check -Id "argocd_workload_verify_identity" -Label "Argo CD workload registration identity verification" -Status $(if ($identityReady) { "ok" } else { "failed" }) -Message $(if ($identityReady) { "The dedicated ServiceAccount, credential metadata, read-only ClusterRole, and binding are present." } else { "One or more dedicated registration identity or RBAC metadata checks failed." }) -Details @{
        required                    = $true
        service_account_present     = $serviceAccountPresent
        credential_metadata_present = $credentialMetadataPresent
        cluster_role_valid          = $clusterRoleValid
        cluster_role_binding_valid  = $bindingValid
        rbac_mode                    = "scoped-read-only-registration"
        secret_data_read            = $false
        read_only                   = $true
    }

    $rbacReadResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "auth", "can-i", "get", "namespaces", "--as", "system:serviceaccount:${ArgoCDWorkloadServiceAccountNamespace}:${ArgoCDWorkloadServiceAccountName}") -TimeoutSeconds 20
    $deploymentWriteResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "auth", "can-i", "create", "deployments.apps", "--all-namespaces", "--as", "system:serviceaccount:${ArgoCDWorkloadServiceAccountNamespace}:${ArgoCDWorkloadServiceAccountName}") -TimeoutSeconds 20
    $serviceWriteResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "auth", "can-i", "create", "services", "--all-namespaces", "--as", "system:serviceaccount:${ArgoCDWorkloadServiceAccountNamespace}:${ArgoCDWorkloadServiceAccountName}") -TimeoutSeconds 20
    $ingressWriteResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "auth", "can-i", "create", "ingresses.networking.k8s.io", "--all-namespaces", "--as", "system:serviceaccount:${ArgoCDWorkloadServiceAccountNamespace}:${ArgoCDWorkloadServiceAccountName}") -TimeoutSeconds 20
    $rbacReadReady = [bool]($rbacReadResult.exit_code -eq 0 -and -not $rbacReadResult.timed_out -and ([string]$rbacReadResult.stdout).Trim() -eq "yes")
    $deploymentWriteDenied = [bool](-not $deploymentWriteResult.timed_out -and ([string]$deploymentWriteResult.stdout).Trim() -eq "no")
    $serviceWriteDenied = [bool](-not $serviceWriteResult.timed_out -and ([string]$serviceWriteResult.stdout).Trim() -eq "no")
    $ingressWriteDenied = [bool](-not $ingressWriteResult.timed_out -and ([string]$ingressWriteResult.stdout).Trim() -eq "no")
    $rbacWriteDenied = [bool]($deploymentWriteDenied -and $serviceWriteDenied -and $ingressWriteDenied)
    $rbacBoundaryReady = [bool]($rbacReadReady -and $rbacWriteDenied)
    $status["write_rbac_configured"] = [bool](-not $rbacWriteDenied)

    Add-Check -Id "argocd_workload_verify_rbac_boundary" -Label "Argo CD workload registration RBAC boundary" -Status $(if ($rbacBoundaryReady) { "ok" } else { "failed" }) -Message $(if ($rbacBoundaryReady) { "Registration read access is present and workload Deployment creation remains denied." } else { "The expected read-only registration authorization boundary was not verified." }) -Details @{
        required                 = $true
        registration_read_access = $rbacReadReady
        write_rbac_configured     = [bool]$status["write_rbac_configured"]
        deployment_write_denied   = $deploymentWriteDenied
        service_write_denied      = $serviceWriteDenied
        ingress_write_denied      = $ingressWriteDenied
        read_only                 = $true
    }

    $applicationsResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", "applications.argoproj.io", "--output", "jsonpath={.items[*].metadata.name}") -TimeoutSeconds 20
    $applicationCountKnown = [bool]($applicationsResult.exit_code -eq 0 -and -not $applicationsResult.timed_out)
    if ($applicationCountKnown) {
        $applicationNames = @(([string]$applicationsResult.stdout) -split "\s+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $status["application_count"] = [int]$applicationNames.Count
    }

    Add-Check -Id "argocd_workload_verify_applications" -Label "Argo CD Application inventory" -Status $(if ($applicationCountKnown) { "ok" } else { "failed" }) -Message $(if ($applicationCountKnown) { "Argo CD Application inventory was read without creating or modifying Applications." } else { "Argo CD Application inventory could not be read." }) -Details @{
        required            = $true
        application_count   = $status["application_count"]
        application_created = $false
        read_only           = $true
    }

    $controllerLogsResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "logs", "statefulset/argocd-application-controller", "--since=24h") -TimeoutSeconds 30 -PreserveStandardOutput $true
    $argocdVisible = $null
    if ($controllerLogsResult.exit_code -eq 0 -and -not $controllerLogsResult.timed_out) {
        $argocdVisible = [bool](([string]$controllerLogsResult.stdout) -match [regex]::Escape("Cluster $ExpectedWorkloadArgoCDEndpoint has been assigned to shard"))
    }
    if ($argocdVisible -ne $true -and $secretContractReady) {
        $argocdVisible = $null
    }
    $status["argocd_visible"] = $argocdVisible

    Add-Check -Id "argocd_workload_verify_visibility" -Label "Argo CD workload cluster visibility" -Status $(if ($argocdVisible -eq $true) { "ok" } elseif ($secretContractReady) { "warning" } else { "failed" }) -Message $(if ($argocdVisible -eq $true) { "Argo CD controller logs confirm that the registered endpoint was assigned to a controller shard." } elseif ($secretContractReady) { "The Argo CD cluster Secret contract is valid, but controller visibility could not be confirmed from current logs." } else { "Argo CD workload cluster visibility could not be verified." }) -Details @{
        required        = [bool](-not $secretContractReady)
        argocd_visible  = $argocdVisible
        evidence_source = if ($argocdVisible -eq $true) { "application-controller-log" } else { "cluster-secret-metadata" }
        read_only       = $true
    }

    $verificationReady = [bool]($secretContractReady -and $identityReady -and $rbacBoundaryReady -and $applicationCountKnown)
    $status["registered"] = $verificationReady
    $status["ready"] = $verificationReady
    $status["checked_at"] = [string](Get-Timestamp)
    if ($verificationReady) {
        $status["status"] = "warning"
        $status["message"] = "Workload cluster registration is verified. No Application exists yet, and workload write RBAC remains a future step."
    }
    else {
        $status["status"] = "error"
        $status["message"] = "Workload cluster registration did not pass all required read-only verification checks."
    }

    Add-Check -Id "argocd_workload_verify_ready" -Label "Argo CD workload cluster registration verification" -Status $(if ($verificationReady) { "warning" } else { "failed" }) -Message ([string]$status["message"]) -Details @{
        required                  = [bool](-not $verificationReady)
        application_count         = $status["application_count"]
        application_created       = $false
        write_rbac_configured      = [bool]$status["write_rbac_configured"]
        endpoint_tls_verified      = $status["endpoint_tls_verified"]
        rbac_mode                  = "scoped-read-only-registration"
        verification_mutated_state = $false
    }

    return $status
}

function New-WorkloadDeployPermissionsStatus {
    param(
        [ValidateSet("not_started", "grant", "verify")]
        [string]$Mode = "not_started"
    )

    return [ordered]@{
        granted                            = $false
        ready                              = $false
        target_cluster                     = "devdeploy-workload"
        target_context                     = "kind-devdeploy-workload"
        managed_namespace                  = $WorkloadManagedNamespace
        namespace_present                  = $false
        service_account_namespace          = $ArgoCDWorkloadServiceAccountNamespace
        service_account_name               = $ArgoCDWorkloadServiceAccountName
        service_account_present            = $false
        rbac_scope                         = "namespace"
        role_name                          = $WorkloadDeployRoleName
        role_present                       = $false
        role_binding_name                  = $WorkloadDeployRoleBindingName
        role_binding_present               = $false
        role_binding_subject_valid         = $false
        role_binding_ref_valid             = $false
        cluster_admin                      = $null
        write_rbac_configured              = $false
        read_scope                         = "namespace-read-all"
        write_scope                        = "namespace-workload-allowlist"
        can_read_managed_namespace_resources = $null
        can_write_managed_namespace        = $null
        can_write_outside_managed_namespace = $null
        can_manage_rbac                    = $null
        can_manage_crds                    = $null
        can_manage_namespaces              = $null
        application_count                  = $null
        mode                               = $Mode
        allowed_resource_groups            = @("*")
        read_resource_groups               = @("*")
        read_resources_summary             = @("*")
        write_resource_groups              = @("", "apps", "networking.k8s.io", "batch", "autoscaling", "policy")
        write_resources_summary             = @(
            "services", "configmaps", "secrets", "serviceaccounts", "persistentvolumeclaims",
            "deployments", "statefulsets", "daemonsets", "ingresses", "jobs", "cronjobs",
            "horizontalpodautoscalers", "poddisruptionbudgets"
        )
        allowed_resources_summary          = @(
            "read:*",
            "write:services", "write:configmaps", "write:secrets", "write:serviceaccounts", "write:persistentvolumeclaims",
            "write:deployments", "write:statefulsets", "write:daemonsets", "write:ingresses", "write:jobs", "write:cronjobs",
            "write:horizontalpodautoscalers", "write:poddisruptionbudgets"
        )
        status                              = "not_started"
        message                             = "Workload deployment permissions have not been granted."
        checked_at                          = [string](Get-Timestamp)
    }
}

function Get-KubectlAuthorizationDecision {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Verb,

        [Parameter(Mandatory = $true)]
        [string]$Resource,

        [string]$Namespace = ""
    )

    $arguments = New-Object System.Collections.Generic.List[string]
    foreach ($argument in @("--context", "kind-devdeploy-workload", "auth", "can-i", $Verb, $Resource)) {
        $arguments.Add([string]$argument) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($Namespace)) {
        $arguments.Add("--namespace") | Out-Null
        $arguments.Add($Namespace) | Out-Null
    }
    $arguments.Add("--as") | Out-Null
    $arguments.Add("system:serviceaccount:${ArgoCDWorkloadServiceAccountNamespace}:${ArgoCDWorkloadServiceAccountName}") | Out-Null

    $result = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @($arguments | ForEach-Object { $_ }) -TimeoutSeconds 20
    $answer = ([string]$result.stdout).Trim().ToLowerInvariant()
    return [ordered]@{
        known   = [bool](-not $result.timed_out -and $answer -in @("yes", "no"))
        allowed = if ($answer -eq "yes") { $true } elseif ($answer -eq "no") { $false } else { $null }
    }
}

function Invoke-GrantWorkloadDeployPermissions {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ManagementCluster,

        [Parameter(Mandatory = $true)]
        [object]$WorkloadCluster,

        [bool]$KubectlAvailable,

        [Parameter(Mandatory = $true)]
        [object]$RegistrationStatus
    )

    $status = New-WorkloadDeployPermissionsStatus -Mode "grant"
    if (-not $KubectlAvailable -or [string]$ManagementCluster["status"] -ne "ready" -or [string]$WorkloadCluster["status"] -ne "ready" -or -not [bool]$RegistrationStatus["registered"] -or -not [bool]$RegistrationStatus["ready"]) {
        $status["status"] = "error"
        $status["message"] = "Both clusters and the existing Argo CD workload registration must be ready before granting deploy permissions."
        Add-Check -Id "workload_deploy_permissions_prerequisites" -Label "Workload deploy permission prerequisites" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required                    = $true
            kubectl_available           = $KubectlAvailable
            management_cluster_status   = [string]$ManagementCluster["status"]
            workload_cluster_status     = [string]$WorkloadCluster["status"]
            registration_status         = [string]$RegistrationStatus["status"]
        }
        return $status
    }

    Add-Check -Id "workload_deploy_permissions_prerequisites" -Label "Workload deploy permission prerequisites" -Status "ok" -Message "Both clusters and the existing read-only Argo CD registration are ready." -Details @{
        required          = $true
        target_cluster    = "devdeploy-workload"
        managed_namespace = $WorkloadManagedNamespace
    }

    $writeVerbs = @("get", "list", "watch", "create", "update", "patch", "delete")
    $readVerbs = @("get", "list", "watch")
    $permissionResources = [ordered]@{
        apiVersion = "v1"
        kind       = "List"
        items      = @(
            [ordered]@{
                apiVersion = "v1"
                kind       = "Namespace"
                metadata   = [ordered]@{
                    name   = $WorkloadManagedNamespace
                    labels = [ordered]@{
                        "app.kubernetes.io/managed-by" = "devdeploy-launcher"
                        "devdeploy.io/purpose"         = "gitops-workloads"
                    }
                }
            },
            [ordered]@{
                apiVersion = "rbac.authorization.k8s.io/v1"
                kind       = "Role"
                metadata   = [ordered]@{
                    name      = $WorkloadDeployRoleName
                    namespace = $WorkloadManagedNamespace
                    labels    = [ordered]@{
                        "app.kubernetes.io/managed-by" = "devdeploy-launcher"
                        "devdeploy.io/purpose"         = "gitops-workload-deploy"
                        "devdeploy.io/security-scope"  = "namespace-write"
                    }
                }
                rules      = @(
                    [ordered]@{ apiGroups = @("*"); resources = @("*"); verbs = $readVerbs },
                    [ordered]@{ apiGroups = @(""); resources = @("services", "configmaps", "secrets", "serviceaccounts", "persistentvolumeclaims"); verbs = $writeVerbs },
                    [ordered]@{ apiGroups = @("apps"); resources = @("deployments", "statefulsets", "daemonsets"); verbs = $writeVerbs },
                    [ordered]@{ apiGroups = @("networking.k8s.io"); resources = @("ingresses"); verbs = $writeVerbs },
                    [ordered]@{ apiGroups = @("batch"); resources = @("jobs", "cronjobs"); verbs = $writeVerbs },
                    [ordered]@{ apiGroups = @("autoscaling"); resources = @("horizontalpodautoscalers"); verbs = $writeVerbs },
                    [ordered]@{ apiGroups = @("policy"); resources = @("poddisruptionbudgets"); verbs = $writeVerbs }
                )
            },
            [ordered]@{
                apiVersion = "rbac.authorization.k8s.io/v1"
                kind       = "RoleBinding"
                metadata   = [ordered]@{
                    name      = $WorkloadDeployRoleBindingName
                    namespace = $WorkloadManagedNamespace
                    labels    = [ordered]@{
                        "app.kubernetes.io/managed-by" = "devdeploy-launcher"
                        "devdeploy.io/purpose"         = "gitops-workload-deploy"
                        "devdeploy.io/security-scope"  = "namespace-write"
                    }
                }
                roleRef    = [ordered]@{
                    apiGroup = "rbac.authorization.k8s.io"
                    kind     = "Role"
                    name     = $WorkloadDeployRoleName
                }
                subjects   = @(
                    [ordered]@{
                        kind      = "ServiceAccount"
                        name      = $ArgoCDWorkloadServiceAccountName
                        namespace = $ArgoCDWorkloadServiceAccountNamespace
                    }
                )
            }
        )
    }

    $applyResult = Invoke-SanitizedInputCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "apply", "--filename", "-") -StandardInput ($permissionResources | ConvertTo-Json -Depth 14 -Compress) -TimeoutSeconds 60
    if ($applyResult.exit_code -ne 0 -or $applyResult.timed_out) {
        $status["status"] = "error"
        $status["message"] = "Namespace-scoped workload deploy permissions could not be reconciled."
        Add-Check -Id "workload_deploy_permissions_reconcile" -Label "Workload deploy permission reconciliation" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required = $true
            error    = $applyResult.stderr
        }
        return $status
    }

    Add-Check -Id "workload_deploy_permissions_reconcile" -Label "Workload deploy permission reconciliation" -Status "ok" -Message "Launcher-owned namespace and namespaced deploy Role/RoleBinding were reconciled." -Details @{
        required          = $true
        managed_namespace = $WorkloadManagedNamespace
        role_name         = $WorkloadDeployRoleName
        role_binding_name = $WorkloadDeployRoleBindingName
        cluster_wide_write = $false
    }

    $scopePatch = [ordered]@{
        stringData = [ordered]@{
            namespaces       = $WorkloadManagedNamespace
            clusterResources = "false"
        }
    }
    $scopePatchPath = Join-Path $StatusDir "argocd-workload-scope-patch.json"
    try {
        $scopePatch | ConvertTo-Json -Depth 5 -Compress | Set-Content -LiteralPath $scopePatchPath -Encoding UTF8
        $scopePatchResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "patch", "secret", $ArgoCDWorkloadClusterSecretName, "--type", "merge", "--patch-file", $scopePatchPath) -TimeoutSeconds 30
    }
    finally {
        if (Test-Path -LiteralPath $scopePatchPath -PathType Leaf) {
            Remove-Item -LiteralPath $scopePatchPath -Force
        }
    }
    if ($scopePatchResult.exit_code -ne 0 -or $scopePatchResult.timed_out) {
        $status["status"] = "error"
        $status["message"] = "The Argo CD cluster Secret namespace scope could not be aligned with devdeploy-apps."
        Add-Check -Id "workload_deploy_permissions_cluster_scope" -Label "Argo CD workload cluster namespace scope" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required = $true
            error    = $scopePatchResult.stderr
        }
        return $status
    }

    $namespaceResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "get", "namespace", $WorkloadManagedNamespace, "--output", "name") -TimeoutSeconds 20
    $roleResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "--namespace", $WorkloadManagedNamespace, "get", "role", $WorkloadDeployRoleName, "--output", "name") -TimeoutSeconds 20
    $bindingRoleResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "--namespace", $WorkloadManagedNamespace, "get", "rolebinding", $WorkloadDeployRoleBindingName, "--output", "jsonpath={.roleRef.kind}/{.roleRef.name}") -TimeoutSeconds 20
    $bindingSubjectResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "--namespace", $WorkloadManagedNamespace, "get", "rolebinding", $WorkloadDeployRoleBindingName, "--output", "jsonpath={.subjects[0].kind}/{.subjects[0].namespace}/{.subjects[0].name}") -TimeoutSeconds 20
    $scopeNamespacesResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", "secret", $ArgoCDWorkloadClusterSecretName, "--output", "jsonpath={.data.namespaces}") -TimeoutSeconds 20 -PreserveStandardOutput $true
    $scopeClusterResourcesResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", "secret", $ArgoCDWorkloadClusterSecretName, "--output", "jsonpath={.data.clusterResources}") -TimeoutSeconds 20 -PreserveStandardOutput $true

    $namespacePresent = [bool]($namespaceResult.exit_code -eq 0 -and -not $namespaceResult.timed_out)
    $rolePresent = [bool]($roleResult.exit_code -eq 0 -and -not $roleResult.timed_out)
    $roleBindingPresent = [bool]($bindingRoleResult.exit_code -eq 0 -and -not $bindingRoleResult.timed_out -and ([string]$bindingRoleResult.stdout).Trim() -eq "Role/$WorkloadDeployRoleName" -and $bindingSubjectResult.exit_code -eq 0 -and -not $bindingSubjectResult.timed_out -and ([string]$bindingSubjectResult.stdout).Trim() -eq "ServiceAccount/${ArgoCDWorkloadServiceAccountNamespace}/${ArgoCDWorkloadServiceAccountName}")
    $storedScopeNamespace = ""
    $storedClusterResources = ""
    try {
        $storedScopeNamespace = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(([string]$scopeNamespacesResult.stdout).Trim()))
        $storedClusterResources = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(([string]$scopeClusterResourcesResult.stdout).Trim()))
    }
    catch {
        $storedScopeNamespace = ""
        $storedClusterResources = ""
    }
    $clusterScopeReady = [bool]($storedScopeNamespace -eq $WorkloadManagedNamespace -and $storedClusterResources -eq "false")

    $status["namespace_present"] = $namespacePresent
    $status["role_present"] = $rolePresent
    $status["role_binding_present"] = $roleBindingPresent
    $status["service_account_present"] = [bool]$RegistrationStatus["service_account_present"]
    $status["role_binding_subject_valid"] = $roleBindingPresent
    $status["role_binding_ref_valid"] = $roleBindingPresent
    Add-Check -Id "workload_deploy_permissions_metadata" -Label "Workload deploy permission metadata" -Status $(if ($namespacePresent -and $rolePresent -and $roleBindingPresent -and $clusterScopeReady) { "ok" } else { "failed" }) -Message $(if ($namespacePresent -and $rolePresent -and $roleBindingPresent -and $clusterScopeReady) { "Namespace, namespaced RBAC, and Argo CD namespace scope match the V1 contract." } else { "Namespace, RBAC, or Argo CD namespace scope verification failed." }) -Details @{
        required                   = $true
        namespace_present          = $namespacePresent
        role_present               = $rolePresent
        role_binding_present       = $roleBindingPresent
        cluster_secret_scope_ready = $clusterScopeReady
        secret_config_read         = $false
    }

    $managedChecks = @(
        Get-KubectlAuthorizationDecision -Verb "create" -Resource "deployments.apps" -Namespace $WorkloadManagedNamespace
        Get-KubectlAuthorizationDecision -Verb "create" -Resource "services" -Namespace $WorkloadManagedNamespace
        Get-KubectlAuthorizationDecision -Verb "create" -Resource "ingresses.networking.k8s.io" -Namespace $WorkloadManagedNamespace
        Get-KubectlAuthorizationDecision -Verb "create" -Resource "configmaps" -Namespace $WorkloadManagedNamespace
        Get-KubectlAuthorizationDecision -Verb "create" -Resource "secrets" -Namespace $WorkloadManagedNamespace
    )
    $managedKnown = [bool](@($managedChecks | Where-Object { -not [bool]$_['known'] }).Count -eq 0)
    $managedAllowed = [bool]($managedKnown -and @($managedChecks | Where-Object { $_['allowed'] -ne $true }).Count -eq 0)

    $readAllDecision = Get-KubectlAuthorizationDecision -Verb "list" -Resource "*.*" -Namespace $WorkloadManagedNamespace
    $resourceClaimReadDecision = Get-KubectlAuthorizationDecision -Verb "list" -Resource "resourceclaims.resource.k8s.io" -Namespace $WorkloadManagedNamespace
    $resourceQuotaReadDecision = Get-KubectlAuthorizationDecision -Verb "list" -Resource "resourcequotas" -Namespace $WorkloadManagedNamespace
    $limitRangeReadDecision = Get-KubectlAuthorizationDecision -Verb "list" -Resource "limitranges" -Namespace $WorkloadManagedNamespace
    $replicationControllerReadDecision = Get-KubectlAuthorizationDecision -Verb "list" -Resource "replicationcontrollers" -Namespace $WorkloadManagedNamespace
    $resourceClaimWriteDecision = Get-KubectlAuthorizationDecision -Verb "create" -Resource "resourceclaims.resource.k8s.io" -Namespace $WorkloadManagedNamespace
    $resourceQuotaWriteDecision = Get-KubectlAuthorizationDecision -Verb "create" -Resource "resourcequotas" -Namespace $WorkloadManagedNamespace
    $limitRangeWriteDecision = Get-KubectlAuthorizationDecision -Verb "create" -Resource "limitranges" -Namespace $WorkloadManagedNamespace
    $replicationControllerWriteDecision = Get-KubectlAuthorizationDecision -Verb "create" -Resource "replicationcontrollers" -Namespace $WorkloadManagedNamespace
    $namespaceReadAllReady = [bool]($readAllDecision['known'] -and $readAllDecision['allowed'] -eq $true -and $resourceClaimReadDecision['known'] -and $resourceClaimReadDecision['allowed'] -eq $true -and $resourceQuotaReadDecision['known'] -and $resourceQuotaReadDecision['allowed'] -eq $true -and $limitRangeReadDecision['known'] -and $limitRangeReadDecision['allowed'] -eq $true -and $replicationControllerReadDecision['known'] -and $replicationControllerReadDecision['allowed'] -eq $true)
    $readOnlyResourceWritesDenied = [bool]($resourceClaimWriteDecision['known'] -and $resourceClaimWriteDecision['allowed'] -eq $false -and $resourceQuotaWriteDecision['known'] -and $resourceQuotaWriteDecision['allowed'] -eq $false -and $limitRangeWriteDecision['known'] -and $limitRangeWriteDecision['allowed'] -eq $false -and $replicationControllerWriteDecision['known'] -and $replicationControllerWriteDecision['allowed'] -eq $false)

    $roleBindingDecision = Get-KubectlAuthorizationDecision -Verb "create" -Resource "rolebindings.rbac.authorization.k8s.io" -Namespace $WorkloadManagedNamespace
    $clusterRoleBindingDecision = Get-KubectlAuthorizationDecision -Verb "create" -Resource "clusterrolebindings.rbac.authorization.k8s.io"
    $namespaceDecision = Get-KubectlAuthorizationDecision -Verb "create" -Resource "namespaces"
    $crdDecision = Get-KubectlAuthorizationDecision -Verb "create" -Resource "customresourcedefinitions.apiextensions.k8s.io"
    $outsideDeploymentDecision = Get-KubectlAuthorizationDecision -Verb "create" -Resource "deployments.apps" -Namespace "default"

    $rbacDenied = [bool]($roleBindingDecision['known'] -and $roleBindingDecision['allowed'] -eq $false -and $clusterRoleBindingDecision['known'] -and $clusterRoleBindingDecision['allowed'] -eq $false)
    $namespaceDenied = [bool]($namespaceDecision['known'] -and $namespaceDecision['allowed'] -eq $false)
    $crdDenied = [bool]($crdDecision['known'] -and $crdDecision['allowed'] -eq $false)
    $outsideWriteDenied = [bool]($outsideDeploymentDecision['known'] -and $outsideDeploymentDecision['allowed'] -eq $false)

    $clusterAdminDecision = Get-KubectlAuthorizationDecision -Verb "*" -Resource "*"
    $clusterWriteResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "auth", "can-i", "create", "deployments.apps", "--all-namespaces", "--as", "system:serviceaccount:${ArgoCDWorkloadServiceAccountNamespace}:${ArgoCDWorkloadServiceAccountName}") -TimeoutSeconds 20
    $clusterWriteAnswer = ([string]$clusterWriteResult.stdout).Trim().ToLowerInvariant()
    $clusterWriteKnown = [bool](-not $clusterWriteResult.timed_out -and $clusterWriteAnswer -in @("yes", "no"))
    $clusterAdmin = if ($clusterAdminDecision['known']) { [bool]$clusterAdminDecision['allowed'] } else { $null }
    $unexpectedClusterWriteBinding = if ($clusterWriteKnown) { [bool]($clusterWriteAnswer -eq "yes") } else { $null }

    $status["cluster_admin"] = $clusterAdmin
    $status["can_read_managed_namespace_resources"] = if ($readAllDecision['known']) { [bool]$readAllDecision['allowed'] } else { $null }
    $status["can_write_managed_namespace"] = if ($managedKnown) { $managedAllowed } else { $null }
    $status["can_write_outside_managed_namespace"] = if ($outsideDeploymentDecision['known']) { [bool]$outsideDeploymentDecision['allowed'] } else { $null }
    $status["can_manage_rbac"] = if ($roleBindingDecision['known'] -and $clusterRoleBindingDecision['known']) { [bool]($roleBindingDecision['allowed'] -or $clusterRoleBindingDecision['allowed']) } else { $null }
    $status["can_manage_crds"] = if ($crdDecision['known']) { [bool]$crdDecision['allowed'] } else { $null }
    $status["can_manage_namespaces"] = if ($namespaceDecision['known']) { [bool]$namespaceDecision['allowed'] } else { $null }

    $authorizationReady = [bool]($managedAllowed -and $namespaceReadAllReady -and $readOnlyResourceWritesDenied -and $rbacDenied -and $namespaceDenied -and $crdDenied -and $outsideWriteDenied -and $clusterAdmin -eq $false -and $unexpectedClusterWriteBinding -eq $false)
    Add-Check -Id "workload_deploy_permissions_authorization" -Label "Workload deploy permission authorization boundary" -Status $(if ($authorizationReady) { "ok" } else { "failed" }) -Message $(if ($authorizationReady) { "Read access covers resources in devdeploy-apps, while writes remain confined to the workload allowlist; RBAC, CRD, namespace, outside-namespace, and cluster-admin writes remain denied." } else { "The expected namespace-scoped read and write authorization boundary was not verified." }) -Details @{
        required                            = $true
        can_write_managed_namespace         = $status["can_write_managed_namespace"]
        can_write_outside_managed_namespace = $status["can_write_outside_managed_namespace"]
        can_manage_rbac                     = $status["can_manage_rbac"]
        can_manage_crds                     = $status["can_manage_crds"]
        can_manage_namespaces               = $status["can_manage_namespaces"]
        cluster_admin                       = $status["cluster_admin"]
        unexpected_cluster_write_binding    = $unexpectedClusterWriteBinding
        can_read_all_managed_namespace       = $readAllDecision['allowed']
        can_list_resourceclaims              = $resourceClaimReadDecision['allowed']
        can_create_resourceclaims            = $resourceClaimWriteDecision['allowed']
        can_list_resourcequotas              = $resourceQuotaReadDecision['allowed']
        can_create_resourcequotas            = $resourceQuotaWriteDecision['allowed']
        can_list_limitranges                 = $limitRangeReadDecision['allowed']
        can_create_limitranges               = $limitRangeWriteDecision['allowed']
        can_list_replicationcontrollers      = $replicationControllerReadDecision['allowed']
        can_create_replicationcontrollers    = $replicationControllerWriteDecision['allowed']
    }

    $applicationsResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", "applications.argoproj.io", "--output", "jsonpath={.items[*].metadata.name}") -TimeoutSeconds 20
    $applicationCountKnown = [bool]($applicationsResult.exit_code -eq 0 -and -not $applicationsResult.timed_out)
    if ($applicationCountKnown) {
        $applicationNames = @(([string]$applicationsResult.stdout) -split "\s+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $status["application_count"] = [int]$applicationNames.Count
    }

    $permissionReady = [bool]($namespacePresent -and $rolePresent -and $roleBindingPresent -and $clusterScopeReady -and $authorizationReady -and $applicationCountKnown)
    $status["granted"] = $permissionReady
    $status["ready"] = $permissionReady
    $status["write_rbac_configured"] = $permissionReady
    $status["checked_at"] = [string](Get-Timestamp)
    if ($permissionReady) {
        $status["status"] = "ready"
        $status["message"] = "Argo CD has namespace-wide read access and workload-allowlist write access in devdeploy-apps. No Application or workload was created."
    }
    else {
        $status["status"] = "error"
        $status["message"] = "Workload deploy permissions did not pass all required namespace and authorization checks."
    }

    Add-Check -Id "workload_deploy_permissions_ready" -Label "Workload deploy permissions" -Status $(if ($permissionReady) { "ok" } else { "failed" }) -Message ([string]$status["message"]) -Details @{
        required            = $true
        application_count   = $status["application_count"]
        application_created = $false
        workload_created    = $false
        cluster_admin       = $status["cluster_admin"]
        rbac_scope          = "namespace"
    }

    return $status
}

function Invoke-VerifyWorkloadDeployPermissions {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ManagementCluster,

        [Parameter(Mandatory = $true)]
        [object]$WorkloadCluster,

        [bool]$KubectlAvailable,

        [Parameter(Mandatory = $true)]
        [object]$RegistrationStatus
    )

    $status = New-WorkloadDeployPermissionsStatus -Mode "verify"
    if (-not $KubectlAvailable -or [string]$ManagementCluster["status"] -ne "ready" -or [string]$WorkloadCluster["status"] -ne "ready" -or -not [bool]$RegistrationStatus["registered"] -or -not [bool]$RegistrationStatus["ready"] -or -not [bool]$RegistrationStatus["cluster_secret_present"]) {
        $status["status"] = "error"
        $status["message"] = "Both clusters and the existing Argo CD workload registration must be ready for read-only permission verification."
        Add-Check -Id "workload_deploy_permissions_verify_prerequisites" -Label "Workload deploy permission verification prerequisites" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required                  = $true
            kubectl_available         = $KubectlAvailable
            management_cluster_status = [string]$ManagementCluster["status"]
            workload_cluster_status   = [string]$WorkloadCluster["status"]
            registration_status       = [string]$RegistrationStatus["status"]
            cluster_secret_present    = [bool]$RegistrationStatus["cluster_secret_present"]
            read_only                 = $true
        }
        return $status
    }

    Add-Check -Id "workload_deploy_permissions_verify_prerequisites" -Label "Workload deploy permission verification prerequisites" -Status "ok" -Message "Both clusters, Argo CD, and the existing workload registration are ready for read-only permission verification." -Details @{
        required          = $true
        managed_namespace = $WorkloadManagedNamespace
        read_only         = $true
    }

    $namespaceResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "get", "namespace", $WorkloadManagedNamespace, "--output", "name") -TimeoutSeconds 20
    $serviceAccountResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "--namespace", $ArgoCDWorkloadServiceAccountNamespace, "get", "serviceaccount", $ArgoCDWorkloadServiceAccountName, "--output", "name") -TimeoutSeconds 20
    $roleResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "--namespace", $WorkloadManagedNamespace, "get", "role", $WorkloadDeployRoleName, "--output", "name") -TimeoutSeconds 20
    $bindingNameResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "--namespace", $WorkloadManagedNamespace, "get", "rolebinding", $WorkloadDeployRoleBindingName, "--output", "name") -TimeoutSeconds 20
    $bindingRoleResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "--namespace", $WorkloadManagedNamespace, "get", "rolebinding", $WorkloadDeployRoleBindingName, "--output", "jsonpath={.roleRef.kind}/{.roleRef.name}") -TimeoutSeconds 20
    $bindingSubjectResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "--namespace", $WorkloadManagedNamespace, "get", "rolebinding", $WorkloadDeployRoleBindingName, "--output", "jsonpath={.subjects[0].kind}/{.subjects[0].namespace}/{.subjects[0].name}") -TimeoutSeconds 20

    $namespacePresent = [bool]($namespaceResult.exit_code -eq 0 -and -not $namespaceResult.timed_out)
    $serviceAccountPresent = [bool]($serviceAccountResult.exit_code -eq 0 -and -not $serviceAccountResult.timed_out)
    $rolePresent = [bool]($roleResult.exit_code -eq 0 -and -not $roleResult.timed_out)
    $roleBindingPresent = [bool]($bindingNameResult.exit_code -eq 0 -and -not $bindingNameResult.timed_out)
    $roleBindingRefValid = [bool]($bindingRoleResult.exit_code -eq 0 -and -not $bindingRoleResult.timed_out -and ([string]$bindingRoleResult.stdout).Trim() -eq "Role/$WorkloadDeployRoleName")
    $roleBindingSubjectValid = [bool]($bindingSubjectResult.exit_code -eq 0 -and -not $bindingSubjectResult.timed_out -and ([string]$bindingSubjectResult.stdout).Trim() -eq "ServiceAccount/${ArgoCDWorkloadServiceAccountNamespace}/${ArgoCDWorkloadServiceAccountName}")
    $metadataReady = [bool]($namespacePresent -and $serviceAccountPresent -and $rolePresent -and $roleBindingPresent -and $roleBindingRefValid -and $roleBindingSubjectValid)

    $status["namespace_present"] = $namespacePresent
    $status["service_account_present"] = $serviceAccountPresent
    $status["role_present"] = $rolePresent
    $status["role_binding_present"] = $roleBindingPresent
    $status["role_binding_ref_valid"] = $roleBindingRefValid
    $status["role_binding_subject_valid"] = $roleBindingSubjectValid

    Add-Check -Id "workload_deploy_permissions_verify_metadata" -Label "Workload deploy permission metadata verification" -Status $(if ($metadataReady) { "ok" } else { "failed" }) -Message $(if ($metadataReady) { "Namespace, ServiceAccount, Role, and RoleBinding metadata match the V1 permission contract." } else { "One or more namespace, ServiceAccount, Role, or RoleBinding metadata checks failed." }) -Details @{
        required                   = $true
        namespace_present          = $namespacePresent
        service_account_present    = $serviceAccountPresent
        role_present               = $rolePresent
        role_binding_present       = $roleBindingPresent
        role_binding_ref_valid     = $roleBindingRefValid
        role_binding_subject_valid = $roleBindingSubjectValid
        read_only                  = $true
    }

    $managedChecks = @(
        Get-KubectlAuthorizationDecision -Verb "create" -Resource "deployments.apps" -Namespace $WorkloadManagedNamespace
        Get-KubectlAuthorizationDecision -Verb "create" -Resource "services" -Namespace $WorkloadManagedNamespace
        Get-KubectlAuthorizationDecision -Verb "create" -Resource "ingresses.networking.k8s.io" -Namespace $WorkloadManagedNamespace
        Get-KubectlAuthorizationDecision -Verb "create" -Resource "configmaps" -Namespace $WorkloadManagedNamespace
        Get-KubectlAuthorizationDecision -Verb "create" -Resource "secrets" -Namespace $WorkloadManagedNamespace
    )
    $managedKnown = [bool](@($managedChecks | Where-Object { -not [bool]$_['known'] }).Count -eq 0)
    $managedAllowed = [bool]($managedKnown -and @($managedChecks | Where-Object { $_['allowed'] -ne $true }).Count -eq 0)

    $readAllDecision = Get-KubectlAuthorizationDecision -Verb "list" -Resource "*.*" -Namespace $WorkloadManagedNamespace
    $resourceClaimReadDecision = Get-KubectlAuthorizationDecision -Verb "list" -Resource "resourceclaims.resource.k8s.io" -Namespace $WorkloadManagedNamespace
    $resourceQuotaReadDecision = Get-KubectlAuthorizationDecision -Verb "list" -Resource "resourcequotas" -Namespace $WorkloadManagedNamespace
    $limitRangeReadDecision = Get-KubectlAuthorizationDecision -Verb "list" -Resource "limitranges" -Namespace $WorkloadManagedNamespace
    $replicationControllerReadDecision = Get-KubectlAuthorizationDecision -Verb "list" -Resource "replicationcontrollers" -Namespace $WorkloadManagedNamespace
    $resourceClaimWriteDecision = Get-KubectlAuthorizationDecision -Verb "create" -Resource "resourceclaims.resource.k8s.io" -Namespace $WorkloadManagedNamespace
    $resourceQuotaWriteDecision = Get-KubectlAuthorizationDecision -Verb "create" -Resource "resourcequotas" -Namespace $WorkloadManagedNamespace
    $limitRangeWriteDecision = Get-KubectlAuthorizationDecision -Verb "create" -Resource "limitranges" -Namespace $WorkloadManagedNamespace
    $replicationControllerWriteDecision = Get-KubectlAuthorizationDecision -Verb "create" -Resource "replicationcontrollers" -Namespace $WorkloadManagedNamespace
    $namespaceReadAllReady = [bool]($readAllDecision['known'] -and $readAllDecision['allowed'] -eq $true -and $resourceClaimReadDecision['known'] -and $resourceClaimReadDecision['allowed'] -eq $true -and $resourceQuotaReadDecision['known'] -and $resourceQuotaReadDecision['allowed'] -eq $true -and $limitRangeReadDecision['known'] -and $limitRangeReadDecision['allowed'] -eq $true -and $replicationControllerReadDecision['known'] -and $replicationControllerReadDecision['allowed'] -eq $true)
    $readOnlyResourceWritesDenied = [bool]($resourceClaimWriteDecision['known'] -and $resourceClaimWriteDecision['allowed'] -eq $false -and $resourceQuotaWriteDecision['known'] -and $resourceQuotaWriteDecision['allowed'] -eq $false -and $limitRangeWriteDecision['known'] -and $limitRangeWriteDecision['allowed'] -eq $false -and $replicationControllerWriteDecision['known'] -and $replicationControllerWriteDecision['allowed'] -eq $false)

    $roleBindingDecision = Get-KubectlAuthorizationDecision -Verb "create" -Resource "rolebindings.rbac.authorization.k8s.io" -Namespace $WorkloadManagedNamespace
    $roleDecision = Get-KubectlAuthorizationDecision -Verb "create" -Resource "roles.rbac.authorization.k8s.io" -Namespace $WorkloadManagedNamespace
    $clusterRoleBindingDecision = Get-KubectlAuthorizationDecision -Verb "create" -Resource "clusterrolebindings.rbac.authorization.k8s.io"
    $clusterRoleDecision = Get-KubectlAuthorizationDecision -Verb "create" -Resource "clusterroles.rbac.authorization.k8s.io"
    $crdDecision = Get-KubectlAuthorizationDecision -Verb "create" -Resource "customresourcedefinitions.apiextensions.k8s.io"
    $namespaceDecision = Get-KubectlAuthorizationDecision -Verb "create" -Resource "namespaces"
    $outsideDeploymentDecision = Get-KubectlAuthorizationDecision -Verb "create" -Resource "deployments.apps" -Namespace "default"
    $clusterAdminDecision = Get-KubectlAuthorizationDecision -Verb "*" -Resource "*"

    $rbacDecisions = @($roleBindingDecision, $roleDecision, $clusterRoleBindingDecision, $clusterRoleDecision)
    $rbacKnown = [bool](@($rbacDecisions | Where-Object { -not [bool]$_['known'] }).Count -eq 0)
    $rbacDenied = [bool]($rbacKnown -and @($rbacDecisions | Where-Object { $_['allowed'] -ne $false }).Count -eq 0)
    $crdDenied = [bool]($crdDecision['known'] -and $crdDecision['allowed'] -eq $false)
    $namespaceDenied = [bool]($namespaceDecision['known'] -and $namespaceDecision['allowed'] -eq $false)
    $outsideWriteDenied = [bool]($outsideDeploymentDecision['known'] -and $outsideDeploymentDecision['allowed'] -eq $false)
    $clusterAdmin = if ($clusterAdminDecision['known']) { [bool]$clusterAdminDecision['allowed'] } else { $null }

    $status["cluster_admin"] = $clusterAdmin
    $status["can_read_managed_namespace_resources"] = if ($readAllDecision['known']) { [bool]$readAllDecision['allowed'] } else { $null }
    $status["can_write_managed_namespace"] = if ($managedKnown) { $managedAllowed } else { $null }
    $status["can_write_outside_managed_namespace"] = if ($outsideDeploymentDecision['known']) { [bool]$outsideDeploymentDecision['allowed'] } else { $null }
    $status["can_manage_rbac"] = if ($rbacKnown) { [bool](-not $rbacDenied) } else { $null }
    $status["can_manage_crds"] = if ($crdDecision['known']) { [bool]$crdDecision['allowed'] } else { $null }
    $status["can_manage_namespaces"] = if ($namespaceDecision['known']) { [bool]$namespaceDecision['allowed'] } else { $null }
    $authorizationReady = [bool]($managedAllowed -and $namespaceReadAllReady -and $readOnlyResourceWritesDenied -and $rbacDenied -and $crdDenied -and $namespaceDenied -and $outsideWriteDenied -and $clusterAdmin -eq $false)

    Add-Check -Id "workload_deploy_permissions_verify_authorization" -Label "Workload deploy permission authorization verification" -Status $(if ($authorizationReady) { "ok" } else { "failed" }) -Message $(if ($authorizationReady) { "Namespace-wide reads are allowed in devdeploy-apps, while writes remain confined to the workload allowlist and RBAC, CRD, namespace, outside-namespace, and cluster-admin writes remain denied." } else { "The expected namespace-scoped read and write authorization boundary was not verified." }) -Details @{
        required                            = $true
        can_write_managed_namespace         = $status["can_write_managed_namespace"]
        can_write_outside_managed_namespace = $status["can_write_outside_managed_namespace"]
        can_manage_rbac                     = $status["can_manage_rbac"]
        can_manage_crds                     = $status["can_manage_crds"]
        can_manage_namespaces               = $status["can_manage_namespaces"]
        cluster_admin                       = $status["cluster_admin"]
        can_read_all_managed_namespace       = $readAllDecision['allowed']
        can_list_resourceclaims              = $resourceClaimReadDecision['allowed']
        can_create_resourceclaims            = $resourceClaimWriteDecision['allowed']
        can_list_resourcequotas              = $resourceQuotaReadDecision['allowed']
        can_create_resourcequotas            = $resourceQuotaWriteDecision['allowed']
        can_list_limitranges                 = $limitRangeReadDecision['allowed']
        can_create_limitranges               = $limitRangeWriteDecision['allowed']
        can_list_replicationcontrollers      = $replicationControllerReadDecision['allowed']
        can_create_replicationcontrollers    = $replicationControllerWriteDecision['allowed']
        read_only                           = $true
    }

    $applicationsResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", "applications.argoproj.io", "--output", "jsonpath={.items[*].metadata.name}") -TimeoutSeconds 20
    $applicationCountKnown = [bool]($applicationsResult.exit_code -eq 0 -and -not $applicationsResult.timed_out)
    if ($applicationCountKnown) {
        $applicationNames = @(([string]$applicationsResult.stdout) -split "\s+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $status["application_count"] = [int]$applicationNames.Count
    }

    Add-Check -Id "workload_deploy_permissions_verify_applications" -Label "Argo CD Application inventory" -Status $(if ($applicationCountKnown) { "ok" } else { "failed" }) -Message $(if ($applicationCountKnown) { "Argo CD Application inventory was read without creating or modifying Applications." } else { "Argo CD Application inventory could not be read." }) -Details @{
        required            = $true
        application_count   = $status["application_count"]
        application_created = $false
        read_only           = $true
    }

    $verificationReady = [bool]($metadataReady -and $authorizationReady -and $applicationCountKnown)
    $status["granted"] = $verificationReady
    $status["ready"] = $verificationReady
    $status["write_rbac_configured"] = $verificationReady
    $status["checked_at"] = [string](Get-Timestamp)
    if ($verificationReady) {
        $status["status"] = "ready"
        $status["message"] = "Namespace-wide read access and workload-allowlist write access are verified in devdeploy-apps. No Application or workload was created or modified."
    }
    else {
        $status["status"] = "error"
        $status["message"] = "Workload deploy permissions did not pass all required read-only verification checks."
    }

    Add-Check -Id "workload_deploy_permissions_verify_ready" -Label "Workload deploy permission verification" -Status $(if ($verificationReady) { "ok" } else { "failed" }) -Message ([string]$status["message"]) -Details @{
        required                  = [bool](-not $verificationReady)
        application_count         = $status["application_count"]
        write_rbac_configured      = $status["write_rbac_configured"]
        cluster_admin              = $status["cluster_admin"]
        verification_mutated_state = $false
    }

    return $status
}

function Protect-GitRepositoryUrl {
    param(
        [AllowNull()]
        [string]$Url
    )

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return ""
    }

    $sanitized = [string]$Url.Trim()
    $sanitized = $sanitized -replace '(?i)^([a-z][a-z0-9+.-]*://)[^/@\s]+@', '$1'
    $sanitized = $sanitized -replace '[?#].*$', ''
    return [string](Protect-LogText $sanitized)
}

function New-GitOpsRepositoryStatus {
    param(
        [string]$RepoPath = "",

        [string]$DefaultBranch = "main",

        [string]$RepoUrlSanitized = ""
    )

    return [ordered]@{
        configured                = $false
        ready                     = $false
        provider                  = "local_path"
        mode                      = "local_path"
        owner                     = ""
        repo                      = ""
        default_branch            = [string]$DefaultBranch
        repo_path                 = [string]$RepoPath
        repo_url_sanitized        = [string]$RepoUrlSanitized
        source_path               = $GitOpsSourcePath
        repository_mode           = "unknown"
        source_present            = $false
        kustomization_valid       = $false
        app_directory_count       = 0
        resource_count            = 0
        empty_resources           = $false
        managed_tree_valid        = $false
        path_initialized          = $false
        kustomization_present     = $false
        apps_directory_present    = $false
        kustomize_render_succeeded = $null
        credentials_configured    = $false
        github_integration_enabled = $false
        status                    = "not_started"
        message                   = "Local GitOps repository configuration has not started."
        checked_at                = [string](Get-Timestamp)
    }
}

function Test-GitOpsKustomizationContent {
    param(
        [AllowNull()]
        [string]$Content
    )

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return $false
    }

    $hasApiVersion = $Content -match '(?m)^\s*apiVersion\s*:\s*kustomize\.config\.k8s\.io/v1beta1\s*(?:#.*)?$'
    $hasKind = $Content -match '(?m)^\s*kind\s*:\s*Kustomization\s*(?:#.*)?$'
    $hasResources = $Content -match '(?m)^\s*resources\s*:'
    return [bool]($hasApiVersion -and $hasKind -and $hasResources)
}

function Get-GitOpsKustomizationResourceEntries {
    param(
        [AllowNull()]
        [string]$Content
    )

    $result = [ordered]@{
        valid           = $false
        resources       = [string[]]@()
        empty_resources = $false
        error_category  = "malformed_kustomization"
    }
    if (-not (Test-GitOpsKustomizationContent -Content $Content)) {
        return $result
    }

    $lines = @(([string]$Content) -split "\r?\n")
    $resourceLineIndexes = New-Object System.Collections.Generic.List[int]
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ([string]$lines[$index] -match '^resources\s*:') {
            $resourceLineIndexes.Add($index) | Out-Null
        }
    }
    if ($resourceLineIndexes.Count -ne 1) {
        $result["error_category"] = "resources_key_count"
        return $result
    }

    $resourceLineIndex = [int]$resourceLineIndexes[0]
    $resourceLine = [string]$lines[$resourceLineIndex]
    $inlineValue = [string]([System.Text.RegularExpressions.Regex]::Match($resourceLine, '^resources\s*:\s*(.*?)\s*(?:#.*)?$').Groups[1].Value)
    if (-not [string]::IsNullOrWhiteSpace($inlineValue)) {
        if ($inlineValue -eq "[]") {
            $result["valid"] = $true
            $result["empty_resources"] = $true
            $result["error_category"] = ""
        }
        else {
            $result["error_category"] = "unsupported_inline_resources"
        }
        return $result
    }

    $resources = New-Object System.Collections.Generic.List[string]
    for ($index = $resourceLineIndex + 1; $index -lt $lines.Count; $index++) {
        $line = [string]$lines[$index]
        if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^\s*#') {
            continue
        }
        if ($line -match '^\S') {
            break
        }
        $itemMatch = [System.Text.RegularExpressions.Regex]::Match($line, '^\s+-\s+(.+?)\s*$')
        if (-not $itemMatch.Success) {
            $result["error_category"] = "malformed_resource_entry"
            return $result
        }
        $resource = [string]$itemMatch.Groups[1].Value.Trim()
        if (($resource.StartsWith('"') -and $resource.EndsWith('"')) -or ($resource.StartsWith("'") -and $resource.EndsWith("'"))) {
            $resource = [string]$resource.Substring(1, $resource.Length - 2).Trim()
        }
        if ([string]::IsNullOrWhiteSpace($resource) -or $resource.Contains("#")) {
            $result["error_category"] = "invalid_resource_entry"
            return $result
        }
        $resources.Add($resource) | Out-Null
    }

    $result["valid"] = $true
    $result["resources"] = [string[]]$resources.ToArray()
    $result["empty_resources"] = [bool]($resources.Count -eq 0)
    $result["error_category"] = ""
    return $result
}

function Test-GitOpsManagedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceRoot,

        [Parameter(Mandatory = $true)]
        [string]$ResourcePath
    )

    $result = [ordered]@{
        valid          = $false
        full_path      = ""
        error_category = "invalid_resource_path"
    }
    if ([string]::IsNullOrWhiteSpace($ResourcePath) -or $ResourcePath.Contains("%") -or [System.IO.Path]::IsPathRooted($ResourcePath) -or $ResourcePath -match '^[A-Za-z][A-Za-z0-9+.-]*:') {
        $result["error_category"] = "absolute_or_encoded_resource_path"
        return $result
    }

    $normalizedResource = [string]($ResourcePath -replace '\\', '/')
    $segments = @($normalizedResource -split '/')
    if ($segments.Count -eq 0 -or @($segments | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -in @(".", "..") }).Count -gt 0) {
        $result["error_category"] = "resource_path_traversal"
        return $result
    }

    try {
        $resolvedSourceRoot = [string](Resolve-Path -LiteralPath $SourceRoot).Path
        $candidatePath = [string][System.IO.Path]::GetFullPath((Join-Path $resolvedSourceRoot ($segments -join [System.IO.Path]::DirectorySeparatorChar)))
        $sourcePrefix = [string]($resolvedSourceRoot.TrimEnd([char[]]"\/") + [System.IO.Path]::DirectorySeparatorChar)
        if (-not $candidatePath.StartsWith($sourcePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $result["error_category"] = "resource_path_escape"
            return $result
        }

        $currentPath = $resolvedSourceRoot
        foreach ($segment in $segments) {
            $currentPath = Join-Path $currentPath $segment
            if (-not (Test-Path -LiteralPath $currentPath)) {
                $result["error_category"] = "referenced_resource_missing"
                return $result
            }
            $item = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
            if ([bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                $result["error_category"] = "resource_symlink_not_allowed"
                return $result
            }
        }

        $result["valid"] = $true
        $result["full_path"] = $candidatePath
        $result["error_category"] = ""
        return $result
    }
    catch {
        $result["error_category"] = "resource_path_resolution_failed"
        return $result
    }
}

function Test-GitOpsManagedKustomizationTree {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceRoot,

        [Parameter(Mandatory = $true)]
        [string]$KustomizationPath,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.HashSet[string]]$VisitedKustomizations
    )

    $result = [ordered]@{
        valid                 = $false
        resource_count        = 0
        error_category        = "malformed_kustomization"
        normalized_resources  = [string[]]@()
    }
    try {
        $resolvedKustomization = [string](Resolve-Path -LiteralPath $KustomizationPath).Path
        if (-not $VisitedKustomizations.Add($resolvedKustomization)) {
            $result["error_category"] = "duplicate_or_cyclic_kustomization"
            return $result
        }
        $content = [string](Get-Content -LiteralPath $resolvedKustomization -Raw -ErrorAction Stop)
    }
    catch {
        $result["error_category"] = "kustomization_read_failed"
        return $result
    }

    $parsed = Get-GitOpsKustomizationResourceEntries -Content $content
    if (-not [bool]$parsed["valid"]) {
        $result["error_category"] = [string]$parsed["error_category"]
        return $result
    }

    $seenResources = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $normalizedResources = New-Object System.Collections.Generic.List[string]
    $kustomizationDirectory = [string](Split-Path -Parent $resolvedKustomization)
    foreach ($resource in @($parsed["resources"])) {
        $normalizedResource = [string](([string]$resource -replace '\\', '/').Trim())
        if (-not $seenResources.Add($normalizedResource)) {
            $result["error_category"] = "duplicate_resource_entry"
            return $result
        }
        $relativeFromSource = if ([string]::Equals($kustomizationDirectory.TrimEnd([char[]]"\/"), $SourceRoot.TrimEnd([char[]]"\/"), [System.StringComparison]::OrdinalIgnoreCase)) {
            $normalizedResource
        }
        else {
            $relativeDirectory = [string]$kustomizationDirectory.Substring($SourceRoot.TrimEnd([char[]]"\/").Length).TrimStart([char[]]"\/")
            [string](Join-Path $relativeDirectory $normalizedResource)
        }
        $pathStatus = Test-GitOpsManagedPath -SourceRoot $SourceRoot -ResourcePath $relativeFromSource
        if (-not [bool]$pathStatus["valid"]) {
            $result["error_category"] = [string]$pathStatus["error_category"]
            return $result
        }

        $fullPath = [string]$pathStatus["full_path"]
        if (Test-Path -LiteralPath $fullPath -PathType Container) {
            $childKustomization = Join-Path $fullPath "kustomization.yaml"
            if (-not (Test-Path -LiteralPath $childKustomization -PathType Leaf)) {
                $result["error_category"] = "referenced_kustomization_missing"
                return $result
            }
            $childResult = Test-GitOpsManagedKustomizationTree -SourceRoot $SourceRoot -KustomizationPath $childKustomization -VisitedKustomizations $VisitedKustomizations
            if (-not [bool]$childResult["valid"]) {
                $result["error_category"] = [string]$childResult["error_category"]
                return $result
            }
            $result["resource_count"] = [int]$result["resource_count"] + [int]$childResult["resource_count"]
        }
        elseif (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            $extension = [string][System.IO.Path]::GetExtension($fullPath)
            if ($extension -notin @(".yaml", ".yml")) {
                $result["error_category"] = "unsupported_resource_file"
                return $result
            }
            try {
                if ([string]::IsNullOrWhiteSpace([string](Get-Content -LiteralPath $fullPath -Raw -ErrorAction Stop))) {
                    $result["error_category"] = "empty_resource_file"
                    return $result
                }
            }
            catch {
                $result["error_category"] = "resource_file_read_failed"
                return $result
            }
            $result["resource_count"] = [int]$result["resource_count"] + 1
        }
        else {
            $result["error_category"] = "referenced_resource_missing"
            return $result
        }
        $normalizedResources.Add($normalizedResource) | Out-Null
    }

    $result["valid"] = $true
    $result["normalized_resources"] = [string[]]$normalizedResources.ToArray()
    $result["error_category"] = ""
    return $result
}

function Test-GitOpsManagedSourceTree {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceRoot,

        [bool]$KubectlAvailable
    )

    $result = [ordered]@{
        ready                       = $false
        repository_mode             = "unknown"
        source_present              = $false
        apps_directory_present      = $false
        kustomization_present       = $false
        kustomization_valid         = $false
        app_directory_count         = 0
        resource_count              = 0
        empty_resources             = $false
        referenced_apps_valid       = $false
        kustomize_render_succeeded  = $false
        files_changed               = $false
        error_category              = "source_missing"
    }
    if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
        return $result
    }

    try {
        $resolvedSourceRoot = [string](Resolve-Path -LiteralPath $SourceRoot).Path
        $sourceItem = Get-Item -LiteralPath $resolvedSourceRoot -Force -ErrorAction Stop
        if ([bool]($sourceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            $result["error_category"] = "source_symlink_not_allowed"
            return $result
        }
    }
    catch {
        $result["error_category"] = "source_resolution_failed"
        return $result
    }

    $result["source_present"] = $true
    $appsPath = Join-Path $resolvedSourceRoot "apps"
    $kustomizationPath = Join-Path $resolvedSourceRoot "kustomization.yaml"
    $result["apps_directory_present"] = [bool](Test-Path -LiteralPath $appsPath -PathType Container)
    $result["kustomization_present"] = [bool](Test-Path -LiteralPath $kustomizationPath -PathType Leaf)
    if (-not $result["apps_directory_present"] -or -not $result["kustomization_present"]) {
        $result["error_category"] = "managed_source_structure_missing"
        return $result
    }

    $appDirectories = @(Get-ChildItem -LiteralPath $appsPath -Directory -Force -ErrorAction SilentlyContinue | Sort-Object -Property Name)
    $result["app_directory_count"] = [int]$appDirectories.Count
    $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $treeResult = Test-GitOpsManagedKustomizationTree -SourceRoot $resolvedSourceRoot -KustomizationPath $kustomizationPath -VisitedKustomizations $visited
    $result["kustomization_valid"] = [bool]$treeResult["valid"]
    $result["resource_count"] = [int]$treeResult["resource_count"]
    if (-not [bool]$treeResult["valid"]) {
        $result["error_category"] = [string]$treeResult["error_category"]
        return $result
    }

    $rootContent = [string](Get-Content -LiteralPath $kustomizationPath -Raw)
    $rootResources = Get-GitOpsKustomizationResourceEntries -Content $rootContent
    $result["empty_resources"] = [bool]$rootResources["empty_resources"]
    $referencedAppNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($resource in @($rootResources["resources"])) {
        $normalized = [string](([string]$resource -replace '\\', '/').Trim('/'))
        if ($normalized -notmatch '^apps/([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)$') {
            $result["error_category"] = "unsupported_root_resource"
            return $result
        }
        $referencedAppNames.Add([string]$Matches[1]) | Out-Null
    }

    $directoryNames = [string[]]@($appDirectories | ForEach-Object { [string]$_.Name })
    $unreferencedDirectories = @($directoryNames | Where-Object { -not $referencedAppNames.Contains($_) })
    if ($unreferencedDirectories.Count -gt 0 -or $referencedAppNames.Count -ne $appDirectories.Count) {
        $result["error_category"] = "app_directory_reference_mismatch"
        return $result
    }
    $result["referenced_apps_valid"] = $true

    if (-not $KubectlAvailable) {
        $result["error_category"] = "kustomize_renderer_unavailable"
        return $result
    }
    $renderResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("kustomize", $resolvedSourceRoot) -TimeoutSeconds 45
    $result["kustomize_render_succeeded"] = [bool]($renderResult.exit_code -eq 0 -and -not $renderResult.timed_out)
    if (-not $result["kustomize_render_succeeded"]) {
        $result["error_category"] = "kustomize_render_failed"
        return $result
    }

    if ($appDirectories.Count -eq 0 -and [bool]$rootResources["empty_resources"]) {
        $result["repository_mode"] = "initial_empty_bootstrap"
    }
    elseif ($appDirectories.Count -gt 0 -and $referencedAppNames.Count -eq $appDirectories.Count) {
        $result["repository_mode"] = "existing_repository_recovery"
    }
    else {
        $result["error_category"] = "repository_mode_invalid"
        return $result
    }

    $result["ready"] = $true
    $result["error_category"] = ""
    return $result
}

function Invoke-ConfigureGitOpsRepository {
    param(
        [bool]$GitAvailable,

        [bool]$KubectlAvailable,

        [string]$RequestedRepoPath,

        [string]$RequestedRepoUrl,

        [string]$RequestedBranch
    )

    $candidatePath = if ([string]::IsNullOrWhiteSpace($RequestedRepoPath)) {
        [string]$RepoRoot
    }
    elseif ([System.IO.Path]::IsPathRooted($RequestedRepoPath)) {
        [string]$RequestedRepoPath
    }
    else {
        [string](Join-Path $RepoRoot $RequestedRepoPath)
    }

    $status = New-GitOpsRepositoryStatus -RepoPath $candidatePath

    if (-not $GitAvailable) {
        $status["status"] = "error"
        $status["message"] = "GitOps repository configuration requires the Git CLI."
        Add-Check -Id "gitops_repository_configure" -Label "GitOps repository configuration" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required = $true
            provider = "local_path"
        }
        return $status
    }

    if (-not (Test-Path -LiteralPath $candidatePath -PathType Container)) {
        $status["status"] = "error"
        $status["message"] = "The requested local GitOps repository path does not exist."
        Add-Check -Id "gitops_repository_path" -Label "GitOps repository path" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required = $true
            repo_path = [string]$candidatePath
        }
        return $status
    }

    try {
        $candidatePath = [string](Resolve-Path -LiteralPath $candidatePath).Path
        $status["repo_path"] = $candidatePath
    }
    catch {
        $status["status"] = "error"
        $status["message"] = "The local GitOps repository path could not be resolved safely."
        Add-Check -Id "gitops_repository_path" -Label "GitOps repository path" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required = $true
            repo_path = [string]$candidatePath
        }
        return $status
    }

    Add-Check -Id "gitops_repository_path" -Label "GitOps repository path" -Status "ok" -Message "The local GitOps repository path exists." -Details @{
        required = $true
        repo_path = [string]$candidatePath
    }

    $repoResult = Invoke-ReadOnlyCommand -FileName "git" -Arguments @("-C", $candidatePath, "rev-parse", "--show-toplevel") -TimeoutSeconds 10 -PreserveStandardOutput $true
    if ($repoResult.exit_code -ne 0 -or $repoResult.timed_out -or [string]::IsNullOrWhiteSpace($repoResult.stdout)) {
        $status["status"] = "error"
        $status["message"] = "The requested local path is not a readable Git worktree."
        Add-Check -Id "gitops_repository_detected" -Label "Git repository detection" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required = $true
            repo_path = [string]$candidatePath
        }
        return $status
    }

    try {
        $gitRoot = [string](Resolve-Path -LiteralPath ([string]$repoResult.stdout.Trim())).Path
    }
    catch {
        $gitRoot = ""
    }

    $normalizedGitRoot = $gitRoot.TrimEnd([char[]]"\/")
    $normalizedCandidatePath = $candidatePath.TrimEnd([char[]]"\/")
    if ([string]::IsNullOrWhiteSpace($gitRoot) -or -not [string]::Equals($normalizedGitRoot, $normalizedCandidatePath, [System.StringComparison]::OrdinalIgnoreCase)) {
        $status["status"] = "error"
        $status["message"] = "GitOpsRepoPath must identify the root of a readable Git worktree."
        Add-Check -Id "gitops_repository_detected" -Label "Git repository detection" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required = $true
            repo_path = [string]$candidatePath
        }
        return $status
    }

    Add-Check -Id "gitops_repository_detected" -Label "Git repository detection" -Status "ok" -Message "A readable Git worktree was detected at the configured local path." -Details @{
        required = $true
        repo_path = [string]$candidatePath
    }

    $workingTreeResult = Invoke-ReadOnlyCommand -FileName "git" -Arguments @("-C", $candidatePath, "status", "--porcelain=v1", "--untracked-files=normal") -TimeoutSeconds 15 -PreserveStandardOutput $true
    if ($workingTreeResult.exit_code -ne 0 -or $workingTreeResult.timed_out) {
        $status["status"] = "error"
        $status["message"] = "The Git working tree status could not be read safely."
        Add-Check -Id "gitops_repository_worktree" -Label "Git working tree status" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required = $true
            repo_path = [string]$candidatePath
        }
        return $status
    }

    $workingTreeClean = [string]::IsNullOrWhiteSpace([string]$workingTreeResult.stdout)
    Add-Check -Id "gitops_repository_worktree" -Label "Git working tree status" -Status "ok" -Message $(if ($workingTreeClean) { "The Git working tree status is readable and clean." } else { "The Git working tree status is readable. Existing changes will be preserved." }) -Details @{
        required = $true
        clean_before_initialize = [bool]$workingTreeClean
    }

    $branch = [string]$RequestedBranch.Trim()
    if (-not [string]::IsNullOrWhiteSpace($branch)) {
        $branchIsSafe = $branch.Length -le 255 -and $branch -notmatch '[\s\x00-\x1F\x7F]' -and -not $branch.StartsWith("-")
        if (-not $branchIsSafe) {
            $status["status"] = "error"
            $status["message"] = "The requested GitOps branch name is not valid for launcher status."
            Add-Check -Id "gitops_repository_branch" -Label "GitOps repository branch" -Status "failed" -Message ([string]$status["message"]) -Details @{
                required = $true
            }
            return $status
        }
    }
    else {
        $branchResult = Invoke-ReadOnlyCommand -FileName "git" -Arguments @("-C", $candidatePath, "branch", "--show-current") -TimeoutSeconds 10 -PreserveStandardOutput $true
        if ($branchResult.exit_code -eq 0 -and -not $branchResult.timed_out -and -not [string]::IsNullOrWhiteSpace($branchResult.stdout)) {
            $branch = [string]$branchResult.stdout.Trim()
        }
        else {
            $branch = "main"
        }
    }
    $status["default_branch"] = $branch

    $repoUrl = [string]$RequestedRepoUrl.Trim()
    if ([string]::IsNullOrWhiteSpace($repoUrl)) {
        $remoteResult = Invoke-ReadOnlyCommand -FileName "git" -Arguments @("-C", $candidatePath, "remote", "get-url", "origin") -TimeoutSeconds 10 -PreserveStandardOutput $true
        if ($remoteResult.exit_code -eq 0 -and -not $remoteResult.timed_out) {
            $repoUrl = [string]$remoteResult.stdout.Trim()
        }
    }
    $status["repo_url_sanitized"] = [string](Protect-GitRepositoryUrl -Url $repoUrl)

    Add-Check -Id "gitops_repository_metadata" -Label "GitOps repository metadata" -Status "ok" -Message "GitOps branch and sanitized repository metadata were resolved." -Details @{
        required       = $true
        provider       = "local_path"
        mode           = "local_path"
        default_branch = [string]$branch
        source_path    = $GitOpsSourcePath
    }

    $sourceRoot = Join-Path $candidatePath $GitOpsSourceRelativeWindowsPath
    $appsPath = Join-Path $sourceRoot "apps"
    $gitKeepPath = Join-Path $appsPath ".gitkeep"
    $kustomizationPath = Join-Path $sourceRoot "kustomization.yaml"

    try {
        New-Item -ItemType Directory -Force -Path $appsPath | Out-Null
        if (-not (Test-Path -LiteralPath $gitKeepPath -PathType Leaf)) {
            New-Item -ItemType File -Path $gitKeepPath -Force | Out-Null
        }
    }
    catch {
        $status["status"] = "error"
        $status["message"] = "The GitOps directory structure could not be initialized."
        Add-Check -Id "gitops_repository_directories" -Label "GitOps directory structure" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required    = $true
            source_path = $GitOpsSourcePath
        }
        return $status
    }

    $appDirectories = @(Get-ChildItem -LiteralPath $appsPath -Directory -ErrorAction SilentlyContinue | Sort-Object -Property Name)
    Add-Check -Id "gitops_repository_directories" -Label "GitOps directory structure" -Status "ok" -Message "The GitOps source and apps directories are present. Existing app directories were preserved." -Details @{
        required             = $true
        source_path          = $GitOpsSourcePath
        apps_directory       = "$GitOpsSourcePath/apps"
        existing_app_count   = [int]$appDirectories.Count
        sample_app_generated = $false
    }

    $existingKustomizationValid = $false
    if (Test-Path -LiteralPath $kustomizationPath -PathType Leaf) {
        try {
            $existingContent = [string](Get-Content -LiteralPath $kustomizationPath -Raw)
            $existingKustomizationValid = Test-GitOpsKustomizationContent -Content $existingContent
        }
        catch {
            $existingKustomizationValid = $false
        }
    }

    $kustomizationChanged = $false
    if (-not $existingKustomizationValid) {
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add("apiVersion: kustomize.config.k8s.io/v1beta1") | Out-Null
        $lines.Add("kind: Kustomization") | Out-Null
        if ($appDirectories.Count -eq 0) {
            $lines.Add("resources: []") | Out-Null
        }
        else {
            $lines.Add("resources:") | Out-Null
            foreach ($directory in $appDirectories) {
                $lines.Add(("  - apps/{0}" -f [string]$directory.Name)) | Out-Null
            }
        }

        try {
            $kustomizationContent = [string](($lines -join "`n") + "`n")
            Set-Content -LiteralPath $kustomizationPath -Value $kustomizationContent -Encoding UTF8
            $kustomizationChanged = $true
        }
        catch {
            $status["status"] = "error"
            $status["message"] = "The GitOps root kustomization could not be initialized."
            Add-Check -Id "gitops_repository_kustomization" -Label "GitOps root kustomization" -Status "failed" -Message ([string]$status["message"]) -Details @{
                required    = $true
                source_path = $GitOpsSourcePath
            }
            return $status
        }
    }

    $finalContent = [string](Get-Content -LiteralPath $kustomizationPath -Raw)
    $kustomizationValid = Test-GitOpsKustomizationContent -Content $finalContent
    if (-not $kustomizationValid) {
        $status["status"] = "error"
        $status["message"] = "The GitOps root kustomization is missing required Kustomize fields."
        Add-Check -Id "gitops_repository_kustomization" -Label "GitOps root kustomization" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required    = $true
            source_path = $GitOpsSourcePath
        }
        return $status
    }

    Add-Check -Id "gitops_repository_kustomization" -Label "GitOps root kustomization" -Status "ok" -Message $(if ($kustomizationChanged) { "A valid deterministic GitOps root kustomization was initialized." } else { "The existing valid GitOps root kustomization was preserved." }) -Details @{
        required      = $true
        source_path   = $GitOpsSourcePath
        file          = "$GitOpsSourcePath/kustomization.yaml"
        changed       = [bool]$kustomizationChanged
        app_count     = [int]$appDirectories.Count
    }

    if ($KubectlAvailable) {
        $renderResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("kustomize", $sourceRoot) -TimeoutSeconds 30
        $renderSucceeded = [bool]($renderResult.exit_code -eq 0 -and -not $renderResult.timed_out)
        $status["kustomize_render_succeeded"] = $renderSucceeded
        Add-Check -Id "gitops_repository_kustomize_render" -Label "GitOps Kustomize render" -Status $(if ($renderSucceeded) { "ok" } else { "warning" }) -Message $(if ($renderSucceeded) { "The GitOps source path renders successfully." } else { "Optional kubectl render validation could not complete. Structural validation passed and existing app content was not modified." }) -Details @{
            required    = $false
            source_path = $GitOpsSourcePath
        }
    }
    else {
        Add-Check -Id "gitops_repository_kustomize_render" -Label "GitOps Kustomize render" -Status "skipped" -Message "kubectl is unavailable; structural kustomization validation passed, but render validation was skipped." -Details @{
            required    = $false
            source_path = $GitOpsSourcePath
        }
    }

    $status["configured"] = $true
    $status["path_initialized"] = [bool](Test-Path -LiteralPath $sourceRoot -PathType Container)
    $status["kustomization_present"] = [bool](Test-Path -LiteralPath $kustomizationPath -PathType Leaf)
    $status["apps_directory_present"] = [bool](Test-Path -LiteralPath $appsPath -PathType Container)
    $status["ready"] = [bool]($status["path_initialized"] -and $status["kustomization_present"] -and $status["apps_directory_present"] -and $kustomizationValid)
    $status["status"] = if ([bool]$status["ready"]) { "ready" } else { "error" }
    $status["message"] = if ([bool]$status["ready"]) {
        "Local GitOps repository path is initialized and ready. No Argo CD Application or workload was created."
    }
    else {
        "Local GitOps repository path was initialized, but validation did not complete successfully."
    }
    $status["checked_at"] = [string](Get-Timestamp)

    Add-Check -Id "gitops_repository_ready" -Label "GitOps repository readiness" -Status $(if ([bool]$status["ready"]) { "ok" } else { "failed" }) -Message ([string]$status["message"]) -Details @{
        required                   = $true
        provider                   = "local_path"
        mode                       = "local_path"
        source_path                = $GitOpsSourcePath
        path_initialized           = [bool]$status["path_initialized"]
        kustomization_present      = [bool]$status["kustomization_present"]
        apps_directory_present     = [bool]$status["apps_directory_present"]
        credentials_configured     = $false
        github_integration_enabled = $false
        application_created        = $false
        sample_app_generated       = $false
    }

    return $status
}

function New-GitOpsRootApplicationStatus {
    return [ordered]@{
        bootstrapped                  = $false
        verified                      = $false
        mode                          = "not_started"
        ready                         = $false
        exists                        = $false
        application_name              = $GitOpsRootApplicationName
        namespace                     = $ArgoCDNamespace
        application_namespace         = $ArgoCDNamespace
        project                       = "default"
        source_repo_url_sanitized     = $GitOpsExpectedRepositoryUrl
        source_target_revision        = $GitOpsTargetRevision
        source_path                   = $GitOpsSourcePath
        repository_mode               = "unknown"
        destination_cluster           = "devdeploy-workload"
        destination_server            = $ExpectedWorkloadArgoCDEndpoint
        destination_namespace         = $WorkloadManagedNamespace
        sync_policy                   = "automated"
        prune_enabled                 = $false
        self_heal_enabled              = $true
        create_namespace              = $false
        application_present           = $false
        application_count_match       = $null
        project_match                 = $null
        source_repo_match             = $null
        source_path_match             = $null
        target_revision_match         = $null
        destination_server_match      = $null
        destination_namespace_match   = $null
        automated_sync_enabled        = $null
        prune_disabled                = $null
        create_namespace_disabled     = $null
        sync_status                    = $null
        health_status                  = $null
        synced                         = $null
        healthy                        = $null
        application_count              = $null
        expected_application_count     = $null
        total_application_count        = $null
        workload_objects_created       = $null
        workload_namespace             = [ordered]@{
            name                     = $WorkloadManagedNamespace
            exists                   = $null
            deployments_count        = $null
            services_count           = $null
            ingresses_count          = $null
            empty_root_mode_expected = $null
        }
        actual                         = [ordered]@{
            namespace                   = $null
            project                     = $null
            source_repo_url_sanitized   = $null
            source_path                 = $null
            target_revision             = $null
            destination_server          = $null
            destination_namespace       = $null
        }
        status                         = "not_started"
        message                        = "GitOps Root Application bootstrap has not started."
        checked_at                     = [string](Get-Timestamp)
    }
}

function Get-PersistedGitOpsRepositoryStatus {
    param(
        [bool]$GitAvailable,

        [bool]$KubectlAvailable
    )

    $repoPath = [string]$RepoRoot
    $repoUrl = ""
    $branch = $GitOpsTargetRevision
    $persistedStatusReady = $false

    if (Test-Path -LiteralPath $StatusPath -PathType Leaf) {
        try {
            $document = Get-Content -LiteralPath $StatusPath -Raw | ConvertFrom-Json
            if ($null -ne $document.platform_bootstrap -and $null -ne $document.platform_bootstrap.components -and $null -ne $document.platform_bootstrap.components.gitops_repository) {
                $persisted = $document.platform_bootstrap.components.gitops_repository
                $persistedStatusReady = [bool]$persisted.ready
                if (-not [string]::IsNullOrWhiteSpace([string]$persisted.repo_path)) {
                    $repoPath = [string]$persisted.repo_path
                }
                if (-not [string]::IsNullOrWhiteSpace([string]$persisted.repo_url_sanitized)) {
                    $repoUrl = [string]$persisted.repo_url_sanitized
                }
                if (-not [string]::IsNullOrWhiteSpace([string]$persisted.default_branch)) {
                    $branch = [string]$persisted.default_branch
                }
            }
        }
        catch {
            $persistedStatusReady = $false
        }
    }

    $status = New-GitOpsRepositoryStatus -RepoPath $repoPath -DefaultBranch $branch -RepoUrlSanitized (Protect-GitRepositoryUrl -Url $repoUrl)
    $status["provider"] = "local_path"
    $status["mode"] = "local_path"

    if (-not (Test-Path -LiteralPath $repoPath -PathType Container)) {
        $status["status"] = "error"
        $status["message"] = "The configured local GitOps repository path is missing. Run -ConfigureGitOpsRepository first."
        Add-Check -Id "gitops_root_repository_path" -Label "GitOps Root Application repository path" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required = $true
            repo_path = [string]$repoPath
        }
        return $status
    }

    try {
        $repoPath = [string](Resolve-Path -LiteralPath $repoPath).Path
        $status["repo_path"] = $repoPath
    }
    catch {
        $status["status"] = "error"
        $status["message"] = "The configured local GitOps repository path could not be resolved safely."
        Add-Check -Id "gitops_root_repository_path" -Label "GitOps Root Application repository path" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required = $true
        }
        return $status
    }

    Add-Check -Id "gitops_root_repository_path" -Label "GitOps Root Application repository path" -Status "ok" -Message "The configured local GitOps repository path exists." -Details @{
        required = $true
        repo_path = [string]$repoPath
        persisted_status_ready = [bool]$persistedStatusReady
    }

    if ($GitAvailable) {
        $gitRootResult = Invoke-ReadOnlyCommand -FileName "git" -Arguments @("-C", $repoPath, "rev-parse", "--show-toplevel") -TimeoutSeconds 10 -PreserveStandardOutput $true
        $gitRootReady = [bool]($gitRootResult.exit_code -eq 0 -and -not $gitRootResult.timed_out -and -not [string]::IsNullOrWhiteSpace($gitRootResult.stdout))
        if ($gitRootReady) {
            try {
                $resolvedGitRoot = [string](Resolve-Path -LiteralPath ([string]$gitRootResult.stdout.Trim())).Path
                $gitRootReady = [string]::Equals($resolvedGitRoot.TrimEnd([char[]]"\/"), $repoPath.TrimEnd([char[]]"\/"), [System.StringComparison]::OrdinalIgnoreCase)
            }
            catch {
                $gitRootReady = $false
            }
        }

        Add-Check -Id "gitops_root_repository_worktree" -Label "GitOps Root Application Git worktree" -Status $(if ($gitRootReady) { "ok" } else { "failed" }) -Message $(if ($gitRootReady) { "The configured GitOps repository is a readable Git worktree." } else { "The configured GitOps repository is not a readable Git worktree. Run -ConfigureGitOpsRepository first." }) -Details @{
            required = $true
            repo_path = [string]$repoPath
        }
        if (-not $gitRootReady) {
            $status["status"] = "error"
            $status["message"] = "The configured GitOps repository is not a readable Git worktree."
            return $status
        }

        if ([string]::IsNullOrWhiteSpace([string]$status["repo_url_sanitized"])) {
            $remoteResult = Invoke-ReadOnlyCommand -FileName "git" -Arguments @("-C", $repoPath, "remote", "get-url", "origin") -TimeoutSeconds 10 -PreserveStandardOutput $true
            if ($remoteResult.exit_code -eq 0 -and -not $remoteResult.timed_out) {
                $status["repo_url_sanitized"] = [string](Protect-GitRepositoryUrl -Url ([string]$remoteResult.stdout.Trim()))
            }
        }
    }
    else {
        Add-Check -Id "gitops_root_repository_worktree" -Label "GitOps Root Application Git worktree" -Status "warning" -Message "Git CLI is unavailable; persisted repository metadata and filesystem structure will be used." -Details @{
            required = $false
            repo_path = [string]$repoPath
        }
    }

    $status["repo_url_sanitized"] = [string](Protect-GitRepositoryUrl -Url ([string]$status["repo_url_sanitized"]))
    if ([string]::IsNullOrWhiteSpace([string]$status["repo_url_sanitized"])) {
        $status["status"] = "error"
        $status["message"] = "The GitOps repository URL is missing. Run -ConfigureGitOpsRepository before bootstrapping the Root Application."
        Add-Check -Id "gitops_root_repository_url" -Label "GitOps Root Application repository URL" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required = $true
        }
        return $status
    }

    Add-Check -Id "gitops_root_repository_url" -Label "GitOps Root Application repository URL" -Status "ok" -Message "A sanitized GitOps repository URL is configured." -Details @{
        required = $true
        credentials_embedded = $false
    }

    if ([string]$status["default_branch"] -ne $GitOpsTargetRevision) {
        $status["status"] = "error"
        $status["message"] = "The configured GitOps branch must be main for the Phase 2I Root Application contract."
        Add-Check -Id "gitops_root_repository_revision" -Label "GitOps Root Application target revision" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required = $true
            expected_revision = $GitOpsTargetRevision
            configured_revision = [string]$status["default_branch"]
        }
        return $status
    }

    $sourceRoot = Join-Path $repoPath $GitOpsSourceRelativeWindowsPath
    $sourceValidation = Test-GitOpsManagedSourceTree -SourceRoot $sourceRoot -KubectlAvailable $KubectlAvailable
    $sourceReady = [bool]$sourceValidation["ready"]

    Add-Check -Id "gitops_root_repository_source" -Label "GitOps Root Application source path" -Status $(if ($sourceReady) { "ok" } else { "failed" }) -Message $(if ($sourceReady -and [string]$sourceValidation["repository_mode"] -eq "existing_repository_recovery") { "The existing populated DevDeploy-managed GitOps source passed containment, structure, and Kustomize render validation for recovery." } elseif ($sourceReady) { "The empty DevDeploy-managed GitOps source passed structure and Kustomize render validation for initial bootstrap." } else { "The DevDeploy-managed GitOps source failed strict containment, structure, reference, or Kustomize render validation." }) -Details @{
        required                      = $true
        source_path                   = $GitOpsSourcePath
        repository_mode               = [string]$sourceValidation["repository_mode"]
        source_present                = [bool]$sourceValidation["source_present"]
        apps_directory_present        = [bool]$sourceValidation["apps_directory_present"]
        kustomization_present         = [bool]$sourceValidation["kustomization_present"]
        kustomization_valid           = [bool]$sourceValidation["kustomization_valid"]
        app_directory_count           = [int]$sourceValidation["app_directory_count"]
        resource_count                = [int]$sourceValidation["resource_count"]
        empty_resources               = [bool]$sourceValidation["empty_resources"]
        referenced_apps_valid         = [bool]$sourceValidation["referenced_apps_valid"]
        kustomize_render_succeeded    = [bool]$sourceValidation["kustomize_render_succeeded"]
        files_changed                 = $false
        error_category                = [string]$sourceValidation["error_category"]
    }

    $status["configured"] = $sourceReady
    $status["ready"] = $sourceReady
    $status["repository_mode"] = [string]$sourceValidation["repository_mode"]
    $status["source_present"] = [bool]$sourceValidation["source_present"]
    $status["kustomization_valid"] = [bool]$sourceValidation["kustomization_valid"]
    $status["app_directory_count"] = [int]$sourceValidation["app_directory_count"]
    $status["resource_count"] = [int]$sourceValidation["resource_count"]
    $status["empty_resources"] = [bool]$sourceValidation["empty_resources"]
    $status["managed_tree_valid"] = $sourceReady
    $status["kustomize_render_succeeded"] = [bool]$sourceValidation["kustomize_render_succeeded"]
    $status["path_initialized"] = [bool]$sourceValidation["source_present"]
    $status["kustomization_present"] = [bool]$sourceValidation["kustomization_present"]
    $status["apps_directory_present"] = [bool]$sourceValidation["apps_directory_present"]
    $status["status"] = if ($sourceReady) { "ready" } else { "error" }
    $status["message"] = if ($sourceReady -and [string]$status["repository_mode"] -eq "existing_repository_recovery") { "The existing DevDeploy-managed GitOps repository is ready for Root Application recovery without changing workload files." } elseif ($sourceReady) { "The empty DevDeploy-managed GitOps repository is ready for initial Root Application bootstrap." } else { "The local GitOps repository did not pass Root Application prerequisites." }
    $status["checked_at"] = [string](Get-Timestamp)
    return $status
}

function Get-WorkloadObjectInventory {
    param(
        [bool]$KubectlAvailable
    )

    if (-not $KubectlAvailable) {
        return [ordered]@{ success = $false; count = $null; keys = @() }
    }

    $result = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "--namespace", $WorkloadManagedNamespace, "get", "deployments.apps,services,ingresses.networking.k8s.io", "--output", "json") -TimeoutSeconds 30 -PreserveStandardOutput $true
    if ($result.exit_code -ne 0 -or $result.timed_out -or [string]::IsNullOrWhiteSpace($result.stdout)) {
        return [ordered]@{ success = $false; count = $null; keys = @() }
    }

    try {
        $document = [string]$result.stdout | ConvertFrom-Json
        $keys = New-Object System.Collections.Generic.List[string]
        foreach ($item in @($document.items)) {
            $keys.Add(("{0}/{1}/{2}" -f [string]$item.kind, [string]$item.metadata.namespace, [string]$item.metadata.name)) | Out-Null
        }
        return [ordered]@{
            success = $true
            count   = [int]$keys.Count
            keys    = @($keys | Sort-Object)
        }
    }
    catch {
        return [ordered]@{ success = $false; count = $null; keys = @() }
    }
}

function Invoke-BootstrapGitOpsRootApplication {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ManagementCluster,

        [Parameter(Mandatory = $true)]
        [object]$WorkloadCluster,

        [bool]$KindAvailable,

        [bool]$KubectlAvailable,

        [Parameter(Mandatory = $true)]
        [object]$ArgoCDStatus,

        [Parameter(Mandatory = $true)]
        [object]$RegistrationStatus,

        [Parameter(Mandatory = $true)]
        [object]$PermissionStatus,

        [Parameter(Mandatory = $true)]
        [object]$RepositoryStatus
    )

    $status = New-GitOpsRootApplicationStatus
    $status["source_repo_url_sanitized"] = [string](Protect-GitRepositoryUrl -Url ([string]$RepositoryStatus["repo_url_sanitized"]))
    $status["repository_mode"] = [string]$RepositoryStatus["repository_mode"]

    $basePrerequisitesReady = [bool]($KindAvailable -and $KubectlAvailable -and [string]$ManagementCluster["status"] -eq "ready" -and [string]$WorkloadCluster["status"] -eq "ready" -and [bool]$ArgoCDStatus["ready"] -and [bool]$RegistrationStatus["ready"] -and [bool]$PermissionStatus["ready"] -and [bool]$RepositoryStatus["ready"])
    if (-not $basePrerequisitesReady) {
        $status["status"] = "error"
        $status["message"] = "Root Application prerequisites are not ready. Verify both clusters, Argo CD, registration, workload permissions, and the GitOps repository first."
        Add-Check -Id "gitops_root_prerequisites" -Label "GitOps Root Application prerequisites" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required = $true
            kind_available = $KindAvailable
            kubectl_available = $KubectlAvailable
            management_cluster_status = [string]$ManagementCluster["status"]
            workload_cluster_status = [string]$WorkloadCluster["status"]
            argocd_status = [string]$ArgoCDStatus["status"]
            registration_ready = [bool]$RegistrationStatus["ready"]
            workload_permissions_ready = [bool]$PermissionStatus["ready"]
            gitops_repository_ready = [bool]$RepositoryStatus["ready"]
            repository_mode = [string]$RepositoryStatus["repository_mode"]
        }
        return $status
    }

    $crdResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "get", "customresourcedefinition", "applications.argoproj.io", "--output", "name") -TimeoutSeconds 20
    $clusterSecretResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", "secret", $ArgoCDWorkloadClusterSecretName, "--output", "name") -TimeoutSeconds 20
    $namespaceResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "get", "namespace", $WorkloadManagedNamespace, "--output", "name") -TimeoutSeconds 20
    $runtimePrerequisitesReady = [bool]($crdResult.exit_code -eq 0 -and -not $crdResult.timed_out -and $clusterSecretResult.exit_code -eq 0 -and -not $clusterSecretResult.timed_out -and $namespaceResult.exit_code -eq 0 -and -not $namespaceResult.timed_out)

    Add-Check -Id "gitops_root_prerequisites" -Label "GitOps Root Application prerequisites" -Status $(if ($runtimePrerequisitesReady) { "ok" } else { "failed" }) -Message $(if ($runtimePrerequisitesReady) { "Both clusters, Argo CD CRDs, registration, deploy permissions, repository source, and destination namespace are ready." } else { "Argo CD CRD, workload cluster Secret, or destination namespace verification failed." }) -Details @{
        required = $true
        argocd_application_crd_present = [bool]($crdResult.exit_code -eq 0 -and -not $crdResult.timed_out)
        workload_cluster_secret_present = [bool]($clusterSecretResult.exit_code -eq 0 -and -not $clusterSecretResult.timed_out)
        destination_namespace_present = [bool]($namespaceResult.exit_code -eq 0 -and -not $namespaceResult.timed_out)
    }
    if (-not $runtimePrerequisitesReady) {
        $status["status"] = "error"
        $status["message"] = "Root Application runtime prerequisites did not pass verification."
        return $status
    }

    $beforeInventory = Get-WorkloadObjectInventory -KubectlAvailable $KubectlAvailable
    Add-Check -Id "gitops_root_workload_inventory_before" -Label "Workload object inventory before Root Application" -Status $(if ([bool]$beforeInventory["success"]) { "ok" } else { "failed" }) -Message $(if ([bool]$beforeInventory["success"]) { "Deployment, Service, and Ingress inventory was captured before Root Application reconciliation." } else { "Workload object inventory could not be captured before Root Application reconciliation." }) -Details @{
        required = $true
        object_count = $beforeInventory["count"]
        secret_data_read = $false
    }
    if (-not [bool]$beforeInventory["success"]) {
        $status["status"] = "error"
        $status["message"] = "Workload object inventory is required before Root Application reconciliation."
        return $status
    }

    $applicationManifest = [ordered]@{
        apiVersion = "argoproj.io/v1alpha1"
        kind       = "Application"
        metadata   = [ordered]@{
            name      = $GitOpsRootApplicationName
            namespace = $ArgoCDNamespace
            labels    = [ordered]@{
                "app.kubernetes.io/managed-by" = "devdeploy-launcher"
                "devdeploy.io/component"       = "gitops-root"
            }
        }
        spec       = [ordered]@{
            project = "default"
            source  = [ordered]@{
                repoURL        = [string]$status["source_repo_url_sanitized"]
                targetRevision = $GitOpsTargetRevision
                path           = $GitOpsSourcePath
            }
            destination = [ordered]@{
                server    = $ExpectedWorkloadArgoCDEndpoint
                namespace = $WorkloadManagedNamespace
            }
            syncPolicy = [ordered]@{
                automated = [ordered]@{
                    prune    = $false
                    selfHeal = $true
                }
                syncOptions = @("CreateNamespace=false")
            }
        }
    }

    $applyResult = Invoke-SanitizedInputCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "apply", "--filename", "-") -StandardInput ($applicationManifest | ConvertTo-Json -Depth 12 -Compress) -TimeoutSeconds 45
    $applySucceeded = [bool]($applyResult.exit_code -eq 0 -and -not $applyResult.timed_out)
    Add-Check -Id "gitops_root_application_apply" -Label "GitOps Root Application reconcile" -Status $(if ($applySucceeded) { "ok" } else { "failed" }) -Message $(if ($applySucceeded) { "Reconciled only argocd/devdeploy-workloads-root in devdeploy-mgmt." } else { "The GitOps Root Application could not be reconciled." }) -Details @{
        required = $true
        application_name = $GitOpsRootApplicationName
        application_namespace = $ArgoCDNamespace
        resource_kind = "Application"
        user_workload_applied = $false
    }
    if (-not $applySucceeded) {
        $status["status"] = "error"
        $status["message"] = "GitOps Root Application reconciliation failed."
        return $status
    }

    $applicationPresent = $false
    $syncStatus = $null
    $healthStatus = $null
    $conditionTypes = @()
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        $applicationStatusResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", "application", $GitOpsRootApplicationName, "--output", "jsonpath={.status.sync.status}|{.status.health.status}|{.status.conditions[*].type}") -TimeoutSeconds 20 -PreserveStandardOutput $true
        if ($applicationStatusResult.exit_code -eq 0 -and -not $applicationStatusResult.timed_out) {
            $applicationPresent = $true
            $statusParts = @(([string]$applicationStatusResult.stdout) -split '\|', 3)
            if ($statusParts.Count -ge 1 -and -not [string]::IsNullOrWhiteSpace($statusParts[0])) {
                $syncStatus = [string]$statusParts[0].Trim()
            }
            if ($statusParts.Count -ge 2 -and -not [string]::IsNullOrWhiteSpace($statusParts[1])) {
                $healthStatus = [string]$statusParts[1].Trim()
            }
            if ($statusParts.Count -ge 3 -and -not [string]::IsNullOrWhiteSpace($statusParts[2])) {
                $conditionTypes = @(([string]$statusParts[2]) -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$syncStatus)) {
                break
            }
        }
        if ($attempt -lt 10) {
            Start-Sleep -Seconds 3
        }
    }

    $specMatches = $false
    if ($applicationPresent) {
        $specResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", "application", $GitOpsRootApplicationName, "--output", "jsonpath={.spec.project}|{.spec.source.repoURL}|{.spec.source.targetRevision}|{.spec.source.path}|{.spec.destination.server}|{.spec.destination.namespace}|{.spec.syncPolicy.automated.prune}|{.spec.syncPolicy.automated.selfHeal}|{.spec.syncPolicy.syncOptions[*]}") -TimeoutSeconds 20 -PreserveStandardOutput $true
        if ($specResult.exit_code -eq 0 -and -not $specResult.timed_out) {
            $specParts = @(([string]$specResult.stdout) -split '\|', 9)
            if ($specParts.Count -eq 9) {
                $specMatches = [bool]((([string]$specParts[0]).Trim()) -eq "default" -and (([string]$specParts[1]).Trim()) -eq [string]$status["source_repo_url_sanitized"] -and (([string]$specParts[2]).Trim()) -eq $GitOpsTargetRevision -and (([string]$specParts[3]).Trim()) -eq $GitOpsSourcePath -and (([string]$specParts[4]).Trim()) -eq $ExpectedWorkloadArgoCDEndpoint -and (([string]$specParts[5]).Trim()) -eq $WorkloadManagedNamespace -and (([string]$specParts[6]).Trim().ToLowerInvariant()) -eq "false" -and (([string]$specParts[7]).Trim().ToLowerInvariant()) -eq "true" -and @(([string]$specParts[8]) -split '\s+') -contains "CreateNamespace=false")
            }
        }
    }

    $status["application_present"] = $applicationPresent
    $status["sync_status"] = $syncStatus
    $status["health_status"] = $healthStatus
    Add-Check -Id "gitops_root_application_spec" -Label "GitOps Root Application specification" -Status $(if ($applicationPresent -and $specMatches) { "ok" } else { "failed" }) -Message $(if ($applicationPresent -and $specMatches) { "The Root Application source, destination, project, and sync policy match the expected contract." } else { "The Root Application is missing or its specification does not match the expected contract." }) -Details @{
        required = $true
        application_present = $applicationPresent
        spec_matches = $specMatches
        source_path = $GitOpsSourcePath
        target_revision = $GitOpsTargetRevision
        destination_server = $ExpectedWorkloadArgoCDEndpoint
        destination_namespace = $WorkloadManagedNamespace
        prune_enabled = $false
        self_heal_enabled = $true
        create_namespace = $false
    }

    $applicationsResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", "applications.argoproj.io", "--output", "jsonpath={.items[*].metadata.name}") -TimeoutSeconds 20
    $applicationCountKnown = [bool]($applicationsResult.exit_code -eq 0 -and -not $applicationsResult.timed_out)
    if ($applicationCountKnown) {
        $applicationNames = @(([string]$applicationsResult.stdout) -split "\s+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $status["application_count"] = [int]$applicationNames.Count
    }
    $applicationCountExpected = [bool]($applicationCountKnown -and [int]$status["application_count"] -eq 1)
    Add-Check -Id "gitops_root_application_inventory" -Label "Argo CD Application inventory" -Status $(if ($applicationCountExpected) { "ok" } elseif ($applicationCountKnown) { "warning" } else { "failed" }) -Message $(if ($applicationCountExpected) { "Argo CD contains exactly the expected Root Application." } elseif ($applicationCountKnown) { "The Root Application exists, but the total Argo CD Application count is not one." } else { "Argo CD Application inventory could not be read." }) -Details @{
        required = [bool](-not $applicationCountKnown)
        application_count = $status["application_count"]
        expected_count = 1
    }

    $afterInventory = Get-WorkloadObjectInventory -KubectlAvailable $KubectlAvailable
    $workloadInventoryKnown = [bool]$afterInventory["success"]
    $newObjectKeys = @()
    if ($workloadInventoryKnown) {
        $beforeKeys = @($beforeInventory["keys"])
        $newObjectKeys = @($afterInventory["keys"] | Where-Object { $beforeKeys -notcontains $_ })
        $status["workload_objects_created"] = [bool]($newObjectKeys.Count -gt 0)
    }
    $noWorkloadCreated = [bool]($workloadInventoryKnown -and $newObjectKeys.Count -eq 0)
    $repositoryRecoveryMode = [bool]([string]$status["repository_mode"] -eq "existing_repository_recovery")
    $workloadInventorySafe = [bool]($workloadInventoryKnown -and ($repositoryRecoveryMode -or $noWorkloadCreated))
    Add-Check -Id "gitops_root_workload_inventory_after" -Label "Workload object inventory after Root Application" -Status $(if ($workloadInventorySafe) { "ok" } else { "failed" }) -Message $(if ($repositoryRecoveryMode -and $workloadInventoryKnown) { "Workload inventory remained readable. In recovery mode Argo CD may reconcile existing Git desired state; the launcher applied only the Root Application." } elseif ($noWorkloadCreated) { "No Deployment, Service, or Ingress was created during empty Root Application bootstrap." } elseif ($workloadInventoryKnown) { "Unexpected workload objects appeared during empty Root Application bootstrap." } else { "Workload object inventory could not be verified after Root Application bootstrap." }) -Details @{
        required = $true
        repository_mode = [string]$status["repository_mode"]
        before_count = $beforeInventory["count"]
        after_count = $afterInventory["count"]
        new_object_count = [int]$newObjectKeys.Count
        launcher_applied_workload = $false
        secret_data_read = $false
    }

    $contractReady = [bool]($applicationPresent -and $specMatches -and $applicationCountExpected -and $workloadInventorySafe)
    $status["bootstrapped"] = [bool]($applicationPresent -and $specMatches)
    $status["ready"] = $contractReady
    $status["checked_at"] = [string](Get-Timestamp)
    $syncHealthy = [bool]($syncStatus -eq "Synced" -and $healthStatus -eq "Healthy")
    if (-not $contractReady) {
        $status["status"] = "error"
        $status["message"] = "The GitOps Root Application did not pass required specification, inventory, or workload-safety checks."
    }
    elseif ($syncHealthy -and $conditionTypes.Count -eq 0) {
        $status["status"] = "ready"
        $status["message"] = if ($repositoryRecoveryMode) { "The GitOps Root Application was recovered and is Synced and Healthy. Existing workload manifests were preserved and only the Application object was reconciled by the launcher." } else { "The GitOps Root Application is configured, Synced, and Healthy. No user workload was created during empty bootstrap." }
    }
    else {
        $status["status"] = "warning"
        $status["message"] = if ($repositoryRecoveryMode) { "The GitOps Root Application was recovered correctly, but repository access, destination access, sync, or health is not fully ready yet. Existing workload manifests were preserved." } else { "The GitOps Root Application is configured correctly, but repository access, destination access, sync, or health is not fully ready yet. No user workload was created during empty bootstrap." }
    }

    Add-Check -Id "gitops_root_application_ready" -Label "GitOps Root Application readiness" -Status $(if ([string]$status["status"] -eq "ready") { "ok" } elseif ([string]$status["status"] -eq "warning") { "warning" } else { "failed" }) -Message ([string]$status["message"]) -Details @{
        required = [bool](-not $contractReady)
        bootstrapped = [bool]$status["bootstrapped"]
        ready = [bool]$status["ready"]
        sync_status = $syncStatus
        health_status = $healthStatus
        condition_types = @($conditionTypes)
        application_count = $status["application_count"]
        workload_objects_created = $status["workload_objects_created"]
        repository_mode = [string]$status["repository_mode"]
        launcher_applied_workload = $false
    }

    return $status
}

function Get-ObjectPropertyValue {
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Get-GitOpsRootWorkloadNamespaceInventory {
    param(
        [bool]$KubectlAvailable
    )

    $inventory = [ordered]@{
        name                     = $WorkloadManagedNamespace
        exists                   = $false
        inventory_known          = $false
        deployments_count        = $null
        services_count           = $null
        ingresses_count          = $null
        empty_root_mode_expected = $false
    }

    if (-not $KubectlAvailable) {
        return $inventory
    }

    $namespaceResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "get", "namespace", $WorkloadManagedNamespace, "--output", "json") -TimeoutSeconds 20 -PreserveStandardOutput $true
    if ($namespaceResult.exit_code -ne 0 -or $namespaceResult.timed_out -or [string]::IsNullOrWhiteSpace($namespaceResult.stdout)) {
        return $inventory
    }

    $inventory["exists"] = $true
    $resourcesResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "--namespace", $WorkloadManagedNamespace, "get", "deployments.apps,services,ingresses.networking.k8s.io", "--output", "json") -TimeoutSeconds 30 -PreserveStandardOutput $true
    if ($resourcesResult.exit_code -ne 0 -or $resourcesResult.timed_out -or [string]::IsNullOrWhiteSpace($resourcesResult.stdout)) {
        return $inventory
    }

    try {
        $document = [string]$resourcesResult.stdout | ConvertFrom-Json
        $items = @($document.items | ForEach-Object { $_ })
        $deploymentCount = @($items | Where-Object { [string]$_.kind -eq "Deployment" }).Count
        $serviceCount = @($items | Where-Object { [string]$_.kind -eq "Service" }).Count
        $ingressCount = @($items | Where-Object { [string]$_.kind -eq "Ingress" }).Count

        $inventory["inventory_known"] = $true
        $inventory["deployments_count"] = [int]$deploymentCount
        $inventory["services_count"] = [int]$serviceCount
        $inventory["ingresses_count"] = [int]$ingressCount
        $inventory["empty_root_mode_expected"] = [bool]($deploymentCount -eq 0 -and $serviceCount -eq 0 -and $ingressCount -eq 0)
    }
    catch {
        $inventory["inventory_known"] = $false
    }

    return $inventory
}

function Invoke-VerifyGitOpsRootApplication {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ManagementCluster,

        [Parameter(Mandatory = $true)]
        [object]$WorkloadCluster,

        [bool]$KubectlAvailable,

        [Parameter(Mandatory = $true)]
        [object]$ArgoCDStatus
    )

    $status = New-GitOpsRootApplicationStatus
    $status["mode"] = "verify"
    $status["source_repo_url_sanitized"] = $GitOpsExpectedRepositoryUrl
    $status["self_heal_enabled"] = $null

    $prerequisitesReady = [bool]($KubectlAvailable -and [string]$ManagementCluster["status"] -eq "ready" -and [string]$WorkloadCluster["status"] -eq "ready" -and [bool]$ArgoCDStatus["ready"])
    Add-Check -Id "gitops_root_verify_prerequisites" -Label "GitOps Root Application verification prerequisites" -Status $(if ($prerequisitesReady) { "ok" } else { "failed" }) -Message $(if ($prerequisitesReady) { "Both clusters, management Argo CD, and kubectl are ready for strict read-only Root Application verification." } else { "Strict Root Application verification requires both clusters, management Argo CD, and kubectl to be ready." }) -Details @{
        required                  = $true
        kubectl_available         = $KubectlAvailable
        management_cluster_status = [string]$ManagementCluster["status"]
        workload_cluster_status   = [string]$WorkloadCluster["status"]
        argocd_status             = [string]$ArgoCDStatus["status"]
        read_only                 = $true
    }
    if (-not $prerequisitesReady) {
        $status["status"] = "error"
        $status["message"] = "GitOps Root Application verification prerequisites are not ready. No resources were modified."
        return $status
    }

    $applicationReadSucceeded = $false
    $applicationCountExpected = $false
    $application = $null
    $applicationsResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", "applications.argoproj.io", "--output", "json") -TimeoutSeconds 30 -PreserveStandardOutput $true
    if ($applicationsResult.exit_code -eq 0 -and -not $applicationsResult.timed_out -and -not [string]::IsNullOrWhiteSpace($applicationsResult.stdout)) {
        try {
            $applicationsDocument = [string]$applicationsResult.stdout | ConvertFrom-Json
            $applicationItems = @($applicationsDocument.items | ForEach-Object { $_ })
            $expectedApplications = @($applicationItems | Where-Object { [string]$_.metadata.name -eq $GitOpsRootApplicationName })
            $status["application_count"] = [int]$applicationItems.Count
            $status["expected_application_count"] = [int]$expectedApplications.Count
            $status["total_application_count"] = [int]$applicationItems.Count
            $applicationCountExpected = [bool]($expectedApplications.Count -eq 1 -and $applicationItems.Count -eq 1)
            $applicationReadSucceeded = $true
            if ($applicationCountExpected) {
                $application = $expectedApplications[0]
            }
        }
        catch {
            $applicationReadSucceeded = $false
        }
    }

    $applicationPresent = [bool]($applicationReadSucceeded -and $null -ne $application)
    $status["exists"] = $applicationPresent
    $status["application_present"] = $applicationPresent
    $status["application_count_match"] = $applicationCountExpected
    Add-Check -Id "gitops_root_verify_application" -Label "GitOps Root Application existence and inventory" -Status $(if ($applicationPresent -and $applicationCountExpected) { "ok" } else { "failed" }) -Message $(if ($applicationPresent -and $applicationCountExpected) { "Exactly one argocd/devdeploy-workloads-root Application exists." } elseif ($applicationReadSucceeded) { "The expected Root Application is missing or is not unique in argocd." } else { "The Argo CD Application inventory could not be read or parsed safely." }) -Details @{
        required                = $true
        application_name        = $GitOpsRootApplicationName
        application_namespace   = $ArgoCDNamespace
        expected_count          = 1
        actual_expected_count   = $status["expected_application_count"]
        total_application_count = $status["total_application_count"]
        read_only               = $true
    }

    $specReady = $false
    $runtimeReady = $false
    if ($applicationPresent) {
        $metadata = Get-ObjectPropertyValue -InputObject $application -Name "metadata"
        $spec = Get-ObjectPropertyValue -InputObject $application -Name "spec"
        $source = Get-ObjectPropertyValue -InputObject $spec -Name "source"
        $destination = Get-ObjectPropertyValue -InputObject $spec -Name "destination"
        $syncPolicy = Get-ObjectPropertyValue -InputObject $spec -Name "syncPolicy"
        $automated = Get-ObjectPropertyValue -InputObject $syncPolicy -Name "automated"
        $runtimeStatus = Get-ObjectPropertyValue -InputObject $application -Name "status"
        $sync = Get-ObjectPropertyValue -InputObject $runtimeStatus -Name "sync"
        $health = Get-ObjectPropertyValue -InputObject $runtimeStatus -Name "health"

        $actualNamespace = [string](Get-ObjectPropertyValue -InputObject $metadata -Name "namespace")
        $actualProject = [string](Get-ObjectPropertyValue -InputObject $spec -Name "project")
        $actualRepoUrl = [string](Protect-GitRepositoryUrl -Url ([string](Get-ObjectPropertyValue -InputObject $source -Name "repoURL")))
        $actualSourcePath = [string](Get-ObjectPropertyValue -InputObject $source -Name "path")
        $actualTargetRevision = [string](Get-ObjectPropertyValue -InputObject $source -Name "targetRevision")
        $actualDestinationServer = [string](Get-ObjectPropertyValue -InputObject $destination -Name "server")
        $actualDestinationNamespace = [string](Get-ObjectPropertyValue -InputObject $destination -Name "namespace")
        $pruneValue = Get-ObjectPropertyValue -InputObject $automated -Name "prune"
        $selfHealValue = Get-ObjectPropertyValue -InputObject $automated -Name "selfHeal"
        $syncOptionsValue = Get-ObjectPropertyValue -InputObject $syncPolicy -Name "syncOptions"
        $syncOptions = @($syncOptionsValue | ForEach-Object { [string]$_ })
        $actualSyncStatus = [string](Get-ObjectPropertyValue -InputObject $sync -Name "status")
        $actualHealthStatus = [string](Get-ObjectPropertyValue -InputObject $health -Name "status")

        $status["actual"] = [ordered]@{
            namespace                 = $actualNamespace
            project                   = $actualProject
            source_repo_url_sanitized = $actualRepoUrl
            source_path               = $actualSourcePath
            target_revision           = $actualTargetRevision
            destination_server        = $actualDestinationServer
            destination_namespace     = $actualDestinationNamespace
        }
        $status["namespace"] = $actualNamespace
        $status["project_match"] = [bool]($actualProject -eq "default")
        $status["source_repo_match"] = [bool]($actualRepoUrl -eq $GitOpsExpectedRepositoryUrl)
        $status["source_path_match"] = [bool]($actualSourcePath -eq $GitOpsSourcePath)
        $status["target_revision_match"] = [bool]($actualTargetRevision -eq $GitOpsTargetRevision)
        $status["destination_server_match"] = [bool]($actualDestinationServer -eq $ExpectedWorkloadArgoCDEndpoint)
        $status["destination_namespace_match"] = [bool]($actualDestinationNamespace -eq $WorkloadManagedNamespace)
        $status["automated_sync_enabled"] = [bool]($null -ne $automated)
        $status["prune_disabled"] = [bool]($null -ne $automated -and ($null -eq $pruneValue -or -not [bool]$pruneValue))
        $status["self_heal_enabled"] = [bool]($null -ne $automated -and $null -ne $selfHealValue -and [bool]$selfHealValue)
        $status["create_namespace_disabled"] = [bool]($syncOptions -contains "CreateNamespace=false")
        $status["sync_status"] = $actualSyncStatus
        $status["health_status"] = $actualHealthStatus
        $status["synced"] = [bool]($actualSyncStatus -eq "Synced")
        $status["healthy"] = [bool]($actualHealthStatus -eq "Healthy")

        $specReady = [bool]($actualNamespace -eq $ArgoCDNamespace -and $status["project_match"] -and $status["source_repo_match"] -and $status["source_path_match"] -and $status["target_revision_match"] -and $status["destination_server_match"] -and $status["destination_namespace_match"] -and $status["automated_sync_enabled"] -and $status["prune_disabled"] -and $status["self_heal_enabled"] -and $status["create_namespace_disabled"])
        $runtimeReady = [bool]($status["synced"] -and $status["healthy"])
    }

    Add-Check -Id "gitops_root_verify_spec" -Label "GitOps Root Application specification" -Status $(if ($specReady) { "ok" } else { "failed" }) -Message $(if ($specReady) { "The Root Application project, source, destination, and sync policy match the expected contract." } else { "The Root Application is missing or one or more specification fields do not match the expected contract." }) -Details @{
        required                      = $true
        project_match                 = $status["project_match"]
        source_repo_match             = $status["source_repo_match"]
        source_path_match             = $status["source_path_match"]
        target_revision_match         = $status["target_revision_match"]
        destination_server_match      = $status["destination_server_match"]
        destination_namespace_match   = $status["destination_namespace_match"]
        automated_sync_enabled        = $status["automated_sync_enabled"]
        prune_disabled                = $status["prune_disabled"]
        self_heal_enabled             = $status["self_heal_enabled"]
        create_namespace_disabled     = $status["create_namespace_disabled"]
        read_only                     = $true
    }

    Add-Check -Id "gitops_root_verify_runtime" -Label "GitOps Root Application sync and health" -Status $(if ($runtimeReady) { "ok" } else { "failed" }) -Message $(if ($runtimeReady) { "The Root Application is Synced and Healthy." } else { "The Root Application is not both Synced and Healthy." }) -Details @{
        required      = $true
        sync_status   = $status["sync_status"]
        health_status = $status["health_status"]
        synced        = $status["synced"]
        healthy       = $status["healthy"]
        read_only     = $true
    }

    $workloadNamespace = Get-GitOpsRootWorkloadNamespaceInventory -KubectlAvailable $KubectlAvailable
    $status["workload_namespace"] = $workloadNamespace
    $workloadNamespaceExists = [bool]$workloadNamespace["exists"]
    $emptyWorkloadInventory = [bool]($workloadNamespaceExists -and $workloadNamespace["inventory_known"] -and $workloadNamespace["empty_root_mode_expected"])
    $status["workload_objects_created"] = if ($workloadNamespace["inventory_known"]) { [bool](-not $workloadNamespace["empty_root_mode_expected"]) } else { $null }

    Add-Check -Id "gitops_root_verify_workload_namespace" -Label "GitOps workload namespace" -Status $(if ($workloadNamespaceExists) { "ok" } else { "failed" }) -Message $(if ($workloadNamespaceExists) { "The devdeploy-apps workload namespace exists." } else { "The devdeploy-apps workload namespace does not exist. Verification does not create it." }) -Details @{
        required        = $true
        namespace       = $WorkloadManagedNamespace
        namespace_exists = $workloadNamespaceExists
        read_only       = $true
    }

    Add-Check -Id "gitops_root_verify_workload_inventory" -Label "GitOps empty-root workload inventory" -Status $(if ($emptyWorkloadInventory) { "ok" } else { "failed" }) -Message $(if ($emptyWorkloadInventory) { "The empty Root Application mode has zero Deployments, Services, and Ingresses." } elseif ($workloadNamespaceExists -and $workloadNamespace["inventory_known"]) { "Unexpected workload objects exist in devdeploy-apps." } else { "Workload object inventory could not be read safely." }) -Details @{
        required                 = $true
        deployments_count        = $workloadNamespace["deployments_count"]
        services_count           = $workloadNamespace["services_count"]
        ingresses_count          = $workloadNamespace["ingresses_count"]
        empty_root_mode_expected = $workloadNamespace["empty_root_mode_expected"]
        read_only                = $true
    }

    $verificationReady = [bool]($applicationPresent -and $applicationCountExpected -and $specReady -and $runtimeReady -and $emptyWorkloadInventory)
    $status["bootstrapped"] = $applicationPresent
    $status["verified"] = $verificationReady
    $status["ready"] = $verificationReady
    $status["status"] = if ($verificationReady) { "ready" } else { "error" }
    $status["message"] = if ($verificationReady) { "The GitOps Root Application passed strict read-only verification and the workload namespace remains empty." } else { "The GitOps Root Application failed one or more strict read-only verification checks. No resources were modified." }
    $status["checked_at"] = [string](Get-Timestamp)

    Add-Check -Id "gitops_root_verify_ready" -Label "GitOps Root Application read-only verification" -Status $(if ($verificationReady) { "ok" } else { "failed" }) -Message ([string]$status["message"]) -Details @{
        required                 = $true
        verified                 = $verificationReady
        application_count_match  = $status["application_count_match"]
        synced                   = $status["synced"]
        healthy                  = $status["healthy"]
        empty_root_mode_expected = $workloadNamespace["empty_root_mode_expected"]
        cluster_mutated          = $false
        secret_data_read         = $false
    }

    return $status
}

function New-WorkloadObservabilityStatus {
    param(
        [ValidateSet("not_started", "bootstrap", "verify")]
        [string]$Mode = "not_started"
    )

    return [ordered]@{
        installed                         = $false
        ready                             = $false
        mode                              = $Mode
        target_cluster                    = "devdeploy-workload"
        target_context                    = "kind-devdeploy-workload"
        namespace                         = $ObservabilityNamespace
        prometheus_release                = $ObservabilityPrometheusRelease
        prometheus_service                = "kube-prometheus-stack-prometheus"
        prometheus_service_port           = 9090
        loki_release                      = $ObservabilityLokiRelease
        loki_service                      = "loki-gateway"
        loki_service_port                 = 80
        alloy_release                     = $ObservabilityAlloyRelease
        grafana_service                   = "kube-prometheus-stack-grafana"
        grafana_service_port              = 80
        grafana_secret_name               = $ObservabilityGrafanaAdminSecretName
        grafana_secret_present            = $false
        grafana_secret_value_logged       = $false
        datasources_configured            = $false
        backend_transport_mode            = "kubernetes_service_proxy"
        backend_config_secret_name        = $BackendWorkloadKubeconfigSecretName
        reader_service_account            = $ObservabilityReaderServiceAccountName
        reader_role                       = $ObservabilityReaderRoleName
        backend_configured                = $false
        backend_uses_service_identity     = $true
        backend_uses_cluster_ip           = $false
        service_proxy_paths_allowlisted   = @(
            "/api/v1/query",
            "/api/v1/query_range",
            "/loki/api/v1/query_range",
            "/api/health"
        )
        status                            = "not_started"
        message                           = "Workload observability bootstrap has not started."
        checked_at                        = [string](Get-Timestamp)
    }
}

function New-GrafanaCredentialSecretManifest {
    $passwordBytes = New-Object byte[] 32
    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $generator.GetBytes($passwordBytes)
        $password = [Convert]::ToBase64String($passwordBytes).TrimEnd("=")
    }
    finally {
        [Array]::Clear($passwordBytes, 0, $passwordBytes.Length)
        $generator.Dispose()
    }

    return [ordered]@{
        apiVersion = "v1"
        kind       = "Secret"
        metadata   = [ordered]@{
            name      = $ObservabilityGrafanaAdminSecretName
            namespace = $ObservabilityNamespace
            labels    = [ordered]@{
                "app.kubernetes.io/managed-by" = "devdeploy-launcher"
                "app.kubernetes.io/part-of" = "devdeploy-observability"
            }
        }
        type       = "Opaque"
        stringData = [ordered]@{
            "admin-user" = "admin"
            "admin-password" = $password
        }
    }
}

function Invoke-WorkloadObservabilityRolloutCheck {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,

        [Parameter(Mandatory = $true)]
        [string]$Kind,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [bool]$Required = $true
    )

    $result = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "--namespace", $ObservabilityNamespace, "rollout", "status", "$Kind/$Name", "--timeout=300s") -TimeoutSeconds 330
    $ready = [bool]($result.exit_code -eq 0 -and -not $result.timed_out)
    Add-Check -Id $Id -Label "Workload observability $Name readiness" -Status $(if ($ready) { "ok" } elseif ($Required) { "failed" } else { "warning" }) -Message $(if ($ready) { "$Name is Ready in devdeploy-workload/$ObservabilityNamespace." } else { "$Name did not become Ready in devdeploy-workload/$ObservabilityNamespace." }) -Details @{
        required  = $Required
        namespace = $ObservabilityNamespace
        kind      = $Kind
        name      = $Name
        error     = $result.stderr
    }
    return $ready
}

function Invoke-BootstrapWorkloadObservability {
    param(
        [Parameter(Mandatory = $true)]
        [object]$WorkloadCluster,

        [bool]$HelmAvailable,

        [bool]$KubectlAvailable,

        [string]$HelmCommand = "helm"
    )

    $status = New-WorkloadObservabilityStatus -Mode "bootstrap"

    if ([string]$WorkloadCluster["status"] -ne "ready") {
        $status["status"] = "error"
        $status["message"] = "devdeploy-workload must be Ready before bootstrapping observability."
        Add-Check -Id "workload_observability_cluster" -Label "Workload observability cluster prerequisite" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required       = $true
            cluster_status = [string]$WorkloadCluster["status"]
        }
        return $status
    }
    Add-Check -Id "workload_observability_cluster" -Label "Workload observability cluster prerequisite" -Status "ok" -Message "devdeploy-workload is ready for explicit observability bootstrap." -Details @{
        required = $true
    }

    if (-not $HelmAvailable -or -not $KubectlAvailable) {
        $status["status"] = "error"
        $status["message"] = "Helm and kubectl are required for -BootstrapWorkloadObservability."
        Add-Check -Id "workload_observability_tools" -Label "Workload observability tools" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required          = $true
            helm_available    = $HelmAvailable
            kubectl_available = $KubectlAvailable
        }
        return $status
    }
    Add-Check -Id "workload_observability_tools" -Label "Workload observability tools" -Status "ok" -Message "Helm and kubectl are available for explicit workload observability bootstrap." -Details @{
        required = $true
        helm_command = $HelmCommand
    }

    foreach ($path in @($ObservabilityPrometheusValuesPath, $ObservabilityLokiValuesPath, $ObservabilityAlloyValuesPath, $ObservabilityGrafanaDatasourcesPath, $ObservabilityReaderRbacPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $status["status"] = "error"
            $status["message"] = "One or more observability values or manifest files are missing."
            Add-Check -Id "workload_observability_assets" -Label "Workload observability assets" -Status "failed" -Message ([string]$status["message"]) -Details @{
                required = $true
                path     = [string]$path
            }
            return $status
        }
    }
    Add-Check -Id "workload_observability_assets" -Label "Workload observability assets" -Status "ok" -Message "Observability Helm values and datasource manifest are present." -Details @{
        required      = $true
        manifest_path = $ObservabilityManifestRelativePath
    }

    $namespaceResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "create", "namespace", $ObservabilityNamespace, "--dry-run=client", "--output", "yaml") -TimeoutSeconds 30 -PreserveStandardOutput $true
    if ($namespaceResult.exit_code -ne 0 -or $namespaceResult.timed_out) {
        $status["status"] = "error"
        $status["message"] = "Could not render the monitoring namespace manifest."
        Add-Check -Id "workload_observability_namespace_render" -Label "Workload observability namespace render" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required = $true
            error    = $namespaceResult.stderr
        }
        return $status
    }
    $namespaceApply = Invoke-SanitizedInputCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "apply", "--filename", "-") -StandardInput ([string]$namespaceResult.stdout) -TimeoutSeconds 45
    if ($namespaceApply.exit_code -ne 0 -or $namespaceApply.timed_out) {
        $status["status"] = "error"
        $status["message"] = "Could not create or verify the monitoring namespace."
        Add-Check -Id "workload_observability_namespace" -Label "Workload observability namespace" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required = $true
            error    = $namespaceApply.stderr
        }
        return $status
    }
    Add-Check -Id "workload_observability_namespace" -Label "Workload observability namespace" -Status "ok" -Message "monitoring namespace is present in devdeploy-workload." -Details @{
        required  = $true
        namespace = $ObservabilityNamespace
    }

    $secretExists = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "--namespace", $ObservabilityNamespace, "get", "secret", $ObservabilityGrafanaAdminSecretName, "--output", "name") -TimeoutSeconds 20
    if ($secretExists.exit_code -ne 0 -or $secretExists.timed_out) {
        $secretManifest = New-GrafanaCredentialSecretManifest
        $secretApply = Invoke-SanitizedInputCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "apply", "--filename", "-") -StandardInput ($secretManifest | ConvertTo-Json -Depth 8 -Compress) -TimeoutSeconds 45
        if ($secretApply.exit_code -ne 0 -or $secretApply.timed_out) {
            $status["status"] = "error"
            $status["message"] = "Grafana admin Secret could not be created or verified."
            Add-Check -Id "workload_observability_grafana_secret" -Label "Grafana admin Secret" -Status "failed" -Message ([string]$status["message"]) -Details @{
                required = $true
                secret_name = $ObservabilityGrafanaAdminSecretName
                secret_value_logged = $false
                error = $secretApply.stderr
            }
            return $status
        }
    }
    $status["grafana_secret_present"] = $true
    Add-Check -Id "workload_observability_grafana_secret" -Label "Grafana admin Secret" -Status "ok" -Message "Grafana admin Secret exists; the generated password was not logged or written to status." -Details @{
        required = $true
        secret_name = $ObservabilityGrafanaAdminSecretName
        secret_value_logged = $false
    }

    foreach ($repo in @(
            @{ name = $ObservabilityPrometheusRepoName; url = $ObservabilityPrometheusRepoUrl },
            @{ name = $ObservabilityGrafanaRepoName; url = $ObservabilityGrafanaRepoUrl }
        )) {
        $repoAdd = Invoke-ReadOnlyCommand -FileName $HelmCommand -Arguments @("repo", "add", [string]$repo.name, [string]$repo.url, "--force-update") -TimeoutSeconds 60
        if ($repoAdd.exit_code -ne 0 -or $repoAdd.timed_out) {
            $status["status"] = "error"
            $status["message"] = "Could not add or update an observability Helm repository."
            Add-Check -Id "workload_observability_helm_repository" -Label "Workload observability Helm repository" -Status "failed" -Message ([string]$status["message"]) -Details @{
                required = $true
                repository = [string]$repo.url
                error = $repoAdd.stderr
            }
            return $status
        }
    }
    $repoUpdate = Invoke-ReadOnlyCommand -FileName $HelmCommand -Arguments @("repo", "update", $ObservabilityPrometheusRepoName, $ObservabilityGrafanaRepoName) -TimeoutSeconds 180
    if ($repoUpdate.exit_code -ne 0 -or $repoUpdate.timed_out) {
        $status["status"] = "error"
        $status["message"] = "Could not refresh observability Helm repositories."
        Add-Check -Id "workload_observability_helm_repository" -Label "Workload observability Helm repository" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required = $true
            error = $repoUpdate.stderr
        }
        return $status
    }
    Add-Check -Id "workload_observability_helm_repository" -Label "Workload observability Helm repository" -Status "ok" -Message "Official Prometheus and Grafana Helm repositories are configured." -Details @{
        required = $true
    }

    $datasourceApply = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "apply", "--filename", $ObservabilityGrafanaDatasourcesPath) -TimeoutSeconds 45
    if ($datasourceApply.exit_code -ne 0 -or $datasourceApply.timed_out) {
        $status["status"] = "error"
        $status["message"] = "Grafana Loki datasource ConfigMap could not be reconciled."
        Add-Check -Id "workload_observability_datasources" -Label "Grafana datasources" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required = $true
            manifest = $ObservabilityGrafanaDatasourcesPath
            error = $datasourceApply.stderr
        }
        return $status
    }
    $status["datasources_configured"] = $true
    Add-Check -Id "workload_observability_datasources" -Label "Grafana datasources" -Status "ok" -Message "Grafana Loki datasource ConfigMap is reconciled; kube-prometheus-stack provides the default Prometheus datasource." -Details @{
        required = $true
        secret_values_written = $false
    }

    $helmInstalls = @(
        @{
            id = "workload_observability_prometheus_release"
            release = $ObservabilityPrometheusRelease
            chart = $ObservabilityPrometheusChart
            version = $ObservabilityPrometheusChartVersion
            values = $ObservabilityPrometheusValuesPath
        },
        @{
            id = "workload_observability_loki_release"
            release = $ObservabilityLokiRelease
            chart = $ObservabilityLokiChart
            version = $ObservabilityLokiChartVersion
            values = $ObservabilityLokiValuesPath
        },
        @{
            id = "workload_observability_alloy_release"
            release = $ObservabilityAlloyRelease
            chart = $ObservabilityAlloyChart
            version = $ObservabilityAlloyChartVersion
            values = $ObservabilityAlloyValuesPath
        }
    )
    foreach ($install in $helmInstalls) {
        $releaseStatusResult = Invoke-ReadOnlyCommand -FileName $HelmCommand -Arguments @("--kube-context", "kind-devdeploy-workload", "status", [string]$install.release, "--namespace", $ObservabilityNamespace, "--output", "json") -TimeoutSeconds 30 -PreserveStandardOutput $true
        if ($releaseStatusResult.exit_code -eq 0 -and -not $releaseStatusResult.timed_out -and -not [string]::IsNullOrWhiteSpace($releaseStatusResult.stdout)) {
            try {
                $releaseStatus = ([string]$releaseStatusResult.stdout | ConvertFrom-Json).info.status
                if ([string]$releaseStatus -in @("pending-install", "pending-upgrade", "pending-rollback")) {
                    $status["status"] = "error"
                    $status["message"] = ("Helm release {0} is stuck in {1}. Resolve the pending release state, then rerun -BootstrapWorkloadObservability." -f [string]$install.release, [string]$releaseStatus)
                    Add-Check -Id ([string]$install.id) -Label "Workload observability Helm release" -Status "failed" -Message ([string]$status["message"]) -Details @{
                        required = $true
                        release = [string]$install.release
                        chart = [string]$install.chart
                        chart_version = [string]$install.version
                        helm_status = [string]$releaseStatus
                        safe_recovery = ("helm --kube-context kind-devdeploy-workload --namespace {0} history {1}" -f $ObservabilityNamespace, [string]$install.release)
                        deletes_resources = $false
                    }
                    return $status
                }
            }
            catch {
                Write-LauncherLog ("Could not parse Helm status for release {0}: {1}" -f [string]$install.release, $_.Exception.Message)
            }
        }

        $helmArgs = @(
            "upgrade", "--install", [string]$install.release, [string]$install.chart,
            "--version", [string]$install.version,
            "--namespace", $ObservabilityNamespace,
            "--kube-context", "kind-devdeploy-workload",
            "--values", [string]$install.values,
            "--wait",
            "--timeout", "10m"
        )
        $result = Invoke-ReadOnlyCommand -FileName $HelmCommand -Arguments $helmArgs -TimeoutSeconds 720
        if ($result.exit_code -ne 0 -or $result.timed_out) {
            $status["status"] = "error"
            $status["message"] = "A workload observability Helm release failed to install or upgrade."
            Add-Check -Id ([string]$install.id) -Label "Workload observability Helm release" -Status "failed" -Message ([string]$status["message"]) -Details @{
                required = $true
                release = [string]$install.release
                chart = [string]$install.chart
                chart_version = [string]$install.version
                error = $result.stderr
            }
            return $status
        }
        Add-Check -Id ([string]$install.id) -Label "Workload observability Helm release" -Status "ok" -Message ("{0} Helm release is installed or reconciled." -f [string]$install.release) -Details @{
            required = $true
            release = [string]$install.release
            chart = [string]$install.chart
            chart_version = [string]$install.version
        }
    }

    $prometheusReady = Invoke-WorkloadObservabilityRolloutCheck -Id "workload_observability_prometheus_ready" -Kind "statefulset" -Name "prometheus-kube-prometheus-stack-prometheus"
    $grafanaReady = Invoke-WorkloadObservabilityRolloutCheck -Id "workload_observability_grafana_ready" -Kind "deployment" -Name "kube-prometheus-stack-grafana" -Required $false
    $lokiReady = Invoke-WorkloadObservabilityRolloutCheck -Id "workload_observability_loki_ready" -Kind "statefulset" -Name "loki"
    $alloyReady = Invoke-WorkloadObservabilityRolloutCheck -Id "workload_observability_alloy_ready" -Kind "daemonset" -Name "alloy"

    $backendConfigResult = Invoke-EnsureManagementBackendWorkloadKubeconfigSecret -KubectlAvailable $KubectlAvailable
    $status["backend_configured"] = [bool]$backendConfigResult["configured"]

    $allReady = [bool]($prometheusReady -and $lokiReady -and $alloyReady -and [bool]$backendConfigResult["configured"])
    $status["installed"] = $allReady
    $status["ready"] = $allReady
    $status["status"] = if ($allReady) { "ready" } else { "error" }
    $status["message"] = if ($allReady) { "Workload observability stack is installed and backend service-proxy configuration is prepared." } else { "Workload observability bootstrap completed with one or more failed readiness checks." }
    $status["checked_at"] = [string](Get-Timestamp)
    if (-not $grafanaReady -and $allReady) {
        $status["status"] = "warning"
        $status["message"] = "Prometheus, Loki, Alloy, and backend transport are ready. Grafana is optional and needs review."
    }
    return $status
}

function Invoke-EnsureManagementBackendWorkloadKubeconfigSecret {
    param(
        [bool]$KubectlAvailable
    )

    $result = [ordered]@{
        configured = $false
        secret_name = $BackendWorkloadKubeconfigSecretName
        service_account = $ObservabilityReaderServiceAccountName
        permission_scope = "monitoring/services/proxy:get"
    }
    if (-not $KubectlAvailable) {
        Add-Check -Id "workload_observability_backend_kubeconfig" -Label "Backend workload kubeconfig Secret" -Status "failed" -Message "kubectl is required to create the backend workload kubeconfig Secret." -Details @{
            required = $true
            secret_name = $BackendWorkloadKubeconfigSecretName
        }
        return $result
    }

    $readerRbacApply = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "apply", "--filename", $ObservabilityReaderRbacPath) -TimeoutSeconds 45
    if ($readerRbacApply.exit_code -ne 0 -or $readerRbacApply.timed_out) {
        Add-Check -Id "workload_observability_reader_rbac" -Label "Backend observability reader RBAC" -Status "failed" -Message "Could not reconcile the narrow workload observability reader RBAC." -Details @{
            required = $true
            namespace = $ObservabilityNamespace
            service_account = $ObservabilityReaderServiceAccountName
            role = $ObservabilityReaderRoleName
            permission_scope = "services:get,list,watch;services/proxy:get"
            error = $readerRbacApply.stderr
        }
        return $result
    }
    Add-Check -Id "workload_observability_reader_rbac" -Label "Backend observability reader RBAC" -Status "ok" -Message "A narrow monitoring namespace reader identity is present for backend Service proxy transport." -Details @{
        required = $true
        namespace = $ObservabilityNamespace
        service_account = $ObservabilityReaderServiceAccountName
        role = $ObservabilityReaderRoleName
        role_binding = $ObservabilityReaderRoleBindingName
        allowed_resources = @("services:get,list,watch", "services/proxy:get")
        cluster_admin = $false
        secret_data_logged = $false
    }

    $tokenBase64 = ""
    $caBase64 = ""
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        $tokenResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "--namespace", $ObservabilityNamespace, "get", "secret", $ObservabilityReaderTokenSecretName, "--output", "jsonpath={.data.token}") -TimeoutSeconds 20 -PreserveStandardOutput $true
        $caResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "--namespace", $ObservabilityNamespace, "get", "secret", $ObservabilityReaderTokenSecretName, "--output", "jsonpath={.data.ca\.crt}") -TimeoutSeconds 20 -PreserveStandardOutput $true
        if ($tokenResult.exit_code -eq 0 -and -not $tokenResult.timed_out -and $caResult.exit_code -eq 0 -and -not $caResult.timed_out -and -not [string]::IsNullOrWhiteSpace($tokenResult.stdout) -and -not [string]::IsNullOrWhiteSpace($caResult.stdout)) {
            $tokenBase64 = ([string]$tokenResult.stdout).Trim()
            $caBase64 = ([string]$caResult.stdout).Trim()
            break
        }
        Start-Sleep -Seconds 1
    }
    if ([string]::IsNullOrWhiteSpace($tokenBase64) -or [string]::IsNullOrWhiteSpace($caBase64)) {
        Add-Check -Id "workload_observability_reader_token" -Label "Backend observability reader token" -Status "failed" -Message "The workload observability reader token was not available yet." -Details @{
            required = $true
            namespace = $ObservabilityNamespace
            secret_name = $ObservabilityReaderTokenSecretName
            secret_data_logged = $false
        }
        return $result
    }
    Add-Check -Id "workload_observability_reader_token" -Label "Backend observability reader token" -Status "ok" -Message "The workload observability reader token Secret is populated; token contents were not logged." -Details @{
        required = $true
        namespace = $ObservabilityNamespace
        secret_name = $ObservabilityReaderTokenSecretName
        secret_data_logged = $false
    }

    try {
        $readerToken = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($tokenBase64))
    }
    catch {
        Add-Check -Id "workload_observability_backend_kubeconfig" -Label "Backend workload kubeconfig Secret" -Status "failed" -Message "The workload observability reader token could not be decoded safely." -Details @{
            required = $true
            secret_name = $ObservabilityReaderTokenSecretName
            secret_data_logged = $false
        }
        return $result
    }

    $hostCluster = Get-HostWorkloadKubeconfigCluster -KubectlAvailable $KubectlAvailable
    if (-not [bool]$hostCluster["ok"]) {
        Add-Check -Id "workload_observability_host_kubeconfig_endpoint" -Label "Local observability kubeconfig endpoint" -Status "failed" -Message ([string]$hostCluster["message"]) -Details @{
            required = $true
            context = [string]$hostCluster["context"]
            source = [string]$hostCluster["source"]
            kubeconfig_path_set = [bool]$hostCluster["kubeconfig_path_set"]
            kubectl_exit_code = $hostCluster["kubectl_exit_code"]
            kubectl_timed_out = $hostCluster["kubectl_timed_out"]
            kubectl_error = $hostCluster["kubectl_error"]
            secret_values_logged = $false
            insecure_skip_tls_verify = $false
            normal_workload_kubeconfig_modified = $false
        }
        $readerToken = $null
        return $result
    }
    Add-Check -Id "workload_observability_host_kubeconfig_endpoint" -Label "Local observability kubeconfig endpoint" -Status "ok" -Message "The local observability kubeconfig will use the host-reachable API endpoint from the selected workload kubeconfig context." -Details @{
        required = $true
        context = [string]$hostCluster["context"]
        source = [string]$hostCluster["source"]
        kubeconfig_path_set = [bool]$hostCluster["kubeconfig_path_set"]
        server = [string]$hostCluster["server"]
        certificate_authority_data_present = [bool]$hostCluster["certificate_authority_data_present"]
        secret_values_logged = $false
        insecure_skip_tls_verify = $false
        normal_workload_kubeconfig_modified = $false
    }

    $localKubeconfig = [ordered]@{
        apiVersion      = "v1"
        kind            = "Config"
        "current-context" = $ObservabilityKubeconfigContext
        clusters        = @(
            [ordered]@{
                name    = "devdeploy-workload"
                cluster = [ordered]@{
                    server = [string]$hostCluster["server"]
                    "certificate-authority-data" = [string]$hostCluster["certificate_authority_data"]
                }
            }
        )
        users           = @(
            [ordered]@{
                name = $ObservabilityReaderServiceAccountName
                user = [ordered]@{
                    token = $readerToken
                }
            }
        )
        contexts        = @(
            [ordered]@{
                name    = $ObservabilityKubeconfigContext
                context = [ordered]@{
                    cluster   = "devdeploy-workload"
                    user      = $ObservabilityReaderServiceAccountName
                    namespace = $ObservabilityNamespace
                }
            }
        )
    }

    $backendKubeconfig = [ordered]@{
        apiVersion      = "v1"
        kind            = "Config"
        "current-context" = $ObservabilityKubeconfigContext
        clusters        = @(
            [ordered]@{
                name    = "devdeploy-workload"
                cluster = [ordered]@{
                    server = $ExpectedWorkloadArgoCDEndpoint
                    "certificate-authority-data" = $caBase64
                }
            }
        )
        users           = @(
            [ordered]@{
                name = $ObservabilityReaderServiceAccountName
                user = [ordered]@{
                    token = $readerToken
                }
            }
        )
        contexts        = @(
            [ordered]@{
                name    = $ObservabilityKubeconfigContext
                context = [ordered]@{
                    cluster   = "devdeploy-workload"
                    user      = $ObservabilityReaderServiceAccountName
                    namespace = $ObservabilityNamespace
                }
            }
        )
    }
    $localKubeconfigJson = ($localKubeconfig | ConvertTo-Json -Depth 16)
    $backendKubeconfigJson = ($backendKubeconfig | ConvertTo-Json -Depth 16)
    Set-ContentAtomicUtf8 -Path $ObservabilityLocalKubeconfigPath -Value $localKubeconfigJson
    Add-Check -Id "workload_observability_local_kubeconfig" -Label "Local observability kubeconfig" -Status "ok" -Message "A launcher-managed narrow observability kubeconfig was written under .devdeploy for local backend development." -Details @{
        required = $false
        path = $ObservabilityLocalKubeconfigRelativePath
        context = $ObservabilityKubeconfigContext
        service_account = $ObservabilityReaderServiceAccountName
        server = [string]$hostCluster["server"]
        endpoint_source = [string]$hostCluster["source"]
        in_cluster_endpoint = $false
        certificate_authority_data_present = $true
        secret_values_logged = $false
        normal_workload_kubeconfig_modified = $false
    }
    Set-LauncherManagedObservabilityBackendEnv

    $backendSecretManifest = [ordered]@{
        apiVersion = "v1"
        kind       = "Secret"
        metadata   = [ordered]@{
            name      = $BackendWorkloadKubeconfigSecretName
            namespace = $PostgresNamespace
            labels    = [ordered]@{
                "app.kubernetes.io/managed-by" = "devdeploy-launcher"
                "app.kubernetes.io/part-of"    = "devdeploy-observability"
            }
        }
        type       = "Opaque"
        stringData = [ordered]@{
            kubeconfig = $backendKubeconfigJson
        }
    }

    $applyResult = Invoke-SanitizedInputCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "apply", "--filename", "-") -StandardInput ($backendSecretManifest | ConvertTo-Json -Depth 18 -Compress) -TimeoutSeconds 45
    if ($applyResult.exit_code -ne 0 -or $applyResult.timed_out) {
        Add-Check -Id "workload_observability_backend_kubeconfig" -Label "Backend workload kubeconfig Secret" -Status "failed" -Message "Could not reconcile the backend workload kubeconfig Secret." -Details @{
            required = $true
            secret_name = $BackendWorkloadKubeconfigSecretName
            secret_data_logged = $false
            service_account = $ObservabilityReaderServiceAccountName
            error = $applyResult.stderr
        }
        return $result
    }
    $result["configured"] = $true
    Add-Check -Id "workload_observability_backend_kubeconfig" -Label "Backend workload kubeconfig Secret" -Status "ok" -Message "Backend workload kubeconfig Secret is present in devdeploy-mgmt/devdeploy; kubeconfig contents were not logged or written to status." -Details @{
        required = $true
        secret_name = $BackendWorkloadKubeconfigSecretName
        secret_data_logged = $false
        backend_mount_path = $ObservabilityBackendMountPath
        service_account = $ObservabilityReaderServiceAccountName
        permission_scope = "monitoring/services/proxy:get"
        uses_cluster_ip = $false
        uses_service_identity = $true
    }
    $readerToken = $null
    return $result
}

function Invoke-VerifyWorkloadObservability {
    param(
        [Parameter(Mandatory = $true)]
        [object]$WorkloadCluster,

        [bool]$HelmAvailable,

        [bool]$KubectlAvailable,

        [string]$HelmCommand = "helm"
    )

    $status = New-WorkloadObservabilityStatus -Mode "verify"
    if ([string]$WorkloadCluster["status"] -ne "ready" -or -not $HelmAvailable -or -not $KubectlAvailable) {
        $status["status"] = "error"
        $status["message"] = "devdeploy-workload, Helm, and kubectl are required for read-only observability verification."
        Add-Check -Id "workload_observability_verify_prerequisites" -Label "Workload observability verification prerequisites" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required = $true
            workload_cluster_status = [string]$WorkloadCluster["status"]
            helm_available = $HelmAvailable
            kubectl_available = $KubectlAvailable
        }
        return $status
    }
    Add-Check -Id "workload_observability_verify_prerequisites" -Label "Workload observability verification prerequisites" -Status "ok" -Message "devdeploy-workload, Helm, and kubectl are available for read-only verification." -Details @{
        required = $true
        helm_command = $HelmCommand
    }

    $namespaceResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-workload", "get", "namespace", $ObservabilityNamespace, "--output", "name") -TimeoutSeconds 20
    $namespaceReady = [bool]($namespaceResult.exit_code -eq 0 -and -not $namespaceResult.timed_out)
    Add-Check -Id "workload_observability_verify_namespace" -Label "Workload observability namespace verification" -Status $(if ($namespaceReady) { "ok" } else { "failed" }) -Message $(if ($namespaceReady) { "monitoring namespace exists in devdeploy-workload." } else { "monitoring namespace could not be verified." }) -Details @{
        required = $true
        namespace = $ObservabilityNamespace
    }

    $releaseChecks = @(
        @{ release = $ObservabilityPrometheusRelease; chart_prefix = "kube-prometheus-stack" },
        @{ release = $ObservabilityLokiRelease; chart_prefix = "loki" },
        @{ release = $ObservabilityAlloyRelease; chart_prefix = "alloy" }
    )
    $releasesReady = $true
    foreach ($release in $releaseChecks) {
        $releaseResult = Invoke-ReadOnlyCommand -FileName $HelmCommand -Arguments @("--kube-context", "kind-devdeploy-workload", "list", "--namespace", $ObservabilityNamespace, "--filter", ("^{0}$" -f [string]$release.release), "--deployed", "--output", "json") -TimeoutSeconds 30 -PreserveStandardOutput $true
        $ready = [bool]($releaseResult.exit_code -eq 0 -and -not $releaseResult.timed_out -and -not [string]::IsNullOrWhiteSpace($releaseResult.stdout))
        $releasesReady = [bool]($releasesReady -and $ready)
        Add-Check -Id ("workload_observability_verify_{0}_release" -f [string]$release.release) -Label "Workload observability Helm release verification" -Status $(if ($ready) { "ok" } else { "failed" }) -Message $(if ($ready) { ("{0} Helm release is deployed." -f [string]$release.release) } else { ("{0} Helm release is not deployed." -f [string]$release.release) }) -Details @{
            required = $true
            release = [string]$release.release
        }
    }

    $prometheusReady = Invoke-WorkloadObservabilityRolloutCheck -Id "workload_observability_verify_prometheus_ready" -Kind "statefulset" -Name "prometheus-kube-prometheus-stack-prometheus"
    $grafanaReady = Invoke-WorkloadObservabilityRolloutCheck -Id "workload_observability_verify_grafana_ready" -Kind "deployment" -Name "kube-prometheus-stack-grafana" -Required $false
    $lokiReady = Invoke-WorkloadObservabilityRolloutCheck -Id "workload_observability_verify_loki_ready" -Kind "statefulset" -Name "loki"
    $alloyReady = Invoke-WorkloadObservabilityRolloutCheck -Id "workload_observability_verify_alloy_ready" -Kind "daemonset" -Name "alloy"
    $backendSecretResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $PostgresNamespace, "get", "secret", $BackendWorkloadKubeconfigSecretName, "--output", "name") -TimeoutSeconds 20
    $backendConfigured = [bool]($backendSecretResult.exit_code -eq 0 -and -not $backendSecretResult.timed_out)
    Add-Check -Id "workload_observability_verify_backend_transport" -Label "Backend observability service-proxy configuration" -Status $(if ($backendConfigured) { "ok" } else { "failed" }) -Message $(if ($backendConfigured) { "Backend workload kubeconfig Secret exists; Secret data was not read." } else { "Backend workload kubeconfig Secret is missing." }) -Details @{
        required = $true
        secret_name = $BackendWorkloadKubeconfigSecretName
        secret_data_read = $false
        uses_cluster_ip = $false
        uses_service_identity = $true
    }

    $allReady = [bool]($namespaceReady -and $releasesReady -and $prometheusReady -and $lokiReady -and $alloyReady -and $backendConfigured)
    $status["installed"] = $allReady
    $status["ready"] = $allReady
    $status["grafana_secret_present"] = $true
    $status["datasources_configured"] = $allReady
    $status["backend_configured"] = $backendConfigured
    $status["status"] = if ($allReady) { "ready" } else { "error" }
    $status["message"] = if ($allReady) { "Workload observability passed read-only verification." } else { "Workload observability verification failed one or more checks." }
    if ($allReady -and -not $grafanaReady) {
        $status["status"] = "warning"
        $status["message"] = "Prometheus, Loki, Alloy, and backend transport are ready. Grafana is optional and needs review."
    }
    $status["checked_at"] = [string](Get-Timestamp)
    return $status
}

function ConvertTo-PlatformStatusValue {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [string] -or $Value.GetType().IsValueType) {
        return $Value
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $copy[[string]$key] = ConvertTo-PlatformStatusValue -Value $Value[$key]
        }
        return $copy
    }

    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $copy = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $copy[[string]$property.Name] = ConvertTo-PlatformStatusValue -Value $property.Value
        }
        return $copy
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($item in $Value) {
            $items.Add((ConvertTo-PlatformStatusValue -Value $item)) | Out-Null
        }
        return ,([object[]]$items.ToArray())
    }

    return $Value
}

function Get-PersistedPlatformBootstrapStatus {
    if (-not (Test-Path -LiteralPath $StatusPath -PathType Leaf)) {
        return $null
    }

    try {
        $document = Get-Content -LiteralPath $StatusPath -Raw | ConvertFrom-Json
        $contract = [string](Get-NamedObjectValue -InputObject $document -Name "contract")
        $platform = Get-NamedObjectValue -InputObject $document -Name "platform_bootstrap"
        $components = Get-NamedObjectValue -InputObject $platform -Name "components"
        if ($contract -ne "devdeploy-launcher-status" -or $null -eq $platform -or $null -eq $components) {
            Write-LauncherLog "Ignoring the prior launcher status because it does not contain a compatible platform snapshot."
            return $null
        }

        return (ConvertTo-PlatformStatusValue -Value $platform)
    }
    catch {
        Write-LauncherLog "Ignoring the prior launcher status because it could not be parsed safely."
        return $null
    }
}

function Get-PersistedPlatformComponent {
    param(
        [AllowNull()]
        [object]$PlatformBootstrap,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $PlatformBootstrap) {
        return $null
    }

    $components = Get-NamedObjectValue -InputObject $PlatformBootstrap -Name "components"
    if ($null -eq $components) {
        return $null
    }

    return (Get-NamedObjectValue -InputObject $components -Name $Name)
}

function Test-PersistedPlatformComponentVerified {
    param(
        [AllowNull()]
        [object]$Component
    )

    if ($null -eq $Component) {
        return $false
    }

    $status = [string](Get-NamedObjectValue -InputObject $Component -Name "status")
    if ($status -eq "ready") {
        return $true
    }

    if ($status -ne "warning") {
        return $false
    }

    foreach ($evidenceField in @("ready", "verified", "installed", "configured", "application_present", "exists")) {
        $value = Get-NamedObjectValue -InputObject $Component -Name $evidenceField
        if ($null -ne $value -and [bool]$value) {
            return $true
        }
    }

    return $false
}

function Resolve-PlatformComponentStatus {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Current,

        [AllowNull()]
        [object]$Persisted,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$LauncherMode,

        [bool]$CurrentInspected,

        [ValidateSet("current_run", "current_live_discovery")]
        [string]$CurrentSource = "current_run"
    )

    $resolved = ConvertTo-PlatformStatusValue -Value $Current
    if ($CurrentInspected) {
        $resolved["status_source"] = $CurrentSource
        $resolved["observed_in_mode"] = $LauncherMode
        $resolved["carried_forward"] = $false
        return $resolved
    }

    if (Test-PersistedPlatformComponentVerified -Component $Persisted) {
        $resolved = ConvertTo-PlatformStatusValue -Value $Persisted
        $resolved["status_source"] = "persisted_prior_verified_state"
        $resolved["observed_in_mode"] = $LauncherMode
        $resolved["carried_forward"] = $true
        $resolved["carried_forward_at"] = [string](Get-Timestamp)
        return $resolved
    }

    $resolved["status"] = "not_checked"
    $resolved["message"] = "$Name was not checked by launcher mode $LauncherMode."
    $resolved["status_source"] = "current_mode_not_checked"
    $resolved["observed_in_mode"] = $LauncherMode
    $resolved["carried_forward"] = $false
    $resolved["checked_at"] = [string](Get-Timestamp)
    if ($resolved.Contains("mode")) {
        $resolved["mode"] = "not_checked"
    }
    foreach ($unknownField in @("installed", "ready", "verified", "configured", "exists", "application_present")) {
        if ($resolved.Contains($unknownField)) {
            $resolved[$unknownField] = $null
        }
    }
    return $resolved
}

function Test-PlatformComponentCurrentEvidence {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Component
    )

    $status = [string](Get-NamedObjectValue -InputObject $Component -Name "status")
    return [bool]($status -notin @("", "not_started", "not_checked", "unknown"))
}

function Get-GitOpsRootApplicationRuntimeStatus {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ManagementCluster,

        [bool]$KubectlAvailable
    )

    $status = New-GitOpsRootApplicationStatus
    $status["mode"] = "runtime_discovery"
    if (-not $KubectlAvailable -or [string]$ManagementCluster["status"] -ne "ready") {
        $status["status"] = "unknown"
        $status["message"] = "GitOps Root Application live status requires kubectl and a Ready management cluster."
        return $status
    }

    $result = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", "application", $GitOpsRootApplicationName, "--ignore-not-found=true", "--output", "json") -TimeoutSeconds 30 -PreserveStandardOutput $true
    if ($result.exit_code -ne 0 -or $result.timed_out) {
        $status["status"] = "unknown"
        $status["message"] = "GitOps Root Application live status could not be read safely."
        return $status
    }
    if ([string]::IsNullOrWhiteSpace([string]$result.stdout)) {
        $status["status"] = "absent"
        $status["message"] = "GitOps Root Application devdeploy-workloads-root is absent."
        return $status
    }

    try {
        $application = [string]$result.stdout | ConvertFrom-Json
        $metadata = Get-ObjectPropertyValue -InputObject $application -Name "metadata"
        $spec = Get-ObjectPropertyValue -InputObject $application -Name "spec"
        $source = Get-ObjectPropertyValue -InputObject $spec -Name "source"
        $destination = Get-ObjectPropertyValue -InputObject $spec -Name "destination"
        $runtime = Get-ObjectPropertyValue -InputObject $application -Name "status"
        $sync = Get-ObjectPropertyValue -InputObject $runtime -Name "sync"
        $health = Get-ObjectPropertyValue -InputObject $runtime -Name "health"

        $syncStatus = [string](Get-ObjectPropertyValue -InputObject $sync -Name "status")
        $healthStatus = [string](Get-ObjectPropertyValue -InputObject $health -Name "status")
        $status["exists"] = $true
        $status["application_present"] = $true
        $status["bootstrapped"] = $true
        $status["application_count"] = 1
        $status["expected_application_count"] = 1
        $status["actual"] = [ordered]@{
            namespace                 = [string](Get-ObjectPropertyValue -InputObject $metadata -Name "namespace")
            project                   = [string](Get-ObjectPropertyValue -InputObject $spec -Name "project")
            source_repo_url_sanitized = [string](Protect-GitRepositoryUrl -Url ([string](Get-ObjectPropertyValue -InputObject $source -Name "repoURL")))
            source_path               = [string](Get-ObjectPropertyValue -InputObject $source -Name "path")
            target_revision           = [string](Get-ObjectPropertyValue -InputObject $source -Name "targetRevision")
            destination_server        = [string](Get-ObjectPropertyValue -InputObject $destination -Name "server")
            destination_namespace     = [string](Get-ObjectPropertyValue -InputObject $destination -Name "namespace")
        }
        $status["sync_status"] = $syncStatus
        $status["health_status"] = $healthStatus
        $status["synced"] = [bool]($syncStatus -eq "Synced")
        $status["healthy"] = [bool]($healthStatus -eq "Healthy")
        $status["ready"] = [bool]($status["synced"] -and $status["healthy"])
        $status["status"] = if ([bool]$status["ready"]) { "ready" } else { "degraded" }
        $status["message"] = if ([bool]$status["ready"]) { "GitOps Root Application is Synced and Healthy." } else { "GitOps Root Application exists but is not both Synced and Healthy." }
        $status["checked_at"] = [string](Get-Timestamp)
        return $status
    }
    catch {
        $status["status"] = "unknown"
        $status["message"] = "GitOps Root Application live status returned malformed data."
        return $status
    }
}

function New-PlatformBootstrapStatus {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ManagementCluster,

        [Parameter(Mandatory = $true)]
        [object]$WorkloadCluster,

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
        [object]$ArgoCDStatusOverride = $null,

        [AllowNull()]
        [object]$WorkloadEndpointStatusOverride = $null,

        [AllowNull()]
        [object]$ArgoCDWorkloadClusterStatusOverride = $null,

        [AllowNull()]
        [object]$WorkloadDeployPermissionsStatusOverride = $null,

        [AllowNull()]
        [object]$GitOpsRepositoryStatusOverride = $null,

        [AllowNull()]
        [object]$GitOpsRootApplicationStatusOverride = $null,

        [AllowNull()]
        [object]$WorkloadObservabilityStatusOverride = $null,

        [AllowNull()]
        [object]$PriorPlatformBootstrap = $null,

        [Parameter(Mandatory = $true)]
        [string]$LauncherMode
    )

    $ingressCurrent = if ($null -ne $IngressStatusOverride) { $IngressStatusOverride } else { Get-ManagementIngressStatus -ManagementCluster $ManagementCluster -HelmAvailable $HelmAvailable -KubectlAvailable $KubectlAvailable }
    $ingressInspected = [bool]($null -ne $IngressStatusOverride -or ($HelmAvailable -and $KubectlAvailable -and [string]$ManagementCluster["status"] -eq "ready"))
    $ingress = Resolve-PlatformComponentStatus -Current $ingressCurrent -Persisted (Get-PersistedPlatformComponent -PlatformBootstrap $PriorPlatformBootstrap -Name "ingress_nginx") -Name "Management ingress-nginx" -LauncherMode $LauncherMode -CurrentInspected $ingressInspected -CurrentSource $(if ($null -ne $IngressStatusOverride) { "current_run" } else { "current_live_discovery" })

    $postgresCurrent = if ($null -ne $PostgresStatusOverride) { $PostgresStatusOverride } else { Get-ManagementPostgresStatus -ManagementCluster $ManagementCluster -HelmAvailable $HelmAvailable -KubectlAvailable $KubectlAvailable }
    $postgresInspected = [bool]($null -ne $PostgresStatusOverride -or ($HelmAvailable -and $KubectlAvailable -and [string]$ManagementCluster["status"] -eq "ready"))
    $postgres = Resolve-PlatformComponentStatus -Current $postgresCurrent -Persisted (Get-PersistedPlatformComponent -PlatformBootstrap $PriorPlatformBootstrap -Name "postgres") -Name "Management PostgreSQL" -LauncherMode $LauncherMode -CurrentInspected $postgresInspected -CurrentSource $(if ($null -ne $PostgresStatusOverride) { "current_run" } else { "current_live_discovery" })

    $argocdCurrent = if ($null -ne $ArgoCDStatusOverride) { $ArgoCDStatusOverride } else { Get-ManagementArgoCDRuntimeStatus -ManagementCluster $ManagementCluster -KubectlAvailable $KubectlAvailable }
    $argocd = Resolve-PlatformComponentStatus -Current $argocdCurrent -Persisted (Get-PersistedPlatformComponent -PlatformBootstrap $PriorPlatformBootstrap -Name "argocd") -Name "Management Argo CD" -LauncherMode $LauncherMode -CurrentInspected $true -CurrentSource $(if ($null -ne $ArgoCDStatusOverride) { "current_run" } else { "current_live_discovery" })

    $workloadEndpointCurrent = if ($null -ne $WorkloadEndpointStatusOverride) { $WorkloadEndpointStatusOverride } else { New-WorkloadClusterEndpointStatus }
    $workloadEndpoint = Resolve-PlatformComponentStatus -Current $workloadEndpointCurrent -Persisted (Get-PersistedPlatformComponent -PlatformBootstrap $PriorPlatformBootstrap -Name "workload_cluster_endpoint") -Name "Workload cluster endpoint" -LauncherMode $LauncherMode -CurrentInspected ([bool]($null -ne $WorkloadEndpointStatusOverride))

    $argocdWorkloadClusterCurrent = if ($null -ne $ArgoCDWorkloadClusterStatusOverride) { $ArgoCDWorkloadClusterStatusOverride } else { New-ArgoCDWorkloadClusterStatus }
    $argocdWorkloadCluster = Resolve-PlatformComponentStatus -Current $argocdWorkloadClusterCurrent -Persisted (Get-PersistedPlatformComponent -PlatformBootstrap $PriorPlatformBootstrap -Name "argocd_workload_cluster") -Name "Argo CD workload cluster registration" -LauncherMode $LauncherMode -CurrentInspected ([bool]($null -ne $ArgoCDWorkloadClusterStatusOverride))

    $workloadDeployPermissionsCurrent = if ($null -ne $WorkloadDeployPermissionsStatusOverride) { $WorkloadDeployPermissionsStatusOverride } else { New-WorkloadDeployPermissionsStatus }
    $workloadDeployPermissions = Resolve-PlatformComponentStatus -Current $workloadDeployPermissionsCurrent -Persisted (Get-PersistedPlatformComponent -PlatformBootstrap $PriorPlatformBootstrap -Name "workload_deploy_permissions") -Name "Workload deploy permissions" -LauncherMode $LauncherMode -CurrentInspected ([bool]($null -ne $WorkloadDeployPermissionsStatusOverride))

    $gitOpsRepositoryCurrent = if ($null -ne $GitOpsRepositoryStatusOverride) { $GitOpsRepositoryStatusOverride } else { New-GitOpsRepositoryStatus -RepoPath $RepoRoot }
    $gitOpsRepository = Resolve-PlatformComponentStatus -Current $gitOpsRepositoryCurrent -Persisted (Get-PersistedPlatformComponent -PlatformBootstrap $PriorPlatformBootstrap -Name "gitops_repository") -Name "GitOps repository" -LauncherMode $LauncherMode -CurrentInspected ([bool]($null -ne $GitOpsRepositoryStatusOverride))

    $gitOpsRootApplicationCurrent = if ($null -ne $GitOpsRootApplicationStatusOverride) { $GitOpsRootApplicationStatusOverride } else { Get-GitOpsRootApplicationRuntimeStatus -ManagementCluster $ManagementCluster -KubectlAvailable $KubectlAvailable }
    $gitOpsRootApplication = Resolve-PlatformComponentStatus -Current $gitOpsRootApplicationCurrent -Persisted (Get-PersistedPlatformComponent -PlatformBootstrap $PriorPlatformBootstrap -Name "gitops_root_application") -Name "GitOps Root Application" -LauncherMode $LauncherMode -CurrentInspected $true -CurrentSource $(if ($null -ne $GitOpsRootApplicationStatusOverride) { "current_run" } else { "current_live_discovery" })

    $workloadObservabilityCurrent = if ($null -ne $WorkloadObservabilityStatusOverride) { $WorkloadObservabilityStatusOverride } else { New-WorkloadObservabilityStatus }
    $workloadObservability = Resolve-PlatformComponentStatus -Current $workloadObservabilityCurrent -Persisted (Get-PersistedPlatformComponent -PlatformBootstrap $PriorPlatformBootstrap -Name "workload_observability") -Name "Workload observability" -LauncherMode $LauncherMode -CurrentInspected ([bool]($null -ne $WorkloadObservabilityStatusOverride))

    $BackendImageStatus = Resolve-PlatformComponentStatus -Current $BackendImageStatus -Persisted (Get-PersistedPlatformComponent -PlatformBootstrap $PriorPlatformBootstrap -Name "backend_image") -Name "Management backend image" -LauncherMode $LauncherMode -CurrentInspected (Test-PlatformComponentCurrentEvidence -Component $BackendImageStatus)
    $BackendSecretStatus = Resolve-PlatformComponentStatus -Current $BackendSecretStatus -Persisted (Get-PersistedPlatformComponent -PlatformBootstrap $PriorPlatformBootstrap -Name "backend_secret") -Name "Management backend Secret" -LauncherMode $LauncherMode -CurrentInspected (Test-PlatformComponentCurrentEvidence -Component $BackendSecretStatus)
    $BackendStatus = Resolve-PlatformComponentStatus -Current $BackendStatus -Persisted (Get-PersistedPlatformComponent -PlatformBootstrap $PriorPlatformBootstrap -Name "backend") -Name "Management backend" -LauncherMode $LauncherMode -CurrentInspected (Test-PlatformComponentCurrentEvidence -Component $BackendStatus)
    $BackendDatabaseStatus = Resolve-PlatformComponentStatus -Current $BackendDatabaseStatus -Persisted (Get-PersistedPlatformComponent -PlatformBootstrap $PriorPlatformBootstrap -Name "backend_database") -Name "Management backend database" -LauncherMode $LauncherMode -CurrentInspected (Test-PlatformComponentCurrentEvidence -Component $BackendDatabaseStatus)
    $FrontendImageStatus = Resolve-PlatformComponentStatus -Current $FrontendImageStatus -Persisted (Get-PersistedPlatformComponent -PlatformBootstrap $PriorPlatformBootstrap -Name "frontend_image") -Name "Management frontend image" -LauncherMode $LauncherMode -CurrentInspected (Test-PlatformComponentCurrentEvidence -Component $FrontendImageStatus)
    $FrontendStatus = Resolve-PlatformComponentStatus -Current $FrontendStatus -Persisted (Get-PersistedPlatformComponent -PlatformBootstrap $PriorPlatformBootstrap -Name "frontend") -Name "Management frontend" -LauncherMode $LauncherMode -CurrentInspected (Test-PlatformComponentCurrentEvidence -Component $FrontendStatus)
    $workloadClusterComponent = Resolve-PlatformComponentStatus -Current $WorkloadCluster -Persisted (Get-PersistedPlatformComponent -PlatformBootstrap $PriorPlatformBootstrap -Name "workload_cluster") -Name "Workload cluster" -LauncherMode $LauncherMode -CurrentInspected $true -CurrentSource "current_live_discovery"
    $devdeployNamespace = Get-DevDeployNamespaceStatus -ManagementCluster $ManagementCluster -KubectlAvailable $KubectlAvailable
    $status = "not_started"
    $message = "Management platform bootstrap has not started yet."

    $ingressFailedChecks = @($Checks | Where-Object { $_.id -like "management_ingress_*" -and $_.status -eq "failed" }).Count
    $postgresFailedChecks = @($Checks | Where-Object { $_.id -like "management_postgres_*" -and $_.status -eq "failed" }).Count
    $backendFailedChecks = @($Checks | Where-Object { $_.id -like "management_backend_*" -and $_.id -notlike "management_backend_database_*" -and $_.status -eq "failed" }).Count
    $backendDatabaseFailedChecks = @($Checks | Where-Object { $_.id -like "management_backend_database_*" -and $_.status -eq "failed" }).Count
    $frontendFailedChecks = @($Checks | Where-Object { $_.id -like "management_frontend_*" -and $_.status -eq "failed" }).Count
    $argocdFailedChecks = @($Checks | Where-Object { $_.id -like "management_argocd_*" -and $_.status -eq "failed" }).Count
    $gitOpsRepositoryFailedChecks = @($Checks | Where-Object { $_.id -like "gitops_repository_*" -and $_.status -eq "failed" }).Count
    $gitOpsRootApplicationFailedChecks = @($Checks | Where-Object { $_.id -like "gitops_root_*" -and $_.status -eq "failed" }).Count
    $workloadObservabilityFailedChecks = @($Checks | Where-Object { $_.id -like "workload_observability_*" -and $_.status -eq "failed" }).Count

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
    elseif ($gitOpsRepositoryFailedChecks -gt 0 -and [string]$gitOpsRepository["status"] -ne "ready") {
        $status = "failed"
        $message = "GitOps repository configuration failed."
    }
    elseif ($gitOpsRootApplicationFailedChecks -gt 0 -and [string]$gitOpsRootApplication["status"] -notin @("ready", "warning")) {
        $status = "failed"
        $message = "GitOps Root Application bootstrap failed."
    }
    elseif ($workloadObservabilityFailedChecks -gt 0 -and [string]$workloadObservability["status"] -ne "ready") {
        $status = "failed"
        $message = "Workload observability bootstrap failed."
    }
    elseif (@(@($ingress, $postgres, $BackendStatus, $BackendDatabaseStatus, $FrontendStatus, $argocd, $argocdWorkloadCluster, $workloadDeployPermissions, $gitOpsRepository, $gitOpsRootApplication, $workloadObservability) | Where-Object { [string]$_["status"] -in @("not_checked", "unknown") }).Count -gt 0) {
        $knownReadyCount = @(@($ingress, $postgres, $BackendStatus, $BackendDatabaseStatus, $FrontendStatus, $argocd, $gitOpsRootApplication, $workloadObservability) | Where-Object { [string]$_["status"] -in @("ready", "warning") }).Count
        $status = if ($knownReadyCount -gt 0) { "partial" } else { "unknown" }
        $message = "Verified platform components are reported individually; one or more unrelated components were not checked by launcher mode $LauncherMode."
    }
    elseif ([string]$ingress["status"] -eq "ready" -and [string]$postgres["status"] -eq "ready" -and [string]$BackendStatus["status"] -in @("ready", "warning") -and [string]$BackendDatabaseStatus["status"] -eq "ready" -and [string]$FrontendStatus["status"] -in @("ready", "warning") -and [string]$argocd["status"] -eq "ready" -and [string]$argocdWorkloadCluster["status"] -in @("ready", "warning") -and [string]$workloadDeployPermissions["status"] -eq "ready" -and [string]$gitOpsRepository["status"] -eq "ready" -and [string]$gitOpsRootApplication["status"] -in @("ready", "warning") -and [bool]$gitOpsRootApplication["application_present"]) {
        $status = "partial"
        $message = "Management platform, workload registration, deploy permissions, GitOps repository, and Root Application are ready. User workload validation remains pending."
    }
    elseif ([string]$ingress["status"] -eq "ready" -and [string]$postgres["status"] -eq "ready" -and [string]$BackendStatus["status"] -in @("ready", "warning") -and [string]$BackendDatabaseStatus["status"] -eq "ready" -and [string]$FrontendStatus["status"] -in @("ready", "warning") -and [string]$argocd["status"] -eq "ready" -and [string]$argocdWorkloadCluster["status"] -in @("ready", "warning") -and [string]$workloadDeployPermissions["status"] -eq "ready" -and [string]$gitOpsRepository["status"] -eq "ready") {
        $status = "partial"
        $message = "Management platform, workload registration, deploy permissions, and the local GitOps repository path are ready. The GitOps Root Application is not configured yet."
    }
    elseif ([string]$ingress["status"] -eq "ready" -and [string]$postgres["status"] -eq "ready" -and [string]$BackendStatus["status"] -in @("ready", "warning") -and [string]$BackendDatabaseStatus["status"] -eq "ready" -and [string]$FrontendStatus["status"] -in @("ready", "warning") -and [string]$argocd["status"] -eq "ready" -and [string]$argocdWorkloadCluster["status"] -in @("ready", "warning") -and [string]$workloadDeployPermissions["status"] -eq "ready") {
        $status = "partial"
        $message = "Management platform, Argo CD registration, and namespace-scoped workload permissions are ready. The GitOps Application model is not configured yet."
    }
    elseif ([string]$ingress["status"] -eq "ready" -and [string]$postgres["status"] -eq "ready" -and [string]$BackendStatus["status"] -in @("ready", "warning") -and [string]$BackendDatabaseStatus["status"] -eq "ready" -and [string]$FrontendStatus["status"] -in @("ready", "warning") -and [string]$argocd["status"] -eq "ready" -and [string]$argocdWorkloadCluster["status"] -in @("ready", "warning")) {
        $status = "partial"
        $message = "Management platform components, Argo CD, and workload cluster registration are ready. The GitOps Application model is not configured yet."
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
    elseif ([string]$gitOpsRootApplication["status"] -in @("ready", "warning") -and [bool]$gitOpsRootApplication["application_present"]) {
        $status = "partial"
        $message = "The GitOps Root Application is configured. Platform bootstrap remains partial until the user workload flow is validated."
    }
    elseif ([string]$argocd["status"] -in @("ready", "warning") -and [string]$argocdWorkloadCluster["status"] -in @("ready", "warning") -and [string]$workloadDeployPermissions["status"] -eq "ready") {
        $status = "partial"
        $message = "Management Argo CD, workload registration, and namespace-scoped deploy permissions are ready. The GitOps Application model is not configured yet."
    }
    elseif ([string]$argocd["status"] -in @("ready", "warning") -and [string]$argocdWorkloadCluster["status"] -in @("ready", "warning")) {
        $status = "partial"
        $message = "Management Argo CD and workload cluster registration are ready. The GitOps Application model is not configured yet."
    }
    elseif ([string]$argocd["status"] -in @("ready", "warning")) {
        $status = "partial"
        $message = "Management Argo CD is ready. Workload registration and the GitOps Application model are not configured yet."
    }
    elseif ([string]$gitOpsRepository["status"] -eq "ready") {
        $status = "partial"
        $message = "The local GitOps repository path is ready. Other platform readiness remains independently reported, and the GitOps Root Application is not configured yet."
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
            workload_cluster = $workloadClusterComponent
            workload_cluster_endpoint = $workloadEndpoint
            argocd_workload_cluster = $argocdWorkloadCluster
            workload_deploy_permissions = $workloadDeployPermissions
            gitops_repository = $gitOpsRepository
            gitops_root_application = $gitOpsRootApplication
            workload_observability = $workloadObservability
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
        workload_cluster_status = [string]$workloadClusterComponent["status"]
        workload_endpoint_status = [string]$workloadEndpoint["status"]
        argocd_workload_cluster_status = [string]$argocdWorkloadCluster["status"]
        workload_deploy_permissions_status = [string]$workloadDeployPermissions["status"]
        gitops_repository_status = [string]$gitOpsRepository["status"]
        gitops_root_application_status = [string]$gitOpsRootApplication["status"]
        workload_observability_status = [string]$workloadObservability["status"]
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
    $status["mode"] = "bootstrap"

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
        "--set-string", "global.domain=",
        "--set-string", "server.ingress.hostname=",
        "--set", "server.ingress.path=$ArgoCDIngressPath",
        "--set", "server.ingress.pathType=Prefix",
        "--set", "server.ingress.tls=false",
        "--set", "configs.params.server\.insecure=true",
        "--set-string", "configs.params.server\.basehref=$ArgoCDIngressPath",
        "--set-string", "configs.params.server\.rootpath=$ArgoCDIngressPath"
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

    $ingressJsonPath = "{.spec.ingressClassName}|{.spec.rules[0].host}|{.spec.rules[0].http.paths[0].path}"
    $ingressResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", "ingress", "argocd-server", "--output", "jsonpath=$ingressJsonPath") -TimeoutSeconds 20
    $ingressParts = if ($ingressResult.exit_code -eq 0 -and -not $ingressResult.timed_out) { @(([string]$ingressResult.stdout).Split('|')) } else { @() }
    $ingressReady = [bool]($ingressParts.Count -ge 3 -and ([string]$ingressParts[0]).Trim() -eq "nginx" -and [string]::IsNullOrWhiteSpace(([string]$ingressParts[1]).Trim()) -and ([string]$ingressParts[2]).Trim() -eq $ArgoCDIngressPath)
    $status["ingress_enabled"] = $ingressReady
    Add-Check -Id "management_argocd_ingress" -Label "Argo CD Ingress" -Status $(if ($ingressReady) { "ok" } else { "failed" }) -Message $(if ($ingressReady) { "Argo CD Ingress is hostless and routes /argocd through ingress class nginx." } else { "Argo CD hostless Ingress path or ingress class verification failed." }) -Details @{
        required      = $true
        namespace     = $ArgoCDNamespace
        ingress       = "argocd-server"
        ingress_class = "nginx"
        host           = $ArgoCDIngressHost
        path           = $ArgoCDIngressPath
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
    Add-Check -Id "management_argocd_ui" -Label "Argo CD local UI" -Status $(if ($uiReady) { "ok" } else { "failed" }) -Message $(if ($uiReady) { "Argo CD UI is reachable through http://localhost:8080/argocd." } else { "Argo CD UI is not reachable through http://localhost:8080/argocd." }) -Details @{
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

function Add-ArgoCDReadinessVerification {
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

    $ready = Test-ArgoCDResourceReady -Kind $Kind -Name $Name
    Add-Check -Id $Id -Label $Label -Status $(if ($ready) { "ok" } elseif ($Required) { "failed" } else { "warning" }) -Message $(if ($ready) { "$Name exists and has at least one Ready replica." } else { "$Name is missing or does not have a Ready replica." }) -Details @{
        required  = $Required
        namespace = $ArgoCDNamespace
        kind      = $Kind
        name      = $Name
    }
    return $ready
}

function Invoke-VerifyManagementArgoCD {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ManagementCluster,

        [bool]$HelmAvailable,

        [bool]$KubectlAvailable
    )

    $status = New-ManagementArgoCDStatus
    $status["mode"] = "verify"

    if ([string]$ManagementCluster["status"] -ne "ready") {
        $status["status"] = "error"
        $status["message"] = "devdeploy-mgmt must be Ready before verifying Argo CD."
        Add-Check -Id "management_argocd_verify_cluster" -Label "Management Argo CD cluster verification" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required       = $true
            cluster_name   = "devdeploy-mgmt"
            cluster_status = [string]$ManagementCluster["status"]
        }
        return $status
    }

    Add-Check -Id "management_argocd_verify_cluster" -Label "Management Argo CD cluster verification" -Status "ok" -Message "devdeploy-mgmt is reachable and has Ready node capacity." -Details @{
        required     = $true
        cluster_name = "devdeploy-mgmt"
        context      = "kind-devdeploy-mgmt"
    }

    if (-not $HelmAvailable -or -not $KubectlAvailable) {
        $status["status"] = "error"
        $status["message"] = "Helm and kubectl are required for read-only Argo CD verification."
        Add-Check -Id "management_argocd_verify_tools" -Label "Management Argo CD verification tools" -Status "failed" -Message ([string]$status["message"]) -Details @{
            required          = $true
            helm_available    = $HelmAvailable
            kubectl_available = $KubectlAvailable
        }
        return $status
    }

    Add-Check -Id "management_argocd_verify_tools" -Label "Management Argo CD verification tools" -Status "ok" -Message "Helm and kubectl are available for read-only Argo CD verification." -Details @{
        required = $true
    }

    $namespaceResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "get", "namespace", $ArgoCDNamespace, "--output", "name") -TimeoutSeconds 20
    $namespaceReady = [bool]($namespaceResult.exit_code -eq 0 -and -not $namespaceResult.timed_out)
    Add-Check -Id "management_argocd_verify_namespace" -Label "Management Argo CD namespace verification" -Status $(if ($namespaceReady) { "ok" } else { "failed" }) -Message $(if ($namespaceReady) { "Namespace argocd exists in devdeploy-mgmt." } else { "Namespace argocd does not exist or could not be read." }) -Details @{
        required  = $true
        namespace = $ArgoCDNamespace
    }
    if (-not $namespaceReady) {
        $status["status"] = "error"
        $status["message"] = "Management Argo CD namespace verification failed. No resources were changed."
        return $status
    }

    $releaseResult = Invoke-ReadOnlyCommand -FileName "helm" -Arguments @("--kube-context", "kind-devdeploy-mgmt", "list", "--namespace", $ArgoCDNamespace, "--filter", "^$ArgoCDRelease$", "--deployed", "--output", "json") -TimeoutSeconds 30 -PreserveStandardOutput $true
    $releaseReady = $false
    $chartVersionMatches = $false
    try {
        if ($releaseResult.exit_code -eq 0 -and -not $releaseResult.timed_out -and -not [string]::IsNullOrWhiteSpace($releaseResult.stdout)) {
            $releaseItems = @(([string]$releaseResult.stdout | ConvertFrom-Json))
            $releaseItem = @($releaseItems | Where-Object { [string]$_.name -eq $ArgoCDRelease -and [string]$_.namespace -eq $ArgoCDNamespace }) | Select-Object -First 1
            if ($null -ne $releaseItem -and [string]$releaseItem.status -eq "deployed") {
                $releaseReady = $true
                $detectedChart = [string]$releaseItem.chart
                if ($detectedChart -match '^argo-cd-(.+)$') {
                    $status["chart_version"] = [string]$Matches[1]
                    $chartVersionMatches = [bool]([string]$Matches[1] -eq $ArgoCDChartVersion)
                }
            }
        }
    }
    catch {
        $releaseReady = $false
    }

    $status["installed"] = $releaseReady
    Add-Check -Id "management_argocd_verify_release" -Label "Management Argo CD Helm release verification" -Status $(if ($releaseReady) { "ok" } else { "failed" }) -Message $(if ($releaseReady) { "Helm release argocd exists and is deployed." } else { "Helm release argocd is missing or is not deployed." }) -Details @{
        required      = $true
        namespace     = $ArgoCDNamespace
        release       = $ArgoCDRelease
        chart         = $ArgoCDChart
        chart_version = [string]$status["chart_version"]
    }
    if (-not $releaseReady) {
        $status["status"] = "error"
        $status["message"] = "Management Argo CD Helm release verification failed. No resources were changed."
        return $status
    }

    Add-Check -Id "management_argocd_verify_chart_version" -Label "Management Argo CD chart version" -Status $(if ($chartVersionMatches) { "ok" } else { "warning" }) -Message $(if ($chartVersionMatches) { "Argo CD chart version matches the pinned version 10.1.0." } else { "Argo CD is deployed, but its chart version differs from the launcher pin 10.1.0." }) -Details @{
        required         = $false
        expected_version = $ArgoCDChartVersion
        detected_version = [string]$status["chart_version"]
    }

    $serverReady = Add-ArgoCDReadinessVerification -Id "management_argocd_verify_server" -Label "Argo CD server verification" -Kind "deployment" -Name "argocd-server"
    $repoServerReady = Add-ArgoCDReadinessVerification -Id "management_argocd_verify_repo_server" -Label "Argo CD repo-server verification" -Kind "deployment" -Name "argocd-repo-server"
    $controllerReady = Add-ArgoCDReadinessVerification -Id "management_argocd_verify_application_controller" -Label "Argo CD application-controller verification" -Kind "statefulset" -Name "argocd-application-controller"

    $applicationSetExistsResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", "deployment", "argocd-applicationset-controller", "--output", "name") -TimeoutSeconds 20
    $applicationSetReady = $true
    if ($applicationSetExistsResult.exit_code -eq 0 -and -not $applicationSetExistsResult.timed_out) {
        $applicationSetReady = Add-ArgoCDReadinessVerification -Id "management_argocd_verify_applicationset" -Label "Argo CD ApplicationSet verification" -Kind "deployment" -Name "argocd-applicationset-controller"
    }
    else {
        Add-Check -Id "management_argocd_verify_applicationset" -Label "Argo CD ApplicationSet verification" -Status "skipped" -Message "ApplicationSet controller is not installed; this optional component was skipped." -Details @{
            required = $false
        }
    }

    $redisDeploymentResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", "deployment", "argocd-redis", "--output", "name") -TimeoutSeconds 20
    if ($redisDeploymentResult.exit_code -eq 0 -and -not $redisDeploymentResult.timed_out) {
        $redisReady = Add-ArgoCDReadinessVerification -Id "management_argocd_verify_redis" -Label "Argo CD Redis verification" -Kind "deployment" -Name "argocd-redis"
    }
    else {
        $redisReady = Add-ArgoCDReadinessVerification -Id "management_argocd_verify_redis" -Label "Argo CD Redis verification" -Kind "statefulset" -Name "argocd-redis"
    }

    $serviceResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", "service", "argocd-server", "--output", "name") -TimeoutSeconds 20
    $serviceReady = [bool]($serviceResult.exit_code -eq 0 -and -not $serviceResult.timed_out)
    Add-Check -Id "management_argocd_verify_service" -Label "Argo CD server Service verification" -Status $(if ($serviceReady) { "ok" } else { "failed" }) -Message $(if ($serviceReady) { "argocd-server Service exists." } else { "argocd-server Service is missing or could not be read." }) -Details @{
        required  = $true
        namespace = $ArgoCDNamespace
        service   = "argocd-server"
    }

    $ingressJsonPath = "{.spec.ingressClassName}|{.spec.rules[0].host}|{.spec.rules[0].http.paths[0].path}"
    $ingressResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", "ingress", "argocd-server", "--output", "jsonpath=$ingressJsonPath") -TimeoutSeconds 20
    $ingressParts = if ($ingressResult.exit_code -eq 0 -and -not $ingressResult.timed_out) { @(([string]$ingressResult.stdout).Split('|')) } else { @() }
    $ingressReady = [bool]($ingressParts.Count -ge 3 -and ([string]$ingressParts[0]).Trim() -eq "nginx" -and [string]::IsNullOrWhiteSpace(([string]$ingressParts[1]).Trim()) -and ([string]$ingressParts[2]).Trim() -eq $ArgoCDIngressPath)
    $status["ingress_enabled"] = $ingressReady
    Add-Check -Id "management_argocd_verify_ingress" -Label "Argo CD Ingress verification" -Status $(if ($ingressReady) { "ok" } else { "failed" }) -Message $(if ($ingressReady) { "Argo CD Ingress is hostless and routes /argocd through class nginx." } else { "Argo CD hostless Ingress path or class verification failed." }) -Details @{
        required      = $true
        namespace     = $ArgoCDNamespace
        ingress       = "argocd-server"
        ingress_class = "nginx"
        host           = $ArgoCDIngressHost
        path           = $ArgoCDIngressPath
    }

    $uiReady = Test-ManagementArgoCDUi
    Add-Check -Id "management_argocd_verify_ui" -Label "Argo CD local UI verification" -Status $(if ($uiReady) { "ok" } else { "failed" }) -Message $(if ($uiReady) { "Argo CD UI is reachable through its hostless /argocd ingress route." } else { "Argo CD UI is not reachable through its hostless /argocd ingress route." }) -Details @{
        required = $true
        url      = $ArgoCDUiAccess
    }

    $adminSecretResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", "secret", "argocd-initial-admin-secret", "--output", "name") -TimeoutSeconds 20
    $adminSecretReady = [bool]($adminSecretResult.exit_code -eq 0 -and -not $adminSecretResult.timed_out)
    $status["admin_secret_present"] = $adminSecretReady
    Add-Check -Id "management_argocd_verify_admin_secret" -Label "Argo CD initial admin Secret verification" -Status $(if ($adminSecretReady) { "ok" } else { "warning" }) -Message $(if ($adminSecretReady) { "Argo CD initial admin Secret exists; its value was not read or printed." } else { "Argo CD initial admin Secret was not found. No Secret data was read." }) -Details @{
        required    = $false
        namespace   = $ArgoCDNamespace
        secret_name = "argocd-initial-admin-secret"
        value_read  = $false
    }

    $applicationsResult = Invoke-ReadOnlyCommand -FileName "kubectl" -Arguments @("--context", "kind-devdeploy-mgmt", "--namespace", $ArgoCDNamespace, "get", "applications.argoproj.io", "--output", "jsonpath={.items[*].metadata.name}") -TimeoutSeconds 20
    $applicationCountKnown = [bool]($applicationsResult.exit_code -eq 0 -and -not $applicationsResult.timed_out)
    if ($applicationCountKnown) {
        $applicationNames = @(([string]$applicationsResult.stdout) -split "\s+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $status["application_count"] = [int]$applicationNames.Count
    }
    Add-Check -Id "management_argocd_verify_applications" -Label "Argo CD Application inventory" -Status $(if ($applicationCountKnown) { "ok" } else { "warning" }) -Message $(if ($applicationCountKnown) { "Argo CD Application count was read without modifying Applications." } else { "Argo CD Application count could not be determined safely." }) -Details @{
        required          = $false
        application_count = $status["application_count"]
        read_only         = $true
    }

    $coreReady = [bool]($serverReady -and $repoServerReady -and $controllerReady -and $applicationSetReady -and $redisReady -and $serviceReady -and $ingressReady -and $uiReady)
    $hasWarnings = [bool](-not $chartVersionMatches -or -not $adminSecretReady -or -not $applicationCountKnown)
    $status["ready"] = $coreReady
    $status["checked_at"] = [string](Get-Timestamp)
    if (-not $coreReady) {
        $status["status"] = "error"
        $status["message"] = "Management Argo CD read-only verification found missing or unready core resources. No resources were changed."
    }
    elseif ($hasWarnings) {
        $status["status"] = "warning"
        $status["message"] = "Management Argo CD core resources are Ready, but optional verification warnings need review."
    }
    else {
        $status["status"] = "ready"
        $status["message"] = "Management Argo CD passed read-only verification."
    }

    Add-Check -Id "management_argocd_verify_ready" -Label "Management Argo CD read-only verification" -Status $(if ($coreReady) { "ok" } else { "failed" }) -Message ([string]$status["message"]) -Details @{
        required                        = $true
        namespace                       = $ArgoCDNamespace
        release                         = $ArgoCDRelease
        application_count               = $status["application_count"]
        workload_cluster_registered     = $false
        gitops_application_created      = $false
        mutation_performed              = $false
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
New-LocalDirectory -Path $ToolsDir
New-LocalDirectory -Path $KubeconfigDir
$priorPlatformBootstrap = Get-PersistedPlatformBootstrapStatus

if ($PlanWorkloadRebootstrap) {
    Write-LauncherLog "Starting DevDeploy Launcher read-only workload rebootstrap planning mode."
}
elseif ($PlanWorkloadPortRecovery) {
    Write-LauncherLog "Starting DevDeploy Launcher read-only workload port recovery planning mode."
}
elseif ($PlanManagementPortRecovery) {
    Write-LauncherLog "Starting DevDeploy Launcher read-only management port recovery planning mode."
}
elseif ($RepairDevDeployKindRestartPolicies) {
    Write-LauncherLog "Starting DevDeploy Launcher explicit DevDeploy kind restart policy repair mode."
}
elseif ($CreateManagementCluster) {
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
elseif ($VerifyManagementArgoCD) {
    Write-LauncherLog "Starting DevDeploy Launcher strict read-only management Argo CD verify mode."
}
elseif ($DiscoverWorkloadClusterEndpoint) {
    Write-LauncherLog "Starting DevDeploy Launcher explicit workload cluster endpoint discovery mode."
}
elseif ($RegisterWorkloadClusterWithArgoCD) {
    Write-LauncherLog "Starting DevDeploy Launcher explicit Argo CD workload cluster registration mode."
}
elseif ($VerifyWorkloadClusterRegistration) {
    Write-LauncherLog "Starting DevDeploy Launcher strict read-only workload cluster registration verification mode."
}
elseif ($GrantWorkloadDeployPermissions) {
    Write-LauncherLog "Starting DevDeploy Launcher explicit namespace-scoped workload deploy permission grant mode."
}
elseif ($VerifyWorkloadDeployPermissions) {
    Write-LauncherLog "Starting DevDeploy Launcher strict read-only workload deploy permission verification mode."
}
elseif ($ConfigureGitOpsRepository) {
    Write-LauncherLog "Starting DevDeploy Launcher explicit local GitOps repository configuration mode."
}
elseif ($BootstrapGitOpsRootApplication) {
    Write-LauncherLog "Starting DevDeploy Launcher explicit GitOps Root Application bootstrap mode."
}
elseif ($VerifyGitOpsRootApplication) {
    Write-LauncherLog "Starting DevDeploy Launcher strict read-only GitOps Root Application verification mode."
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

$managementIntegrityRequired = [bool](Test-ManagementClusterIntegrityRequired)
$dockerAvailable = Test-CommandAvailable -Name "docker" -Label "Docker CLI" -Required ([bool]($managementIntegrityRequired -or -not ($EnsureManagementBackendSecret -or $VerifyManagementBackendSecret -or $VerifyManagementBackend -or $BootstrapManagementFrontend -or $VerifyManagementFrontend -or $BootstrapManagementArgoCD -or $VerifyManagementArgoCD -or $RegisterWorkloadClusterWithArgoCD -or $VerifyWorkloadClusterRegistration -or $GrantWorkloadDeployPermissions -or $VerifyWorkloadDeployPermissions -or $ConfigureGitOpsRepository -or $BootstrapGitOpsRootApplication -or $VerifyGitOpsRootApplication -or $InitializeManagementBackendDatabase)))
$kindAvailable = Test-CommandAvailable -Name "kind" -Label "kind CLI" -Required ([bool](-not ($BuildManagementBackendImage -or $BuildManagementFrontendImage -or $ConfigureGitOpsRepository)))
$kubectlAvailable = Test-CommandAvailable -Name "kubectl" -Label "kubectl CLI" -Required ([bool](-not ($BuildManagementBackendImage -or $BuildManagementFrontendImage -or $ConfigureGitOpsRepository)))
$gitAvailable = Test-CommandAvailable -Name "git" -Label "git CLI" -Required ([bool]($ConfigureGitOpsRepository -or $BootstrapGitOpsRootApplication))
$helmAvailable = $false
if (-not ($BootstrapWorkloadObservability -or $VerifyWorkloadObservability)) {
    $helmAvailable = Test-CommandAvailable -Name "helm" -Label "Helm CLI" -Required ([bool]($BootstrapManagementIngress -or $BootstrapManagementPostgres -or $BootstrapManagementArgoCD -or $VerifyManagementArgoCD -or $RegisterWorkloadClusterWithArgoCD))
}
$workloadObservabilityHelmCommand = "helm"
if ($BootstrapWorkloadObservability -or $VerifyWorkloadObservability) {
    $workloadObservabilityHelm = Resolve-WorkloadObservabilityHelm -BootstrapMode ([bool]$BootstrapWorkloadObservability)
    $helmAvailable = [bool]$workloadObservabilityHelm["available"]
    if ($helmAvailable) {
        $workloadObservabilityHelmCommand = [string]$workloadObservabilityHelm["command"]
    }
}

if (-not $managementIntegrityRequired -and ($EnsureManagementBackendSecret -or $VerifyManagementBackendSecret -or $VerifyManagementBackend -or $BootstrapManagementFrontend -or $VerifyManagementFrontend -or $BootstrapManagementArgoCD -or $VerifyManagementArgoCD -or $RegisterWorkloadClusterWithArgoCD -or $VerifyWorkloadClusterRegistration -or $GrantWorkloadDeployPermissions -or $VerifyWorkloadDeployPermissions -or $ConfigureGitOpsRepository -or $BootstrapGitOpsRootApplication -or $VerifyGitOpsRootApplication -or $InitializeManagementBackendDatabase)) {
    $dockerDaemonReachable = $false
    Add-Check -Id "docker_daemon" -Label "Docker daemon" -Status "skipped" -Message "Docker daemon check is not required for this launcher mode." -Details @{
        required = $false
    }
}
else {
    $dockerDaemonReachable = Test-DockerDaemon -DockerCliAvailable $dockerAvailable
    $dockerFollowUpMode = [bool](
        $BuildManagementBackendImage -or
        $LoadManagementBackendImage -or
        $BuildManagementFrontendImage -or
        $LoadManagementFrontendImage -or
        $BootstrapManagementFrontend -or
        $BootstrapWorkloadObservability -or
        $VerifyWorkloadObservability
    )
    if (-not $dockerDaemonReachable -and $dockerFollowUpMode) {
        $dockerDaemonReachable = Test-DockerDaemonFollowUp -DockerCliAvailable $dockerAvailable
    }
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

$PortSelection = Resolve-LauncherPortPlan -DockerAvailable $dockerAvailable -DockerDaemonReachable $dockerDaemonReachable -ManagementClusterExists $managementClusterExistsBeforePortCheck -WorkloadClusterExists $workloadClusterExistsBeforePortCheck

foreach ($entry in $PortPlan.GetEnumerator()) {
    $portKey = [string]$entry.Key
    $isManagementPort = $portKey -in @("management_api", "management_http", "management_https")
    $isWorkloadPort = $portKey -in @("workload_api", "workload_http", "workload_https")
    $expectedCluster = if ($isManagementPort) { "devdeploy-mgmt" } elseif ($isWorkloadPort) { "devdeploy-workload" } else { "" }
    $existingClusterDetected = [bool](($isManagementPort -and $managementClusterExistsBeforePortCheck) -or ($isWorkloadPort -and $workloadClusterExistsBeforePortCheck))
    $portRequired = [bool](-not $existingClusterDetected)
    if (($BootstrapManagementIngress -or $BootstrapManagementPostgres -or $BootstrapManagementArgoCD -or $VerifyManagementArgoCD -or $DiscoverWorkloadClusterEndpoint -or $RegisterWorkloadClusterWithArgoCD -or $VerifyWorkloadClusterRegistration -or $GrantWorkloadDeployPermissions -or $VerifyWorkloadDeployPermissions -or $VerifyGitOpsRootApplication) -and $isWorkloadPort) {
        $portRequired = $false
    }
    if ($BuildManagementBackendImage -or $BuildManagementFrontendImage -or $LoadManagementFrontendImage -or $BootstrapManagementFrontend -or $VerifyManagementFrontend -or $BootstrapManagementArgoCD -or $VerifyManagementArgoCD -or $DiscoverWorkloadClusterEndpoint -or $RegisterWorkloadClusterWithArgoCD -or $VerifyWorkloadClusterRegistration -or $GrantWorkloadDeployPermissions -or $VerifyWorkloadDeployPermissions -or $ConfigureGitOpsRepository -or $BootstrapGitOpsRootApplication -or $VerifyGitOpsRootApplication -or $InitializeManagementBackendDatabase -or $LoadManagementBackendImage -or $EnsureManagementBackendSecret -or $VerifyManagementBackendSecret -or $BootstrapManagementBackend -or $VerifyManagementBackend) {
        $portRequired = $false
    }
    $allowBusyAsOk = [bool]$existingClusterDetected

    Test-LocalPortAvailable -Port ([int]$entry.Value) -Required $portRequired -AllowBusyAsOk $allowBusyAsOk -ExpectedCluster $expectedCluster -ExistingClusterDetected $existingClusterDetected
}

if ($workloadClusterExistsBeforePortCheck) {
    $detectedStatus = if ($CreateWorkloadCluster -or $BootstrapManagementIngress -or $BootstrapManagementPostgres -or $BuildManagementBackendImage -or $BuildManagementFrontendImage -or $LoadManagementFrontendImage -or $BootstrapManagementFrontend -or $VerifyManagementFrontend -or $BootstrapManagementArgoCD -or $VerifyManagementArgoCD -or $DiscoverWorkloadClusterEndpoint -or $RegisterWorkloadClusterWithArgoCD -or $VerifyWorkloadClusterRegistration -or $GrantWorkloadDeployPermissions -or $VerifyWorkloadDeployPermissions -or $ConfigureGitOpsRepository -or $BootstrapGitOpsRootApplication -or $VerifyGitOpsRootApplication -or $InitializeManagementBackendDatabase -or $LoadManagementBackendImage -or $EnsureManagementBackendSecret -or $VerifyManagementBackendSecret -or $BootstrapManagementBackend -or $VerifyManagementBackend) { "ok" } else { "warning" }
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
    elseif ($VerifyManagementArgoCD) {
        "devdeploy-workload already exists. Argo CD verify mode is read-only and targets only devdeploy-mgmt."
    }
    elseif ($DiscoverWorkloadClusterEndpoint) {
        "devdeploy-workload already exists. Endpoint discovery reads its metadata and does not create registration resources in it."
    }
    elseif ($RegisterWorkloadClusterWithArgoCD) {
        "devdeploy-workload already exists. This explicit mode reconciles only its dedicated Argo CD registration identity and management-cluster registration Secret."
    }
    elseif ($VerifyWorkloadClusterRegistration) {
        "devdeploy-workload already exists. Registration verification reads metadata and authorization state without modifying the workload cluster."
    }
    elseif ($GrantWorkloadDeployPermissions) {
        "devdeploy-workload already exists. This explicit mode reconciles only devdeploy-apps and its namespaced Role/RoleBinding."
    }
    elseif ($VerifyWorkloadDeployPermissions) {
        "devdeploy-workload already exists. Permission verification reads namespace, RBAC, and authorization state without modifying the workload cluster."
    }
    elseif ($ConfigureGitOpsRepository) {
        "devdeploy-workload already exists. Local GitOps repository configuration does not use, modify, or delete it."
    }
    elseif ($BootstrapGitOpsRootApplication) {
        "devdeploy-workload already exists. Root Application bootstrap verifies its registration, namespace, permissions, and empty workload inventory without applying user workloads."
    }
    elseif ($VerifyGitOpsRootApplication) {
        "devdeploy-workload already exists. Root Application verification reads only Application and workload inventory state without modifying either cluster."
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

Test-KindClusters -KindAvailable $kindAvailable -ManagementCreateMode ([bool]$CreateManagementCluster) -WorkloadCreateMode ([bool]$CreateWorkloadCluster) -ManagementIngressBootstrapMode ([bool]$BootstrapManagementIngress) -ManagementPostgresBootstrapMode ([bool]$BootstrapManagementPostgres) -ManagementBackendImageBuildMode ([bool]$BuildManagementBackendImage) -ManagementBackendImageLoadMode ([bool]$LoadManagementBackendImage) -ManagementBackendSecretEnsureMode ([bool]$EnsureManagementBackendSecret) -ManagementBackendSecretVerifyMode ([bool]$VerifyManagementBackendSecret) -ManagementBackendBootstrapMode ([bool]$BootstrapManagementBackend) -ManagementBackendVerifyMode ([bool]$VerifyManagementBackend) -ManagementFrontendImageBuildMode ([bool]$BuildManagementFrontendImage) -ManagementFrontendImageLoadMode ([bool]$LoadManagementFrontendImage) -ManagementFrontendBootstrapMode ([bool]$BootstrapManagementFrontend) -ManagementBackendDatabaseInitializeMode ([bool]$InitializeManagementBackendDatabase) -ManagementFrontendVerifyMode ([bool]$VerifyManagementFrontend) -ManagementArgoCDBootstrapMode ([bool]$BootstrapManagementArgoCD) -ManagementArgoCDVerifyMode ([bool]$VerifyManagementArgoCD) -WorkloadEndpointDiscoveryMode ([bool]$DiscoverWorkloadClusterEndpoint) -WorkloadArgoCDRegistrationMode ([bool]$RegisterWorkloadClusterWithArgoCD) -WorkloadArgoCDVerificationMode ([bool]$VerifyWorkloadClusterRegistration) -WorkloadDeployPermissionGrantMode ([bool]$GrantWorkloadDeployPermissions) -WorkloadDeployPermissionVerifyMode ([bool]$VerifyWorkloadDeployPermissions) -GitOpsRepositoryConfigureMode ([bool]$ConfigureGitOpsRepository) -GitOpsRootApplicationBootstrapMode ([bool]$BootstrapGitOpsRootApplication) -GitOpsRootApplicationVerifyMode ([bool]$VerifyGitOpsRootApplication)
if ($VerifyGitOpsRootApplication) {
    Add-Check -Id "kubectl_context" -Label "kubectl current context" -Status "skipped" -Message "Root Application verification uses explicit kubectl contexts and does not read or change the current context." -Details @{
        required  = $false
        read_only = $true
    }
}
else {
    Test-KubectlContext -KubectlAvailable $kubectlAvailable
}

$launcherMode = "preflight"
if ($PlanWorkloadRebootstrap) {
    $launcherMode = "workload_rebootstrap_plan"
}
elseif ($PlanWorkloadPortRecovery) {
    $launcherMode = "workload_port_recovery_plan"
}
elseif ($PlanManagementPortRecovery) {
    $launcherMode = "management_port_recovery_plan"
}
elseif ($RepairDevDeployKindRestartPolicies) {
    $launcherMode = "devdeploy_kind_restart_policy_repair"
}
elseif ($CreateManagementCluster) {
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
elseif ($VerifyManagementArgoCD) {
    $launcherMode = "management_argocd_verify"
}
elseif ($DiscoverWorkloadClusterEndpoint) {
    $launcherMode = "workload_cluster_endpoint_discovery"
}
elseif ($RegisterWorkloadClusterWithArgoCD) {
    $launcherMode = "workload_cluster_argocd_registration"
}
elseif ($VerifyWorkloadClusterRegistration) {
    $launcherMode = "workload_cluster_argocd_registration_verify"
}
elseif ($GrantWorkloadDeployPermissions) {
    $launcherMode = "workload_deploy_permissions_grant"
}
elseif ($VerifyWorkloadDeployPermissions) {
    $launcherMode = "workload_deploy_permissions_verify"
}
elseif ($ConfigureGitOpsRepository) {
    $launcherMode = "gitops_repository_configure"
}
elseif ($BootstrapGitOpsRootApplication) {
    $launcherMode = "gitops_root_application_bootstrap"
}
elseif ($VerifyGitOpsRootApplication) {
    $launcherMode = "gitops_root_application_verify"
}
elseif ($BootstrapWorkloadObservability) {
    $launcherMode = "workload_observability_bootstrap"
}
elseif ($VerifyWorkloadObservability) {
    $launcherMode = "workload_observability_verify"
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
$platformWorkloadEndpointOverride = $null
$platformArgoCDWorkloadClusterOverride = $null
$platformWorkloadDeployPermissionsOverride = $null
$platformGitOpsRepositoryOverride = $null
$platformGitOpsRootApplicationOverride = $null
$platformWorkloadObservabilityOverride = $null

if ($CreateManagementCluster) {
    Write-KindConfigPreview -Id "management_kind_config" -Label "Management kind config" -ClusterName "devdeploy-mgmt" -Path $MgmtKindConfigPath -ApiServerPort ([int]$PortPlan["management_api"]) -HttpHostPort ([int]$PortPlan["management_http"]) -HttpsHostPort ([int]$PortPlan["management_https"])

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
    Reset-CanonicalManagementClusterStatus
}
elseif ($CreateWorkloadCluster) {
    Write-KindConfigPreview -Id "workload_kind_config" -Label "Workload kind config" -ClusterName "devdeploy-workload" -Path $WorkloadKindConfigPath -ApiServerPort ([int]$PortPlan["workload_api"]) -HttpHostPort ([int]$PortPlan["workload_http"]) -HttpsHostPort ([int]$PortPlan["workload_https"])

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
elseif ($RepairDevDeployKindRestartPolicies) {
    Invoke-DevDeployKindRestartPolicyRepair -DockerAvailable $dockerAvailable -DockerDaemonReachable $dockerDaemonReachable | Out-Null
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
    if ([string]$frontendStatus["status"] -eq "ready" -and [string]$managementCluster["integrity_status"] -eq "ok") {
        Set-DockerDaemonCheckFromEvidence -Evidence "management_kind_integrity_and_frontend_rollout" | Out-Null
        $dockerDaemonReachable = $true
    }
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
elseif ($VerifyManagementArgoCD) {
    $managementCluster = New-ManagementClusterStatus -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable
    $platformArgoCDOverride = Invoke-VerifyManagementArgoCD -ManagementCluster $managementCluster -HelmAvailable $helmAvailable -KubectlAvailable $kubectlAvailable
}
elseif ($DiscoverWorkloadClusterEndpoint) {
    $managementCluster = New-ManagementClusterStatus -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable
    $workloadCluster = New-WorkloadClusterStatus -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable
    $platformWorkloadEndpointOverride = Invoke-DiscoverWorkloadClusterEndpoint -ManagementCluster $managementCluster -WorkloadCluster $workloadCluster -DockerAvailable $dockerAvailable -DockerDaemonReachable $dockerDaemonReachable -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable
}
elseif ($RegisterWorkloadClusterWithArgoCD) {
    $managementCluster = New-ManagementClusterStatus -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable
    $workloadCluster = New-WorkloadClusterStatus -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable
    $platformArgoCDOverride = Get-ManagementArgoCDStatus -ManagementCluster $managementCluster -HelmAvailable $helmAvailable -KubectlAvailable $kubectlAvailable
    $platformArgoCDWorkloadClusterOverride = Invoke-RegisterWorkloadClusterWithArgoCD -ManagementCluster $managementCluster -WorkloadCluster $workloadCluster -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable -ArgoCDStatus $platformArgoCDOverride
}
elseif ($VerifyWorkloadClusterRegistration) {
    $managementCluster = New-ManagementClusterStatus -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable
    $workloadCluster = New-WorkloadClusterStatus -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable
    $platformArgoCDOverride = Get-ManagementArgoCDRuntimeStatus -ManagementCluster $managementCluster -KubectlAvailable $kubectlAvailable
    $platformArgoCDWorkloadClusterOverride = Invoke-VerifyWorkloadClusterRegistration -ManagementCluster $managementCluster -WorkloadCluster $workloadCluster -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable -ArgoCDStatus $platformArgoCDOverride
}
elseif ($GrantWorkloadDeployPermissions) {
    $managementCluster = New-ManagementClusterStatus -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable
    $workloadCluster = New-WorkloadClusterStatus -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable
    $platformArgoCDOverride = Get-ManagementArgoCDRuntimeStatus -ManagementCluster $managementCluster -KubectlAvailable $kubectlAvailable
    $platformArgoCDWorkloadClusterOverride = Invoke-VerifyWorkloadClusterRegistration -ManagementCluster $managementCluster -WorkloadCluster $workloadCluster -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable -ArgoCDStatus $platformArgoCDOverride
    $platformWorkloadDeployPermissionsOverride = Invoke-GrantWorkloadDeployPermissions -ManagementCluster $managementCluster -WorkloadCluster $workloadCluster -KubectlAvailable $kubectlAvailable -RegistrationStatus $platformArgoCDWorkloadClusterOverride
    if ([bool]$platformWorkloadDeployPermissionsOverride["ready"]) {
        $platformArgoCDWorkloadClusterOverride["write_rbac_configured"] = $true
        $platformArgoCDWorkloadClusterOverride["message"] = "Workload cluster registration is verified and namespace-scoped deploy RBAC is configured. No Application exists yet."
    }
}
elseif ($VerifyWorkloadDeployPermissions) {
    $managementCluster = New-ManagementClusterStatus -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable
    $workloadCluster = New-WorkloadClusterStatus -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable
    $platformArgoCDOverride = Get-ManagementArgoCDRuntimeStatus -ManagementCluster $managementCluster -KubectlAvailable $kubectlAvailable
    $platformArgoCDWorkloadClusterOverride = Invoke-VerifyWorkloadClusterRegistration -ManagementCluster $managementCluster -WorkloadCluster $workloadCluster -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable -ArgoCDStatus $platformArgoCDOverride
    $platformWorkloadDeployPermissionsOverride = Invoke-VerifyWorkloadDeployPermissions -ManagementCluster $managementCluster -WorkloadCluster $workloadCluster -KubectlAvailable $kubectlAvailable -RegistrationStatus $platformArgoCDWorkloadClusterOverride
    if ([bool]$platformWorkloadDeployPermissionsOverride["ready"]) {
        $platformArgoCDWorkloadClusterOverride["write_rbac_configured"] = $true
        $platformArgoCDWorkloadClusterOverride["message"] = "Workload cluster registration and namespace-scoped deploy RBAC passed read-only verification. No Application exists yet."
    }
}
elseif ($ConfigureGitOpsRepository) {
    $platformGitOpsRepositoryOverride = Invoke-ConfigureGitOpsRepository -GitAvailable $gitAvailable -KubectlAvailable $kubectlAvailable -RequestedRepoPath $GitOpsRepoPath -RequestedRepoUrl $GitOpsRepoUrl -RequestedBranch $GitOpsBranch
}
elseif ($BootstrapGitOpsRootApplication) {
    $managementCluster = New-ManagementClusterStatus -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable
    $workloadCluster = New-WorkloadClusterStatus -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable
    $platformArgoCDOverride = Get-ManagementArgoCDRuntimeStatus -ManagementCluster $managementCluster -KubectlAvailable $kubectlAvailable
    $platformArgoCDWorkloadClusterOverride = Invoke-VerifyWorkloadClusterRegistration -ManagementCluster $managementCluster -WorkloadCluster $workloadCluster -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable -ArgoCDStatus $platformArgoCDOverride
    $platformWorkloadDeployPermissionsOverride = Invoke-VerifyWorkloadDeployPermissions -ManagementCluster $managementCluster -WorkloadCluster $workloadCluster -KubectlAvailable $kubectlAvailable -RegistrationStatus $platformArgoCDWorkloadClusterOverride
    if ([bool]$platformWorkloadDeployPermissionsOverride["ready"]) {
        $platformArgoCDWorkloadClusterOverride["write_rbac_configured"] = $true
    }
    $platformGitOpsRepositoryOverride = Get-PersistedGitOpsRepositoryStatus -GitAvailable $gitAvailable -KubectlAvailable $kubectlAvailable
    $platformGitOpsRootApplicationOverride = Invoke-BootstrapGitOpsRootApplication -ManagementCluster $managementCluster -WorkloadCluster $workloadCluster -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable -ArgoCDStatus $platformArgoCDOverride -RegistrationStatus $platformArgoCDWorkloadClusterOverride -PermissionStatus $platformWorkloadDeployPermissionsOverride -RepositoryStatus $platformGitOpsRepositoryOverride
}
elseif ($VerifyGitOpsRootApplication) {
    $managementCluster = New-ManagementClusterStatus -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable
    $workloadCluster = New-WorkloadClusterStatus -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable
    $platformArgoCDOverride = Get-ManagementArgoCDRuntimeStatus -ManagementCluster $managementCluster -KubectlAvailable $kubectlAvailable
    $platformGitOpsRootApplicationOverride = Invoke-VerifyGitOpsRootApplication -ManagementCluster $managementCluster -WorkloadCluster $workloadCluster -KubectlAvailable $kubectlAvailable -ArgoCDStatus $platformArgoCDOverride
}
elseif ($BootstrapWorkloadObservability) {
    $workloadCluster = New-WorkloadClusterStatus -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable
    $platformWorkloadObservabilityOverride = Invoke-BootstrapWorkloadObservability -WorkloadCluster $workloadCluster -HelmAvailable $helmAvailable -KubectlAvailable $kubectlAvailable -HelmCommand $workloadObservabilityHelmCommand
    if ([string]$platformWorkloadObservabilityOverride["status"] -eq "ready" -and [string]$workloadCluster["integrity_status"] -eq "ok") {
        Set-DockerDaemonCheckFromEvidence -Evidence "workload_kind_integrity_and_observability_readiness" | Out-Null
        $dockerDaemonReachable = $true
    }
}
elseif ($VerifyWorkloadObservability) {
    $workloadCluster = New-WorkloadClusterStatus -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable
    $platformWorkloadObservabilityOverride = Invoke-VerifyWorkloadObservability -WorkloadCluster $workloadCluster -HelmAvailable $helmAvailable -KubectlAvailable $kubectlAvailable -HelmCommand $workloadObservabilityHelmCommand
    if ([string]$platformWorkloadObservabilityOverride["status"] -in @("ready", "warning") -and [string]$workloadCluster["integrity_status"] -eq "ok") {
        Set-DockerDaemonCheckFromEvidence -Evidence "workload_kind_integrity_and_observability_verification" | Out-Null
        $dockerDaemonReachable = $true
    }
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
    Write-KindConfigPreview -Id "kind_config_mgmt_preview" -Label "Management kind config preview" -ClusterName "devdeploy-mgmt" -Path $MgmtKindConfigPath -ApiServerPort ([int]$PortPlan["management_api"]) -HttpHostPort ([int]$PortPlan["management_http"]) -HttpsHostPort ([int]$PortPlan["management_https"])
    Write-KindConfigPreview -Id "kind_config_workload_preview" -Label "Workload kind config preview" -ClusterName "devdeploy-workload" -Path $WorkloadKindConfigPath -ApiServerPort ([int]$PortPlan["workload_api"]) -HttpHostPort ([int]$PortPlan["workload_http"]) -HttpsHostPort ([int]$PortPlan["workload_https"])
}

if ($null -eq $managementCluster) {
    $managementCluster = New-ManagementClusterStatus -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable
}
if ($null -eq $workloadCluster) {
    $workloadCluster = New-WorkloadClusterStatus -KindAvailable $kindAvailable -KubectlAvailable $kubectlAvailable
}
$platformHelmAvailable = [bool]($helmAvailable -and -not $BuildManagementBackendImage -and -not $BuildManagementFrontendImage -and -not $LoadManagementFrontendImage -and -not $BootstrapManagementFrontend -and -not $VerifyManagementFrontend -and -not $VerifyGitOpsRootApplication -and -not $InitializeManagementBackendDatabase -and -not $LoadManagementBackendImage -and -not $EnsureManagementBackendSecret -and -not $VerifyManagementBackendSecret -and -not $BootstrapManagementBackend -and -not $VerifyManagementBackend -and -not $BootstrapWorkloadObservability -and -not $VerifyWorkloadObservability)
$platformBootstrap = New-PlatformBootstrapStatus -ManagementCluster $managementCluster -WorkloadCluster $workloadCluster -HelmAvailable $platformHelmAvailable -KubectlAvailable $kubectlAvailable -BackendImageStatus $backendImageStatus -BackendSecretStatus $backendSecretStatus -BackendStatus $backendStatus -BackendDatabaseStatus $backendDatabaseStatus -FrontendImageStatus $frontendImageStatus -FrontendStatus $frontendStatus -IngressStatusOverride $platformIngressOverride -PostgresStatusOverride $platformPostgresOverride -ArgoCDStatusOverride $platformArgoCDOverride -WorkloadEndpointStatusOverride $platformWorkloadEndpointOverride -ArgoCDWorkloadClusterStatusOverride $platformArgoCDWorkloadClusterOverride -WorkloadDeployPermissionsStatusOverride $platformWorkloadDeployPermissionsOverride -GitOpsRepositoryStatusOverride $platformGitOpsRepositoryOverride -GitOpsRootApplicationStatusOverride $platformGitOpsRootApplicationOverride -WorkloadObservabilityStatusOverride $platformWorkloadObservabilityOverride -PriorPlatformBootstrap $priorPlatformBootstrap -LauncherMode $launcherMode
$workloadRebootstrapPlan = $null
$managementPortRecoveryPlan = $null
if ($PlanWorkloadRebootstrap -or $PlanWorkloadPortRecovery) {
    $workloadRebootstrapPlan = New-WorkloadRebootstrapPlan -ManagementCluster $managementCluster -WorkloadCluster $workloadCluster
    $planCheckStatus = if ([bool]$workloadRebootstrapPlan["management_healthy"]) { "ok" } else { "warning" }
    Add-Check -Id "workload_rebootstrap_plan" -Label "Workload cluster rebootstrap plan" -Status $planCheckStatus -Message "Generated a plan-only workload cluster rebootstrap sequence. No commands were executed." -Details @{
        required                      = $false
        mode                          = "plan_only"
        affected_cluster              = "devdeploy-workload"
        management_preserved          = $true
        destructive_commands_executed = $false
        requires_user_confirmation    = $true
        selected_workload_https_port  = [int]$PortPlan["workload_https"]
    }
}
if ($PlanManagementPortRecovery) {
    $managementPortRecoveryPlan = New-ManagementPortRecoveryPlan -ManagementCluster $managementCluster
    Add-Check -Id "management_port_recovery_plan" -Label "Management cluster port recovery plan" -Status "warning" -Message "Generated a plan-only management port recovery sequence. No commands were executed." -Details @{
        required                       = $false
        mode                           = "plan_only"
        affected_cluster               = "devdeploy-mgmt"
        destructive_commands_executed  = $false
        requires_user_confirmation     = $true
        backup_verification_required   = $true
        selected_management_https_port = [int]$PortPlan["management_https"]
        internal_cluster_ready         = $managementPortRecoveryPlan["internal_cluster_ready"]
        host_access_healthy            = [bool]$managementPortRecoveryPlan["host_access_healthy"]
        recreation_required            = [bool]$managementPortRecoveryPlan["recreation_required"]
        recreation_reason              = [string]$managementPortRecoveryPlan["recreation_reason"]
    }
}
$stableChecks = @($Checks | ForEach-Object { $_ })
$overallStatus = [string](Get-OverallStatus -StableChecks $stableChecks)
$summary = New-LauncherSummary -StableChecks $stableChecks
$artifacts = New-LauncherArtifacts -IncludeManagementKindConfig ([bool]($GenerateKindConfigs -or $CreateManagementCluster)) -IncludeWorkloadKindConfig ([bool]($GenerateKindConfigs -or $CreateWorkloadCluster))
$nextActions = @(New-NextActions -StableChecks $stableChecks -LauncherMode $launcherMode -OverallStatus $overallStatus -ManagementCluster $managementCluster -WorkloadCluster $workloadCluster -PlatformBootstrap $platformBootstrap)
$managementRecoveryPlan = New-ClusterRecoveryPlan -Cluster $managementCluster -Role "management"
$workloadRecoveryPlan = New-ClusterRecoveryPlan -Cluster $workloadCluster -Role "workload"

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
    management_recovery_plan = $managementRecoveryPlan
    workload_recovery_plan = $workloadRecoveryPlan
    platform_bootstrap = $platformBootstrap
    checks           = $stableChecks
    artifacts        = $artifacts
    ports            = $PortPlan
    port_selection   = $PortSelection
    next_actions     = [string[]]$nextActions
}

if ($PlanWorkloadRebootstrap -or $PlanWorkloadPortRecovery) {
    $statusDocument["workload_rebootstrap_plan"] = $workloadRebootstrapPlan
}
if ($PlanManagementPortRecovery) {
    $statusDocument["management_port_recovery_plan"] = $managementPortRecoveryPlan
}

$statusDocument | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $StatusPath -Encoding UTF8
Write-LauncherLog ("Wrote launcher status to {0}" -f $StatusPath)

if (-not $Quiet) {
    Write-Host ("DevDeploy Launcher preflight status: {0}" -f $overallStatus)
    Write-KindIntegrityConsole -Cluster $managementCluster -Required (Test-ManagementClusterIntegrityRequired)
    Write-KindIntegrityConsole -Cluster $workloadCluster -Required (Test-WorkloadClusterIntegrityRequired)
    if ($PlanManagementPortRecovery) {
        Write-ManagementPortRecoveryPlanConsole -Plan $managementPortRecoveryPlan
    }
    elseif ($PlanWorkloadRebootstrap -or $PlanWorkloadPortRecovery) {
        Write-WorkloadRebootstrapPlanConsole -Plan $workloadRebootstrapPlan
    }
    else {
        Write-ClusterRecoveryPlanConsole -RecoveryPlan $managementRecoveryPlan
        Write-ClusterRecoveryPlanConsole -RecoveryPlan $workloadRecoveryPlan
    }
    if ($PlanManagementPortRecovery) {
        Write-Host "Management port recovery plan was generated locally. Management and workload clusters were not changed."
    }
    elseif ($PlanWorkloadRebootstrap -or $PlanWorkloadPortRecovery) {
        Write-Host "Workload rebootstrap plan was generated locally. Management and workload clusters were not changed."
    }
    elseif ($CreateManagementCluster) {
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
    elseif ($VerifyManagementArgoCD) {
        Write-Host ("Verified management Argo CD release: {0}/{1}" -f $ArgoCDNamespace, $ArgoCDRelease)
        Write-Host ("Management Argo CD UI: {0}" -f $ArgoCDUiAccess)
    }
    elseif ($DiscoverWorkloadClusterEndpoint) {
        Write-Host "Workload cluster endpoint discovery completed without registration."
    }
    elseif ($RegisterWorkloadClusterWithArgoCD) {
        Write-Host "Workload cluster registration with management Argo CD completed. No Application was created."
    }
    elseif ($VerifyWorkloadClusterRegistration) {
        Write-Host "Workload cluster registration read-only verification completed. No resources were reconciled."
    }
    elseif ($GrantWorkloadDeployPermissions) {
        Write-Host "Namespace-scoped workload deploy permissions were reconciled. No Application or workload was created."
    }
    elseif ($VerifyWorkloadDeployPermissions) {
        Write-Host "Namespace-scoped workload deploy permissions passed read-only verification. No resources were reconciled."
    }
    elseif ($ConfigureGitOpsRepository) {
        Write-Host ("Local GitOps source path: {0}" -f (Join-Path ([string]$platformBootstrap["components"]["gitops_repository"]["repo_path"]) $GitOpsSourceRelativeWindowsPath))
        Write-Host "No Argo CD Application or user workload was created."
    }
    elseif ($BootstrapGitOpsRootApplication) {
        Write-Host ("GitOps Root Application: {0}/{1}" -f $ArgoCDNamespace, $GitOpsRootApplicationName)
        Write-Host "Only the Root Application was reconciled; no user workload manifest was applied by the launcher."
    }
    elseif ($VerifyGitOpsRootApplication) {
        Write-Host ("Verified GitOps Root Application: {0}/{1}" -f $ArgoCDNamespace, $GitOpsRootApplicationName)
        Write-Host "Verification was strictly read-only; no cluster resource was reconciled."
    }
    elseif ($BootstrapWorkloadObservability) {
        Write-Host ("Workload observability namespace: kind-devdeploy-workload/{0}" -f $ObservabilityNamespace)
        Write-Host "Prometheus, Loki, Alloy, Grafana, datasources, and backend service-proxy configuration were reconciled only because -BootstrapWorkloadObservability was explicitly requested."
    }
    elseif ($VerifyWorkloadObservability) {
        Write-Host ("Verified workload observability namespace: kind-devdeploy-workload/{0}" -f $ObservabilityNamespace)
        Write-Host "Verification was read-only; no Helm release or Kubernetes resource was reconciled."
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
