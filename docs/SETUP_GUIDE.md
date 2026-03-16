# Setup Guide

Complete step-by-step guide for setting up GitHub self-hosted runners on Linux and Windows VMs.

---

## Table of Contents

- [Step 0: Install and Authenticate GitHub CLI](#step-0-install-and-authenticate-github-cli)
- [Step 1: Clone This Repository](#step-1-clone-this-repository)
- [Step 2: Configure Settings](#step-2-configure-settings)
- [Step 3: Install Dependencies](#step-3-install-dependencies)
- [Step 4: Set Up Your First Runner](#step-4-set-up-your-first-runner)
- [Step 5: Add More Runner Instances](#step-5-add-more-runner-instances)
- [Step 6: Verify Runners in GitHub](#step-6-verify-runners-in-github)
- [Step 7: Use Runners in Workflows](#step-7-use-runners-in-workflows)
- [Token Authentication Methods](#token-authentication-methods)
- [Required Permissions](#required-permissions)

---

## Step 0: Install and Authenticate GitHub CLI

The GitHub CLI (`gh`) is the **recommended** way for scripts to auto-fetch runner registration tokens. Install it first.

### Install on Ubuntu / Debian

```bash
# Add the GitHub CLI repository
(type -p wget >/dev/null || sudo apt-get install wget -y) \
  && sudo mkdir -p -m 755 /etc/apt/keyrings \
  && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
  && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
  && sudo apt-get update \
  && sudo apt-get install gh -y
```

### Install on RHEL / CentOS / Fedora

```bash
sudo dnf install 'dnf-command(config-manager)' -y
sudo dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
sudo dnf install gh -y
```

### Install on Windows

```powershell
# Option A: Using winget (recommended)
winget install --id GitHub.cli

# Option B: Using Chocolatey
choco install gh -y

# Option C: Download MSI from https://cli.github.com/
```

### Authenticate GitHub CLI

After installation, log in:

```bash
# Interactive login (opens browser)
gh auth login

# Follow the prompts:
#   1. Select "GitHub.com"
#   2. Select "HTTPS"
#   3. Authenticate via browser
```

### Verify Authentication

```bash
gh auth status
```

Expected output:
```
github.com
  ✓ Logged in to github.com account YOUR_USERNAME
  ✓ Git operations configured to use https
  ✓ Token: gho_****
  ✓ Token scopes: admin:org, repo, workflow
```

> **Important:** For **org-level** runners, your account needs the `admin:org` scope. For **repo-level** runners, you need `repo` scope.

To add missing scopes:
```bash
gh auth refresh -s admin:org
```

---

## Step 1: Clone This Repository

```bash
git clone <repository-url> github-runner-setup
cd github-runner-setup
```

---

## Step 2: Configure Settings

Copy the example config and edit it:

```bash
cp config/runner-config.example.env config/runner-config.env
```

Edit `config/runner-config.env` with your values:

```env
# Choose scope: "org" or "repo"
RUNNER_SCOPE="org"

# For org-level runners
GITHUB_ORG="my-organization"

# For repo-level runners (uncomment and set if using repo scope)
# GITHUB_REPO="owner/repo-name"

# Runner naming
RUNNER_NAME_PREFIX="runner"

# Labels for targeting in workflows
RUNNER_LABELS="self-hosted,linux,x64"

# Optional: limit max runners on this VM (leave empty for auto-detect)
MAX_RUNNERS=""
```

> **Note:** The config file is optional. You can pass all values as command-line arguments instead.

---

## Step 3: Install Dependencies

### Linux

```bash
sudo bash linux/install-dependencies.sh
```

The script will:
1. Auto-detect your distro (Ubuntu/Debian, RHEL/CentOS, Fedora)
2. Install core tools: Python 3, Terraform, Docker, Git, jq, curl, unzip, wget
3. Prompt you for optional tools: Node.js, AWS CLI, Azure CLI, Go, Java 17/21

Options:
```bash
# Install everything without prompts
sudo bash linux/install-dependencies.sh --install-all

# Skip optional tools entirely
sudo bash linux/install-dependencies.sh --skip-optional
```

### Windows (PowerShell as Administrator)

```powershell
.\windows\install-dependencies.ps1
```

Options:
```powershell
# Install everything without prompts
.\windows\install-dependencies.ps1 -InstallAll

# Skip optional tools
.\windows\install-dependencies.ps1 -SkipOptional
```

---

## Step 4: Set Up Your First Runner

### Linux - Organization Runner

```bash
sudo bash linux/setup-runner.sh \
  --scope org \
  --org my-organization \
  --name prod-runner-1 \
  --labels "self-hosted,linux,x64,production"
```

### Linux - Repository Runner

```bash
sudo bash linux/setup-runner.sh \
  --scope repo \
  --repo owner/repo-name \
  --name dev-runner-1 \
  --labels "self-hosted,linux,x64"
```

### Windows - Organization Runner

```powershell
.\windows\setup-runner.ps1 `
  -Scope org `
  -Org my-organization `
  -Name prod-runner-win-1 `
  -Labels "self-hosted,windows,x64,production"
```

### Windows - Repository Runner

```powershell
.\windows\setup-runner.ps1 `
  -Scope repo `
  -Repo owner/repo-name `
  -Name dev-runner-win-1 `
  -Labels "self-hosted,windows,x64"
```

The setup script will:
1. Check VM capacity (CPU, RAM, disk)
2. Auto-fetch a registration token (gh CLI → GITHUB_PAT → manual)
3. Download the latest GitHub Actions runner
4. Configure and register with GitHub
5. Install as a system service (systemd / Windows Service)
6. Validate the installation
7. Print a summary with all check results

---

## Step 5: Add More Runner Instances

### Linux

```bash
# Add 2 more runners
sudo bash linux/add-runner.sh \
  --scope org \
  --org my-organization \
  --count 2 \
  --labels "self-hosted,linux,x64"

# Add 1 runner with a custom name suffix
sudo bash linux/add-runner.sh \
  --scope org \
  --org my-organization \
  --instance-id worker-gpu \
  --labels "self-hosted,linux,gpu"
```

### Windows

```powershell
# Add 3 more runners
.\windows\add-runner.ps1 `
  -Scope org `
  -Org my-organization `
  -Count 3 `
  -Labels "self-hosted,windows,x64"
```

The script checks VM capacity before adding and warns if at/over the limit.

---

## Step 6: Verify Runners in GitHub

After setup, verify your runners appear in GitHub:

- **Org runners:** `https://github.com/organizations/YOUR_ORG/settings/actions/runners`
- **Repo runners:** `https://github.com/YOUR_OWNER/YOUR_REPO/settings/actions/runners`

Each runner should show:
- **Status:** `Idle` (green) = ready to accept jobs
- **Labels:** The labels you assigned during setup

### Validate from the VM

```bash
# Linux - validate all runners
sudo bash linux/validate-runner.sh

# Linux - validate a specific runner
sudo bash linux/validate-runner.sh --name prod-runner-1 --verbose
```

```powershell
# Windows - validate all runners
.\windows\validate-runner.ps1

# Windows - validate a specific runner
.\windows\validate-runner.ps1 -Name prod-runner-win-1 -Detailed
```

---

## Step 7: Use Runners in Workflows

Reference your self-hosted runners in GitHub Actions workflows using `runs-on`:

```yaml
jobs:
  build:
    # Target a self-hosted Linux runner
    runs-on: [self-hosted, linux]
    steps:
      - uses: actions/checkout@v4
      - run: echo "Running on self-hosted runner!"
```

See the `examples/` directory for complete workflow examples:
- `basic-workflow.yml` - Simple CI pipeline
- `matrix-workflow.yml` - Multi-OS matrix build
- `deploy-workflow.yml` - Terraform deployment with approval gates

---

## Token Authentication Methods

Scripts obtain runner tokens using a **3-tier fallback**:

| Priority | Method | How it works |
|----------|--------|-------------|
| 1 | **GitHub CLI (`gh`)** | If `gh` is installed and authenticated, uses `gh api` to auto-create tokens. **Recommended.** |
| 2 | **`GITHUB_PAT` env var** | Set `GITHUB_PAT` in your environment or `runner-config.env`. Calls the GitHub REST API. |
| 3 | **Manual entry** | If neither is available, the script prompts you to paste a token from the GitHub UI. |

### Using GITHUB_PAT (alternative to gh CLI)

```bash
# Set in environment
export GITHUB_PAT="ghp_your_token_here"

# Or set in runner-config.env
GITHUB_PAT="ghp_your_token_here"
```

### Providing a token directly (skip auto-fetch)

```bash
# Linux
sudo bash linux/setup-runner.sh --scope org --org my-org --name runner-1 --token AXXXXXX

# Windows
.\windows\setup-runner.ps1 -Scope org -Org my-org -Name runner-1 -Token AXXXXXX
```

---

## Required Permissions

### For Organization-Level Runners

| Method | Required Permission |
|--------|-------------------|
| GitHub CLI | Account must be an **org admin** with `admin:org` scope |
| GITHUB_PAT | Token needs `admin:org` scope |
| Manual token | Generated from org settings (requires org admin access) |

### For Repository-Level Runners

| Method | Required Permission |
|--------|-------------------|
| GitHub CLI | Account must have **admin** access to the repository |
| GITHUB_PAT | Token needs `repo` scope |
| Manual token | Generated from repo settings (requires repo admin access) |

### System Permissions

| OS | Requirement |
|----|------------|
| Linux | `sudo` / root access (for systemd service, package installation) |
| Windows | Run PowerShell as **Administrator** (for Windows Service, package installation) |
