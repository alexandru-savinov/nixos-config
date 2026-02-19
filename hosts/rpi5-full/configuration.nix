# Raspberry Pi 5 Full Configuration
# Extends the minimal rpi5 config with all services (Open-WebUI, n8n, Gatus, Qdrant)
#
# IMPORTANT: This configuration should only be built NATIVELY on the RPi5.
# Do NOT use this for SD image builds - chromadb fails under QEMU emulation.
#
# Build SD image with minimal config:
#   nix build .#images.rpi5-sd-image
#
# After first boot, rebuild natively with full services:
#   sudo nixos-rebuild switch --flake github:alexandru-savinov/nixos-config#rpi5-full

{ config
, pkgs
, lib
, self
, ...
}:

{
  imports = [
    # Import the base rpi5 configuration
    ../rpi5/configuration.nix

    # ARM compatibility fix for Open-WebUI (removes chromadb on aarch64-linux)
    ../../modules/system/open-webui-arm-fix.nix

    # Additional services for full deployment
    ../../modules/services/open-webui.nix
    ../../modules/services/n8n.nix
    ../../modules/services/qdrant.nix # External vector DB for RAG on ARM
    ../../modules/services/gatus.nix # Declarative status monitoring
    ../../modules/services/nixframe.nix # Digital photo frame on HDMI-A-2
  ];

  # Package overrides for memory-constrained ARM builds
  nixpkgs.overlays = [
    (final: prev: {
      # Override n8n to increase Node.js heap size during TypeScript compilation
      #
      # Problem: n8n 1.123+ build OOMs on ARM with default Node.js heap
      # Root cause: Node.js calculates heap based on available RAM at build time.
      #             On RPi5 with active services, only ~2-3GB RAM available → ~1.5-2GB default heap
      #             ARM TypeScript compilation requires ~6GB (more than x86_64 due to architecture)
      #
      # System resources: RPi5 4GB RAM + 8GB swapfile + ~2GB zram (dynamic)
      # Solution: Set 6GB heap limit to utilize swap effectively during build
      #
      # Note: This is a build-time requirement only. Runtime n8n uses default heap.
      #
      # TODO: Monitor n8n upstream - may be optimized in future releases
      n8n = prev.n8n.overrideAttrs (old: {
        NODE_OPTIONS = "--max-old-space-size=6144"; # 6GB heap for build-time TypeScript compilation
      });
    })
  ];

  # Agenix secrets for additional services
  age.secrets = {
    # Open-WebUI secrets
    open-webui-secret-key.file = "${self}/secrets/open-webui-secret-key.age";
    openrouter-api-key.file = "${self}/secrets/openrouter-api-key.age";
    tavily-api-key.file = "${self}/secrets/tavily-api-key.age";

    # n8n workflow automation
    n8n-encryption-key.file = "${self}/secrets/n8n-encryption-key.age";
    n8n-admin-password.file = "${self}/secrets/n8n-admin-password.age";
    # n8n API key for Claude Code MCP (workflow management)
    # Generate in n8n: Settings > API > Create API Key
    n8n-api-key = {
      file = "${self}/secrets/n8n-api-key.age";
      mode = "0400"; # Readable only by root (systemd service runs as root)
    };

    # OpenAI API key (for TTS/STT)
    openai-api-key.file = "${self}/secrets/openai-api-key.age";

    # E2E test credentials
    e2e-test-api-key.file = "${self}/secrets/e2e-test-api-key.age";

    # CalDAV credentials for NixFrame calendar sidebar
    caldav-credentials = {
      file = "${self}/secrets/caldav-credentials.age";
      owner = "nixframe";
    };

    # Hetzner Cloud API token for VPS provisioning
    hcloud-api-token.file = "${self}/secrets/hcloud-api-token.age";
  };

  # Open-WebUI with OpenRouter backend
  # Access via Tailscale HTTPS: https://rpi5.tail4249a9.ts.net
  #
  # ARM Fix (Issue #64): jemalloc page size + onnxruntime crashes
  # - Polars has jemalloc compiled for 4KB pages; RPi5 kernel 6.12+ uses 16KB
  # - chromadb/onnxruntime crashes on aarch64-linux during import
  # - See: modules/system/open-webui-arm-fix.nix
  services.open-webui-tailscale = {
    enable = true;
    enableSignup = false;
    secretKeyFile = config.age.secrets.open-webui-secret-key.path;
    openai.apiKeyFile = config.age.secrets.openrouter-api-key.path;
    webuiUrl = "https://rpi5.tail4249a9.ts.net";

    # Only show ZDR (Zero Data Retention) models from OpenRouter
    zdrModelsOnly.enable = true;

    # Tavily Search API for web search (works without chromadb; document embedding requires it)
    tavilySearch = {
      enable = true;
      apiKeyFile = config.age.secrets.tavily-api-key.path;
    };

    # Vector Database: Use Qdrant instead of chromadb (which crashes on ARM)
    # This enables RAG document embedding on ARM/aarch64
    vectorDb = {
      type = "qdrant";
      qdrant = {
        uri = "http://127.0.0.1:6333";
        onDisk = true; # Use mmap storage for low memory footprint
        multitenancy = true; # Reduces RAM usage
      };
    };

    # Memory feature - required for autoMemory
    memory.enable = true;

    # Auto Memory: Automatically extract and store memories from conversations
    # Uses the configured LLM model to identify memorable facts from user messages
    autoMemory = {
      enable = true;
      model = "openai/gpt-4o-mini"; # Fast and cheap for memory extraction
    };

    # Extra environment variables for ARM compatibility
    extraEnvironment = {
      # ============================================================
      # ARM precautions: Limit threading for resource-constrained RPi5
      # Note: These do NOT fix the SIGBUS issue (see open-webui-arm-fix.nix)
      # They reduce resource contention on the quad-core ARM device
      # ============================================================
      OMP_NUM_THREADS = "1"; # OpenMP (used by PyTorch, NumPy)
      OPENBLAS_NUM_THREADS = "1"; # OpenBLAS threading
      MKL_NUM_THREADS = "1"; # Intel MKL (if present)
      NUMEXPR_NUM_THREADS = "1"; # NumExpr threading
      TOKENIZERS_PARALLELISM = "false"; # HuggingFace tokenizers

      # Disable CUDA detection (not available on ARM, but prevents probing)
      CUDA_VISIBLE_DEVICES = "";

      # RAG features now enabled via Qdrant external vector DB
      # Document embedding works! Web search continues to work via Tavily.
    };

    # OIDC authentication - disabled (same issue as sancta-choir with tsidp on same host)
    oidc.enable = false;

    # Voice Support - use OpenAI APIs for better performance on RPi5
    # Local Whisper would be too slow on ARM
    voice = {
      enable = true;

      stt = {
        engine = "openai";
        openai.apiKeyFile = config.age.secrets.openai-api-key.path;
      };

      tts = {
        engine = "openai";
        openai = {
          apiKeyFile = config.age.secrets.openai-api-key.path;
          model = "tts-1";
          voice = "nova";
        };
      };

      voiceModePrompt = ''
        You are a helpful, patient, and friendly assistant speaking with children.
        Use simple language appropriate for children.
        Be encouraging and supportive.
        Keep responses concise (1-2 sentences) for voice conversations.
        If speaking Russian, use child-friendly Russian.
        If speaking Romanian, use child-friendly Romanian.
        Always be kind and positive.
      '';
    };

    # Tailscale Serve for HTTPS (default port 443)
    tailscaleServe = {
      enable = true;
      httpsPort = 443;
    };

    # E2E Testing - declarative test user provisioning
    # Run tests with:
    #   export OPENWEBUI_TEST_API_KEY=$(sudo cat /run/open-webui/e2e-test-api-key)
    #   nix-shell --run "pytest tests/e2e/ -v"
    testing = {
      enable = true;
      apiKeyFile = config.age.secrets.e2e-test-api-key.path;
    };
  };

  # n8n Workflow Automation
  # Access via Tailscale HTTPS: https://rpi5.tail4249a9.ts.net:5678
  services.n8n-tailscale = {
    enable = true;
    encryptionKeyFile = config.age.secrets.n8n-encryption-key.path;

    # OpenRouter API key - injected as OPENROUTER_API_KEY environment variable
    # Workflows can reference it using: Bearer {{ $env.OPENROUTER_API_KEY }}
    openrouterApiKeyFile = config.age.secrets.openrouter-api-key.path;

    # OpenAI API key - for TTS pronunciation audio in image-to-anki workflow
    # Workflows can reference it using: Bearer {{ $env.OPENAI_API_KEY }}
    openaiApiKeyFile = config.age.secrets.openai-api-key.path;

    # Allow $env expressions in workflows (required for declarative API keys)
    # Safe here because workflows are controlled via workflowsDir, not user-created
    blockEnvAccessInCode = false;

    # Lower concurrency for RPi5 resource constraints
    concurrencyLimit = 2;

    # Declarative workflows - imported on service start
    # Workflows must have stable "id" field for idempotency
    workflowsDir = "${self}/n8n-workflows";

    # Wait for this webhook to be registered before completing workflow sync
    # Prevents 404 errors when accessing webhooks immediately after n8n start
    webhookHealthCheck = "image-to-anki-ui";

    # Admin password for REST API authentication (required for community packages)
    adminPasswordFile = config.age.secrets.n8n-admin-password.path;

    # Community packages installed via REST API
    # Requires adminPasswordFile to authenticate with n8n
    communityPackages = [ "n8n-nodes-zip" ];

    # Enable Node.js built-in modules in Code nodes:
    # - crypto: efficient SHA256 hashing (pure JS is slow on ARM)
    # - fs, path: file-based job status tracking for async workflow patterns
    # - child_process: ImageMagick convert for NixFrame photo processing (HEIC→JPEG, EXIF auto-orient)
    extraEnvironment = {
      NODE_FUNCTION_ALLOW_BUILTIN = "fs,path,crypto,child_process";
      # Enable n8n Public API for Claude Code MCP integration
      N8N_PUBLIC_API_DISABLED = "false";
    };

    tailscaleServe.enable = true;
  };

  # n8n MCP Server for Claude Code - FULL MODE with workflow management
  # Enables Claude Code to create/update/delete workflows via n8n API
  services.n8n-mcp-claude = {
    n8nUrl = "http://127.0.0.1:5678";
    apiKeyFile = config.age.secrets.n8n-api-key.path;
  };

  # Qdrant Vector Database - External vector DB for RAG on ARM
  # Required because chromadb crashes on aarch64-linux (onnxruntime SIGBUS)
  # Access via Tailscale HTTPS: https://rpi5.tail4249a9.ts.net:6333
  services.qdrant-tailscale = {
    enable = true;
    port = 6333;
    grpcPort = 6334;

    # On-disk storage for low memory footprint (critical for 4GB RPi5)
    # Uses mmap - trades some query speed for significantly lower RAM
    storage.onDisk = true;

    # Limit workers to reduce resource contention
    performance.maxWorkers = 2;

    # Expose via Tailscale HTTPS
    tailscaleServe = {
      enable = true;
      httpsPort = 6333;
    };
  };

  # Qdrant resource limits
  systemd.services.qdrant.serviceConfig = {
    MemoryMax = "512M";
    MemoryHigh = "384M";
    CPUQuota = "100%"; # 1 core max
    Nice = 10; # Lower priority than Open-WebUI
  };

  # RPi5 resource limits for Open-WebUI
  # These override any defaults to ensure stability on limited hardware
  systemd.services.open-webui.serviceConfig = {
    MemoryMax = "2G";
    MemoryHigh = "1536M";
    CPUQuota = "300%"; # 3 cores max
    Nice = 5;
    IOSchedulingClass = "best-effort";
    IOSchedulingPriority = 4;

    # Allow fchown syscalls - SQLite WAL mode needs these for database operations
    # Open-WebUI's systemd hardening blocks @chown group; re-allow fchown here
    SystemCallFilter = [ "fchown" "fchown32" ];
  };

  # Gatus - Declarative status monitoring with HTTPS
  # Access via Tailscale HTTPS: https://rpi5.tail4249a9.ts.net:3001
  services.gatus-tailscale = {
    enable = true;
    port = 3001;

    ui = {
      title = "RPi5 Status";
      header = "Service Health Dashboard";
    };

    storage = {
      type = "sqlite";
      caching = true;
    };

    # HTTPS access via Tailscale Serve
    tailscaleServe = {
      enable = true;
      httpsPort = 3001;
    };

    # API key for suite authentication (used as ${GATUS_API_KEY} in suite endpoints)
    # Uses the provisioned API key from Open-WebUI (not the raw agenix secret)
    apiKeyFile = "/run/open-webui/e2e-test-api-key";
    # Wait for the test user provisioning service to create the API key
    apiKeyServiceDependency = "open-webui-e2e-test-user.service";

    # Monitored Endpoints
    endpoints = {
      # ----------------------------------------------------------------------
      # rpi5 local services (this host)
      # ----------------------------------------------------------------------
      rpi5-open-webui = {
        name = "Open-WebUI";
        group = "rpi5";
        url = "http://127.0.0.1:8080/health";
        interval = "1m";
        conditions = [ "[STATUS] == 200" ];
      };

      rpi5-n8n = {
        name = "n8n";
        group = "rpi5";
        url = "http://127.0.0.1:5678/healthz";
        interval = "1m";
        conditions = [ "[STATUS] == 200" ];
      };

      rpi5-anki-workflow = {
        name = "Anki Workflow";
        group = "rpi5";
        url = "http://127.0.0.1:5678/webhook/image-to-anki-ui";
        interval = "1m";
        conditions = [ "[STATUS] == 200" ];
      };

      rpi5-nixframe = {
        name = "NixFrame Upload";
        group = "rpi5";
        url = "http://127.0.0.1:5678/webhook/nixframe-ui";
        interval = "1m";
        conditions = [ "[STATUS] == 200" ];
      };

      rpi5-qdrant = {
        name = "Qdrant";
        group = "rpi5";
        url = "http://127.0.0.1:6333/readyz";
        interval = "1m";
        conditions = [ "[STATUS] == 200" ];
      };

      rpi5-tailscale = {
        name = "Tailscale";
        group = "rpi5";
        # Use Tailscale hostname to verify actual Tailscale connectivity
        url = "icmp://rpi5.tail4249a9.ts.net";
        interval = "30s";
        conditions = [ "[CONNECTED] == true" ];
      };

      # ----------------------------------------------------------------------
      # sancta-choir services (remote host via Tailscale)
      # ----------------------------------------------------------------------
      sancta-choir-open-webui = {
        name = "Open-WebUI";
        group = "sancta-choir";
        url = "https://sancta-choir.tail4249a9.ts.net/health";
        interval = "1m";
        conditions = [
          "[STATUS] == 200"
          "[RESPONSE_TIME] < 5000" # 5s threshold for Tailscale routing latency
        ];
      };

      sancta-choir-n8n = {
        name = "n8n";
        group = "sancta-choir";
        url = "https://sancta-choir.tail4249a9.ts.net:5678/healthz";
        interval = "1m";
        conditions = [
          "[STATUS] == 200"
          "[RESPONSE_TIME] < 5000" # 5s threshold for Tailscale routing latency
        ];
      };

      sancta-choir-tailscale = {
        name = "Tailscale";
        group = "sancta-choir";
        url = "icmp://sancta-choir.tail4249a9.ts.net";
        interval = "30s";
        conditions = [ "[CONNECTED] == true" ];
      };

      # ----------------------------------------------------------------------
      # External services
      # ----------------------------------------------------------------------
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
    };

    # ==========================================================================
    # Functional Test Suites (Gatus ALPHA feature - API may change upstream)
    # ==========================================================================
    # Suites run endpoints sequentially with shared context.
    # Unlike health endpoints, these verify actual functionality works end-to-end.
    suites = {
      # LLM Chat Chain Test - Verifies Open-WebUI can actually process chat requests
      # This goes beyond health checks to ensure the full LLM pipeline works:
      # 1. Backend can list models (OpenRouter connection works)
      # 2. Chat completion returns valid response (LLM actually responds)
      chat-chain-test = {
        name = "LLM Chat Chain";
        group = "functional";
        interval = "1h"; # Run hourly - more expensive than health checks

        endpoints = [
          # Step 1: Verify OpenRouter backend is connected and models are available
          {
            name = "verify-models";
            url = "http://127.0.0.1:8080/api/models";
            headers = {
              Authorization = "Bearer \${GATUS_API_KEY}";
            };
            conditions = [
              "[STATUS] == 200"
              "len([BODY].data) > 0" # At least one model available
            ];
          }

          # Step 2: Send actual chat completion and verify LLM responds
          {
            name = "chat-completion";
            url = "http://127.0.0.1:8080/api/chat/completions";
            method = "POST";
            headers = {
              Authorization = "Bearer \${GATUS_API_KEY}";
              Content-Type = "application/json";
            };
            # Use cheap/fast model with minimal tokens for monitoring
            # Note: Model ID must match the full Open-WebUI model path (format: provider.model/name)
            body = builtins.toJSON {
              model = "openrouter_zdr_only_models.openai/gpt-4o-mini";
              messages = [{ role = "user"; content = "Reply with exactly one word: PONG"; }];
              max_tokens = 5;
              temperature = 0;
            };
            conditions = [
              "[STATUS] == 200"
              "[RESPONSE_TIME] < 30000" # 30s timeout for LLM response
            ];
          }
        ];
      };
    };
  };

  # Gatus resource limits for RPi5
  systemd.services.gatus.serviceConfig = {
    MemoryMax = "256M";
    MemoryHigh = "192M";
    CPUQuota = "50%"; # Half a core max
    Nice = 15; # Lower priority than other services
  };

  # ──────────────────────────────────────────────────────────────
  # NixFrame — Digital photo frame on HDMI-A-2
  # ──────────────────────────────────────────────────────────────
  # Displays rotating slideshow with clock sidebar on the TV.
  # Upload photos: https://rpi5.tail4249a9.ts.net:5678/webhook/nixframe-ui
  services.nixframe.enable = true;
  services.nixframe.weather.enable = true;
  services.nixframe.calendar = {
    enable = true;
    credentialsFile = config.age.secrets.caldav-credentials.path;
  };

  # Hetzner Cloud CLI for VPS provisioning (RPi5 is the control plane)
  environment.systemPackages = [ pkgs.hcloud ];

  # Add ImageMagick to n8n PATH for HEIC conversion and EXIF auto-orient
  # Allow n8n to write to nixframe photo directory (ProtectSystem=strict blocks it)
  systemd.services.n8n = {
    path = [ pkgs.imagemagick ];
    serviceConfig = {
      ReadWritePaths = [ "/var/lib/nixframe/photos" ];
      MemoryMax = "1536M";
      MemoryHigh = "1G";
      CPUQuota = "200%"; # 2 cores max
      Nice = 7; # Between Open-WebUI (5) and qdrant (10)
    };
  };
}
