{ config, pkgs, pkgs-unstable, lib, ... }:

{
  options.customModules.dev-tools = {
    enable = lib.mkEnableOption "development tools package set";
  };

  config = lib.mkIf config.customModules.dev-tools.enable {
    environment.systemPackages = with pkgs; [
      # Editors
      helix
      vim

      # Terminal multiplexers
      tmux

      # System monitoring
      htop
      btop

      # File navigation and search
      tree
      ripgrep
      fd

      # Development tools
      nodejs_22
      gh
      pkgs-unstable.github-copilot-cli # Use unstable for latest features

      # Nix development tools
      nixpkgs-fmt
      nil # Nix language server
    ];
  };
}
