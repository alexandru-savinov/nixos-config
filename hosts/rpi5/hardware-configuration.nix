# Raspberry Pi 5 Hardware Configuration
# This file contains hardware-specific settings for the Raspberry Pi 5
#
# NOTE: After first boot, you should regenerate this with:
#   nixos-generate-config --show-hardware-config
# and update the UUIDs/device paths accordingly.

{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  # Raspberry Pi 5 boot configuration
  # Uses UEFI boot via the Pi's firmware
  boot.loader = {
    # Use systemd-boot for UEFI boot (works with RPi5's UEFI firmware)
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = false;

    # Alternative: Use generic extlinux (more compatible with RPi)
    # generic-extlinux-compatible.enable = true;

    # Timeout for boot menu
    timeout = 3;
  };

  # Kernel configuration for RPi5
  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "usbhid"
    "usb_storage"
    "sd_mod"
    "sdhci_pci"
  ];

  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  # RPi5 specific kernel parameters
  boot.kernelParams = [
    # Console output
    "console=tty1"
    # Reduce GPU memory for headless operation (16MB minimum)
    "cma=64M"
  ];

  # Filesystem configuration
  # IMPORTANT: Update these device paths/UUIDs after installation!
  # Use `lsblk -f` or `blkid` to find correct values
  fileSystems."/" = {
    # For SD card: typically /dev/mmcblk0p2
    # For NVMe (via HAT): typically /dev/nvme0n1p2
    # For USB drive: typically /dev/sda2
    device = "/dev/disk/by-label/NIXOS_ROOT";
    fsType = "ext4";
    options = [ "noatime" "nodiratime" ];
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/NIXOS_BOOT";
    fsType = "vfat";
    options = [ "fmask=0022" "dmask=0022" ];
  };

  # Swap configuration (recommended for RPi with limited RAM)
  swapDevices = [
    # Swap file (more flexible than partition)
    # { device = "/swapfile"; size = 2048; }
  ];

  # Enable zram for better memory management (already in common.nix but can override)
  zramSwap = {
    enable = true;
    memoryPercent = 50; # Use up to 50% of RAM for compressed swap
  };

  # Hardware-specific settings
  hardware = {
    # Enable hardware video acceleration (opengl for NixOS 24.05)
    opengl.enable = true;

    # Enable firmware for RPi
    enableRedistributableFirmware = true;

    # Raspberry Pi specific firmware
    firmware = with pkgs; [
      raspberrypiWirelessFirmware
    ];
  };

  # CPU frequency scaling for power management
  powerManagement.cpuFreqGovernor = lib.mkDefault "ondemand";

  # Platform specification
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
}
