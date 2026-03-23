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

let
  secret = name: config.age.secrets.${name}.path;
  openaiApiKeyPath = secret "openai-api-key";

  # Gatus endpoint helpers — reduce boilerplate across monitored services
  httpEndpoint = group: name: url: {
    inherit name group url;
    interval = "1m";
    conditions = [ "[STATUS] == 200" ];
  };

  remoteHttpEndpoint = group: name: url: {
    inherit name group url;
    interval = "1m";
    conditions = [
      "[STATUS] == 200"
      "[RESPONSE_TIME] < 5000" # 5s threshold for Tailscale routing latency
    ];
  };

  icmpEndpoint = group: name: url: {
    inherit name group url;
    interval = "30s";
    conditions = [ "[CONNECTED] == true" ];
  };
in
{
  imports = [
    # Import the base rpi5 configuration
    ../rpi5/configuration.nix

    # Open-WebUI and Qdrant disabled — too heavy for RPi5 right now
    # ../../modules/system/open-webui-arm-fix.nix
    # ../../modules/services/open-webui.nix
    # ../../modules/services/qdrant.nix # External vector DB for RAG on ARM

    # Additional services for full deployment
    ../../modules/services/n8n.nix
    ../../modules/services/gatus.nix # Declarative status monitoring
    ../../modules/services/nixframe.nix # Digital photo frame (auto-detects HDMI output)
    ../../modules/services/backup-pull.nix # Pull backups from sancta-claw
    ../../modules/system/ssh-hardened.nix
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
  age.secrets =
    let
      inherit (import ../../lib/secrets.nix { inherit self; }) secret ownedSecret;
    in
    {
      # Open-WebUI (disabled)
      # open-webui-secret-key = secret "open-webui-secret-key";
      openrouter-api-key = secret "openrouter-api-key"; # also used by n8n
      # tavily-api-key = secret "tavily-api-key";
      openai-api-key = secret "openai-api-key"; # also used by n8n
      # e2e-test-api-key = secret "e2e-test-api-key";

      # n8n workflow automation
      n8n-encryption-key = secret "n8n-encryption-key";
      n8n-admin-password = secret "n8n-admin-password";
      telegram-bot-token = secret "telegram-bot-token";

      # n8n API key for Claude Code MCP (workflow management)
      # Generate in n8n: Settings > API > Create API Key
      n8n-api-key = {
        file = "${self}/secrets/n8n-api-key.age";
        mode = "0400"; # Readable only by root (systemd service runs as root)
      };

      # CalDAV credentials for NixFrame calendar sidebar
      caldav-credentials = ownedSecret "nixframe" "caldav-credentials";

      # Backup pull secrets
      rpi5-backup-ssh-key = {
        file = "${self}/secrets/rpi5-backup-ssh-key.age";
        mode = "0400";
      };
      restic-password = {
        file = "${self}/secrets/restic-password.age";
        mode = "0400";
      };
      backup-telegram-env = {
        file = "${self}/secrets/backup-telegram-env.age";
        mode = "0400";
      };
    };

  # Open-WebUI DISABLED — too heavy for RPi5 (triton-llvm, torch, etc.)
  # To re-enable: uncomment imports above, secrets, and this block
  # services.open-webui-tailscale = { ... };

  # n8n Workflow Automation
  # Access via Tailscale HTTPS: https://rpi5.tail4249a9.ts.net:5678
  services.n8n-tailscale = {
    enable = true;
    encryptionKeyFile = secret "n8n-encryption-key";

    # OpenRouter API key - injected as OPENROUTER_API_KEY environment variable
    # Workflows can reference it using: Bearer {{ $env.OPENROUTER_API_KEY }}
    openrouterApiKeyFile = secret "openrouter-api-key";

    # OpenAI API key - for TTS pronunciation audio in image-to-anki workflow
    # Workflows can reference it using: Bearer {{ $env.OPENAI_API_KEY }}
    openaiApiKeyFile = openaiApiKeyPath;

    # Telegram bot token - for tender monitor and other workflow notifications
    telegramBotTokenFile = secret "telegram-bot-token";

    # N8N_BLOCK_ENV_ACCESS_IN_NODE is all-or-nothing: it blocks $env in ALL
    # expression fields (HTTP Request headers, etc.), not just Code nodes.
    # Our workflows use {{ $env.OPENROUTER_API_KEY }} in HTTP Request headers,
    # so we must keep this disabled until workflows migrate to n8n Credentials. (#229)
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
    adminPasswordFile = secret "n8n-admin-password";

    # Community packages installed via REST API
    # Requires adminPasswordFile to authenticate with n8n
    communityPackages = [ "n8n-nodes-zip" ];

    # Enable Node.js built-in modules in Code nodes:
    # - crypto: efficient SHA256 hashing (pure JS is slow on ARM)
    # - fs, path: file-based job status tracking for async workflow patterns
    # - child_process: NixFrame HEIC→JPEG conversion (removing from Code nodes doesn't
    #   help — n8n's Execute Command node allows the same; n8n user is systemd-sandboxed)
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
    apiKeyFile = secret "n8n-api-key";
  };

  # Qdrant and Open-WebUI DISABLED — see comment above
  # services.qdrant-tailscale = { ... };
  # systemd.services.qdrant.serviceConfig = { ... };
  # systemd.services.open-webui.serviceConfig = { ... };

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

    # API key for suite authentication — disabled with Open-WebUI
    # apiKeyFile = "/run/open-webui/e2e-test-api-key";
    # apiKeyServiceDependency = "open-webui-e2e-test-user.service";

    # Monitored Endpoints
    endpoints = {
      # rpi5 local services (this host)
      # rpi5-open-webui = httpEndpoint "rpi5" "Open-WebUI" "http://127.0.0.1:8080/health";
      rpi5-n8n = httpEndpoint "rpi5" "n8n" "http://127.0.0.1:5678/healthz";
      rpi5-anki-workflow = httpEndpoint "rpi5" "Anki Workflow" "http://127.0.0.1:5678/webhook/image-to-anki-ui";
      rpi5-nixframe = httpEndpoint "rpi5" "NixFrame Upload" "http://127.0.0.1:5678/webhook/nixframe-ui";
      # rpi5-qdrant = httpEndpoint "rpi5" "Qdrant" "http://127.0.0.1:6333/readyz";
      rpi5-tailscale = icmpEndpoint "rpi5" "Tailscale" "icmp://rpi5.tail4249a9.ts.net";

      # sancta-claw services (remote VPS via Tailscale)
      sancta-claw-openclaw = remoteHttpEndpoint "sancta-claw" "OpenClaw Gateway" "https://sancta-claw.tail4249a9.ts.net:18789/healthz";
      sancta-claw-tailscale = icmpEndpoint "sancta-claw" "Tailscale" "icmp://sancta-claw.tail4249a9.ts.net";

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
    };

    # Functional test suites disabled with Open-WebUI
    # suites = { chat-chain-test = { ... }; };
  };

  # Gatus resource limits for RPi5
  systemd.services.gatus.serviceConfig = {
    MemoryMax = "256M";
    MemoryHigh = "192M";
    CPUQuota = "50%"; # Half a core max
    Nice = 15; # Lower priority than other services
  };

  # ──────────────────────────────────────────────────────────────
  # NixFrame — Digital photo frame (auto-detects HDMI output)
  # ──────────────────────────────────────────────────────────────
  # Displays rotating slideshow with clock sidebar on the TV.
  # Upload photos: https://rpi5.tail4249a9.ts.net:5678/webhook/nixframe-ui
  services.nixframe = {
    enable = true;
    weather.enable = true;
    calendar = {
      enable = true;
      credentialsFile = secret "caldav-credentials";
    };
  };

  # ── Backup: pull from sancta-claw ──────────────────────────────────────
  # Daily rsync → tmpfs staging → restic encrypted repo
  # See modules/services/backup-pull.nix for architecture details
  services.backup-pull = {
    enable = true;
    remoteHost = "46.225.168.24"; # sancta-claw public IP (bypasses Tailscale SSH policy)
    remotePaths = [ "/" ]; # relative to rrsync root (/var/lib/openclaw)
    sshKeyFile = secret "rpi5-backup-ssh-key";
    resticPasswordFile = secret "restic-password";
    excludePatterns = [
      "sessions/"
      "*.log"
      ".cache/"
      "node_modules/"
      ".npm/"
      ".npm-global/lib/"
      "models/" # whisper models (~607M), re-downloadable
      ".config/vdirsyncer/" # contains plaintext CalDAV credentials (in agenix)
      ".node-compile-cache/" # transient Node.js bytecode cache
    ];
    telegramEnvFile = secret "backup-telegram-env";
  };

  # Add n8n to nixframe group so it can write photos to nixframe's home dir
  users.users.n8n.extraGroups = [ "nixframe" ];

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

  # ── Security hardening (overrides base rpi5 bootstrap defaults) ─────────
  # Base rpi5 allows password auth + passwordless sudo for SD-card first boot.
  # In production (rpi5-full), lock these down via ssh-hardened.nix import.
  #
  # Passwordless sudo for nixos user is safe here because:
  # - SSH password auth is disabled (key-only)
  # - The nixos user is accessed via `su` from root (who is also key-only)
  # security.sudo.wheelNeedsPassword left at base default (false)

  # Fresh install — NixOS 25.05
  # mkOverride 49 beats rpi5's mkForce (priority 50) which fights nixos-raspberrypi upstream
  # mkForce needed: rpi5-full imports rpi5/configuration.nix which sets "24.05"
  system.stateVersion = lib.mkForce "25.05";
}
