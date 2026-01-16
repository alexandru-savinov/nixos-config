{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.gatus-tailscale;

  # Convert Nix endpoint definitions to Gatus YAML format
  endpointToYaml = ep: {
    name = ep.name;
    group = ep.group;
    url = ep.url;
    interval = ep.interval;
    conditions = ep.conditions;
  } // optionalAttrs (ep.method != null) { method = ep.method; }
    // optionalAttrs (ep.body != null) { body = ep.body; }
    // optionalAttrs (ep.headers != { }) { headers = ep.headers; }
    // optionalAttrs (ep.dns != null) { dns = ep.dns; }
    // optionalAttrs (ep.ssh != null) { ssh = ep.ssh; }
    // optionalAttrs ep.enabled { enabled = ep.enabled; };

  # Generate full Gatus settings
  gatusSettings = {
    web = {
      address = "127.0.0.1";
      port = cfg.port;
    };
    endpoints = map endpointToYaml (filter (ep: ep.enabled) (attrValues cfg.endpoints));
  } // optionalAttrs (cfg.ui != null) { ui = cfg.ui; }
    // optionalAttrs (cfg.storage != null) { storage = cfg.storage; }
    // optionalAttrs (cfg.alerting != { }) { alerting = cfg.alerting; };

  endpointModule = types.submodule {
    options = {
      enabled = mkOption {
        type = types.bool;
        default = true;
        description = "Whether this endpoint is enabled.";
      };

      name = mkOption {
        type = types.str;
        description = "Display name for the endpoint.";
      };

      group = mkOption {
        type = types.str;
        default = "default";
        description = "Group name for organizing endpoints.";
      };

      url = mkOption {
        type = types.str;
        description = ''
          URL to monitor. Supports:
          - HTTP/HTTPS: https://example.com/health
          - TCP: tcp://host:port
          - ICMP: icmp://host
          - DNS: dns://1.1.1.1 (with dns option)
        '';
      };

      method = mkOption {
        type = types.nullOr (types.enum [ "GET" "POST" "PUT" "DELETE" "PATCH" "HEAD" "OPTIONS" ]);
        default = null;
        description = "HTTP method (defaults to GET).";
      };

      body = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Request body for HTTP requests.";
      };

      headers = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "HTTP headers to send with the request.";
      };

      interval = mkOption {
        type = types.str;
        default = "5m";
        description = "Check interval (e.g., 30s, 5m, 1h).";
      };

      conditions = mkOption {
        type = types.listOf types.str;
        default = [ "[STATUS] == 200" ];
        description = ''
          Health conditions to check. Available placeholders:
          - [STATUS]: HTTP status code
          - [RESPONSE_TIME]: Response time in ms
          - [BODY]: Response body
          - [CONNECTED]: Connection success (TCP/ICMP)
          - [DNS_RCODE]: DNS response code
        '';
        example = [
          "[STATUS] == 200"
          "[RESPONSE_TIME] < 500"
        ];
      };

      dns = mkOption {
        type = types.nullOr (types.submodule {
          options = {
            query-name = mkOption {
              type = types.str;
              description = "DNS query name.";
            };
            query-type = mkOption {
              type = types.enum [ "A" "AAAA" "CNAME" "MX" "NS" "TXT" ];
              default = "A";
              description = "DNS query type.";
            };
          };
        });
        default = null;
        description = "DNS query configuration.";
      };

      ssh = mkOption {
        type = types.nullOr (types.submodule {
          options = {
            username = mkOption {
              type = types.str;
              description = "SSH username.";
            };
            password = mkOption {
              type = types.str;
              default = "";
              description = "SSH password (prefer key-based auth).";
            };
          };
        });
        default = null;
        description = "SSH configuration for SSH endpoints.";
      };
    };
  };
in
{
  options.services.gatus-tailscale = {
    enable = mkEnableOption "Gatus status page with Tailscale access";

    port = mkOption {
      type = types.port;
      default = 8080;
      description = "Port for Gatus web interface to listen on.";
    };

    endpoints = mkOption {
      type = types.attrsOf endpointModule;
      default = { };
      description = "Endpoints to monitor.";
      example = literalExpression ''
        {
          open-webui = {
            name = "Open-WebUI";
            group = "sancta-choir";
            url = "https://sancta-choir.tail4249a9.ts.net/health";
            interval = "1m";
            conditions = [ "[STATUS] == 200" ];
          };
          n8n = {
            name = "n8n";
            group = "sancta-choir";
            url = "https://sancta-choir.tail4249a9.ts.net:5678/healthz";
            conditions = [ "[STATUS] == 200" ];
          };
        }
      '';
    };

    ui = mkOption {
      type = types.nullOr (types.submodule {
        options = {
          title = mkOption {
            type = types.str;
            default = "Status";
            description = "Title displayed on the status page.";
          };
          header = mkOption {
            type = types.str;
            default = "Health Status";
            description = "Header text on the status page.";
          };
          logo = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "URL or path to logo image.";
          };
          link = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Link when clicking the logo.";
          };
        };
      });
      default = {
        title = "Infrastructure Status";
        header = "Service Health";
      };
      description = "UI customization settings.";
    };

    storage = mkOption {
      type = types.nullOr (types.submodule {
        options = {
          type = mkOption {
            type = types.enum [ "memory" "sqlite" "postgres" ];
            default = "sqlite";
            description = "Storage backend type.";
          };
          path = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Path for SQLite database (defaults to /var/lib/gatus/data.db).";
          };
          caching = mkOption {
            type = types.bool;
            default = true;
            description = "Enable caching for improved performance.";
          };
        };
      });
      default = {
        type = "sqlite";
        caching = true;
      };
      description = "Storage configuration for historical data.";
    };

    alerting = mkOption {
      type = types.attrsOf types.anything;
      default = { };
      description = ''
        Alerting configuration. Supports various providers:
        - email, slack, discord, telegram, pagerduty, etc.
        See Gatus documentation for provider-specific options.
      '';
      example = literalExpression ''
        {
          discord = {
            webhook-url = "https://discord.com/api/webhooks/...";
            default-alert = {
              enabled = true;
              failure-threshold = 3;
              success-threshold = 2;
              send-on-resolved = true;
            };
          };
        }
      '';
    };

    tailscaleServe = {
      enable = mkEnableOption "Tailscale Serve for HTTPS access";

      httpsPort = mkOption {
        type = types.port;
        default = 8080;
        description = "HTTPS port for Tailscale Serve to expose.";
      };
    };
  };

  config = mkIf cfg.enable {
    # Enable Gatus using the native NixOS module
    services.gatus = {
      enable = true;
      settings = gatusSettings;
    };

    # Add CAP_NET_RAW for ICMP ping support (required for icmp:// endpoints)
    systemd.services.gatus.serviceConfig = {
      AmbientCapabilities = [ "CAP_NET_RAW" ];
      CapabilityBoundingSet = [ "CAP_NET_RAW" ];
    };

    # Tailscale Serve configuration for HTTPS access
    systemd.services.tailscale-serve-gatus = mkIf cfg.tailscaleServe.enable {
      description = "Configure Tailscale Serve for Gatus HTTPS access";
      after = [
        "network-online.target"
        "tailscaled.service"
        "gatus.service"
      ];
      wants = [ "network-online.target" ];
      requires = [
        "tailscaled.service"
        "gatus.service"
      ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        # Wait for tailscaled to be ready (timeout: 60 seconds)
        timeout=60
        while ! ${pkgs.tailscale}/bin/tailscale status &>/dev/null; do
          timeout=$((timeout - 1))
          if [ $timeout -le 0 ]; then
            echo "ERROR: tailscaled not ready after 60 seconds"
            exit 1
          fi
          sleep 1
        done

        # Wait for gatus to be listening (timeout: 60 seconds)
        timeout=60
        while ! ${pkgs.netcat}/bin/nc -z 127.0.0.1 ${toString cfg.port} 2>/dev/null; do
          timeout=$((timeout - 1))
          if [ $timeout -le 0 ]; then
            echo "ERROR: gatus not listening on port ${toString cfg.port} after 60 seconds"
            exit 1
          fi
          sleep 1
        done

        # Check if serve is already configured for this port
        if ! ${pkgs.tailscale}/bin/tailscale serve status 2>/dev/null | grep -q "https:${toString cfg.tailscaleServe.httpsPort}"; then
          echo "Configuring Tailscale Serve for Gatus..."
          ${pkgs.tailscale}/bin/tailscale serve --bg --https ${toString cfg.tailscaleServe.httpsPort} http://127.0.0.1:${toString cfg.port}
        else
          echo "Tailscale Serve already configured for Gatus"
        fi
      '';

      preStop = ''
        echo "Removing Tailscale Serve configuration for Gatus..."
        ${pkgs.tailscale}/bin/tailscale serve --https ${toString cfg.tailscaleServe.httpsPort} off || true
      '';
    };

    # Access Gatus via Tailscale HTTPS (requires tailscaleServe.enable = true):
    #   https://<hostname>.<tailnet>.ts.net:8080
    # Service binds to localhost only for security - no direct network access possible
  };
}
