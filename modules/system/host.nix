{ config, pkgs, lib, ... }:

{
  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # SSH
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  # Firewall
  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 ];

  # System packages
  environment.systemPackages = with pkgs; [
    helix
    git
    curl
    wget
    tmux
    htop
    tree
    ripgrep
    fd
    btop
    nodejs
    gh
    github-copilot-cli
    # Nix development tools
    nixpkgs-fmt
    nil # Nix language server
  ];

  # Time zone
  time.timeZone = "UTC";

  # Locale
  i18n.defaultLocale = "en_US.UTF-8";
}
