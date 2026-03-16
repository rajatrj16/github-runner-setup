# Troubleshooting Guide

Common issues, debugging steps, and solutions for GitHub self-hosted runners.

---

## Table of Contents

- [Quick Diagnostics](#quick-diagnostics)
- [Common Issues](#common-issues)
  - [Runner Not Appearing in GitHub](#runner-not-appearing-in-github)
  - [Token Errors](#token-errors)
  - [Service Not Starting](#service-not-starting)
  - [Runner Goes Offline](#runner-goes-offline)
  - [Jobs Stuck in Queue](#jobs-stuck-in-queue)
  - [Permission Denied Errors](#permission-denied-errors)
  - [Network / Connectivity Issues](#network--connectivity-issues)
  - [Disk Space Issues](#disk-space-issues)
- [Reading Runner Logs](#reading-runner-logs)
- [Re-registering a Runner](#re-registering-a-runner)
- [Service Recovery](#service-recovery)

---

## Quick Diagnostics

Run the built-in diagnostic tools first:

### Linux

```bash
# Full health check
sudo bash linux/validate-runner.sh --verbose

# Detailed diagnostics report
sudo bash linux/debug-runner.sh --output /tmp/runner-debug.txt

# Diagnose a specific runner
sudo bash linux/debug-runner.sh --name my-runner
```

### Windows

```powershell
# Full health check
.\windows\validate-runner.ps1 -Detailed

# Detailed diagnostics report
.\windows\debug-runner.ps1 -OutputFile C:\temp\runner-debug.txt

# Diagnose a specific runner
.\windows\debug-runner.ps1 -Name my-runner
```

---

## Common Issues

### Runner Not Appearing in GitHub

**Symptoms:** Setup script completes but the runner doesn't show in GitHub Settings > Actions > Runners.

**Causes & Solutions:**

1. **Registration failed silently**
   ```bash
   # Check if .runner file exists (proves successful registration)
   ls -la /opt/github-runners/my-runner/.runner
   ls -la /opt/github-runners/my-runner/.credentials
   ```
   If either file is missing, the runner didn't register. Re-run setup.

2. **Wrong scope/org/repo**
   - Verify you're checking the right settings page:
     - Org: `https://github.com/organizations/YOUR_ORG/settings/actions/runners`
     - Repo: `https://github.com/OWNER/REPO/settings/actions/runners`

3. **Service not running** (runner registered but not connecting)
   ```bash
   # Linux
   cd /opt/github-runners/my-runner && sudo ./svc.sh status

   # Windows
   cd C:\github-runners\my-runner; .\svc.cmd status
   ```

---

### Token Errors

**Symptom:** `"message": "Bad credentials"` or `"message": "Not Found"` during token fetch.

**Solutions:**

| Error | Cause | Fix |
|-------|-------|-----|
| `Bad credentials` | PAT is invalid or expired | Generate a new PAT or re-authenticate `gh auth login` |
| `Not Found` | Wrong org/repo name, or insufficient permissions | Double-check `--org`/`--repo` values; ensure admin access |
| `Must have admin access` | Account lacks admin role | Use an org admin account or a PAT with `admin:org` scope |
| `Token has expired` | Registration token expired (valid for 1 hour) | Re-run the script to get a fresh token |

**Refresh gh CLI authentication:**
```bash
gh auth logout
gh auth login
gh auth refresh -s admin:org,repo
```

**Verify gh CLI has correct scopes:**
```bash
gh auth status
# Look for: Token scopes: admin:org, repo
```

---

### Service Not Starting

**Symptom:** Runner installed but service fails to start.

#### Linux (systemd)

```bash
cd /opt/github-runners/my-runner

# Check service status
sudo ./svc.sh status

# Check systemd journal for errors
sudo journalctl -u "actions.runner.*" --no-pager -n 50

# Check if another process is using the same port/socket
sudo lsof -i -P | grep Runner

# Try running the runner interactively to see errors
sudo -u github-runner ./run.sh
```

**Common fixes:**
- **File permissions:** `sudo chown -R github-runner:github-runner /opt/github-runners/my-runner`
- **SELinux blocking:** `sudo setenforce 0` (temporarily) or create proper SELinux policy
- **Missing libraries:** Run `sudo ./bin/installdependencies.sh` inside the runner dir

#### Windows

```powershell
cd C:\github-runners\my-runner

# Check service status
.\svc.cmd status

# Check Windows Event Log
Get-EventLog -LogName Application -Source "actions.runner*" -Newest 20

# Try running interactively
.\run.cmd
```

**Common fixes:**
- **Run as Administrator** when installing the service
- **Antivirus blocking:** Add runner directory to exclusions
- **.NET runtime missing:** Install .NET 6.0 runtime

---

### Runner Goes Offline

**Symptom:** Runner was working but now shows "Offline" in GitHub.

**Check in order:**

1. **Service crashed**
   ```bash
   # Linux
   cd /opt/github-runners/my-runner
   sudo ./svc.sh status

   # Restart if stopped
   sudo ./svc.sh start
   ```

2. **VM rebooted** - Service should auto-start, but check:
   ```bash
   # Linux: verify service is enabled
   systemctl is-enabled actions.runner.*.service

   # If not enabled
   cd /opt/github-runners/my-runner
   sudo ./svc.sh install github-runner
   sudo ./svc.sh start
   ```

3. **Network connectivity lost**
   ```bash
   # Test GitHub connectivity
   curl -sf https://github.com -o /dev/null && echo "OK" || echo "FAIL"
   curl -sf https://api.github.com -o /dev/null && echo "OK" || echo "FAIL"
   ```

4. **Credential rotation** - If the runner's credentials become invalid:
   ```bash
   # Re-register the runner (see Re-registering section below)
   ```

---

### Jobs Stuck in Queue

**Symptom:** Workflow jobs remain in "Queued" state and never start.

**Causes & Solutions:**

1. **Label mismatch** - The workflow's `runs-on` labels don't match any runner's labels.
   ```yaml
   # Workflow expects:
   runs-on: [self-hosted, linux, gpu]

   # But runner only has:
   # labels: self-hosted, linux
   ```
   Fix: Add missing labels or update the workflow.

2. **Runner is busy** - All matching runners are already running jobs.
   ```bash
   # Check how many runners are available
   sudo bash linux/validate-runner.sh
   # Consider adding more runners
   sudo bash linux/add-runner.sh --scope org --org my-org --count 2
   ```

3. **Runner group restrictions** (org-level) - Runner is in a group that the repo can't access.
   - Check: Org Settings > Actions > Runner groups > Edit group > Repository access

4. **Workflow permissions** - The repo may not be allowed to use org runners.
   - Check: Org Settings > Actions > General > Allow select repositories

---

### Permission Denied Errors

**During setup:**
```
Error: Must be run as root/Administrator
```
- **Linux:** Use `sudo bash linux/setup-runner.sh ...`
- **Windows:** Right-click PowerShell > "Run as Administrator"

**During job execution:**
```
Error: Permission denied accessing /path/to/file
```
- Runner runs as `github-runner` user. Check file ownership:
  ```bash
  ls -la /path/to/file
  sudo chown -R github-runner:github-runner /opt/github-runners/my-runner
  ```

**Docker permission denied:**
```
Error: Got permission denied while trying to connect to the Docker daemon socket
```
- Add the runner user to the docker group:
  ```bash
  sudo usermod -aG docker github-runner
  # Restart the runner service after
  cd /opt/github-runners/my-runner
  sudo ./svc.sh stop
  sudo ./svc.sh start
  ```

---

### Network / Connectivity Issues

**Required network access for GitHub runners:**

| Endpoint | Purpose |
|----------|---------|
| `github.com` | Runner registration and management |
| `api.github.com` | REST API calls |
| `*.actions.githubusercontent.com` | Actions service communication |
| `ghcr.io` | GitHub Container Registry |
| `*.blob.core.windows.net` | Action package downloads |

**Test connectivity:**
```bash
# Linux
for url in https://github.com https://api.github.com https://pipelines.actions.githubusercontent.com; do
  echo -n "$url: "
  curl -sf --max-time 10 -o /dev/null "$url" && echo "OK" || echo "FAIL"
done
```

```powershell
# Windows
@("https://github.com", "https://api.github.com", "https://pipelines.actions.githubusercontent.com") | ForEach-Object {
    try {
        $null = Invoke-WebRequest -Uri $_ -UseBasicParsing -TimeoutSec 10
        Write-Host "$_ : OK"
    } catch {
        Write-Host "$_ : FAIL"
    }
}
```

**If behind a proxy:**
```bash
# Set proxy for the runner
export http_proxy="http://proxy:8080"
export https_proxy="http://proxy:8080"
export no_proxy="localhost,127.0.0.1"

# Configure in the runner's .env file
echo "http_proxy=http://proxy:8080" >> /opt/github-runners/my-runner/.env
echo "https_proxy=http://proxy:8080" >> /opt/github-runners/my-runner/.env
```

---

### Disk Space Issues

**Symptom:** Jobs fail with disk space errors, or runner can't download packages.

```bash
# Check disk usage
df -h /opt/github-runners

# Check which runner work directories are using the most space
du -sh /opt/github-runners/*//_work/* 2>/dev/null | sort -rh | head -10
```

**Clean up old work directories:**
```bash
# Clean all runner work directories (stop services first!)
for dir in /opt/github-runners/*/; do
  echo "Cleaning $dir/_work"
  rm -rf "$dir/_work/"*
done
```

**Clean up old runner logs:**
```bash
# Remove logs older than 7 days
find /opt/github-runners/*/_diag -name "*.log" -mtime +7 -delete
```

---

## Reading Runner Logs

Runner logs are stored in the `_diag` directory inside each runner's folder.

### Key log files

| File | Contains |
|------|----------|
| `Runner_*.log` | Main runner process logs (connection, registration) |
| `Worker_*.log` | Job execution logs (steps, commands, outputs) |

### Linux

```bash
# View the latest runner log
ls -t /opt/github-runners/my-runner/_diag/Runner_*.log | head -1 | xargs tail -100

# Search for errors
grep -i "error\|fail\|exception" /opt/github-runners/my-runner/_diag/Runner_*.log | tail -20

# Follow logs in real-time
tail -f /opt/github-runners/my-runner/_diag/Runner_*.log
```

### Windows

```powershell
# View the latest runner log
Get-ChildItem C:\github-runners\my-runner\_diag\Runner_*.log | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | Get-Content -Tail 100

# Search for errors
Select-String -Path C:\github-runners\my-runner\_diag\Runner_*.log -Pattern "error|fail|exception" | Select-Object -Last 20
```

---

## Re-registering a Runner

If a runner's credentials become corrupted or you need to re-register:

### Linux

```bash
cd /opt/github-runners/my-runner

# 1. Stop the service
sudo ./svc.sh stop

# 2. Remove the old registration
# Get a removal token (auto via gh CLI):
REMOVE_TOKEN=$(gh api --method POST orgs/MY_ORG/actions/runners/remove-token | jq -r '.token')
./config.sh remove --token "$REMOVE_TOKEN"

# 3. Get a new registration token
REG_TOKEN=$(gh api --method POST orgs/MY_ORG/actions/runners/registration-token | jq -r '.token')

# 4. Re-configure
./config.sh --url https://github.com/MY_ORG --token "$REG_TOKEN" --name my-runner --labels "self-hosted,linux" --unattended --replace

# 5. Restart the service
sudo ./svc.sh start
```

### Windows

```powershell
cd C:\github-runners\my-runner

# 1. Stop the service
.\svc.cmd stop

# 2. Remove old registration
$removeToken = (gh api --method POST orgs/MY_ORG/actions/runners/remove-token | ConvertFrom-Json).token
.\config.cmd remove --token $removeToken

# 3. Re-configure
$regToken = (gh api --method POST orgs/MY_ORG/actions/runners/registration-token | ConvertFrom-Json).token
.\config.cmd --url https://github.com/MY_ORG --token $regToken --name my-runner --labels "self-hosted,windows" --unattended --replace

# 4. Restart service
.\svc.cmd start
```

---

## Service Recovery

### Linux - Restart a crashed service

```bash
cd /opt/github-runners/my-runner
sudo ./svc.sh stop
sudo ./svc.sh start
sudo ./svc.sh status
```

### Linux - Rebuild the service from scratch

```bash
cd /opt/github-runners/my-runner
sudo ./svc.sh stop
sudo ./svc.sh uninstall
sudo ./svc.sh install github-runner
sudo ./svc.sh start
```

### Windows - Restart a service

```powershell
cd C:\github-runners\my-runner
.\svc.cmd stop
.\svc.cmd start
.\svc.cmd status
```

### Windows - Rebuild the service

```powershell
cd C:\github-runners\my-runner
.\svc.cmd stop
.\svc.cmd uninstall
.\svc.cmd install
.\svc.cmd start
```

### Enable auto-restart on failure (Linux)

If the runner service keeps crashing, configure systemd to auto-restart:

```bash
# Find the service name
systemctl list-units --type=service | grep actions.runner

# Edit the service to add restart policy
sudo systemctl edit actions.runner.MY_ORG.my-runner.service
```

Add this override:
```ini
[Service]
Restart=always
RestartSec=10
```

Then reload:
```bash
sudo systemctl daemon-reload
sudo systemctl restart actions.runner.MY_ORG.my-runner.service
```
