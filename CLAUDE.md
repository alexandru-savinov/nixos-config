# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Current Environment

**You are running on rpi5** (Raspberry Pi 5, aarch64-linux). The **primary deploy target** is `rpi5-full`. The `sancta-choir` VPS hosts the OpenClaw AI gateway.

| Task | Command | Notes |
|------|---------|-------|
| Build & validate | `nix flake check` | Evaluates all configs |
| Build for deploy | `nixos-rebuild build --flake .#rpi5-full` | **Always use `rpi5-full`**, not `rpi5` |
| Deploy locally | `sudo nixos-rebuild switch --flake .#rpi5-full` | Native rebuild on RPi5 |
| SD image (rare) | `nix build .#images.rpi5-sd-image` | Uses minimal `rpi5` config |

### Default Deploy Target

**When the user says "deploy", "build", or "rebuild" without specifying a target, ALWAYS use `rpi5-full`.**

The `sancta-choir` configuration (x86_64 Hetzner VPS) hosts the **OpenClaw AI gateway**. It is built in CI but deployed separately. Only build or deploy `sancta-choir` when the user explicitly asks for it by name.

**Tailscale hostname:**
- `rpi5` or `rpi5.tail4249a9.ts.net`

## Project Overview

Flake-based NixOS configuration:
- **rpi5-full** (aarch64-linux): Raspberry Pi 5 ← **You are here** (only active host)
- **rpi5** (aarch64-linux): Minimal config for SD image builds only
- **sancta-choir** (x86_64-linux): Hetzner VPS — OpenClaw AI gateway
- **sancta-kuzea** (x86_64-linux): Hetzner VPS — OpenClaw container host
- **hetzner-ephemeral** (x86_64-linux): On-demand Hetzner VPS (disposable)

## Commands

```bash
# Build and validate
nix flake check
nix fmt
nixos-rebuild build --flake .#rpi5-full

# Deploy (local)
sudo nixos-rebuild switch --flake .#rpi5-full

# Tests
nix-shell --run "pytest tests/ -v"

# Secrets
cd secrets && agenix -e <secret>.age    # Edit secret
cd secrets && agenix -r                  # Re-encrypt all

# RPi5 SD image (rare, for fresh installs only)
nix build .#images.rpi5-sd-image
```

## Hetzner Cloud VPS Management

RPi5 serves as the control plane for Hetzner Cloud VPS provisioning. All operations use `--build-on-remote` (RPi5 evaluates the flake, target VPS builds its own x86_64 closure).

```
RPi5 (aarch64) ──hcloud──→ Hetzner API (create/destroy/manage VPS)
       │
       └──nixos-anywhere──→ Fresh VPS (x86_64, --build-on-remote)
               │
               └── NixOS config + Tailscale auto-join
```

### Hetzner Commands

| Task | Command | Notes |
|------|---------|-------|
| CLI with token | `sudo nix run .#hcloud-wrap -- server list` | Reads token from agenix |
| Create VPS | `sudo nix run .#hetzner-create -- --name NAME` | Full provisioning via nixos-anywhere |
| Destroy VPS | `sudo nix run .#hetzner-destroy -- --name NAME` | With Tailscale cleanup |
| List servers | `nix run .#hetzner-manage -- list` | No sudo needed |
| SSH into VPS | `nix run .#hetzner-manage -- ssh --name NAME` | Resolves IP automatically |
| Snapshot | `nix run .#hetzner-manage -- snapshot --name NAME` | Creates timestamped image |
| Resize | `nix run .#hetzner-manage -- resize --name NAME --type cx32` | Poweroff → resize → poweron |
| Deploy update | `nix run .#hetzner-manage -- deploy --name NAME` | git pull + nixos-rebuild |

### Shared Module

VPS configs use `modules/system/hetzner-cloud.nix`:
```nix
hetzner-cloud.enable = true;
hetzner-cloud.ipv4Address = "116.203.223.113";  # null for DHCP (ephemeral)
hetzner-cloud.macAddress = "92:00:06:bb:96:03";  # optional
```

Disk layout for new instances: `modules/system/hetzner-disko.nix` (GPT + BIOS boot + ext4).

### Secrets Bootstrapping

- **Ephemeral instances**: Tailscale auth key injected via `--extra-files` (no agenix)
- **Persistent instances**: Two-phase deploy — first with `--extra-files`, then add host key to `secrets.nix`, re-encrypt, and `nixos-rebuild switch`

## Architecture

```
hosts/common.nix                 # Shared: SSH, zram, flakes
hosts/<hostname>/configuration.nix
modules/services/                # Custom service wrappers
modules/system/                  # Networking, packages
secrets/                         # Agenix .age files
```

### Where to Put Things

| What | Where |
|------|-------|
| New service module | `modules/services/<name>.nix` |
| System-wide packages | `modules/system/packages.nix` |
| Host-specific config | `hosts/<hostname>/configuration.nix` |
| Shared across all hosts | `hosts/common.nix` |
| New secret | `secrets/<name>.age` + `secrets/secrets.nix` |
| Hetzner VPS module | `modules/system/hetzner-cloud.nix` (shared) |
| Hetzner disk layout | `modules/system/hetzner-disko.nix` (for nixos-anywhere) |
| Flake input | `flake.nix` inputs section |

## Services

Custom NixOS modules wrap upstream services with Tailscale integration and agenix secrets:

| Module | Port | Description |
|--------|------|-------------|
| `services.open-webui-tailscale` | 8080 | AI gateway (OpenRouter + Tavily Search) |
| `services.n8n-tailscale` | 5678 | Workflow automation with execution pruning |
| `services.nixframe` | VT 7 / HDMI-A-2 | Digital photo frame with n8n upload |
| `services.gatus-tailscale` | 3001 | Declarative status monitoring |
| `services.qdrant-tailscale` | 6333 | Vector database for RAG on ARM |
| `services.openclaw` | - | AI programming partner (Claude Code, file-based inbox) |
| `services.tailscale` | - | Mesh VPN (all services exposed via Tailscale only) |

**Security Pattern:** Services bind to `127.0.0.1` only, accessed via Tailscale Serve HTTPS proxy. Localhost binding provides defense-in-depth. OpenClaw uses a different model: file-based inbox with per-UID nftables network restriction (no listener).

Access URLs (HTTPS via Tailscale Serve):
- Open-WebUI: `https://rpi5.tail4249a9.ts.net`
- n8n: `https://rpi5.tail4249a9.ts.net:5678`
- NixFrame upload: `https://rpi5.tail4249a9.ts.net:5678/webhook/nixframe-ui`
- Gatus: `https://rpi5.tail4249a9.ts.net:3001`
- Qdrant: `https://rpi5.tail4249a9.ts.net:6333`

## Secrets (Agenix)

```nix
# Define in secrets/secrets.nix, then in host config:
age.secrets.my-secret.file = "${self}/secrets/my-secret.age";

# Use in service:
someService.secretFile = config.age.secrets.my-secret.path;
```

Current secrets: `openrouter-api-key`, `openai-api-key`, `tavily-api-key`, `n8n-encryption-key`, `n8n-admin-password`, `n8n-api-key`, `tailscale-auth-key`, `open-webui-secret-key`, `e2e-test-api-key`, `unifi-password`, `anthropic-api-key`, `openclaw-github-token`, `caldav-credentials`, `hcloud-api-token` (rpi5 only)

## CI/CD

GitHub Actions on push/PR: `nix flake check`, build sancta-choir (x86_64), evaluate rpi5 (aarch64 minimal), format check. **Note:** `rpi5-full` is NOT verified in CI — validate locally with `nixos-rebuild build --flake .#rpi5-full`. Main branch protected - use PRs.

## Git Workflow

**IMPORTANT:** Always use git worktrees when making code changes. Never commit directly to main.

### Pre-Switch Validation

**Before creating or switching to a worktree**, validate the current work:

```bash
# 1. Format check
nix fmt

# 2. Flake validation + tests
nix flake check

# 3. Build current host
nixos-rebuild build --flake .#rpi5-full
```

This ensures broken code isn't left behind when context-switching.

### Worktree Commands

```bash
# Create worktree for new feature/fix
git worktree add ../nixos-config-<branch-name> -b <branch-name>
cd ../nixos-config-<branch-name>

# After PR is merged, clean up
git worktree remove ../nixos-config-<branch-name>
```

### Branch Naming
- `feat/<name>` - New features
- `fix/<name>` - Bug fixes
- `docs/<name>` - Documentation changes
- `refactor/<name>` - Code refactoring

## Slash Commands

Use these plugin commands when working on this project:

| Command | When to Use |
|---------|-------------|
| `/nix-commit:commit` | Commit changes (runs `nix fmt` first) |
| `/nix-commit:commit-push-pr` | Commit, push, and create PR (runs `nix fmt` first) |
| `/clean_gone` | After merging PRs to clean up stale local branches |
| `/review-pr` | Before creating pull requests to catch issues early |
| `/feature-dev` | For complex feature implementations requiring architecture planning |
| `/screenshot:screenshot` | Capture NixFrame display screenshot (args: `forecast`, `sidebar`, or empty for full) |

### Project-Local Plugins

This repo has custom Claude Code plugins in `.claude/plugins/` that override marketplace commands:

| Plugin | Location | Purpose |
|--------|----------|---------|
| `nix-commit` | `.claude/plugins/nix-commit/` | Runs `nix fmt` before commits to pass CI formatting checks |
| `local-review` | `.claude/plugins/local-review/` | Pre-commit code review |
| `screenshot` | `.claude/plugins/screenshot/` | Capture NixFrame display screenshots |

**Important:** Use `/nix-commit:commit` instead of `/commit` to ensure Nix files are formatted before committing. This prevents CI failures from formatting mismatches.

## Verify Before Fixing

**Before applying any fix, follow this protocol — no exceptions:**

1. **State the hypothesis** — one sentence: *"I believe the root cause is X because Y."* Name the exact option, file, or behavior.
2. **Design a minimal test** — the smallest command that confirms or refutes the hypothesis *without making changes*:
   ```bash
   nixos-rebuild dry-build --flake .#rpi5-full 2>&1 | grep -iE "warn|error"  # capture current state
   nix eval .#nixosConfigurations.rpi5-full.config.<option>                   # inspect value
   grep -r "optionName" modules/                                              # find where it's set
   ```
3. **Run the test** — if it refutes the hypothesis, revise and repeat from step 1. Do NOT apply the fix anyway.
4. **Apply the fix** — minimal change only, exactly what the hypothesis identified.
5. **Verify** — re-run the same test. Confirm the problem is gone and no new warnings appeared.

**Anti-patterns to avoid:**
- Applying a fix that "seems right" without testing first
- Fixing multiple things at once (can't tell what caused what)
- Using `2>/dev/null` to suppress errors without understanding them

See also: `~/.claude/skills/verify-first/SKILL.md` (installed via `services.claude-skills`).

## Nix Code Style

- Use `lib.mkIf` for conditional options, not inline `if`
- Prefer `lib.mkDefault` for overridable defaults
- Module options: use `lib.mkEnableOption` for boolean enables
- Imports: group by type (modules, services, system)
- Secrets: always use `age.secrets.<name>.path`, never hardcode paths

## Adding New Services

1. Create module in `modules/services/<name>.nix`
2. Follow the Tailscale wrapper pattern:
   - Bind to `127.0.0.1` only
   - Create `<name>-tailscale-serve.service` for HTTPS proxy
   - Use `age.secrets` for sensitive config
3. Add to host configuration
4. Add secret to `secrets/secrets.nix` if needed

## n8n Async Workflow Pattern

For long-running n8n workflows (>60s), use the async job pattern to prevent browser timeout:

### Architecture
```
User → Main Webhook → Create Job ID → Trigger Worker → Return HTTP 202 immediately
                         │
                         ↓ (fire-and-forget)
                   Background Worker → Process → Update Status File

UI Polling → Status Endpoint → Read Status File → Return Progress JSON
```

### Key Components

| Component | Response Mode | Purpose |
|-----------|--------------|---------|
| Main webhook | `responseNode` | Create job, return 202 with statusUrl |
| Worker webhook | `onReceived` | Process in background |
| Status endpoint | `responseNode` | Read job status file |

### Fire-and-Forget Pattern
To trigger background work without blocking:
```json
{
  "options": { "timeout": 1000 },
  "continueOnFail": true
}
```

### Required Environment
Enable Node.js built-in modules for file-based status tracking:
```nix
extraEnvironment = {
  NODE_FUNCTION_ALLOW_BUILTIN = "fs,path,crypto";
};
```

### Job Storage
- Status files: `/var/lib/n8n/jobs/{jobId}/status.json`
- Auto-cleanup: `n8n-cleanup-jobs.timer` removes jobs older than 7 days

See PR #154 for reference implementation (`image-to-anki-*.json` workflows).

## Troubleshooting

### Build Failures

```bash
# Clear evaluation cache
rm -rf ~/.cache/nix/eval-cache*

# Check specific host (fast, catches config errors without building)
nix eval .#nixosConfigurations.rpi5-full.config.system.build.toplevel
```

### Service Issues

```bash
# Check service status (local on rpi5)
systemctl status <service>

# View logs
journalctl -u <service> -f
```

### Tailscale Issues

```bash
tailscale status
tailscale serve status
```

## Profiling & Debugging

### Installed Tools

| Tool | Package | Purpose |
|------|---------|---------|
| `strace` | `strace` | Syscall tracer for debugging service issues |
| `nix-tree` | `nix-tree` | Interactive closure size browser |

### Nix Evaluation Profiling

Profile where eval time is spent (built into Nix 2.31+, no extra tools needed):

```bash
# Generate collapsed stack trace
nix eval --eval-profiler flamegraph --eval-profile-file /tmp/eval.folded \
  .#nixosConfigurations.rpi5-full.config.system.build.toplevel

# Visualize: upload /tmp/eval.folded to https://speedscope.app
# Or generate SVG:
nix shell nixpkgs#flamegraph -c flamegraph.pl /tmp/eval.folded > /tmp/eval.svg
```

**Note:** Sampling-based - trivial expressions produce empty output. Flake eval is complex enough to work.

### On-Demand Tools (not installed, use via nix shell)

```bash
nix shell nixpkgs#flamegraph          # Flamegraph visualization
nix shell nixpkgs#nix-output-monitor  # Pretty build output (nom)
nix shell nixpkgs#nvd                 # Diff NixOS generations
nix shell github:Kha/nixprof          # Deeper Nix eval tracing
nix shell nixpkgs#statix              # Nix linter
nix shell nixpkgs#deadnix             # Find unused Nix code
```

### RPi5 Memory & Resource Monitoring

```bash
systemd-cgtop                    # Per-service CPU/memory/IO (requires reboot for memory after PR #202)
cat /proc/pressure/memory        # PSI memory pressure (requires reboot for psi=1)
systemctl status earlyoom        # OOM killer status
journalctl -u earlyoom -f        # Watch earlyoom decisions
```

**Important:** `cgroup_enable=memory` and `psi=1` boot params were added in PR #202 but require a **reboot** to take effect. Verify: `grep -q "cgroup_enable=memory" /proc/cmdline && echo "Applied" || echo "Reboot required"`. Until then, `systemd-cgtop` won't show memory columns and `/proc/pressure/` won't exist.

### perf (NOT available)

`linuxPackages.perf` has a kernel version mismatch (perf 6.18.2 vs running kernel 6.12.34). Do not add until the nixos-raspberrypi module updates.

## Service Configuration Notes

### Localhost Binding

Each service has its own environment variable for binding:

| Service | Variable | Value |
|---------|----------|-------|
| Open-WebUI | `host` option | `127.0.0.1` (default) |
| n8n | `N8N_LISTEN_ADDRESS` env | `127.0.0.1` |
| Gatus | `address` setting | `127.0.0.1` |
| Qdrant | `host` option | `127.0.0.1` (default) |

**Note:** n8n uses `N8N_LISTEN_ADDRESS`, not `N8N_HOST`. Always check official docs for correct variable names.

### Tailscale Serve Best Practices

1. **Port-specific cleanup:** Use `tailscale serve --https PORT off` in preStop, not `tailscale serve reset` (which breaks other services)

2. **Service ordering:** Tailscale Serve systemd services use `after` + `requires` on the main service, but this only waits for service start, not for the port to be listening

3. **Idempotent setup:** Check if serve is already configured before adding:
   ```bash
   if ! tailscale serve status | grep -q "https:PORT"; then
     tailscale serve --bg --https PORT http://127.0.0.1:PORT
   fi
   ```
