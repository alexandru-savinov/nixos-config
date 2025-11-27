{ config
, pkgs
, lib
, self
, ...
}:

{
  imports = [
    ./hardware-configuration.nix
    ../common.nix
    ../../modules/system/host.nix
    ../../modules/system/networking.nix
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

  # Uptime Kuma - Status monitoring
  # Access via Tailscale: http://sancta-choir.tail4249a9.ts.net:3001
  services.uptime-kuma-tailscale = {
    enable = true;
    port = 3001;
  };

  # Hostname
  networking.hostName = "sancta-choir";
  networking.domain = "";

  # SSH authorized keys for remote access
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPw5RFrFfZQUWlyfGSU1Q8BlEHnvIdBtcnCn+uYtEzal nixos-sancta-choir"
  ];
}
