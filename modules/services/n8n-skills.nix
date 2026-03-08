# n8n Skills for Claude Code
#
# This module fetches n8n skills from GitHub and installs them
# for Claude Code via home-manager symlinks.
#
# Skills teach Claude how to build production-ready n8n workflows
# using the n8n-mcp MCP server. The 7 skills cover:
# - Expression syntax ({{}} patterns)
# - MCP tools expert (highest priority - guides all MCP operations)
# - Workflow patterns (5 production-tested architectures)
# - Validation expert (error resolution)
# - Node configuration (operation-aware setup)
# - Code JavaScript (10 production patterns)
# - Code Python (limitation awareness)
#
# Source: https://github.com/czlonkowski/n8n-skills
#
# Usage:
#   services.n8n-skills = {
#     enable = true;
#     users = [ "nixos" "root" ];
#   };

{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.n8n-skills;
in
{
  options.services.n8n-skills = {
    enable = mkEnableOption "n8n skills for Claude Code";

    version = mkOption {
      type = types.str;
      default = "d9c287202999481777868c4ce7441ced847350b3";
      example = "main";
      description = ''
        Git commit SHA or branch to fetch from czlonkowski/n8n-skills.
        Use a specific commit SHA for reproducible builds.
        Default is pinned to a known-good commit.

        To update:
          nix shell nixpkgs#nix-prefetch-github -c \
            nix-prefetch-github czlonkowski n8n-skills --rev main
      '';
    };

    hash = mkOption {
      type = types.str;
      default = "sha256-qmVQJgaol3SDHtmGLE81PFJS+4fXXgtzdnn5sMnAje8=";
      description = ''
        SHA256 hash of the fetched source.
        Must match the version specified above.

        To compute for a new version:
          nix shell nixpkgs#nix-prefetch-github -c \
            nix-prefetch-github czlonkowski n8n-skills --rev <commit-or-branch>
      '';
    };

    users = mkOption {
      type = types.listOf types.str;
      default = [ "nixos" ];
      example = [ "nixos" "root" ];
      description = ''
        List of users to install n8n skills for.
        Skills are symlinked to ~/.claude/skills/ for each user.
      '';
    };
  };

  config = mkIf cfg.enable (
    let
      # Fetch skills from GitHub with pinned commit
      # Moved inside config block to avoid infinite recursion
      n8nSkillsSrc = pkgs.fetchFromGitHub {
        owner = "czlonkowski";
        repo = "n8n-skills";
        rev = cfg.version;
        hash = cfg.hash;
      };

      # Skill names — each maps to skills/<name> in the repo
      skillNames = [
        "n8n-code-javascript"
        "n8n-code-python"
        "n8n-expression-syntax"
        "n8n-mcp-tools-expert"
        "n8n-node-configuration"
        "n8n-validation-expert"
        "n8n-workflow-patterns"
      ];

      skillFiles = listToAttrs (map (name: {
        name = ".claude/skills/${name}";
        value.source = "${n8nSkillsSrc}/skills/${name}";
      }) skillNames);
    in
    {
      # Configure home-manager for each user
      home-manager.users = genAttrs cfg.users (_: {
        home.stateVersion = mkDefault "24.05";
        home.file = skillFiles;
      });
    }
  );
}
