# Raspberry Pi 5 NixOS Configuration

This directory contains the NixOS configuration for a Raspberry Pi 5 running **Open-WebUI** with OpenRouter backend.

## Features

- 🌐 **Open-WebUI** with OpenRouter API integration
- 🔍 **Tavily Search** for RAG web search capabilities
- 🔒 **Tailscale** for secure remote access (HTTPS via Tailscale Serve)
- 💾 **Resource optimizations** for RPi5's limited RAM/storage
- 🔐 **Agenix** for encrypted secrets management

## Prerequisites

- Raspberry Pi 5 (8GB recommended for Open-WebUI)
- MicroSD card (32GB+) or NVMe SSD via M.2 HAT (recommended)
- Network connectivity (Ethernet recommended for initial setup)
- Another computer to SSH from

## Migration from Raspberry Pi OS

The easiest way to migrate is using the **bootstrap script** which leverages `nixos-infect`:

### Quick Start (From Raspberry Pi OS)

```bash
# 1. Flash Raspberry Pi OS Lite (64-bit) to your SD card
#    - Use Raspberry Pi Imager
#    - Enable SSH in the imager settings
#    - Set hostname, username, and password

# 2. Boot the Pi and SSH into it
ssh pi@<pi-ip>

# 3. Run the bootstrap script
curl -L https://raw.githubusercontent.com/alexandru-savinov/nixos-config/main/scripts/bootstrap.sh | sudo bash -s -- rpi5
```

The script will:
1. Install Nix package manager
2. Enable flakes
3. Optionally run `nixos-infect` to convert your system to NixOS
4. Generate hardware configuration
5. Apply the rpi5 configuration

### What the Bootstrap Script Does

```
┌─────────────────────────────────────────────────────────────┐
│  NixOS Bootstrap/Infect Script                              │
│  For Raspberry Pi 5 and other aarch64/x86_64 systems        │
└─────────────────────────────────────────────────────────────┘

Step 1/5: Checking Nix installation...
Step 2/5: Enabling flakes...
Step 3/5: Checking if NixOS is installed...
         → Offers nixos-infect option
Step 4/5: Generating hardware configuration...
Step 5/5: Applying configuration...
```

## Alternative: Fresh NixOS Installation

### Method 1: Using Pre-built NixOS Image

```bash
# Download the latest NixOS aarch64 SD image
curl -L -o nixos-sd.img.zst https://hydra.nixos.org/job/nixos/release-24.05/nixos.sd_image.aarch64-linux/latest/download-by-type/file/sd-image
zstd -d nixos-sd.img.zst

# Flash to SD card (replace /dev/sdX with your device!)
sudo dd if=nixos-sd.img of=/dev/sdX bs=4M status=progress conv=fsync

# Boot the Pi, SSH in (default: nixos/nixos)
ssh nixos@<pi-ip>

# Apply configuration
sudo nixos-rebuild switch --flake github:alexandru-savinov/nixos-config#rpi5
```

### Method 2: Manual Partitioning

```bash
# For SD card
sudo parted /dev/mmcblk0 -- mklabel gpt
sudo parted /dev/mmcblk0 -- mkpart ESP fat32 1MB 512MB
sudo parted /dev/mmcblk0 -- set 1 esp on
sudo parted /dev/mmcblk0 -- mkpart primary ext4 512MB 100%

# Format
sudo mkfs.fat -F 32 -n NIXOS_BOOT /dev/mmcblk0p1
sudo mkfs.ext4 -L NIXOS_ROOT /dev/mmcblk0p2

# Mount and install
sudo mount /dev/disk/by-label/NIXOS_ROOT /mnt
sudo mkdir -p /mnt/boot
sudo mount /dev/disk/by-label/NIXOS_BOOT /mnt/boot

sudo nixos-install --flake github:alexandru-savinov/nixos-config#rpi5
```

## Post-Installation Setup

### 1. Update Hardware Configuration

After first boot, verify the hardware configuration matches your setup:

```bash
nixos-generate-config --show-hardware-config > /tmp/hw.nix
diff /tmp/hw.nix /etc/nixos/hosts/rpi5/hardware-configuration.nix
```

Update `hardware-configuration.nix` with correct UUIDs if needed.

### 2. Update Secrets for RPi5

Get the Pi's SSH host key and update the secrets:

```bash
# On the Pi - get the host key
cat /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $1 " " $2}'
# Output: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA...
```

On your development machine:
```bash
# Edit secrets/secrets.nix - replace the rpi5 placeholder key
vim secrets/secrets.nix

# Re-encrypt all secrets with the new key
cd secrets
agenix -r

# Commit and push
git add -A && git commit -m "Add real rpi5 host key" && git push
```

### 3. Rebuild to Apply Secrets

```bash
sudo nixos-rebuild switch --flake github:alexandru-savinov/nixos-config#rpi5
```

## Resource Optimizations

The RPi5 configuration includes several optimizations for running Open-WebUI on limited hardware:

### Memory Management

| Setting | Value | Purpose |
|---------|-------|---------|
| zram | 50% of RAM | Compressed swap in memory |
| Swap file | 4GB | Disk swap for heavy workloads |
| vm.swappiness | 60 | Balanced swap usage |
| vm.min_free_kbytes | 64MB | Reserve for system stability |

### Open-WebUI Limits

| Limit | Value | Purpose |
|-------|-------|---------|
| MemoryMax | 2GB | Prevent runaway memory usage |
| MemoryHigh | 1.5GB | Trigger memory pressure earlier |
| CPUQuota | 300% | Max 3 cores |
| Nice | 5 | Lower priority during builds |

### Nix Build Optimization

| Setting | Value | Purpose |
|---------|-------|---------|
| max-jobs | 2 | Limit concurrent builds |
| cores | 2 | Cores per build job |
| GC trigger | 1GB free | Auto garbage collection |
| GC retention | 3 days | Aggressive cleanup |

### Storage Optimization

- Documentation disabled (except man pages)
- Journal limited to 100MB
- Daily garbage collection
- Auto-optimize nix store

## Accessing Open-WebUI

Once deployed, Open-WebUI is accessible via Tailscale:

```
https://rpi5.tail4249a9.ts.net
```

Features enabled:
- OpenRouter API (access to Claude, GPT-4, etc.)
- Tavily web search for RAG
- Tailscale HTTPS certificates (automatic)

## Troubleshooting

### Memory Issues During Build

If builds fail with OOM:

```bash
# Temporarily add more swap
sudo fallocate -l 4G /tmp/swapfile
sudo chmod 600 /tmp/swapfile
sudo mkswap /tmp/swapfile
sudo swapon /tmp/swapfile

# Then rebuild
sudo nixos-rebuild switch --flake .#rpi5

# Remove temporary swap
sudo swapoff /tmp/swapfile
rm /tmp/swapfile
```

### Open-WebUI Not Starting

```bash
# Check service status
systemctl status open-webui

# View logs
journalctl -u open-webui -f

# Check memory usage
free -h
htop
```

### Tailscale Issues

```bash
# Check Tailscale status
tailscale status

# Re-authenticate if needed
tailscale up --ssh

# Check serve configuration
tailscale serve status
```

### chromadb Build Issues

The configuration includes `allowBroken = true` because chromadb is marked as broken on aarch64.
This is a known issue with NixOS 24.05. The package still works, just not officially supported.

### Secrets Not Decrypting

```bash
# Verify host key matches secrets.nix
cat /etc/ssh/ssh_host_ed25519_key.pub

# Check agenix status
ls -la /run/agenix/

# Manual decryption test
agenix -d open-webui-secret-key.age
```

## Performance Tips

### Use NVMe Instead of SD Card

For significantly better performance:
1. Get an M.2 HAT for RPi5
2. Install NVMe SSD
3. Flash NixOS to NVMe
4. Update hardware-configuration.nix

### Active Cooling

For sustained workloads, use active cooling:
- Official RPi5 Active Cooler
- Or case with built-in fan

### Reduce Build Load

For faster rebuilds, use a remote builder:

```nix
nix.buildMachines = [{
  hostName = "sancta-choir";
  system = "x86_64-linux";
  # ... remote build config
}];
```

## Useful Commands

```bash
# Check system status
systemctl status

# View logs
journalctl -f

# Check Open-WebUI
systemctl status open-webui
curl -s http://127.0.0.1:8080/health

# Tailscale status
tailscale status
tailscale serve status

# Rebuild configuration
sudo nixos-rebuild switch --flake github:alexandru-savinov/nixos-config#rpi5

# Update flake inputs
nix flake update

# Garbage collect
sudo nix-collect-garbage -d

# Check disk usage
df -h
du -sh /nix/store

# Monitor resources
htop
btop
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Raspberry Pi 5                         │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────┐    ┌─────────────────┐    ┌────────────┐  │
│  │  Tailscale  │───▶│   Open-WebUI    │───▶│ OpenRouter │  │
│  │   (HTTPS)   │    │  (port 8080)    │    │    API     │  │
│  └─────────────┘    └─────────────────┘    └────────────┘  │
│        │                    │                              │
│        ▼                    ▼                              │
│  ┌─────────────┐    ┌─────────────────┐                    │
│  │  Tailscale  │    │  Tavily Search  │                    │
│  │    Serve    │    │   (RAG Web)     │                    │
│  └─────────────┘    └─────────────────┘                    │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## Files in This Directory

| File | Purpose |
|------|---------|
| `configuration.nix` | Main RPi5 NixOS configuration |
| `hardware-configuration.nix` | Hardware-specific settings (UUIDs, boot) |
| `README.md` | This documentation |