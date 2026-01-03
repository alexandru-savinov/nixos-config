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

    # Additional services for full deployment
    ../../modules/services/open-webui.nix
    ../../modules/services/uptime-kuma.nix
    ../../modules/services/n8n.nix
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
  };

  # Open-WebUI with OpenRouter backend
  # Access via Tailscale HTTPS: https://rpi5.tail4249a9.ts.net
  services.open-webui-tailscale = {
    enable = true;
    enableSignup = false;
    secretKeyFile = config.age.secrets.open-webui-secret-key.path;
    openai.apiKeyFile = config.age.secrets.openrouter-api-key.path;
    webuiUrl = "https://rpi5.tail4249a9.ts.net";

    # Only show ZDR (Zero Data Retention) models from OpenRouter
    zdrModelsOnly.enable = true;

    # Tavily Search API for RAG web search
    tavilySearch = {
      enable = true;
      apiKeyFile = config.age.secrets.tavily-api-key.path;
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

    tailscaleServe.enable = true;
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
  };
}
