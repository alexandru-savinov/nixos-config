{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.gatus-tailscale;

  # Convert Nix endpoint definitions to Gatus attrset format
  # Note: 'enabled' is a Nix-only option for filtering, not a Gatus config field
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
  // optionalAttrs (ep.ssh != null) { ssh = ep.ssh; };

  # Convert suite endpoint to Gatus attrset format (includes store and always-run)
  suiteEndpointToYaml = ep: {
    name = ep.name;
    url = ep.url;
    conditions = ep.conditions;
  } // optionalAttrs (ep.method != null) { method = ep.method; }
  // optionalAttrs (ep.body != null) { body = ep.body; }
  // optionalAttrs (ep.headers != { }) { headers = ep.headers; }
  // optionalAttrs (ep.store != { }) { store = ep.store; }
  // optionalAttrs ep.always-run { always-run = true; };

  # Convert suite to Gatus attrset format
  suiteToYaml = suite: {
    name = suite.name;
    group = suite.group;
    interval = suite.interval;
    endpoints = map suiteEndpointToYaml suite.endpoints;
  } // optionalAttrs (suite.context != { }) { context = suite.context; };

  # Transform storage config - filter null values and set SQLite default path
  storageConfig =
    if cfg.storage == null then null
    else {
      type = cfg.storage.type;
      caching = cfg.storage.caching;
    } // optionalAttrs (cfg.storage.type == "sqlite") {
      # SQLite requires an explicit path - use state directory
      path = if cfg.storage.path != null then cfg.storage.path else "/var/lib/gatus/data.db";
    } // optionalAttrs (cfg.storage.path != null && cfg.storage.type != "sqlite") {
      path = cfg.storage.path;
    };

  # Transform UI config - filter null values
  uiConfig =
    if cfg.ui == null then null
    else filterAttrs (n: v: v != null) cfg.ui;

  # Filter enabled suites
  enabledSuites = filter (s: s.enabled) (attrValues cfg.suites);

  # Generate full Gatus settings
  gatusSettings = {
    web = {
      address = "127.0.0.1";
      port = cfg.port;
    };
    endpoints = map endpointToYaml (filter (ep: ep.enabled) (attrValues cfg.endpoints));
  } // optionalAttrs (uiConfig != null) { ui = uiConfig; }
  // optionalAttrs (storageConfig != null) { storage = storageConfig; }
  // optionalAttrs (cfg.alerting != { }) { alerting = cfg.alerting; }
  // optionalAttrs (enabledSuites != [ ]) { suites = map suiteToYaml enabledSuites; };

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
          Health conditions to check. Available placeholders by endpoint type:

          HTTP/HTTPS endpoints:
          - [STATUS]: HTTP status code
          - [RESPONSE_TIME]: Response time in ms
          - [BODY]: Response body
          - [CERTIFICATE_EXPIRATION]: Days until cert expires
          - [DOMAIN_EXPIRATION]: Days until domain expires

          TCP endpoints:
          - [CONNECTED]: Connection success (boolean)
          - [RESPONSE_TIME]: Response time in ms

          ICMP endpoints:
          - [CONNECTED]: Ping success (boolean)
          - [RESPONSE_TIME]: Response time in ms
          - [IP]: Resolved IP address

          DNS endpoints:
          - [DNS_RCODE]: DNS response code
          - [BODY]: DNS response body
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
              type = types.enum [ "A" "AAAA" "CNAME" "MX" "NS" "TXT" "SOA" "PTR" "SRV" ];
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

  # Suite endpoint module (sequential endpoints with store/always-run support)
  suiteEndpointModule = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = "Name of this step in the suite.";
      };

      url = mkOption {
        type = types.str;
        description = "URL to request.";
      };

      method = mkOption {
        type = types.nullOr (types.enum [ "GET" "POST" "PUT" "DELETE" "PATCH" ]);
        default = null;
        description = "HTTP method (defaults to GET).";
      };

      body = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Request body.";
      };

      headers = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "HTTP headers to send.";
      };

      conditions = mkOption {
        type = types.listOf types.str;
        default = [ "[STATUS] == 200" ];
        description = "Conditions to verify.";
      };

      store = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = ''
          Variables to extract and store in context for subsequent endpoints.
          Example: { itemId = "[BODY].id"; }
        '';
      };

      always-run = mkOption {
        type = types.bool;
        default = false;
        description = "Run this endpoint even if previous endpoints failed (useful for cleanup).";
      };
    };
  };

  # Suite module (ALPHA feature - sequential endpoints with shared context)
  suiteModule = types.submodule {
    options = {
      enabled = mkOption {
        type = types.bool;
        default = true;
        description = "Whether this suite is enabled.";
      };

      name = mkOption {
        type = types.str;
        description = "Name of the suite.";
      };

      group = mkOption {
        type = types.str;
        default = "suites";
        description = "Group name for organizing suites.";
      };

      interval = mkOption {
        type = types.str;
        default = "15m";
        description = "Interval between suite executions.";
      };

      context = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = ''
          Initial context variables available to all endpoints.
          Can be referenced as [CONTEXT].varName in URLs, bodies, headers, and conditions.
        '';
      };

      endpoints = mkOption {
        type = types.listOf suiteEndpointModule;
        description = "Sequential list of endpoints to execute.";
      };
    };
  };
in
{
  options.services.gatus-tailscale = {
    enable = mkEnableOption "Gatus status page with Tailscale access";

    port = mkOption {
      type = types.port;
      default = 3001;
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

    # Suites - ALPHA feature for sequential endpoint testing with shared context
    suites = mkOption {
      type = types.attrsOf suiteModule;
      default = { };
      description = ''
        Suites for sequential endpoint testing (ALPHA feature).
        Endpoints in a suite run sequentially and can share context via store/[CONTEXT].
        Useful for testing multi-step workflows like authentication or CRUD operations.
      '';
      example = literalExpression ''
        {
          chat-test = {
            name = "LLM Chat Test";
            group = "functional";
            interval = "1h";
            endpoints = [
              {
                name = "verify-models";
                url = "http://127.0.0.1:8080/api/models";
                conditions = [ "[STATUS] == 200" ];
              }
              {
                name = "chat-completion";
                url = "http://127.0.0.1:8080/api/chat/completions";
                method = "POST";
                # Use builtins.toJSON for type-safe request bodies
                body = builtins.toJSON {
                  model = "gpt-4o-mini";
                  messages = [{ role = "user"; content = "Reply: OK"; }];
                };
                conditions = [ "[STATUS] == 200" ];
              }
            ];
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
            description = "Path for SQLite database. If null, defaults to /var/lib/gatus/data.db.";
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
        default = 3001;
        description = "HTTPS port for Tailscale Serve to expose.";
      };
    };

    environmentFiles = mkOption {
      type = types.listOf types.path;
      default = [ ];
      description = ''
        List of environment files to load. Each file should contain KEY=value pairs.
        Variables can be referenced in Gatus config using ''${VAR} syntax.
        Useful for passing API keys to suite endpoints without storing in Nix store.
      '';
      example = literalExpression ''
        [ config.age.secrets.my-api-key.path ]
      '';
    };

    apiKeyFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Path to file containing API key for suite authentication.
        The key will be available as ''${GATUS_API_KEY} in endpoint configurations.
        File should contain just the raw key value (not KEY=value format).
      '';
      example = literalExpression ''
        config.age.secrets.e2e-test-api-key.path
      '';
    };

    apiKeyServiceDependency = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Systemd service that must complete before the API key file exists.
        Useful when the API key is provisioned by another service (e.g., user provisioning).
      '';
      example = "open-webui-e2e-test-user.service";
    };
  };

  config = mkIf cfg.enable {
    # Enable Gatus using the native NixOS module
    services.gatus = {
      enable = true;
      settings = gatusSettings;
    };

    # Add CAP_NET_RAW for ICMP ping support (required for icmp:// endpoints)
    # Load environment files for secret API keys (referenced via ${VAR} in config)
    systemd.services.gatus.serviceConfig =
      let
        # Build list of environment files to load
        envFiles = cfg.environmentFiles
          ++ optional (cfg.apiKeyFile != null) "/run/gatus/env";
      in
      {
        AmbientCapabilities = [ "CAP_NET_RAW" ];
        CapabilityBoundingSet = [ "CAP_NET_RAW" ];
      } // optionalAttrs (envFiles != [ ]) {
        EnvironmentFile = envFiles;
      };

    # Setup service to create environment file from API key before gatus starts
    # EnvironmentFile is loaded before ExecStartPre, so we need a separate service
    # (Using ExecStartPre would fail because the env file wouldn't exist when systemd reads EnvironmentFile)
    systemd.services.gatus-env-setup = mkIf (cfg.apiKeyFile != null) {
      description = "Create Gatus environment file from API key";
      before = [ "gatus.service" ];
      requiredBy = [ "gatus.service" ];
      # Wait for API key provisioning service if specified - use requires for strict dependency
      after = optional (cfg.apiKeyServiceDependency != null) cfg.apiKeyServiceDependency;
      requires = optional (cfg.apiKeyServiceDependency != null) cfg.apiKeyServiceDependency;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail

        API_KEY_FILE="${cfg.apiKeyFile}"

        # Validate API key file exists
        if [ ! -e "$API_KEY_FILE" ]; then
          echo "ERROR: API key file does not exist: $API_KEY_FILE"
          ${optionalString (cfg.apiKeyServiceDependency != null) ''
          echo "This file should be created by: ${cfg.apiKeyServiceDependency}"
          echo "Check if that service completed successfully:"
          echo "  systemctl status ${cfg.apiKeyServiceDependency}"
          ''}
          exit 1
        fi

        # Validate API key file is readable
        if [ ! -r "$API_KEY_FILE" ]; then
          echo "ERROR: API key file is not readable: $API_KEY_FILE"
          echo "Current permissions: $(ls -la "$API_KEY_FILE")"
          exit 1
        fi

        # Read and validate API key content
        API_KEY=$(cat "$API_KEY_FILE" | tr -d '[:space:]')

        if [ -z "$API_KEY" ]; then
          echo "ERROR: API key file is empty or contains only whitespace: $API_KEY_FILE"
          echo "Suite endpoints will fail authentication without a valid API key."
          exit 1
        fi

        if [ ''${#API_KEY} -lt 10 ]; then
          echo "WARNING: API key appears suspiciously short (''${#API_KEY} characters)."
          echo "This may indicate a truncated or invalid key."
        fi

        # Create environment file
        mkdir -p /run/gatus
        echo "GATUS_API_KEY=$API_KEY" > /run/gatus/env
        chmod 600 /run/gatus/env

        echo "Gatus environment file created successfully."
        echo "API key length: ''${#API_KEY} characters"
      '';
    };

    # Ensure gatus waits for env setup
    systemd.services.gatus.after = mkIf (cfg.apiKeyFile != null) [ "gatus-env-setup.service" ];

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
      # PartOf ensures this service restarts when gatus restarts
      # Without this, Requires= only stops this service but doesn't restart it
      partOf = [ "gatus.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        set -euo pipefail

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
          if ! ${pkgs.tailscale}/bin/tailscale serve --bg --https ${toString cfg.tailscaleServe.httpsPort} http://127.0.0.1:${toString cfg.port}; then
            echo "ERROR: Failed to configure Tailscale Serve for Gatus"
            exit 1
          fi
          echo "Tailscale Serve configured successfully"
        else
          echo "Tailscale Serve already configured for Gatus"
        fi
      '';

      preStop = ''
        echo "Removing Tailscale Serve configuration for Gatus..."
        ${pkgs.tailscale}/bin/tailscale serve --bg --https ${toString cfg.tailscaleServe.httpsPort} off || true
      '';
    };

    # Access Gatus via Tailscale HTTPS (requires tailscaleServe.enable = true):
    #   https://<hostname>.<tailnet>.ts.net:<tailscaleServe.httpsPort>
    # Service binds to localhost only for security - no direct network access possible
  };
}
