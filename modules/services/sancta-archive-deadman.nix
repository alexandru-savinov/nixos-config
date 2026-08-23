# sancta-archive-deadman — the one watcher that does NOT need the soul volume.
#
# THE GAP THIS CLOSES (2026-08-23 transcript-archive review, confidence 93):
# every guard of the transcript archive runs through sancta-wq-tick, and
# wq-tick itself is gated on the soul mount (ConditionPathIsMountPoint) — as
# is the producer, as is the mirror. That gate is correct for THEM: a unit
# that reads the soul must not run against the bare underlay. But it means
# the whole family shares one failure mode: if the LUKS volume fails to
# unlock after a reboot, the producer AND every guard of the producer go
# silent TOGETHER, and nothing anywhere says so. The alarm "source unmounted"
# cannot cover the case where the alarm itself does not run.
#
# So this unit is deliberately the odd one out in the family:
#   * NO ConditionPathIsMountPoint, no Requires/After on sancta-soul-mount —
#     it runs whether or not the soul volume is there. That absence is
#     load-bearing and is pinned by tests/module-eval.nix, because the
#     natural refactor ("add the mount gate like every other soul unit")
#     would silently rebuild the exact defect this module exists to close.
#   * ENTIRELY store-backed: pkgs.writeShellScript, absolute store paths for
#     every tool. Nothing it executes lives on the soul volume, so
#     tests/unit-script-refs.nix really covers it (unlike the soul-side
#     ExecStarts, which that check is structurally blind to).
#   * It WRITES NOTHING — not to the soul volume (which may be the thing
#     that is absent), not anywhere else. ProtectSystem=strict with an empty
#     ReadWritePaths makes that structural rather than promised. The unit
#     FAILING is the alarm: red in `systemctl --failed`, one plain line in
#     the journal. No feed line, no stamp file, no onFailure chain — every
#     one of those would hand this watcher a dependency, and its only value
#     is having none.
#
# WHAT IT CHECKS, daily:
#   (a) the soul volume is actually mounted at its mountpoint;
#   (b) the archive heartbeat (last-run.json, written by the producer OUTSIDE
#       the soul volume) exists and its EMBEDDED ts is younger than maxAge.
# Content ts via jq, never mtime — a `touch` on the heartbeat must not turn
# this green (the statusline's stale counter reading 7 for two nights while
# mtime looked fine is the fresh scar). Any inability to answer — missing
# file, unparseable JSON, a ts `date` cannot read, a ts from the future —
# fails loudly rather than guessing: "could not ask" is never "healthy"
# (the F6 lesson from the same review).
#
# WHAT IT CANNOT DO: distinguish WHY the beat stopped (producer dead, state
# dir wiped, volume never unlocked). It only refuses to let any of those be
# silent. rpi5's soul-mirror staleness switch remains the off-host second
# eye; this is the on-host one that survives the mount.

{ config, lib, pkgs, ... }:

let
  inherit (lib) mkIf mkOption mkEnableOption types;
  cfg = config.services.sancta-archive-deadman;

  cu = "${pkgs.coreutils}/bin";

  # The env contract (SANCTA_DEADMAN_*) exists so the SAME store script can be
  # exercised against fixtures — run with a fake mount and a hand-written
  # heartbeat, both directions, before it ever judges the real ones. The unit
  # below pins the real values; tests/module-eval.nix pins the pinning.
  deadmanScript = pkgs.writeShellScript "sancta-archive-deadman" ''
    set -uo pipefail

    MOUNT="''${SANCTA_DEADMAN_SOUL_MOUNT:?SANCTA_DEADMAN_SOUL_MOUNT unset}"
    HEARTBEAT="''${SANCTA_DEADMAN_HEARTBEAT:?SANCTA_DEADMAN_HEARTBEAT unset}"
    MAX_AGE="''${SANCTA_DEADMAN_MAX_AGE_SEC:?SANCTA_DEADMAN_MAX_AGE_SEC unset}"
    # Tolerated clock skew before a future ts is treated as forged/broken.
    SKEW=300

    reasons=""
    flag() { reasons="''${reasons:+$reasons; }$1"; }

    # (a) The mount itself. This is the check no soul-gated unit can make:
    # they are all skipped in exactly the world where it fails.
    if ! ${pkgs.util-linux}/bin/mountpoint -q "$MOUNT"; then
      flag "soul volume NOT mounted at $MOUNT — producer and every soul-gated guard are silent right now"
    fi

    # (b) The heartbeat's CONTENT ts. Every branch that cannot positively
    # establish freshness flags — never the benefit of the doubt.
    if [ ! -f "$HEARTBEAT" ]; then
      flag "archive heartbeat missing: $HEARTBEAT — no beat recorded, or the state dir is gone"
    elif ! ts=$(${pkgs.jq}/bin/jq -er '.ts' "$HEARTBEAT"); then
      flag "archive heartbeat unreadable: no parseable .ts in $HEARTBEAT — refusing to guess"
    elif ! ts_epoch=$(${cu}/date -d "$ts" +%s); then
      flag "archive heartbeat ts not a timestamp: '$ts' — refusing to guess"
    else
      now=$(${cu}/date +%s)
      age=$((now - ts_epoch))
      if [ "$age" -gt "$MAX_AGE" ]; then
        flag "archive heartbeat STALE: content ts $ts is ''${age}s old (> ''${MAX_AGE}s) — the daily beat has stopped"
      elif [ "$age" -lt "-$SKEW" ]; then
        flag "archive heartbeat ts is in the FUTURE: $ts — clock skew or a hand-written beat"
      fi
    fi

    if [ -n "$reasons" ]; then
      echo "DEADMAN: $reasons" >&2
      exit 1
    fi
    echo "deadman OK: $MOUNT mounted; heartbeat content ts $ts (''${age}s <= ''${MAX_AGE}s)"
  '';
in
{
  options.services.sancta-archive-deadman = {
    enable = mkEnableOption "mount-independent dead-man check for the transcript archive (fails red when the soul volume or the archive heartbeat is silent)";

    soulMount = mkOption {
      type = types.str;
      default = "/var/lib/sancta/.claude";
      description = ''
        Where the soul volume must be mounted. Deliberately a LITERAL, not a
        read of services.sancta-soul-volume.mountPoint: this unit must keep
        evaluating and running in a world where the soul-volume module is
        broken, disabled or gone — that is its entire purpose. The relation
        to the real option is pinned in tests/module-eval.nix instead, where
        drift fails a check rather than adding a dependency.
      '';
    };

    heartbeatFile = mkOption {
      type = types.str;
      default = "/var/lib/sancta/transcript-archive/last-run.json";
      description = ''
        The producer's heartbeat (services.sancta-transcript-archive.stateDir
        + /last-run.json). Lives OUTSIDE the soul volume by the archive's own
        design, which is exactly what makes it readable from here when the
        volume is not: an assertion below rejects any path under soulMount,
        because a watcher whose evidence lives on the watched thing cannot
        tell "volume absent" from "beat never happened" — and this module has
        already seen what one shared gate does to a family of guards.
      '';
    };

    maxAgeSeconds = mkOption {
      type = types.ints.positive;
      default = 259200;
      description = ''
        Heartbeat content ts older than this fails the unit. 3 days: the
        producer beats daily and its own guard (archive-check, soul-gated)
        alarms at ~2 days, so this fires one day AFTER the primary guard
        would have — if this one is the first to say anything, the primary
        guard was silent too, which is precisely the story worth a red unit.
      '';
    };

    user = mkOption {
      type = types.str;
      default = "sancta";
      description = "Account the check runs as. Must be able to read heartbeatFile (mode 0600 under the archive's 0700 stateDir), so in practice the archive user.";
    };

    onCalendar = mkOption {
      type = types.str;
      default = "*-*-* 07:10:00";
      description = "systemd OnCalendar. Daily, after the producer's 04:20(+20min) slot, so the morning's beat has had hours to land before it is judged.";
    };

    randomizedDelaySec = mkOption {
      type = types.str;
      default = "15min";
      description = "systemd RandomizedDelaySec, so this does not start on the same second as the other daily timers.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        # The relation, made structural (the 2026-07-31 lesson: the class
        # hides in RELATIONS between settings). A heartbeat re-pointed onto
        # the soul volume would quietly rebuild the shared-gate defect this
        # module exists to close.
        assertion = !(lib.hasPrefix "${cfg.soulMount}/" "${cfg.heartbeatFile}");
        message = "services.sancta-archive-deadman.heartbeatFile (${cfg.heartbeatFile}) must NOT live under soulMount (${cfg.soulMount}) — the dead-man's evidence may not depend on the mount it watches.";
      }
    ];

    systemd.services.sancta-archive-deadman = {
      description = "Mount-independent dead-man check for the Sancta transcript archive (its FAILURE is the alarm)";

      # NO soul-mount coupling of any kind — no Condition, no Requires, no
      # After, no onFailure into soul-fed alert paths. Pinned by
      # tests/module-eval.nix; see the module header for why the obvious
      # "make it consistent with the family" edit here is the regression.
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        ExecStart = deadmanScript;

        Environment = [
          "SANCTA_DEADMAN_SOUL_MOUNT=${cfg.soulMount}"
          "SANCTA_DEADMAN_HEARTBEAT=${cfg.heartbeatFile}"
          "SANCTA_DEADMAN_MAX_AGE_SEC=${toString cfg.maxAgeSeconds}"
        ];

        # Writes NOTHING, structurally: strict + an empty writable set. The
        # journal line arrives via stdout/stderr, which systemd owns.
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        LockPersonality = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        SystemCallFilter = [ "@system-service" ];
      };
    };

    systemd.timers.sancta-archive-deadman = {
      description = "Daily mount-independent dead-man check for the transcript archive";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.onCalendar;
        # A beat missed because the host was down is exactly the kind of
        # morning after which the mount is most likely to be absent.
        Persistent = true;
        RandomizedDelaySec = cfg.randomizedDelaySec;
      };
    };
  };
}
