{ config
, pkgs
, pkgs-unstable
, lib
, ...
}:

with lib;

let
  cfg = config.services.open-webui-tailscale;

  # Create open-webui package with qdrant-client when needed
  # This is required because the default open-webui package doesn't include qdrant-client
  # See: https://github.com/nixos/nixpkgs/issues/422030
  # Uses pkgs-unstable for latest open-webui version and Python dependency compatibility
  openWebuiWithQdrant = pkgs-unstable.open-webui.overridePythonAttrs (oldAttrs: {
    propagatedBuildInputs = (oldAttrs.propagatedBuildInputs or [ ]) ++ [
      pkgs-unstable.python3Packages.qdrant-client
    ];
  });
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

      fastMode = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Enable fast web search mode that skips the full RAG pipeline.

          When enabled (default), web searches use only Tavily snippets instead of:
          1. Fetching full page content from search results
          2. Chunking and generating embeddings
          3. Storing in vector database
          4. Querying embeddings for context

          Performance: ~2-3 seconds (fast mode) vs ~40+ seconds (full RAG)

          Disable for deep research where full page content improves answer quality.
          Recommended to keep enabled on resource-constrained devices (RPi5).
        '';
      };
    };

    # Vector Database Configuration (for RAG document embedding)
    # Required on ARM where chromadb is disabled due to onnxruntime crashes
    vectorDb = {
      type = mkOption {
        type = types.enum [ "chromadb" "qdrant" "pgvector" "milvus" "opensearch" ];
        default = "chromadb";
        description = ''
          Vector database backend for RAG document embedding.
          - chromadb: Default, embedded (NOT available on ARM/aarch64)
          - qdrant: Recommended for ARM, low memory with on_disk mode
          - pgvector: PostgreSQL extension (requires PostgreSQL setup)
          - milvus: Milvus vector database
          - opensearch: OpenSearch with vector support
        '';
      };

      qdrant = {
        uri = mkOption {
          type = types.str;
          default = "http://127.0.0.1:6333";
          description = "Qdrant server URI.";
        };

        apiKeyFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "Path to file containing Qdrant API key (if authentication enabled).";
        };

        onDisk = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Enable on-disk storage mode for Qdrant.
            Significantly reduces RAM usage at cost of some query speed.
            Recommended for memory-constrained devices (RPi5).
          '';
        };

        multitenancy = mkOption {
          type = types.bool;
          default = true;
          description = "Enable multitenancy mode for collection management (reduces RAM).";
        };

        collectionPrefix = mkOption {
          type = types.str;
          default = "open-webui";
          description = "Prefix for Qdrant collection names.";
        };
      };

      pgvector = {
        dbUrl = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "postgresql://user:pass@localhost/openwebui";
          description = "PostgreSQL connection URL with pgvector extension.";
        };
      };

      milvus = {
        uri = mkOption {
          type = types.str;
          default = "http://127.0.0.1:19530";
          description = "Milvus server URI.";
        };
      };
    };

    # Memory Feature Configuration (Experimental)
    # Allows models to store and retrieve long-term information about users
    # Each user gets their own vector collection for semantic memory search
    memory = {
      enable = mkEnableOption "persistent memory feature for LLMs" // {
        default = true;
      };
    };

    # Auto Memory Filter - Automatically extracts memories from conversations
    # Requires memory.enable = true for the underlying storage
    autoMemory = {
      enable = mkEnableOption "automatic memory extraction from conversations";

      model = mkOption {
        type = types.str;
        default = "openai/gpt-4o-mini";
        example = "anthropic/claude-3-haiku";
        description = ''
          LLM model to use for memory extraction.
          Should be fast and inexpensive since it runs on every message.
          Uses the OpenRouter API (hardcoded to openrouter.ai/api/v1).
          Model names must use OpenRouter format: provider/model-name.
        '';
      };

      relatedMemoriesCount = mkOption {
        type = types.int;
        default = 5;
        description = "Number of related memories to check for duplicates.";
      };

      relatedMemoriesDistance = mkOption {
        type = types.float;
        default = 0.75;
        description = "Distance threshold for similar memories (lower = more similar).";
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
      default = "https://rpi5.tail4249a9.ts.net";
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

    # E2E Testing Support
    testing = {
      enable = mkEnableOption "Declarative test user provisioning for E2E tests";

      apiKeyFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = "/run/agenix/e2e-test-api-key";
        description = ''
          Path to agenix secret file that enables test user provisioning.
          When set (along with testing.enable), a test user with JWT API key
          is provisioned automatically. The generated API key is written to
          /run/open-webui/e2e-test-api-key for E2E tests to read.

          Note: The file content is not used directly - the API key is
          JWT-generated using secretKeyFile at runtime.
        '';
      };

      userEmail = mkOption {
        type = types.str;
        default = "e2e-test@local.test";
        description = "Email address for the test user.";
      };

      userName = mkOption {
        type = types.str;
        default = "E2E Test User";
        description = "Display name for the test user.";
      };
    };
  };

  config = mkIf cfg.enable {
    # Create dedicated system user and group for open-webui
    # This replaces DynamicUser to ensure consistent file ownership
    # across the main service and all helper services
    users.users.open-webui = {
      isSystemUser = true;
      group = "open-webui";
      home = cfg.stateDir;
      description = "Open-WebUI service user";
    };

    users.groups.open-webui = { };

    # Warn if no secret key file is provided
    warnings = optional (cfg.secretKeyFile == null) ''
      services.open-webui-tailscale.secretKeyFile is not set!
      Using default WEBUI_SECRET_KEY is INSECURE for production.
      Generate a secret: openssl rand -hex 32
      Store it with agenix or sops-nix.
    '';

    # Assertions for configuration dependencies
    assertions = [
      {
        assertion = cfg.testing.enable -> cfg.secretKeyFile != null;
        message = "services.open-webui-tailscale.secretKeyFile must be set when testing.enable is true (required for JWT API key generation)";
      }
      {
        assertion = cfg.autoMemory.enable -> cfg.memory.enable;
        message = "services.open-webui-tailscale.memory.enable must be true when autoMemory.enable is true (autoMemory requires memory storage)";
      }
      {
        assertion = cfg.autoMemory.enable -> cfg.openai.apiKeyFile != null;
        message = "services.open-webui-tailscale.openai.apiKeyFile must be set when autoMemory.enable is true (required for memory extraction LLM)";
      }
    ];

    # Open-WebUI service configuration
    services.open-webui = {
      enable = true;
      inherit (cfg) host port stateDir;
      openFirewall = false; # Accessed via Tailscale only

      # Always use pkgs-unstable for latest open-webui version
      # Add qdrant-client when qdrant vector DB is selected
      package =
        if (cfg.vectorDb.type == "qdrant")
        then openWebuiWithQdrant
        else pkgs-unstable.open-webui;

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
        # Enable API keys for E2E testing
        (mkIf cfg.testing.enable {
          ENABLE_API_KEYS = "true";
        })
        # When ZDR-only mode is enabled, use a dummy URL so base connection
        # returns no models. The pipe function provides ZDR models only.
        {
          OPENAI_API_BASE_URL =
            if cfg.zdrModelsOnly.enable
            then "http://127.0.0.1:1"  # Unreachable - no models from base
            else cfg.openai.apiBaseUrl;
        }
        (mkIf cfg.tavilySearch.enable {
          # Open-WebUI 0.6+ uses ENABLE_WEB_SEARCH (not ENABLE_RAG_WEB_SEARCH)
          ENABLE_WEB_SEARCH = "True";
          WEB_SEARCH_ENGINE = "tavily";
          WEB_SEARCH_RESULT_COUNT = "3";
          WEB_SEARCH_CONCURRENT_REQUESTS = "10";
        })
        # Fast web search mode: skip page fetching and embedding for ~10x faster searches
        # Uses only Tavily snippets instead of full RAG pipeline
        # See: https://docs.openwebui.com/getting-started/env-configuration/
        (mkIf (cfg.tavilySearch.enable && cfg.tavilySearch.fastMode) {
          BYPASS_WEB_SEARCH_WEB_LOADER = "True";
          BYPASS_WEB_SEARCH_EMBEDDING_AND_RETRIEVAL = "True";
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
        # Vector Database Configuration
        # Only configure if not using default chromadb
        (mkIf (cfg.vectorDb.type != "chromadb") {
          VECTOR_DB = cfg.vectorDb.type;
        })
        # Qdrant-specific configuration
        (mkIf (cfg.vectorDb.type == "qdrant") {
          QDRANT_URI = cfg.vectorDb.qdrant.uri;
          QDRANT_ON_DISK = if cfg.vectorDb.qdrant.onDisk then "True" else "False";
          ENABLE_QDRANT_MULTITENANCY_MODE = if cfg.vectorDb.qdrant.multitenancy then "True" else "False";
          QDRANT_COLLECTION_PREFIX = cfg.vectorDb.qdrant.collectionPrefix;
        })
        # pgvector-specific configuration
        (mkIf (cfg.vectorDb.type == "pgvector" && cfg.vectorDb.pgvector.dbUrl != null) {
          PGVECTOR_DB_URL = cfg.vectorDb.pgvector.dbUrl;
        })
        # Milvus-specific configuration
        (mkIf (cfg.vectorDb.type == "milvus") {
          MILVUS_URI = cfg.vectorDb.milvus.uri;
        })
        # Memory feature configuration
        # Stores per-user memories in vector DB for semantic retrieval
        (mkIf cfg.memory.enable {
          ENABLE_MEMORIES = "True";
          USER_PERMISSIONS_FEATURES_MEMORIES = "True";
        })
        cfg.extraEnvironment
      ];
    };

    # Load secrets from files at runtime using a separate script
    # This runs via ExecStartPre to avoid conflicts with upstream preStart
    systemd.services.open-webui = {
      # Ensure Qdrant is running before Open-WebUI starts when using Qdrant vector DB
      after = mkIf (cfg.vectorDb.type == "qdrant") [ "qdrant.service" ];
      wants = mkIf (cfg.vectorDb.type == "qdrant") [ "qdrant.service" ];

      serviceConfig = mkMerge [
        {
          # Run as dedicated user instead of root
          # This overrides upstream's DynamicUser=true with a static user
          # for consistent file ownership across main + helper services
          DynamicUser = lib.mkForce false;
          User = "open-webui";
          Group = "open-webui";
          StateDirectory = "open-webui";
          StateDirectoryMode = "0750";
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
            || (cfg.vectorDb.type == "qdrant" && cfg.vectorDb.qdrant.apiKeyFile != null)
          )
          {
            RuntimeDirectory = "open-webui";
            EnvironmentFile = "-/run/open-webui/secrets.env";
            # Run secrets setup script as root (+ prefix) to read agenix secrets,
            # then chown the env file so the open-webui user can read it
            ExecStartPre = lib.mkBefore [
              ("+" + pkgs.writeShellScript "open-webui-secrets" ''
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
                ${optionalString (cfg.vectorDb.type == "qdrant" && cfg.vectorDb.qdrant.apiKeyFile != null) ''
                  read_secret "${cfg.vectorDb.qdrant.apiKeyFile}" "QDRANT_API_KEY"
                ''}

                chmod 600 "$SECRETS_FILE"
                chown open-webui:open-webui "$SECRETS_FILE"
              '')
            ];
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
        # Run as open-webui user for database access
        User = "open-webui";
        Group = "open-webui";
      };

      script = ''
                set -euo pipefail

                FUNCTIONS_DIR="${cfg.stateDir}/functions"
                DB_FILE="${cfg.stateDir}/data/webui.db"
                FUNCTION_ID="openrouter_zdr_only_models"
                FUNCTION_FILE="${./open-webui-functions/openrouter_zdr_pipe.py}"

                # Read API key from secrets.env (created by main service's ExecStartPre)
                # This avoids needing root access to read agenix secrets directly
                if [ -f /run/open-webui/secrets.env ]; then
                  source /run/open-webui/secrets.env || {
                    echo "ERROR: Failed to parse /run/open-webui/secrets.env" >&2
                    exit 1
                  }
                  if [ -z "''${OPENAI_API_KEY:-}" ]; then
                    echo "ERROR: OPENAI_API_KEY not found in secrets.env" >&2
                    echo "HINT: Ensure services.open-webui-tailscale.openai.apiKeyFile is configured" >&2
                    exit 1
                  fi
                  API_KEY="$OPENAI_API_KEY"
                else
                  echo "ERROR: /run/open-webui/secrets.env not found" >&2
                  exit 1
                fi

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
                  trap 'rm -f "$VALVES_FILE"' EXIT
                  echo "$VALVES_JSON" > "$VALVES_FILE"

                  # Export variables for Python (avoids shell injection via quoted HEREDOC)
                  export DB_FILE FUNCTION_FILE VALVES_FILE FUNCTION_ID ADMIN_ID NOW

                  # Insert the function with content and valves
                  ${pkgs.python3}/bin/python3 << 'PYTHON'
        import sqlite3
        import json
        import os

        db_file = os.environ["DB_FILE"]
        function_file = os.environ["FUNCTION_FILE"]
        valves_file = os.environ["VALVES_FILE"]
        function_id = os.environ["FUNCTION_ID"]
        admin_id = os.environ.get("ADMIN_ID") or None
        now = int(os.environ["NOW"])

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
                else
                  # Write valves JSON to temp file for Python to read
                  VALVES_FILE=$(mktemp)
                  trap 'rm -f "$VALVES_FILE"' EXIT
                  echo "$VALVES_JSON" > "$VALVES_FILE"

                  # Export variables for Python (avoids shell injection via quoted HEREDOC)
                  export DB_FILE FUNCTION_FILE VALVES_FILE FUNCTION_ID

                  # Update valves to ensure API key is current
                  ${pkgs.python3}/bin/python3 << 'PYTHON'
        import sqlite3
        import json
        import time
        import os

        db_file = os.environ["DB_FILE"]
        function_file = os.environ["FUNCTION_FILE"]
        valves_file = os.environ["VALVES_FILE"]
        function_id = os.environ["FUNCTION_ID"]

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
                fi

                echo "ZDR function provisioning complete"
      '';
    };

    # E2E Test User Provisioning
    # Creates admin user with JWT API key for E2E testing
    systemd.services.open-webui-e2e-test-user = mkIf (cfg.testing.enable && cfg.testing.apiKeyFile != null) {
      description = "Provision E2E Test User for Open-WebUI";
      wantedBy = [ "multi-user.target" ];
      after = [ "open-webui.service" ];
      requires = [ "open-webui.service" ];

      path = [
        pkgs.sqlite
        pkgs.util-linux
        (pkgs.python3.withPackages (ps: [ ps.pyjwt ps.bcrypt ]))
      ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Run as open-webui user for database access
        User = "open-webui";
        Group = "open-webui";
        RuntimeDirectory = "open-webui";
        RuntimeDirectoryMode = "0755";
      };

      script = ''
                set -euo pipefail

                # Export variables for Python to read via os.environ (avoids shell injection)
                export DB_FILE="${cfg.stateDir}/data/webui.db"
                export USER_EMAIL="${cfg.testing.userEmail}"
                export USER_NAME="${cfg.testing.userName}"

                echo "Waiting for Open-WebUI database..."
                for i in $(seq 1 60); do
                  if [ -f "$DB_FILE" ]; then
                    break
                  fi
                  echo "Waiting for database... ($i/60)"
                  sleep 1
                done

                if [ ! -f "$DB_FILE" ]; then
                  echo "ERROR: Database not found at $DB_FILE after 60 seconds"
                  exit 1
                fi

                # Read the WEBUI_SECRET_KEY from secrets.env (created by main service's ExecStartPre)
                # This avoids needing root access to read agenix secrets directly
                if [ -f /run/open-webui/secrets.env ]; then
                  source /run/open-webui/secrets.env || {
                    echo "ERROR: Failed to parse /run/open-webui/secrets.env" >&2
                    exit 1
                  }
                  if [ -z "''${WEBUI_SECRET_KEY:-}" ]; then
                    echo "ERROR: WEBUI_SECRET_KEY not found in secrets.env" >&2
                    echo "HINT: Ensure services.open-webui-tailscale.secretKeyFile is configured" >&2
                    exit 1
                  fi
                  export SECRET_KEY="$WEBUI_SECRET_KEY"
                else
                  echo "ERROR: /run/open-webui/secrets.env not found" >&2
                  exit 1
                fi

                # Run Python script to provision user with proper JWT API key
                python3 << 'PYEOF'
        import sqlite3
        import json
        import time
        import uuid
        import os
        import jwt
        import bcrypt

        # Read from environment variables (safer than shell interpolation)
        db_path = os.environ["DB_FILE"]
        secret_key = os.environ["SECRET_KEY"]
        user_email = os.environ["USER_EMAIL"]
        user_name = os.environ["USER_NAME"]

        conn = sqlite3.connect(db_path)
        cursor = conn.cursor()

        # Check if user exists
        cursor.execute("SELECT id FROM user WHERE email=?", (user_email,))
        row = cursor.fetchone()

        now = int(time.time())

        if row:
            user_id = row[0]
            print(f"E2E test user already exists (id={user_id}), updating...")
        else:
            user_id = str(uuid.uuid4())
            print(f"Creating new E2E test user: {user_email}")

            # Insert user with admin role (api_key moved to separate table in 0.7.x)
            cursor.execute("""
                INSERT INTO user (id, name, email, role, profile_image_url, created_at, updated_at, last_active_at)
                VALUES (?, ?, ?, 'admin', '/static/user.png', ?, ?, ?)
            """, (user_id, user_name, user_email, now, now, now))

        # Ensure user has admin role
        cursor.execute("""
            UPDATE user SET role='admin', updated_at=? WHERE id=?
        """, (now, user_id))

        # Generate JWT API key
        payload = {
            "id": user_id,
            "iat": now,
            "jti": str(uuid.uuid4()),
        }
        token = jwt.encode(payload, secret_key, algorithm="HS256")
        api_key = f"sk-{token}"
        key_id = f"e2e-test-{user_id[:8]}"

        # Delete existing API key for this user (if any) and insert new one
        # Open-WebUI 0.7.x moved api_key from user table to separate api_key table
        cursor.execute("DELETE FROM api_key WHERE user_id=?", (user_id,))
        cursor.execute("""
            INSERT INTO api_key (id, user_id, key, data, expires_at, last_used_at, created_at, updated_at)
            VALUES (?, ?, ?, '{}', NULL, NULL, ?, ?)
        """, (key_id, user_id, api_key, now, now))
        print(f"Created API key in api_key table (id={key_id})")

        # Create or update auth entry (required for API key auth)
        cursor.execute("SELECT id FROM auth WHERE id=?", (user_id,))
        if not cursor.fetchone():
            # Generate random password hash (not used, API key auth only)
            random_pw = str(uuid.uuid4())
            pw_hash = bcrypt.hashpw(random_pw.encode(), bcrypt.gensalt()).decode()
            cursor.execute("""
                INSERT INTO auth (id, email, password, active)
                VALUES (?, ?, ?, 1)
            """, (user_id, user_email, pw_hash))
            print("Created auth entry for E2E test user")

        # Enable API keys in config if not already enabled
        cursor.execute("SELECT data FROM config LIMIT 1")
        config_row = cursor.fetchone()
        if config_row:
            config = json.loads(config_row[0])
            if "features" not in config:
                config["features"] = {}
            if not config["features"].get("enable_api_keys"):
                config["features"]["enable_api_keys"] = True
                cursor.execute("UPDATE config SET data=?", (json.dumps(config),))
                print("Enabled API keys in config")

        conn.commit()
        conn.close()

        print(f"E2E test user provisioned successfully")
        # Note: API key is stored in database only, not logged for security
        PYEOF

                # Write the generated API key to a file for E2E tests to read
                # This file is created fresh each run with the current API key
                API_KEY_OUTPUT="/run/open-webui/e2e-test-api-key"
                python3 -c '
        import sqlite3
        import sys
        import os
        conn = sqlite3.connect(os.environ["DB_FILE"])
        cursor = conn.cursor()
        # Open-WebUI 0.7.x: api_key moved from user table to separate api_key table
        cursor.execute("""
            SELECT ak.key FROM api_key ak
            JOIN user u ON ak.user_id = u.id
            WHERE u.email = ?
            ORDER BY ak.created_at DESC LIMIT 1
        """, (os.environ["USER_EMAIL"],))
        row = cursor.fetchone()
        conn.close()
        if not row:
            user_email = os.environ["USER_EMAIL"]
            print(f"ERROR: No API key found for {user_email}", file=sys.stderr)
            print("Check open-webui-e2e-test-user service logs for setup failures", file=sys.stderr)
            sys.exit(1)
        print(row[0], end="")
        ' > "$API_KEY_OUTPUT"
                chmod 600 "$API_KEY_OUTPUT"
                echo "API key written to $API_KEY_OUTPUT"
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
      # PartOf ensures this service restarts when open-webui restarts
      # Without this, Requires= only stops this service but doesn't restart it
      partOf = [ "open-webui.service" ];

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
        if ! ${pkgs.tailscale}/bin/tailscale serve --bg --https ${toString cfg.tailscaleServe.httpsPort} off; then
          echo "WARNING: Failed to remove Tailscale Serve configuration for port ${toString cfg.tailscaleServe.httpsPort}. Manual cleanup may be required." >&2
        fi
      '';
    };

    # Memory Feature Migration
    # Updates existing database to enable memory feature (PersistentConfig vars)
    # This is needed because ENABLE_MEMORIES is only read from env on first launch
    systemd.services.open-webui-memory-migration = mkIf cfg.memory.enable {
      description = "Enable Memory Feature in Open-WebUI Database";
      wantedBy = [ "multi-user.target" ];
      after = [ "open-webui.service" ];
      requires = [ "open-webui.service" ];

      path = [
        pkgs.sqlite
        (pkgs.python3.withPackages (ps: [ ]))
      ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Run as open-webui user for database and state directory access
        User = "open-webui";
        Group = "open-webui";
      };

      script = ''
                set -euo pipefail

                DB_FILE="${cfg.stateDir}/data/webui.db"
                MARKER_FILE="${cfg.stateDir}/.memory-migration-complete"

                # Skip if migration already completed
                if [ -f "$MARKER_FILE" ]; then
                  echo "Memory migration already completed, skipping"
                  exit 0
                fi

                echo "Waiting for Open-WebUI database..."
                for i in $(seq 1 60); do
                  if [ -f "$DB_FILE" ]; then
                    break
                  fi
                  echo "Waiting for database... ($i/60)"
                  sleep 1
                done

                if [ ! -f "$DB_FILE" ]; then
                  echo "ERROR: Database not found at $DB_FILE after 60 seconds"
                  exit 1
                fi

                # Wait for schema to be ready (config table must exist)
                echo "Waiting for database schema to be initialized..."
                for i in $(seq 1 30); do
                  if sqlite3 "$DB_FILE" "SELECT 1 FROM config LIMIT 1" >/dev/null 2>&1; then
                    echo "Database schema is ready"
                    break
                  fi
                  if [ "$i" -eq 30 ]; then
                    echo "ERROR: Database schema not ready after 30 seconds"
                    echo "HINT: The config table does not exist. Open-WebUI may not have started properly."
                    exit 1
                  fi
                  echo "Waiting for schema... ($i/30)"
                  sleep 1
                done

                # Update config to enable memory feature
                # Uses Python to safely handle JSON merging with proper error handling
                python3 << 'PYEOF'
        import sqlite3
        import json
        import sys

        db_path = "${cfg.stateDir}/data/webui.db"

        try:
            conn = sqlite3.connect(db_path, timeout=30)
        except sqlite3.OperationalError as e:
            print(f"ERROR: Cannot connect to database at {db_path}: {e}")
            print("HINT: The database may be locked by Open-WebUI or corrupted")
            sys.exit(1)

        try:
            cursor = conn.cursor()

            # Get current config
            try:
                cursor.execute("SELECT data FROM config LIMIT 1")
            except sqlite3.OperationalError as e:
                print(f"ERROR: Failed to query config table: {e}")
                conn.close()
                sys.exit(1)

            row = cursor.fetchone()

            if row:
                try:
                    config = json.loads(row[0])
                except json.JSONDecodeError as e:
                    print(f"ERROR: Config data in database is not valid JSON: {e}")
                    conn.close()
                    sys.exit(1)
            else:
                print("WARNING: No existing config found in database, creating new config")
                print("HINT: This is normal on first run, but may indicate data loss on existing installs")
                config = {"version": 0}

            # Ensure features section exists
            if "features" not in config:
                config["features"] = {}

            # Enable memory features if not already enabled
            changed = False
            if not config["features"].get("enable_memories"):
                config["features"]["enable_memories"] = True
                changed = True
                print("Enabled enable_memories in config")

            if not config["features"].get("enable_memory_tool"):
                config["features"]["enable_memory_tool"] = True
                changed = True
                print("Enabled enable_memory_tool in config")

            # Ensure user permissions for memory
            if "permissions" not in config:
                config["permissions"] = {}
            if "features" not in config["permissions"]:
                config["permissions"]["features"] = {}
            if not config["permissions"]["features"].get("memory"):
                config["permissions"]["features"]["memory"] = True
                changed = True
                print("Enabled user memory permission in config")

            if changed:
                try:
                    cursor.execute("UPDATE config SET data = ? WHERE rowid = 1", (json.dumps(config),))
                    if cursor.rowcount == 0:
                        print("WARNING: No config row found to update, inserting new row")
                        cursor.execute("INSERT INTO config (data) VALUES (?)", (json.dumps(config),))
                    conn.commit()
                    print(f"Memory feature migration complete (updated {cursor.rowcount} row(s))")
                except sqlite3.OperationalError as e:
                    print(f"ERROR: Failed to update config in database: {e}")
                    print("HINT: Database may be locked, disk may be full, or filesystem may be read-only")
                    conn.close()
                    sys.exit(1)
            else:
                print("Memory feature already enabled, no changes needed")

        finally:
            conn.close()
        PYEOF

                # Mark migration as complete
                touch "$MARKER_FILE"
                echo "Migration marker created at $MARKER_FILE"
      '';
    };

    # Auto Memory Filter Provisioning
    # Installs the auto memory extraction function into Open-WebUI
    systemd.services.open-webui-auto-memory-function = mkIf cfg.autoMemory.enable {
      description = "Provision Auto Memory Filter Function for Open-WebUI";
      wantedBy = [ "multi-user.target" ];
      after = [ "open-webui.service" "open-webui-memory-migration.service" ];
      requires = [ "open-webui.service" ];

      path = [
        pkgs.sqlite
        (pkgs.python3.withPackages (ps: [ ]))
      ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Run as open-webui user for database access
        User = "open-webui";
        Group = "open-webui";
      };

      script = ''
                set -euo pipefail

                DB_FILE="${cfg.stateDir}/data/webui.db"
                FUNCTION_ID="auto_memory_filter"
                FUNCTION_FILE="${./open-webui-functions/auto_memory_filter.py}"

                # Read API key from secrets.env (created by main service's ExecStartPre)
                # This avoids needing root access to read agenix secrets directly
                if [ -f /run/open-webui/secrets.env ]; then
                  source /run/open-webui/secrets.env || {
                    echo "ERROR: Failed to parse /run/open-webui/secrets.env" >&2
                    exit 1
                  }
                  if [ -z "''${OPENAI_API_KEY:-}" ]; then
                    echo "ERROR: OPENAI_API_KEY not found in secrets.env" >&2
                    echo "HINT: Ensure services.open-webui-tailscale.openai.apiKeyFile is configured" >&2
                    exit 1
                  fi
                  API_KEY="$OPENAI_API_KEY"
                else
                  echo "ERROR: /run/open-webui/secrets.env not found" >&2
                  exit 1
                fi

                # Wait for database to exist
                echo "Waiting for Open-WebUI database..."
                for i in $(seq 1 60); do
                  if [ -f "$DB_FILE" ]; then
                    break
                  fi
                  echo "Waiting for database... ($i/60)"
                  sleep 1
                done

                if [ ! -f "$DB_FILE" ]; then
                  echo "ERROR: Database not found at $DB_FILE"
                  exit 1
                fi

                # Wait for schema to be ready (with timeout validation)
                echo "Waiting for database schema..."
                SCHEMA_READY=false
                for i in $(seq 1 30); do
                  if sqlite3 "$DB_FILE" "SELECT 1 FROM function LIMIT 1" >/dev/null 2>&1; then
                    SCHEMA_READY=true
                    break
                  fi
                  echo "Waiting for schema... ($i/30)"
                  sleep 1
                done

                if [ "$SCHEMA_READY" != "true" ]; then
                  echo "ERROR: Database schema not ready after 30 seconds"
                  echo "The 'function' table does not exist - Open-WebUI may not have started properly"
                  exit 1
                fi

                # Export variables for Python
                export DB_FILE FUNCTION_FILE FUNCTION_ID API_KEY
                export MODEL="${cfg.autoMemory.model}"
                export RELATED_N="${toString cfg.autoMemory.relatedMemoriesCount}"
                export RELATED_DIST="${toString cfg.autoMemory.relatedMemoriesDistance}"
                export STATE_DIR="${cfg.stateDir}"

                # Use Python to install/update the function
                python3 << 'PYTHON'
        import sqlite3
        import json
        import os
        import time

        db_file = os.environ["DB_FILE"]
        function_file = os.environ["FUNCTION_FILE"]
        function_id = os.environ["FUNCTION_ID"]
        api_key = os.environ["API_KEY"]
        model = os.environ["MODEL"]
        related_n = int(os.environ["RELATED_N"])
        related_dist = float(os.environ["RELATED_DIST"])
        state_dir = os.environ["STATE_DIR"]

        # Read function content
        with open(function_file) as f:
            content = f.read()

        # Build valves configuration
        valves = {
            "openai_api_url": "https://openrouter.ai/api/v1",
            "model": model,
            "api_key": api_key,
            "related_memories_n": related_n,
            "related_memories_dist": related_dist,
            "auto_save_user": True,
            "direct_db_path": f"{state_dir}/data/webui.db",
            "enabled": True,
        }

        meta = {
            "description": "Automatically extracts and stores memories from conversations"
        }

        conn = sqlite3.connect(db_file)
        cursor = conn.cursor()

        # Check if function exists
        cursor.execute("SELECT id FROM function WHERE id = ?", (function_id,))
        exists = cursor.fetchone()

        now = int(time.time())

        if exists:
            # Update existing function
            cursor.execute("""
                UPDATE function
                SET content = ?, valves = ?, meta = ?, updated_at = ?, is_active = 1, is_global = 1
                WHERE id = ?
            """, (content, json.dumps(valves), json.dumps(meta), now, function_id))
            print(f"Updated auto memory filter function")
        else:
            # Get admin user ID for ownership
            cursor.execute("SELECT id FROM user WHERE role='admin' LIMIT 1")
            row = cursor.fetchone()
            admin_id = row[0] if row else ""

            # Insert new function
            cursor.execute("""
                INSERT INTO function (id, user_id, name, type, content, meta, created_at, updated_at, valves, is_active, is_global)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, (
                function_id,
                admin_id,
                "Auto Memory Filter",
                "filter",
                content,
                json.dumps(meta),
                now,
                now,
                json.dumps(valves),
                1,
                1,
            ))
            print(f"Installed auto memory filter function")

        conn.commit()
        conn.close()
        print("Auto memory filter provisioning complete")
        PYTHON
      '';
    };
  };
}
