# Raspberry Pi 5 Hardware Configuration
# Uses raspberry-pi-nix for proper kernel, firmware, and device tree support
# See: https://github.com/nix-community/raspberry-pi-nix
#
# This configuration works with the SD image built by raspberry-pi-nix

{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  # ============================================================
  # RASPBERRY PI 5 BOARD CONFIGURATION
  # ============================================================
  # bcm2711 for rpi 3, 3+, 4, zero 2 w
  # bcm2712 for rpi 5
  raspberry-pi-nix.board = "bcm2712";

  # ============================================================
  # FILESYSTEM CONFIGURATION
  # ============================================================
  # raspberry-pi-nix SD image uses NIXOS_SD label for root
  # The firmware partition is managed automatically

  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
    options = [ "noatime" "nodiratime" ];
  };

  # Firmware partition is managed by raspberry-pi-nix
  # It automatically updates firmware and config.txt

  # ============================================================
  # SWAP CONFIGURATION
  # ============================================================
  # Swap file is configured in configuration.nix
  # zram is also enabled there
  swapDevices = [ ];

  # ============================================================
  # HARDWARE SETTINGS
  # ============================================================
  hardware = {
    # Enable GPU drivers (opengl for NixOS 24.05)
    opengl.enable = true;

    # Enable firmware for RPi (handled by raspberry-pi-nix)
    enableRedistributableFirmware = true;
  };

  # CPU frequency scaling for power management
  powerManagement.cpuFreqGovernor = lib.mkDefault "ondemand";

  # Platform specification
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";

  # ============================================================
  # RASPBERRY PI CONFIG.TXT SETTINGS
  # ============================================================
  # These settings are managed by raspberry-pi-nix and written to config.txt
  # on the firmware partition

  hardware.raspberry-pi.config = {
    all = {
      options = {
        # 64-bit mode
        arm_64bit = {
          enable = true;
          value = true;
        };
        # Enable UART for serial console debugging
        enable_uart = {
          enable = true;
          value = true;
        };
        # Disable warning overlays
        avoid_warnings = {
          enable = true;
          value = true;
        };
        # Disable overscan
        disable_overscan = {
          enable = true;
          value = true;
        };
      };
      # Device tree parameters
      base-dt-params = {
        # Enable Bluetooth
        krnbt = {
          enable = true;
          value = "on";
        };
      };
      # GPU overlay for headless operation
      dt-overlays = {
        vc4-kms-v3d = {
          enable = true;
          params = { };
        };
      };
    };
  };
}
