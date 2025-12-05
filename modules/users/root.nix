{ config, pkgs, pkgs-unstable, lib, ... }:

{
  # Home Manager configuration for root user
  home-manager.users.root = {
    home.stateVersion = "24.05";

    # Add ~/.local/bin to PATH for user-installed binaries (e.g., opencode)
    home.sessionPath = [ "$HOME/.local/bin" ];

    # OpenCode configuration - uses Open WebUI as LLM gateway
    # API key is read from agenix-managed secret at runtime via {file:...} syntax
    xdg.configFile."opencode/opencode.json".text = builtins.toJSON {
      "$schema" = "https://opencode.ai/config.json";
      autoupdate = false;  # Managed by Zed or manual updates
      provider = {
        openwebui = {
          npm = "@ai-sdk/openai-compatible";
          name = "Open WebUI";
          options = {
            baseURL = "https://sancta-choir.tail4249a9.ts.net/api";
            apiKey = "{file:/run/agenix/opencode-api-key}";
          };
          models = {
            "openrouter/anthropic/claude-sonnet-4" = {
              name = "Claude Sonnet 4 (via OpenRouter)";
              limit = {
                context = 200000;
                output = 16384;
              };
            };
            "openrouter/anthropic/claude-opus-4" = {
              name = "Claude Opus 4 (via OpenRouter)";
              limit = {
                context = 200000;
                output = 32000;
              };
            };
            "openrouter/google/gemini-2.5-pro" = {
              name = "Gemini 2.5 Pro (via OpenRouter)";
              limit = {
                context = 1000000;
                output = 65536;
              };
            };
          };
        };
      };
      model = "openwebui/openrouter/anthropic/claude-sonnet-4";
    };

    # Additional user-specific home-manager configs can go here
    programs.git = {
      enable = true;
      # Git config is already set via .gitconfig, just enable HM management
    };

    # Bash configuration
    programs.bash = {
      enable = true;
      # Use NixOS-managed copilot instead of VS Code's older bundled version
      # VS Code adds its shim to PATH first, so we override with an alias
      shellAliases = {
        copilot = "${pkgs-unstable.github-copilot-cli}/bin/copilot";
      };
    };
  };
}
