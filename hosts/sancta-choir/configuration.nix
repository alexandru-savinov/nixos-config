{ config
, pkgs
, lib
, self
, claude-code
, ...
}:

{
  # Pin kernel to 6.6 LTS to avoid store corruption from incomplete 6.12 build
  boot.kernelPackages = pkgs.linuxPackages_6_6;

  # Enable aarch64 emulation for cross-building RPi5 images
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  # Add nix-community cache for pre-built RPi5 kernels
  # Also add claude-code cachix for pre-built Claude Code binaries
  nix.settings = {
    substituters = [
      "https://cache.nixos.org"
      "https://nix-community.cachix.org"
      "https://claude-code.cachix.org"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "claude-code.cachix.org-1:p3pMxGi7K+xT7I3dLghdlrUijD8s+wfQlmWp8gQ/TJA="
    ];
  };

  imports = [
    ./hardware-configuration.nix
    ../common.nix
    ../../modules/system/host.nix
    ../../modules/system/networking.nix
    ../../modules/system/dev-tools.nix
    ../../modules/users/root.nix
    ../../modules/services/claude.nix
    ../../modules/services/tailscale.nix
    # Disable old container-based OpenClaw (replaced with nix-openclaw)
    # ../../modules/services/openclaw-container.nix
  ];

  # Enable development tools and Claude Code
  customModules.dev-tools.enable = true;
  customModules.claude.enable = true;

  # Agenix secrets (defaults: owner=root, group=root, mode=0400)
  age.secrets = {
    tailscale-auth-key.file = "${self}/secrets/tailscale-auth-key.age";
  };

  # Home Manager settings (root user config provided by modules/users/root.nix)
  # nix-openclaw Home Manager integration disabled — upstream bird2/bird3
  # alias bug (same issue as sancta-kuzea). Will use npm install instead.
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
  };

  # Swap space (prevents OOM during builds on 4GB VPS)
  swapDevices = [
    {
      device = "/swapfile";
      size = 2048; # 2GB
    }
  ];

  # Hostname
  networking.hostName = "sancta-choir";
  networking.domain = "";

  # SSH authorized keys for remote access
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPw5RFrFfZQUWlyfGSU1Q8BlEHnvIdBtcnCn+uYtEzal nixos-sancta-choir"
  ];

  # Fresh install — NixOS 25.05
  system.stateVersion = lib.mkForce "25.05";
}
