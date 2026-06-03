{ lib
, self
, ...
}:

{
  imports = [
    ./hardware-configuration.nix
    ./disk-config.nix
    ./hermes-service.nix
    ../common.nix
    ../../modules/system/nix-ld.nix
    ../../modules/users/root.nix
    ../../modules/services/tailscale.nix
    ../../modules/system/ssh-hardened.nix
  ];

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # ── Networking (Hetzner Cloud — DHCP for DR portability) ────────────────
  networking = {
    hostName = "hermes-claw";
    useDHCP = true;
    usePredictableInterfaceNames = lib.mkForce false;
    nameservers = [ "8.8.8.8" "185.12.64.1" "185.12.64.2" ];
    # Firewall: SSH only on public interface, Tailscale trusted
    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 ];
    };
  };

  # Time zone
  time.timeZone = "Europe/Chisinau";
  i18n.defaultLocale = "en_US.UTF-8";

  # ── Agenix Secrets ──────────────────────────────────────────────────────
  # Use stable age recovery key (not SSH host key) for secret decryption.
  # Placed by nixos-anywhere --extra-files during DR.
  age.identityPaths = [ "/root/.age/recovery.key" ];
  age.secrets =
    let
      inherit (import ../../lib/secrets.nix { inherit self; }) secret;
    in
    {
      tailscale-auth-key = secret "tailscale-auth-key";
    };

  # ── Home Manager (scaffolding — required by root.nix, no user configs yet) ──
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
  };

  # ── Swap (4GB — OOM headroom for builds/manual switch on this CX33 GRUB VPS) ──
  # No disk swap otherwise (only RAM-backed zram from common.nix, useless under a
  # build RSS spike). Mirrors sancta-choir; guards against the #451/#252 build-OOM
  # brick on a remote GRUB host. No kernel pin — hermes-claw has no corrupted-store
  # history, and a prophylactic pin would just be unretired maintenance debt.
  swapDevices = [
    {
      device = "/swapfile";
      size = 4096; # 4GB
    }
  ];

  # ── SSH authorized keys (cross-host management from sancta-choir + rpi5) ──
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPw5RFrFfZQUWlyfGSU1Q8BlEHnvIdBtcnCn+uYtEzal nixos-sancta-choir"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL2btaYomBlcKG+snrIrBuTXcEaBKEGQoAaF59YWwkal nixos@rpi5"
  ];

  # ── Automatic security updates ──────────────────────────────────────────
  # Disabled until first successful manual deploy + verify (per Task 7).
  # Will be enabled in a follow-up PR after the host has run unattended for ≥48h.
  system.autoUpgrade.enable = false;

  # Fresh install — NixOS 25.11
  system.stateVersion = "25.11";
}
