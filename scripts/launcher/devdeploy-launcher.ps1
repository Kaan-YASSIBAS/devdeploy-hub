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
$Checks = New-Object System.Collections.Generic.List[object]

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
        path     = $command.Source
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
        [int]$Port
    )

    $listener = $null
    try {
        $endpoint = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse("127.0.0.1")), $Port
        $listener = New-Object System.Net.Sockets.TcpListener $endpoint
        $listener.Start()
        Add-Check -Id ("port_{0}" -f $Port) -Label ("Port {0}" -f $Port) -Status "ok" -Message ("Port {0} is available on 127.0.0.1." -f $Port) -Details @{
            port     = $Port
            address  = "127.0.0.1"
            required = $true
        }
    }
    catch {
        Add-Check -Id ("port_{0}" -f $Port) -Label ("Port {0}" -f $Port) -Status "failed" -Message ("Port {0} is already in use. Free this port before creating DevDeploy local clusters." -f $Port) -Details @{
            port     = $Port
            address  = "127.0.0.1"
            required = $true
            error    = Protect-LogText $_.Exception.Message
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
        [bool]$KindAvailable
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

New-LocalDirectory -Path $StatusDir
New-LocalDirectory -Path $LogsDir
New-LocalDirectory -Path $KindDir

Write-LauncherLog "Starting DevDeploy Launcher read-only preflight."

$dockerAvailable = Test-CommandAvailable -Name "docker" -Label "Docker CLI" -Required $true
$kindAvailable = Test-CommandAvailable -Name "kind" -Label "kind CLI" -Required $true
$kubectlAvailable = Test-CommandAvailable -Name "kubectl" -Label "kubectl CLI" -Required $true
[void](Test-CommandAvailable -Name "git" -Label "git CLI" -Required $false)
[void](Test-CommandAvailable -Name "helm" -Label "Helm CLI" -Required $false)

Test-DockerDaemon -DockerCliAvailable $dockerAvailable

foreach ($port in $RequiredPorts) {
    Test-LocalPortAvailable -Port $port
}

Test-KindClusters -KindAvailable $kindAvailable
Test-KubectlContext -KubectlAvailable $kubectlAvailable

$overallStatus = "ok"
if ($Checks | Where-Object { $_.status -eq "failed" }) {
    $overallStatus = "failed"
}
elseif ($Checks | Where-Object { $_.status -eq "warning" }) {
    $overallStatus = "warning"
}

$statusDocument = [ordered]@{
    launcher_version = $LauncherVersion
    generated_at     = [string](Get-Timestamp)
    host_os          = [string]([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)
    shell            = [string]("{0} {1}" -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion.ToString())
    repo_root        = [string]$RepoRoot
    status           = $overallStatus
    checks           = @($Checks | ForEach-Object { $_ })
}

$statusDocument | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $StatusPath -Encoding UTF8
Write-LauncherLog ("Wrote launcher status to {0}" -f $StatusPath)

if (-not $Quiet) {
    Write-Host ("DevDeploy Launcher preflight status: {0}" -f $overallStatus)
    Write-Host ("Status: {0}" -f $StatusPath)
    Write-Host ("Log: {0}" -f $LogPath)
}

if ($overallStatus -eq "failed") {
    exit 1
}

exit 0
