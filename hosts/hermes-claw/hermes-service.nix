{ config
, pkgs
, lib
, ...
}:
let
  hermesImage = "docker.io/nousresearch/hermes-agent:v0.12.0";
  dataDir = "/var/lib/hermes/data";
  # User's personal Telegram chat ID — same value used in nullclaw and openclaw
  # watchers. Not a secret (it's just a numeric ID).
  telegramAllowedUsers = "364749075";

  hermesAgentEnvBody = ''
    set -euo pipefail
    BOT_TOKEN=$(${pkgs.coreutils}/bin/tr -d "\n" < "${config.age.secrets.zero-kuzea-telegram-bot-token.path}")
    OR_KEY=$(${pkgs.coreutils}/bin/tr -d "\n" < "${config.age.secrets.openrouter-api-key.path}")
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
  # Expose env-injection script body for module-eval tests (Task 6).
  # Mirrors the openclawBrowserConfigBody pattern in sancta-claw.
  system.build.hermesAgentEnvBody = hermesAgentEnvBody;

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
    cmd = [ "gateway" "run" ];
    # API only on loopback. No public port. Dashboard (9119) intentionally not exposed.
    ports = [ "127.0.0.1:8642:8642" ];
    volumes = [ "${dataDir}:/opt/data" ];
    environmentFiles = [ "/run/hermes-agent/env" ];
    extraOptions = [
      "--security-opt=no-new-privileges"
      "--cap-drop=ALL"
      "--read-only"
      "--tmpfs=/tmp:size=64m"
      "--shm-size=256m"
      "--memory=2g"
      "--cpus=2.0"
    ];
  };

  # Override auto-generated podman-hermes-agent.service: add secret-injection
  # ExecStartPre + systemd hardening directives.
  systemd.services.podman-hermes-agent = {
    serviceConfig = {
      # `-` prefix: tolerate missing file at unit-load time; ExecStartPre creates it.
      EnvironmentFile = lib.mkForce "-/run/hermes-agent/env";
      RuntimeDirectory = "hermes-agent";
      RuntimeDirectoryMode = "0700";
      ExecStartPre = [
        (pkgs.writeShellScript "hermes-agent-setup-env" hermesAgentEnvBody)
      ];
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" "AF_NETLINK" ];
      ReadWritePaths = [ dataDir ];
      Restart = lib.mkForce "on-failure";
      RestartSec = lib.mkForce "10s";
    };
  };

  # Alias unit so `systemctl is-active hermes-agent` works without the podman- prefix.
  systemd.services.hermes-agent = {
    description = "Hermes Agent (alias for podman-hermes-agent)";
    requires = [ "podman-hermes-agent.service" ];
    after = [ "podman-hermes-agent.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.coreutils}/bin/true";
      RemainAfterExit = true;
    };
  };
}
