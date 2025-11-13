{ config, pkgs, lib, ... }:

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
      shellAliases = {
        copilot = "${pkgs.nodejs_22}/bin/node ~/.npm-global/lib/node_modules/@github/copilot/index.js";
      };
    };
  };
}
