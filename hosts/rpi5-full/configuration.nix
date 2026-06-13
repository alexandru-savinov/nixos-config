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
    ../../modules/services/home-assistant.nix # Home Assistant with Tailscale Serve
    ../../modules/services/home-assistant-mcp-claude.nix # hass-mcp for Claude Code
    ../../modules/system/nix-ld.nix # runtime loader so uvx-spawned hass-mcp interpreter can run
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

  # Locally-packaged tools available on this host. Ralphex orchestrates
  # Claude Code agents through multi-step plan files; lives in pkgs/ralphex.nix.
  environment.systemPackages = [
    self.packages.${pkgs.system}.ralphex
    # hass-cli — CLI agent-control level for Home Assistant
    pkgs.home-assistant-cli
    # websocat — first-class WebSocket client for HA WS-API diagnostics
    # (so checks don't depend on an off-PATH store python + hand-rolled framing)
    pkgs.websocat
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

      # Home Assistant Long-Lived Access Token (LLAT) for agent-control tooling
      # (hass-cli + voska/hass-mcp). Minted in the HA UI after owner onboarding;
      # consumed by the home-assistant-mcp-claude oneshot and by hass-cli at use
      # time. Root-owned (default) — systemd HA and the MCP config oneshot both
      # run as root.
      home-assistant-token = secret "home-assistant-token";

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

  # Advertise rpi5 as a Tailscale exit node for the tailnet.
  # Scoped here (not in modules/services/tailscale.nix) because that module is
  # shared with sancta-choir, sancta-claw, and zero-kuzea — none of which
  # should advertise exit-node. useRoutingFeatures = "both" enables IPv4/IPv6
  # forwarding via the NixOS module (sets net.ipv4.ip_forward etc).
  services.tailscale = {
    useRoutingFeatures = lib.mkForce "both";
    extraUpFlags = [ "--advertise-exit-node" ];
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

    # Node.js built-in modules in Code nodes:
    # - crypto: efficient SHA256 hashing (pure JS is slow on ARM)
    # - fs, path: file-based job status tracking for async workflow patterns
    # - child_process: NixFrame HEIC→JPEG conversion (removing from Code nodes doesn't
    #   help — n8n's Execute Command node allows the same; n8n user is systemd-sandboxed)
    allowBuiltinModules = [
      "fs"
      "path"
      "crypto"
      "child_process"
    ];

    extraEnvironment = {
      # Enable n8n Public API for Claude Code MCP integration
      N8N_PUBLIC_API_DISABLED = "false";
      # Increase task runner heap for APKG assembly (reads all card files into one JSON blob)
      N8N_RUNNERS_MAX_OLD_SPACE_SIZE = "1024";
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

    # Home Assistant LLAT injected into Gatus's env as GATUS_API_KEY (written to
    # /run/gatus/env, kept out of the nix store), referenced as ${GATUS_API_KEY}
    # in the Home Assistant endpoint header below for an authenticated health check.
    apiKeyFile = config.age.secrets.home-assistant-token.path;

    # Monitored Endpoints
    endpoints = {
      # rpi5 local services (this host)
      # rpi5-open-webui = httpEndpoint "rpi5" "Open-WebUI" "http://127.0.0.1:8080/health";
      rpi5-n8n = httpEndpoint "rpi5" "n8n" "http://127.0.0.1:5678/healthz";
      rpi5-anki-workflow = httpEndpoint "rpi5" "Anki Workflow" "http://127.0.0.1:5678/webhook/image-to-anki-ui";
      rpi5-nixframe = httpEndpoint "rpi5" "NixFrame Upload" "http://127.0.0.1:5678/webhook/nixframe-ui";
      # Authenticated HA health check — Bearer token is the LLAT, expanded by
      # Gatus from GATUS_API_KEY at runtime (never rendered into the nix store).
      rpi5-home-assistant = (httpEndpoint "rpi5" "Home Assistant" "http://127.0.0.1:8123/api/") // {
        headers = { Authorization = "Bearer \${GATUS_API_KEY}"; };
      };
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

  # ──────────────────────────────────────────────────────────────
  # Home Assistant — declarative install via native services.home-assistant
  # ──────────────────────────────────────────────────────────────
  # Bound to 127.0.0.1:8123, fronted by Tailscale Serve HTTPS.
  # Access: https://rpi5.tail4249a9.ts.net:8123
  #
  # Phase A (autonomous): secretsFile is unset (null); HA serves the
  # onboarding page without an LLAT. All token wiring is deferred until
  # after the human completes onboarding and provisions the secret file —
  # see plan-home-assistant.md Tasks 5/6.
  services.home-assistant-tailscale = {
    enable = true;
    timeZone = "Europe/Bucharest";
    tailscaleServe.enable = true;
    # Roborock Saros 10 vacuum — bundles python-roborock so the cloud-light
    # integration (Roborock account login once, then local LAN control) can be
    # configured via the Add Integration UI / config flow.
    extraComponents = [ "roborock" ];
  };

  # Explicit external/internal URLs so HA doesn't auto-detect behind the
  # Tailscale Serve reverse proxy — auto-detection sees http://127.0.0.1:8123
  # which breaks mobile app OAuth redirects (intermittent 400 on /auth/authorize).
  services.home-assistant.config.homeassistant = {
    external_url = "https://rpi5.tail4249a9.ts.net:8123";
    internal_url = "http://127.0.0.1:8123";
  };

  # Bluetooth: the RPi5 has an integrated BT adapter (hci0, UART serial0). Enable
  # the BlueZ stack so Home Assistant's bluetooth integration (pulled in by
  # default_config) can manage the adapter over D-Bus and move from setup_retry
  # to loaded. Without this, bluetoothd never runs and HA's BLE scanner fails.
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

  # Local Samsung TV control via the core `samsungtv` integration (no cloud / no
  # SmartThings). HA (192.168.1.37/24) shares the LAN with the TVs — The Frame 75
  # (QE75LS03AAUXUA) at 192.168.1.50, verified directly reachable (8001/8002 open,
  # TokenAuthSupport, no AP isolation). HA pairs over wss :8002 (an "Allow" popup
  # on the TV) and powers it on via Wake-on-LAN — the `wake_on_lan` component
  # (loaded via config.wake_on_lan below) provides the send_magic_packet service
  # used by the turn-on automation (samsungtv's implicit WoL is deprecated).
  #
  # A component toggle here is a CACHE HIT, NOT a rebuild: on nixpkgs 25.11
  # extraComponents only feeds the systemd PYTHONPATH; the home-assistant drv is
  # unchanged and the deps (samsungtvws/wakeonlan/getmac/async-upnp-client) are
  # pure-python, already in the store. (A real HA rebuild — version bump or a
  # propagatedBuildInputs overlay — is the only OOM hazard, not this.) Note:
  # extraComponents REPLACES the module default, so the 4 base components are
  # restated alongside samsungtv + wake_on_lan.
  #
  # SmartThings was removed: the Samsung soundbar (S801B) + washer are cloud-only
  # and HA's smartthings integration needs the restricted `sse` OAuth scope, which
  # Samsung grants only to HA Cloud's account-linking app — not obtainable by a
  # self-hosted OAuth app, so unusable without Nabu Casa (home-assistant/core#139551).
  #
  # Local IoT appliance integrations. `tplink` (python-kasa) controls the Tapo
  # P110 smart plug + energy sensors over the local KLAP protocol (cache-hit,
  # pure-python). The Xiaomi Humidifier 3 Lite does NOT use core `xiaomi_miio`:
  # HA core's Xiaomi cloud login (the bundled micloud library) is broken by
  # Xiaomi's now-mandatory captcha (home-assistant/core#145081, closed not-planned),
  # and the "3 Lite" is a newer MIoT model core doesn't support. Instead we use the
  # al-one `xiaomi_miot` community integration via customComponents below.
  services.home-assistant.extraComponents = [
    "default_config"
    "met"
    "esphome"
    "rpi_power"
    "samsungtv"
    "wake_on_lan"
    "tplink"
    # Google Cast — local media control of the Samsung S801B soundbar, which has
    # Chromecast built-in (ports 8008/8009; DLNA is NOT available on this B-series
    # soundbar). Gives a media_player for play/pause/volume/cast-audio/TTS over the
    # LAN (hardware power/source/EQ still require SmartThings). Auto-discovers via
    # zeroconf (default_config) — no credentials needed.
    "cast"
  ];

  # al-one/hass-xiaomi-miot ("Xiaomi Miot Auto") for the Xiaomi humidifier (and
  # future MIoT devices). NixOS-native, packaged in nixpkgs — NO HACS. It is the
  # one integration that implements Xiaomi's captcha/2FA login flow; the account
  # login is done once in the HA config flow and lives in HA's state dir, not Nix.
  services.home-assistant.customComponents = [
    pkgs.home-assistant-custom-components.xiaomi_miot
  ];

  # The al-one xiaomi_miot package (nixpkgs 1.1.1) doesn't bundle pyhap, which its
  # media_player platform imports at load — without it the whole integration fails
  # to set up ("No module named 'pyhap'"). Provide it via HA's python env.
  # hap-python is pure-python + cached, so this stays a cache hit (no HA rebuild).
  services.home-assistant.extraPackages = ps: with ps; [
    hap-python
  ];

  # Load the wake_on_lan integration (YAML-only, no config flow) so the
  # wake_on_lan.send_magic_packet service is registered for the Samsung TV
  # turn-on automation.
  services.home-assistant.config.wake_on_lan = { };

  # Wake-on-LAN turn-on automation for The Frame, declared in Nix because this
  # configuration.yaml does not `!include automations.yaml` (so UI/API-created
  # automations do not load). Fires the samsungtv `turn_on` trigger when HA is
  # asked to power the TV on while it is in standby, and sends a magic packet to
  # its MAC. Replaces samsungtv's deprecated implicit Wake-on-LAN.
  services.home-assistant.config.automation = [
    {
      id = "frame75_wol";
      alias = "The Frame 75 - Wake on LAN";
      mode = "single";
      trigger = [
        {
          platform = "samsungtv.turn_on";
          entity_id = "media_player.samsung_the_frame_75_qe75ls03aauxua";
        }
      ];
      action = [
        {
          service = "wake_on_lan.send_magic_packet";
          data.mac = "64:07:f6:da:ca:3d";
        }
      ];
    }
  ];

  # HA MCP server for Claude Code. Phase B (post-onboarding): tokenFile points
  # at the agenix-decrypted LLAT, so the per-user oneshot injects HA_TOKEN into
  # the MCP entry. The runtime `if [ -f tokenFile ]` guard in the oneshot reads
  # the decrypted file at /run/agenix/home-assistant-token.
  services.home-assistant-mcp-claude = {
    enable = true;
    users = [ "nixos" ];
    haUrl = "http://127.0.0.1:8123";
    tokenFile = config.age.secrets.home-assistant-token.path;
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

  # Operator alert when the DNS-watchdog crash-loop breaker opens (#450).
  # Reuses the backup alert credentials (TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID).
  services.tailscale-dns-watchdog.telegramEnvFile = secret "backup-telegram-env";

  # Add n8n to nixframe group so it can write photos to nixframe's home dir
  users.users.n8n.extraGroups = [ "nixframe" ];

  # Add ImageMagick to n8n PATH for HEIC conversion and EXIF auto-orient
  # Allow n8n to write to nixframe photo directory (ProtectSystem=strict blocks it)
  systemd.services.n8n = {
    path = [ pkgs.imagemagick ];
    serviceConfig = {
      ReadWritePaths = [ "/var/lib/nixframe/photos" ];
      MemoryMax = "1536M";
      MemoryHigh = "1280M";
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
  system.stateVersion = "25.05";
}
