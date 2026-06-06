{ config
, lib
, pkgs
, ...
}:
{
  # ── Container runtime ────────────────────────────────────────────────
  # Upstream module sets virtualisation.docker.enable = mkDefault true when
  # backend == "docker". We use podman, so explicitly disable docker.
  virtualisation.docker.enable = false;
  virtualisation.podman.enable = true;

  # ── Agenix secret: combined env file with API keys ───────────────────
  age.secrets.hermes-env = {
    file = ../../secrets/hermes-env.age;
    owner = "hermes";
    group = "hermes";
    mode = "0400";
  };

  # ── Hermes Agent (upstream NixOS module, container mode) ─────────────
  services.hermes-agent = {
    enable = true;
    addToSystemPackages = true;

    # Build the sealed venv with the `messaging` optional-dependency group so
    # python-telegram-bot is bundled. The default `all` group excludes it, so
    # without this the Telegram adapter fails to load ("python-telegram-bot not
    # installed"). Resolved by uv from the existing lock — no collision risk.
    extraDependencyGroups = [ "messaging" ];

    # Container configuration
    container = {
      enable = true;
      backend = "podman";
      image = "ubuntu:24.04";
      hostUsers = [ "root" ];
      extraOptions = [
        "--security-opt=no-new-privileges"
        # 4g: headroom for writable layer (apt cache, pip, npm) + agent tools
        "--memory=4g"
        "--cpus=2.0"
      ];
    };

    # Declarative config — deep-merged into $HERMES_HOME/config.yaml
    settings = {
      # ChatGPT subscription via the openai-codex provider (browser/device-code
      # OAuth — no API key). Credentials are NOT declarative: run a one-time
      #   podman exec -it hermes-agent /data/current-package/bin/hermes \
      #     auth add --type oauth --no-browser openai-codex
      # which writes ~/.hermes/auth.json, persisted on the host at
      # /var/lib/hermes/.hermes/auth.json (survives container recreation).
      # Model must be one your ChatGPT plan exposes (see `hermes model`);
      # gpt-5.3-codex is API-only and is rejected by the ChatGPT-account backend.
      model = {
        default = "gpt-5.5";
        provider = "openai-codex";
      };
      auxiliary = {
        title_generation = { provider = "openai-codex"; model = "gpt-5.4-mini"; };
        compression = { provider = "openai-codex"; model = "gpt-5.4-mini"; };
        session_search = { provider = "openai-codex"; model = "gpt-5.4-mini"; };
        web_extract = { provider = "openai-codex"; model = "gpt-5.4-mini"; };
      };
      toolsets = [ "all" ];
      memory = { enabled = true; };
      terminal = {
        backend = "local";
        cwd = "/data/workspace";
      };
    };

    # Secrets via combined agenix env file
    environmentFiles = [ config.age.secrets.hermes-env.path ];

    # Non-secret environment
    environment = {
      TELEGRAM_ALLOWED_USERS = "364749075,7957556729";
      HERMES_DASHBOARD = "0";
    };

    # Extra host packages available inside the container
    extraPackages = with pkgs; [
      git
      ripgrep
      jq
      curl
    ];
  };

  # ── Fix skills directory permissions ────────────────────────────────
  # Default skills are copied from the Nix store (read-only, 444/555).
  # The upstream entrypoint chown's HERMES_HOME but doesn't chmod u+w,
  # so the hermes user owns the files but can't write to them.
  # Run after the upstream activation script to ensure skills are writable.
  system.activationScripts."hermes-skills-permissions" = lib.stringAfter [ "hermes-agent-setup" ] ''
    if [ -d /var/lib/hermes/.hermes/skills ]; then
      find /var/lib/hermes/.hermes/skills -not -perm -u+w -exec chmod u+w {} +
    fi
  '';
}
