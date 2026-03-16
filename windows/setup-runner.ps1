# =============================================================================
# setup-runner.ps1 - Install and Register a GitHub Self-Hosted Runner (Windows)
# =============================================================================
# This script downloads the latest GitHub Actions runner, configures it for
# org-level or repo-level use, and installs it as a Windows Service.
#
# Prerequisites:
#   - Run as Administrator
#   - PowerShell 5.1+ or PowerShell 7+
#   - GitHub CLI (gh) authenticated OR GITHUB_PAT env var OR manual token
#
# Usage:
#   .\setup-runner.ps1 -Scope org -Org my-org -Name my-runner
#   .\setup-runner.ps1 -Scope repo -Repo owner/repo -Name my-runner
#   .\setup-runner.ps1 -Scope org -Org my-org -Name my-runner -Labels "windows,x64,prod"
#   .\setup-runner.ps1 -Scope org -Org my-org -Name my-runner -Token AXXXXXXX
#   .\setup-runner.ps1 -Scope org -Org my-org -Name my-runner -Force
#
# Parameters:
#   -Scope        Required. "org" or "repo"
#   -Org          Required if Scope=org. GitHub organization name
#   -Repo         Required if Scope=repo. GitHub repo in "owner/repo" format
#   -Name         Optional. Runner name (default: hostname-runner)
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
    [string]$Name = "",
    [string]$Labels = "self-hosted",
    [string]$RunnerGroup = "",
    [string]$Token = "",
    [switch]$Force,
    [string]$ConfigFile = ""
)

$ErrorActionPreference = "Stop"

# =============================================================================
# Color and formatting helpers
# =============================================================================
function Write-OK    { param([string]$Msg) Write-Host "[OK]   " -ForegroundColor Green -NoNewline; Write-Host " $Msg" }
function Write-FAIL  { param([string]$Msg) Write-Host "[FAIL] " -ForegroundColor Red -NoNewline; Write-Host " $Msg" }
function Write-WARN  { param([string]$Msg) Write-Host "[WARN] " -ForegroundColor Yellow -NoNewline; Write-Host " $Msg" }
function Write-INFO  { param([string]$Msg) Write-Host "[INFO] " -ForegroundColor Cyan -NoNewline; Write-Host " $Msg" }
function Write-STEP  { param([string]$Msg) Write-Host "`n==> $Msg" -ForegroundColor Blue }

# =============================================================================
# Default values
# =============================================================================
$RunnerInstallDir = "C:\github-runners"
$RunnerWorkDir = "_work"
$MaxRunners = ""
$RegToken = ""
$RunnerDir = ""

# Track validation results for final summary
$ValidationResults = @()

# =============================================================================
# Load config file if provided or if default exists
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
        Write-INFO "Loading config from $configPath"
        Get-Content $configPath | ForEach-Object {
            # Skip comments and empty lines
            if ($_ -match '^\s*#' -or $_ -match '^\s*$') { return }
            # Parse KEY="VALUE" or KEY=VALUE
            if ($_ -match '^([^=]+)=(.*)$') {
                $key = $Matches[1].Trim()
                $val = $Matches[2].Trim().Trim('"').Trim("'")
                # Set as script-level variable if not already set via parameter
                Set-Variable -Name "Config_$key" -Value $val -Scope Script
            }
        }
    }
}

Load-Config

# Apply config defaults (parameters take precedence)
if (-not $Scope)  { $Scope  = if ($Script:Config_RUNNER_SCOPE) { $Script:Config_RUNNER_SCOPE } else { "" } }
if (-not $Org)    { $Org    = if ($Script:Config_GITHUB_ORG) { $Script:Config_GITHUB_ORG } else { "" } }
if (-not $Repo)   { $Repo   = if ($Script:Config_GITHUB_REPO) { $Script:Config_GITHUB_REPO } else { "" } }
if (-not $Name)   { $Name   = "$($env:COMPUTERNAME)-runner" }
if (-not $Labels) { $Labels = "self-hosted" }
if ($Script:Config_RUNNER_INSTALL_DIR) { $RunnerInstallDir = $Script:Config_RUNNER_INSTALL_DIR }
if ($Script:Config_RUNNER_WORK_DIR)    { $RunnerWorkDir = $Script:Config_RUNNER_WORK_DIR }
if ($Script:Config_MAX_RUNNERS)        { $MaxRunners = $Script:Config_MAX_RUNNERS }

# =============================================================================
# Check: Running as Administrator
# =============================================================================
function Test-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
    Write-FAIL "This script must be run as Administrator"
    Write-Host "Right-click PowerShell and select 'Run as Administrator'"
    exit 1
}

# =============================================================================
# Validate required arguments
# =============================================================================
function Validate-Args {
    Write-STEP "Validating arguments"

    if (-not $Scope) {
        Write-FAIL "-Scope is required (org or repo)"
        exit 1
    }

    if ($Scope -notin @("org", "repo")) {
        Write-FAIL "-Scope must be 'org' or 'repo', got: $Scope"
        exit 1
    }

    if ($Scope -eq "org" -and -not $Org) {
        Write-FAIL "-Org is required when Scope is 'org'"
        exit 1
    }

    if ($Scope -eq "repo" -and -not $Repo) {
        Write-FAIL "-Repo is required when Scope is 'repo' (format: owner/repo)"
        exit 1
    }

    Write-OK "Arguments validated (Scope=$Scope, Name=$Name)"
    $Script:ValidationResults += "Arguments: PASS"
}

# =============================================================================
# VM Capacity Check
# =============================================================================
function Check-VMCapacity {
    Write-STEP "Checking VM capacity"

    # Get system resources
    $cpuCores = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
    $totalRamGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $freeDiskGB = [math]::Round((Get-PSDrive -Name ($RunnerInstallDir.Substring(0,1))).Free / 1GB)

    Write-INFO "System resources: $cpuCores CPU cores, $totalRamGB GB RAM, $freeDiskGB GB free disk"

    # Calculate recommended max: 1 runner per 2 cores, 4 GB RAM, 10 GB disk
    $maxByCpu = [math]::Max(1, [math]::Floor($cpuCores / 2))
    $maxByRam = [math]::Max(1, [math]::Floor($totalRamGB / 4))
    $maxByDisk = [math]::Max(1, [math]::Floor($freeDiskGB / 10))

    $recommendedMax = [math]::Min($maxByCpu, [math]::Min($maxByRam, $maxByDisk))

    $effectiveMax = if ($MaxRunners) { [int]$MaxRunners } else { $recommendedMax }

    if ($MaxRunners) {
        Write-INFO "Using user-configured MAX_RUNNERS=$MaxRunners (recommended: $recommendedMax)"
    } else {
        Write-INFO "Auto-calculated max runners: $effectiveMax (CPU=$maxByCpu, RAM=$maxByRam, Disk=$maxByDisk)"
    }

    # Count existing runners
    $currentCount = 0
    if (Test-Path $RunnerInstallDir) {
        $currentCount = (Get-ChildItem -Path $RunnerInstallDir -Directory -ErrorAction SilentlyContinue | Measure-Object).Count
    }

    Write-INFO "Current runners on VM: $currentCount / $effectiveMax"

    if ($currentCount -lt $effectiveMax) {
        Write-OK "Capacity available ($currentCount/$effectiveMax runners)"
        $Script:ValidationResults += "VM Capacity: PASS ($currentCount/$effectiveMax)"
    } elseif ($currentCount -eq $effectiveMax) {
        Write-WARN "VM is at capacity ($currentCount/$effectiveMax runners)"
        if ($Force) {
            Write-WARN "Proceeding anyway (-Force flag set)"
            $Script:ValidationResults += "VM Capacity: WARN - at capacity, forced"
        } else {
            $confirm = Read-Host "VM is at capacity. Continue anyway? (y/N)"
            if ($confirm -ne "y" -and $confirm -ne "Y") {
                Write-FAIL "Aborted by user. Use -Force to skip this check."
                exit 1
            }
            $Script:ValidationResults += "VM Capacity: WARN - at capacity, user confirmed"
        }
    } else {
        Write-FAIL "VM is over capacity ($currentCount/$effectiveMax runners)"
        if ($Force) {
            Write-WARN "Proceeding anyway (-Force flag set)"
            $Script:ValidationResults += "VM Capacity: WARN - over capacity, forced"
        } else {
            Write-FAIL "Use -Force to override this check."
            exit 1
        }
    }
}

# =============================================================================
# Obtain registration token using 3-tier fallback
# =============================================================================
function Get-RegistrationToken {
    Write-STEP "Obtaining runner registration token"

    # If user provided token directly
    if ($Token) {
        Write-OK "Using provided registration token"
        $Script:RegToken = $Token
        $Script:ValidationResults += "Token: PASS (provided directly)"
        return
    }

    # Build API path
    $apiPath = if ($Scope -eq "org") {
        "orgs/$Org/actions/runners/registration-token"
    } else {
        "repos/$Repo/actions/runners/registration-token"
    }

    # --- Tier 1: GitHub CLI ---
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
                $Script:ValidationResults += "Token: PASS (via gh CLI)"
                return
            }
        } catch {
            Write-WARN "GitHub CLI token fetch failed, trying next method..."
        }
    } else {
        Write-INFO "GitHub CLI (gh) not found, trying next method..."
    }

    # --- Tier 2: GITHUB_PAT ---
    $pat = $env:GITHUB_PAT
    if (-not $pat -and $Script:Config_GITHUB_PAT) { $pat = $Script:Config_GITHUB_PAT }

    if ($pat) {
        Write-INFO "Attempting token fetch via GITHUB_PAT..."
        try {
            $apiUrl = "https://api.github.com/$apiPath"
            $headers = @{
                "Accept"        = "application/vnd.github+json"
                "Authorization" = "Bearer $pat"
            }
            $response = Invoke-RestMethod -Uri $apiUrl -Method Post -Headers $headers -ErrorAction Stop
            if ($response.token) {
                $Script:RegToken = $response.token
                Write-OK "Registration token obtained via GITHUB_PAT"
                $Script:ValidationResults += "Token: PASS (via GITHUB_PAT)"
                return
            }
        } catch {
            Write-WARN "GITHUB_PAT token fetch failed: $($_.Exception.Message)"
        }
    } else {
        Write-INFO "GITHUB_PAT not set, trying next method..."
    }

    # --- Tier 3: Manual entry ---
    Write-INFO "Auto-fetch methods exhausted. Please provide a registration token manually."
    Write-Host ""
    if ($Scope -eq "org") {
        Write-Host "  Get token from: https://github.com/organizations/$Org/settings/actions/runners/new"
    } else {
        Write-Host "  Get token from: https://github.com/$Repo/settings/actions/runners/new"
    }
    Write-Host ""
    $Script:RegToken = Read-Host "  Paste registration token"

    if (-not $Script:RegToken) {
        Write-FAIL "No registration token provided. Cannot continue."
        exit 1
    }

    Write-OK "Registration token received (manual entry)"
    $Script:ValidationResults += "Token: PASS (manual entry)"
}

# =============================================================================
# Download and extract the latest runner package
# =============================================================================
function Download-Runner {
    Write-STEP "Downloading latest GitHub Actions runner"

    # Determine architecture
    $arch = if ([Environment]::Is64BitOperatingSystem) { "x64" } else { "x86" }
    # Check for ARM64
    if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { $arch = "arm64" }

    # Fetch latest version
    Write-INFO "Fetching latest runner version..."
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/actions/runner/releases/latest" -ErrorAction Stop
        $latestVersion = $release.tag_name -replace '^v', ''
    } catch {
        Write-FAIL "Could not determine latest runner version: $($_.Exception.Message)"
        exit 1
    }

    Write-INFO "Latest runner version: $latestVersion"

    # Create runner directory
    $Script:RunnerDir = Join-Path $RunnerInstallDir $Name
    if (Test-Path $Script:RunnerDir) {
        Write-WARN "Runner directory already exists: $($Script:RunnerDir)"
        Write-WARN "If you want to re-install, remove it first with uninstall-runner.ps1"
        exit 1
    }

    New-Item -ItemType Directory -Path $Script:RunnerDir -Force | Out-Null

    # Download
    $downloadUrl = "https://github.com/actions/runner/releases/download/v${latestVersion}/actions-runner-win-${arch}-${latestVersion}.zip"
    $zipFile = Join-Path $env:TEMP "actions-runner-win-${arch}-${latestVersion}.zip"

    Write-INFO "Downloading from: $downloadUrl"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $downloadUrl -OutFile $zipFile -UseBasicParsing -ErrorAction Stop
        Write-OK "Runner package downloaded"
    } catch {
        Write-FAIL "Failed to download runner package: $($_.Exception.Message)"
        Remove-Item -Path $Script:RunnerDir -Recurse -Force -ErrorAction SilentlyContinue
        exit 1
    }

    # Extract
    Write-INFO "Extracting to $($Script:RunnerDir)..."
    try {
        Expand-Archive -Path $zipFile -DestinationPath $Script:RunnerDir -Force
        Write-OK "Runner package extracted"
    } catch {
        Write-FAIL "Failed to extract runner package: $($_.Exception.Message)"
        Remove-Item -Path $Script:RunnerDir -Recurse -Force -ErrorAction SilentlyContinue
        exit 1
    }

    # Cleanup
    Remove-Item -Path $zipFile -Force -ErrorAction SilentlyContinue

    $Script:ValidationResults += "Download: PASS (v$latestVersion, $arch)"
}

# =============================================================================
# Configure the runner
# =============================================================================
function Configure-Runner {
    Write-STEP "Configuring runner"

    $url = if ($Scope -eq "org") { "https://github.com/$Org" } else { "https://github.com/$Repo" }

    $configArgs = @(
        "--url", $url,
        "--token", $RegToken,
        "--name", $Name,
        "--labels", $Labels,
        "--work", $RunnerWorkDir,
        "--unattended",
        "--replace"
    )

    if ($RunnerGroup -and $Scope -eq "org") {
        $configArgs += @("--runnergroup", $RunnerGroup)
    }

    Write-INFO "Running config.cmd..."
    $configCmd = Join-Path $Script:RunnerDir "config.cmd"

    try {
        & $configCmd $configArgs
        if ($LASTEXITCODE -ne 0) { throw "config.cmd exited with code $LASTEXITCODE" }
        Write-OK "Runner configured successfully"
        $Script:ValidationResults += "Configuration: PASS"
    } catch {
        Write-FAIL "Runner configuration failed: $($_.Exception.Message)"
        $Script:ValidationResults += "Configuration: FAIL"
        exit 1
    }
}

# =============================================================================
# Install runner as a Windows Service
# =============================================================================
function Install-RunnerService {
    Write-STEP "Installing runner as Windows Service"

    $svcCmd = Join-Path $Script:RunnerDir "svc.cmd"

    # Install the service
    Write-INFO "Installing Windows Service..."
    try {
        & $svcCmd install
        if ($LASTEXITCODE -ne 0) { throw "svc.cmd install exited with code $LASTEXITCODE" }
        Write-OK "Windows Service installed"
    } catch {
        Write-FAIL "Failed to install Windows Service: $($_.Exception.Message)"
        $Script:ValidationResults += "Service install: FAIL"
        exit 1
    }

    # Start the service
    Write-INFO "Starting runner service..."
    try {
        & $svcCmd start
        if ($LASTEXITCODE -ne 0) { throw "svc.cmd start exited with code $LASTEXITCODE" }
        Write-OK "Runner service started"
    } catch {
        Write-FAIL "Failed to start runner service: $($_.Exception.Message)"
        $Script:ValidationResults += "Service start: FAIL"
        exit 1
    }

    # Verify
    Start-Sleep -Seconds 3
    try {
        $status = & $svcCmd status 2>&1
        if ($status -match "Running|Started") {
            Write-OK "Runner service is running"
            $Script:ValidationResults += "Service: PASS (running)"
        } else {
            Write-WARN "Service may not be running correctly. Check with: $svcCmd status"
            $Script:ValidationResults += "Service: WARN (check status)"
        }
    } catch {
        Write-WARN "Could not verify service status"
        $Script:ValidationResults += "Service: WARN (check status)"
    }
}

# =============================================================================
# Final validation
# =============================================================================
function Validate-Installation {
    Write-STEP "Validating installation"

    $allPass = $true

    if (Test-Path $Script:RunnerDir) {
        Write-OK "Runner directory exists: $($Script:RunnerDir)"
    } else {
        Write-FAIL "Runner directory missing: $($Script:RunnerDir)"
        $allPass = $false
    }

    $runnerFile = Join-Path $Script:RunnerDir ".runner"
    if (Test-Path $runnerFile) {
        Write-OK "Runner registration file exists"
    } else {
        Write-FAIL "Runner registration file missing"
        $allPass = $false
    }

    $credFile = Join-Path $Script:RunnerDir ".credentials"
    if (Test-Path $credFile) {
        Write-OK "Runner credentials file exists"
    } else {
        Write-FAIL "Runner credentials file missing"
        $allPass = $false
    }

    if ($allPass) {
        $Script:ValidationResults += "Final validation: PASS"
    } else {
        $Script:ValidationResults += "Final validation: FAIL"
    }
}

# =============================================================================
# Print final summary
# =============================================================================
function Print-Summary {
    Write-Host ""
    Write-Host "============================================================================="
    Write-Host "  SETUP SUMMARY"
    Write-Host "============================================================================="
    Write-Host "  Runner Name  : $Name"
    Write-Host "  Scope        : $Scope"
    if ($Scope -eq "org") {
        Write-Host "  Organization : $Org"
    } else {
        Write-Host "  Repository   : $Repo"
    }
    Write-Host "  Labels       : $Labels"
    Write-Host "  Install Dir  : $($Script:RunnerDir)"
    Write-Host "  Service Mode : Windows Service"
    Write-Host "============================================================================="
    Write-Host ""

    $hasFail = $false
    foreach ($result in $Script:ValidationResults) {
        if ($result -match "FAIL") {
            Write-Host "  [FAIL] $result" -ForegroundColor Red
            $hasFail = $true
        } elseif ($result -match "WARN") {
            Write-Host "  [WARN] $result" -ForegroundColor Yellow
        } else {
            Write-Host "  [ OK ] $result" -ForegroundColor Green
        }
    }

    Write-Host ""
    if ($hasFail) {
        Write-Host "  Setup completed with errors. Review the failures above." -ForegroundColor Red
        Write-Host "  Run debug-runner.ps1 for more details."
        exit 1
    } else {
        Write-Host "  Setup completed successfully!" -ForegroundColor Green
        if ($Scope -eq "org") {
            Write-Host "  Your runner should now appear at: https://github.com/organizations/$Org/settings/actions/runners"
        } else {
            Write-Host "  Your runner should now appear at: https://github.com/$Repo/settings/actions/runners"
        }
    }
    Write-Host "============================================================================="
}

# =============================================================================
# Main execution
# =============================================================================
Write-Host "============================================================================="
Write-Host "  GitHub Self-Hosted Runner Setup (Windows)"
Write-Host "============================================================================="

Validate-Args
Check-VMCapacity
Get-RegistrationToken
Download-Runner
Configure-Runner
Install-RunnerService
Validate-Installation
Print-Summary
