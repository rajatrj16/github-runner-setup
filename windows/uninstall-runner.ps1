# =============================================================================
# uninstall-runner.ps1 - Remove GitHub Self-Hosted Runner(s) (Windows)
# =============================================================================
# Stops the Windows Service, deregisters the runner from GitHub, and removes
# all runner files. Supports removing a single runner by name or all runners.
#
# Prerequisites:
#   - Run as Administrator
#   - GitHub CLI (gh) authenticated OR GITHUB_PAT env var OR manual token
#
# Usage:
#   .\uninstall-runner.ps1 -Name my-runner -Scope org -Org my-org
#   .\uninstall-runner.ps1 -Name my-runner -Scope repo -Repo owner/repo
#   .\uninstall-runner.ps1 -All -Scope org -Org my-org
#   .\uninstall-runner.ps1 -Name my-runner -Scope org -Org my-org -Token RXXXXXXX
#
# Parameters:
#   -Name        Remove a specific runner by name
#   -All         Remove ALL runners from this VM
#   -Scope       Required. "org" or "repo"
#   -Org         Required if Scope=org. GitHub organization name
#   -Repo        Required if Scope=repo. GitHub repo in "owner/repo" format
#   -Token       Optional. Provide a removal token directly (skip auto-fetch)
#   -ConfigFile  Optional. Path to runner-config.env file
# =============================================================================

param(
    [string]$Name = "",
    [switch]$All,
    [string]$Scope = "",
    [string]$Org = "",
    [string]$Repo = "",
    [string]$Token = "",
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
$RemovalToken = ""
$Removed = @()
$FailedList = @()

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

if (-not $Scope) { $Scope = if ($Script:Config_RUNNER_SCOPE) { $Script:Config_RUNNER_SCOPE } else { "" } }
if (-not $Org)   { $Org   = if ($Script:Config_GITHUB_ORG) { $Script:Config_GITHUB_ORG } else { "" } }
if (-not $Repo)  { $Repo  = if ($Script:Config_GITHUB_REPO) { $Script:Config_GITHUB_REPO } else { "" } }
if ($Script:Config_RUNNER_INSTALL_DIR) { $RunnerInstallDir = $Script:Config_RUNNER_INSTALL_DIR }

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

    if (-not $Name -and -not $All) {
        Write-FAIL "Either -Name <runner-name> or -All is required"
        exit 1
    }
    if (-not $Scope) { Write-FAIL "-Scope is required (org or repo)"; exit 1 }
    if ($Scope -eq "org" -and -not $Org) { Write-FAIL "-Org is required when Scope is 'org'"; exit 1 }
    if ($Scope -eq "repo" -and -not $Repo) { Write-FAIL "-Repo is required when Scope is 'repo'"; exit 1 }

    Write-OK "Arguments validated"
}

# =============================================================================
# Obtain removal token (3-tier fallback)
# =============================================================================
function Get-RemovalToken {
    Write-STEP "Obtaining runner removal token"

    if ($Token) {
        Write-OK "Using provided removal token"
        $Script:RemovalToken = $Token
        return
    }

    $apiPath = if ($Scope -eq "org") { "orgs/$Org/actions/runners/remove-token" } else { "repos/$Repo/actions/runners/remove-token" }

    # Tier 1: GitHub CLI
    $ghCmd = Get-Command gh -ErrorAction SilentlyContinue
    if ($ghCmd) {
        Write-INFO "Attempting token fetch via GitHub CLI (gh)..."
        try {
            $null = gh auth status 2>&1
            $ghResponse = gh api --method POST $apiPath 2>&1
            $parsed = $ghResponse | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($parsed.token) {
                $Script:RemovalToken = $parsed.token
                Write-OK "Removal token obtained via GitHub CLI"
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
                $Script:RemovalToken = $response.token
                Write-OK "Removal token obtained via GITHUB_PAT"
                return
            }
        } catch { Write-WARN "GITHUB_PAT token fetch failed, trying next method..." }
    }

    # Tier 3: Manual
    Write-INFO "Please provide a removal token manually."
    if ($Scope -eq "org") {
        Write-Host "  Get token from: https://github.com/organizations/$Org/settings/actions/runners"
    } else {
        Write-Host "  Get token from: https://github.com/$Repo/settings/actions/runners"
    }
    $Script:RemovalToken = Read-Host "  Paste removal token"
    if (-not $Script:RemovalToken) { Write-FAIL "No removal token provided."; exit 1 }
    Write-OK "Removal token received (manual entry)"
}

# =============================================================================
# Remove a single runner
# =============================================================================
function Remove-SingleRunner {
    param([string]$RunnerName)

    Write-STEP "Removing runner: $RunnerName"
    $runnerDir = Join-Path $RunnerInstallDir $RunnerName

    if (-not (Test-Path $runnerDir)) {
        Write-FAIL "Runner directory not found: $runnerDir"
        $Script:FailedList += "$RunnerName (directory not found)"
        return
    }

    # Step 1: Stop and uninstall Windows Service
    $svcCmd = Join-Path $runnerDir "svc.cmd"
    if (Test-Path $svcCmd) {
        Write-INFO "Stopping runner service..."
        try {
            & $svcCmd stop 2>&1 | Out-Null
            & $svcCmd uninstall 2>&1 | Out-Null
            Write-OK "Service stopped and uninstalled"
        } catch {
            Write-WARN "Service removal had issues: $($_.Exception.Message)"
        }
    } else {
        Write-WARN "svc.cmd not found, skipping service removal"
    }

    # Step 2: Deregister from GitHub
    $configCmd = Join-Path $runnerDir "config.cmd"
    if (Test-Path $configCmd) {
        Write-INFO "Deregistering runner from GitHub..."
        try {
            & $configCmd remove --token $RemovalToken 2>&1 | Out-Null
            Write-OK "Runner deregistered from GitHub"
        } catch {
            Write-WARN "Deregistration failed (runner may already be removed from GitHub)"
        }
    }

    # Step 3: Remove files
    Write-INFO "Removing runner files: $runnerDir"
    try {
        Remove-Item -Path $runnerDir -Recurse -Force
        Write-OK "Runner files removed"
        $Script:Removed += $RunnerName
    } catch {
        Write-FAIL "Failed to remove runner files: $($_.Exception.Message)"
        $Script:FailedList += "$RunnerName (file removal failed)"
    }
}

# =============================================================================
# Print summary
# =============================================================================
function Print-Summary {
    Write-Host ""
    Write-Host "============================================================================="
    Write-Host "  UNINSTALL SUMMARY"
    Write-Host "============================================================================="

    if ($Removed.Count -gt 0) {
        Write-Host "`n  Removed ($($Removed.Count)):"
        foreach ($r in $Removed) { Write-Host "    [OK]   $r" -ForegroundColor Green }
    }

    if ($FailedList.Count -gt 0) {
        Write-Host "`n  Failed ($($FailedList.Count)):"
        foreach ($r in $FailedList) { Write-Host "    [FAIL] $r" -ForegroundColor Red }
    }

    Write-Host ""
    Write-Host "============================================================================="

    if ($FailedList.Count -gt 0) {
        Write-Host "  Some runners could not be removed. Review errors above." -ForegroundColor Red
        exit 1
    } else {
        Write-Host "  All runners removed successfully!" -ForegroundColor Green
    }
    Write-Host "============================================================================="
}

# =============================================================================
# Main
# =============================================================================
Write-Host "============================================================================="
Write-Host "  GitHub Self-Hosted Runner - Uninstall (Windows)"
Write-Host "============================================================================="

Validate-Args
Get-RemovalToken

if ($All) {
    if (-not (Test-Path $RunnerInstallDir)) {
        Write-INFO "No runners found in $RunnerInstallDir"
        exit 0
    }

    $runnerDirs = Get-ChildItem -Path $RunnerInstallDir -Directory -ErrorAction SilentlyContinue
    if ($runnerDirs.Count -eq 0) {
        Write-INFO "No runner directories found"
        exit 0
    }

    Write-WARN "This will remove $($runnerDirs.Count) runner(s) from this VM."
    $confirm = Read-Host "Are you sure? (y/N)"
    if ($confirm -ne "y" -and $confirm -ne "Y") {
        Write-INFO "Aborted."
        exit 0
    }

    foreach ($dir in $runnerDirs) {
        Remove-SingleRunner -RunnerName $dir.Name
    }
} else {
    Remove-SingleRunner -RunnerName $Name
}

Print-Summary
