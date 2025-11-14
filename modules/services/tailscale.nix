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
    
    # Declarative authentication with auth key file
    # Setup instructions:
    # 1. Generate reusable auth key at https://login.tailscale.com/admin/settings/keys
    #    - Check "Reusable" option
    #    - Set appropriate expiration (90 days, 180 days, or never)
    # 2. On the server, run:
    #    echo "tskey-auth-xxxxx-yyyyyyyy" | sudo tee /var/lib/tailscale/auth-key
    #    sudo chmod 600 /var/lib/tailscale/auth-key
    # 3. Deploy this configuration
    authKeyFile = "/var/lib/tailscale/auth-key";
    
    # Extra flags for 'tailscale up' command
    extraUpFlags = [
      "--ssh"              # Enable Tailscale SSH
      "--accept-routes"    # Accept subnet routes from other nodes
    ];
  };

  # Trust the Tailscale interface
  networking.firewall.trustedInterfaces = [ "tailscale0" ];
  
  # Ensure tailscale directory exists with correct permissions
  systemd.tmpfiles.rules = [
    "d /var/lib/tailscale 0700 root root -"
  ];
}
