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
