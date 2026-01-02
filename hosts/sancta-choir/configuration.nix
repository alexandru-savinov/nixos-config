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

  imports = [
    ./hardware-configuration.nix
    ../common.nix
    ../../modules/system/host.nix
    ../../modules/system/networking.nix
    ../../modules/system/nix-ld.nix
    ../../modules/users/root.nix
    ../../modules/services/copilot.nix
    ../../modules/services/claude.nix
    ../../modules/services/tailscale.nix
    ../../modules/services/tsidp.nix
    ../../modules/services/open-webui.nix
    ../../modules/services/uptime-kuma.nix
    ../../modules/services/n8n.nix
    ../../modules/services/home-assistant.nix
  ];

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

    # OpenCode API key (Open WebUI API key for LLM gateway)
    # TEMPORARILY DISABLED due to missing secret file
    # opencode-api-key.file = "${self}/secrets/opencode-api-key.age";

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

  # Uptime Kuma - Status monitoring with automatic backups and HTTPS
  # Access via Tailscale HTTPS: https://sancta-choir.tail4249a9.ts.net:3001
  services.uptime-kuma-tailscale = {
    enable = true;
    port = 3001;

    # Automatic database backups (daily, kept for 7 days)
    backup = {
      enable = true;
      schedule = "daily";
      retention = 7;
    };

    # HTTPS access via Tailscale Serve
    tailscaleServe = {
      enable = true;
      httpsPort = 3001;
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

  # Home Assistant with Tailscale and Declarative Configuration
  # Access via Tailscale HTTPS: https://sancta-choir.tail4249a9.ts.net:8123
  # DISABLED by default - enable after creating mqtt-password.age secret:
  #   cd secrets && echo "your-mqtt-password" | agenix -e mqtt-password.age && agenix -r
  services.home-assistant-tailscale = {
    enable = false; # Set to true after creating secrets

    # Declarative Home Assistant configuration
    # All automations, scripts, and scenes defined in Nix
    config = {
      # Core settings
      homeassistant = {
        name = "Home";
        unit_system = "metric";
        time_zone = "Europe/Bucharest";
        # Location stored as secrets for privacy
        # latitude = "!secret home_latitude";
        # longitude = "!secret home_longitude";
      };

      # Enable default integrations
      default_config = { };

      # MQTT integration for zigbee2mqtt (running on RPi5)
      # Replace with your RPi5's Tailscale IP
      # mqtt = {
      #   broker = "100.x.x.x";  # RPi5 Tailscale IP
      #   port = 1883;
      #   username = "homeassistant";
      #   password = "!secret mqtt_password";
      #   discovery = true;
      #   discovery_prefix = "homeassistant";
      # };

      # Example: Declarative automations
      automation = [
        {
          id = "motion_light_on";
          alias = "Turn on light when motion detected";
          trigger = {
            platform = "state";
            entity_id = "binary_sensor.motion_sensor";
            to = "on";
          };
          condition = {
            condition = "state";
            entity_id = "sun.sun";
            state = "below_horizon";
          };
          action = {
            service = "light.turn_on";
            target.entity_id = "light.living_room";
            data.brightness_pct = 80;
          };
        }
        {
          id = "motion_light_off";
          alias = "Turn off light when no motion";
          trigger = {
            platform = "state";
            entity_id = "binary_sensor.motion_sensor";
            to = "off";
            for = "00:05:00"; # 5 minutes
          };
          action = {
            service = "light.turn_off";
            target.entity_id = "light.living_room";
          };
        }
      ];

      # Example: Declarative scripts
      script = {
        bedtime_routine = {
          alias = "Bedtime Routine";
          sequence = [
            { service = "light.turn_off"; target.entity_id = "all"; }
            { delay.seconds = 5; }
            { service = "climate.set_temperature"; data.temperature = 18; }
          ];
        };
        good_morning = {
          alias = "Good Morning";
          sequence = [
            { service = "light.turn_on"; target.entity_id = "light.bedroom"; data.brightness_pct = 30; }
            { delay.seconds = 10; }
            { service = "light.turn_on"; target.entity_id = "light.bedroom"; data.brightness_pct = 100; }
          ];
        };
      };

      # Example: Declarative scenes
      scene = [
        {
          id = "movie_time";
          name = "Movie Time";
          entities = {
            "light.living_room" = { state = "on"; brightness = 50; };
            "light.tv_backlight" = { state = "on"; brightness = 30; };
          };
        }
        {
          id = "work_mode";
          name = "Work Mode";
          entities = {
            "light.office" = { state = "on"; brightness = 255; color_temp = 350; };
          };
        }
      ];
    };

    # Agenix secrets for Home Assistant
    # secrets = {
    #   mqtt_password.file = config.age.secrets.mqtt-password.path;
    #   home_latitude.file = config.age.secrets.home-latitude.path;
    #   home_longitude.file = config.age.secrets.home-longitude.path;
    # };

    # Components needed for setup (auto-discovered from config, add any missing)
    extraComponents = [
      "esphome"
      "mqtt"
      "met" # Weather
      "radio_browser"
    ];

    # Build-time config validation (catches errors before deployment)
    validateConfig = true;

    # HTTPS access via Tailscale Serve
    tailscaleServe = {
      enable = true;
      httpsPort = 8123;
    };
  };

  # Hostname
  networking.hostName = "sancta-choir";
  networking.domain = "";

  # SSH authorized keys for remote access
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPw5RFrFfZQUWlyfGSU1Q8BlEHnvIdBtcnCn+uYtEzal nixos-sancta-choir"
  ];
}
