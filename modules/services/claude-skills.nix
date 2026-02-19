# Claude Code Skills — project-local skills stored in this repo.
#
# Installs project-local Claude Code skills into ~/.claude/skills/
# for each specified user via home-manager symlinks.
# Note: each skill must be explicitly listed in home.file — the directory
# is not scanned automatically. Add new skills alongside verify-first.
#
# Usage:
#   services.claude-skills = {
#     enable = true;
#     users = [ "nixos" ];
#   };

{ config, lib, self, ... }:

with lib;

let
  cfg = config.services.claude-skills;
  skillsDir = "${self}/modules/claude-skills";
in
{
  options.services.claude-skills = {
    enable = mkEnableOption "project-local Claude Code skills";

    users = mkOption {
      type = types.listOf types.str;
      default = [ "nixos" ];
      description = "Users to install Claude skills for.";
    };
  };

  config = mkIf cfg.enable {
    home-manager.users = listToAttrs (map
      (user: {
        name = user;
        value = {
          home.stateVersion = lib.mkDefault "24.05";
          home.file = {
            ".claude/skills/verify-first".source = "${skillsDir}/verify-first";
          };
        };
      })
      cfg.users);
  };
}
