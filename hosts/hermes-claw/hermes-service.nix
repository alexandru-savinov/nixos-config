{ config
, pkgs
, lib
, ...
}:
let
  # Image pinned by tag AND digest. The tag scheme is date-based (v2026.X.Y),
  # not semver — verified via `curl https://hub.docker.com/v2/repositories/
  # nousresearch/hermes-agent/tags/`. Pinning by digest defends against
  # silent retag / supply-chain swap. Bump both pieces together when upgrading.
  hermesImage = "docker.io/nousresearch/hermes-agent:v2026.4.30@sha256:900e1f8076662a20a685142321808085cc0b2935bb904b234c6828b4d7fb0f77";
  dataDir = "/var/lib/hermes/data";
  # User's personal Telegram chat ID — same value used in nullclaw and openclaw
  # watchers. Not a secret (it's just a numeric ID).
  telegramAllowedUsers = "364749075";

  # Pin the model + provider in code. The upstream Docker entrypoint copies
  # cli-config.yaml.example to /opt/data/config.yaml ONLY IF the path is
  # missing — and that example defaults to anthropic/claude-opus-4.6 (paid).
  # Per upstream .env.example "LLM_MODEL is no longer read from .env", so the
  # only way to enforce free+ZDR routing is to pre-place config.yaml.
  # Bind-mounted read-only from /nix/store so the file can't drift on the host.
  hermesConfigYamlBody = ''
    # Managed by NixOS (hosts/hermes-claw/hermes-service.nix). Edits will be
    # overwritten on the next deploy. Pin keeps the agent on free+ZDR rails.
    model:
      default: "qwen/qwen3-coder:free"
      provider: "openrouter"
      base_url: "https://openrouter.ai/api/v1"
  '';
  hermesConfigYaml = pkgs.writeText "hermes-config.yaml" hermesConfigYamlBody;

  hermesAgentEnvBody = ''
    set -euo pipefail
    BOT_TOKEN=$(${pkgs.coreutils}/bin/tr -d "\n" < "${config.age.secrets.zero-kuzea-telegram-bot-token.path}")
    OR_KEY=$(${pkgs.coreutils}/bin/tr -d "\n" < "${config.age.secrets.openrouter-api-key.path}")
    # Fail fast on silently-empty agenix material (matches nullclaw pattern).
    [ -n "$BOT_TOKEN" ] || { echo "ERROR: telegram bot token is empty" >&2; exit 1; }
    [ -n "$OR_KEY" ] || { echo "ERROR: openrouter api key is empty" >&2; exit 1; }
    umask 077
    ${pkgs.coreutils}/bin/cat > /run/hermes-agent/env <<EOF
    TELEGRAM_BOT_TOKEN=$BOT_TOKEN
    TELEGRAM_ALLOWED_USERS=${telegramAllowedUsers}
    OPENROUTER_API_KEY=$OR_KEY
    HERMES_DASHBOARD=0
    EOF
    ${pkgs.coreutils}/bin/chmod 0600 /run/hermes-agent/env
  '';
in
{
  # Expose env-injection script body + config.yaml body for module-eval tests
  # (Task 6). Mirrors the openclawBrowserConfigBody pattern in sancta-claw.
  # Pure-evaluable (no readFile of /nix/store paths).
  system.build.hermesAgentEnvBody = hermesAgentEnvBody;
  system.build.hermesConfigYamlBody = hermesConfigYamlBody;

  virtualisation.podman.enable = true;
  virtualisation.oci-containers.backend = "podman";

  users.users.hermes = {
    isSystemUser = true;
    group = "hermes";
    home = dataDir;
    createHome = true;
  };
  users.groups.hermes = { };

  systemd.tmpfiles.rules = [
    "d ${dataDir} 0750 hermes hermes -"
  ];

  virtualisation.oci-containers.containers.hermes-agent = {
    image = hermesImage;
    autoStart = true;
    cmd = [
      "gateway"
      "run"
    ];
    # API only on loopback. No public port. Dashboard (9119) intentionally not exposed.
    ports = [ "127.0.0.1:8642:8642" ];
    volumes = [
      "${dataDir}:/opt/data"
      # Read-only bind-mount over the persistent volume's config.yaml. The
      # entrypoint's `[ ! -f config.yaml ] && cp example` branch is bypassed
      # because the file already exists (from this mount), so the upstream
      # default model (anthropic/claude-opus-4.6 — paid) never lands.
      "${hermesConfigYaml}:/opt/data/config.yaml:ro"
    ];
    environmentFiles = [ "/run/hermes-agent/env" ];
    extraOptions = [
      "--security-opt=no-new-privileges"
      "--cap-drop=ALL"
      # `--read-only` removed: triggers `crun: write: No space left on device`
      # at OCI spec prep time on this image (verified empirically — even an
      # empty bind-mount + tmpfs /tmp config fails before the entrypoint runs,
      # so it's not an upstream Python bytecode write). Container security
      # boundary remains: namespace isolation + dropped caps + no-new-privs;
      # rootfs writes are ephemeral (vanish on container remove). Reintroduce
      # once the upstream crun/image interaction is understood.
      # tmpfs size MUST be >=1g for this image — crun fails at OCI spec prep
      # with a misleading "No space left on device" if smaller (verified
      # empirically: 64m/256m/512m all fail; 1g works). The container's actual
      # /tmp usage at startup is modest, so 1g is comfortable headroom; the
      # tmpfs counts against the container's --memory budget.
      "--tmpfs=/tmp:size=1g"
      "--shm-size=256m"
      "--memory=2g"
      "--cpus=2.0"
    ];
  };

  # Override auto-generated podman-hermes-agent.service: add secret-injection
  # ExecStartPre + restart policy.
  #
  # NOTE on hardening: this unit is the container *manager* — it shells out
  # to `podman run --pull missing` which writes images to /var/lib/containers/
  # storage, container state to /run/containers, and manages cgroups. Applying
  # ProtectSystem=strict / ProtectControlGroups / PrivateDevices to *this*
  # unit would block podman from doing its job. Workload hardening lives on
  # the container itself via `extraOptions` (--cap-drop=ALL,
  # --security-opt=no-new-privileges, tmpfs, memory/cpu caps), which the
  # kernel actually applies inside the container's namespace.
  systemd.services.podman-hermes-agent = {
    serviceConfig = {
      # Secrets reach the container via `oci-containers.containers.hermes-agent
      # .environmentFiles` (podman parses it with `--env-file` — read by podman,
      # not exported into its host-process env). Deliberately NOT setting
      # `EnvironmentFile=` here — that would also export TELEGRAM_BOT_TOKEN +
      # OPENROUTER_API_KEY into /proc/$pid/environ of the podman wrapper.
      RuntimeDirectory = "hermes-agent";
      RuntimeDirectoryMode = "0700";
      ExecStartPre = [
        (pkgs.writeShellScript "hermes-agent-setup-env" hermesAgentEnvBody)
      ];
      Restart = lib.mkForce "on-failure";
      RestartSec = lib.mkForce "10s";
    };
  };

  # Alias unit so `systemctl is-active hermes-agent` works without the podman- prefix.
  # BindsTo (not just Requires) so the alias goes inactive when the underlying
  # container service stops or fails — without this, the oneshot would remain
  # active after a container crash and lie about agent health.
  systemd.services.hermes-agent = {
    description = "Hermes Agent (alias for podman-hermes-agent)";
    bindsTo = [ "podman-hermes-agent.service" ];
    after = [ "podman-hermes-agent.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.coreutils}/bin/true";
      RemainAfterExit = true;
    };
  };
}
