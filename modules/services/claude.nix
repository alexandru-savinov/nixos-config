{ config, pkgs, lib, claude-code ? null, ... }:

let
  cfg = config.customModules.claude;
in
{
  # Claude Code - AI-powered coding assistant
  # Auto-updated hourly via github:sadjow/claude-code-nix flake
  #
  # IMPORTANT: This module requires the claude-code flake input to be passed via specialArgs:
  #   specialArgs = { inherit claude-code; };
  # See flake.nix for an example.

  options.customModules.claude = {
    enable = lib.mkEnableOption "Claude Code package";

    agentTeams = {
      enable = lib.mkEnableOption "Claude Code Agent Teams (experimental)";

      teammateMode = lib.mkOption {
        type = lib.types.enum [ "auto" "in-process" "tmux" ];
        default = "auto";
        description = ''
          Display mode for agent team teammates.
          - "auto": split panes if running in tmux, in-process otherwise
          - "in-process": all teammates in the main terminal (Shift+Up/Down to navigate)
          - "tmux": force split-pane mode (requires tmux)
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = claude-code != null;
          message = ''
            The claude module requires the claude-code flake input to be passed via specialArgs.

            Add this to your flake inputs:
              claude-code = {
                url = "github:sadjow/claude-code-nix";
                inputs.nixpkgs.follows = "nixpkgs-unstable";
              };

            Then pass it to specialArgs in your nixosSystem:
              specialArgs = { inherit claude-code; };
          '';
        }
      ];

      environment.systemPackages = [
        claude-code.packages.${pkgs.system}.default
      ];
    }

    (lib.mkIf cfg.agentTeams.enable {
      environment.sessionVariables = {
        CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1";
      };

      # teammateMode is a Claude Code settings.json key (no env var equivalent).
      # Use --teammate-mode flag per session, or set in ~/.claude/settings.json:
      #   { "teammateMode": "in-process" }
      # The "auto" default uses split panes when inside tmux, in-process otherwise.
      # tmux is provided by customModules.dev-tools.
    })
  ]);
}
