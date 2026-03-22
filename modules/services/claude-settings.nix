# Claude Code user settings — declarative ~/.claude/settings.json
#
# Manages the user-level Claude Code settings via Home Manager symlink.
# Read-only: runtime changes (plugin enables, etc.) go in the project-level
# .claude/settings.json which is tracked in git.
#
# Usage:
#   services.claude-settings = {
#     enable = true;
#     users = [ "nixos" ];
#   };

{ config, lib, ... }:

let
  inherit (lib) mkEnableOption mkOption mkIf mkDefault types genAttrs;
  cfg = config.services.claude-settings;

  settingsJson = builtins.toJSON {
    skipDangerousModePermissionPrompt = true;
    enabledPlugins = {
      "nix-commit@nixos-config-local" = true;
      "local-review@nixos-config-local" = true;
      "screenshot@nixos-config-local" = true;
      "nixd-lsp@nixos-config-local" = true;
      "frontend-design@claude-plugins-official" = true;
      "claude-code-setup@claude-plugins-official" = true;
    };
    env = {
      ENABLE_LSP_TOOL = "1";
    };
  };
in
{
  options.services.claude-settings = {
    enable = mkEnableOption "declarative Claude Code user settings";

    users = mkOption {
      type = types.listOf types.str;
      default = [ "nixos" ];
      description = "Users to manage Claude Code settings for.";
    };
  };

  config = mkIf cfg.enable {
    home-manager.users = genAttrs cfg.users (_: {
      home.stateVersion = mkDefault "24.05";
      home.file.".claude/settings.json".text = settingsJson;
    });
  };
}
