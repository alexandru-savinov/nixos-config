{ config
, pkgs
, lib
, self
, claude-code
, nix-openclaw
, ...
}:

{
  # Add nix-openclaw overlay to provide pkgs.openclaw
  nixpkgs.overlays = [
    nix-openclaw.overlays.default
  ];

  imports = [
    ./hardware-configuration.nix
    ../common.nix
    ../../modules/system/host.nix
    ../../modules/system/networking.nix
    ../../modules/system/dev-tools.nix
    ../../modules/users/root.nix
    ../../modules/services/claude.nix
    ../../modules/services/tailscale.nix
    # Using nix-openclaw instead of custom container-based OpenClaw
    # ../../modules/services/openclaw-container.nix
  ];

  # Enable development tools and Claude Code
  customModules.dev-tools.enable = true;
  customModules.claude.enable = true;

  # Agenix secrets (defaults: owner=root, group=root, mode=0400)
  age.secrets = {
    tailscale-auth-key.file = "${self}/secrets/tailscale-auth-key.age";
    # API keys and tokens will be configured during OpenClaw onboarding
    # anthropic-api-key.file = "${self}/secrets/anthropic-api-key.age";
    # telegram-bot-token.file = "${self}/secrets/telegram-bot-token.age";
  };

  # Home Manager for root user (Official OpenClaw with Telegram)
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    users.root = import ../../home/root-openclaw.nix;
    extraSpecialArgs = { inherit self nix-openclaw; };
  };

  # CRITICAL: Keep hostname as "sancta-choir" for Phase 1 deployment
  # This maintains Tailscale access during migration
  # Will be changed to "sancta-kuzea" in Phase 2 after verification
  networking.hostName = "sancta-choir";
  networking.domain = "";

  # Swap space (prevents OOM during builds on 4GB VPS)
  # 2GB swap provides buffer for memory-intensive builds (Node.js, Rust, etc)
  swapDevices = [
    {
      device = "/swapfile";
      size = 2048; # 2GB
    }
  ];

  # SSH authorized keys for remote access
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPw5RFrFfZQUWlyfGSU1Q8BlEHnvIdBtcnCn+uYtEzal nixos-sancta-choir"
  ];

  # Override stateVersion from common.nix
  system.stateVersion = lib.mkForce "24.11";
}
