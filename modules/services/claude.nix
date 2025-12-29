{ config, pkgs, lib, claude-code, ... }:

{
  # Claude Code - AI-powered coding assistant
  # Auto-updated hourly via github:sadjow/claude-code-nix flake

  # Add Claude Code to system packages
  environment.systemPackages = [
    claude-code.packages.${pkgs.system}.default
  ];
}
