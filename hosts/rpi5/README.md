# Raspberry Pi 5 NixOS Configuration

This directory contains the NixOS configuration for a Raspberry Pi 5 running **Open-WebUI** with OpenRouter backend.

> ⚠️ **Important:** NixOS support for RPi5 is experimental. This configuration uses `nixpkgs-unstable` with `linuxPackages_rpi4` (generic aarch64 kernel for RPi 3/4/5).
> See: https://nixos.wiki/wiki/NixOS_on_ARM/Raspberry_Pi_5

## Features

- 🌐 **Open-WebUI** with OpenRouter API integration
- 🔍 **Tavily Search** for RAG web search capabilities
- 🔒 **Tailscale** for secure remote access (HTTPS via Tailscale Serve)
- 💾 **Resource optimizations** for RPi5's limited RAM/storage
- 🔐 **Agenix** for encrypted secrets management
- 🐧 **linuxPackages_rpi4** kernel for RPi5 compatibility

## Prerequisites

- Raspberry Pi 5 (8GB recommended for Open-WebUI)
- MicroSD card (32GB+) or NVMe SSD via M.2 HAT (recommended)
- Network connectivity (Ethernet recommended for initial setup)
- Another computer for flashing and SSH

## Installation (Fresh NixOS)

Since RPi5 requires special kernel support, we recommend flashing a fresh NixOS image rather than using nixos-infect.

### Step 1: Download NixOS Image

**On Windows:**
1. Download from: https://hydra.nixos.org/job/nixos/release-24.05/nixos.sd_image.aarch64-linux/latest/download-by-type/file/sd-image
2. Extract the `.img.zst` file using 7-Zip (https://7-zip.org/)

**On Linux/macOS:**
```bash
curl -L -o nixos-sd.img.zst https://hydra.nixos.org/job/nixos/release-24.05/nixos.sd_image.aarch64-linux/latest/download-by-type/file/sd-image
zstd -d nixos-sd.img.zst
```

### Step 2: Flash to SD Card

**Using Raspberry Pi Imager (Recommended):**
1. Download: https://www.raspberrypi.com/software/
2. Open Raspberry Pi Imager
3. Choose OS → Scroll down → **Use custom** → Select your `.img` file
4. Choose Storage → Select your SD card
5. Click **Write**

**Using dd (Linux/macOS):**
```bash
# Replace /dev/sdX with your actual SD card device!
sudo dd if=nixos-sd.img of=/dev/sdX bs=4M status=progress conv=fsync
```

### Step 3: First Boot & SSH

1. Insert SD card into RPi5
2. Connect Ethernet cable
3. Power on and wait ~2 minutes
4. Find the Pi's IP address (check your router's DHCP clients or use `nmap -sn 192.168.1.0/24`)
5. SSH in:

```bash
# Default credentials: nixos / nixos
ssh nixos@<pi-ip>
```

### Step 4: Apply Configuration

```bash
# Become root
sudo -i

# Enable flakes (if not already)
mkdir -p ~/.config/nix
echo 'experimental-features = nix-command flakes' >> ~/.config/nix/nix.conf

# Apply the RPi5 configuration
nixos-rebuild switch --flake github:alexandru-savinov/nixos-config#rpi5
```

This will take a while as it downloads and builds the configuration.

### Step 5: Get Host Key & Update Secrets

After the rebuild completes, get the SSH host key:

```bash
cat /etc/ssh/ssh_host_ed25519_key.pub
# Output: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... root@rpi5
```

Then on your development machine:
1. Edit `secrets/secrets.nix` - replace the `rpi5` placeholder with the real key
2. Re-encrypt secrets: `cd secrets && agenix -r`
3. Commit and push
4. On the Pi: `nixos-rebuild switch --flake github:alexandru-savinov/nixos-config#rpi5`

### Step 6: Harden SSH (After Setup)

Once you've verified SSH key access works, edit the configuration to disable password auth:

```nix
services.openssh.settings = {
  PermitRootLogin = "prohibit-password";
  PasswordAuthentication = false;
};
```

## Technical Details

### Kernel Configuration

This configuration uses `linuxPackages_rpi4` from nixpkgs-unstable, which provides a generic aarch64 kernel compatible with Raspberry Pi 3, 4, and 5.

```nix
boot.kernelPackages = pkgs.linuxPackages_rpi4;
boot.loader.grub.enable = false;
boot.loader.generic-extlinux-compatible.enable = true;
```

### Resource Optimizations

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

### Boot Issues

1. Connect a monitor to see boot messages
2. Verify SD card is properly formatted
3. Try a fresh flash of the NixOS image

### Memory Issues During Build

```bash
# Check memory usage
free -h
htop

# If builds fail with OOM, add temporary swap
sudo fallocate -l 4G /tmp/swapfile
sudo chmod 600 /tmp/swapfile
sudo mkswap /tmp/swapfile
sudo swapon /tmp/swapfile

# Rebuild
sudo nixos-rebuild switch --flake .#rpi5

# Remove temporary swap
sudo swapoff /tmp/swapfile && rm /tmp/swapfile
```

### Open-WebUI Not Starting

```bash
# Check service status
systemctl status open-webui
journalctl -u open-webui -f

# Check if secrets are decrypted
ls -la /run/agenix/
```

### Tailscale Issues

```bash
# Check status
tailscale status

# Re-authenticate
tailscale up --ssh

# Check serve configuration
tailscale serve status
```

### Network Issues

```bash
# Check interface
ip addr show end0

# Test connectivity
ping -c 3 1.1.1.1
```

## Useful Commands

```bash
# System status
systemctl status

# View logs
journalctl -f

# Check Open-WebUI
systemctl status open-webui
curl -s http://127.0.0.1:8080/health

# Tailscale
tailscale status
tailscale serve status

# Rebuild
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
│                  (nixpkgs-unstable + rpi4 kernel)           │
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
| `hardware-configuration.nix` | Hardware-specific settings (kernel, boot, filesystems) |
| `README.md` | This documentation |