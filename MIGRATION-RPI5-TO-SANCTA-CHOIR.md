# Migration Plan: Rename rpi5 to sancta-choir

**Date:** 2025-01-13  
**From:** `rpi5` (Raspberry Pi 5, aarch64-linux, local LAN)  
**To:** `sancta-choir` (Primary server, inherits the name from decommissioned Hetzner VPS)

## Overview

This migration renames the Raspberry Pi 5 host from `rpi5` to `sancta-choir`, making it the primary server for Open WebUI and related services. The original `sancta-choir` was an x86_64 VPS on Hetzner Cloud that has been decommissioned.

## Current State

### rpi5 (Current)
- **Architecture:** aarch64-linux (Raspberry Pi 5)
- **Location:** Local LAN (192.168.1.36)
- **Tailscale name:** `rpi5.tail4249a9.ts.net`
- **Host key:** `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIONeeV4HZKWxt/N4MPIj7Cwj5u7wJIu4Biul5n9kW57 root@rpi5`
- **Services:** Tailscale, SSH, VSCode Server (Open WebUI disabled)
- **Networking:** DHCP on local LAN

### sancta-choir (Old VPS - to be removed)
- **Architecture:** x86_64-linux (Hetzner Cloud VPS)
- **Status:** Decommissioned
- **Host key:** `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILkqRZZKLsSV7L67Rzh38UDU6F2GeMmgyiVLlQgS70zP root@sancta-choir`

## Migration Tasks

### Phase 1: Pre-Migration Preparation

- [ ] **1.1** Backup current rpi5 configuration
  ```bash
  cp -r hosts/rpi5 hosts/rpi5.backup
  ```

- [ ] **1.2** Verify Tailscale is working on rpi5
  ```bash
  tailscale status
  ```

- [ ] **1.3** Document current rpi5 host key (already captured above)

### Phase 2: Configuration Changes

#### 2.1 Rename Host Directory
- [ ] Rename `hosts/rpi5/` → `hosts/sancta-choir/`
- [ ] Delete old `hosts/sancta-choir/` (VPS config)

#### 2.2 Update `flake.nix`

**Remove old sancta-choir (x86_64) configuration:**
```nix
# DELETE this entire block (lines ~51-74)
sancta-choir = nixpkgs.lib.nixosSystem {
  system = "x86_64-linux";
  ...
};
```

**Rename rpi5 to sancta-choir:**
```nix
# Change from:
rpi5 = nixpkgs.lib.nixosSystem {
  system = "aarch64-linux";
  ...
  modules = [
    ./hosts/rpi5/configuration.nix
    ...
  ];
};

# Change to:
sancta-choir = nixpkgs.lib.nixosSystem {
  system = "aarch64-linux";
  ...
  modules = [
    ./hosts/sancta-choir/configuration.nix
    ...
  ];
};
```

**Update SD image reference:**
```nix
# Change from:
images = {
  rpi5-sd-image = self.nixosConfigurations.rpi5.config.system.build.sdImage;
};

# Change to:
images = {
  sancta-choir-sd-image = self.nixosConfigurations.sancta-choir.config.system.build.sdImage;
};
```

#### 2.3 Update Host Configuration (`hosts/sancta-choir/configuration.nix`)

**Changes required:**
1. Update hostname:
   ```nix
   networking.hostName = "sancta-choir";  # Was "rpi5"
   ```

2. Enable Open WebUI (uncomment):
   ```nix
   imports = [
     ...
     ../../modules/services/open-webui.nix  # Uncomment this
   ];
   ```

3. Enable Open WebUI secrets:
   ```nix
   age.secrets = {
     tailscale-auth-key.file = "${self}/secrets/tailscale-auth-key.age";
     open-webui-secret-key.file = "${self}/secrets/open-webui-secret-key.age";      # Uncomment
     openrouter-api-key.file = "${self}/secrets/openrouter-api-key.age";            # Uncomment
     tavily-api-key.file = "${self}/secrets/tavily-api-key.age";                    # Uncomment
     oidc-client-secret.file = "${self}/secrets/oidc-client-secret.age";            # Add if needed
     opencode-api-key.file = "${self}/secrets/opencode-api-key.age";                # Add
   };
   ```

4. Enable Open WebUI service:
   ```nix
   services.open-webui-tailscale = {
     enable = true;
     enableSignup = false;
     secretKeyFile = config.age.secrets.open-webui-secret-key.path;
     openai.apiKeyFile = config.age.secrets.openrouter-api-key.path;
     webuiUrl = "https://sancta-choir.tail4249a9.ts.net";
     
     tavilySearch = {
       enable = true;
       apiKeyFile = config.age.secrets.tavily-api-key.path;
     };
     
     oidc.enable = false;  # Keep disabled (tsidp same-host issue)
     
     tailscaleServe = {
       enable = true;
       httpsPort = 443;
     };
   };
   ```

5. Remove x86_64-specific settings:
   - Remove `boot.binfmt.emulatedSystems` (was for cross-compiling rpi5 from VPS)
   - Remove nix-community cachix (optional, can keep for convenience)

6. Update comments to reflect new role as primary server

#### 2.4 Update `secrets/secrets.nix`

```nix
let
  # Personal keys for editing secrets
  root-sancta-choir = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPw5RFrFfZQUWlyfGSU1Q8BlEHnvIdBtcnCn+uYtEzal nixos-sancta-choir";

  # System host keys - USE THE RPi5 KEY (it's now sancta-choir)
  sancta-choir = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIONeeV4HZKWxt/N4MPIj7Cwj5u7wJIu4Biul5n9kW57 root@rpi5";
  # Note: The key comment still says "root@rpi5" but that's just metadata, the key itself is what matters

  # REMOVE the old sancta-choir VPS key and rpi5 separate entry
  # OLD (delete): sancta-choir = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILkqRZZKLsSV7L67Rzh38UDU6F2GeMmgyiVLlQgS70zP root@sancta-choir";
  # OLD (delete): rpi5 = "ssh-ed25519 ...";

  users = [ root-sancta-choir ];
  systems = [ sancta-choir ];  # Only one system now
  allKeys = users ++ systems;
  sanctaChoirKeys = allKeys;  # Same as allKeys now (only one host)
in
{
  "tailscale-auth-key.age".publicKeys = allKeys;
  "open-webui-secret-key.age".publicKeys = allKeys;
  "openrouter-api-key.age".publicKeys = allKeys;
  "tavily-api-key.age".publicKeys = allKeys;
  "oidc-client-secret.age".publicKeys = sanctaChoirKeys;
  "opencode-api-key.age".publicKeys = sanctaChoirKeys;
}
```

#### 2.5 Update `modules/services/open-webui.nix`

Update default webuiUrl (optional, can override in host config):
```nix
webuiUrl = mkOption {
  type = types.str;
  default = "https://sancta-choir.tail4249a9.ts.net";  # Already correct
  ...
};
```

#### 2.6 Update `modules/users/root.nix`

The opencode config references sancta-choir URL - **no change needed**:
```nix
baseURL = "https://sancta-choir.tail4249a9.ts.net/api";  # Already correct
```

#### 2.7 Update `modules/system/host.nix`

This file has Hetzner-specific networking. Options:
- **Option A:** Delete it entirely (rpi5 config doesn't use it)
- **Option B:** Keep for reference/future x86_64 hosts
- **Recommendation:** Delete or move to `hosts/sancta-choir-vps.backup/`

#### 2.8 Update `modules/system/networking.nix`

This file has Hetzner Cloud static IP config. Options:
- **Option A:** Delete it (rpi5 uses DHCP)
- **Option B:** Keep for reference
- **Recommendation:** Delete or archive

#### 2.9 Update `.github/workflows/check.yml`

```yaml
- name: Build aarch64-linux configurations
  run: |
    echo "Building sancta-choir (aarch64-linux)..."
    nix build .#nixosConfigurations.sancta-choir.config.system.build.toplevel

# REMOVE the x86_64-linux build step (no longer have x86_64 hosts)
# Or change it to evaluate-only for CI speed
```

#### 2.10 Update `.github/copilot-instructions.md`

Update documentation to reflect:
- Single host (sancta-choir on RPi5)
- Architecture is now aarch64-linux
- Remove Hetzner Cloud references
- Update networking section for DHCP/local LAN

### Phase 3: Re-encrypt Secrets

After updating `secrets/secrets.nix`, re-encrypt all secrets so the new host key can decrypt them:

```bash
cd secrets

# Re-encrypt each secret (you need access to a key that can already decrypt)
agenix -r -i ~/.ssh/id_ed25519  # Or whichever key you use

# This re-encrypts all secrets with the updated public keys
```

### Phase 4: Tailscale Hostname Change

**Important:** Tailscale machine names need to be updated:

1. Go to [Tailscale Admin Console](https://login.tailscale.com/admin/machines)
2. Find the `rpi5` machine
3. Click on it → Edit → Rename to `sancta-choir`
4. Or use CLI on the Pi:
   ```bash
   sudo tailscale set --hostname=sancta-choir
   ```

After this, the machine will be accessible at:
- `https://sancta-choir.tail4249a9.ts.net`

### Phase 5: Deploy

```bash
# On the Raspberry Pi (currently named rpi5)
cd /etc/nixos

# Pull the changes
git pull

# Rebuild with new configuration
sudo nixos-rebuild switch --flake .#sancta-choir

# Verify hostname changed
hostname  # Should output: sancta-choir

# Verify Tailscale
tailscale status

# Verify Open WebUI is running
systemctl status open-webui
tailscale serve status
```

### Phase 6: Post-Migration Verification

- [ ] **6.1** SSH works: `ssh root@sancta-choir.tail4249a9.ts.net`
- [ ] **6.2** Open WebUI accessible: `https://sancta-choir.tail4249a9.ts.net`
- [ ] **6.3** Tailscale Serve configured correctly
- [ ] **6.4** All secrets decrypt properly
- [ ] **6.5** CI/CD passes on new configuration

### Phase 7: Cleanup

- [ ] **7.1** Remove backup files
- [ ] **7.2** Remove old VPS hardware-configuration.nix (x86_64/qemu-guest)
- [ ] **7.3** Update README.md if needed
- [ ] **7.4** Archive or delete `modules/system/networking.nix` (Hetzner-specific)
- [ ] **7.5** Archive or delete `modules/system/host.nix` (Hetzner-specific)

## Files to Modify (Summary)

| File | Action |
|------|--------|
| `hosts/rpi5/` | Rename to `hosts/sancta-choir/` |
| `hosts/sancta-choir/` (old VPS) | Delete |
| `hosts/sancta-choir/configuration.nix` | Update hostname, enable Open WebUI |
| `hosts/sancta-choir/hardware-configuration.nix` | Keep (RPi5 hardware) |
| `hosts/sancta-choir/README.md` | Update (was `hosts/rpi5/README.md`) - change URLs and references |
| `flake.nix` | Remove x86_64 config, rename rpi5→sancta-choir |
| `secrets/secrets.nix` | Update host keys |
| `modules/system/host.nix` | Delete or archive |
| `modules/system/networking.nix` | Delete or archive |
| `modules/services/open-webui.nix` | No change needed (default URL already correct) |
| `modules/users/root.nix` | No change needed (opencode URL already correct) |
| `.github/workflows/check.yml` | Update build targets |
| `.github/copilot-instructions.md` | Update documentation |
| `OPENCODE-PLAN.md` | No change needed (URLs already use sancta-choir) |
| `README.md` | Update if it references rpi5 |

### Additional Files Found with References

| File | Reference | Action |
|------|-----------|--------|
| `hosts/rpi5/README.md` | URLs like `rpi5.tail4249a9.ts.net`, commands with `#rpi5` | Update all to `sancta-choir` |
| `modules/services/tsidp.nix` | Comment mentions sancta-choir | No change needed |

## Rollback Plan

If something goes wrong:

1. The Pi still has SSH access via local IP (192.168.1.36)
2. Boot from SD card recovery if needed
3. Restore from backup:
   ```bash
   git checkout HEAD~1  # Revert to previous commit
   sudo nixos-rebuild switch --flake .#rpi5  # Use old name
   ```

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Secrets fail to decrypt | Medium | High | Test agenix decrypt before full deploy |
| Tailscale rename breaks connectivity | Low | Medium | Can rename back in admin console |
| Open WebUI fails on aarch64 | Low | Medium | chromadb previously had issues, test incrementally |
| SSH lockout | Low | High | Keep local console access, test SSH before reboot |

## Notes

- The host SSH key (`/etc/ssh/ssh_host_ed25519_key`) stays the same - only the hostname changes
- The Tailscale identity will update when hostname changes
- Open WebUI data directory (`/var/lib/open-webui`) will be fresh (new install)
- The old VPS sancta-choir's Open WebUI data is not migrated (separate machine)

## Appendix: Commands Quick Reference

### Pre-Migration Checks
```bash
# On rpi5 - verify current state
hostname                              # Should be: rpi5
tailscale status                      # Should show rpi5 in network
cat /etc/ssh/ssh_host_ed25519_key.pub # Capture the host key
```

### During Migration (on development machine)
```bash
# Git operations
git checkout -b migration/rpi5-to-sancta-choir
git mv hosts/rpi5 hosts/sancta-choir-new
rm -rf hosts/sancta-choir              # Remove old VPS config
git mv hosts/sancta-choir-new hosts/sancta-choir

# Re-encrypt secrets
cd secrets
agenix -r -i ~/.ssh/id_ed25519

# Test build
nix flake check
nix build .#nixosConfigurations.sancta-choir.config.system.build.toplevel
```

### Post-Migration Deployment (on the Pi)
```bash
# Apply new configuration
cd /etc/nixos
git pull
sudo nixos-rebuild switch --flake .#sancta-choir

# Update Tailscale hostname
sudo tailscale set --hostname=sancta-choir

# Verify
hostname
tailscale status
systemctl status open-webui
tailscale serve status
curl -s http://127.0.0.1:8080/health
```