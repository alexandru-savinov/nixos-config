# Raspberry Pi 5 Hardware Configuration
# Uses linuxPackages_rpi4 (generic aarch64 kernel for RPi 3/4/5)
# See: https://nixos.wiki/wiki/NixOS_on_ARM/Raspberry_Pi_5
#
# NOTE: After first boot, verify filesystem UUIDs with:
#   lsblk -f
#   blkid
# and update device paths if needed.

{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  # ============================================================
  # KERNEL CONFIGURATION FOR RPi5
  # ============================================================
  # Use the RPi4 kernel package which supports RPi 3/4/5
  # This is the recommended approach for nixos-unstable
  boot.kernelPackages = pkgs.linuxPackages_rpi4;

  # Raspberry Pi 5 boot configuration
  boot.loader = {
    # Use generic extlinux for RPi compatibility
    grub.enable = false;
    generic-extlinux-compatible.enable = true;

    # Timeout for boot menu
    timeout = 3;
  };

  # Kernel modules
  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "xhci_hcd"
    "usbhid"
    "usb_storage"
    "sd_mod"
    "sdhci_pci"
    # RPi5 specific
    "vc4"
    "bcm2835_dma"
    "i2c_bcm2835"
  ];

  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  # RPi5 kernel parameters
  boot.kernelParams = [
    # Console output
    "console=ttyS0,115200"
    "console=tty1"
    # Reduce GPU memory for headless operation
    "cma=64M"
  ];

  # ============================================================
  # FILESYSTEM CONFIGURATION
  # ============================================================
  # IMPORTANT: Update these device paths/UUIDs after installation!
  # The NixOS SD image uses labels, but you may want to switch to UUIDs

  fileSystems."/" = {
    # Standard NixOS SD image label
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
    options = [ "noatime" "nodiratime" ];
  };

  # Firmware partition (managed by NixOS SD image)
  fileSystems."/boot/firmware" = {
    device = "/dev/disk/by-label/FIRMWARE";
    fsType = "vfat";
    options = [ "fmask=0022" "dmask=0022" "nofail" ];
  };

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
    # Enable GPU drivers (for potential future GUI use)
    graphics.enable = true;

    # Enable firmware for RPi
    enableRedistributableFirmware = true;

    # Raspberry Pi wireless firmware
    firmware = with pkgs; [
      raspberrypiWirelessFirmware
    ];
  };

  # CPU frequency scaling for power management
  powerManagement.cpuFreqGovernor = lib.mkDefault "ondemand";

  # Platform specification
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";

  # ============================================================
  # RPi5 SPECIFIC SETTINGS
  # ============================================================
  # These may need adjustment based on your specific hardware

  # Enable hardware RNG for better entropy
  hardware.cpu.amd.updateMicrocode = lib.mkDefault false;
  hardware.cpu.intel.updateMicrocode = lib.mkDefault false;

  # Network interface - RPi5 uses end0 for ethernet
  networking.interfaces.end0.useDHCP = lib.mkDefault true;
}
