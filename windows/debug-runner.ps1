# =============================================================================
# debug-runner.ps1 - Collect Diagnostic Information for GitHub Runners (Windows)
# =============================================================================
# Gathers detailed diagnostic data about runner instances, system state,
# network connectivity, and service logs. Outputs a diagnostics report that
# can be used for troubleshooting or shared with support.
#
# Usage:
#   .\debug-runner.ps1
#   .\debug-runner.ps1 -Name my-runner
#   .\debug-runner.ps1 -OutputFile C:\temp\runner-diagnostics.txt
#
# Parameters:
#   -Name        Optional. Debug a specific runner (default: all runners)
#   -OutputFile  Optional. Save report to a file (default: stdout only)
#   -ConfigFile  Optional. Path to runner-config.env file
# =============================================================================

param(
    [string]$Name = "",
    [string]$OutputFile = "",
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

# Report buffer
$Script:Report = @()
function Add-Report { param([string]$Line) $Script:Report += $Line }
function Add-ReportSection { param([string]$Title)
    Add-Report ""
    Add-Report "============================================================================="
    Add-Report "  $Title"
    Add-Report "============================================================================="
}

# =============================================================================
# Defaults
# =============================================================================
$RunnerInstallDir = "C:\github-runners"

# =============================================================================
# Load config
# =============================================================================
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir

function Load-Config {
    $configPath = ""
    if ($ConfigFile -and (Test-Path $ConfigFile)) { $configPath = $ConfigFile }
    elseif (Test-Path "$ProjectDir\config\runner-config.env") { $configPath = "$ProjectDir\config\runner-config.env" }
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

# =============================================================================
# Collect: System information
# =============================================================================
function Collect-SystemInfo {
    Write-STEP "Collecting system information"
    Add-ReportSection "SYSTEM INFORMATION"

    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem

    Add-Report "  Date       : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC' -AsUTC)"
    Add-Report "  Hostname   : $($env:COMPUTERNAME)"
    Add-Report "  OS         : $($os.Caption) $($os.Version)"
    Add-Report "  Arch       : $($env:PROCESSOR_ARCHITECTURE)"
    Add-Report "  Build      : $($os.BuildNumber)"
    Add-Report "  Uptime     : $((Get-Date) - $os.LastBootUpTime)"

    Write-OK "System information collected"
}

# =============================================================================
# Collect: Resource usage
# =============================================================================
function Collect-Resources {
    Write-STEP "Collecting resource usage"
    Add-ReportSection "RESOURCE USAGE"

    # CPU
    $cpuCores = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
    Add-Report "  CPU Cores  : $cpuCores"

    try {
        $cpuLoad = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
        Add-Report "  CPU Load   : $cpuLoad%"
    } catch {
        Add-Report "  CPU Load   : N/A"
    }

    # Memory
    $os = Get-CimInstance Win32_OperatingSystem
    $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $freeGB = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    $usedGB = [math]::Round($totalGB - $freeGB, 1)
    Add-Report ""
    Add-Report "  Memory:"
    Add-Report "    Total    : $totalGB GB"
    Add-Report "    Used     : $usedGB GB"
    Add-Report "    Free     : $freeGB GB"

    # Disk
    $driveLetter = $RunnerInstallDir.Substring(0, 1)
    $drive = Get-PSDrive -Name $driveLetter -ErrorAction SilentlyContinue
    if ($drive) {
        $dFreeGB = [math]::Round($drive.Free / 1GB)
        $dTotalGB = [math]::Round(($drive.Used + $drive.Free) / 1GB)
        Add-Report ""
        Add-Report "  Disk ($driveLetter`:):"
        Add-Report "    Total    : $dTotalGB GB"
        Add-Report "    Free     : $dFreeGB GB"
    }

    Write-OK "Resource usage collected"
}

# =============================================================================
# Collect: Network connectivity
# =============================================================================
function Collect-Network {
    Write-STEP "Checking network connectivity"
    Add-ReportSection "NETWORK CONNECTIVITY"

    # DNS
    try {
        $null = Resolve-DnsName github.com -ErrorAction Stop
        Add-Report "  DNS (github.com)       : OK"
    } catch {
        Add-Report "  DNS (github.com)       : FAIL"
    }

    # HTTPS
    try {
        $r = Invoke-WebRequest -Uri "https://github.com" -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        Add-Report "  HTTPS (github.com)     : OK (HTTP $($r.StatusCode))"
    } catch {
        Add-Report "  HTTPS (github.com)     : FAIL"
    }

    # API
    try {
        $r = Invoke-WebRequest -Uri "https://api.github.com" -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        Add-Report "  API (api.github.com)   : OK (HTTP $($r.StatusCode))"
    } catch {
        Add-Report "  API (api.github.com)   : FAIL"
    }

    # Actions pipelines
    try {
        $r = Invoke-WebRequest -Uri "https://pipelines.actions.githubusercontent.com" -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        Add-Report "  Actions pipelines      : OK (HTTP $($r.StatusCode))"
    } catch {
        Add-Report "  Actions pipelines      : FAIL or no response"
    }

    Write-OK "Network connectivity checks completed"
}

# =============================================================================
# Collect: GitHub CLI status
# =============================================================================
function Collect-GhStatus {
    Write-STEP "Checking GitHub CLI status"
    Add-ReportSection "GITHUB CLI STATUS"

    if (Get-Command gh -ErrorAction SilentlyContinue) {
        $ghVer = gh --version 2>&1 | Select-Object -First 1
        Add-Report "  gh installed: YES ($ghVer)"
        try {
            $authStatus = gh auth status 2>&1 | Out-String
            Add-Report ""
            Add-Report "  Auth status:"
            $authStatus -split "`n" | ForEach-Object { Add-Report "    $_" }
        } catch {
            Add-Report "  Auth status: Not authenticated"
        }
        Write-OK "GitHub CLI is installed"
    } else {
        Add-Report "  gh installed: NO"
        Add-Report "  Install gh CLI: https://cli.github.com/"
        Write-WARN "GitHub CLI is not installed"
    }
}

# =============================================================================
# Collect: Installed tool versions
# =============================================================================
function Collect-ToolVersions {
    Write-STEP "Collecting installed tool versions"
    Add-ReportSection "INSTALLED TOOLS"

    $tools = @(
        @{ Name = "git";       Cmd = "git --version" },
        @{ Name = "curl";      Cmd = "curl --version" },
        @{ Name = "jq";        Cmd = "jq --version" },
        @{ Name = "python";    Cmd = "python --version" },
        @{ Name = "pip";       Cmd = "pip --version" },
        @{ Name = "docker";    Cmd = "docker --version" },
        @{ Name = "terraform"; Cmd = "terraform version" },
        @{ Name = "node";      Cmd = "node --version" },
        @{ Name = "npm";       Cmd = "npm --version" },
        @{ Name = "aws";       Cmd = "aws --version" },
        @{ Name = "az";        Cmd = "az version" },
        @{ Name = "go";        Cmd = "go version" },
        @{ Name = "java";      Cmd = "java -version" },
        @{ Name = "gh";        Cmd = "gh --version" }
    )

    foreach ($tool in $tools) {
        if (Get-Command $tool.Name -ErrorAction SilentlyContinue) {
            try {
                $version = Invoke-Expression $tool.Cmd 2>&1 | Select-Object -First 1
                Add-Report "  $($tool.Name): $version"
            } catch {
                Add-Report "  $($tool.Name): installed (version check failed)"
            }
        } else {
            Add-Report "  $($tool.Name): NOT INSTALLED"
        }
    }

    Write-OK "Tool versions collected"
}

# =============================================================================
# Collect: Runner-specific diagnostics
# =============================================================================
function Collect-RunnerDiagnostics {
    param([string]$RunnerDir)

    $runnerName = Split-Path -Leaf $RunnerDir
    Write-STEP "Diagnosing runner: $runnerName"
    Add-ReportSection "RUNNER: $runnerName"

    Add-Report "  Directory  : $RunnerDir"

    if (-not (Test-Path $RunnerDir)) {
        Add-Report "  Status     : DIRECTORY NOT FOUND"
        Write-FAIL "Runner directory not found: $RunnerDir"
        return
    }

    # Registration status
    $runnerFile = Join-Path $RunnerDir ".runner"
    if (Test-Path $runnerFile) {
        Add-Report "  Registered : YES"
        try {
            $info = Get-Content $runnerFile | ConvertFrom-Json
            Add-Report "  Agent Name : $($info.agentName)"
            Add-Report "  Pool ID    : $($info.poolId)"
        } catch { }
    } else {
        Add-Report "  Registered : NO (.runner file missing)"
    }

    # Credentials
    if (Test-Path (Join-Path $RunnerDir ".credentials")) {
        Add-Report "  Credentials: YES"
    } else {
        Add-Report "  Credentials: MISSING"
    }

    # Service status
    Add-Report ""
    Add-Report "  Service Status:"
    $svcCmd = Join-Path $RunnerDir "svc.cmd"
    if (Test-Path $svcCmd) {
        try {
            $svcOutput = & $svcCmd status 2>&1 | Out-String
            $svcOutput -split "`n" | ForEach-Object { Add-Report "    $_" }
        } catch {
            Add-Report "    Could not query service status"
        }
    } else {
        Add-Report "    svc.cmd not found"
    }

    # Recent logs
    $logDir = Join-Path $RunnerDir "_diag"
    if (Test-Path $logDir) {
        Add-Report ""
        Add-Report "  Recent Logs:"

        $latestLog = Get-ChildItem -Path $logDir -Filter "Runner_*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latestLog) {
            Add-Report "    Latest runner log: $($latestLog.Name)"
            Add-Report "    --- Last 20 lines ---"
            Get-Content $latestLog.FullName -Tail 20 -ErrorAction SilentlyContinue | ForEach-Object { Add-Report "    $_" }

            $errorCount = (Select-String -Path $latestLog.FullName -Pattern "error|exception|fail" -CaseSensitive:$false -ErrorAction SilentlyContinue | Measure-Object).Count
            Add-Report "    --- Error count: $errorCount ---"

            if ($errorCount -gt 0) {
                Add-Report ""
                Add-Report "    Recent errors:"
                Select-String -Path $latestLog.FullName -Pattern "error|exception|fail" -CaseSensitive:$false -ErrorAction SilentlyContinue |
                    Select-Object -Last 10 | ForEach-Object { Add-Report "      $($_.Line)" }
            }
        } else {
            Add-Report "    No Runner log files found"
        }

        $latestWorkerLog = Get-ChildItem -Path $logDir -Filter "Worker_*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latestWorkerLog) {
            Add-Report ""
            Add-Report "    Latest worker log: $($latestWorkerLog.Name)"
            Add-Report "    --- Last 10 lines ---"
            Get-Content $latestWorkerLog.FullName -Tail 10 -ErrorAction SilentlyContinue | ForEach-Object { Add-Report "    $_" }
        }
    } else {
        Add-Report "  Logs: _diag directory not found"
    }

    Write-OK "Diagnostics collected for $runnerName"
}

# =============================================================================
# Save report
# =============================================================================
function Save-Report {
    if ($OutputFile) {
        $Script:Report | Out-File -FilePath $OutputFile -Encoding UTF8
        Write-OK "Report saved to: $OutputFile"
    }

    # Always print to stdout
    Write-Host ""
    $Script:Report | ForEach-Object { Write-Host $_ }
}

# =============================================================================
# Main
# =============================================================================
Write-Host "============================================================================="
Write-Host "  GitHub Runner - Diagnostics Report (Windows)"
Write-Host "============================================================================="

Add-Report "============================================================================="
Add-Report "  GITHUB RUNNER DIAGNOSTICS REPORT"
Add-Report "  Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC' -AsUTC)"
Add-Report "============================================================================="

Collect-SystemInfo
Collect-Resources
Collect-Network
Collect-GhStatus
Collect-ToolVersions

# Runner-specific diagnostics
if ($Name) {
    Collect-RunnerDiagnostics -RunnerDir (Join-Path $RunnerInstallDir $Name)
} else {
    if (Test-Path $RunnerInstallDir) {
        $dirs = Get-ChildItem -Path $RunnerInstallDir -Directory -ErrorAction SilentlyContinue
        if ($dirs.Count -eq 0) {
            Add-ReportSection "RUNNERS"
            Add-Report "  No runner directories found in $RunnerInstallDir"
            Write-WARN "No runners found"
        } else {
            foreach ($dir in $dirs) {
                Collect-RunnerDiagnostics -RunnerDir $dir.FullName
            }
        }
    } else {
        Add-ReportSection "RUNNERS"
        Add-Report "  Runner install directory does not exist: $RunnerInstallDir"
        Write-WARN "Runner install directory missing"
    }
}

Add-Report ""
Add-Report "============================================================================="
Add-Report "  END OF DIAGNOSTICS REPORT"
Add-Report "============================================================================="

Save-Report
Write-OK "Diagnostics collection complete"
