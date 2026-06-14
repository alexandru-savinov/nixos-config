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

    # Build the sealed venv with the `messaging` optional-dependency group
    # so python-telegram-bot (and discord.py, slack-sdk, qrcode) are
    # bundled. The default `all` group excludes them; without this, the
    # Telegram adapter logs "python-telegram-bot not installed / No
    # adapter available for telegram" and the bot stops responding
    # silently after every container recreation (writable layer wipes
    # any prior apt/pip install). Resolved by uv from the existing lock
    # — no collision risk.
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
      # OpenRouter via the `openrouter` provider. API key in agenix secret
      # `hermes-env` (OPENROUTER_API_KEY). Previously tried ChatGPT
      # subscription via openai-codex/gpt-5.5 (PR #467) but the user is on
      # the free plan — every call hit HTTP 429 usage_limit_reached. The
      # `:free` Nemotron variant is blocked by OpenRouter's privacy
      # guardrail (404 "No endpoints available matching your guardrail
      # restrictions"); the paid Nemotron routes via DeepInfra and runs
      # cleanly. Cost observed: ~$0.000007 per `reply: pong` call.
      model = {
        default = "nvidia/nemotron-3-super-120b-a12b";
        provider = "openrouter";
        base_url = "https://openrouter.ai/api/v1";
      };
      auxiliary = {
        title_generation = { provider = "openrouter"; model = "nvidia/nemotron-3-super-120b-a12b"; };
        compression = { provider = "openrouter"; model = "nvidia/nemotron-3-super-120b-a12b"; };
        session_search = { provider = "openrouter"; model = "nvidia/nemotron-3-super-120b-a12b"; };
        web_extract = { provider = "openrouter"; model = "nvidia/nemotron-3-super-120b-a12b"; };
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
