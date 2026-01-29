{ config, pkgs, pkgs-unstable ? pkgs, lib, ... }:

{
  # Development tools package set
  # IMPORTANT: For latest github-copilot-cli, pass pkgs-unstable via specialArgs:
  #   pkgs-unstable = import nixpkgs-unstable { system = "..."; };
  # Otherwise, the stable version will be used.

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
