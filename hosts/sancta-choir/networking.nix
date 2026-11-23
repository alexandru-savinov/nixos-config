# Consolidated sancta-choir base + Hetzner networking config (#232).
#
# Replaces modules/system/host.nix and modules/system/networking.nix, which
# were imported only by this host and defined overlapping values: the same
# eth0 address in both (rendered twice), the same default gateway twice,
# nameserver lists that merged with duplicates, and a localCommands
# `ip route add` that repeated what ipv4.routes already declares.
{ lib, ... }:

{
  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # ── Hetzner Cloud networking ──────────────────────────────────────────
  networking = {
    hostName = lib.mkForce "sancta-choir";
    useDHCP = false;
    usePredictableInterfaceNames = lib.mkForce false;
    dhcpcd.enable = false;

    interfaces.eth0 = {
      useDHCP = false;
      ipv4.addresses = [
        {
          address = "116.203.223.113";
          prefixLength = 32;
        }
      ];
      ipv6.addresses = [
        {
          address = "fe80::9000:6ff:febb:9603";
          prefixLength = 64;
        }
      ];
      # On-link route to the Hetzner gateway (the /32 address has no subnet
      # route, so the gateway must be reachable via an explicit route).
      ipv4.routes = [
        {
          address = "172.31.1.1";
          prefixLength = 32;
        }
      ];
    };

    defaultGateway = {
      address = "172.31.1.1";
      interface = "eth0";
    };

    # Order preserved from the previous module merge (8.8.8.8 was first);
    # duplicate Hetzner entries dropped.
    nameservers = [
      "8.8.8.8"
      "185.12.64.1"
      "185.12.64.2"
    ];

    firewall.enable = true;
    firewall.allowedTCPPorts = [ 22 ];
  };

  # MAC address binding
  services.udev.extraRules = ''
    ATTR{address}=="92:00:06:bb:96:03", NAME="eth0"
  '';

  # SSH
  services.openssh = {
    enable = true;
    settings = {
      # Root never logs in over OpenSSH (any port); see ssh-admin.nix.
      PermitRootLogin = "no";
      PasswordAuthentication = false;
    };
  };


  # VSCode Server support
  services.vscode-server.enable = true;
  # The module installs its watcher as a user unit for EVERY user manager. Only
  # the accounts that run VS Code Remote get it; service and forced-command
  # accounts (diag, agent, sancta, ...) never run it on login. `|` makes the
  # conditions an OR.
  systemd.user.services.auto-fix-vscode-server.unitConfig.ConditionUser = [ "|root" "|alexandru" ];

  # Time zone
  time.timeZone = "Europe/Chisinau";

  # Locale
  i18n.defaultLocale = "en_US.UTF-8";
}
