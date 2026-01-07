{ config, pkgs, lib, ... }:

{
  # Common configuration shared across all hosts

  # Boot and system maintenance
  boot.tmp.cleanOnBoot = true;
  zramSwap.enable = true;

  # SSH is enabled by default for all hosts with keepalive settings
  services.openssh = {
    enable = true;
    settings = {
      # Keepalive settings to prevent connection drops (especially for Zed/VSCode remote)
      ClientAliveInterval = 60; # Send keepalive every 60 seconds
      ClientAliveCountMax = 3; # Disconnect after 3 missed probes (180s total)
      TCPKeepAlive = true; # Enable TCP-level keepalives
    };
  };

  # Nix settings
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # FHS compatibility: create /bin/bash symlink for scripts with hardcoded shebangs
  # Required for tools like Claude Code plugins that use #!/bin/bash
  system.activationScripts.binbash = lib.stringAfter [ "stdio" ] ''
    ln -sfn ${pkgs.bash}/bin/bash /bin/bash
  '';

  # System packages available on all hosts
  environment.systemPackages = with pkgs; [
    vim
    git
    curl
    wget
    jq # Required for Ralph Wiggum plugin hooks (JSON parsing)
  ];

  # Default state version (override per host if needed)
  system.stateVersion = "23.11";
}
