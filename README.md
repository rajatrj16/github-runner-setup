# GitHub Self-Hosted Runner Setup

A complete toolkit for installing, configuring, and managing GitHub Actions self-hosted runners on **Linux** (Ubuntu/Debian, RHEL/CentOS, Fedora) and **Windows** VMs.

---

## Features

- **Org-level or repo-level** runners via a single `--scope` argument
- **Automatic token management** — GitHub CLI → PAT → manual entry fallback
- **VM capacity check** — auto-calculates max runners based on CPU/RAM/disk
- **Multi-instance support** — add multiple runners to a single VM
- **Service mode** — runs as systemd (Linux) or Windows Service
- **Dependency installer** — core tools auto-installed, optional tools prompted
- **Validation & diagnostics** — built-in health checks and debug reports
- **Multi-distro** — detects Ubuntu/Debian, RHEL/CentOS, Fedora automatically
- **Example workflows** — ready-to-use GitHub Actions YAML files

---

## Project Structure

```
github-runner-setup/
├── README.md                            # This file
├── docs/
│   ├── SETUP_GUIDE.md                   # Detailed step-by-step setup guide
│   ├── UNINSTALL_GUIDE.md               # How to cleanly remove runners
│   └── TROUBLESHOOTING.md               # Debugging common issues
├── examples/
│   ├── basic-workflow.yml               # Simple CI workflow
│   ├── matrix-workflow.yml              # Multi-OS matrix build
│   └── deploy-workflow.yml              # Terraform deploy with approval
├── config/
│   └── runner-config.example.env        # Example configuration file
├── linux/
│   ├── setup-runner.sh                  # Install & register first runner
│   ├── add-runner.sh                    # Add additional runner instances
│   ├── install-dependencies.sh          # Install dev tools
│   ├── uninstall-runner.sh              # Stop service, remove runner
│   ├── validate-runner.sh               # Health check & validation
│   └── debug-runner.sh                  # Collect diagnostic info
└── windows/
    ├── setup-runner.ps1                 # Install & register first runner
    ├── add-runner.ps1                   # Add additional runner instances
    ├── install-dependencies.ps1         # Install dev tools
    ├── uninstall-runner.ps1             # Stop service, remove runner
    ├── validate-runner.ps1              # Health check & validation
    └── debug-runner.ps1                 # Collect diagnostic info
```

---

## Prerequisites

### Required

| Tool | Purpose |
|------|---------|
| **GitHub CLI (`gh`)** | Auto-fetch runner registration tokens ([install guide](docs/SETUP_GUIDE.md#step-0-install-and-authenticate-github-cli)) |
| **sudo / Administrator** | Install services and packages |
| **curl** | Download runner packages (auto-installed if missing) |
| **jq** | Parse API responses (auto-installed if missing) |

### Core Tools (auto-installed by `install-dependencies`)

| Tool | Notes |
|------|-------|
| Python 3 | Latest stable via package manager |
| Terraform | From HashiCorp official repo |
| Docker | Docker CE (Linux) / Docker Desktop (Windows) |
| Git | Latest from package manager |
| jq, curl, unzip, wget | Utility tools |

### Optional Tools (prompted during `install-dependencies`)

| Tool | Default |
|------|---------|
| Node.js LTS | Skip |
| AWS CLI v2 | Skip |
| Azure CLI | Skip |
| Go (latest) | Skip |
| Java 17 (OpenJDK) | Skip |
| Java 21 (OpenJDK) | Skip |

---

## Quick Start

### 1. Install GitHub CLI and authenticate

```bash
# Install (Ubuntu/Debian)
sudo apt install gh -y

# Authenticate
gh auth login
```

See [SETUP_GUIDE.md](docs/SETUP_GUIDE.md#step-0-install-and-authenticate-github-cli) for other OS install commands.

### 2. Clone and configure

```bash
git clone <repository-url> github-runner-setup
cd github-runner-setup
cp config/runner-config.example.env config/runner-config.env
# Edit config/runner-config.env with your org/repo details
```

### 3. Install dependencies

```bash
# Linux
sudo bash linux/install-dependencies.sh

# Windows (PowerShell as Administrator)
.\windows\install-dependencies.ps1
```

### 4. Set up your first runner

```bash
# Linux - org-level runner
sudo bash linux/setup-runner.sh \
  --scope org \
  --org my-organization \
  --name prod-runner-1 \
  --labels "self-hosted,linux,x64"

# Windows - org-level runner
.\windows\setup-runner.ps1 `
  -Scope org `
  -Org my-organization `
  -Name prod-runner-win-1 `
  -Labels "self-hosted,windows,x64"
```

### 5. Add more runners

```bash
# Add 3 more Linux runners
sudo bash linux/add-runner.sh --scope org --org my-org --count 3

# Add 2 more Windows runners
.\windows\add-runner.ps1 -Scope org -Org my-org -Count 2
```

### 6. Use in your workflows

```yaml
jobs:
  build:
    runs-on: [self-hosted, linux]
    steps:
      - uses: actions/checkout@v4
      - run: echo "Running on self-hosted runner!"
```

See the [`examples/`](examples/) directory for complete workflow files.

---

## Token Authentication

Scripts auto-fetch registration tokens using a **3-tier fallback**:

| Priority | Method | Details |
|----------|--------|---------|
| 1 | **GitHub CLI (`gh`)** | If `gh` is installed and authenticated. **Recommended.** |
| 2 | **`GITHUB_PAT` env var** | Set in environment or `runner-config.env` |
| 3 | **Manual entry** | Script prompts you to paste a token from GitHub UI |

You can also pass `--token` directly to skip auto-fetch entirely.

---

## VM Capacity Check

Before adding runners, scripts auto-calculate how many the VM can support:

- **Formula:** `min(CPU_cores/2, RAM_GB/4, free_disk_GB/10)`
- **Override:** Set `MAX_RUNNERS` in `runner-config.env`
- **Bypass:** Use `--force` flag to skip the check

---

## Management Commands

| Action | Linux | Windows |
|--------|-------|---------|
| **Validate** | `sudo bash linux/validate-runner.sh` | `.\windows\validate-runner.ps1` |
| **Debug** | `sudo bash linux/debug-runner.sh` | `.\windows\debug-runner.ps1` |
| **Uninstall one** | `sudo bash linux/uninstall-runner.sh --name runner-1 --scope org --org my-org` | `.\windows\uninstall-runner.ps1 -Name runner-1 -Scope org -Org my-org` |
| **Uninstall all** | `sudo bash linux/uninstall-runner.sh --all --scope org --org my-org` | `.\windows\uninstall-runner.ps1 -All -Scope org -Org my-org` |

---

## Documentation

- **[Setup Guide](docs/SETUP_GUIDE.md)** — Detailed step-by-step instructions for all OS
- **[Uninstall Guide](docs/UNINSTALL_GUIDE.md)** — How to cleanly remove runners
- **[Troubleshooting](docs/TROUBLESHOOTING.md)** — Common issues, log reading, service recovery

---

## Example Workflows

| File | Description |
|------|-------------|
| [`basic-workflow.yml`](examples/basic-workflow.yml) | Simple CI pipeline on a self-hosted runner |
| [`matrix-workflow.yml`](examples/matrix-workflow.yml) | Multi-OS matrix build (Linux + Windows) |
| [`deploy-workflow.yml`](examples/deploy-workflow.yml) | Terraform deploy with plan/approve/apply stages |
