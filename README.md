# NixOS Configuration Repository

Multi-machine NixOS configuration with shared modules.

## Structure

```
.
├── flake.nix              # Flake definition
├── hosts/
│   ├── common.nix         # Shared configuration
│   └── sancta-choir/      # Host-specific configs
├── modules/
│   ├── services/          # Service modules
│   ├── users/             # User configurations
│   └── system/            # System configurations
└── scripts/               # Deployment helpers
```

## Usage

### Initial Setup (New Machine)

1. Clone this repository:
   ```bash
   git clone <repo-url> /etc/nixos-config
   ```

2. Copy hardware configuration:
   ```bash
   cp /etc/nixos/hardware-configuration.nix /etc/nixos-config/hosts/<hostname>/
   ```

3. Create host configuration in `hosts/<hostname>/configuration.nix`

4. Build and test:
   ```bash
   cd /etc/nixos-config
   nixos-rebuild build --flake .#<hostname>
   ```

5. Activate:
   ```bash
   nixos-rebuild switch --flake .#<hostname>
   ```

### Updating Configuration

1. Pull latest changes:
   ```bash
   cd /etc/nixos-config
   git pull
   ```

2. Test build:
   ```bash
   nix flake check
   nixos-rebuild build --flake .#<hostname>
   ```

3. Apply changes:
   ```bash
   nixos-rebuild switch --flake .#<hostname>
   ```

### Testing

Before deploying:
```bash
# Check flake syntax and build all hosts
nix flake check

# Build without activating
nixos-rebuild build --flake .#<hostname>

# Test in VM
nixos-rebuild build-vm --flake .#<hostname>
./result/bin/run-*-vm
```

## Hosts

- **sancta-choir**: Primary server (Hetzner Cloud)

## Security Notes

- Hardware configurations are excluded from git (machine-specific)
- SSH keys should be managed via secrets management (TODO: add sops-nix)
- Never commit secrets directly to this repository

## Adding New Hosts

1. Create `hosts/<hostname>/configuration.nix`
2. Import `common.nix` and relevant modules
3. Add hardware configuration (not committed)
4. Add to `flake.nix` nixosConfigurations
5. Test and deploy
