{ config
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
        default = "tencent/hy3-preview:free";
        provider = "openrouter";
        base_url = "https://openrouter.ai/api/v1";
      };
      auxiliary = {
        title_generation = { provider = "openrouter"; model = "tencent/hy3-preview:free"; };
        compression = { provider = "openrouter"; model = "tencent/hy3-preview:free"; };
        session_search = { provider = "openrouter"; model = "tencent/hy3-preview:free"; };
        web_extract = { provider = "openrouter"; model = "tencent/hy3-preview:free"; };
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
      TELEGRAM_ALLOWED_USERS = "364749075";
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
}
