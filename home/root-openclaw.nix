{ config, pkgs, nix-openclaw, ... }:

{
  # Import nix-openclaw home-manager module
  imports = [
    nix-openclaw.homeManagerModules.default
  ];

  # Enable OpenClaw
  programs.openclaw = {
    enable = true;

    config = {
      # Gateway configuration
      gateway = {
        mode = "local";
        auth = {
          # Will be generated on first run or via onboarding
          tokenFile = "/root/.openclaw/gateway-token";
        };
      };

      # Telegram channel configuration
      channels.telegram = {
        # Token will be provided via onboarding wizard
        tokenFile = "/run/agenix/telegram-bot-token";
        # DM policy: require pairing for security
        dmPolicy = "pairing";
        # Can also use allowlist:
        # allowFrom = [ 123456789 ]; # Your Telegram user ID
      };

      # Model provider (Anthropic)
      env = {
        ANTHROPIC_API_KEY_FILE = "/run/agenix/anthropic-api-key";
      };
    };

    # Enable bundled plugins
    bundledPlugins = {
      peekaboo = true;     # Screenshot/vision tools
      summarize = true;    # Text summarization
      oracle = true;       # General knowledge
      webSearch = true;    # Web search capability
    };
  };

  # Home Manager state version
  home.stateVersion = "24.11";
}
