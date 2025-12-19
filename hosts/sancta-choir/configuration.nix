{ config
, pkgs
, lib
, self
, ...
}:

{
  # Enable aarch64 emulation for cross-building RPi5 images
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  # Add nix-community cache for pre-built RPi5 kernels
  nix.settings = {
    substituters = [
      "https://cache.nixos.org"
      "https://nix-community.cachix.org"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
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
    ../../modules/services/tailscale.nix
    ../../modules/services/tsidp.nix
    ../../modules/services/open-webui.nix
    ../../modules/services/uptime-kuma.nix
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

    # OpenCode API key (Open WebUI API key for LLM gateway)
    # TEMPORARILY DISABLED due to missing secret file
    # opencode-api-key.file = "${self}/secrets/opencode-api-key.age";
  };

  # Open-WebUI with OpenRouter and Tailscale OAuth
  services.open-webui-tailscale = {
    enable = true;
    enableSignup = false; # Disabled - signup closed
    secretKeyFile = config.age.secrets.open-webui-secret-key.path;
    openai.apiKeyFile = config.age.secrets.openrouter-api-key.path;
    webuiUrl = "https://sancta-choir.tail4249a9.ts.net";

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

  # Hostname
  networking.hostName = "sancta-choir";
  networking.domain = "";

  # SSH authorized keys for remote access
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPw5RFrFfZQUWlyfGSU1Q8BlEHnvIdBtcnCn+uYtEzal nixos-sancta-choir"
  ];
}
