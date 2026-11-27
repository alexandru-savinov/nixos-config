# One pinned static file served as a Tailscale Service (its own origin, tcp:443).
#
# The bytes are private and are NOT in this repo or its closure: CI builds choir's
# full toplevel, so a requireFile would turn the required build red on every PR,
# and a CI-only stub would make the tested closure differ from the deployed one.
# Only the pin (sha256 + length) lives here. The file is placed by hand at
# <dir>/<sha256>.html (dir root:root 0700, file 0400) through the attended deploy
# route. The name is content-addressed, so a re-pin is a new name and a rollback
# is the old pin.
#
# The unit verifies length and sha256 before serving and uses `serve clear <svc>`
# to remove its own mapping. On a mismatch or a missing file it tries to clear
# the mapping and fails. tailscaled persists Serve config across reboots, so boot
# clears first. A timer re-verifies the file and any existing mapping. The boot
# unit clears the mapping on stop or failed start. Boot and verify share a lock,
# and boot waits for tailscaled to be Running before checking the file.
#
# Accepted residuals
# Bytes changed after a check are served until the next check (root-only path).
# A mapping left by an unclean shutdown can be reachable briefly at boot before the boot clear.
# Serve writers on this host share one config ETag, so a concurrent write elsewhere can fail once (game writes retry 3x).
# After a rollback, the deploy handoff checks that
# `tailscale serve status --json | jq '.Services["svc:game"]'` returns null.
# After 5 failed boot runs in an hour the unit stays failed (the alert has fired)
# until someone restarts it.
# The host must be approved for the service by hand in the admin console; the
# tailnet policy has no services auto-approver on purpose.
{ config, lib, pkgs, ... }:
let
  cfg = config.sancta.svcGame;
  env = {
    TS = "${pkgs.tailscale}/bin/tailscale";
    SVC = cfg.service;
    DIR = cfg.dir;
    SHA = cfg.sha256;
    LEN = toString cfg.length;
    LOCK = "/run/svc-game.lock";
  };
  script = mode: "${pkgs.bash}/bin/bash ${./svc-game.sh} ${mode}";
  common = {
    after = [ "tailscaled.service" ];
    wants = [ "tailscaled.service" ];
    environment = env;
    path = [ pkgs.coreutils pkgs.jq pkgs.util-linux ];
    onFailure = lib.optional (cfg.onFailureUnit != null) cfg.onFailureUnit;
    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "300s";
    };
  };
in
{
  options.sancta.svcGame = {
    enable = lib.mkEnableOption "a pinned static file served as a Tailscale Service";
    service = lib.mkOption {
      type = lib.types.strMatching "svc:[a-z0-9-]+";
      default = "svc:game";
      description = "Tailscale Service name.";
    };
    dir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/svc-game";
      description = "Root-owned 0700 directory holding <sha256>.html.";
    };
    sha256 = lib.mkOption {
      type = lib.types.strMatching "[0-9a-f]{64}";
      description = "Pinned sha256 (lower-case hex) of the file.";
    };
    length = lib.mkOption {
      type = lib.types.ints.positive;
      description = "Pinned length of the file in bytes.";
    };
    verifyInterval = lib.mkOption {
      type = lib.types.str;
      default = "15min";
      description = "How often the timer re-verifies the file and its Serve mapping.";
    };
    onFailureUnit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Unit started when verification or serving fails.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [ "d ${cfg.dir} 0700 root root -" ];

    # Boot run: clear first, then verify and serve. RemainAfterExit so a switch
    # does not re-run it needlessly; restartTriggers re-run it when the pin changes.
    systemd.services.svc-game = common // {
      description = "Serve the pinned file as ${cfg.service} (boot run)";
      wantedBy = [ "multi-user.target" ];
      # The membrane writes the same Serve config ETag during boot.
      after = common.after ++ [ "sancta-membrane-serve.service" ];
      restartTriggers = [ cfg.sha256 (toString cfg.length) ./svc-game.sh ];
      unitConfig = {
        StartLimitIntervalSec = 3600;
        StartLimitBurst = 5;
      };
      serviceConfig = common.serviceConfig // {
        RemainAfterExit = true;
        ExecStart = script "boot";
        ExecStop = script "stop";
        ExecStopPost = script "stop-post";
        Restart = "on-failure";
        RestartSec = "60s";
      };
    };

    systemd.services.svc-game-verify = common // {
      description = "Re-verify the pinned file behind ${cfg.service}";
      serviceConfig = common.serviceConfig // { ExecStart = script "verify"; };
    };
    systemd.timers.svc-game-verify = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = cfg.verifyInterval;
      };
    };
  };
}
