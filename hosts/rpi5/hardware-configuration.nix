# Raspberry Pi 5 Hardware Configuration
# Simplified version using generic aarch64 kernel (no raspberry-pi-nix)
# Works with nixos-infect from Raspberry Pi OS

{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  # ============================================================
  # BOOT CONFIGURATION
  # ============================================================
  # Use the extlinux bootloader (works with RPi firmware)
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;

  # Use the generic aarch64 kernel (or rpi4 kernel for better Pi support)
  # The rpi4 kernel also works on Pi 5 and has better hardware support
  boot.kernelPackages = pkgs.linuxPackages_rpi4;

  # Kernel parameters for Raspberry Pi
  boot.kernelParams = [
    "console=ttyAMA0,115200"
    "console=tty1"
  ];

  # ============================================================
  # FILESYSTEM CONFIGURATION
  # ============================================================
  # nixos-infect will set this up based on the existing partitions
  # These are placeholders - nixos-infect will generate the real ones

  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
    options = [ "noatime" "nodiratime" ];
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/NIXOS_BOOT";
    fsType = "vfat";
  };

  # ============================================================
  # SWAP CONFIGURATION
  # ============================================================
  swapDevices = [ ];

  # ============================================================
  # HARDWARE SETTINGS
  # ============================================================
  hardware = {
    # Enable GPU (OpenGL)
    opengl.enable = true;

    # Enable firmware for WiFi, Bluetooth, etc.
    enableRedistributableFirmware = true;
    firmware = [ pkgs.raspberrypiWirelessFirmware ];
  };

  # CPU frequency scaling
  powerManagement.cpuFreqGovernor = lib.mkDefault "ondemand";

  # Platform specification
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
}
