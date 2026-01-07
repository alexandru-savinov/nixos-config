# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Flake-based NixOS configuration for multi-machine deployment:
- **sancta-choir** (x86_64-linux): Hetzner Cloud VPS
- **rpi5** (aarch64-linux): Raspberry Pi 5

## Commands

```bash
# Build and validate
nix flake check
nix fmt
nixos-rebuild build --flake .#sancta-choir

# Deploy
nix run .#deploy -- sancta-choir

# Tests
nix-shell --run "pytest tests/ -v"

# Secrets
cd secrets && agenix -e <secret>.age    # Edit secret
cd secrets && agenix -r                  # Re-encrypt all

# RPi5 SD image
nix build .#images.rpi5-sd-image
```

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
| Flake input | `flake.nix` inputs section |

## Services

Custom NixOS modules wrap upstream services with Tailscale integration and agenix secrets:

| Module | Port | Description |
|--------|------|-------------|
| `services.open-webui-tailscale` | 8080 | AI gateway (OpenRouter + Tavily Search) |
| `services.n8n-tailscale` | 5678 | Workflow automation with execution pruning |
| `services.uptime-kuma-tailscale` | 3001 | Status monitoring with auto-backups |
| `services.tailscale` | - | Mesh VPN (all services exposed via Tailscale only) |

**Security Pattern:** Services bind to `127.0.0.1` only, accessed via Tailscale Serve HTTPS proxy. No firewall rules needed - localhost binding provides defense-in-depth.

Access URLs (HTTPS only):
- Open-WebUI: `https://sancta-choir.tail4249a9.ts.net`
- Uptime Kuma: `https://sancta-choir.tail4249a9.ts.net:3001`
- n8n: `https://sancta-choir.tail4249a9.ts.net:5678`

## Secrets (Agenix)

```nix
# Define in secrets/secrets.nix, then in host config:
age.secrets.my-secret.file = "${self}/secrets/my-secret.age";

# Use in service:
someService.secretFile = config.age.secrets.my-secret.path;
```

Current secrets: `openrouter-api-key`, `tavily-api-key`, `n8n-encryption-key`, `tailscale-auth-key`, `open-webui-secret-key`

## CI/CD

GitHub Actions on push/PR: `nix flake check`, build all hosts, format check. Main branch protected - use PRs.

## Git Workflow

**IMPORTANT:** Always use git worktrees when making code changes. Never commit directly to main.

### Pre-Switch Validation

**Before creating or switching to a worktree**, validate the current work:

```bash
# 1. Format check
nix fmt

# 2. Flake validation + tests
nix flake check

# 3. Build current host (architecture-specific)
nixos-rebuild build --flake .#sancta-choir  # x86_64 only
nixos-rebuild build --flake .#rpi5          # aarch64 only
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

### Project-Local Plugins

This repo has custom Claude Code plugins in `.claude/plugins/` that override marketplace commands:

| Plugin | Location | Purpose |
|--------|----------|---------|
| `nix-commit` | `.claude/plugins/nix-commit/` | Runs `nix fmt` before commits to pass CI formatting checks |
| `local-review` | `.claude/plugins/local-review/` | Pre-commit code review |

**Important:** Use `/nix-commit:commit` instead of `/commit` to ensure Nix files are formatted before committing. This prevents CI failures from formatting mismatches.

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

## Troubleshooting

### Build Failures

```bash
# Clear evaluation cache
rm -rf ~/.cache/nix/eval-cache*

# Check specific host (fast, catches config errors without building)
nix eval .#nixosConfigurations.sancta-choir.config.system.build.toplevel
nix eval .#nixosConfigurations.rpi5.config.system.build.toplevel
```

### Service Issues

```bash
# Check service status
ssh sancta-choir "systemctl status <service>"
ssh rpi5 "systemctl status <service>"

# View logs
ssh sancta-choir "journalctl -u <service> -f"
```

### Tailscale Issues

```bash
tailscale status
tailscale serve status
```

## Service Configuration Notes

### Localhost Binding

Each service has its own environment variable for binding:

| Service | Variable | Value |
|---------|----------|-------|
| Open-WebUI | `host` option | `127.0.0.1` (default) |
| Uptime Kuma | `HOST` setting | `127.0.0.1` |
| n8n | `N8N_LISTEN_ADDRESS` env | `127.0.0.1` |

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
