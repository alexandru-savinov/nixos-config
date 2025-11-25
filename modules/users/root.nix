{ config, pkgs, pkgs-unstable, lib, ... }:

{
  # Home Manager configuration for root user
  home-manager.users.root = {
    home.stateVersion = "24.05";

    # Additional user-specific home-manager configs can go here
    programs.git = {
      enable = true;
      # Git config is already set via .gitconfig, just enable HM management
    };

    # Bash configuration
    programs.bash = {
      enable = true;
      # Note: 'copilot' command is available directly from pkgs-unstable.github-copilot-cli
      # No alias needed as it's in PATH via environment.systemPackages
    };
  };
}
