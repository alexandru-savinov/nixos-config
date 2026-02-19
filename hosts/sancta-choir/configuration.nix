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
    ../common.nix
    ../../modules/system/hetzner-cloud.nix
    ../../modules/system/dev-tools.nix
    ../../modules/users/root.nix
    ../../modules/services/claude.nix
    ../../modules/services/tailscale.nix
  ];

  # Hetzner Cloud VPS configuration
  hetzner-cloud = {
    enable = true;
    ipv4Address = "116.203.223.113";
    macAddress = "92:00:06:bb:96:03";
  };

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # Enable development tools and Claude Code
  customModules.dev-tools.enable = true;
  customModules.claude.enable = true;

  # Agenix secrets (defaults: owner=root, group=root, mode=0400)
  age.secrets = {
    tailscale-auth-key.file = "${self}/secrets/tailscale-auth-key.age";
    # These secrets will be created during OpenClaw onboarding
    # anthropic-api-key.file = "${self}/secrets/anthropic-api-key.age";
    # telegram-bot-token.file = "${self}/secrets/telegram-bot-token.age";
  };

  # Home Manager for root user (OpenClaw)
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    users.root = import ../../home/root-openclaw.nix;
    extraSpecialArgs = { inherit self nix-openclaw; };
  };

  # Hostname
  networking.hostName = "sancta-choir";
  networking.domain = "";

  # VSCode Server support
  services.vscode-server.enable = true;

  # Time zone and locale
  time.timeZone = "Europe/Chisinau";
  i18n.defaultLocale = "en_US.UTF-8";

  # SSH authorized keys for remote access
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPw5RFrFfZQUWlyfGSU1Q8BlEHnvIdBtcnCn+uYtEzal nixos-sancta-choir"
  ];
}
