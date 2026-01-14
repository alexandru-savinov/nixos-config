# Raspberry Pi 5 Full Configuration
# Extends the minimal rpi5 config with all services (Open-WebUI, n8n, Uptime Kuma)
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
    ../../modules/services/uptime-kuma.nix
    ../../modules/services/n8n.nix
    ../../modules/services/qdrant.nix # External vector DB for RAG on ARM
  ];

  # Agenix secrets for additional services
  age.secrets = {
    # Open-WebUI secrets
    open-webui-secret-key.file = "${self}/secrets/open-webui-secret-key.age";
    openrouter-api-key.file = "${self}/secrets/openrouter-api-key.age";
    tavily-api-key.file = "${self}/secrets/tavily-api-key.age";

    # n8n workflow automation
    n8n-encryption-key.file = "${self}/secrets/n8n-encryption-key.age";

    # OpenAI API key (for TTS/STT)
    openai-api-key.file = "${self}/secrets/openai-api-key.age";

    # E2E test credentials
    e2e-test-api-key.file = "${self}/secrets/e2e-test-api-key.age";
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

    # Auto Memory: Automatically extract and store memories from conversations
    # Uses a fast LLM (gpt-4o-mini) to identify memorable facts from user messages
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

  # Uptime Kuma - Status monitoring with automatic backups and HTTPS
  # Access via Tailscale HTTPS: https://rpi5.tail4249a9.ts.net:3001
  services.uptime-kuma-tailscale = {
    enable = true;
    port = 3001;

    backup = {
      enable = true;
      schedule = "daily";
      retention = 7;
    };

    tailscaleServe = {
      enable = true;
      httpsPort = 3001;
    };
  };

  # n8n Workflow Automation
  # Access via Tailscale HTTPS: https://rpi5.tail4249a9.ts.net:5678
  services.n8n-tailscale = {
    enable = true;
    encryptionKeyFile = config.age.secrets.n8n-encryption-key.path;

    # Lower concurrency for RPi5 resource constraints
    concurrencyLimit = 2;

    # Declarative workflows - imported on service start
    # Workflows must have stable "id" field for idempotency
    workflowsDir = "${self}/n8n-workflows";

    tailscaleServe.enable = true;
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
}
