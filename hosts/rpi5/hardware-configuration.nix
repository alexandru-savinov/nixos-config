# Raspberry Pi 5 Hardware Configuration
# Corrected for NVMe SSD root + SD card boot (hybrid setup)
#
# This replaces the repo's hosts/rpi5/hardware-configuration.nix
# which incorrectly uses NIXOS_SD label (SD card partition)
#
# Current setup:
#   - Boot/Firmware: SD card (mmcblk0p1, label FIRMWARE)
#   - Root filesystem: NVMe SSD (nvme0n1p2, label NIXOS)
#
# Uses lib.mkForce to override raspberry-pi-nix defaults from sd-image.nix

{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  # ============================================================
  # BOOT CONFIGURATION
  # ============================================================
  # raspberry-pi-nix handles kernel and device trees
  # but we need to preserve the hybrid boot setup

  boot.initrd.availableKernelModules = [ "nvme" "usbhid" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  # Kernel parameters for Raspberry Pi 5
  boot.kernelParams = [
    "console=ttyAMA10,115200"  # Pi 5 uses ttyAMA10 for serial
    "console=tty1"
  ];

  # ============================================================
  # FILESYSTEM CONFIGURATION
  # ============================================================

  # Root filesystem - NVMe SSD (NOT the SD card!)
  # Use mkForce to override raspberry-pi-nix sd-image.nix defaults
  fileSystems."/" = lib.mkForce {
    device = "/dev/disk/by-uuid/344d4f56-d1a1-4df3-a0d3-aa22cab48ffc";
    fsType = "ext4";
    options = [ "noatime" "nodiratime" ];
  };

  # Boot/Firmware partition - SD card (hybrid boot setup)
  # Pi 5 boots from SD card, then pivots to NVMe root
  fileSystems."/boot/firmware" = lib.mkForce {
    device = "/dev/disk/by-label/FIRMWARE";
    fsType = "vfat";
    options = [ "defaults" ];
  };

  # ============================================================
  # SWAP CONFIGURATION
  # ============================================================
  # Swap file on NVMe for better performance
  swapDevices = lib.mkForce [
    { device = "/var/swapfile"; }
  ];

  # ============================================================
  # HARDWARE SETTINGS
  # ============================================================
  hardware = {
    # Enable redistributable firmware for WiFi, Bluetooth, etc.
    enableRedistributableFirmware = true;
  };

  # CPU frequency scaling
  powerManagement.cpuFreqGovernor = lib.mkDefault "ondemand";

  # DHCP enabled by default
  networking.useDHCP = lib.mkDefault true;

  # Platform specification
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
}
