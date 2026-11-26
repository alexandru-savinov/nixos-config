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
# The unit verifies length and sha256 before serving, and touches only its own
# service (`serve clear <svc>`, never a whole-config reset). On a mismatch or a missing
# file it clears the service and fails, so the alert unit fires. tailscaled keeps
# Serve config across reboots, so the boot run clears first; a timer re-verifies.
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
  };
  script = mode: "${pkgs.bash}/bin/bash ${./svc-game.sh} ${mode}";
  common = {
    after = [ "tailscaled.service" ];
    wants = [ "tailscaled.service" ];
    environment = env;
    path = [ pkgs.coreutils ];
    onFailure = lib.optional (cfg.onFailureUnit != null) cfg.onFailureUnit;
    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "60s";
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
      description = "How often the timer re-verifies the bytes.";
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
      restartTriggers = [ cfg.sha256 (toString cfg.length) ./svc-game.sh ];
      serviceConfig = common.serviceConfig // {
        RemainAfterExit = true;
        ExecStart = script "boot";
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
