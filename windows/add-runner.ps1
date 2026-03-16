# =============================================================================
# add-runner.ps1 - Add Additional Runner Instances to an Existing VM (Windows)
# =============================================================================
# Adds one or more new GitHub Actions runner instances to a VM that already
# has runners configured. Each instance gets its own directory, unique name,
# and separate Windows Service.
#
# Prerequisites:
#   - Run as Administrator
#   - At least one runner already set up via setup-runner.ps1
#   - GitHub CLI (gh) authenticated OR GITHUB_PAT env var OR manual token
#
# Usage:
#   .\add-runner.ps1 -Scope org -Org my-org -Count 2
#   .\add-runner.ps1 -Scope repo -Repo owner/repo -Count 3 -Labels "windows,x64"
#   .\add-runner.ps1 -Scope org -Org my-org -InstanceId worker-5
#   .\add-runner.ps1 -Scope org -Org my-org -Count 2 -Force
#
# Parameters:
#   -Scope        Required. "org" or "repo"
#   -Org          Required if Scope=org. GitHub organization name
#   -Repo         Required if Scope=repo. GitHub repo in "owner/repo" format
#   -Count        Optional. Number of runner instances to add (default: 1)
#   -InstanceId   Optional. Custom suffix for the runner name (only with Count=1)
#   -Labels       Optional. Comma-separated labels (default: self-hosted)
#   -RunnerGroup  Optional. Runner group name (org-level only)
#   -Token        Optional. Skip auto-fetch, use this registration token directly
#   -Force        Optional. Skip VM capacity check
#   -ConfigFile   Optional. Path to runner-config.env file
# =============================================================================

param(
    [string]$Scope = "",
    [string]$Org = "",
    [string]$Repo = "",
    [int]$Count = 1,
    [string]$InstanceId = "",
    [string]$Labels = "self-hosted",
    [string]$RunnerGroup = "",
    [string]$Token = "",
    [switch]$Force,
    [string]$ConfigFile = ""
)

$ErrorActionPreference = "Stop"

# =============================================================================
# Color helpers
# =============================================================================
function Write-OK    { param([string]$Msg) Write-Host "[OK]   " -ForegroundColor Green -NoNewline; Write-Host " $Msg" }
function Write-FAIL  { param([string]$Msg) Write-Host "[FAIL] " -ForegroundColor Red -NoNewline; Write-Host " $Msg" }
function Write-WARN  { param([string]$Msg) Write-Host "[WARN] " -ForegroundColor Yellow -NoNewline; Write-Host " $Msg" }
function Write-INFO  { param([string]$Msg) Write-Host "[INFO] " -ForegroundColor Cyan -NoNewline; Write-Host " $Msg" }
function Write-STEP  { param([string]$Msg) Write-Host "`n==> $Msg" -ForegroundColor Blue }

# =============================================================================
# Defaults
# =============================================================================
$RunnerInstallDir = "C:\github-runners"
$RunnerWorkDir = "_work"
$MaxRunners = ""
$RegToken = ""

$CreatedRunners = @()
$FailedRunners = @()

# =============================================================================
# Load config
# =============================================================================
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir

function Load-Config {
    $configPath = ""
    if ($ConfigFile -and (Test-Path $ConfigFile)) {
        $configPath = $ConfigFile
    } elseif (Test-Path "$ProjectDir\config\runner-config.env") {
        $configPath = "$ProjectDir\config\runner-config.env"
    }

    if ($configPath) {
        Get-Content $configPath | ForEach-Object {
            if ($_ -match '^\s*#' -or $_ -match '^\s*$') { return }
            if ($_ -match '^([^=]+)=(.*)$') {
                $key = $Matches[1].Trim()
                $val = $Matches[2].Trim().Trim('"').Trim("'")
                Set-Variable -Name "Config_$key" -Value $val -Scope Script
            }
        }
    }
}

Load-Config

if (-not $Scope)  { $Scope  = if ($Script:Config_RUNNER_SCOPE) { $Script:Config_RUNNER_SCOPE } else { "" } }
if (-not $Org)    { $Org    = if ($Script:Config_GITHUB_ORG) { $Script:Config_GITHUB_ORG } else { "" } }
if (-not $Repo)   { $Repo   = if ($Script:Config_GITHUB_REPO) { $Script:Config_GITHUB_REPO } else { "" } }
if ($Script:Config_RUNNER_INSTALL_DIR) { $RunnerInstallDir = $Script:Config_RUNNER_INSTALL_DIR }
if ($Script:Config_RUNNER_WORK_DIR)    { $RunnerWorkDir = $Script:Config_RUNNER_WORK_DIR }
if ($Script:Config_MAX_RUNNERS)        { $MaxRunners = $Script:Config_MAX_RUNNERS }

# =============================================================================
# Check: Running as Administrator
# =============================================================================
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-FAIL "This script must be run as Administrator"
    exit 1
}

# =============================================================================
# Validate arguments
# =============================================================================
function Validate-Args {
    Write-STEP "Validating arguments"

    if (-not $Scope) { Write-FAIL "-Scope is required (org or repo)"; exit 1 }
    if ($Scope -notin @("org","repo")) { Write-FAIL "-Scope must be 'org' or 'repo'"; exit 1 }
    if ($Scope -eq "org" -and -not $Org) { Write-FAIL "-Org is required when Scope is 'org'"; exit 1 }
    if ($Scope -eq "repo" -and -not $Repo) { Write-FAIL "-Repo is required when Scope is 'repo'"; exit 1 }
    if ($Count -lt 1) { Write-FAIL "-Count must be at least 1"; exit 1 }
    if ($InstanceId -and $Count -gt 1) { Write-FAIL "-InstanceId can only be used with -Count 1"; exit 1 }

    Write-OK "Arguments validated (Scope=$Scope, Count=$Count)"
}

# =============================================================================
# VM Capacity Check
# =============================================================================
function Check-VMCapacity {
    Write-STEP "Checking VM capacity for $Count additional runner(s)"

    $cpuCores = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
    $totalRamGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $freeDiskGB = [math]::Round((Get-PSDrive -Name ($RunnerInstallDir.Substring(0,1))).Free / 1GB)

    Write-INFO "System resources: $cpuCores CPU cores, $totalRamGB GB RAM, $freeDiskGB GB free disk"

    $maxByCpu = [math]::Max(1, [math]::Floor($cpuCores / 2))
    $maxByRam = [math]::Max(1, [math]::Floor($totalRamGB / 4))
    $maxByDisk = [math]::Max(1, [math]::Floor($freeDiskGB / 10))
    $recommendedMax = [math]::Min($maxByCpu, [math]::Min($maxByRam, $maxByDisk))

    $effectiveMax = if ($MaxRunners) { [int]$MaxRunners } else { $recommendedMax }

    $currentCount = 0
    if (Test-Path $RunnerInstallDir) {
        $currentCount = (Get-ChildItem -Path $RunnerInstallDir -Directory -ErrorAction SilentlyContinue | Measure-Object).Count
    }

    $afterCount = $currentCount + $Count
    $slotsAvailable = [math]::Max(0, $effectiveMax - $currentCount)

    Write-INFO "Current runners: $currentCount | Requesting: $Count | After: $afterCount / $effectiveMax"

    if ($afterCount -le $effectiveMax) {
        Write-OK "Capacity available. $slotsAvailable slot(s) free."
    } else {
        Write-WARN "Requesting $Count runners but only $slotsAvailable slot(s) available (max=$effectiveMax)"
        if ($Force) {
            Write-WARN "Proceeding anyway (-Force flag set)"
        } else {
            $confirm = Read-Host "VM will be over capacity after adding. Continue? (y/N)"
            if ($confirm -ne "y" -and $confirm -ne "Y") {
                Write-FAIL "Aborted. Use -Force to skip."
                exit 1
            }
        }
    }
}

# =============================================================================
# Obtain registration token (3-tier fallback)
# =============================================================================
function Get-RegistrationToken {
    Write-STEP "Obtaining runner registration token"

    if ($Token) {
        Write-OK "Using provided registration token"
        $Script:RegToken = $Token
        return
    }

    $apiPath = if ($Scope -eq "org") { "orgs/$Org/actions/runners/registration-token" } else { "repos/$Repo/actions/runners/registration-token" }

    # Tier 1: GitHub CLI
    $ghCmd = Get-Command gh -ErrorAction SilentlyContinue
    if ($ghCmd) {
        Write-INFO "Attempting token fetch via GitHub CLI (gh)..."
        try {
            $null = gh auth status 2>&1
            $ghResponse = gh api --method POST $apiPath 2>&1
            $parsed = $ghResponse | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($parsed.token) {
                $Script:RegToken = $parsed.token
                Write-OK "Registration token obtained via GitHub CLI"
                return
            }
        } catch { Write-WARN "GitHub CLI token fetch failed, trying next method..." }
    }

    # Tier 2: GITHUB_PAT
    $pat = $env:GITHUB_PAT
    if (-not $pat -and $Script:Config_GITHUB_PAT) { $pat = $Script:Config_GITHUB_PAT }
    if ($pat) {
        Write-INFO "Attempting token fetch via GITHUB_PAT..."
        try {
            $headers = @{ "Accept" = "application/vnd.github+json"; "Authorization" = "Bearer $pat" }
            $response = Invoke-RestMethod -Uri "https://api.github.com/$apiPath" -Method Post -Headers $headers -ErrorAction Stop
            if ($response.token) {
                $Script:RegToken = $response.token
                Write-OK "Registration token obtained via GITHUB_PAT"
                return
            }
        } catch { Write-WARN "GITHUB_PAT token fetch failed, trying next method..." }
    }

    # Tier 3: Manual
    Write-INFO "Please provide a registration token manually."
    if ($Scope -eq "org") {
        Write-Host "  Get token from: https://github.com/organizations/$Org/settings/actions/runners/new"
    } else {
        Write-Host "  Get token from: https://github.com/$Repo/settings/actions/runners/new"
    }
    $Script:RegToken = Read-Host "  Paste registration token"
    if (-not $Script:RegToken) { Write-FAIL "No token provided."; exit 1 }
    Write-OK "Token received (manual entry)"
}

# =============================================================================
# Generate unique runner name
# =============================================================================
function Get-RunnerName {
    param([int]$Index)

    if ($InstanceId) {
        return "$($env:COMPUTERNAME)-$InstanceId"
    }

    $baseName = "$($env:COMPUTERNAME)-runner"
    $candidateIndex = $Index
    while (Test-Path (Join-Path $RunnerInstallDir "$baseName-$candidateIndex")) {
        $candidateIndex++
    }
    return "$baseName-$candidateIndex"
}

# =============================================================================
# Add a single runner instance
# =============================================================================
function Add-SingleRunner {
    param([string]$RunnerName)

    Write-STEP "Adding runner: $RunnerName"

    $runnerDir = Join-Path $RunnerInstallDir $RunnerName
    if (Test-Path $runnerDir) {
        Write-FAIL "Runner directory already exists: $runnerDir"
        return $false
    }

    # Determine architecture
    $arch = if ([Environment]::Is64BitOperatingSystem) { "x64" } else { "x86" }
    if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { $arch = "arm64" }

    # Get latest version
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/actions/runner/releases/latest" -ErrorAction Stop
        $latestVersion = $release.tag_name -replace '^v', ''
    } catch {
        Write-FAIL "Could not determine latest runner version"
        return $false
    }

    New-Item -ItemType Directory -Path $runnerDir -Force | Out-Null

    # Download
    $downloadUrl = "https://github.com/actions/runner/releases/download/v${latestVersion}/actions-runner-win-${arch}-${latestVersion}.zip"
    $zipFile = Join-Path $env:TEMP "actions-runner-${RunnerName}.zip"

    Write-INFO "Downloading runner v${latestVersion}..."
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $downloadUrl -OutFile $zipFile -UseBasicParsing -ErrorAction Stop
    } catch {
        Write-FAIL "Download failed for $RunnerName"
        Remove-Item -Path $runnerDir -Recurse -Force -ErrorAction SilentlyContinue
        return $false
    }

    # Extract
    try {
        Expand-Archive -Path $zipFile -DestinationPath $runnerDir -Force
    } catch {
        Write-FAIL "Extraction failed for $RunnerName"
        Remove-Item -Path $runnerDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $zipFile -Force -ErrorAction SilentlyContinue
        return $false
    }
    Remove-Item -Path $zipFile -Force -ErrorAction SilentlyContinue
    Write-OK "Downloaded and extracted runner"

    # Configure
    $url = if ($Scope -eq "org") { "https://github.com/$Org" } else { "https://github.com/$Repo" }
    $configArgs = @("--url", $url, "--token", $RegToken, "--name", $RunnerName, "--labels", $Labels, "--work", $RunnerWorkDir, "--unattended", "--replace")
    if ($RunnerGroup -and $Scope -eq "org") { $configArgs += @("--runnergroup", $RunnerGroup) }

    Write-INFO "Configuring runner..."
    try {
        & (Join-Path $runnerDir "config.cmd") $configArgs
        if ($LASTEXITCODE -ne 0) { throw "config.cmd failed" }
        Write-OK "Runner configured"
    } catch {
        Write-FAIL "Configuration failed for $RunnerName"
        Remove-Item -Path $runnerDir -Recurse -Force -ErrorAction SilentlyContinue
        return $false
    }

    # Install and start service
    Write-INFO "Installing Windows Service..."
    try {
        & (Join-Path $runnerDir "svc.cmd") install
        & (Join-Path $runnerDir "svc.cmd") start
        Write-OK "Service installed and started"
    } catch {
        Write-FAIL "Service setup failed for $RunnerName"
        return $false
    }

    # Validate
    Start-Sleep -Seconds 2
    if ((Test-Path (Join-Path $runnerDir ".runner")) -and (Test-Path (Join-Path $runnerDir ".credentials"))) {
        Write-OK "Runner $RunnerName is installed and running"
        return $true
    } else {
        Write-FAIL "Runner $RunnerName registration files missing"
        return $false
    }
}

# =============================================================================
# Print summary
# =============================================================================
function Print-Summary {
    Write-Host ""
    Write-Host "============================================================================="
    Write-Host "  ADD RUNNER SUMMARY"
    Write-Host "============================================================================="
    Write-Host "  Requested : $Count runner(s)"
    Write-Host "  Created   : $($CreatedRunners.Count)"
    Write-Host "  Failed    : $($FailedRunners.Count)"
    Write-Host "============================================================================="

    if ($CreatedRunners.Count -gt 0) {
        Write-Host "`n  Successfully created:"
        foreach ($r in $CreatedRunners) { Write-Host "    [OK]   $r" -ForegroundColor Green }
    }

    if ($FailedRunners.Count -gt 0) {
        Write-Host "`n  Failed:"
        foreach ($r in $FailedRunners) { Write-Host "    [FAIL] $r" -ForegroundColor Red }
    }

    Write-Host ""
    Write-Host "  Runners should appear at:"
    if ($Scope -eq "org") {
        Write-Host "  https://github.com/organizations/$Org/settings/actions/runners"
    } else {
        Write-Host "  https://github.com/$Repo/settings/actions/runners"
    }
    Write-Host "============================================================================="

    if ($FailedRunners.Count -gt 0) { exit 1 }
}

# =============================================================================
# Main
# =============================================================================
Write-Host "============================================================================="
Write-Host "  GitHub Self-Hosted Runner - Add Instances (Windows)"
Write-Host "============================================================================="

Validate-Args
Check-VMCapacity
Get-RegistrationToken

# Count existing runners for naming
$existingCount = 0
if (Test-Path $RunnerInstallDir) {
    $existingCount = (Get-ChildItem -Path $RunnerInstallDir -Directory -ErrorAction SilentlyContinue | Measure-Object).Count
}

for ($i = 1; $i -le $Count; $i++) {
    $runnerName = Get-RunnerName -Index ($existingCount + $i)
    $result = Add-SingleRunner -RunnerName $runnerName
    if ($result) {
        $CreatedRunners += $runnerName
    } else {
        $FailedRunners += $runnerName
    }
}

Print-Summary
