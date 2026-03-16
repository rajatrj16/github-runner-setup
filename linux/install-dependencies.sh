#!/usr/bin/env bash
# =============================================================================
# install-dependencies.sh - Install Runner Dependency Tools (Linux)
# =============================================================================
# Installs core and optional development tools needed by GitHub Actions runners.
# Detects the Linux distro and uses the appropriate package manager.
#
# Core tools (always installed):
#   Python 3, Terraform, Docker, Git, jq, curl, unzip, wget
#
# Optional tools (prompted interactively):
#   Node.js LTS, AWS CLI v2, Azure CLI, Go, Java 17, Java 21
#
# Usage:
#   sudo bash install-dependencies.sh
#   sudo bash install-dependencies.sh --skip-optional
#   sudo bash install-dependencies.sh --install-all
#
# Arguments:
#   --skip-optional   Skip all optional tool prompts
#   --install-all     Install all optional tools without prompting
# =============================================================================

set -euo pipefail

# =============================================================================
# Color helpers
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
print_fail() { echo -e "${RED}[FAIL]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_step() { echo -e "\n${BLUE}==>${NC} $1"; }

# =============================================================================
# Defaults
# =============================================================================
SKIP_OPTIONAL=false
INSTALL_ALL=false
PKG_MANAGER=""
DISTRO_ID=""

# Track installation results
INSTALLED=()
SKIPPED=()
FAILED=()

# =============================================================================
# Parse arguments
# =============================================================================
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-optional) SKIP_OPTIONAL=true; shift ;;
        --install-all)   INSTALL_ALL=true; shift ;;
        -h|--help)
            head -22 "$0" | grep "^#" | sed 's/^# \?//'
            exit 0
            ;;
        *) print_fail "Unknown argument: $1"; exit 1 ;;
    esac
done

# =============================================================================
# Detect distro and package manager
# =============================================================================
detect_distro() {
    print_step "Detecting Linux distribution"

    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        DISTRO_ID="${ID:-unknown}"
    fi

    if command -v apt-get &>/dev/null; then
        PKG_MANAGER="apt"
    elif command -v dnf &>/dev/null; then
        PKG_MANAGER="dnf"
    elif command -v yum &>/dev/null; then
        PKG_MANAGER="yum"
    else
        print_fail "No supported package manager found"
        exit 1
    fi

    print_ok "Distro: $DISTRO_ID | Package manager: $PKG_MANAGER"
}

# =============================================================================
# Helper: install a package via the detected package manager
# =============================================================================
pkg_install() {
    local packages=("$@")
    case $PKG_MANAGER in
        apt) apt-get install -y -qq "${packages[@]}" ;;
        dnf) dnf install -y -q "${packages[@]}" ;;
        yum) yum install -y -q "${packages[@]}" ;;
    esac
}

# =============================================================================
# Helper: prompt user for optional tool installation
# Returns 0 (yes) or 1 (no)
# =============================================================================
prompt_install() {
    local tool_name=$1
    if [[ "$INSTALL_ALL" == true ]]; then return 0; fi
    if [[ "$SKIP_OPTIONAL" == true ]]; then return 1; fi
    read -rp "  Install $tool_name? (y/N): " answer
    [[ "$answer" == "y" || "$answer" == "Y" ]]
}

# =============================================================================
# Helper: validate a tool is installed and record result
# =============================================================================
validate_tool() {
    local tool_name=$1
    local check_cmd=$2
    if eval "$check_cmd" &>/dev/null; then
        local version
        version=$(eval "$check_cmd" 2>&1 | head -1)
        print_ok "$tool_name installed: $version"
        INSTALLED+=("$tool_name")
        return 0
    else
        print_fail "$tool_name installation could not be verified"
        FAILED+=("$tool_name")
        return 1
    fi
}

# =============================================================================
# CORE: System utilities
# =============================================================================
install_system_utils() {
    print_step "Installing system utilities (curl, jq, unzip, wget, tar, git)"

    case $PKG_MANAGER in
        apt)
            apt-get update -qq
            pkg_install curl jq unzip wget tar git ca-certificates gnupg lsb-release software-properties-common
            ;;
        dnf|yum)
            pkg_install curl jq unzip wget tar git ca-certificates gnupg2
            ;;
    esac

    for tool in curl jq unzip wget tar git; do
        validate_tool "$tool" "$tool --version" || true
    done
}

# =============================================================================
# CORE: Python 3
# =============================================================================
install_python() {
    print_step "Installing Python 3"

    if command -v python3 &>/dev/null; then
        print_info "Python 3 already installed, upgrading..."
    fi

    case $PKG_MANAGER in
        apt) pkg_install python3 python3-pip python3-venv ;;
        dnf) pkg_install python3 python3-pip ;;
        yum) pkg_install python3 python3-pip ;;
    esac

    validate_tool "Python 3" "python3 --version" || true
    validate_tool "pip3" "pip3 --version" || true
}

# =============================================================================
# CORE: Terraform
# =============================================================================
install_terraform() {
    print_step "Installing Terraform"

    if command -v terraform &>/dev/null; then
        print_info "Terraform already installed"
        validate_tool "Terraform" "terraform --version"
        return
    fi

    case $PKG_MANAGER in
        apt)
            # Add HashiCorp GPG key and repository
            wget -qO- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg 2>/dev/null || true
            echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
                > /etc/apt/sources.list.d/hashicorp.list
            apt-get update -qq
            pkg_install terraform
            ;;
        dnf)
            dnf config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo 2>/dev/null || true
            dnf install -y -q terraform
            ;;
        yum)
            yum-config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo 2>/dev/null || true
            yum install -y -q terraform
            ;;
    esac

    validate_tool "Terraform" "terraform --version" || true
}

# =============================================================================
# CORE: Docker
# =============================================================================
install_docker() {
    print_step "Installing Docker"

    if command -v docker &>/dev/null; then
        print_info "Docker already installed"
        validate_tool "Docker" "docker --version"
        return
    fi

    case $DISTRO_ID in
        ubuntu|debian)
            # Add Docker official GPG key and repository
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/$DISTRO_ID/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null || true
            chmod a+r /etc/apt/keyrings/docker.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$DISTRO_ID $(lsb_release -cs) stable" \
                > /etc/apt/sources.list.d/docker.list
            apt-get update -qq
            pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
        centos|rhel|fedora|rocky|almalinux)
            dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null || \
            yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null || true
            pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
        *)
            print_warn "Unsupported distro for Docker auto-install: $DISTRO_ID. Trying generic approach..."
            curl -fsSL https://get.docker.com | sh || true
            ;;
    esac

    # Enable and start Docker service
    systemctl enable docker 2>/dev/null || true
    systemctl start docker 2>/dev/null || true

    # Add github-runner user to docker group if it exists
    if id "github-runner" &>/dev/null; then
        usermod -aG docker github-runner 2>/dev/null || true
    fi

    validate_tool "Docker" "docker --version" || true
}

# =============================================================================
# OPTIONAL: Node.js LTS
# =============================================================================
install_nodejs() {
    print_step "Installing Node.js LTS (optional)"

    if ! prompt_install "Node.js LTS"; then
        SKIPPED+=("Node.js")
        print_info "Skipped Node.js"
        return
    fi

    if command -v node &>/dev/null; then
        print_info "Node.js already installed"
        validate_tool "Node.js" "node --version"
        return
    fi

    # Use NodeSource for LTS installation
    case $PKG_MANAGER in
        apt)
            curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - 2>/dev/null
            pkg_install nodejs
            ;;
        dnf|yum)
            curl -fsSL https://rpm.nodesource.com/setup_lts.x | bash - 2>/dev/null
            pkg_install nodejs
            ;;
    esac

    validate_tool "Node.js" "node --version" || true
    validate_tool "npm" "npm --version" || true
}

# =============================================================================
# OPTIONAL: AWS CLI v2
# =============================================================================
install_awscli() {
    print_step "Installing AWS CLI v2 (optional)"

    if ! prompt_install "AWS CLI v2"; then
        SKIPPED+=("AWS CLI")
        print_info "Skipped AWS CLI"
        return
    fi

    if command -v aws &>/dev/null; then
        print_info "AWS CLI already installed"
        validate_tool "AWS CLI" "aws --version"
        return
    fi

    local arch
    arch=$(uname -m)
    local awscli_arch="x86_64"
    [[ "$arch" == "aarch64" ]] && awscli_arch="aarch64"

    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${awscli_arch}.zip" -o /tmp/awscliv2.zip
    unzip -qo /tmp/awscliv2.zip -d /tmp/
    /tmp/aws/install --update 2>/dev/null || /tmp/aws/install
    rm -rf /tmp/awscliv2.zip /tmp/aws

    validate_tool "AWS CLI" "aws --version" || true
}

# =============================================================================
# OPTIONAL: Azure CLI
# =============================================================================
install_azurecli() {
    print_step "Installing Azure CLI (optional)"

    if ! prompt_install "Azure CLI"; then
        SKIPPED+=("Azure CLI")
        print_info "Skipped Azure CLI"
        return
    fi

    if command -v az &>/dev/null; then
        print_info "Azure CLI already installed"
        validate_tool "Azure CLI" "az --version"
        return
    fi

    curl -fsSL https://aka.ms/InstallAzureCLIDeb | bash 2>/dev/null || {
        # Fallback: pip install
        print_warn "Script install failed, trying pip..."
        pip3 install azure-cli 2>/dev/null || true
    }

    validate_tool "Azure CLI" "az --version" || true
}

# =============================================================================
# OPTIONAL: Go (latest stable)
# =============================================================================
install_go() {
    print_step "Installing Go (optional)"

    if ! prompt_install "Go (latest stable)"; then
        SKIPPED+=("Go")
        print_info "Skipped Go"
        return
    fi

    if command -v go &>/dev/null; then
        print_info "Go already installed"
        validate_tool "Go" "go version"
        return
    fi

    # Fetch latest Go version
    local go_version
    go_version=$(curl -fsSL "https://go.dev/VERSION?m=text" 2>/dev/null | head -1)
    if [[ -z "$go_version" ]]; then
        print_fail "Could not determine latest Go version"
        FAILED+=("Go")
        return
    fi

    local arch
    arch=$(uname -m)
    local go_arch="amd64"
    [[ "$arch" == "aarch64" ]] && go_arch="arm64"

    curl -fsSL "https://go.dev/dl/${go_version}.linux-${go_arch}.tar.gz" -o /tmp/go.tar.gz
    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go.tar.gz
    rm -f /tmp/go.tar.gz

    # Add Go to system PATH if not already there
    if ! grep -q '/usr/local/go/bin' /etc/profile.d/go.sh 2>/dev/null; then
        echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh
    fi
    export PATH=$PATH:/usr/local/go/bin

    validate_tool "Go" "go version" || true
}

# =============================================================================
# OPTIONAL: Java 17
# =============================================================================
install_java17() {
    print_step "Installing Java 17 (optional)"

    if ! prompt_install "Java 17 (OpenJDK)"; then
        SKIPPED+=("Java 17")
        print_info "Skipped Java 17"
        return
    fi

    case $PKG_MANAGER in
        apt) pkg_install openjdk-17-jdk ;;
        dnf) dnf install -y -q java-17-openjdk-devel ;;
        yum) yum install -y -q java-17-openjdk-devel ;;
    esac

    validate_tool "Java 17" "java -version" || true
}

# =============================================================================
# OPTIONAL: Java 21
# =============================================================================
install_java21() {
    print_step "Installing Java 21 (optional)"

    if ! prompt_install "Java 21 (OpenJDK)"; then
        SKIPPED+=("Java 21")
        print_info "Skipped Java 21"
        return
    fi

    case $PKG_MANAGER in
        apt) pkg_install openjdk-21-jdk ;;
        dnf) dnf install -y -q java-21-openjdk-devel ;;
        yum) yum install -y -q java-21-openjdk-devel ;;
    esac

    validate_tool "Java 21" "java -version" || true
}

# =============================================================================
# Print summary
# =============================================================================
print_summary() {
    echo ""
    echo "============================================================================="
    echo "  DEPENDENCY INSTALLATION SUMMARY"
    echo "============================================================================="
    echo ""

    if [[ ${#INSTALLED[@]} -gt 0 ]]; then
        echo "  Installed (${#INSTALLED[@]}):"
        for t in "${INSTALLED[@]}"; do
            echo -e "    ${GREEN}[OK]${NC} $t"
        done
    fi

    if [[ ${#SKIPPED[@]} -gt 0 ]]; then
        echo ""
        echo "  Skipped (${#SKIPPED[@]}):"
        for t in "${SKIPPED[@]}"; do
            echo -e "    ${YELLOW}[--]${NC} $t"
        done
    fi

    if [[ ${#FAILED[@]} -gt 0 ]]; then
        echo ""
        echo "  Failed (${#FAILED[@]}):"
        for t in "${FAILED[@]}"; do
            echo -e "    ${RED}[FAIL]${NC} $t"
        done
    fi

    echo ""
    echo "============================================================================="

    if [[ ${#FAILED[@]} -gt 0 ]]; then
        echo -e "  ${RED}Some installations failed. Review errors above.${NC}"
        exit 1
    else
        echo -e "  ${GREEN}All requested tools installed successfully!${NC}"
    fi
    echo "============================================================================="
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo "============================================================================="
    echo "  GitHub Runner - Dependency Installer (Linux)"
    echo "============================================================================="

    # Must run as root
    if [[ $EUID -ne 0 ]]; then
        print_fail "This script must be run as root (sudo)"
        exit 1
    fi

    detect_distro

    # --- Core tools (always installed) ---
    print_info "Installing core tools..."
    install_system_utils
    install_python
    install_terraform
    install_docker

    # --- Optional tools (prompted) ---
    if [[ "$SKIP_OPTIONAL" != true ]]; then
        echo ""
        echo "============================================================================="
        echo "  Optional Tools"
        echo "  Select which additional tools to install (y/N for each):"
        echo "============================================================================="
    fi

    install_nodejs
    install_awscli
    install_azurecli
    install_go
    install_java17
    install_java21

    print_summary
}

main
