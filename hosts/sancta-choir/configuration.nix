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
    ../../modules/system/dev-tools.nix
    ../../modules/users/root.nix
    ../../modules/services/copilot.nix
    ../../modules/services/claude.nix
    ../../modules/services/tailscale.nix
    ../../modules/services/tsidp.nix
    ../../modules/services/gatus.nix
    ../../modules/services/openclaw.nix
  ];

  # Enable development tools and Claude Code
  customModules.dev-tools.enable = true;
  customModules.claude.enable = true;

  # Agenix secrets (defaults: owner=root, group=root, mode=0400)
  age.secrets = {
    # Tailscale
    tailscale-auth-key.file = "${self}/secrets/tailscale-auth-key.age";

    # OpenClaw AI programming partner
    anthropic-api-key.file = "${self}/secrets/anthropic-api-key.age";
    openclaw-github-token.file = "${self}/secrets/openclaw-github-token.age";
  };

  # Gatus - Declarative status monitoring with HTTPS
  # Access via Tailscale HTTPS: https://sancta-choir.tail4249a9.ts.net:3001
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
    endpoints = {
      # ----------------------------------------------------------------------
      # sancta-choir services (this host)
      # ----------------------------------------------------------------------
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

  # OpenClaw AI programming partner
  # Uses Claude Code CLI in one-shot mode for automated task execution
  # Tasks arrive via file-based inbox, results written to /var/lib/openclaw/results/
  services.openclaw = {
    enable = true;
    anthropicApiKeyFile = config.age.secrets.anthropic-api-key.path;
    githubTokenFile = config.age.secrets.openclaw-github-token.path;
    repoUrl = "https://github.com/alexandru-savinov/nixos-config.git";
    repoBranch = "main";
    model = "sonnet";
    maxTurns = 50;
    maxBudgetUsd = 5.0;
    allowedBuildTargets = [ "sancta-choir" ];
    resourceLimits = {
      memoryMax = "4G";
      cpuQuota = "200%";
    };
    tailscaleServe = {
      enable = false; # Phase 2: enable when HTTP server is implemented
    };
    networkRestriction.enable = true;
  };

  # Hostname
  networking.hostName = "sancta-choir";
  networking.domain = "";

  # SSH authorized keys for remote access
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPw5RFrFfZQUWlyfGSU1Q8BlEHnvIdBtcnCn+uYtEzal nixos-sancta-choir"
  ];
}
