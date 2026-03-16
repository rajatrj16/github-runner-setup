# Uninstall Guide

How to cleanly remove GitHub self-hosted runners from your VMs.

---

## Table of Contents

- [Remove a Single Runner](#remove-a-single-runner)
- [Remove All Runners](#remove-all-runners)
- [Manual Removal](#manual-removal)
- [Cleanup Residual Files](#cleanup-residual-files)
- [Remove from GitHub UI](#remove-from-github-ui)

---

## Remove a Single Runner

### Linux

```bash
# Remove a specific runner (auto-fetches removal token via gh CLI)
sudo bash linux/uninstall-runner.sh \
  --name prod-runner-1 \
  --scope org \
  --org my-organization

# Remove a repo-level runner
sudo bash linux/uninstall-runner.sh \
  --name dev-runner-1 \
  --scope repo \
  --repo owner/repo-name

# Provide a removal token directly
sudo bash linux/uninstall-runner.sh \
  --name prod-runner-1 \
  --scope org \
  --org my-organization \
  --token ARXXXXXXX
```

### Windows (PowerShell as Administrator)

```powershell
# Remove a specific runner
.\windows\uninstall-runner.ps1 `
  -Name prod-runner-win-1 `
  -Scope org `
  -Org my-organization

# Provide a removal token directly
.\windows\uninstall-runner.ps1 `
  -Name prod-runner-win-1 `
  -Scope org `
  -Org my-organization `
  -Token ARXXXXXXX
```

### What the uninstall script does

1. **Stops the service** - Stops the systemd service (Linux) or Windows Service
2. **Uninstalls the service** - Removes the service registration from the OS
3. **Deregisters from GitHub** - Calls `config.sh remove` / `config.cmd remove` with the removal token to remove the runner from GitHub
4. **Deletes runner files** - Removes the entire runner directory

---

## Remove All Runners

### Linux

```bash
# Remove ALL runners on this VM (prompts for confirmation)
sudo bash linux/uninstall-runner.sh \
  --all \
  --scope org \
  --org my-organization
```

### Windows

```powershell
# Remove ALL runners on this VM (prompts for confirmation)
.\windows\uninstall-runner.ps1 `
  -All `
  -Scope org `
  -Org my-organization
```

The script will:
1. List all runner directories found
2. Ask for confirmation before proceeding
3. Remove each runner one by one
4. Print a summary of results

---

## Manual Removal

If the scripts fail or are unavailable, you can remove runners manually.

### Linux - Manual Steps

```bash
# 1. Find your runner directory
ls /opt/github-runners/

# 2. Navigate to the runner directory
cd /opt/github-runners/my-runner

# 3. Stop the service
sudo ./svc.sh stop
sudo ./svc.sh uninstall

# 4. Get a removal token (choose one method):
#    Method A: GitHub CLI
gh api --method POST orgs/MY_ORG/actions/runners/remove-token | jq -r '.token'
#    Method B: GitHub UI - go to Settings > Actions > Runners

# 5. Deregister the runner
./config.sh remove --token YOUR_REMOVAL_TOKEN

# 6. Remove runner files
cd /
sudo rm -rf /opt/github-runners/my-runner
```

### Windows - Manual Steps

```powershell
# 1. Find your runner directory
Get-ChildItem C:\github-runners\

# 2. Navigate to the runner directory
cd C:\github-runners\my-runner

# 3. Stop and uninstall the service
.\svc.cmd stop
.\svc.cmd uninstall

# 4. Get a removal token (choose one method):
#    Method A: GitHub CLI
gh api --method POST orgs/MY_ORG/actions/runners/remove-token | ConvertFrom-Json | Select-Object -ExpandProperty token
#    Method B: GitHub UI - go to Settings > Actions > Runners

# 5. Deregister the runner
.\config.cmd remove --token YOUR_REMOVAL_TOKEN

# 6. Remove runner files
cd C:\
Remove-Item -Path C:\github-runners\my-runner -Recurse -Force
```

---

## Cleanup Residual Files

After removing runners, you may want to clean up leftover data.

### Linux

```bash
# Remove the base runner directory if empty
sudo rmdir /opt/github-runners 2>/dev/null

# Remove the github-runner service user (if no longer needed)
sudo userdel -r github-runner 2>/dev/null

# Remove systemd service files that may be orphaned
sudo systemctl list-units --type=service | grep "actions.runner"
# If any orphaned services appear:
# sudo systemctl disable <service-name>
# sudo rm /etc/systemd/system/<service-name>.service
# sudo systemctl daemon-reload

# Clean up any leftover temporary files
sudo rm -f /tmp/actions-runner-*.tar.gz
```

### Windows

```powershell
# Remove the base runner directory if empty
Remove-Item -Path C:\github-runners -ErrorAction SilentlyContinue

# Check for orphaned services
Get-Service | Where-Object { $_.Name -like "actions.runner*" }
# If any orphaned services appear:
# sc.exe delete "service-name"

# Clean up temporary files
Remove-Item -Path "$env:TEMP\actions-runner-*.zip" -Force -ErrorAction SilentlyContinue
```

---

## Remove from GitHub UI

If the runner was already deleted from the VM but still shows in GitHub:

1. Go to your runner settings:
   - **Org:** `https://github.com/organizations/YOUR_ORG/settings/actions/runners`
   - **Repo:** `https://github.com/YOUR_OWNER/YOUR_REPO/settings/actions/runners`
2. Find the runner showing as **Offline**
3. Click the runner name
4. Click **Remove** (or the **...** menu > **Remove**)
5. Confirm the removal

> **Note:** Offline runners are automatically removed by GitHub after 30 days of inactivity. You can force-remove them immediately from the UI.
