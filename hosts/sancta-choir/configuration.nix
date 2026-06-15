{ config
, pkgs
, lib
, self
, ...
}:

{
  # Pin kernel to 6.6 LTS — workaround for the Feb-2026 #252 incident, where an
  # OOM-killed build left corrupted 6.12.63 store paths that would not boot. The
  # 6.12 kernel itself is not broken; the corruption was build-time only.
  # EXIT CRITERIA (unpin only when ALL hold): (1) GC the corrupt paths on-host
  # (`nix-collect-garbage -d`); (2) a clean `nixos-rebuild build` of a 6.12 kernel
  # succeeds on-host; (3) validate via `nixos-rebuild boot` + manual reboot first.
  # Do NOT unpin remotely-untested — a bad kernel on a headless VPS needs
  # rescue-mode recovery.
  boot.kernelPackages = pkgs.linuxPackages_6_6;

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
    ./networking.nix
    ../common.nix
    ../../modules/system/dev-tools.nix
    ../../modules/users/root.nix
    ../../modules/services/claude-shared.nix
    ../../modules/services/herdr.nix
    ../../modules/services/tailscale.nix
    ../../modules/services/open-webui.nix
  ];

  # Enable development tools and Claude Code
  customModules.dev-tools.enable = true;
  customModules.claudeShared = {
    enable = true;
    # `herdr` is included so the dedicated herdr user (which runs the herdr
    # server + agent panes) gets the full Claude Code stack — claude CLI, skills,
    # agents, commands — under /var/lib/herdr/.claude, not just root.
    users = [ "root" "herdr" ];
  };

  # OpenAI Codex CLI (github.com/openai/codex) — a second terminal coding agent
  # alongside Claude Code, available to all users (incl. herdr panes) on this
  # agent-runtime host.
  environment.systemPackages = [ pkgs.codex ];

  # herdr — always-on terminal workspace server for AI coding agents. The server
  # lives here so long-running sessions survive the Mac sleeping; it runs as a
  # dedicated unprivileged `herdr` user whose only sudo is a fixed-flake deploy
  # wrapper (`herdr-deploy`) + GC — no raw nixos-rebuild/systemctl. Attach with
  # `herdr --remote herdr@sancta-choir-1.tail4249a9.ts.net`.
  customModules.herdr.enable = true;

  # Agenix secrets (defaults: owner=root, group=root, mode=0400)
  age.secrets =
    let
      inherit (import ../../lib/secrets.nix { inherit self; }) secret;
    in
    {
      tailscale-auth-key = secret "tailscale-auth-key";
      # Open-WebUI secrets
      open-webui-secret-key = secret "open-webui-secret-key";
      openrouter-api-key = secret "openrouter-api-key";
      tavily-api-key = secret "tavily-api-key";
      e2e-test-api-key = secret "e2e-test-api-key";
    };

  # ==========================================================================
  # Open-WebUI — AI chat gateway via OpenRouter
  # ==========================================================================
  # Access: https://sancta-choir-1.tail4249a9.ts.net (via Tailscale Serve)
  services.open-webui-tailscale = {
    enable = true;
    webuiUrl = "https://sancta-choir-1.tail4249a9.ts.net";
    secretKeyFile = config.age.secrets.open-webui-secret-key.path;

    # OpenRouter as LLM backend
    openai.apiKeyFile = config.age.secrets.openrouter-api-key.path;

    # OIDC via Tailscale tsidp
    oidc.enable = true;

    # Tavily web search
    tavilySearch = {
      enable = true;
      apiKeyFile = config.age.secrets.tavily-api-key.path;
    };

    # Memory features
    memory.enable = true;
    autoMemory.enable = true;

    # ZDR-only models (OpenRouter Zero Data Retention)
    zdrModelsOnly.enable = true;

    # OpenRouter cost tracking (per-request cost + credits remaining)
    costTracker.enable = true;

    # E2E testing
    testing = {
      enable = true;
      apiKeyFile = config.age.secrets.e2e-test-api-key.path;
    };

    # Tailscale Serve HTTPS (default: enabled on port 443)
    tailscaleServe.enable = true;
  };

  # Home Manager (root user config provided by modules/users/root.nix)
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
  };

  # Swap space (4GB for Open-WebUI + builds on 8GB VPS)
  swapDevices = [
    {
      device = "/swapfile";
      size = 4096; # 4GB
    }
  ];

  networking.hostName = "sancta-choir";

  # SSH authorized keys for remote access
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPw5RFrFfZQUWlyfGSU1Q8BlEHnvIdBtcnCn+uYtEzal nixos-sancta-choir"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL2btaYomBlcKG+snrIrBuTXcEaBKEGQoAaF59YWwkal nixos@rpi5"
  ];

  # Fresh install — NixOS 25.05
  system.stateVersion = "25.05";
}
