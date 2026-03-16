#!/usr/bin/env bash
# =============================================================================
# debug-runner.sh - Collect Diagnostic Information for GitHub Runners (Linux)
# =============================================================================
# Gathers detailed diagnostic data about runner instances, system state,
# network connectivity, and service logs. Outputs a diagnostics report that
# can be used for troubleshooting or shared with support.
#
# Usage:
#   sudo bash debug-runner.sh
#   sudo bash debug-runner.sh --name my-runner
#   sudo bash debug-runner.sh --output /tmp/runner-diagnostics.txt
#
# Arguments:
#   --name    Optional. Debug a specific runner (default: all runners)
#   --output  Optional. Save report to a file (default: stdout only)
#   --config  Optional. Path to runner-config.env file
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

# Append to report buffer
REPORT=""
report() { REPORT+="$1"$'\n'; }
report_section() {
    report ""
    report "============================================================================="
    report "  $1"
    report "============================================================================="
}

# =============================================================================
# Defaults
# =============================================================================
RUNNER_NAME=""
OUTPUT_FILE=""
CONFIG_FILE=""
RUNNER_INSTALL_DIR="/opt/github-runners"

# =============================================================================
# Parse arguments
# =============================================================================
while [[ $# -gt 0 ]]; do
    case $1 in
        --name)   RUNNER_NAME="$2"; shift 2 ;;
        --output) OUTPUT_FILE="$2"; shift 2 ;;
        --config) CONFIG_FILE="$2"; shift 2 ;;
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

# =============================================================================
# Collect: System information
# =============================================================================
collect_system_info() {
    print_step "Collecting system information"
    report_section "SYSTEM INFORMATION"

    report "  Date       : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    report "  Hostname   : $(hostname)"
    report "  Kernel     : $(uname -r)"
    report "  Arch       : $(uname -m)"

    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        report "  OS         : ${PRETTY_NAME:-unknown}"
        report "  OS ID      : ${ID:-unknown}"
        report "  OS Version : ${VERSION_ID:-unknown}"
    fi

    report "  Uptime     : $(uptime -p 2>/dev/null || uptime)"

    print_ok "System information collected"
}

# =============================================================================
# Collect: Resource usage
# =============================================================================
collect_resources() {
    print_step "Collecting resource usage"
    report_section "RESOURCE USAGE"

    # CPU
    local cpu_cores
    cpu_cores=$(nproc 2>/dev/null || echo "unknown")
    local load_avg
    load_avg=$(cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}' || echo "unknown")
    report "  CPU Cores  : $cpu_cores"
    report "  Load Avg   : $load_avg"

    # Memory
    report ""
    report "  Memory:"
    free -h 2>/dev/null | sed 's/^/    /' >> /dev/null || true
    local mem_info
    mem_info=$(free -h 2>/dev/null || echo "  (free command not available)")
    report "$mem_info" | sed 's/^/    /'

    # Disk
    report ""
    report "  Disk (runner install dir: $RUNNER_INSTALL_DIR):"
    local disk_info
    disk_info=$(df -h "$RUNNER_INSTALL_DIR" 2>/dev/null || df -h / 2>/dev/null || echo "  (df not available)")
    while IFS= read -r line; do
        report "    $line"
    done <<< "$disk_info"

    print_ok "Resource usage collected"
}

# =============================================================================
# Collect: Network connectivity
# =============================================================================
collect_network() {
    print_step "Checking network connectivity"
    report_section "NETWORK CONNECTIVITY"

    # DNS resolution
    local dns_result="FAIL"
    if host github.com &>/dev/null 2>&1 || nslookup github.com &>/dev/null 2>&1; then
        dns_result="OK"
    fi
    report "  DNS (github.com)       : $dns_result"

    # HTTPS to github.com
    local https_result="FAIL"
    local https_code
    https_code=$(curl -sf --max-time 10 -o /dev/null -w "%{http_code}" "https://github.com" 2>/dev/null || echo "000")
    if [[ "$https_code" == "200" || "$https_code" == "301" ]]; then
        https_result="OK (HTTP $https_code)"
    else
        https_result="FAIL (HTTP $https_code)"
    fi
    report "  HTTPS (github.com)     : $https_result"

    # GitHub API
    local api_result="FAIL"
    local api_code
    api_code=$(curl -sf --max-time 10 -o /dev/null -w "%{http_code}" "https://api.github.com" 2>/dev/null || echo "000")
    if [[ "$api_code" == "200" ]]; then
        api_result="OK (HTTP $api_code)"
    else
        api_result="FAIL (HTTP $api_code)"
    fi
    report "  API (api.github.com)   : $api_result"

    # Actions service endpoints
    local actions_result="FAIL"
    local actions_code
    actions_code=$(curl -sf --max-time 10 -o /dev/null -w "%{http_code}" "https://pipelines.actions.githubusercontent.com" 2>/dev/null || echo "000")
    if [[ "$actions_code" != "000" ]]; then
        actions_result="OK (HTTP $actions_code)"
    fi
    report "  Actions pipelines      : $actions_result"

    if [[ "$dns_result" == "FAIL" ]]; then
        print_fail "DNS resolution failed for github.com"
    elif [[ "$https_code" == "000" ]]; then
        print_fail "Cannot reach github.com over HTTPS"
    else
        print_ok "Network connectivity checks completed"
    fi
}

# =============================================================================
# Collect: GitHub CLI status
# =============================================================================
collect_gh_status() {
    print_step "Checking GitHub CLI status"
    report_section "GITHUB CLI STATUS"

    if command -v gh &>/dev/null; then
        report "  gh installed: YES ($(gh --version 2>&1 | head -1))"
        local auth_status
        auth_status=$(gh auth status 2>&1 || true)
        report ""
        report "  Auth status:"
        while IFS= read -r line; do
            report "    $line"
        done <<< "$auth_status"
        print_ok "GitHub CLI is installed"
    else
        report "  gh installed: NO"
        report "  Install gh CLI: https://cli.github.com/"
        print_warn "GitHub CLI is not installed"
    fi
}

# =============================================================================
# Collect: Runner-specific diagnostics
# =============================================================================
collect_runner_diagnostics() {
    local runner_dir=$1
    local runner_name
    runner_name=$(basename "$runner_dir")

    print_step "Diagnosing runner: $runner_name"
    report_section "RUNNER: $runner_name"

    report "  Directory  : $runner_dir"

    # Check if directory exists and has expected files
    if [[ ! -d "$runner_dir" ]]; then
        report "  Status     : DIRECTORY NOT FOUND"
        print_fail "Runner directory not found: $runner_dir"
        return
    fi

    # Registration status
    if [[ -f "$runner_dir/.runner" ]]; then
        report "  Registered : YES"
        local runner_info
        runner_info=$(cat "$runner_dir/.runner" 2>/dev/null || echo "{}")
        local agent_name
        agent_name=$(echo "$runner_info" | jq -r '.agentName // "unknown"' 2>/dev/null || echo "unknown")
        local pool_id
        pool_id=$(echo "$runner_info" | jq -r '.poolId // "unknown"' 2>/dev/null || echo "unknown")
        report "  Agent Name : $agent_name"
        report "  Pool ID    : $pool_id"
    else
        report "  Registered : NO (.runner file missing)"
    fi

    # Credentials
    if [[ -f "$runner_dir/.credentials" ]]; then
        report "  Credentials: YES"
    else
        report "  Credentials: MISSING"
    fi

    # Service status
    report ""
    report "  Service Status:"
    if [[ -f "$runner_dir/svc.sh" ]]; then
        local svc_output
        cd "$runner_dir"
        svc_output=$(./svc.sh status 2>&1 || true)
        cd - >/dev/null
        while IFS= read -r line; do
            report "    $line"
        done <<< "$svc_output"
    else
        report "    svc.sh not found"
    fi

    # Recent log entries
    local log_dir="$runner_dir/_diag"
    if [[ -d "$log_dir" ]]; then
        report ""
        report "  Recent Logs:"

        # Find the latest Runner log
        local latest_runner_log
        latest_runner_log=$(ls -t "$log_dir"/Runner_*.log 2>/dev/null | head -1)
        if [[ -n "$latest_runner_log" ]]; then
            report "    Latest runner log: $(basename "$latest_runner_log")"

            # Show last 20 lines
            report "    --- Last 20 lines ---"
            tail -20 "$latest_runner_log" 2>/dev/null | while IFS= read -r line; do
                report "    $line"
            done

            # Count errors
            local error_count
            error_count=$(grep -ci "error\|exception\|fail" "$latest_runner_log" 2>/dev/null || echo 0)
            report "    --- Error count: $error_count ---"

            if [[ "$error_count" -gt 0 ]]; then
                report ""
                report "    Recent errors:"
                grep -i "error\|exception\|fail" "$latest_runner_log" 2>/dev/null | tail -10 | while IFS= read -r line; do
                    report "      $line"
                done
            fi
        else
            report "    No Runner log files found"
        fi

        # Find the latest Worker log
        local latest_worker_log
        latest_worker_log=$(ls -t "$log_dir"/Worker_*.log 2>/dev/null | head -1)
        if [[ -n "$latest_worker_log" ]]; then
            report ""
            report "    Latest worker log: $(basename "$latest_worker_log")"
            report "    --- Last 10 lines ---"
            tail -10 "$latest_worker_log" 2>/dev/null | while IFS= read -r line; do
                report "    $line"
            done
        fi
    else
        report "  Logs: _diag directory not found"
    fi

    print_ok "Diagnostics collected for $runner_name"
}

# =============================================================================
# Collect: Installed tool versions
# =============================================================================
collect_tool_versions() {
    print_step "Collecting installed tool versions"
    report_section "INSTALLED TOOLS"

    local tools=(
        "git:git --version"
        "curl:curl --version"
        "jq:jq --version"
        "python3:python3 --version"
        "pip3:pip3 --version"
        "docker:docker --version"
        "terraform:terraform version"
        "node:node --version"
        "npm:npm --version"
        "aws:aws --version"
        "az:az version"
        "go:go version"
        "java:java -version"
        "gh:gh --version"
    )

    for entry in "${tools[@]}"; do
        local name="${entry%%:*}"
        local cmd="${entry#*:}"

        if command -v "$name" &>/dev/null; then
            local version
            version=$(eval "$cmd" 2>&1 | head -1 || echo "error getting version")
            report "  $name: $version"
        else
            report "  $name: NOT INSTALLED"
        fi
    done

    print_ok "Tool versions collected"
}

# =============================================================================
# Save report to file if requested
# =============================================================================
save_report() {
    if [[ -n "$OUTPUT_FILE" ]]; then
        # Strip ANSI color codes for file output
        echo "$REPORT" | sed 's/\x1b\[[0-9;]*m//g' > "$OUTPUT_FILE"
        print_ok "Report saved to: $OUTPUT_FILE"
    fi

    # Always print to stdout
    echo ""
    echo "$REPORT"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo "============================================================================="
    echo "  GitHub Runner - Diagnostics Report (Linux)"
    echo "============================================================================="

    report "============================================================================="
    report "  GITHUB RUNNER DIAGNOSTICS REPORT"
    report "  Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    report "============================================================================="

    collect_system_info
    collect_resources
    collect_network
    collect_gh_status
    collect_tool_versions

    # Collect runner-specific diagnostics
    if [[ -n "$RUNNER_NAME" ]]; then
        collect_runner_diagnostics "$RUNNER_INSTALL_DIR/$RUNNER_NAME"
    else
        if [[ -d "$RUNNER_INSTALL_DIR" ]]; then
            local found=false
            for runner_dir in "$RUNNER_INSTALL_DIR"/*/; do
                if [[ -d "$runner_dir" ]]; then
                    found=true
                    collect_runner_diagnostics "$runner_dir"
                fi
            done
            if [[ "$found" == false ]]; then
                report_section "RUNNERS"
                report "  No runner directories found in $RUNNER_INSTALL_DIR"
                print_warn "No runners found"
            fi
        else
            report_section "RUNNERS"
            report "  Runner install directory does not exist: $RUNNER_INSTALL_DIR"
            print_warn "Runner install directory missing"
        fi
    fi

    report ""
    report "============================================================================="
    report "  END OF DIAGNOSTICS REPORT"
    report "============================================================================="

    save_report

    print_ok "Diagnostics collection complete"
}

main
