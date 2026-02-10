{ pkgs-unstable, ... }:

{
  # Home Manager configuration for root user
  home-manager.users.root = {
    home.stateVersion = "24.05";

    # Add ~/.local/bin to PATH for user-installed binaries
    home.sessionPath = [ "$HOME/.local/bin" ];

    # Additional user-specific home-manager configs can go here
    programs.git = {
      enable = true;
      # Git config is already set via .gitconfig, just enable HM management
    };

    # Bash configuration
    programs.bash = {
      enable = true;
      # Use NixOS-managed copilot instead of VS Code's older bundled version
      # VS Code adds its shim to PATH first, so we override with an alias
      shellAliases = {
        copilot = "${pkgs-unstable.github-copilot-cli}/bin/copilot";
      };
    };
  };
}
