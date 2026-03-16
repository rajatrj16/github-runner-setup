#!/usr/bin/env bash
# =============================================================================
# setup-runner.sh - Install and Register a GitHub Self-Hosted Runner (Linux)
# =============================================================================
# This script downloads the latest GitHub Actions runner, configures it for
# org-level or repo-level use, and installs it as a systemd service.
#
# Prerequisites:
#   - sudo/root access
#   - curl, jq (auto-installed if missing)
#   - GitHub CLI (gh) authenticated OR GITHUB_PAT env var OR manual token
#
# Usage:
#   sudo bash setup-runner.sh --scope org --org my-org --name my-runner
#   sudo bash setup-runner.sh --scope repo --repo owner/repo --name my-runner
#   sudo bash setup-runner.sh --scope org --org my-org --name my-runner --labels "linux,x64,prod"
#   sudo bash setup-runner.sh --scope org --org my-org --name my-runner --token AXXXXXXX
#   sudo bash setup-runner.sh --scope org --org my-org --name my-runner --force
#
# Arguments:
#   --scope       Required. "org" or "repo"
#   --org         Required if scope=org. GitHub organization name
#   --repo        Required if scope=repo. GitHub repo in "owner/repo" format
#   --name        Optional. Runner name (default: hostname-runner)
#   --labels      Optional. Comma-separated labels (default: self-hosted)
#   --runner-group Optional. Runner group name (org-level only)
#   --token       Optional. Skip auto-fetch, use this registration token directly
#   --force       Optional. Skip VM capacity check
#   --config      Optional. Path to runner-config.env file
# =============================================================================

set -euo pipefail

# =============================================================================
# Color and formatting helpers
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
print_fail() { echo -e "${RED}[FAIL]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_step() { echo -e "\n${BLUE}==>${NC} $1"; }

# =============================================================================
# Default values
# =============================================================================
SCOPE=""
ORG=""
REPO=""
RUNNER_NAME=""
LABELS="self-hosted"
RUNNER_GROUP=""
TOKEN=""
FORCE=false
CONFIG_FILE=""
RUNNER_INSTALL_DIR="/opt/github-runners"
RUNNER_WORK_DIR="_work"
MAX_RUNNERS=""
RUNNER_DIR=""
REG_TOKEN=""

# Track validation results for final summary
VALIDATION_RESULTS=()

# =============================================================================
# Parse command-line arguments
# =============================================================================
while [[ $# -gt 0 ]]; do
    case $1 in
        --scope)        SCOPE="$2"; shift 2 ;;
        --org)          ORG="$2"; shift 2 ;;
        --repo)         REPO="$2"; shift 2 ;;
        --name)         RUNNER_NAME="$2"; shift 2 ;;
        --labels)       LABELS="$2"; shift 2 ;;
        --runner-group) RUNNER_GROUP="$2"; shift 2 ;;
        --token)        TOKEN="$2"; shift 2 ;;
        --force)        FORCE=true; shift ;;
        --config)       CONFIG_FILE="$2"; shift 2 ;;
        -h|--help)
            head -30 "$0" | grep "^#" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            print_fail "Unknown argument: $1"
            exit 1
            ;;
    esac
done

# =============================================================================
# Load config file if provided or if default exists
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
    print_info "Loading config from $CONFIG_FILE"
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
elif [[ -f "$PROJECT_DIR/config/runner-config.env" ]]; then
    print_info "Loading config from $PROJECT_DIR/config/runner-config.env"
    # shellcheck disable=SC1091
    source "$PROJECT_DIR/config/runner-config.env"
fi

# Apply config file values as defaults (CLI args take precedence)
SCOPE="${SCOPE:-${RUNNER_SCOPE:-}}"
ORG="${ORG:-${GITHUB_ORG:-}}"
REPO="${REPO:-${GITHUB_REPO:-}}"
RUNNER_NAME="${RUNNER_NAME:-${RUNNER_NAME_PREFIX:-runner}-$(hostname)}"
LABELS="${LABELS:-self-hosted}"
RUNNER_INSTALL_DIR="${RUNNER_INSTALL_DIR:-/opt/github-runners}"
RUNNER_WORK_DIR="${RUNNER_WORK_DIR:-_work}"
MAX_RUNNERS="${MAX_RUNNERS:-}"

# =============================================================================
# Validate required arguments
# =============================================================================
validate_args() {
    print_step "Validating arguments"

    if [[ -z "$SCOPE" ]]; then
        print_fail "--scope is required (org or repo)"
        exit 1
    fi

    if [[ "$SCOPE" != "org" && "$SCOPE" != "repo" ]]; then
        print_fail "--scope must be 'org' or 'repo', got: $SCOPE"
        exit 1
    fi

    if [[ "$SCOPE" == "org" && -z "$ORG" ]]; then
        print_fail "--org is required when scope is 'org'"
        exit 1
    fi

    if [[ "$SCOPE" == "repo" && -z "$REPO" ]]; then
        print_fail "--repo is required when scope is 'repo' (format: owner/repo)"
        exit 1
    fi

    print_ok "Arguments validated (scope=$SCOPE, name=$RUNNER_NAME)"
    VALIDATION_RESULTS+=("Arguments: PASS")
}

# =============================================================================
# Detect Linux distribution and set package manager
# =============================================================================
detect_distro() {
    print_step "Detecting Linux distribution"

    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        DISTRO_ID="${ID:-unknown}"
        DISTRO_VERSION="${VERSION_ID:-unknown}"
        DISTRO_NAME="${PRETTY_NAME:-unknown}"
    else
        DISTRO_ID="unknown"
        DISTRO_VERSION="unknown"
        DISTRO_NAME="unknown"
    fi

    # Determine package manager
    if command -v apt-get &>/dev/null; then
        PKG_MANAGER="apt"
    elif command -v dnf &>/dev/null; then
        PKG_MANAGER="dnf"
    elif command -v yum &>/dev/null; then
        PKG_MANAGER="yum"
    else
        print_fail "No supported package manager found (apt, dnf, yum)"
        exit 1
    fi

    print_ok "Detected: $DISTRO_NAME (ID=$DISTRO_ID, Version=$DISTRO_VERSION, Pkg=$PKG_MANAGER)"
    VALIDATION_RESULTS+=("Distro detection: PASS ($DISTRO_NAME)")
}

# =============================================================================
# Install basic prerequisites (curl, jq) if missing
# =============================================================================
install_prerequisites() {
    print_step "Checking prerequisites"

    local missing=()

    for tool in curl jq tar; do
        if ! command -v "$tool" &>/dev/null; then
            missing+=("$tool")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        print_info "Installing missing prerequisites: ${missing[*]}"
        case $PKG_MANAGER in
            apt)
                apt-get update -qq
                apt-get install -y -qq "${missing[@]}"
                ;;
            dnf)
                dnf install -y -q "${missing[@]}"
                ;;
            yum)
                yum install -y -q "${missing[@]}"
                ;;
        esac
    fi

    # Verify all prerequisites are now available
    for tool in curl jq tar; do
        if command -v "$tool" &>/dev/null; then
            print_ok "$tool is available"
        else
            print_fail "$tool could not be installed"
            exit 1
        fi
    done

    VALIDATION_RESULTS+=("Prerequisites: PASS")
}

# =============================================================================
# VM Capacity Check
# Calculates how many runner instances this VM can support based on
# CPU cores, RAM, and disk space. Uses user override if MAX_RUNNERS is set.
# =============================================================================
check_vm_capacity() {
    print_step "Checking VM capacity"

    # Get system resources
    local cpu_cores
    cpu_cores=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 2)

    local total_ram_gb
    total_ram_gb=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 4)

    # Create install dir if it does not exist yet so df can resolve it
    mkdir -p "$RUNNER_INSTALL_DIR" 2>/dev/null || true

    local free_disk_gb
    free_disk_gb=$(df -BG "$RUNNER_INSTALL_DIR" 2>/dev/null | awk 'NR==2 {gsub("G",""); print $4}' || \
                   df -BG / | awk 'NR==2 {gsub("G",""); print $4}')

    print_info "System resources: ${cpu_cores} CPU cores, ${total_ram_gb} GB RAM, ${free_disk_gb} GB free disk"

    # Calculate recommended max runners: 1 runner per 2 cores, 4 GB RAM, 10 GB disk
    local max_by_cpu=$((cpu_cores / 2))
    local max_by_ram=$((total_ram_gb / 4))
    local max_by_disk=$((free_disk_gb / 10))

    # Ensure at least 1
    [[ $max_by_cpu -lt 1 ]] && max_by_cpu=1
    [[ $max_by_ram -lt 1 ]] && max_by_ram=1
    [[ $max_by_disk -lt 1 ]] && max_by_disk=1

    # Recommended max is the minimum of the three
    local recommended_max=$max_by_cpu
    [[ $max_by_ram -lt $recommended_max ]] && recommended_max=$max_by_ram
    [[ $max_by_disk -lt $recommended_max ]] && recommended_max=$max_by_disk

    # Use user override if set, otherwise use calculated value
    local effective_max
    if [[ -n "$MAX_RUNNERS" ]]; then
        effective_max=$MAX_RUNNERS
        print_info "Using user-configured MAX_RUNNERS=$MAX_RUNNERS (recommended: $recommended_max)"
    else
        effective_max=$recommended_max
        print_info "Auto-calculated max runners: $effective_max (CPU=$max_by_cpu, RAM=$max_by_ram, Disk=$max_by_disk)"
    fi

    # Count existing runner instances
    local current_count=0
    if [[ -d "$RUNNER_INSTALL_DIR" ]]; then
        current_count=$(find "$RUNNER_INSTALL_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
    fi

    print_info "Current runners on VM: $current_count / $effective_max"

    # Decide whether to proceed
    if [[ $current_count -lt $effective_max ]]; then
        print_ok "Capacity available ($current_count/$effective_max runners)"
        VALIDATION_RESULTS+=("VM Capacity: PASS ($current_count/$effective_max)")
    elif [[ $current_count -eq $effective_max ]]; then
        print_warn "VM is at capacity ($current_count/$effective_max runners)"
        if [[ "$FORCE" == true ]]; then
            print_warn "Proceeding anyway (--force flag set)"
            VALIDATION_RESULTS+=("VM Capacity: WARN - at capacity, forced ($current_count/$effective_max)")
        else
            read -rp "VM is at capacity. Continue anyway? (y/N): " confirm
            if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                print_fail "Aborted by user. Use --force to skip this check."
                exit 1
            fi
            VALIDATION_RESULTS+=("VM Capacity: WARN - at capacity, user confirmed ($current_count/$effective_max)")
        fi
    else
        print_fail "VM is over capacity ($current_count/$effective_max runners)"
        if [[ "$FORCE" == true ]]; then
            print_warn "Proceeding anyway (--force flag set)"
            VALIDATION_RESULTS+=("VM Capacity: WARN - over capacity, forced ($current_count/$effective_max)")
        else
            print_fail "Use --force to override this check."
            exit 1
        fi
    fi
}

# =============================================================================
# Obtain registration token using 3-tier fallback:
#   1. GitHub CLI (gh)
#   2. GITHUB_PAT environment variable
#   3. Manual entry
# =============================================================================
get_registration_token() {
    print_step "Obtaining runner registration token"

    # If user provided a token directly, use it
    if [[ -n "$TOKEN" ]]; then
        print_ok "Using provided registration token"
        REG_TOKEN="$TOKEN"
        VALIDATION_RESULTS+=("Token: PASS (provided directly)")
        return
    fi

    # Build the API path based on scope
    local api_path
    if [[ "$SCOPE" == "org" ]]; then
        api_path="orgs/$ORG/actions/runners/registration-token"
    else
        api_path="repos/$REPO/actions/runners/registration-token"
    fi

    # --- Tier 1: Try GitHub CLI ---
    if command -v gh &>/dev/null; then
        print_info "Attempting token fetch via GitHub CLI (gh)..."
        if gh auth status &>/dev/null; then
            local gh_response
            gh_response=$(gh api --method POST "$api_path" 2>/dev/null || true)
            if [[ -n "$gh_response" ]]; then
                REG_TOKEN=$(echo "$gh_response" | jq -r '.token // empty')
                if [[ -n "$REG_TOKEN" ]]; then
                    print_ok "Registration token obtained via GitHub CLI"
                    VALIDATION_RESULTS+=("Token: PASS (via gh CLI)")
                    return
                fi
            fi
            print_warn "GitHub CLI token fetch failed, trying next method..."
        else
            print_warn "GitHub CLI not authenticated. Run 'gh auth login' first. Trying next method..."
        fi
    else
        print_info "GitHub CLI (gh) not found, trying next method..."
    fi

    # --- Tier 2: Try GITHUB_PAT environment variable ---
    local pat="${GITHUB_PAT:-}"
    if [[ -n "$pat" ]]; then
        print_info "Attempting token fetch via GITHUB_PAT..."
        local api_url="https://api.github.com/$api_path"
        local response
        response=$(curl -s -X POST \
            -H "Accept: application/vnd.github+json" \
            -H "Authorization: Bearer $pat" \
            "$api_url" 2>/dev/null || true)

        if [[ -n "$response" ]]; then
            REG_TOKEN=$(echo "$response" | jq -r '.token // empty')
            if [[ -n "$REG_TOKEN" ]]; then
                print_ok "Registration token obtained via GITHUB_PAT"
                VALIDATION_RESULTS+=("Token: PASS (via GITHUB_PAT)")
                return
            fi
            # Check for error message from API
            local error_msg
            error_msg=$(echo "$response" | jq -r '.message // empty')
            if [[ -n "$error_msg" ]]; then
                print_warn "API error: $error_msg"
            fi
        fi
        print_warn "GITHUB_PAT token fetch failed, trying next method..."
    else
        print_info "GITHUB_PAT not set, trying next method..."
    fi

    # --- Tier 3: Manual entry ---
    print_info "Auto-fetch methods exhausted. Please provide a registration token manually."
    echo ""
    echo "  To get a token, go to:"
    if [[ "$SCOPE" == "org" ]]; then
        echo "  https://github.com/organizations/$ORG/settings/actions/runners/new"
    else
        echo "  https://github.com/$REPO/settings/actions/runners/new"
    fi
    echo ""
    read -rp "  Paste registration token: " REG_TOKEN

    if [[ -z "$REG_TOKEN" ]]; then
        print_fail "No registration token provided. Cannot continue."
        exit 1
    fi

    print_ok "Registration token received (manual entry)"
    VALIDATION_RESULTS+=("Token: PASS (manual entry)")
}

# =============================================================================
# Download and extract the latest runner package
# =============================================================================
download_runner() {
    print_step "Downloading latest GitHub Actions runner"

    # Determine architecture
    local arch
    arch=$(uname -m)
    case $arch in
        x86_64)  RUNNER_ARCH="x64" ;;
        aarch64) RUNNER_ARCH="arm64" ;;
        armv7l)  RUNNER_ARCH="arm" ;;
        *)
            print_fail "Unsupported architecture: $arch"
            exit 1
            ;;
    esac

    # Fetch the latest runner version from GitHub API
    print_info "Fetching latest runner version..."
    local releases_url="https://api.github.com/repos/actions/runner/releases/latest"
    local latest_version
    latest_version=$(curl -s "$releases_url" | jq -r '.tag_name' | sed 's/^v//')

    if [[ -z "$latest_version" || "$latest_version" == "null" ]]; then
        print_fail "Could not determine latest runner version"
        exit 1
    fi

    print_info "Latest runner version: $latest_version"

    # Create the runner directory
    RUNNER_DIR="$RUNNER_INSTALL_DIR/$RUNNER_NAME"
    if [[ -d "$RUNNER_DIR" ]]; then
        print_warn "Runner directory already exists: $RUNNER_DIR"
        print_warn "If you want to re-install, remove it first with uninstall-runner.sh"
        exit 1
    fi

    mkdir -p "$RUNNER_DIR"

    # Download the runner package
    local download_url="https://github.com/actions/runner/releases/download/v${latest_version}/actions-runner-linux-${RUNNER_ARCH}-${latest_version}.tar.gz"
    local tar_file="/tmp/actions-runner-linux-${RUNNER_ARCH}-${latest_version}.tar.gz"

    print_info "Downloading from: $download_url"
    if curl -sL "$download_url" -o "$tar_file"; then
        print_ok "Runner package downloaded"
    else
        print_fail "Failed to download runner package"
        rm -rf "$RUNNER_DIR"
        exit 1
    fi

    # Extract the runner package
    print_info "Extracting to $RUNNER_DIR..."
    if tar -xzf "$tar_file" -C "$RUNNER_DIR"; then
        print_ok "Runner package extracted"
    else
        print_fail "Failed to extract runner package"
        rm -rf "$RUNNER_DIR"
        exit 1
    fi

    # Clean up the tar file
    rm -f "$tar_file"

    VALIDATION_RESULTS+=("Download: PASS (v$latest_version, $RUNNER_ARCH)")
}

# =============================================================================
# Configure the runner with GitHub
# =============================================================================
configure_runner() {
    print_step "Configuring runner"

    # Build the GitHub URL for runner registration
    local url
    if [[ "$SCOPE" == "org" ]]; then
        url="https://github.com/$ORG"
    else
        url="https://github.com/$REPO"
    fi

    # Build the config command arguments
    local config_cmd=(
        "$RUNNER_DIR/config.sh"
        --url "$url"
        --token "$REG_TOKEN"
        --name "$RUNNER_NAME"
        --labels "$LABELS"
        --work "$RUNNER_WORK_DIR"
        --unattended
        --replace
    )

    # Add runner group if specified (org-level only)
    if [[ -n "$RUNNER_GROUP" && "$SCOPE" == "org" ]]; then
        config_cmd+=(--runnergroup "$RUNNER_GROUP")
    fi

    print_info "Running config.sh..."
    if "${config_cmd[@]}"; then
        print_ok "Runner configured successfully"
        VALIDATION_RESULTS+=("Configuration: PASS")
    else
        print_fail "Runner configuration failed"
        VALIDATION_RESULTS+=("Configuration: FAIL")
        exit 1
    fi
}

# =============================================================================
# Install runner as a systemd service
# =============================================================================
install_service() {
    print_step "Installing runner as systemd service"

    # Create a dedicated service user if it doesn't exist
    local service_user="github-runner"
    if ! id "$service_user" &>/dev/null; then
        print_info "Creating service user: $service_user"
        useradd -r -m -s /usr/sbin/nologin "$service_user" 2>/dev/null || true
    fi

    # Set ownership of the runner directory
    chown -R "$service_user":"$service_user" "$RUNNER_DIR"

    # Install the systemd service using the runner's built-in script
    print_info "Installing systemd service..."
    cd "$RUNNER_DIR"
    if ./svc.sh install "$service_user"; then
        print_ok "Systemd service installed"
    else
        print_fail "Failed to install systemd service"
        VALIDATION_RESULTS+=("Service install: FAIL")
        exit 1
    fi

    # Start the service
    print_info "Starting runner service..."
    if ./svc.sh start; then
        print_ok "Runner service started"
    else
        print_fail "Failed to start runner service"
        VALIDATION_RESULTS+=("Service start: FAIL")
        exit 1
    fi

    # Verify the service is running
    sleep 2
    if ./svc.sh status 2>&1 | grep -qi "active\|running"; then
        print_ok "Runner service is running"
        VALIDATION_RESULTS+=("Service: PASS (running)")
    else
        print_warn "Service may not be running correctly. Check with: cd $RUNNER_DIR && sudo ./svc.sh status"
        VALIDATION_RESULTS+=("Service: WARN (check status)")
    fi

    cd - >/dev/null
}

# =============================================================================
# Final validation - verify the full installation
# =============================================================================
validate_installation() {
    print_step "Validating installation"

    local all_pass=true

    # Check runner directory exists and has key files
    if [[ -d "$RUNNER_DIR" ]]; then
        print_ok "Runner directory exists: $RUNNER_DIR"
    else
        print_fail "Runner directory missing: $RUNNER_DIR"
        all_pass=false
    fi

    # Check config file was created (proves successful registration)
    if [[ -f "$RUNNER_DIR/.runner" ]]; then
        print_ok "Runner registration file exists"
    else
        print_fail "Runner registration file missing"
        all_pass=false
    fi

    # Check credentials file exists
    if [[ -f "$RUNNER_DIR/.credentials" ]]; then
        print_ok "Runner credentials file exists"
    else
        print_fail "Runner credentials file missing"
        all_pass=false
    fi

    if [[ "$all_pass" == true ]]; then
        VALIDATION_RESULTS+=("Final validation: PASS")
    else
        VALIDATION_RESULTS+=("Final validation: FAIL")
    fi
}

# =============================================================================
# Print final summary of all validation steps
# =============================================================================
print_summary() {
    echo ""
    echo "============================================================================="
    echo "  SETUP SUMMARY"
    echo "============================================================================="
    echo "  Runner Name  : $RUNNER_NAME"
    echo "  Scope        : $SCOPE"
    if [[ "$SCOPE" == "org" ]]; then
        echo "  Organization : $ORG"
    else
        echo "  Repository   : $REPO"
    fi
    echo "  Labels       : $LABELS"
    echo "  Install Dir  : $RUNNER_DIR"
    echo "  Service Mode : systemd"
    echo "============================================================================="
    echo ""

    local has_fail=false
    for result in "${VALIDATION_RESULTS[@]}"; do
        if [[ "$result" == *"FAIL"* ]]; then
            echo -e "  ${RED}[FAIL]${NC} $result"
            has_fail=true
        elif [[ "$result" == *"WARN"* ]]; then
            echo -e "  ${YELLOW}[WARN]${NC} $result"
        else
            echo -e "  ${GREEN}[ OK ]${NC} $result"
        fi
    done

    echo ""
    if [[ "$has_fail" == true ]]; then
        echo -e "  ${RED}Setup completed with errors. Review the failures above.${NC}"
        echo "  Run debug-runner.sh for more details."
        exit 1
    else
        echo -e "  ${GREEN}Setup completed successfully!${NC}"
        echo "  Your runner should now appear at:"
        if [[ "$SCOPE" == "org" ]]; then
            echo "  https://github.com/organizations/$ORG/settings/actions/runners"
        else
            echo "  https://github.com/$REPO/settings/actions/runners"
        fi
    fi
    echo "============================================================================="
}

# =============================================================================
# Main execution flow
# =============================================================================
main() {
    echo "============================================================================="
    echo "  GitHub Self-Hosted Runner Setup (Linux)"
    echo "============================================================================="

    validate_args
    detect_distro
    install_prerequisites
    check_vm_capacity
    get_registration_token
    download_runner
    configure_runner
    install_service
    validate_installation
    print_summary
}

main
