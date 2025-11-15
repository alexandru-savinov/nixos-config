# NixOS Configuration Repository - AI Agent Guide

**Last Updated:** 2025-11-15

## Project Architecture

This is a **flake-based NixOS configuration** for managing multiple machines with shared modules. The repository enables both local and remote deployments via `nix run` directly from GitHub.

### Core Structure

```
flake.nix          # Central flake with nixosConfigurations, packages, and apps outputs
├── hosts/         # Per-machine configurations
│   ├── common.nix # Shared settings (flakes, SSH, zram, boot cleanup)
│   └── sancta-choir/
│       ├── configuration.nix        # Host-specific imports and SSH keys
│       └── hardware-configuration.nix  # Auto-generated hardware config
├── modules/       # Reusable NixOS modules
│   ├── services/  # Service configs (open-webui, tailscale, tsidp, copilot MCP server)
│   ├── system/    # System configs (networking, packages, firewall)
│   └── users/     # Home-manager user configurations
└── scripts/       # Deployment scripts (shebangs removed, wrapped by writeShellApplication)
```

### Key Architectural Decisions

- **Flake inputs**: Pinned to NixOS 24.05 stable (`nixos-24.05` branch), with nixpkgs-unstable for specific packages
- **Multi-system support**: Scripts packaged for `x86_64-linux` and `aarch64-linux` via `forAllSystems`
- **Home-manager integration**: Loaded as NixOS module (not standalone), configuration in `modules/users/`
- **Remote deployment**: `packages` and `apps` outputs enable `nix run github:alexandru-savinov/nixos-config#install`
- **AI Gateway**: Open WebUI integrated with Tailscale Serve and optional tsidp OAuth authentication

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
6. Pass `nixpkgs-unstable` in specialArgs if needed for certain packages
7. Update CI workflow to build new host

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

### Modifying Flake Dependencies

1. Update version in `inputs` section of `flake.nix`
2. Run `nix flake update` to regenerate `flake.lock`
3. Test with `nix flake check` before committing
4. For home-manager: ensure `.follows = "nixpkgs"` to avoid version mismatches
5. For unstable packages: use `nixpkgs-unstable` input and pass via specialArgs

## External Dependencies

- **NixOS 24.05 stable**: Main nixpkgs channel
- **nixpkgs-unstable**: For bleeding-edge packages (tsidp)
- **home-manager release-24.05**: User environment management
- **nixos-vscode-server**: Remote VSCode support (main branch)
- **tsidp**: Tailscale Identity Provider for OAuth (follows nixpkgs-unstable)
- **GitHub Copilot CLI**: Installed as system package, MCP server config in `.copilot/mcp-config.json`

## AI Gateway Services

The `ai-gateway` branch includes Open WebUI integration:

### Open WebUI
- **Module**: `modules/services/open-webui.nix`
- **Port**: 8080 (internal)
- **Tailscale Serve**: Exposed as HTTPS via Tailscale (port 443)
- **Authentication**: Optional tsidp OAuth integration
- **Container**: Running via Docker/Podman with Ollama backend support
- **Access**: Via `https://<tailscale-hostname>` when Tailscale Serve is enabled

### Tailscale
- **Module**: `modules/services/tailscale.nix`
- **Features**: Declarative auth with authkey, automatic serve configuration
- **Serve Config**: Configured to expose Open WebUI on port 443
- **Network**: Provides secure private network access to services

### tsidp (Tailscale Identity Provider)
- **Module**: `modules/services/tsidp.nix` (optional)
- **Purpose**: OAuth authentication for Open WebUI
- **Integration**: Works with Tailscale network for identity verification

## Security Considerations

- SSH keys stored directly in config (consider secrets management for production)
- Root login disabled except with SSH keys (`PermitRootLogin = "prohibit-password"`)
- Firewall enabled by default, only port 22 (SSH) open
- Actual hostname is `sancta-choir` (matches directory name and flake configuration)
- **Tailscale**: Provides encrypted network layer for services
- **Open WebUI**: Exposed only via Tailscale network (not public internet)
- **tsidp OAuth**: Optional additional authentication layer for Open WebUI
- **Secrets Management**: Tailscale authkey should be managed via secrets (currently in config)

## Development Environment

- **Formatter**: `nixpkgs-fmt` (run with `nix fmt`)
- **LSP**: `nil` (Nix language server)
- **Shell**: `shell.nix` provides `nixpkgs-fmt` and `nil` for non-flake environments
- **Editor**: Helix configured by default, but VSCode server enabled for remote development
