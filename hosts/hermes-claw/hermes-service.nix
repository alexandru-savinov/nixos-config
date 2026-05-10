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
      model = {
        default = "qwen/qwen3-coder:free";
        provider = "openrouter";
        base_url = "https://openrouter.ai/api/v1";
      };
      auxiliary = {
        title_generation = { provider = "openrouter"; model = "qwen/qwen3-coder:free"; };
        compression = { provider = "openrouter"; model = "qwen/qwen3-coder:free"; };
        session_search = { provider = "openrouter"; model = "qwen/qwen3-coder:free"; };
        web_extract = { provider = "openrouter"; model = "qwen/qwen3-coder:free"; };
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
