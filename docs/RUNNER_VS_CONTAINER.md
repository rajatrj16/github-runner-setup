# Host-Runner vs. Container-Based Job Execution

A discovery document comparing running GitHub Actions jobs **directly on the self-hosted runner host** versus **inside containers on the same VM**.

---

## Overview

Both approaches execute on the **same self-hosted VM**. The difference is _where_ the job steps runs

## Approach A: Run Directly on Host

Jobs execute as OS processes on the runner VM. Tools and dependencies are pre-installed on the host.

```yaml
jobs:
  build:
    runs-on: [self-hosted, linux]
    steps:
      - uses: actions/checkout@v4
      - run: python -m pytest
```

### Pros

- **Zero overhead** — no image pull, no container startup latency
- **Full hardware access** — GPU, host networking, mounted drives
- **Pre-installed tools** — dependencies installed once, available to all jobs
- **Simpler debugging** — SSH into the VM, inspect processes directly

### Cons

- **Partial isolation only** — each runner instance has its own `_work` directory (e.g., `/opt/github-runners/runner-1/_work`), so job workspaces don't overlap across runners. However, all runners on the same host still share:
  - System-wide tools and configs (`/usr/local/bin`, `/etc/`, global pip/npm packages)
  - Temp directories (`/tmp`)
  - Shared OS user home (`~/.config`, `~/.cache`) if runners use the same service account
  - Running processes, ports, and system resources
- **State drift** — a job can install or modify global packages, change system config, or leave files outside `_work`, affecting jobs on any runner on that host
- **Dependency conflicts** — two concurrent jobs on different runners needing different global tool versions can collide

---

## Approach B: Run Jobs in Containers

The runner pulls a Docker image and executes all job steps inside that container. The container runs on the same self-hosted VM.

```yaml
jobs:
  build:
    runs-on: [self-hosted, linux]
    container:
      image: python:3.12-slim
    steps:
      - uses: actions/checkout@v4
      - run: pip install -r requirements.txt && pytest
```

### Job Containers

Both run as Docker containers on the same VM.

### Pros

- **Clean environment** — each job starts fresh, no leftover state
- **Reproducible** — image pins the exact OS + tool versions
- **Isolation** — jobs can't modify the host filesystem (unless volumes are mounted)
- **Version flexibility** — different jobs can use different tool versions simultaneously

### Cons

- **Image pull latency** — first run downloads the image (mitigated by caching)
- **Resource overhead** — container runtime adds CPU/memory cost
- **Limited host access** — no direct GPU, host networking requires `--network host`
- **Docker required** — Docker must be installed and running on the host
- **Complexity** — registry auth, image maintenance, Dockerfile management

---

## Approach C: Hybrid

Run some steps on the host and some in containers. Useful when you need host-level access for certain tasks but want isolation for others.

```yaml
jobs:
  build:
    runs-on: [self-hosted, linux]
    steps:
      # Host step — uses pre-installed Terraform
      - name: Terraform Plan
        run: terraform plan

      # Container step — isolated Python environment
      - name: Run tests
        uses: docker://python:3.12-slim
        with:
          args: bash -c "pip install -r requirements.txt && pytest"
```

This gives you the best of both: host tools where needed, container isolation where it matters.

---

## Security Comparison

### Host-Direct Risks

| Risk | Description |
|------|-------------|
| **Shared filesystem** | A malicious job can read/write anywhere the runner user has access |
| **Persistent state** | Secrets, tokens, or credentials left behind are visible to the next job |
| **Privilege escalation** | If runner runs as root (not recommended), a job has full VM control |
| **No job boundary** | One job can kill processes, exhaust resources, or modify system config |

### Container Isolation (Benefits & Limits)

| Benefit | Limitation |
|---------|-----------|
| Separate filesystem per job | Containers share the host kernel — not a VM-level boundary |
| Controlled network by default | Privileged containers (`--privileged`) break isolation |
| Disposable — removed after job | Mounted volumes can leak data between jobs |

**Key takeaway:** Containers reduce the blast radius significantly but are **not a security sandbox**. They are a strong default, not a guarantee.


## Private Registry

When using `container:` with a private image, the runner needs credentials to pull it. Three patterns:

### 1. Workflow `credentials` Block (Recommended)

Credentials are scoped to the job and provided via GitHub Secrets.

```yaml
jobs:
  build:
    runs-on: [self-hosted, linux]
    container:
      image: myregistry.io/myapp:1.0
      credentials:
        username: ${{ secrets.REGISTRY_USERNAME }}
        password: ${{ secrets.REGISTRY_PASSWORD }}
    steps:
      - uses: actions/checkout@v4
      - run: make test
```

- Works with any registry (ACR, ECR, GHCR, Docker Hub, etc.)
- Credentials are not persisted on disk after the job
- **Best for most use cases**

### 2. Pre-Authenticated `docker login` on Host

Run `docker login` once on the VM. All jobs can pull without per-job credentials.

```bash
# On the runner VM (one-time setup)
echo "$REGISTRY_PASSWORD" | docker login myregistry.io -u myuser --password-stdin
```

- Simpler — no per-workflow credential config
- **Risk:** Credentials persist in `~/.docker/config.json` on the host
- Any job running on that host can pull any image from that registry

### 3. Credential Helpers & Short-Lived Tokens

Use cloud-provider credential helpers that generate ephemeral tokens.

```bash
# Example: configure a credential helper
# The helper binary obtains a short-lived token automatically
echo '{"credHelpers":{"myregistry.io":"my-cred-helper"}}' > ~/.docker/config.json
```

| Registry | Credential Helper |
|----------|------------------|
| ACR | `docker-credential-acr-env` or `az acr login` |

- **Most secure** — tokens are short-lived and auto-rotated
- Requires the helper binary installed on the host

---

## Performance & Efficiency

| Factor | Host-Direct | Container-Based |
|--------|-------------|-----------------|
| **Startup time** | ~0s | 1–30s (depends on image size & cache) |
| **First-run cost** | None (tools pre-installed) | Image pull (can be 100MB–2GB+) |
| **Subsequent runs** | Same | Fast if image is cached locally |
| **Tool availability** | All host tools available | Only what's in the image |
| **Disk usage** | Single set of tools | Each image consumes disk space |
| **CPU/RAM overhead** | None | ~1–5% for container runtime |
| **Caching** | OS-level package cache | Docker layer cache + `--mount=type=cache` |

### When containers still make sense despite pre-installed host dependencies

- **Version pinning** — need exact `python:3.11.8` for reproducibility
- **Multi-version testing** — matrix across Python 3.10, 3.11, 3.12 in parallel
- **Clean-room builds** — release artifacts must be built in a known environment

---

## Decision Matrix

| Scenario | Recommended | Reason |
|----------|-------------|--------|
| Simple CI with pre-installed tools | **Host-direct** | No overhead, dependencies already there |
| Multi-version matrix builds | **Container** | Each job uses a different image/version |
| Builds requiring exact reproducibility | **Container** | Image pins every dependency |
| Jobs that use GPU or special hardware | **Host-direct** | Direct hardware access |
| Terraform / infra provisioning | **Host-direct** | Needs host credentials, cloud CLI |
| Building Docker images | **Host-direct** | Avoids Docker-in-Docker complexity |
| Mixed needs (infra + app tests) | **Hybrid** | Host for infra, container for app |
| Strict compliance / audit requirements | **Container** | Provable, scannable build environment |
