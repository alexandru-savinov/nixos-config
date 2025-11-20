{ config, pkgs, lib, ... }:

{
  # Tailscale - Zero-config VPN for secure private networking
  services.tailscale = {
    enable = true;

    # Port for tunnel traffic
    port = 41641;

    # Interface name for the Tailscale network
    interfaceName = "tailscale0";

    # Enable client routing features (for using exit nodes, accepting routes)
    useRoutingFeatures = "client";

    # Open firewall for Tailscale UDP traffic
    openFirewall = true;

    # Declarative authentication with auth key from agenix
    authKeyFile = config.age.secrets.tailscale-auth-key.path;

    # Extra flags for 'tailscale up' command
    extraUpFlags = [
      "--ssh" # Enable Tailscale SSH
      "--accept-routes" # Accept subnet routes from other nodes
    ];
  };

  # Trust the Tailscale interface
  networking.firewall.trustedInterfaces = [ "tailscale0" ];

  # Ensure tailscale directory exists with correct permissions
  systemd.tmpfiles.rules = [
    "d /var/lib/tailscale 0700 root root -"
  ];
}
