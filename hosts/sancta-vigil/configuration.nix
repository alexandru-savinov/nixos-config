# ==========================================================================
# sancta-vigil - Dedicated Observability Host (PLACEHOLDER)
# ==========================================================================
# This is a placeholder for the future dedicated observability instance.
#
# Planned services:
#   - Gatus: Status page and uptime monitoring (moved from sancta-choir)
#   - Grafana: Metrics visualization dashboard
#   - Loki: Log aggregation
#   - Prometheus: Metrics collection
#   - Alertmanager: Alert routing and notifications
#
# Architecture:
#   sancta-vigil monitors → sancta-choir, rpi5, and future hosts
#   All services accessible via Tailscale only
#
# Migration path:
#   1. Deploy sancta-vigil with Gatus
#   2. Verify monitoring works
#   3. Disable Gatus on sancta-choir
#   4. Add additional observability stack (Grafana, Loki, etc.)
#
# To implement:
#   1. Uncomment and complete this configuration
#   2. Add hardware-configuration.nix for the target machine
#   3. Add to flake.nix nixosConfigurations
#   4. Move Gatus endpoints here from sancta-choir
# ==========================================================================

{ config
, pkgs
, lib
, self
, ...
}:

{
  imports = [
    # ./hardware-configuration.nix  # Add when deploying
    ../common.nix
    ../../modules/users/root.nix
    ../../modules/services/tailscale.nix
    ../../modules/services/gatus.nix
  ];

  # Agenix secrets
  age.secrets = {
    tailscale-auth-key.file = "${self}/secrets/tailscale-auth-key.age";
  };

  # Gatus - Centralized status monitoring
  # Will monitor all infrastructure from this dedicated host
  services.gatus-tailscale = {
    enable = true;
    port = 3001;

    ui = {
      title = "Infrastructure Status";
      header = "Service Health Dashboard";
    };

    storage = {
      type = "sqlite";
      caching = true;
    };

    tailscaleServe = {
      enable = true;
      httpsPort = 3001;
    };

    # All endpoints will be monitored via Tailscale
    endpoints = {
      # sancta-choir services
      sancta-choir-open-webui = {
        name = "Open-WebUI";
        group = "sancta-choir";
        url = "https://sancta-choir.tail4249a9.ts.net/health";
        interval = "1m";
        conditions = [ "[STATUS] == 200" ];
      };

      sancta-choir-n8n = {
        name = "n8n";
        group = "sancta-choir";
        url = "https://sancta-choir.tail4249a9.ts.net:5678/healthz";
        interval = "1m";
        conditions = [ "[STATUS] == 200" ];
      };

      sancta-choir-tailscale = {
        name = "Tailscale";
        group = "sancta-choir";
        url = "icmp://sancta-choir.tail4249a9.ts.net";
        interval = "30s";
        conditions = [ "[CONNECTED] == true" ];
      };

      # rpi5 services
      rpi5-open-webui = {
        name = "Open-WebUI";
        group = "rpi5";
        url = "https://rpi5.tail4249a9.ts.net/health";
        interval = "1m";
        conditions = [
          "[STATUS] == 200"
          "[RESPONSE_TIME] < 5000"
        ];
      };

      rpi5-n8n = {
        name = "n8n";
        group = "rpi5";
        url = "https://rpi5.tail4249a9.ts.net:5678/healthz";
        interval = "1m";
        conditions = [
          "[STATUS] == 200"
          "[RESPONSE_TIME] < 5000"
        ];
      };

      rpi5-qdrant = {
        name = "Qdrant";
        group = "rpi5";
        url = "https://rpi5.tail4249a9.ts.net:6333/readyz";
        interval = "1m";
        conditions = [ "[STATUS] == 200" ];
      };

      rpi5-tailscale = {
        name = "Tailscale";
        group = "rpi5";
        url = "icmp://rpi5.tail4249a9.ts.net";
        interval = "30s";
        conditions = [ "[CONNECTED] == true" ];
      };

      # External services
      external-openrouter = {
        name = "OpenRouter API";
        group = "external";
        url = "https://openrouter.ai/api/v1/models";
        interval = "5m";
        conditions = [
          "[STATUS] == 200"
          "[RESPONSE_TIME] < 3000"
        ];
      };

      external-tavily = {
        name = "Tavily API";
        group = "external";
        url = "https://api.tavily.com/";
        interval = "5m";
        conditions = [ "[STATUS] < 500" ];
      };
    };
  };

  # Hostname
  networking.hostName = "sancta-vigil";
  networking.domain = "";

  # SSH authorized keys
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPw5RFrFfZQUWlyfGSU1Q8BlEHnvIdBtcnCn+uYtEzal nixos-sancta-choir"
  ];

  # System state version
  system.stateVersion = "24.11";
}
