{ config, pkgs, lib, nix-openclaw, ... }:

{
  # Import nix-openclaw home-manager module
  imports = [
    nix-openclaw.homeManagerModules.openclaw
  ];

  # Enable OpenClaw with minimal configuration
  # Full configuration will be done via 'openclaw onboard' wizard
  programs.openclaw = {
    enable = true;

    # Configuration will be managed by onboarding wizard
    # The wizard creates ~/.openclaw/config.json with:
    # - Gateway auth token
    # - Telegram bot token
    # - Anthropic API key
    # - Channel configurations
  };

  # Home Manager state version (use mkForce to override modules/users/root.nix)
  home.stateVersion = lib.mkForce "24.11";
}
