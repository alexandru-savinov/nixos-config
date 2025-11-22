{
  config,
  pkgs,
  lib,
  ...
}:

with lib;

let
  cfg = config.services.open-webui-tailscale;
in
{
  options.services.open-webui-tailscale = {
    enable = mkEnableOption "Open-WebUI with Tailscale Serve";

    host = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Host address for Open-WebUI to listen on. Keep localhost for Tailscale Serve.";
    };

    port = mkOption {
      type = types.port;
      default = 8080;
      description = "Port for Open-WebUI to listen on.";
    };

    stateDir = mkOption {
      type = types.path;
      default = "/var/lib/open-webui";
      description = "Directory for Open-WebUI state (database, uploads, vector DB).";
    };

    secretKeyFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/run/secrets/open-webui-secret-key";
      description = ''
        Path to file containing the WEBUI_SECRET_KEY (JWT signing secret).
        Generate with: openssl rand -hex 32
        Use agenix or sops-nix for secret management.
        If null, a warning will be issued and default key used (insecure).
      '';
    };

    jwtExpiresIn = mkOption {
      type = types.str;
      default = "7d";
      example = "24h";
      description = "JWT token expiration time. Never use '-1' in production.";
    };

    openai = {
      apiBaseUrl = mkOption {
        type = types.str;
        default = "https://openrouter.ai/api/v1";
        description = "OpenAI-compatible API base URL. Defaults to OpenRouter.";
      };

      apiKeyFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = "/run/secrets/openrouter-api-key";
        description = ''
          Path to file containing the OpenRouter (or OpenAI) API key.
          Use agenix or sops-nix for secret management.
        '';
      };
    };

    oidc = {
      enable = mkEnableOption "OIDC authentication via tsidp";

      issuerUrl = mkOption {
        type = types.str;
        default = "https://idp.tail4249a9.ts.net";
        example = "https://idp.yourtailnet.ts.net";
        description = "OIDC issuer URL (tsidp endpoint).";
      };

      clientId = mkOption {
        type = types.str;
        default = "open-webui";
        description = "OAuth client ID.";
      };

      clientSecretFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = "/var/lib/secrets/oidc-client-secret";
        description = "Path to file containing OIDC client secret.";
      };
    };

    tavilySearch = {
      enable = mkEnableOption "Tavily Search for RAG web search";

      apiKeyFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = "/run/secrets/tavily-api-key";
        description = ''
          Path to file containing the Tavily API key.
          Use agenix or sops-nix for secret management.
          Get your API key from https://app.tavily.com
        '';
      };
    };

    enableSignup = mkOption {
      type = types.bool;
      default = false;
      description = "Allow new user signups. Disable for private deployments.";
    };

    defaultUserRole = mkOption {
      type = types.enum [
        "pending"
        "user"
        "admin"
      ];
      default = "pending";
      description = "Default role for new users.";
    };

    tailscaleServe = {
      enable = mkEnableOption "Tailscale Serve for HTTPS access" // {
        default = true;
      };

      httpsPort = mkOption {
        type = types.port;
        default = 443;
        description = "HTTPS port for Tailscale Serve to expose.";
      };
    };

    webuiUrl = mkOption {
      type = types.str;
      default = "https://sancta-choir.tail4249a9.ts.net";
      example = "https://myhost.tail<hex>.ts.net";
      description = "Public URL for OpenWebUI (used for OAuth callbacks).";
    };

    extraEnvironment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = literalExpression ''
        {
          ENABLE_RAG_WEB_SEARCH = "True";
          ENABLE_IMAGE_GENERATION = "False";
        }
      '';
      description = "Additional environment variables for Open-WebUI.";
    };
  };

  config = mkIf cfg.enable {
    # Warn if no secret key file is provided
    warnings = optional (cfg.secretKeyFile == null) ''
      services.open-webui-tailscale.secretKeyFile is not set!
      Using default WEBUI_SECRET_KEY is INSECURE for production.
      Generate a secret: openssl rand -hex 32
      Store it with agenix or sops-nix.
    '';

    # Open-WebUI service configuration
    services.open-webui = {
      enable = true;
      inherit (cfg) host port stateDir;
      openFirewall = false; # Accessed via Tailscale only

      environment = mkMerge [
        {
          # Security
          ANONYMIZED_TELEMETRY = "False";
          DO_NOT_TRACK = "True";
          SCARF_NO_ANALYTICS = "True";
          ENABLE_PERSISTENT_CONFIG = "True"; # Allow config from env vars but persist UI changes

          # JWT Configuration
          JWT_EXPIRES_IN = cfg.jwtExpiresIn;

          # User Management
          ENABLE_SIGNUP = if cfg.enableSignup then "True" else "False";
          DEFAULT_USER_ROLE = cfg.defaultUserRole;

          # OpenAI-compatible API
          OPENAI_API_BASE_URL = cfg.openai.apiBaseUrl;

          # WebUI URL for OAuth callbacks
          WEBUI_URL = cfg.webuiUrl;
        }
        (mkIf cfg.tavilySearch.enable {
          ENABLE_RAG_WEB_SEARCH = "True";
          RAG_WEB_SEARCH_ENGINE = "tavily";
          RAG_WEB_SEARCH_RESULT_COUNT = "3";
          RAG_WEB_SEARCH_CONCURRENT_REQUESTS = "10";
        })
        (mkIf cfg.oidc.enable {
          # OIDC Configuration
          OAUTH_PROVIDER_NAME = "Tailscale";
          OPENID_PROVIDER_URL = "${cfg.oidc.issuerUrl}/.well-known/openid-configuration";
          OAUTH_CLIENT_ID = cfg.oidc.clientId;
          OPENID_REDIRECT_URI = "${cfg.webuiUrl}/oauth/oidc/callback";
        })
        cfg.extraEnvironment
      ];
    };

    # Load secrets from files at runtime
    systemd.services.open-webui = {
      preStart =
        mkIf
          (
            cfg.secretKeyFile != null
            || cfg.openai.apiKeyFile != null
            || cfg.oidc.clientSecretFile != null
            || (cfg.tavilySearch.enable && cfg.tavilySearch.apiKeyFile != null)
          )
          ''
            SECRETS_FILE="/run/open-webui/secrets.env"
            : > "$SECRETS_FILE"

            ${optionalString (cfg.secretKeyFile != null) ''
              echo "WEBUI_SECRET_KEY=$(cat ${cfg.secretKeyFile})" >> "$SECRETS_FILE"
            ''}
            ${optionalString (cfg.openai.apiKeyFile != null) ''
              echo "OPENAI_API_KEY=$(cat ${cfg.openai.apiKeyFile})" >> "$SECRETS_FILE"
            ''}
            ${optionalString (cfg.oidc.clientSecretFile != null) ''
              echo "OAUTH_CLIENT_SECRET=$(cat ${cfg.oidc.clientSecretFile})" >> "$SECRETS_FILE"
            ''}
            ${optionalString (cfg.tavilySearch.enable && cfg.tavilySearch.apiKeyFile != null) ''
              echo "TAVILY_API_KEY=$(cat ${cfg.tavilySearch.apiKeyFile})" >> "$SECRETS_FILE"
            ''}

            chmod 600 "$SECRETS_FILE"

            # Initialize config.json with Tavily settings if enabled and config exists
            ${optionalString cfg.tavilySearch.enable ''
              CONFIG_FILE="${cfg.stateDir}/config.json"
              if [ -f "$CONFIG_FILE" ]; then
                TAVILY_KEY=$(cat ${cfg.tavilySearch.apiKeyFile})
                ${pkgs.gnused}/bin/sed -i \
                  -e 's/"engine": "[^"]*"/"engine": "tavily"/' \
                  -e "s/\"tavily_api_key\": \"[^\"]*\"/\"tavily_api_key\": \"$TAVILY_KEY\"/" \
                  "$CONFIG_FILE"
              fi
            ''}
          '';

      serviceConfig = mkMerge [
        {
          # Systemd hardening
          DynamicUser = lib.mkForce false;
          StateDirectory = "open-webui";
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          NoNewPrivileges = true;
        }
        (mkIf
          (
            cfg.secretKeyFile != null
            || cfg.openai.apiKeyFile != null
            || cfg.oidc.clientSecretFile != null
            || (cfg.tavilySearch.enable && cfg.tavilySearch.apiKeyFile != null)
          )
          {
            RuntimeDirectory = "open-webui";
            # Use - prefix to make EnvironmentFile optional (won't fail if missing)
            EnvironmentFile = "-/run/open-webui/secrets.env";
          }
        )
      ];
    };

    # Tailscale Serve configuration
    systemd.services.tailscale-serve-open-webui = mkIf cfg.tailscaleServe.enable {
      description = "Configure Tailscale Serve for Open-WebUI";
      after = [
        "network-online.target"
        "tailscaled.service"
        "open-webui.service"
      ];
      wants = [ "network-online.target" ];
      requires = [
        "tailscaled.service"
        "open-webui.service"
      ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      # Idempotent configuration - only configure if not already set
      script = ''
        # Wait for tailscaled to be ready
        until ${pkgs.tailscale}/bin/tailscale status &>/dev/null; do
          sleep 1
        done

        # Check if serve is already configured for this port
        if ! ${pkgs.tailscale}/bin/tailscale serve status 2>/dev/null | grep -q "https:${toString cfg.tailscaleServe.httpsPort}"; then
          echo "Configuring Tailscale Serve for Open-WebUI..."
          ${pkgs.tailscale}/bin/tailscale serve --bg --https ${toString cfg.tailscaleServe.httpsPort} http://${cfg.host}:${toString cfg.port}
        else
          echo "Tailscale Serve already configured for Open-WebUI"
        fi
      '';

      # Reset serve configuration on service stop
      preStop = ''
        echo "Resetting Tailscale Serve configuration..."
        ${pkgs.tailscale}/bin/tailscale serve reset || true
      '';
    };
  };
}
