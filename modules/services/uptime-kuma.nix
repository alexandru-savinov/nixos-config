{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.uptime-kuma-tailscale;
in
{
  options.services.uptime-kuma-tailscale = {
    enable = mkEnableOption "Uptime Kuma with Tailscale access";

    port = mkOption {
      type = types.port;
      default = 3001;
      description = "Port for Uptime Kuma to listen on.";
    };
  };

  config = mkIf cfg.enable {
    # Enable Uptime Kuma service using native NixOS module
    # Bind to 0.0.0.0 but firewall restricts to Tailscale interface only
    services.uptime-kuma = {
      enable = true;
      settings = {
        HOST = "0.0.0.0";
        PORT = toString cfg.port;
      };
    };

    # Allow access only via Tailscale interface (no public internet access)
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ cfg.port ];

    # Access Uptime Kuma directly via Tailscale:
    #   http://sancta-choir.tail4249a9.ts.net:3001
    #   or http://100.77.249.31:3001
  };
}
