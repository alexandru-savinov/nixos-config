# NixOS Configuration Repository - AI Agent Guide

**Last Updated:** 2025-11-26

## Project Architecture

This is a **flake-based NixOS configuration** for managing multiple machines with shared modules. The repository enables both local and remote deployments via `nix run` directly from GitHub.

### Core Structure

```
flake.nix          # Central flake with nixosConfigurations, packages, and apps outputs
├── hosts/         # Per-machine configurations
│   ├── common.nix # Shared settings (flakes, SSH, zram, boot cleanup)
│   └── sancta-choir/
│       ├── configuration.nix        # Host-specific imports, agenix secrets, SSH keys
│       └── hardware-configuration.nix  # Auto-generated hardware config
├── modules/       # Reusable NixOS modules
│   ├── services/  # Service configs (open-webui, tailscale, tsidp, copilot MCP server)
│   ├── system/    # System configs (networking, packages, firewall)
│   └── users/     # Home-manager user configurations
├── scripts/       # Deployment scripts (shebangs removed, wrapped by writeShellApplication)
├── secrets/       # Agenix-encrypted secrets (.age files)
│   ├── secrets.nix              # Public key definitions for encryption
│   ├── open-webui-secret-key.age
│   ├── openrouter-api-key.age
│   ├── tailscale-auth-key.age
│   ├── tavily-api-key.age
│   └── oidc-client-secret.age
└── tests/         # NixOS test modules
```

### Key Architectural Decisions

- **Flake inputs**: Pinned to NixOS 24.05 stable (`nixos-24.05` branch), with nixpkgs-unstable for specific packages
- **Multi-system support**: Scripts packaged for `x86_64-linux` and `aarch64-linux` via `forAllSystems`
- **Home-manager integration**: Loaded as NixOS module (not standalone), configuration in `modules/users/`
- **Remote deployment**: `packages` and `apps` outputs enable `nix run github:alexandru-savinov/nixos-config#install`
- **AI Gateway**: Open WebUI integrated with Tailscale Serve and Tavily Search API
- **Secrets Management**: Uses agenix for encrypted secrets (`.age` files in `secrets/`)
- **tsidp**: Currently disabled due to tsnet same-host isolation limitation

## Critical Workflows

### Deployment Scripts (writeShellApplication Pattern)

Scripts in `scripts/` **must NOT have shebangs** - `writeShellApplication` adds its own. Scripts include:
- `deploy.sh`: Updates existing systems (requires `nixos-rebuild`, `git`, `coreutils`, `gnugrep`, `gnused`)
- `install.sh`: Fresh installations from GitHub (requires `nixos-rebuild`, `git`, `coreutils`)

Both scripts:
1. Use `set -euo pipefail` as first line (not shebang)
2. Are wrapped via `builtins.readFile` in `flake.nix`
3. Accept hostname as first argument, optional flake path/branch as second

### Testing & Building

```bash
# Local development cycle
nix flake check                                    # Validate flake
nixos-rebuild build --flake .#sancta-choir         # Test build
./scripts/deploy.sh sancta-choir                   # Local deploy
nix run .#deploy -- sancta-choir                   # Via app wrapper

# Remote testing (from any branch/commit)
nix run github:alexandru-savinov/nixos-config/dev#deploy -- sancta-choir
nix run github:alexandru-savinov/nixos-config#install -- sancta-choir
```

### CI/CD

GitHub Actions (`.github/workflows/check.yml`) runs on push/PR:
- `nix flake check` - Validates flake structure
- Builds all host configurations (`nixosConfigurations.*.config.system.build.toplevel`)
- Checks Nix code formatting with `nixpkgs-fmt`

## Project-Specific Conventions

### Module Organization

- **hosts/**: Host-specific overrides only (imports, hostname, SSH keys)
- **modules/system/**: Hardware-agnostic system config (networking, packages, firewall)
- **modules/users/**: home-manager configs (never use `home-manager.users.<user>.home.username`)
- **modules/services/**: Service-specific settings (e.g., MCP server JSON configs)

### Networking Pattern (Hetzner Cloud)

The system uses **manual networking configuration** (no DHCP):
- Primary interface: `eth0` (forced via `usePredictableInterfaceNames = lib.mkForce false`)
- Static IP with `/32` prefix + manual gateway route to `172.31.1.1`
- udev rules bind MAC address to `eth0` name
- See `modules/system/networking.nix` for the complete pattern

### Home-Manager Integration

- Loaded via `home-manager.nixosModules.home-manager` in `flake.nix`
- User configs in `modules/users/<username>.nix`
- Use `home-manager.users.<user>` attribute set
- Always set `home.stateVersion` matching NixOS version (currently `24.05`)
- Note: `system.stateVersion` in `hosts/common.nix` is `23.11` (original install version, should not change)

### VSCode Server Support

- Uses `nixos-vscode-server` flake input for remote development
- Enabled in `modules/system/host.nix` via `services.vscode-server.enable = true`
- Required for GitHub Copilot development workflow

## Common Patterns

### Adding a New Host

1. Create `hosts/<hostname>/` directory
2. Add `configuration.nix` (imports common.nix + modules + hardware-configuration.nix)
3. Set `networking.hostName` and SSH keys
4. Generate `hardware-configuration.nix` with `nixos-generate-config`
5. Add to `flake.nix` in `nixosConfigurations` with correct system architecture
6. Pass `pkgs-unstable` in specialArgs if needed for certain packages
7. Configure agenix secrets in `age.secrets` attribute set
8. Update CI workflow to build new host

### Adding System Packages

Edit `modules/system/host.nix` → `environment.systemPackages`:
- Use `with pkgs;` for package lists
- Include Nix dev tools: `nixpkgs-fmt` (formatter), `nil` (LSP)
- Development tools: `helix`, `gh`, `github-copilot-cli`
- For unstable packages: use `nixpkgs-unstable` passed via specialArgs

### Adding Services

1. Create module in `modules/services/<service>.nix`
2. Define service configuration with enable option
3. Import in host's `configuration.nix`
4. For containerized services: use `virtualisation.docker` or `virtualisation.podman`
5. For Tailscale-exposed services: configure `tailscale serve` in service module
6. For secrets: add `.age` file to `secrets/`, update `secrets/secrets.nix`, reference via `config.age.secrets.<name>.path`

### Modifying Flake Dependencies

1. Update version in `inputs` section of `flake.nix`
2. Run `nix flake update` to regenerate `flake.lock`
3. Test with `nix flake check` before committing
4. For home-manager: ensure `.follows = "nixpkgs"` to avoid version mismatches
5. For unstable packages: use `nixpkgs-unstable` input and pass via specialArgs

### Managing Secrets with Agenix

1. Define public keys in `secrets/secrets.nix`:
   - User keys (SSH keys authorized in configs)
   - System keys (from `/etc/ssh/ssh_host_ed25519_key.pub`)
2. Create encrypted secrets:
   ```bash
   cd secrets
   agenix -e <secret-name>.age  # Edit/create secret
   ```
3. Reference in host configuration:
   ```nix
   age.secrets.<name>.file = "${self}/secrets/<name>.age";
   ```
4. Use secret path in service configs:
   ```nix
   someService.apiKeyFile = config.age.secrets.<name>.path;
   ```

## External Dependencies

- **NixOS 24.05 stable**: Main nixpkgs channel
- **nixpkgs-unstable**: For bleeding-edge packages (github-copilot-cli)
- **home-manager release-24.05**: User environment management
- **nixos-vscode-server**: Remote VSCode support (main branch)
- **tsidp**: Tailscale Identity Provider for OAuth (follows nixpkgs-unstable) - currently disabled
- **agenix**: Secret management with age encryption
- **GitHub Copilot CLI**: Installed from unstable as system package

## AI Gateway Services

The configuration includes Open WebUI integration:

### Open WebUI
- **Module**: `modules/services/open-webui.nix`
- **Port**: 8080 (internal, localhost only)
- **Tailscale Serve**: Exposed as HTTPS via Tailscale at `https://sancta-choir.tail4249a9.ts.net`
- **OpenRouter**: OpenAI-compatible API backend at `https://openrouter.ai/api/v1`
- **Tavily Search**: Web search RAG integration enabled
- **Authentication**: OIDC disabled (tsidp same-host limitation), signup disabled
- **Secrets**: JWT key, OpenRouter API key, Tavily API key managed via agenix

### Tailscale
- **Module**: `modules/services/tailscale.nix`
- **Features**: Declarative auth with authkey, SSH enabled, accepts routes
- **Interface**: `tailscale0` (trusted in firewall)
- **Port**: 41641 (UDP)

### tsidp (Tailscale Identity Provider)
- **Module**: `modules/services/tsidp.nix`
- **Status**: DISABLED
- **Reason**: tsnet isolation prevents same-host communication
- **Future**: Deploy on separate machine when needed

## Security Considerations

- SSH keys stored directly in config (consider secrets management for production)
- Root login disabled except with SSH keys (`PermitRootLogin = "prohibit-password"`)
- Firewall enabled by default, only port 22 (SSH) open on public interface
- Actual hostname is `sancta-choir` (matches directory name and flake configuration)
- **Tailscale**: Provides encrypted network layer for services
- **Open WebUI**: Exposed only via Tailscale network (not public internet)
- **Tailscale interface** (`tailscale0`) is trusted in firewall
- **Secrets Management**: All sensitive data (API keys, auth tokens) encrypted with agenix

## Development Environment

- **Formatter**: `nixpkgs-fmt` (run with `nix fmt`)
- **LSP**: `nil` (Nix language server)
- **Shell**: `shell.nix` provides `nixpkgs-fmt` and `nil` for non-flake environments
- **Editor**: Helix configured by default, but VSCode server enabled for remote development

## Branch Protection

The `main` branch is protected and requires pull requests for all changes.

### Standard Workflow
```bash
# Create feature branch
git checkout -b feature/my-changes

# Make changes and commit
git add .
git commit -m "feat: description"

# Push branch
git push origin feature/my-changes

# Create PR
gh pr create --title "Title" --body "Description"

# Wait for CI checks to pass, then merge
gh pr merge --squash --delete-branch

# Or enable auto-merge (merges automatically when checks pass)
gh pr merge --squash --delete-branch --auto
```

**Note:** Direct pushes to `main` are blocked. All changes must go through pull requests. CI checks must pass before merging. Do not use `--admin` flag to bypass checks.

## Domain Expertise Reference

When requesting AI assistance, consider these domain categories:

| Domain | Scope | Key Files |
|--------|-------|-----------|
| **NixOS Configuration** | Flake management, modules, packages | `flake.nix`, `modules/` |
| **Deployment/CI** | GitHub Actions, deployment scripts | `.github/workflows/`, `scripts/` |
| **Infrastructure** | Networking, firewall, Tailscale | `modules/system/networking.nix` |
| **AI Gateway** | Open WebUI, OpenRouter, Tavily Search | `modules/services/open-webui.nix` |
| **Security** | Secrets, SSH, firewall rules | `secrets/`, SSH configs |
| **Documentation** | README, guides, comments | `README.md`, `.github/` |

**Complex tasks** often span multiple domains. For example:
- Adding a new service: NixOS Config + Infrastructure
- Deploying AI gateway: AI Gateway + Deployment
- Security hardening: Security + Infrastructure
