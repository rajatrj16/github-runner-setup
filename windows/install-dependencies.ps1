# =============================================================================
# install-dependencies.ps1 - Install Runner Dependency Tools (Windows)
# =============================================================================
# Installs core and optional development tools needed by GitHub Actions runners.
# Uses winget (preferred) or chocolatey as package manager.
#
# Core tools (always installed):
#   Python 3, Terraform, Docker Desktop, Git, jq, curl
#
# Optional tools (prompted interactively):
#   Node.js LTS, AWS CLI v2, Azure CLI, Go, Java 17, Java 21
#
# Usage:
#   .\install-dependencies.ps1
#   .\install-dependencies.ps1 -SkipOptional
#   .\install-dependencies.ps1 -InstallAll
#
# Parameters:
#   -SkipOptional   Skip all optional tool prompts
#   -InstallAll     Install all optional tools without prompting
# =============================================================================

param(
    [switch]$SkipOptional,
    [switch]$InstallAll
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
# Track results
# =============================================================================
$Installed = @()
$Skipped = @()
$Failed = @()

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
# Detect package manager (winget or chocolatey)
# =============================================================================
$PkgManager = ""

function Detect-PackageManager {
    Write-STEP "Detecting package manager"

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        $Script:PkgManager = "winget"
        Write-OK "Found winget"
    } elseif (Get-Command choco -ErrorAction SilentlyContinue) {
        $Script:PkgManager = "choco"
        Write-OK "Found chocolatey"
    } else {
        Write-WARN "Neither winget nor chocolatey found. Attempting to install winget..."
        # winget is typically pre-installed on Windows 10/11. If missing, try choco.
        try {
            # Try installing Chocolatey as fallback
            Set-ExecutionPolicy Bypass -Scope Process -Force
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
            Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
            $Script:PkgManager = "choco"
            Write-OK "Chocolatey installed"
        } catch {
            Write-FAIL "Could not install a package manager. Install winget or chocolatey manually."
            exit 1
        }
    }
}

# =============================================================================
# Helper: Install a package
# =============================================================================
function Install-Package {
    param(
        [string]$WingetId,
        [string]$ChocoId,
        [string]$DisplayName
    )

    Write-INFO "Installing $DisplayName..."

    try {
        if ($PkgManager -eq "winget") {
            winget install --id $WingetId --accept-source-agreements --accept-package-agreements --silent 2>&1 | Out-Null
        } else {
            choco install $ChocoId -y --no-progress 2>&1 | Out-Null
        }
        return $true
    } catch {
        Write-WARN "Package manager install failed for $DisplayName : $($_.Exception.Message)"
        return $false
    }
}

# =============================================================================
# Helper: Prompt for optional tool
# =============================================================================
function Prompt-Install {
    param([string]$ToolName)

    if ($InstallAll) { return $true }
    if ($SkipOptional) { return $false }

    $answer = Read-Host "  Install $ToolName ? (y/N)"
    return ($answer -eq "y" -or $answer -eq "Y")
}

# =============================================================================
# Helper: Validate tool installation
# =============================================================================
function Validate-Tool {
    param(
        [string]$ToolName,
        [string]$Command
    )

    try {
        $version = Invoke-Expression $Command 2>&1 | Select-Object -First 1
        Write-OK "$ToolName installed: $version"
        $Script:Installed += $ToolName
        return $true
    } catch {
        Write-FAIL "$ToolName installation could not be verified"
        $Script:Failed += $ToolName
        return $false
    }
}

# =============================================================================
# Refresh PATH so newly installed tools are discoverable
# =============================================================================
function Refresh-Path {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
}

# =============================================================================
# CORE: Git
# =============================================================================
function Install-Git {
    Write-STEP "Installing Git"

    if (Get-Command git -ErrorAction SilentlyContinue) {
        Write-INFO "Git already installed"
        Validate-Tool "Git" "git --version"
        return
    }

    Install-Package -WingetId "Git.Git" -ChocoId "git" -DisplayName "Git"
    Refresh-Path
    Validate-Tool "Git" "git --version"
}

# =============================================================================
# CORE: Python 3
# =============================================================================
function Install-Python {
    Write-STEP "Installing Python 3"

    if (Get-Command python -ErrorAction SilentlyContinue) {
        $pyVer = python --version 2>&1
        if ($pyVer -match "Python 3") {
            Write-INFO "Python 3 already installed"
            Validate-Tool "Python 3" "python --version"
            return
        }
    }

    Install-Package -WingetId "Python.Python.3.12" -ChocoId "python3" -DisplayName "Python 3"
    Refresh-Path
    Validate-Tool "Python 3" "python --version"
    Validate-Tool "pip" "pip --version"
}

# =============================================================================
# CORE: Terraform
# =============================================================================
function Install-Terraform {
    Write-STEP "Installing Terraform"

    if (Get-Command terraform -ErrorAction SilentlyContinue) {
        Write-INFO "Terraform already installed"
        Validate-Tool "Terraform" "terraform --version"
        return
    }

    Install-Package -WingetId "Hashicorp.Terraform" -ChocoId "terraform" -DisplayName "Terraform"
    Refresh-Path
    Validate-Tool "Terraform" "terraform --version"
}

# =============================================================================
# CORE: Docker Desktop
# =============================================================================
function Install-Docker {
    Write-STEP "Installing Docker Desktop"

    if (Get-Command docker -ErrorAction SilentlyContinue) {
        Write-INFO "Docker already installed"
        Validate-Tool "Docker" "docker --version"
        return
    }

    Install-Package -WingetId "Docker.DockerDesktop" -ChocoId "docker-desktop" -DisplayName "Docker Desktop"
    Refresh-Path

    # Docker Desktop may need a restart to fully work
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        Validate-Tool "Docker" "docker --version"
    } else {
        Write-WARN "Docker installed but may require a system restart to be available"
        $Script:Installed += "Docker (restart required)"
    }
}

# =============================================================================
# CORE: jq
# =============================================================================
function Install-Jq {
    Write-STEP "Installing jq"

    if (Get-Command jq -ErrorAction SilentlyContinue) {
        Write-INFO "jq already installed"
        Validate-Tool "jq" "jq --version"
        return
    }

    Install-Package -WingetId "jqlang.jq" -ChocoId "jq" -DisplayName "jq"
    Refresh-Path
    Validate-Tool "jq" "jq --version"
}

# =============================================================================
# OPTIONAL: Node.js LTS
# =============================================================================
function Install-NodeJS {
    Write-STEP "Node.js LTS (optional)"

    if (-not (Prompt-Install "Node.js LTS")) {
        $Script:Skipped += "Node.js"
        Write-INFO "Skipped Node.js"
        return
    }

    if (Get-Command node -ErrorAction SilentlyContinue) {
        Write-INFO "Node.js already installed"
        Validate-Tool "Node.js" "node --version"
        return
    }

    Install-Package -WingetId "OpenJS.NodeJS.LTS" -ChocoId "nodejs-lts" -DisplayName "Node.js LTS"
    Refresh-Path
    Validate-Tool "Node.js" "node --version"
    Validate-Tool "npm" "npm --version"
}

# =============================================================================
# OPTIONAL: AWS CLI v2
# =============================================================================
function Install-AWSCLI {
    Write-STEP "AWS CLI v2 (optional)"

    if (-not (Prompt-Install "AWS CLI v2")) {
        $Script:Skipped += "AWS CLI"
        Write-INFO "Skipped AWS CLI"
        return
    }

    if (Get-Command aws -ErrorAction SilentlyContinue) {
        Write-INFO "AWS CLI already installed"
        Validate-Tool "AWS CLI" "aws --version"
        return
    }

    Install-Package -WingetId "Amazon.AWSCLI" -ChocoId "awscli" -DisplayName "AWS CLI"
    Refresh-Path
    Validate-Tool "AWS CLI" "aws --version"
}

# =============================================================================
# OPTIONAL: Azure CLI
# =============================================================================
function Install-AzureCLI {
    Write-STEP "Azure CLI (optional)"

    if (-not (Prompt-Install "Azure CLI")) {
        $Script:Skipped += "Azure CLI"
        Write-INFO "Skipped Azure CLI"
        return
    }

    if (Get-Command az -ErrorAction SilentlyContinue) {
        Write-INFO "Azure CLI already installed"
        Validate-Tool "Azure CLI" "az --version"
        return
    }

    Install-Package -WingetId "Microsoft.AzureCLI" -ChocoId "azure-cli" -DisplayName "Azure CLI"
    Refresh-Path
    Validate-Tool "Azure CLI" "az --version"
}

# =============================================================================
# OPTIONAL: Go
# =============================================================================
function Install-Go {
    Write-STEP "Go (optional)"

    if (-not (Prompt-Install "Go (latest stable)")) {
        $Script:Skipped += "Go"
        Write-INFO "Skipped Go"
        return
    }

    if (Get-Command go -ErrorAction SilentlyContinue) {
        Write-INFO "Go already installed"
        Validate-Tool "Go" "go version"
        return
    }

    Install-Package -WingetId "GoLang.Go" -ChocoId "golang" -DisplayName "Go"
    Refresh-Path
    Validate-Tool "Go" "go version"
}

# =============================================================================
# OPTIONAL: Java 17
# =============================================================================
function Install-Java17 {
    Write-STEP "Java 17 (optional)"

    if (-not (Prompt-Install "Java 17 (OpenJDK)")) {
        $Script:Skipped += "Java 17"
        Write-INFO "Skipped Java 17"
        return
    }

    Install-Package -WingetId "EclipseAdoptium.Temurin.17.JDK" -ChocoId "temurin17" -DisplayName "Java 17"
    Refresh-Path
    Validate-Tool "Java 17" "java -version"
}

# =============================================================================
# OPTIONAL: Java 21
# =============================================================================
function Install-Java21 {
    Write-STEP "Java 21 (optional)"

    if (-not (Prompt-Install "Java 21 (OpenJDK)")) {
        $Script:Skipped += "Java 21"
        Write-INFO "Skipped Java 21"
        return
    }

    Install-Package -WingetId "EclipseAdoptium.Temurin.21.JDK" -ChocoId "temurin21" -DisplayName "Java 21"
    Refresh-Path
    Validate-Tool "Java 21" "java -version"
}

# =============================================================================
# Print summary
# =============================================================================
function Print-Summary {
    Write-Host ""
    Write-Host "============================================================================="
    Write-Host "  DEPENDENCY INSTALLATION SUMMARY"
    Write-Host "============================================================================="
    Write-Host ""

    if ($Installed.Count -gt 0) {
        Write-Host "  Installed ($($Installed.Count)):"
        foreach ($t in $Installed) { Write-Host "    [OK]   $t" -ForegroundColor Green }
    }

    if ($Skipped.Count -gt 0) {
        Write-Host ""
        Write-Host "  Skipped ($($Skipped.Count)):"
        foreach ($t in $Skipped) { Write-Host "    [--]   $t" -ForegroundColor Yellow }
    }

    if ($Failed.Count -gt 0) {
        Write-Host ""
        Write-Host "  Failed ($($Failed.Count)):"
        foreach ($t in $Failed) { Write-Host "    [FAIL] $t" -ForegroundColor Red }
    }

    Write-Host ""
    Write-Host "============================================================================="

    if ($Failed.Count -gt 0) {
        Write-Host "  Some installations failed. Review errors above." -ForegroundColor Red
        exit 1
    } else {
        Write-Host "  All requested tools installed successfully!" -ForegroundColor Green
    }
    Write-Host "============================================================================="
}

# =============================================================================
# Main
# =============================================================================
Write-Host "============================================================================="
Write-Host "  GitHub Runner - Dependency Installer (Windows)"
Write-Host "============================================================================="

Detect-PackageManager

# --- Core tools ---
Write-INFO "Installing core tools..."
Install-Git
Install-Python
Install-Terraform
Install-Docker
Install-Jq

# --- Optional tools ---
if (-not $SkipOptional) {
    Write-Host ""
    Write-Host "============================================================================="
    Write-Host "  Optional Tools"
    Write-Host "  Select which additional tools to install (y/N for each):"
    Write-Host "============================================================================="
}

Install-NodeJS
Install-AWSCLI
Install-AzureCLI
Install-Go
Install-Java17
Install-Java21

Print-Summary
