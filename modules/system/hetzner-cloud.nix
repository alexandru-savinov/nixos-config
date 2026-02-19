# Shared NixOS module for Hetzner Cloud VPS instances
# Consolidates boot, networking, SSH, and firewall configuration
#
# Usage in host config:
#   imports = [ ../../modules/system/hetzner-cloud.nix ];
#   hetzner-cloud.enable = true;
#   hetzner-cloud.ipv4Address = "1.2.3.4";
#   hetzner-cloud.macAddress = "aa:bb:cc:dd:ee:ff";  # optional

{ config, pkgs, lib, modulesPath, ... }:

let
  cfg = config.hetzner-cloud;
in
{
  # QEMU guest profile must be at top level (imports can't be conditional)
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  options.hetzner-cloud = {
    enable = lib.mkEnableOption "Hetzner Cloud VPS configuration";

    ipv4Address = lib.mkOption {
      type = lib.types.str;
      description = "Static IPv4 address assigned by Hetzner";
      example = "116.203.223.113";
    };

    ipv4Gateway = lib.mkOption {
      type = lib.types.str;
      default = "172.31.1.1";
      description = "IPv4 gateway (Hetzner Cloud default is 172.31.1.1)";
    };

    macAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "MAC address for udev eth0 binding (optional)";
      example = "92:00:06:bb:96:03";
    };

    nameservers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "185.12.64.1" "185.12.64.2" ];
      description = "DNS nameservers (defaults to Hetzner DNS)";
    };
  };

  config = lib.mkIf cfg.enable {
    # ── Boot ─────────────────────────────────────────────────────
    boot.loader.grub.device = "/dev/sda";
    boot.initrd.availableKernelModules = [ "ata_piix" "uhci_hcd" "xen_blkfront" "vmw_pvscsi" ];
    boot.initrd.kernelModules = [ "nvme" ];

    # ── Networking ───────────────────────────────────────────────
    networking.useDHCP = false;
    networking.usePredictableInterfaceNames = lib.mkForce false;
    networking.dhcpcd.enable = false;
    networking.nameservers = cfg.nameservers;

    networking.interfaces.eth0 = {
      useDHCP = false;
      ipv4.addresses = [{
        address = cfg.ipv4Address;
        prefixLength = 32;
      }];
      ipv4.routes = [{ address = cfg.ipv4Gateway; prefixLength = 32; }];
    };

    networking.defaultGateway = {
      address = cfg.ipv4Gateway;
      interface = "eth0";
    };

    # MAC address binding (stable interface naming)
    services.udev.extraRules = lib.mkIf (cfg.macAddress != null) ''
      ATTR{address}=="${cfg.macAddress}", NAME="eth0"
    '';

    # ── Swap ─────────────────────────────────────────────────────
    swapDevices = [{
      device = "/swapfile";
      size = 2048; # 2GB — prevents OOM during builds on 4GB VPS
    }];

    # ── SSH ──────────────────────────────────────────────────────
    services.openssh = {
      enable = true;
      settings = {
        PermitRootLogin = "prohibit-password";
        PasswordAuthentication = false;
      };
    };

    # ── Firewall ─────────────────────────────────────────────────
    networking.firewall.enable = true;
    networking.firewall.allowedTCPPorts = [ 22 ];

    # ── Filesystem (for existing instances without disko) ────────
    # New instances should use hetzner-disko.nix instead
    fileSystems."/" = lib.mkDefault { device = "/dev/sda1"; fsType = "ext4"; };
  };
}
