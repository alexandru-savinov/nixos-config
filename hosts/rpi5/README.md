# Raspberry Pi 5 NixOS Configuration

This directory contains the NixOS configuration for a Raspberry Pi 5.

## Prerequisites

- Raspberry Pi 5 (4GB or 8GB recommended)
- MicroSD card (32GB+) or NVMe SSD via M.2 HAT
- Network connectivity (Ethernet recommended for initial setup)
- Another computer to SSH from

## Installation Methods

### Method 1: Using Pre-built NixOS Image (Recommended)

1. **Download NixOS ARM image**
   ```bash
   # Download the latest NixOS aarch64 SD image
   curl -L -o nixos-sd.img.zst https://hydra.nixos.org/job/nixos/release-24.05/nixos.sd_image.aarch64-linux/latest/download-by-type/file/sd-image
   zstd -d nixos-sd.img.zst
   ```

2. **Flash to SD card**
   ```bash
   # Replace /dev/sdX with your SD card device
   sudo dd if=nixos-sd.img of=/dev/sdX bs=4M status=progress conv=fsync
   ```

3. **Boot and SSH into the Pi**
   ```bash
   # Find the Pi's IP (check router or use nmap)
   ssh nixos@<pi-ip>
   # Default password: nixos
   ```

4. **Run the bootstrap script**
   ```bash
   curl -L https://raw.githubusercontent.com/alexandru-savinov/nixos-config/main/scripts/bootstrap.sh | sudo bash -s -- rpi5
   ```

### Method 2: Infect Existing Raspberry Pi OS

1. **Flash Raspberry Pi OS Lite (64-bit)**
   - Use Raspberry Pi Imager
   - Enable SSH in the imager settings
   - Set hostname, username, and password

2. **SSH into the Pi**
   ```bash
   ssh pi@<pi-ip>
   ```

3. **Run the bootstrap script**
   ```bash
   curl -L https://raw.githubusercontent.com/alexandru-savinov/nixos-config/main/scripts/bootstrap.sh | sudo bash -s -- rpi5
   ```

4. **Follow the nixos-infect prompts**
   - The script will convert Raspberry Pi OS to NixOS
   - System will reboot automatically

### Method 3: Manual Installation

1. **Boot NixOS image and SSH in**

2. **Partition the drive**
   ```bash
   # For SD card
   sudo parted /dev/mmcblk0 -- mklabel gpt
   sudo parted /dev/mmcblk0 -- mkpart ESP fat32 1MB 512MB
   sudo parted /dev/mmcblk0 -- set 1 esp on
   sudo parted /dev/mmcblk0 -- mkpart primary ext4 512MB 100%
   
   # Format
   sudo mkfs.fat -F 32 -n NIXOS_BOOT /dev/mmcblk0p1
   sudo mkfs.ext4 -L NIXOS_ROOT /dev/mmcblk0p2
   
   # Mount
   sudo mount /dev/disk/by-label/NIXOS_ROOT /mnt
   sudo mkdir -p /mnt/boot
   sudo mount /dev/disk/by-label/NIXOS_BOOT /mnt/boot
   ```

3. **Generate hardware configuration**
   ```bash
   sudo nixos-generate-config --root /mnt
   ```

4. **Apply this configuration**
   ```bash
   sudo nixos-install --flake github:alexandru-savinov/nixos-config#rpi5
   ```

## Post-Installation Setup

### 1. Update Hardware Configuration

After first boot, generate and update the hardware configuration:

```bash
nixos-generate-config --show-hardware-config > /tmp/hw.nix
```

Update `hardware-configuration.nix` with the correct UUIDs/device paths.

### 2. Add Your SSH Key

Edit `configuration.nix` and add your SSH public key:

```nix
users.users.root.openssh.authorizedKeys.keys = [
  "ssh-ed25519 AAAA... your-key"
];
```

### 3. Update Secrets Configuration

Get the Pi's host key and update `secrets/secrets.nix`:

```bash
# On the Pi
cat /etc/ssh/ssh_host_ed25519_key.pub
```

Replace the placeholder in `secrets/secrets.nix` with the actual key.

### 4. Re-encrypt Secrets

On your development machine with agenix:

```bash
cd secrets
agenix -r  # Re-encrypt all secrets with new key
```

### 5. Rebuild

```bash
sudo nixos-rebuild switch --flake github:alexandru-savinov/nixos-config#rpi5
```

## Tailscale Access

Once configured, you can access the Pi via Tailscale:

```bash
# SSH via Tailscale (no port forwarding needed)
ssh root@rpi5
```

## Hardware Notes

### Performance Optimization

- Use NVMe SSD via M.2 HAT for better performance
- The configuration uses zram for memory compression
- Build jobs are limited to avoid OOM issues

### Power Management

- CPU governor is set to "ondemand" for power efficiency
- Consider active cooling for sustained workloads

### GPIO and Hardware Access

If you need GPIO access, add to configuration:

```nix
users.users.root.extraGroups = [ "gpio" ];
hardware.raspberry-pi."5".gpio.enable = true;
```

## Troubleshooting

### Boot Issues

1. Check the SD card/NVMe is properly formatted
2. Verify boot partition has correct files
3. Connect a monitor to see boot messages

### Network Issues

1. Check Ethernet cable connection
2. Verify DHCP is working: `ip addr`
3. For WiFi, ensure firmware is loaded: `dmesg | grep wifi`

### Build Failures

If builds fail due to memory:

```bash
# Add swap temporarily
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile

# Then rebuild
sudo nixos-rebuild switch --flake .#rpi5
```

## Useful Commands

```bash
# Check system status
systemctl status

# View logs
journalctl -f

# Check Tailscale status
tailscale status

# Rebuild configuration
sudo nixos-rebuild switch --flake github:alexandru-savinov/nixos-config#rpi5

# Update flake inputs
nix flake update

# Garbage collect old generations
sudo nix-collect-garbage -d
```
