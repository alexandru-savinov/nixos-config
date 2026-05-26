# Claude Code via the `claude-shared` flake — replaces the in-repo
# claude{,-settings,-skills,-agents}.nix modules. Installs the CC package
# (from claude-shared's own claude-code input) and wires user-level config
# (settings, skills, agents, commands) into ~/.claude/ via HM symlinks.
#
# Requires the `claude-shared` flake input passed via specialArgs:
#   specialArgs = { inherit claude-shared; };
#
# Usage:
#   customModules.claudeShared = {
#     enable = true;
#     users = [ "nixos" ];
#   };
{ config, lib, claude-shared ? null, ... }:

let
  inherit (lib) mkEnableOption mkOption types mkIf genAttrs;
  cfg = config.customModules.claudeShared;
in
{
  options.customModules.claudeShared = {
    enable = mkEnableOption "Claude Code via claude-shared (package + user config)";

    users = mkOption {
      type = types.listOf types.str;
      default = [ "nixos" ];
      description = "Users to configure Claude Code for.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = claude-shared != null;
        message = ''
          customModules.claudeShared.enable requires the `claude-shared`
          flake input passed via specialArgs.

          Add to flake.nix:
            claude-shared.url = "github:alexandru-savinov/claude-shared";
            ... specialArgs = { inherit claude-shared; }; ...
        '';
      }
    ];

    home-manager.users = genAttrs cfg.users (_: {
      # Match the default the old claude-{settings,skills,agents}.nix modules
      # used. Required because HM needs stateVersion when no other module
      # provides one for this user.
      home.stateVersion = lib.mkDefault "24.05";

      imports = [ claude-shared.homeManagerModules.default ];

      programs.claude-code = {
        enable = true;
        installPackage = true;
        # Headless server — no zellij integration. Statusline + tab-rename
        # hooks are Mac-workflow-specific.
        zellijIntegration.enable = false;
      };
    });
  };
}
