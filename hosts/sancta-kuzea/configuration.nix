{ config
, pkgs
, lib
, self
, claude-code
, nix-openclaw
, ...
}:

{
  imports = [
    ./hardware-configuration.nix
    ../common.nix
    ../../modules/system/host.nix
    ../../modules/system/networking.nix
    ../../modules/system/dev-tools.nix
    ../../modules/users/root.nix
    ../../modules/services/claude.nix
    ../../modules/services/tailscale.nix
    # Will install Official OpenClaw via npm instead of nix-openclaw
    # nix-openclaw has upstream bugs (bird2/bird3 ambiguity)
  ];

  # Enable development tools and Claude Code
  customModules.dev-tools.enable = true;
  customModules.claude.enable = true;

  # Build tools for OpenClaw npm installation (llama.cpp compilation)
  environment.systemPackages = with pkgs; [
    cmake
    gnumake
    gcc
    python3
  ];

  # Agenix secrets (defaults: owner=root, group=root, mode=0400)
  age.secrets = {
    tailscale-auth-key.file = "${self}/secrets/tailscale-auth-key.age";
    # API keys and tokens will be configured during OpenClaw onboarding
    # anthropic-api-key.file = "${self}/secrets/anthropic-api-key.age";
    # telegram-bot-token.file = "${self}/secrets/telegram-bot-token.age";
  };

  # OpenClaw will be installed via npm globally after deployment
  # Run: npm install -g openclaw@latest --prefix /usr/local
  # Then: openclaw onboard --flow quickstart

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
