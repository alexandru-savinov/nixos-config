# Claude Code Agents — project-local agents stored in this repo.
#
# Installs project-local Claude Code agents into ~/.claude/agents/
# for each specified user via home-manager symlinks.
# Note: each agent must be explicitly listed in home.file — the directory
# is not scanned automatically. Add new agents alongside nix-security-reviewer.
#
# Usage:
#   services.claude-agents = {
#     enable = true;
#     users = [ "nixos" ];
#   };

{ config, lib, self, ... }:

with lib;

let
  cfg = config.services.claude-agents;
  agentsDir = "${self}/modules/claude-agents";
in
{
  options.services.claude-agents = {
    enable = mkEnableOption "project-local Claude Code agents";

    users = mkOption {
      type = types.listOf types.str;
      default = [ "nixos" ];
      description = "Users to install Claude agents for.";
    };
  };

  config = mkIf cfg.enable {
    home-manager.users = genAttrs cfg.users (_: {
      home.stateVersion = mkDefault "24.05";
      home.file = {
        ".claude/agents/nix-security-reviewer".source = "${agentsDir}/nix-security-reviewer";
      };
    });
  };
}
