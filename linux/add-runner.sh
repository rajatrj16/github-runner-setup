#!/usr/bin/env bash
# =============================================================================
# add-runner.sh - Add Additional Runner Instances to an Existing VM (Linux)
# =============================================================================
# This script adds one or more new GitHub Actions runner instances to a VM
# that already has runners configured. Each instance gets its own directory,
# unique name, and separate systemd service.
#
# Prerequisites:
#   - sudo/root access
#   - At least one runner already set up via setup-runner.sh
#   - curl, jq (should already be installed)
#   - GitHub CLI (gh) authenticated OR GITHUB_PAT env var OR manual token
#
# Usage:
#   sudo bash add-runner.sh --scope org --org my-org --count 2
#   sudo bash add-runner.sh --scope repo --repo owner/repo --count 3 --labels "linux,x64"
#   sudo bash add-runner.sh --scope org --org my-org --instance-id worker-5
#   sudo bash add-runner.sh --scope org --org my-org --count 2 --force
#
# Arguments:
#   --scope        Required. "org" or "repo"
#   --org          Required if scope=org. GitHub organization name
#   --repo         Required if scope=repo. GitHub repo in "owner/repo" format
#   --count        Optional. Number of runner instances to add (default: 1)
#   --instance-id  Optional. Custom suffix for the runner name (only with count=1)
#   --labels       Optional. Comma-separated labels (default: self-hosted)
#   --runner-group Optional. Runner group name (org-level only)
#   --token        Optional. Skip auto-fetch, use this registration token directly
#   --force        Optional. Skip VM capacity check
#   --config       Optional. Path to runner-config.env file
# =============================================================================

set -euo pipefail

# =============================================================================
# Color and formatting helpers
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
# Default values
# =============================================================================
SCOPE=""
ORG=""
REPO=""
COUNT=1
INSTANCE_ID=""
LABELS="self-hosted"
RUNNER_GROUP=""
TOKEN=""
FORCE=false
CONFIG_FILE=""
RUNNER_INSTALL_DIR="/opt/github-runners"
RUNNER_WORK_DIR="_work"
MAX_RUNNERS=""
REG_TOKEN=""

# Track results
VALIDATION_RESULTS=()
CREATED_RUNNERS=()
FAILED_RUNNERS=()

# =============================================================================
# Parse command-line arguments
# =============================================================================
while [[ $# -gt 0 ]]; do
    case $1 in
        --scope)        SCOPE="$2"; shift 2 ;;
        --org)          ORG="$2"; shift 2 ;;
        --repo)         REPO="$2"; shift 2 ;;
        --count)        COUNT="$2"; shift 2 ;;
        --instance-id)  INSTANCE_ID="$2"; shift 2 ;;
        --labels)       LABELS="$2"; shift 2 ;;
        --runner-group) RUNNER_GROUP="$2"; shift 2 ;;
        --token)        TOKEN="$2"; shift 2 ;;
        --force)        FORCE=true; shift ;;
        --config)       CONFIG_FILE="$2"; shift 2 ;;
        -h|--help)
            head -35 "$0" | grep "^#" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            print_fail "Unknown argument: $1"
            exit 1
            ;;
    esac
done

# =============================================================================
# Load config file
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
elif [[ -f "$PROJECT_DIR/config/runner-config.env" ]]; then
    # shellcheck disable=SC1091
    source "$PROJECT_DIR/config/runner-config.env"
fi

# Apply config defaults
SCOPE="${SCOPE:-${RUNNER_SCOPE:-}}"
ORG="${ORG:-${GITHUB_ORG:-}}"
REPO="${REPO:-${GITHUB_REPO:-}}"
LABELS="${LABELS:-self-hosted}"
RUNNER_INSTALL_DIR="${RUNNER_INSTALL_DIR:-/opt/github-runners}"
RUNNER_WORK_DIR="${RUNNER_WORK_DIR:-_work}"
MAX_RUNNERS="${MAX_RUNNERS:-}"

# =============================================================================
# Validate arguments
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

    # Validate count is a positive integer
    if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || [[ "$COUNT" -lt 1 ]]; then
        print_fail "--count must be a positive integer, got: $COUNT"
        exit 1
    fi

    # instance-id is only valid with count=1
    if [[ -n "$INSTANCE_ID" && "$COUNT" -gt 1 ]]; then
        print_fail "--instance-id can only be used with --count 1"
        exit 1
    fi

    print_ok "Arguments validated (scope=$SCOPE, count=$COUNT)"
}

# =============================================================================
# VM Capacity Check - checks if the VM can handle the requested number of runners
# =============================================================================
check_vm_capacity() {
    print_step "Checking VM capacity for $COUNT additional runner(s)"

    local cpu_cores
    cpu_cores=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 2)

    local total_ram_gb
    total_ram_gb=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 4)

    mkdir -p "$RUNNER_INSTALL_DIR" 2>/dev/null || true

    local free_disk_gb
    free_disk_gb=$(df -BG "$RUNNER_INSTALL_DIR" 2>/dev/null | awk 'NR==2 {gsub("G",""); print $4}' || \
                   df -BG / | awk 'NR==2 {gsub("G",""); print $4}')

    print_info "System resources: ${cpu_cores} CPU cores, ${total_ram_gb} GB RAM, ${free_disk_gb} GB free disk"

    # Calculate max runners
    local max_by_cpu=$((cpu_cores / 2))
    local max_by_ram=$((total_ram_gb / 4))
    local max_by_disk=$((free_disk_gb / 10))
    [[ $max_by_cpu -lt 1 ]] && max_by_cpu=1
    [[ $max_by_ram -lt 1 ]] && max_by_ram=1
    [[ $max_by_disk -lt 1 ]] && max_by_disk=1

    local recommended_max=$max_by_cpu
    [[ $max_by_ram -lt $recommended_max ]] && recommended_max=$max_by_ram
    [[ $max_by_disk -lt $recommended_max ]] && recommended_max=$max_by_disk

    local effective_max
    if [[ -n "$MAX_RUNNERS" ]]; then
        effective_max=$MAX_RUNNERS
        print_info "Using user-configured MAX_RUNNERS=$MAX_RUNNERS (recommended: $recommended_max)"
    else
        effective_max=$recommended_max
        print_info "Auto-calculated max runners: $effective_max"
    fi

    # Count existing runners
    local current_count=0
    if [[ -d "$RUNNER_INSTALL_DIR" ]]; then
        current_count=$(find "$RUNNER_INSTALL_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
    fi

    local after_count=$((current_count + COUNT))
    local slots_available=$((effective_max - current_count))

    print_info "Current runners: $current_count | Requesting: $COUNT | After: $after_count / $effective_max"

    if [[ $slots_available -lt 0 ]]; then
        slots_available=0
    fi

    if [[ $after_count -le $effective_max ]]; then
        print_ok "Capacity available. $slots_available slot(s) free, requesting $COUNT."
    elif [[ $after_count -gt $effective_max ]]; then
        print_warn "Requesting $COUNT runners but only $slots_available slot(s) available (max=$effective_max)"
        if [[ "$FORCE" == true ]]; then
            print_warn "Proceeding anyway (--force flag set)"
        else
            read -rp "VM will be over capacity after adding. Continue? (y/N): " confirm
            if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                print_fail "Aborted. Use --force to skip this check."
                exit 1
            fi
        fi
    fi
}

# =============================================================================
# Obtain registration token (same 3-tier fallback as setup-runner.sh)
# =============================================================================
get_registration_token() {
    print_step "Obtaining runner registration token"

    if [[ -n "$TOKEN" ]]; then
        print_ok "Using provided registration token"
        REG_TOKEN="$TOKEN"
        return
    fi

    local api_path
    if [[ "$SCOPE" == "org" ]]; then
        api_path="orgs/$ORG/actions/runners/registration-token"
    else
        api_path="repos/$REPO/actions/runners/registration-token"
    fi

    # Tier 1: GitHub CLI
    if command -v gh &>/dev/null; then
        print_info "Attempting token fetch via GitHub CLI (gh)..."
        if gh auth status &>/dev/null; then
            local gh_response
            gh_response=$(gh api --method POST "$api_path" 2>/dev/null || true)
            if [[ -n "$gh_response" ]]; then
                REG_TOKEN=$(echo "$gh_response" | jq -r '.token // empty')
                if [[ -n "$REG_TOKEN" ]]; then
                    print_ok "Registration token obtained via GitHub CLI"
                    return
                fi
            fi
            print_warn "GitHub CLI token fetch failed, trying next method..."
        else
            print_warn "GitHub CLI not authenticated, trying next method..."
        fi
    fi

    # Tier 2: GITHUB_PAT
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
                return
            fi
        fi
        print_warn "GITHUB_PAT token fetch failed, trying next method..."
    fi

    # Tier 3: Manual entry
    print_info "Please provide a registration token manually."
    echo ""
    if [[ "$SCOPE" == "org" ]]; then
        echo "  Get token from: https://github.com/organizations/$ORG/settings/actions/runners/new"
    else
        echo "  Get token from: https://github.com/$REPO/settings/actions/runners/new"
    fi
    echo ""
    read -rp "  Paste registration token: " REG_TOKEN

    if [[ -z "$REG_TOKEN" ]]; then
        print_fail "No registration token provided."
        exit 1
    fi
    print_ok "Registration token received (manual entry)"
}

# =============================================================================
# Generate a unique runner name for each instance
# =============================================================================
generate_runner_name() {
    local index=$1

    if [[ -n "$INSTANCE_ID" ]]; then
        # User-specified instance ID (only valid for count=1)
        echo "$(hostname)-${INSTANCE_ID}"
    else
        # Auto-generate: hostname-runner-<index>
        # Find the next available index by checking existing directories
        local base_name
        base_name="$(hostname)-runner"
        local candidate_index=$index
        while [[ -d "$RUNNER_INSTALL_DIR/${base_name}-${candidate_index}" ]]; do
            candidate_index=$((candidate_index + 1))
        done
        echo "${base_name}-${candidate_index}"
    fi
}

# =============================================================================
# Add a single runner instance
# Returns 0 on success, 1 on failure
# =============================================================================
add_single_runner() {
    local runner_name=$1
    local runner_dir="$RUNNER_INSTALL_DIR/$runner_name"

    print_step "Adding runner: $runner_name"

    # Check if directory already exists
    if [[ -d "$runner_dir" ]]; then
        print_fail "Runner directory already exists: $runner_dir"
        return 1
    fi

    # Determine architecture
    local arch
    arch=$(uname -m)
    case $arch in
        x86_64)  local runner_arch="x64" ;;
        aarch64) local runner_arch="arm64" ;;
        armv7l)  local runner_arch="arm" ;;
        *)
            print_fail "Unsupported architecture: $arch"
            return 1
            ;;
    esac

    # Get latest version
    local latest_version
    latest_version=$(curl -s "https://api.github.com/repos/actions/runner/releases/latest" | jq -r '.tag_name' | sed 's/^v//')
    if [[ -z "$latest_version" || "$latest_version" == "null" ]]; then
        print_fail "Could not determine latest runner version"
        return 1
    fi

    # Create directory
    mkdir -p "$runner_dir"

    # Download runner package
    local download_url="https://github.com/actions/runner/releases/download/v${latest_version}/actions-runner-linux-${runner_arch}-${latest_version}.tar.gz"
    local tar_file="/tmp/actions-runner-${runner_name}.tar.gz"

    print_info "Downloading runner v${latest_version}..."
    if ! curl -sL "$download_url" -o "$tar_file"; then
        print_fail "Download failed for $runner_name"
        rm -rf "$runner_dir"
        return 1
    fi

    # Extract
    if ! tar -xzf "$tar_file" -C "$runner_dir"; then
        print_fail "Extraction failed for $runner_name"
        rm -rf "$runner_dir"
        rm -f "$tar_file"
        return 1
    fi
    rm -f "$tar_file"
    print_ok "Downloaded and extracted runner"

    # Build GitHub URL
    local url
    if [[ "$SCOPE" == "org" ]]; then
        url="https://github.com/$ORG"
    else
        url="https://github.com/$REPO"
    fi

    # Configure runner
    local config_cmd=(
        "$runner_dir/config.sh"
        --url "$url"
        --token "$REG_TOKEN"
        --name "$runner_name"
        --labels "$LABELS"
        --work "$RUNNER_WORK_DIR"
        --unattended
        --replace
    )

    if [[ -n "$RUNNER_GROUP" && "$SCOPE" == "org" ]]; then
        config_cmd+=(--runnergroup "$RUNNER_GROUP")
    fi

    print_info "Configuring runner..."
    if ! "${config_cmd[@]}"; then
        print_fail "Configuration failed for $runner_name"
        rm -rf "$runner_dir"
        return 1
    fi
    print_ok "Runner configured"

    # Set up service user and ownership
    local service_user="github-runner"
    if ! id "$service_user" &>/dev/null; then
        useradd -r -m -s /usr/sbin/nologin "$service_user" 2>/dev/null || true
    fi
    chown -R "$service_user":"$service_user" "$runner_dir"

    # Install and start systemd service
    print_info "Installing systemd service..."
    cd "$runner_dir"
    if ! ./svc.sh install "$service_user"; then
        print_fail "Service install failed for $runner_name"
        cd - >/dev/null
        return 1
    fi

    if ! ./svc.sh start; then
        print_fail "Service start failed for $runner_name"
        cd - >/dev/null
        return 1
    fi
    cd - >/dev/null

    # Validate
    sleep 2
    if [[ -f "$runner_dir/.runner" && -f "$runner_dir/.credentials" ]]; then
        print_ok "Runner $runner_name is installed and running"
        return 0
    else
        print_fail "Runner $runner_name registration files missing"
        return 1
    fi
}

# =============================================================================
# Print summary
# =============================================================================
print_summary() {
    echo ""
    echo "============================================================================="
    echo "  ADD RUNNER SUMMARY"
    echo "============================================================================="
    echo "  Requested : $COUNT runner(s)"
    echo "  Created   : ${#CREATED_RUNNERS[@]}"
    echo "  Failed    : ${#FAILED_RUNNERS[@]}"
    echo "============================================================================="

    if [[ ${#CREATED_RUNNERS[@]} -gt 0 ]]; then
        echo ""
        echo "  Successfully created:"
        for r in "${CREATED_RUNNERS[@]}"; do
            echo -e "    ${GREEN}[OK]${NC} $r"
        done
    fi

    if [[ ${#FAILED_RUNNERS[@]} -gt 0 ]]; then
        echo ""
        echo "  Failed:"
        for r in "${FAILED_RUNNERS[@]}"; do
            echo -e "    ${RED}[FAIL]${NC} $r"
        done
    fi

    echo ""
    echo "  Runners should appear at:"
    if [[ "$SCOPE" == "org" ]]; then
        echo "  https://github.com/organizations/$ORG/settings/actions/runners"
    else
        echo "  https://github.com/$REPO/settings/actions/runners"
    fi
    echo "============================================================================="

    # Exit with error if any runners failed
    if [[ ${#FAILED_RUNNERS[@]} -gt 0 ]]; then
        exit 1
    fi
}

# =============================================================================
# Main execution
# =============================================================================
main() {
    echo "============================================================================="
    echo "  GitHub Self-Hosted Runner - Add Instances (Linux)"
    echo "============================================================================="

    validate_args
    check_vm_capacity
    get_registration_token

    # Find the starting index for auto-naming
    local existing_count=0
    if [[ -d "$RUNNER_INSTALL_DIR" ]]; then
        existing_count=$(find "$RUNNER_INSTALL_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
    fi

    # Add each runner instance
    for ((i = 1; i <= COUNT; i++)); do
        local runner_name
        runner_name=$(generate_runner_name $((existing_count + i)))

        if add_single_runner "$runner_name"; then
            CREATED_RUNNERS+=("$runner_name")
        else
            FAILED_RUNNERS+=("$runner_name")
        fi
    done

    print_summary
}

main
