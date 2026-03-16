#!/usr/bin/env bash
# =============================================================================
# validate-runner.sh - Health Check and Validation for GitHub Runners (Linux)
# =============================================================================
# Validates that installed GitHub Actions runners are healthy and operational.
# Checks service status, registration files, tool versions, system resources,
# and VM capacity.
#
# Usage:
#   sudo bash validate-runner.sh
#   sudo bash validate-runner.sh --name my-runner
#   sudo bash validate-runner.sh --verbose
#
# Arguments:
#   --name     Optional. Validate a specific runner only (default: all runners)
#   --verbose  Optional. Show detailed output for each check
#   --config   Optional. Path to runner-config.env file
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
RUNNER_NAME=""
VERBOSE=false
CONFIG_FILE=""
RUNNER_INSTALL_DIR="/opt/github-runners"
MAX_RUNNERS=""

# Counters
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

# =============================================================================
# Parse arguments
# =============================================================================
while [[ $# -gt 0 ]]; do
    case $1 in
        --name)    RUNNER_NAME="$2"; shift 2 ;;
        --verbose) VERBOSE=true; shift ;;
        --config)  CONFIG_FILE="$2"; shift 2 ;;
        -h|--help)
            head -18 "$0" | grep "^#" | sed 's/^# \?//'
            exit 0
            ;;
        *) print_fail "Unknown argument: $1"; exit 1 ;;
    esac
done

# =============================================================================
# Load config
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

RUNNER_INSTALL_DIR="${RUNNER_INSTALL_DIR:-/opt/github-runners}"
MAX_RUNNERS="${MAX_RUNNERS:-}"

# =============================================================================
# Check: System resources
# =============================================================================
check_system_resources() {
    print_step "System Resources"

    # CPU
    local cpu_cores
    cpu_cores=$(nproc 2>/dev/null || echo "unknown")
    print_info "CPU cores: $cpu_cores"

    # RAM
    local total_ram free_ram
    total_ram=$(awk '/MemTotal/ {printf "%.1f", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo "unknown")
    free_ram=$(awk '/MemAvailable/ {printf "%.1f", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo "unknown")
    print_info "RAM: ${free_ram} GB free / ${total_ram} GB total"

    # Check if RAM is critically low (less than 512MB free)
    local free_ram_mb
    free_ram_mb=$(awk '/MemAvailable/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    if [[ "$free_ram_mb" -lt 512 ]]; then
        print_warn "Available RAM is critically low (${free_ram_mb} MB)"
        WARN_COUNT=$((WARN_COUNT + 1))
    else
        print_ok "RAM is adequate"
        PASS_COUNT=$((PASS_COUNT + 1))
    fi

    # Disk
    local disk_free disk_total disk_usage_pct
    disk_free=$(df -BG "$RUNNER_INSTALL_DIR" 2>/dev/null | awk 'NR==2 {gsub("G",""); print $4}' || echo "unknown")
    disk_total=$(df -BG "$RUNNER_INSTALL_DIR" 2>/dev/null | awk 'NR==2 {gsub("G",""); print $2}' || echo "unknown")
    disk_usage_pct=$(df "$RUNNER_INSTALL_DIR" 2>/dev/null | awk 'NR==2 {print $5}' || echo "unknown")
    print_info "Disk: ${disk_free} GB free / ${disk_total} GB total (${disk_usage_pct} used)"

    if [[ "$disk_free" != "unknown" && "$disk_free" -lt 5 ]]; then
        print_warn "Disk space is critically low (${disk_free} GB free)"
        WARN_COUNT=$((WARN_COUNT + 1))
    else
        print_ok "Disk space is adequate"
        PASS_COUNT=$((PASS_COUNT + 1))
    fi
}

# =============================================================================
# Check: VM capacity (current vs max runners)
# =============================================================================
check_vm_capacity() {
    print_step "VM Capacity"

    local cpu_cores
    cpu_cores=$(nproc 2>/dev/null || echo 2)
    local total_ram_gb
    total_ram_gb=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 4)
    local free_disk_gb
    free_disk_gb=$(df -BG "$RUNNER_INSTALL_DIR" 2>/dev/null | awk 'NR==2 {gsub("G",""); print $4}' || echo 50)

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
    else
        effective_max=$recommended_max
    fi

    local current_count=0
    if [[ -d "$RUNNER_INSTALL_DIR" ]]; then
        current_count=$(find "$RUNNER_INSTALL_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
    fi

    print_info "Runners: $current_count / $effective_max (recommended max: $recommended_max)"

    if [[ $current_count -le $effective_max ]]; then
        print_ok "VM capacity: $current_count / $effective_max"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        print_warn "VM over capacity: $current_count / $effective_max"
        WARN_COUNT=$((WARN_COUNT + 1))
    fi
}

# =============================================================================
# Check: Network connectivity to GitHub
# =============================================================================
check_network() {
    print_step "Network Connectivity"

    # Test DNS resolution
    if host github.com &>/dev/null || nslookup github.com &>/dev/null 2>&1; then
        print_ok "DNS resolution for github.com"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        print_fail "Cannot resolve github.com"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi

    # Test HTTPS connectivity
    if curl -sf --max-time 10 "https://github.com" -o /dev/null 2>/dev/null; then
        print_ok "HTTPS connectivity to github.com"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        print_fail "Cannot reach https://github.com"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi

    # Test GitHub API access
    if curl -sf --max-time 10 "https://api.github.com" -o /dev/null 2>/dev/null; then
        print_ok "GitHub API is accessible"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        print_fail "Cannot reach GitHub API"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# =============================================================================
# Check: Installed tools
# =============================================================================
check_tools() {
    print_step "Installed Tools"

    local tools=(
        "git:git --version"
        "curl:curl --version"
        "jq:jq --version"
        "python3:python3 --version"
        "docker:docker --version"
        "terraform:terraform --version"
    )

    for entry in "${tools[@]}"; do
        local name="${entry%%:*}"
        local cmd="${entry#*:}"

        if command -v "$name" &>/dev/null; then
            if [[ "$VERBOSE" == true ]]; then
                local version
                version=$(eval "$cmd" 2>&1 | head -1)
                print_ok "$name: $version"
            else
                print_ok "$name is installed"
            fi
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            print_warn "$name is not installed"
            WARN_COUNT=$((WARN_COUNT + 1))
        fi
    done

    # Optional tools - just info, not warnings
    local optional_tools=("node" "npm" "aws" "az" "go" "java")
    for tool in "${optional_tools[@]}"; do
        if command -v "$tool" &>/dev/null; then
            if [[ "$VERBOSE" == true ]]; then
                local version
                version=$("$tool" --version 2>&1 | head -1 || echo "unknown")
                print_info "$tool (optional): $version"
            else
                print_info "$tool (optional) is installed"
            fi
        fi
    done
}

# =============================================================================
# Check: Individual runner health
# =============================================================================
check_runner() {
    local runner_dir=$1
    local runner_name
    runner_name=$(basename "$runner_dir")

    print_step "Runner: $runner_name"

    # Check directory structure
    if [[ -f "$runner_dir/config.sh" && -f "$runner_dir/run.sh" ]]; then
        print_ok "Runner binaries present"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        print_fail "Runner binaries missing in $runner_dir"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return
    fi

    # Check registration files
    if [[ -f "$runner_dir/.runner" ]]; then
        print_ok "Runner is registered (.runner file exists)"
        PASS_COUNT=$((PASS_COUNT + 1))

        if [[ "$VERBOSE" == true ]]; then
            local runner_info
            runner_info=$(cat "$runner_dir/.runner" 2>/dev/null || echo "{}")
            local reg_name
            reg_name=$(echo "$runner_info" | jq -r '.agentName // "unknown"' 2>/dev/null || echo "unknown")
            print_info "Registered name: $reg_name"
        fi
    else
        print_fail "Runner is NOT registered (.runner file missing)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi

    # Check credentials
    if [[ -f "$runner_dir/.credentials" ]]; then
        print_ok "Credentials file exists"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        print_fail "Credentials file missing"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi

    # Check systemd service status
    if [[ -f "$runner_dir/svc.sh" ]]; then
        cd "$runner_dir"
        local svc_status
        svc_status=$(./svc.sh status 2>&1 || true)

        if echo "$svc_status" | grep -qi "active\|running"; then
            print_ok "Service is running"
            PASS_COUNT=$((PASS_COUNT + 1))
        elif echo "$svc_status" | grep -qi "inactive\|dead"; then
            print_fail "Service is NOT running (inactive/dead)"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        else
            print_warn "Service status unclear"
            WARN_COUNT=$((WARN_COUNT + 1))
            if [[ "$VERBOSE" == true ]]; then
                echo "$svc_status" | head -5
            fi
        fi
        cd - >/dev/null
    else
        print_warn "svc.sh not found - cannot check service status"
        WARN_COUNT=$((WARN_COUNT + 1))
    fi

    # Check runner logs for recent errors
    local log_dir="$runner_dir/_diag"
    if [[ -d "$log_dir" ]]; then
        local latest_log
        latest_log=$(ls -t "$log_dir"/Runner_*.log 2>/dev/null | head -1)
        if [[ -n "$latest_log" ]]; then
            local error_count
            error_count=$(grep -ci "error\|exception\|fail" "$latest_log" 2>/dev/null || echo 0)
            if [[ "$error_count" -gt 0 ]]; then
                print_warn "Found $error_count error(s) in latest log: $(basename "$latest_log")"
                WARN_COUNT=$((WARN_COUNT + 1))
                if [[ "$VERBOSE" == true ]]; then
                    echo "  Last 3 errors:"
                    grep -i "error\|exception\|fail" "$latest_log" | tail -3 | sed 's/^/    /'
                fi
            else
                print_ok "No errors in latest runner log"
                PASS_COUNT=$((PASS_COUNT + 1))
            fi
        fi
    fi
}

# =============================================================================
# Print summary
# =============================================================================
print_summary() {
    echo ""
    echo "============================================================================="
    echo "  VALIDATION SUMMARY"
    echo "============================================================================="
    echo ""
    echo -e "  ${GREEN}Passed${NC}  : $PASS_COUNT"
    echo -e "  ${YELLOW}Warnings${NC}: $WARN_COUNT"
    echo -e "  ${RED}Failed${NC}  : $FAIL_COUNT"
    echo ""

    if [[ $FAIL_COUNT -gt 0 ]]; then
        echo -e "  ${RED}Some checks failed. Run debug-runner.sh for detailed diagnostics.${NC}"
        echo "============================================================================="
        exit 1
    elif [[ $WARN_COUNT -gt 0 ]]; then
        echo -e "  ${YELLOW}All critical checks passed, but there are warnings to review.${NC}"
        echo "============================================================================="
        exit 0
    else
        echo -e "  ${GREEN}All checks passed! Runners are healthy.${NC}"
        echo "============================================================================="
        exit 0
    fi
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo "============================================================================="
    echo "  GitHub Runner - Validation & Health Check (Linux)"
    echo "============================================================================="

    check_system_resources
    check_vm_capacity
    check_network
    check_tools

    # Check individual runners
    if [[ -n "$RUNNER_NAME" ]]; then
        # Validate a specific runner
        local runner_dir="$RUNNER_INSTALL_DIR/$RUNNER_NAME"
        if [[ -d "$runner_dir" ]]; then
            check_runner "$runner_dir"
        else
            print_fail "Runner not found: $runner_dir"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    else
        # Validate all runners
        if [[ -d "$RUNNER_INSTALL_DIR" ]]; then
            local found=false
            for runner_dir in "$RUNNER_INSTALL_DIR"/*/; do
                if [[ -d "$runner_dir" ]]; then
                    found=true
                    check_runner "$runner_dir"
                fi
            done
            if [[ "$found" == false ]]; then
                print_warn "No runner directories found in $RUNNER_INSTALL_DIR"
                WARN_COUNT=$((WARN_COUNT + 1))
            fi
        else
            print_warn "Runner install directory does not exist: $RUNNER_INSTALL_DIR"
            WARN_COUNT=$((WARN_COUNT + 1))
        fi
    fi

    print_summary
}

main
