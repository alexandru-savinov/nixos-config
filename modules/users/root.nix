{ config, pkgs, pkgs-unstable, lib, ... }:

{
  # Home Manager configuration for root user
  home-manager.users.root = {
    home.stateVersion = "24.05";

    # Add ~/.local/bin to PATH for user-installed binaries (e.g., opencode)
    home.sessionPath = [ "$HOME/.local/bin" ];

    # Opencode wrapper: always runs the latest available binary installed by Zed
    # This handles version changes automatically when Zed updates the agent
    home.file.".local/bin/opencode" = {
      executable = true;
      text = ''
        #!/bin/sh
        exec "$(find "$HOME/.local/share/zed/external_agents/opencode/opencode" -name opencode -type f -executable 2>/dev/null | sort -V | tail -n1)" "$@"
      '';
    };

    # OpenCode configuration - uses Open WebUI as LLM gateway
    # API key is read from agenix-managed secret at runtime via {file:...} syntax
    xdg.configFile."opencode/opencode.json".text = builtins.toJSON {
      "$schema" = "https://opencode.ai/config.json";
      autoupdate = false; # Managed by Zed or manual updates
      provider = {
        openwebui = {
          npm = "@ai-sdk/openai-compatible";
          name = "Open WebUI";
          options = {
            baseURL = "https://sancta-choir.tail4249a9.ts.net/api";
            apiKey = "{file:/run/agenix/opencode-api-key}";
          };
          models = {
            "anthropic/claude-sonnet-4" = {
              name = "Claude Sonnet 4";
              limit = {
                context = 200000;
                output = 16384;
              };
            };
            "anthropic/claude-opus-4" = {
              name = "Claude Opus 4";
              limit = {
                context = 200000;
                output = 32000;
              };
            };
            "google/gemini-2.5-pro-preview" = {
              name = "Gemini 2.5 Pro";
              limit = {
                context = 1000000;
                output = 65536;
              };
            };
          };
        };
      };
      model = "openwebui/anthropic/claude-sonnet-4";
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
