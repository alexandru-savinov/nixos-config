{ config
, pkgs
, lib
, self
, claude-code
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
    ../../modules/services/openclaw-container.nix
  ];

  # Enable development tools and Claude Code
  customModules.dev-tools.enable = true;
  customModules.claude.enable = true;

  # Agenix secrets (defaults: owner=root, group=root, mode=0400)
  age.secrets = {
    tailscale-auth-key.file = "${self}/secrets/tailscale-auth-key.age";
    anthropic-api-key.file = "${self}/secrets/anthropic-api-key.age";
    openclaw-github-token.file = "${self}/secrets/openclaw-github-token.age";
  };

  # OpenClaw in systemd-nspawn container (main purpose of this host)
  services.openclaw-container = {
    enable = true;
    anthropicApiKeyFile = config.age.secrets.anthropic-api-key.path;
    githubTokenFile = config.age.secrets.openclaw-github-token.path;
    repoUrl = "https://github.com/alexandru-savinov/nixos-config.git";
    repoBranch = "main";
    model = "sonnet";
    maxTurns = 50;
    maxBudgetUsd = 5.0;
  };

  # CRITICAL: Keep hostname as "sancta-choir" for Phase 1 deployment
  # This maintains Tailscale access during migration
  # Will be changed to "sancta-kuzea" in Phase 2 after verification
  networking.hostName = "sancta-choir";
  networking.domain = "";

  # SSH authorized keys for remote access
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPw5RFrFfZQUWlyfGSU1Q8BlEHnvIdBtcnCn+uYtEzal nixos-sancta-choir"
  ];

  # Override stateVersion from common.nix
  system.stateVersion = lib.mkForce "24.11";
}
