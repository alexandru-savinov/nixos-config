{ config
, pkgs
, lib
, self
, claude-code
, ...
}:

{
  # Enable aarch64 emulation for cross-building RPi5 images
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  # Add nix-community cache for pre-built RPi5 kernels
  # Also add claude-code cachix for pre-built Claude Code binaries
  nix.settings = {
    substituters = [
      "https://cache.nixos.org"
      "https://nix-community.cachix.org"
      "https://claude-code.cachix.org"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "claude-code.cachix.org-1:p3pMxGi7K+xT7I3dLghdlrUijD8s+wfQlmWp8gQ/TJA="
    ];
  };

  # Allow insecure n8n package (CVE-2025-68613 - evaluate risk for your use case)
  nixpkgs.config.permittedInsecurePackages = [
    "n8n-1.91.3"
  ];

  imports = [
    ./hardware-configuration.nix
    ../common.nix
    ../../modules/system/host.nix
    ../../modules/system/networking.nix
    ../../modules/system/nix-ld.nix
    ../../modules/system/dev-tools.nix
    ../../modules/users/root.nix
    ../../modules/services/copilot.nix
    ../../modules/services/claude.nix
    ../../modules/services/tailscale.nix
    ../../modules/services/tsidp.nix
    ../../modules/services/open-webui.nix
    ../../modules/services/gatus.nix
    ../../modules/services/n8n.nix
  ];

  # Enable development tools and Claude Code
  customModules.dev-tools.enable = true;
  customModules.claude.enable = true;
  customModules.claude.agentTeams.enable = true;

  # Agenix secrets (defaults: owner=root, group=root, mode=0400)
  age.secrets = {
    # Open-WebUI secrets
    open-webui-secret-key.file = "${self}/secrets/open-webui-secret-key.age";
    openrouter-api-key.file = "${self}/secrets/openrouter-api-key.age";
    oidc-client-secret.file = "${self}/secrets/oidc-client-secret.age";
    tavily-api-key.file = "${self}/secrets/tavily-api-key.age";

    # Tailscale
    tailscale-auth-key.file = "${self}/secrets/tailscale-auth-key.age";

    # n8n workflow automation
    n8n-encryption-key.file = "${self}/secrets/n8n-encryption-key.age";

    # OpenAI API key (for TTS/STT - separate from OpenRouter)
    openai-api-key.file = "${self}/secrets/openai-api-key.age";
  };

  # Open-WebUI with OpenRouter and Tailscale OAuth
  services.open-webui-tailscale = {
    enable = true;
    enableSignup = false; # Disabled - signup closed
    secretKeyFile = config.age.secrets.open-webui-secret-key.path;
    openai.apiKeyFile = config.age.secrets.openrouter-api-key.path;
    webuiUrl = "https://sancta-choir.tail4249a9.ts.net";

    # Only show ZDR (Zero Data Retention) models from OpenRouter
    zdrModelsOnly.enable = true;

    # Tavily Search API
    tavilySearch = {
      enable = true;
      apiKeyFile = config.age.secrets.tavily-api-key.path;
    };

    # Tailscale OIDC authentication - DISABLED
    # Note: tsidp OAuth doesn't work when both services run on same host
    # Due to tsnet isolation - the sancta-choir daemon cannot see the idp tsnet node as a peer
    # Future: Deploy tsidp on separate machine or wait for tsnet improvements
    oidc = {
      enable = false;
      issuerUrl = "http://100.68.185.44";
      clientId = "open-webui";
      clientSecretFile = config.age.secrets.oidc-client-secret.path;
    };

    # Voice Support - Seamless hands-free voice conversations for children
    # STT: Local Whisper (works with Call mode, uses CPU)
    # TTS: OpenAI TTS (high quality, supports multiple languages)
    voice = {
      enable = true;

      stt.engine = "whisper"; # Local Whisper - works with Call mode (phone icon)

      tts = {
        engine = "openai";
        openai = {
          apiKeyFile = config.age.secrets.openai-api-key.path;
          model = "tts-1"; # tts-1 for speed, tts-1-hd for quality
          voice = "nova"; # Options: alloy, echo, fable, onyx, nova, shimmer
        };
      };

      # Child-friendly voice mode prompt
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
  };

  # Gatus - Declarative status monitoring with HTTPS
  # Access via Tailscale HTTPS: https://sancta-choir.tail4249a9.ts.net:3001
  # Replaces Uptime Kuma for fully NixOS-native configuration
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

    # HTTPS access via Tailscale Serve
    tailscaleServe = {
      enable = true;
      httpsPort = 3001;
    };

    # ==========================================================================
    # Monitored Endpoints
    # ==========================================================================
    # Services are grouped by host for organization.
    endpoints = {
      # ----------------------------------------------------------------------
      # sancta-choir services (this host)
      # ----------------------------------------------------------------------
      sancta-choir-open-webui = {
        name = "Open-WebUI";
        group = "sancta-choir";
        url = "http://127.0.0.1:8080/health";
        interval = "1m";
        conditions = [ "[STATUS] == 200" ];
      };

      sancta-choir-n8n = {
        name = "n8n";
        group = "sancta-choir";
        url = "http://127.0.0.1:5678/healthz";
        interval = "1m";
        conditions = [ "[STATUS] == 200" ];
      };

      sancta-choir-tailscale = {
        name = "Tailscale";
        group = "sancta-choir";
        url = "icmp://100.68.185.44";
        interval = "30s";
        conditions = [ "[CONNECTED] == true" ];
      };

      # ----------------------------------------------------------------------
      # rpi5 services (remote host via Tailscale)
      # ----------------------------------------------------------------------
      rpi5-open-webui = {
        name = "Open-WebUI";
        group = "rpi5";
        url = "https://rpi5.tail4249a9.ts.net/health";
        interval = "1m";
        conditions = [
          "[STATUS] == 200"
          "[RESPONSE_TIME] < 5000" # 5s threshold for Tailscale routing latency
        ];
      };

      rpi5-n8n = {
        name = "n8n";
        group = "rpi5";
        url = "https://rpi5.tail4249a9.ts.net:5678/healthz";
        interval = "1m";
        conditions = [
          "[STATUS] == 200"
          "[RESPONSE_TIME] < 5000" # 5s threshold for Tailscale routing latency
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

      external-tavily = {
        name = "Tavily API";
        group = "external";
        url = "https://api.tavily.com/";
        interval = "5m";
        # Tavily returns 4xx without auth headers; only treat 5xx server errors as failures
        conditions = [ "[STATUS] < 500" ];
      };
    };
  };

  # n8n Workflow Automation
  # Access via Tailscale HTTPS: https://sancta-choir.tail4249a9.ts.net:5678
  # Used as AI agent orchestration platform with Open-WebUI as LLM gateway
  services.n8n-tailscale = {
    enable = true;
    encryptionKeyFile = config.age.secrets.n8n-encryption-key.path;

    # HTTPS access via Tailscale Serve (service binds to localhost only)
    tailscaleServe.enable = true;
  };

  # Hostname
  networking.hostName = "sancta-choir";
  networking.domain = "";

  # SSH authorized keys for remote access
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPw5RFrFfZQUWlyfGSU1Q8BlEHnvIdBtcnCn+uYtEzal nixos-sancta-choir"
  ];
}
