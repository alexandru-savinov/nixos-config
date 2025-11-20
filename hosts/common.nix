{ config, pkgs, lib, ... }:

{
  # Common configuration shared across all hosts

  # Boot and system maintenance
  boot.tmp.cleanOnBoot = true;
  zramSwap.enable = true;

  # SSH is enabled by default for all hosts
  services.openssh.enable = true;

  # Nix settings
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # System packages available on all hosts
  environment.systemPackages = with pkgs; [
    vim
    git
    curl
    wget
  ];

  # Default state version (override per host if needed)
  system.stateVersion = "23.11";
}
