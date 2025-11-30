# Raspberry Pi 5 NixOS Configuration

This directory contains the NixOS configuration for a Raspberry Pi 5 running **Open-WebUI** with OpenRouter backend.

> ⚠️ **Important:** This configuration uses [raspberry-pi-nix](https://github.com/nix-community/raspberry-pi-nix) for proper RPi5 kernel, firmware, and device tree support. The standard NixOS aarch64 image has limited RPi5 compatibility.

## Features

- 🌐 **Open-WebUI** with OpenRouter API integration
- 🔍 **Tavily Search** for RAG web search capabilities
- 🔒 **Tailscale** for secure remote access (HTTPS via Tailscale Serve)
- 💾 **Resource optimizations** for RPi5's limited RAM/storage
- 🔐 **Agenix** for encrypted secrets management
- 🐧 **raspberry-pi-nix** with BCM2712 kernel for full RPi5 hardware support

## Prerequisites

- Raspberry Pi 5 (8GB recommended for Open-WebUI)
- MicroSD card (32GB+) or NVMe SSD via M.2 HAT
- Network connectivity (Ethernet recommended for initial setup)
- Another computer for building the SD image

## Installation

### Option A: Build Custom SD Image (Recommended)

This builds a complete SD image with your configuration pre-installed.

**On a Linux machine with Nix (or use the nix-community cachix for faster builds):**

```bash
# Clone the repository
git clone https://github.com/alexandru-savinov/nixos-config.git
cd nixos-config

# Optional: Use cachix for pre-built kernels (saves hours of compile time)
nix-shell -p cachix --run "cachix use nix-community"

# Build the SD image (requires aarch64 emulation or native aarch64)
nix build '.#nixosConfigurations.rpi5.config.system.build.sdImage'

# The image will be at: result/sd-image/nixos-rpi5.img.zst
```

**If you need aarch64 emulation on x86_64:**

```bash
# Add to your /etc/nixos/configuration.nix
boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
```

**Flash the image:**

```bash
# Decompress and flash (Linux/macOS)
zstdcat result/sd-image/nixos-rpi5.img.zst | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync

# Or on Windows: use 7-Zip to extract, then Raspberry Pi Imager to flash
```

### Option B: Flash Generic NixOS, Then Apply Config

If you can't build the custom image, use the generic NixOS aarch64 image:

1. **Download NixOS image:**
   - https://hydra.nixos.org/job/nixos/release-24.05/nixos.sd_image.aarch64-linux/latest/download-by-type/file/sd-image

2. **Flash and boot** (see Windows/Linux instructions below)

3. **SSH in and apply config:**
   ```bash
   ssh nixos@<pi-ip>  # password: nixos
   sudo -i
   
   # Enable flakes
   mkdir -p ~/.config/nix
   echo 'experimental-features = nix-command flakes' >> ~/.config/nix/nix.conf
   
   # Apply configuration
   nixos-rebuild switch --flake github:alexandru-savinov/nixos-config#rpi5
   ```

> ⚠️ **Note:** The generic image may have limited hardware support. The custom SD image (Option A) is strongly recommended.

## Flashing Instructions

### Windows

1. Download and extract the `.img.zst` file using [7-Zip](https://7-zip.org/)
2. Open [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
3. Choose OS → Scroll down → **Use custom** → Select the `.img` file
4. Choose Storage → Select your SD card
5. Click **Write**

### Linux/macOS

```bash
# For custom image
zstdcat nixos-rpi5.img.zst | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync

# For generic NixOS image
zstd -d nixos-sd.img.zst
sudo dd if=nixos-sd.img of=/dev/sdX bs=4M status=progress conv=fsync
```

## First Boot

1. Insert SD card into RPi5
2. Connect Ethernet cable
3. Power on and wait ~2-3 minutes
4. Find the Pi's IP (check router DHCP or `nmap -sn 192.168.1.0/24`)
5. SSH in:
   ```bash
   # Custom image: root with your SSH key
   ssh root@<pi-ip>
   
   # Generic image: nixos / nixos
   ssh nixos@<pi-ip>
   ```

## Post-Installation: Update Secrets

After first boot, you need to update the agenix secrets with the real host key:

```bash
# On the Pi - get the SSH host key
cat /etc/ssh/ssh_host_ed25519_key.pub
# Output: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... root@rpi5
```

Then on your development machine:

1. Edit `secrets/secrets.nix` - replace the `rpi5` placeholder with the real key
2. Re-encrypt secrets:
   ```bash
   cd secrets
   agenix -r
   ```
3. Commit and push
4. On the Pi, rebuild:
   ```bash
   nixos-rebuild switch --flake github:alexandru-savinov/nixos-config#rpi5
   ```

## Technical Details

### raspberry-pi-nix Configuration

```nix
# Board selection (BCM2712 = RPi5)
raspberry-pi-nix.board = "bcm2712";

# Kernel: Uses official Raspberry Pi Linux fork
# Firmware: Managed automatically with config.txt generation
# Boot: U-Boot with proper device tree support
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
2. Verify SD card is properly flashed
3. Try rebuilding the SD image
4. Check if the RPi5 power supply is adequate (5V/5A recommended)

### Memory Issues During Build

```bash
# Check memory usage
free -h
htop

# If builds fail with OOM, the config already includes 4GB swap
# You can add more temporarily:
sudo fallocate -l 4G /tmp/swapfile
sudo chmod 600 /tmp/swapfile
sudo mkswap /tmp/swapfile
sudo swapon /tmp/swapfile

# Rebuild
sudo nixos-rebuild switch --flake .#rpi5
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

### Secrets Not Decrypting

```bash
# Verify host key matches secrets.nix
cat /etc/ssh/ssh_host_ed25519_key.pub

# Check agenix status
ls -la /run/agenix/

# Try manual decryption
agenix -d tailscale-auth-key.age
```

## Using the nix-community Cache

The raspberry-pi-nix project pushes kernel builds to cachix. To avoid compiling the Linux kernel yourself (which takes hours on RPi5):

```bash
# Install cachix
nix-shell -p cachix

# Use the nix-community cache
cachix use nix-community
```

Or add to your NixOS configuration:

```nix
nix.settings = {
  substituters = [ "https://nix-community.cachix.org" ];
  trusted-public-keys = [
    "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
  ];
};
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
│              (raspberry-pi-nix + BCM2712 kernel)            │
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
| `hardware-configuration.nix` | raspberry-pi-nix board config and settings |
| `README.md` | This documentation |

## References

- [raspberry-pi-nix](https://github.com/nix-community/raspberry-pi-nix) - RPi NixOS support
- [NixOS on ARM/Raspberry Pi 5](https://nixos.wiki/wiki/NixOS_on_ARM/Raspberry_Pi_5) - Wiki page
- [nixpkgs#260754](https://github.com/NixOS/nixpkgs/issues/260754) - RPi5 support issue