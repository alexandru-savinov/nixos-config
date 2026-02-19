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
    ../common.nix
    ../../modules/system/hetzner-cloud.nix
    ../../modules/system/dev-tools.nix
    ../../modules/users/root.nix
    ../../modules/services/claude.nix
    ../../modules/services/tailscale.nix
  ];

  # Hetzner Cloud VPS configuration (shares IP with sancta-choir during migration)
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

  # CRITICAL: Keep hostname as "sancta-choir" for Phase 1 deployment
  # This maintains Tailscale access during migration
  # Will be changed to "sancta-kuzea" in Phase 2 after verification
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

  # Override stateVersion from common.nix
  system.stateVersion = lib.mkForce "24.11";
}
