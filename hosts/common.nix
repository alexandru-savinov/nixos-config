{ pkgs, lib, ... }:

{
  boot.tmp.cleanOnBoot = true;
  zramSwap.enable = true;

  services.openssh = {
    enable = true;
    settings = {
      # Prevent connection drops (especially for Zed/VSCode remote)
      ClientAliveInterval = 60;
      ClientAliveCountMax = 3;
      TCPKeepAlive = true;
    };
  };

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # /bin/bash symlink for tools with hardcoded #!/bin/bash shebangs (e.g. Claude Code plugins)
  system.activationScripts.binbash = lib.stringAfter [ "stdio" ] ''
    ln -sfn ${pkgs.bash}/bin/bash /bin/bash
  '';

  environment.systemPackages = with pkgs; [
    vim
    git
    curl
    wget
    jq # Required for Ralph Wiggum plugin hooks (JSON parsing)
    zellij
  ];

  # ── fail2ban — brute-force protection ───────────────────────────────────
  services.fail2ban = {
    enable = true;
    maxretry = 5;
    bantime = "1h";
    bantime-increment.enable = true;
    jails.sshd.settings = {
      enabled = true;
      filter = "sshd[mode=aggressive]";
      maxretry = 3;
    };
  };

  # Default state version (override per host if needed)
  system.stateVersion = "23.11";
}
