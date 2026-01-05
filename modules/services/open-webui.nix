{ config
, pkgs
, lib
, ...
}:

with lib;

let
  cfg = config.services.open-webui-tailscale;
in
{
  options.services.open-webui-tailscale = {
    enable = mkEnableOption "Open-WebUI with Tailscale Serve";

    zdrModelsOnly = {
      enable = mkEnableOption "ZDR-only models via auto-provisioned Pipe Function (disables direct OpenRouter connection)";
    };

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

    # Voice Support Configuration
    voice = {
      enable = mkEnableOption "Voice support (TTS/STT) for seamless voice conversations";

      stt = {
        engine = mkOption {
          type = types.enum [ "whisper" "openai" "deepgram" ];
          default = "whisper";
          description = ''
            Speech-to-Text engine:
            - whisper: Local Whisper model (default, works with Call mode, uses CPU/RAM)
            - openai: Uses OpenAI Whisper API (fast, requires API key)
            - deepgram: Uses Deepgram Nova (very fast, requires API key)
            Note: Browser WebAPI only works for microphone button, NOT Call mode.
          '';
        };

        openai = {
          apiKeyFile = mkOption {
            type = types.nullOr types.path;
            default = null;
            example = "/run/secrets/openai-api-key";
            description = "Path to file containing OpenAI API key for Whisper STT.";
          };
        };

        deepgram = {
          apiKeyFile = mkOption {
            type = types.nullOr types.path;
            default = null;
            example = "/run/secrets/deepgram-api-key";
            description = "Path to file containing Deepgram API key for STT.";
          };
        };
      };

      tts = {
        engine = mkOption {
          type = types.enum [ "openai" "elevenlabs" "azure" "browser" ];
          default = "openai";
          description = ''
            Text-to-Speech engine:
            - openai: OpenAI TTS (high quality, multi-language) [recommended]
            - elevenlabs: ElevenLabs TTS (premium quality)
            - azure: Azure Speech Services (requires Open-WebUI v0.4+)
            - browser: Browser's native TTS (free, quality varies)

            Note: Azure TTS is NOT supported in Open-WebUI v0.3.12. Use openai
            or elevenlabs for TTS in this version.
          '';
        };

        azure = {
          apiKeyFile = mkOption {
            type = types.nullOr types.path;
            default = null;
            example = "/run/secrets/azure-speech-api-key";
            description = ''
              Path to file containing the Azure Speech Services API key.
              Get your API key from https://portal.azure.com
              Create a Speech Services resource in your preferred region.
            '';
          };

          region = mkOption {
            type = types.str;
            default = "westeurope";
            example = "eastus";
            description = "Azure Speech Services region (e.g., westeurope, eastus).";
          };

          outputFormat = mkOption {
            type = types.str;
            default = "audio-24khz-96kbitrate-mono-mp3";
            example = "audio-48khz-192kbitrate-mono-mp3";
            description = ''
              Audio output format for Azure TTS.
              - audio-24khz-96kbitrate-mono-mp3 (balanced quality/bandwidth)
              - audio-48khz-192kbitrate-mono-mp3 (HD quality)
              - audio-16khz-64kbitrate-mono-mp3 (low bandwidth)
            '';
          };
        };

        openai = {
          apiKeyFile = mkOption {
            type = types.nullOr types.path;
            default = null;
            example = "/run/secrets/openai-api-key";
            description = "Path to file containing the OpenAI API key for TTS.";
          };

          model = mkOption {
            type = types.enum [ "tts-1" "tts-1-hd" ];
            default = "tts-1";
            description = "OpenAI TTS model (tts-1 for speed, tts-1-hd for quality).";
          };

          voice = mkOption {
            type = types.enum [ "alloy" "echo" "fable" "onyx" "nova" "shimmer" ];
            default = "nova";
            description = "OpenAI TTS voice.";
          };
        };
      };

      # Child-friendly voice mode prompt
      voiceModePrompt = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "You are a helpful, patient, and friendly assistant speaking with children.";
        description = ''
          Custom system prompt for voice conversations.
          Leave null to use OpenWebUI's default.
          For children, consider using simple language and encouraging responses.
        '';
      };
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
          ENABLE_PERSISTENT_CONFIG = "True";

          # JWT Configuration
          JWT_EXPIRES_IN = cfg.jwtExpiresIn;

          # User Management
          ENABLE_SIGNUP = if cfg.enableSignup then "True" else "False";
          DEFAULT_USER_ROLE = cfg.defaultUserRole;

          # WebUI URL for OAuth callbacks
          WEBUI_URL = cfg.webuiUrl;
        }
        # When ZDR-only mode is enabled, use a dummy URL so base connection
        # returns no models. The pipe function provides ZDR models only.
        {
          OPENAI_API_BASE_URL =
            if cfg.zdrModelsOnly.enable
            then "http://127.0.0.1:1"  # Unreachable - no models from base
            else cfg.openai.apiBaseUrl;
        }
        (mkIf cfg.tavilySearch.enable {
          ENABLE_RAG_WEB_SEARCH = "True";
          RAG_WEB_SEARCH_ENGINE = "tavily";
          RAG_WEB_SEARCH_RESULT_COUNT = "3";
          RAG_WEB_SEARCH_CONCURRENT_REQUESTS = "10";
        })
        (mkIf cfg.oidc.enable {
          OAUTH_PROVIDER_NAME = "Tailscale";
          OPENID_PROVIDER_URL = "${cfg.oidc.issuerUrl}/.well-known/openid-configuration";
          OAUTH_CLIENT_ID = cfg.oidc.clientId;
          OPENID_REDIRECT_URI = "${cfg.webuiUrl}/oauth/oidc/callback";
        })
        # Voice Support - STT Configuration
        (mkIf cfg.voice.enable (
          if cfg.voice.stt.engine == "whisper" then {
            # Empty/unset = use local Whisper model (default, works with Call mode)
          } else if cfg.voice.stt.engine == "openai" then {
            AUDIO_STT_ENGINE = "openai";
            AUDIO_STT_MODEL = "whisper-1";
          } else if cfg.voice.stt.engine == "deepgram" then {
            AUDIO_STT_ENGINE = "deepgram";
          } else { }
        ))
        # Voice Support - TTS Configuration
        (mkIf (cfg.voice.enable && cfg.voice.tts.engine == "azure") {
          AUDIO_TTS_ENGINE = "azure";
          AUDIO_TTS_AZURE_SPEECH_REGION = cfg.voice.tts.azure.region;
          AUDIO_TTS_AZURE_SPEECH_OUTPUT_FORMAT = cfg.voice.tts.azure.outputFormat;
        })
        (mkIf (cfg.voice.enable && cfg.voice.tts.engine == "openai") {
          AUDIO_TTS_ENGINE = "openai";
          AUDIO_TTS_MODEL = cfg.voice.tts.openai.model;
          AUDIO_TTS_VOICE = cfg.voice.tts.openai.voice;
        })
        (mkIf (cfg.voice.enable && cfg.voice.tts.engine == "browser") {
          AUDIO_TTS_ENGINE = "";
        })
        # Voice Mode Prompt (for child-friendly conversations)
        (mkIf (cfg.voice.enable && cfg.voice.voiceModePrompt != null) {
          VOICE_MODE_PROMPT_TEMPLATE = cfg.voice.voiceModePrompt;
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
            || (cfg.voice.enable && cfg.voice.tts.engine == "azure" && cfg.voice.tts.azure.apiKeyFile != null)
            || (cfg.voice.enable && cfg.voice.tts.engine == "openai" && cfg.voice.tts.openai.apiKeyFile != null)
            || (cfg.voice.enable && cfg.voice.stt.engine == "openai" && cfg.voice.stt.openai.apiKeyFile != null)
            || (cfg.voice.enable && cfg.voice.stt.engine == "deepgram" && cfg.voice.stt.deepgram.apiKeyFile != null)
          )
          ''
            set -euo pipefail

            SECRETS_FILE="/run/open-webui/secrets.env"
            : > "$SECRETS_FILE"

            # Helper function to safely read a secret file
            read_secret() {
              local file="$1"
              local var_name="$2"
              if [[ ! -f "$file" ]]; then
                echo "ERROR: Secret file not found: $file" >&2
                exit 1
              fi
              local value
              value=$(cat "$file")
              if [[ -z "$value" ]]; then
                echo "ERROR: Secret file is empty: $file" >&2
                exit 1
              fi
              echo "$var_name=$value" >> "$SECRETS_FILE"
            }

            ${optionalString (cfg.secretKeyFile != null) ''
              read_secret "${cfg.secretKeyFile}" "WEBUI_SECRET_KEY"
            ''}
            ${optionalString (cfg.openai.apiKeyFile != null) ''
              read_secret "${cfg.openai.apiKeyFile}" "OPENAI_API_KEY"
            ''}
            ${optionalString (cfg.oidc.clientSecretFile != null) ''
              read_secret "${cfg.oidc.clientSecretFile}" "OAUTH_CLIENT_SECRET"
            ''}
            ${optionalString (cfg.tavilySearch.enable && cfg.tavilySearch.apiKeyFile != null) ''
              read_secret "${cfg.tavilySearch.apiKeyFile}" "TAVILY_API_KEY"
            ''}
            ${optionalString (cfg.voice.enable && cfg.voice.tts.engine == "azure" && cfg.voice.tts.azure.apiKeyFile != null) ''
              read_secret "${cfg.voice.tts.azure.apiKeyFile}" "AUDIO_TTS_API_KEY"
            ''}
            ${optionalString (cfg.voice.enable && cfg.voice.tts.engine == "openai" && cfg.voice.tts.openai.apiKeyFile != null) ''
              read_secret "${cfg.voice.tts.openai.apiKeyFile}" "AUDIO_TTS_OPENAI_API_KEY"
            ''}
            ${optionalString (cfg.voice.enable && cfg.voice.stt.engine == "openai" && cfg.voice.stt.openai.apiKeyFile != null) ''
              read_secret "${cfg.voice.stt.openai.apiKeyFile}" "AUDIO_STT_OPENAI_API_KEY"
            ''}
            ${optionalString (cfg.voice.enable && cfg.voice.stt.engine == "deepgram" && cfg.voice.stt.deepgram.apiKeyFile != null) ''
              read_secret "${cfg.voice.stt.deepgram.apiKeyFile}" "DEEPGRAM_API_KEY"
            ''}

            chmod 600 "$SECRETS_FILE"
          '';

      serviceConfig = mkMerge [
        {
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
            || (cfg.voice.enable && cfg.voice.tts.engine == "azure" && cfg.voice.tts.azure.apiKeyFile != null)
            || (cfg.voice.enable && cfg.voice.tts.engine == "openai" && cfg.voice.tts.openai.apiKeyFile != null)
            || (cfg.voice.enable && cfg.voice.stt.engine == "openai" && cfg.voice.stt.openai.apiKeyFile != null)
            || (cfg.voice.enable && cfg.voice.stt.engine == "deepgram" && cfg.voice.stt.deepgram.apiKeyFile != null)
          )
          {
            RuntimeDirectory = "open-webui";
            EnvironmentFile = "-/run/open-webui/secrets.env";
          }
        )
      ];
    };

    # Provision ZDR pipe function if enabled
    systemd.services.open-webui-zdr-function = mkIf cfg.zdrModelsOnly.enable {
      description = "Provision OpenRouter ZDR Pipe Function";
      wantedBy = [ "multi-user.target" ];
      after = [ "open-webui.service" ];
      requires = [ "open-webui.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
                # Wait for Open WebUI to be ready
                sleep 5

                FUNCTIONS_DIR="${cfg.stateDir}/functions"
                DB_FILE="${cfg.stateDir}/data/webui.db"
                FUNCTION_ID="openrouter_zdr_only_models"
                FUNCTION_FILE="${./open-webui-functions/openrouter_zdr_pipe.py}"

                # Read API key from agenix secret
                API_KEY=$(cat ${cfg.openai.apiKeyFile})

                # Create valves JSON with API key
                VALVES_JSON=$(${pkgs.jq}/bin/jq -n \
                  --arg api_key "$API_KEY" \
                  '{
                    "NAME_PREFIX": "ZDR/",
                    "OPENROUTER_API_BASE_URL": "https://openrouter.ai/api/v1",
                    "OPENROUTER_API_KEY": $api_key,
                    "ZDR_CACHE_TTL": 3600,
                    "ENABLE_ZDR_ENFORCEMENT": true
                  }')

                # Create functions directory if it doesn't exist
                mkdir -p "$FUNCTIONS_DIR"

                # Copy the function file
                cp "$FUNCTION_FILE" "$FUNCTIONS_DIR/$FUNCTION_ID.py"
                chmod 600 "$FUNCTIONS_DIR/$FUNCTION_ID.py"

                # Read function content for database
                FUNCTION_CONTENT=$(cat "$FUNCTION_FILE")

                # Wait for database to exist
                for i in $(seq 1 30); do
                  if [ -f "$DB_FILE" ]; then
                    break
                  fi
                  echo "Waiting for database... ($i/30)"
                  sleep 1
                done

                if [ ! -f "$DB_FILE" ]; then
                  echo "Database not found at $DB_FILE"
                  exit 1
                fi

                # Check if function already exists
                EXISTS=$(${pkgs.sqlite}/bin/sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM function WHERE id='$FUNCTION_ID';")

                if [ "$EXISTS" = "0" ]; then
                  # Get admin user ID
                  ADMIN_ID=$(${pkgs.sqlite}/bin/sqlite3 "$DB_FILE" "SELECT id FROM user WHERE role='admin' LIMIT 1;")

                  if [ -z "$ADMIN_ID" ]; then
                    echo "No admin user found, using empty user_id"
                    ADMIN_ID=""
                  fi

                  NOW=$(date +%s)

                  # Write valves JSON to temp file for Python to read
                  VALVES_FILE=$(mktemp)
                  echo "$VALVES_JSON" > "$VALVES_FILE"

                  # Insert the function with content and valves
                  ${pkgs.python3}/bin/python3 << PYTHON
        import sqlite3
        import json
        import os

        db_file = "$DB_FILE"
        function_file = "$FUNCTION_FILE"
        valves_file = "$VALVES_FILE"
        function_id = "$FUNCTION_ID"
        admin_id = "$ADMIN_ID" or None
        now = $NOW

        conn = sqlite3.connect(db_file)
        cursor = conn.cursor()

        content = open(function_file).read()
        valves = json.load(open(valves_file))
        meta = {"description": "Only shows OpenRouter models with Zero Data Retention policy"}

        cursor.execute("""
            INSERT INTO function (id, user_id, name, type, content, meta, created_at, updated_at, valves, is_active, is_global)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (
            function_id,
            admin_id,
            "OpenRouter ZDR-Only Models",
            "pipe",
            content,
            json.dumps(meta),
            now,
            now,
            json.dumps(valves),
            1,
            1
        ))

        conn.commit()
        conn.close()
        print("Function inserted into database")
        PYTHON
                  rm -f "$VALVES_FILE"
                else
                  # Write valves JSON to temp file for Python to read
                  VALVES_FILE=$(mktemp)
                  echo "$VALVES_JSON" > "$VALVES_FILE"

                  # Update valves to ensure API key is current
                  ${pkgs.python3}/bin/python3 << PYTHON
        import sqlite3
        import json
        import time

        db_file = "$DB_FILE"
        function_file = "$FUNCTION_FILE"
        valves_file = "$VALVES_FILE"
        function_id = "$FUNCTION_ID"

        conn = sqlite3.connect(db_file)
        cursor = conn.cursor()

        valves = json.load(open(valves_file))
        content = open(function_file).read()

        cursor.execute("""
            UPDATE function
            SET valves = ?, content = ?, updated_at = ?
            WHERE id = ?
        """, (json.dumps(valves), content, int(time.time()), function_id))

        conn.commit()
        conn.close()
        print("Function valves and content updated")
        PYTHON
                  rm -f "$VALVES_FILE"
                fi

                echo "ZDR function provisioning complete"
      '';
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

      script = ''
        # Wait for tailscaled to be ready (timeout: 60 seconds)
        timeout=60
        until ${pkgs.tailscale}/bin/tailscale status &>/dev/null; do
          timeout=$((timeout - 1))
          if [ $timeout -le 0 ]; then
            echo "ERROR: tailscaled not ready after 60 seconds"
            exit 1
          fi
          sleep 1
        done

        # Wait for Open-WebUI to be listening (timeout: 60 seconds)
        # The 'after' directive only waits for service start, not port availability
        timeout=60
        while ! ${pkgs.netcat}/bin/nc -z ${cfg.host} ${toString cfg.port} 2>/dev/null; do
          timeout=$((timeout - 1))
          if [ $timeout -le 0 ]; then
            echo "ERROR: Open-WebUI not listening on port ${toString cfg.port} after 60 seconds"
            exit 1
          fi
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

      preStop = ''
        echo "Removing Tailscale Serve configuration for Open-WebUI..."
        ${pkgs.tailscale}/bin/tailscale serve --bg --https ${toString cfg.tailscaleServe.httpsPort} off || true
      '';
    };
  };
}
