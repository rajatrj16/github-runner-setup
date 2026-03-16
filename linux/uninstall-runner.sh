#!/usr/bin/env bash
# =============================================================================
# uninstall-runner.sh - Remove GitHub Self-Hosted Runner(s) (Linux)
# =============================================================================
# Stops the systemd service, deregisters the runner from GitHub, and removes
# all runner files. Supports removing a single runner by name or all runners.
#
# Prerequisites:
#   - sudo/root access
#   - GitHub CLI (gh) authenticated OR GITHUB_PAT env var OR manual token
#
# Usage:
#   sudo bash uninstall-runner.sh --name my-runner --scope org --org my-org
#   sudo bash uninstall-runner.sh --name my-runner --scope repo --repo owner/repo
#   sudo bash uninstall-runner.sh --all --scope org --org my-org
#   sudo bash uninstall-runner.sh --name my-runner --scope org --org my-org --token RXXXXXXX
#
# Arguments:
#   --name    Remove a specific runner by name
#   --all     Remove ALL runners from this VM
#   --scope   Required. "org" or "repo"
#   --org     Required if scope=org. GitHub organization name
#   --repo    Required if scope=repo. GitHub repo in "owner/repo" format
#   --token   Optional. Provide a removal token directly (skip auto-fetch)
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

# =============================================================================
# Defaults
# =============================================================================
RUNNER_NAME=""
REMOVE_ALL=false
SCOPE=""
ORG=""
REPO=""
TOKEN=""
CONFIG_FILE=""
RUNNER_INSTALL_DIR="/opt/github-runners"
REMOVAL_TOKEN=""

# Track results
REMOVED=()
FAILED=()

# =============================================================================
# Parse arguments
# =============================================================================
while [[ $# -gt 0 ]]; do
    case $1 in
        --name)   RUNNER_NAME="$2"; shift 2 ;;
        --all)    REMOVE_ALL=true; shift ;;
        --scope)  SCOPE="$2"; shift 2 ;;
        --org)    ORG="$2"; shift 2 ;;
        --repo)   REPO="$2"; shift 2 ;;
        --token)  TOKEN="$2"; shift 2 ;;
        --config) CONFIG_FILE="$2"; shift 2 ;;
        -h|--help)
            head -28 "$0" | grep "^#" | sed 's/^# \?//'
            exit 0
            ;;
        *) print_fail "Unknown argument: $1"; exit 1 ;;
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

SCOPE="${SCOPE:-${RUNNER_SCOPE:-}}"
ORG="${ORG:-${GITHUB_ORG:-}}"
REPO="${REPO:-${GITHUB_REPO:-}}"
RUNNER_INSTALL_DIR="${RUNNER_INSTALL_DIR:-/opt/github-runners}"

# =============================================================================
# Validate arguments
# =============================================================================
validate_args() {
    print_step "Validating arguments"

    if [[ -z "$RUNNER_NAME" && "$REMOVE_ALL" == false ]]; then
        print_fail "Either --name <runner-name> or --all is required"
        exit 1
    fi

    if [[ -z "$SCOPE" ]]; then
        print_fail "--scope is required (org or repo)"
        exit 1
    fi

    if [[ "$SCOPE" == "org" && -z "$ORG" ]]; then
        print_fail "--org is required when scope is 'org'"
        exit 1
    fi

    if [[ "$SCOPE" == "repo" && -z "$REPO" ]]; then
        print_fail "--repo is required when scope is 'repo'"
        exit 1
    fi

    print_ok "Arguments validated"
}

# =============================================================================
# Obtain removal token using 3-tier fallback (same as registration token)
# =============================================================================
get_removal_token() {
    print_step "Obtaining runner removal token"

    # If user provided a token directly, use it
    if [[ -n "$TOKEN" ]]; then
        print_ok "Using provided removal token"
        REMOVAL_TOKEN="$TOKEN"
        return
    fi

    local api_path
    if [[ "$SCOPE" == "org" ]]; then
        api_path="orgs/$ORG/actions/runners/remove-token"
    else
        api_path="repos/$REPO/actions/runners/remove-token"
    fi

    # Tier 1: GitHub CLI
    if command -v gh &>/dev/null; then
        print_info "Attempting token fetch via GitHub CLI (gh)..."
        if gh auth status &>/dev/null; then
            local gh_response
            gh_response=$(gh api --method POST "$api_path" 2>/dev/null || true)
            if [[ -n "$gh_response" ]]; then
                REMOVAL_TOKEN=$(echo "$gh_response" | jq -r '.token // empty')
                if [[ -n "$REMOVAL_TOKEN" ]]; then
                    print_ok "Removal token obtained via GitHub CLI"
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
            REMOVAL_TOKEN=$(echo "$response" | jq -r '.token // empty')
            if [[ -n "$REMOVAL_TOKEN" ]]; then
                print_ok "Removal token obtained via GITHUB_PAT"
                return
            fi
        fi
        print_warn "GITHUB_PAT token fetch failed, trying next method..."
    fi

    # Tier 3: Manual entry
    print_info "Please provide a removal token manually."
    echo ""
    if [[ "$SCOPE" == "org" ]]; then
        echo "  Get token from: https://github.com/organizations/$ORG/settings/actions/runners"
    else
        echo "  Get token from: https://github.com/$REPO/settings/actions/runners"
    fi
    echo ""
    read -rp "  Paste removal token: " REMOVAL_TOKEN

    if [[ -z "$REMOVAL_TOKEN" ]]; then
        print_fail "No removal token provided."
        exit 1
    fi
    print_ok "Removal token received (manual entry)"
}

# =============================================================================
# Remove a single runner instance
# =============================================================================
remove_single_runner() {
    local runner_name=$1
    local runner_dir="$RUNNER_INSTALL_DIR/$runner_name"

    print_step "Removing runner: $runner_name"

    # Check if runner directory exists
    if [[ ! -d "$runner_dir" ]]; then
        print_fail "Runner directory not found: $runner_dir"
        FAILED+=("$runner_name (directory not found)")
        return 1
    fi

    # Step 1: Stop the systemd service
    print_info "Stopping runner service..."
    if [[ -f "$runner_dir/svc.sh" ]]; then
        cd "$runner_dir"
        ./svc.sh stop 2>/dev/null || true
        ./svc.sh uninstall 2>/dev/null || true
        cd - >/dev/null
        print_ok "Service stopped and uninstalled"
    else
        print_warn "svc.sh not found, skipping service removal"
    fi

    # Step 2: Deregister the runner from GitHub
    print_info "Deregistering runner from GitHub..."
    if [[ -f "$runner_dir/config.sh" ]]; then
        cd "$runner_dir"
        if ./config.sh remove --token "$REMOVAL_TOKEN" 2>/dev/null; then
            print_ok "Runner deregistered from GitHub"
        else
            print_warn "Deregistration failed (runner may already be removed from GitHub)"
        fi
        cd - >/dev/null
    else
        print_warn "config.sh not found, skipping deregistration"
    fi

    # Step 3: Remove runner files
    print_info "Removing runner files: $runner_dir"
    if rm -rf "$runner_dir"; then
        print_ok "Runner files removed"
        REMOVED+=("$runner_name")
        return 0
    else
        print_fail "Failed to remove runner files"
        FAILED+=("$runner_name (file removal failed)")
        return 1
    fi
}

# =============================================================================
# Print summary
# =============================================================================
print_summary() {
    echo ""
    echo "============================================================================="
    echo "  UNINSTALL SUMMARY"
    echo "============================================================================="
    echo ""

    if [[ ${#REMOVED[@]} -gt 0 ]]; then
        echo "  Removed (${#REMOVED[@]}):"
        for r in "${REMOVED[@]}"; do
            echo -e "    ${GREEN}[OK]${NC} $r"
        done
    fi

    if [[ ${#FAILED[@]} -gt 0 ]]; then
        echo ""
        echo "  Failed (${#FAILED[@]}):"
        for r in "${FAILED[@]}"; do
            echo -e "    ${RED}[FAIL]${NC} $r"
        done
    fi

    echo ""
    echo "============================================================================="

    if [[ ${#FAILED[@]} -gt 0 ]]; then
        echo -e "  ${RED}Some runners could not be removed. Review errors above.${NC}"
        exit 1
    else
        echo -e "  ${GREEN}All runners removed successfully!${NC}"
    fi
    echo "============================================================================="
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo "============================================================================="
    echo "  GitHub Self-Hosted Runner - Uninstall (Linux)"
    echo "============================================================================="

    validate_args
    get_removal_token

    if [[ "$REMOVE_ALL" == true ]]; then
        # Remove all runner directories under RUNNER_INSTALL_DIR
        if [[ ! -d "$RUNNER_INSTALL_DIR" ]]; then
            print_info "No runners found in $RUNNER_INSTALL_DIR"
            exit 0
        fi

        local runner_dirs
        runner_dirs=$(find "$RUNNER_INSTALL_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null)

        if [[ -z "$runner_dirs" ]]; then
            print_info "No runner directories found"
            exit 0
        fi

        # Confirmation prompt for removing all
        local count
        count=$(echo "$runner_dirs" | wc -l)
        print_warn "This will remove $count runner(s) from this VM."
        read -rp "Are you sure? (y/N): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            print_info "Aborted."
            exit 0
        fi

        while IFS= read -r dir; do
            local name
            name=$(basename "$dir")
            remove_single_runner "$name" || true
        done <<< "$runner_dirs"
    else
        remove_single_runner "$RUNNER_NAME"
    fi

    print_summary
}

main
