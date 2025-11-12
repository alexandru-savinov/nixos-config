{ config, pkgs, lib, ... }:

{
  # Home Manager configuration for root user
  home-manager.users.root = {
    home.stateVersion = "23.11";

    # Additional user-specific home-manager configs can go here
    programs.git = {
      enable = true;
      # Git config is already set via .gitconfig, just enable HM management
    };
  };
}
