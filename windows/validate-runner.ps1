# =============================================================================
# validate-runner.ps1 - Health Check and Validation for GitHub Runners (Windows)
# =============================================================================
# Validates that installed GitHub Actions runners are healthy and operational.
# Checks service status, registration files, tool versions, system resources,
# and VM capacity.
#
# Usage:
#   .\validate-runner.ps1
#   .\validate-runner.ps1 -Name my-runner
#   .\validate-runner.ps1 -Verbose
#
# Parameters:
#   -Name        Optional. Validate a specific runner only (default: all runners)
#   -Detailed    Optional. Show detailed output for each check
#   -ConfigFile  Optional. Path to runner-config.env file
# =============================================================================

param(
    [string]$Name = "",
    [switch]$Detailed,
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
$MaxRunners = ""
$PassCount = 0
$WarnCount = 0
$FailCount = 0

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
if ($Script:Config_RUNNER_INSTALL_DIR) { $RunnerInstallDir = $Script:Config_RUNNER_INSTALL_DIR }
if ($Script:Config_MAX_RUNNERS) { $MaxRunners = $Script:Config_MAX_RUNNERS }

# =============================================================================
# Check: System resources
# =============================================================================
function Check-SystemResources {
    Write-STEP "System Resources"

    # CPU
    $cpuCores = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
    Write-INFO "CPU cores: $cpuCores"

    # RAM
    $os = Get-CimInstance Win32_OperatingSystem
    $totalRamGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $freeRamGB = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    $freeRamMB = [math]::Round($os.FreePhysicalMemory / 1KB)
    Write-INFO "RAM: $freeRamGB GB free / $totalRamGB GB total"

    if ($freeRamMB -lt 512) {
        Write-WARN "Available RAM is critically low ($freeRamMB MB)"
        $Script:WarnCount++
    } else {
        Write-OK "RAM is adequate"
        $Script:PassCount++
    }

    # Disk
    $driveLetter = $RunnerInstallDir.Substring(0, 1)
    $drive = Get-PSDrive -Name $driveLetter -ErrorAction SilentlyContinue
    if ($drive) {
        $freeGB = [math]::Round($drive.Free / 1GB)
        $totalGB = [math]::Round(($drive.Used + $drive.Free) / 1GB)
        Write-INFO "Disk ($driveLetter`:): $freeGB GB free / $totalGB GB total"

        if ($freeGB -lt 5) {
            Write-WARN "Disk space is critically low ($freeGB GB free)"
            $Script:WarnCount++
        } else {
            Write-OK "Disk space is adequate"
            $Script:PassCount++
        }
    }
}

# =============================================================================
# Check: VM capacity
# =============================================================================
function Check-VMCapacity {
    Write-STEP "VM Capacity"

    $cpuCores = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
    $totalRamGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $driveLetter = $RunnerInstallDir.Substring(0, 1)
    $freeDiskGB = [math]::Round((Get-PSDrive -Name $driveLetter).Free / 1GB)

    $maxByCpu = [math]::Max(1, [math]::Floor($cpuCores / 2))
    $maxByRam = [math]::Max(1, [math]::Floor($totalRamGB / 4))
    $maxByDisk = [math]::Max(1, [math]::Floor($freeDiskGB / 10))
    $recommendedMax = [math]::Min($maxByCpu, [math]::Min($maxByRam, $maxByDisk))

    $effectiveMax = if ($MaxRunners) { [int]$MaxRunners } else { $recommendedMax }

    $currentCount = 0
    if (Test-Path $RunnerInstallDir) {
        $currentCount = (Get-ChildItem -Path $RunnerInstallDir -Directory -ErrorAction SilentlyContinue | Measure-Object).Count
    }

    Write-INFO "Runners: $currentCount / $effectiveMax (recommended max: $recommendedMax)"

    if ($currentCount -le $effectiveMax) {
        Write-OK "VM capacity: $currentCount / $effectiveMax"
        $Script:PassCount++
    } else {
        Write-WARN "VM over capacity: $currentCount / $effectiveMax"
        $Script:WarnCount++
    }
}

# =============================================================================
# Check: Network connectivity
# =============================================================================
function Check-Network {
    Write-STEP "Network Connectivity"

    # DNS
    try {
        $null = Resolve-DnsName github.com -ErrorAction Stop
        Write-OK "DNS resolution for github.com"
        $Script:PassCount++
    } catch {
        Write-FAIL "Cannot resolve github.com"
        $Script:FailCount++
    }

    # HTTPS
    try {
        $response = Invoke-WebRequest -Uri "https://github.com" -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        Write-OK "HTTPS connectivity to github.com (HTTP $($response.StatusCode))"
        $Script:PassCount++
    } catch {
        Write-FAIL "Cannot reach https://github.com"
        $Script:FailCount++
    }

    # GitHub API
    try {
        $response = Invoke-WebRequest -Uri "https://api.github.com" -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        Write-OK "GitHub API is accessible (HTTP $($response.StatusCode))"
        $Script:PassCount++
    } catch {
        Write-FAIL "Cannot reach GitHub API"
        $Script:FailCount++
    }
}

# =============================================================================
# Check: Installed tools
# =============================================================================
function Check-Tools {
    Write-STEP "Installed Tools"

    $coreTools = @(
        @{ Name = "git";       Cmd = "git --version" },
        @{ Name = "curl";      Cmd = "curl --version" },
        @{ Name = "jq";        Cmd = "jq --version" },
        @{ Name = "python";    Cmd = "python --version" },
        @{ Name = "docker";    Cmd = "docker --version" },
        @{ Name = "terraform"; Cmd = "terraform --version" }
    )

    foreach ($tool in $coreTools) {
        if (Get-Command $tool.Name -ErrorAction SilentlyContinue) {
            if ($Detailed) {
                $version = Invoke-Expression $tool.Cmd 2>&1 | Select-Object -First 1
                Write-OK "$($tool.Name): $version"
            } else {
                Write-OK "$($tool.Name) is installed"
            }
            $Script:PassCount++
        } else {
            Write-WARN "$($tool.Name) is not installed"
            $Script:WarnCount++
        }
    }

    # Optional tools (info only)
    $optionalTools = @("node", "npm", "aws", "az", "go", "java", "gh")
    foreach ($tool in $optionalTools) {
        if (Get-Command $tool -ErrorAction SilentlyContinue) {
            if ($Detailed) {
                try {
                    $version = Invoke-Expression "$tool --version" 2>&1 | Select-Object -First 1
                    Write-INFO "$tool (optional): $version"
                } catch {
                    Write-INFO "$tool (optional) is installed"
                }
            } else {
                Write-INFO "$tool (optional) is installed"
            }
        }
    }
}

# =============================================================================
# Check: Individual runner health
# =============================================================================
function Check-Runner {
    param([string]$RunnerDir)

    $runnerName = Split-Path -Leaf $RunnerDir
    Write-STEP "Runner: $runnerName"

    # Check directory structure
    if ((Test-Path (Join-Path $RunnerDir "config.cmd")) -and (Test-Path (Join-Path $RunnerDir "run.cmd"))) {
        Write-OK "Runner binaries present"
        $Script:PassCount++
    } else {
        Write-FAIL "Runner binaries missing in $RunnerDir"
        $Script:FailCount++
        return
    }

    # Check registration
    $runnerFile = Join-Path $RunnerDir ".runner"
    if (Test-Path $runnerFile) {
        Write-OK "Runner is registered (.runner file exists)"
        $Script:PassCount++

        if ($Detailed) {
            try {
                $info = Get-Content $runnerFile | ConvertFrom-Json
                Write-INFO "Registered name: $($info.agentName)"
            } catch { }
        }
    } else {
        Write-FAIL "Runner is NOT registered (.runner file missing)"
        $Script:FailCount++
    }

    # Check credentials
    if (Test-Path (Join-Path $RunnerDir ".credentials")) {
        Write-OK "Credentials file exists"
        $Script:PassCount++
    } else {
        Write-FAIL "Credentials file missing"
        $Script:FailCount++
    }

    # Check Windows Service status
    $svcCmd = Join-Path $RunnerDir "svc.cmd"
    if (Test-Path $svcCmd) {
        try {
            $svcOutput = & $svcCmd status 2>&1 | Out-String
            if ($svcOutput -match "Running|Started") {
                Write-OK "Service is running"
                $Script:PassCount++
            } elseif ($svcOutput -match "Stopped|Inactive") {
                Write-FAIL "Service is NOT running"
                $Script:FailCount++
            } else {
                Write-WARN "Service status unclear"
                $Script:WarnCount++
            }
        } catch {
            Write-WARN "Could not check service status"
            $Script:WarnCount++
        }
    }

    # Check runner logs for errors
    $logDir = Join-Path $RunnerDir "_diag"
    if (Test-Path $logDir) {
        $latestLog = Get-ChildItem -Path $logDir -Filter "Runner_*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latestLog) {
            $errorCount = (Select-String -Path $latestLog.FullName -Pattern "error|exception|fail" -CaseSensitive:$false -ErrorAction SilentlyContinue | Measure-Object).Count
            if ($errorCount -gt 0) {
                Write-WARN "Found $errorCount error(s) in latest log: $($latestLog.Name)"
                $Script:WarnCount++
                if ($Detailed) {
                    Write-Host "  Last 3 errors:"
                    Select-String -Path $latestLog.FullName -Pattern "error|exception|fail" -CaseSensitive:$false | Select-Object -Last 3 | ForEach-Object { Write-Host "    $($_.Line)" }
                }
            } else {
                Write-OK "No errors in latest runner log"
                $Script:PassCount++
            }
        }
    }
}

# =============================================================================
# Print summary
# =============================================================================
function Print-Summary {
    Write-Host ""
    Write-Host "============================================================================="
    Write-Host "  VALIDATION SUMMARY"
    Write-Host "============================================================================="
    Write-Host ""
    Write-Host "  Passed  : $PassCount" -ForegroundColor Green
    Write-Host "  Warnings: $WarnCount" -ForegroundColor Yellow
    Write-Host "  Failed  : $FailCount" -ForegroundColor Red
    Write-Host ""

    if ($FailCount -gt 0) {
        Write-Host "  Some checks failed. Run debug-runner.ps1 for detailed diagnostics." -ForegroundColor Red
        Write-Host "============================================================================="
        exit 1
    } elseif ($WarnCount -gt 0) {
        Write-Host "  All critical checks passed, but there are warnings to review." -ForegroundColor Yellow
        Write-Host "============================================================================="
    } else {
        Write-Host "  All checks passed! Runners are healthy." -ForegroundColor Green
        Write-Host "============================================================================="
    }
}

# =============================================================================
# Main
# =============================================================================
Write-Host "============================================================================="
Write-Host "  GitHub Runner - Validation & Health Check (Windows)"
Write-Host "============================================================================="

Check-SystemResources
Check-VMCapacity
Check-Network
Check-Tools

# Check individual runners
if ($Name) {
    $runnerDir = Join-Path $RunnerInstallDir $Name
    if (Test-Path $runnerDir) {
        Check-Runner -RunnerDir $runnerDir
    } else {
        Write-FAIL "Runner not found: $runnerDir"
        $FailCount++
    }
} else {
    if (Test-Path $RunnerInstallDir) {
        $dirs = Get-ChildItem -Path $RunnerInstallDir -Directory -ErrorAction SilentlyContinue
        if ($dirs.Count -eq 0) {
            Write-WARN "No runner directories found in $RunnerInstallDir"
            $WarnCount++
        } else {
            foreach ($dir in $dirs) {
                Check-Runner -RunnerDir $dir.FullName
            }
        }
    } else {
        Write-WARN "Runner install directory does not exist: $RunnerInstallDir"
        $WarnCount++
    }
}

Print-Summary
