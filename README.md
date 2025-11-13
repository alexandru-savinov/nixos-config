# NixOS Configuration Repository

Multi-machine NixOS configuration with shared modules. Deploy locally or remotely via `nix run` from GitHub.

## Quick Start

### Fresh System Installation

On a new NixOS system with flakes enabled:

```bash
# Enable flakes first (if needed)
mkdir -p ~/.config/nix
echo 'experimental-features = nix-command flakes' >> ~/.config/nix/nix.conf

# Install configuration directly from GitHub
nix run github:alexandru-savinov/nixos-config -- sancta-choir
```

### Alternative Installation Methods

**Option 1: Direct nixos-rebuild (no wrapper)**
```bash
sudo nixos-rebuild switch --flake github:alexandru-savinov/nixos-config#sancta-choir
```

**Option 2: Clone and deploy locally**
```bash
git clone https://github.com/alexandru-savinov/nixos-config.git /etc/nixos-config
cd /etc/nixos-config
./scripts/deploy.sh sancta-choir
```

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

## Usage Examples

### Local Development Workflow

```bash
cd /etc/nixos-config

# Edit configurations
vim hosts/sancta-choir/configuration.nix

# Test build
nix flake check
nixos-rebuild build --flake .#sancta-choir

# Deploy changes
./scripts/deploy.sh sancta-choir
# or
nix run .#deploy -- sancta-choir
```

### Testing from Branches

```bash
# Test from dev branch
nix run github:alexandru-savinov/nixos-config/dev#deploy -- sancta-choir

# Test from specific commit
nix run github:alexandru-savinov/nixos-config/abc123#install -- sancta-choir
```

### Remote Deployment

```bash
# Deploy from GitHub (useful for CI/CD)
./scripts/deploy.sh sancta-choir github:alexandru-savinov/nixos-config

# Or using nix run
nix run github:alexandru-savinov/nixos-config#deploy -- sancta-choir
```

## Prerequisites

### For Fresh Installations

- NixOS installed (minimal installation is fine)
- Internet connection
- Experimental features enabled:
  ```bash
  mkdir -p ~/.config/nix
  echo 'experimental-features = nix-command flakes' >> ~/.config/nix/nix.conf
  ```

### For Development

- Git
- Nix with flakes support
- Text editor
- Basic understanding of Nix language

### Hardware Configuration

Each host needs a `hardware-configuration.nix`:

```bash
# Generate hardware config
sudo nixos-generate-config --show-hardware-config > /tmp/hardware-configuration.nix

# Copy to your host directory
cp /tmp/hardware-configuration.nix hosts/<hostname>/

# Commit and push
git add hosts/<hostname>/hardware-configuration.nix
git commit -m "Add hardware config for <hostname>"
git push
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

## Troubleshooting

### Flakes Not Available

**Error:** `error: unrecognized command 'flake'`

**Solution:**
```bash
# Enable experimental features
mkdir -p ~/.config/nix
echo 'experimental-features = nix-command flakes' >> ~/.config/nix/nix.conf

# Or temporarily:
nix-shell -p git --command "nix --experimental-features 'nix-command flakes' run ..."
```

### File Not Found Errors

**Error:** `error: getting status of '/nix/store/.../some-file': No such file`

**Cause:** Unstaged files in git aren't included in the flake

**Solution:**
```bash
# Stage all files
git add .

# Or commit them
git commit -m "Add missing files"
```

### Hardware Configuration Missing

**Error:** Build fails with missing hardware configuration

**Solution:**
1. Generate: `nixos-generate-config`
2. Copy to: `hosts/<hostname>/hardware-configuration.nix`
3. Commit and push
4. Try installation again

### Network Issues

**Error:** `error: unable to download 'https://github.com/...'`

**Solution:**
- Check internet connection
- Verify GitHub is accessible
- Try with explicit commit hash instead of branch name

### Permission Denied

**Error:** `error: permission denied`

**Solution:**
- Use `sudo` for `nixos-rebuild`
- Or run the wrapper scripts which handle sudo automatically

### Build Failures

1. Check flake syntax:
   ```bash
   nix flake check
   ```

2. Build without applying:
   ```bash
   nixos-rebuild build --flake .#hostname
   ```

3. Check logs:
   ```bash
   journalctl -xeu nixos-rebuild
   ```

### Rollback

If something goes wrong:

```bash
# List generations
sudo nix-env --list-generations --profile /nix/var/nix/profiles/system

# Rollback to previous generation
sudo nixos-rebuild switch --rollback

# Boot into specific generation
sudo nixos-rebuild switch --switch-generation <number>
```

## Advanced Usage

### Multi-Architecture Support

The flake supports both x86_64-linux and aarch64-linux:

```bash
# Build for ARM
nix build .#packages.aarch64-linux.install

# Run on ARM system
nix run github:alexandru-savinov/nixos-config -- hostname
```

### Custom Branches

```bash
# Install from development branch
nix run github:alexandru-savinov/nixos-config/dev -- sancta-choir

# Install from pull request
nix run github:alexandru-savinov/nixos-config/pull/123/head -- sancta-choir
```

### Secrets Management

⚠️ **Never commit secrets to git!**

TODO: Implement sops-nix for secret management

For now:
- Use separate secrets file (not in git)
- Manage SSH keys manually
- Use environment variables where appropriate

### CI/CD Integration

Example GitHub Actions workflow:

```yaml
name: Build NixOS Config
on: [push, pull_request]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: cachix/install-nix-action@v22
        with:
          extra_nix_config: |
            experimental-features = nix-command flakes
      - run: nix flake check
      - run: nix build .#nixosConfigurations.sancta-choir.config.system.build.toplevel
```

## Hosts

- **sancta-choir**: Primary server (Hetzner Cloud)

## Known Limitations

### Internet Required
- Remote installations require internet connectivity
- GitHub must be accessible
- Flake inputs are fetched on each run (use `--offline` for cached builds)

### Flakes Must Be Enabled
- Requires `experimental-features = nix-command flakes`
- Not available on older Nix versions (<2.4)

### Fresh System Requirements
- NixOS already installed (use this after basic installation)
- Boot loader configured
- Network configured
- Minimal system working

### Hardware Configuration
- Must be committed to repo for remote installations
- Contains machine-specific settings
- Manual setup required for new hosts

### Git Staging Requirement
- Unstaged files are not included in flake
- Must commit or stage files for them to be available
- Can cause "file not found" errors

### Script Execution Context
- Scripts packaged with `writeShellApplication` run from `/nix/store`
- Cannot rely on repository structure or `BASH_SOURCE` paths
- For local development, run from repository directory
- Remote execution via `nix run` works independently

### No Secrets Management
- TODO: Implement sops-nix
- SSH keys must be managed manually
- Don't commit secrets to git

## Performance Notes

### First Run
- Downloads all flake inputs
- Builds packages from scratch
- Can take 10-30 minutes depending on configuration

### Subsequent Runs
- Uses cached inputs and builds
- Much faster (1-5 minutes typically)
- Only rebuilds changed components

### Cache Usage
```bash
# Clear cache if needed
nix-collect-garbage -d
```

### Offline Mode
```bash
# Use previously cached data
nix run --offline github:alexandru-savinov/nixos-config -- sancta-choir
```

## Security Notes

- Hardware configurations are excluded from git (machine-specific)
- SSH keys should be managed via secrets management (TODO: add sops-nix)
- Never commit secrets directly to this repository

## Tested Scenarios

✅ **Local Development**
- Clone repo and deploy locally
- Make changes and rebuild
- Run `nix flake check`
- Build without applying

✅ **Remote Installation**
- Fresh install via `nix run github:...`
- Direct `nixos-rebuild --flake github:...`
- Install from specific branch
- Install from specific commit

✅ **Multi-Architecture**
- Build for x86_64-linux
- Build for aarch64-linux
- Cross-compilation support

✅ **Apps and Packages**
- `nix run .#deploy`
- `nix run .#install`
- Default app configuration
- Remote execution from GitHub

## Adding New Hosts

1. Create `hosts/<hostname>/configuration.nix`
2. Import `common.nix` and relevant modules
3. Add hardware configuration (not committed)
4. Add to `flake.nix` nixosConfigurations
5. Test and deploy
