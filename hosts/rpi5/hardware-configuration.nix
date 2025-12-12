# Raspberry Pi 5 Hardware Configuration
# Uses raspberry-pi-nix for proper Pi 5 kernel with RP1 SD controller support
# See: https://github.com/nix-community/raspberry-pi-nix

{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  # ============================================================
  # BOOT CONFIGURATION
  # ============================================================
  # raspberry-pi-nix handles boot configuration automatically
  # It sets up the correct kernel, firmware, and device trees for Pi 5

  # Kernel parameters for Raspberry Pi
  boot.kernelParams = [
    "console=ttyAMA10,115200" # Pi 5 uses ttyAMA10 for serial
    "console=tty1"
  ];

  # ============================================================
  # FILESYSTEM CONFIGURATION
  # ============================================================
  # raspberry-pi-nix SD image will set these up automatically
  # These are defaults that work with the generated SD image

  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
    options = [ "noatime" "nodiratime" ];
  };

  # Boot partition is managed by raspberry-pi-nix
  # It handles firmware, kernel, and config.txt automatically

  # ============================================================
  # SWAP CONFIGURATION
  # ============================================================
  swapDevices = [ ];

  # ============================================================
  # HARDWARE SETTINGS
  # ============================================================
  hardware = {
    # raspberry-pi-nix handles GPU and firmware automatically
    # Enable redistributable firmware for WiFi, Bluetooth, etc.
    enableRedistributableFirmware = true;
  };

  # CPU frequency scaling
  powerManagement.cpuFreqGovernor = lib.mkDefault "ondemand";

  # Platform specification
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
}
