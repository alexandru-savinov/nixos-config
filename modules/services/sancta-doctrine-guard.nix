# sancta-doctrine-guard — assert the authored substrate is present and recoverable.
#
# WHY THIS EXISTS
# ---------------
# 2026-07-21: the RPi5 → sancta-choir migration lost six council assessor files.
# 2026-07-25: found four days later, by accident, during an unrelated /doctor run.
#
# Nothing on this host was CAPABLE of noticing. Every existing soul unit
# (soul-open, soul-mount, worker, soul-mirror) gates on the volume being
# MOUNTED; not one asserts its CONTENT. The backup faithfully archived the
# absence, weekly, as zero-knowledge ciphertext — a mirror of a hole is a hole.
#
# The control case proves it was never the mechanism that failed: compliance.md,
# opportunity.md and risk.md sat in the same directory, went through the same
# migration, and survived — because they were committed. The three that lived
# were in a repo. The six that died were not.
#
# Design: ~/.claude/index/docs/plans/2026-07-25-substrate-permanence-design.md §4
#
# THREE RULES THIS MODULE OBEYS, AND WHY
#
#   1. Assertions are DERIVED from `git ls-files`, never typed. A hand-maintained
#      list of "files that must exist" is the 2026-07-21 bug wearing a new hat:
#      it goes stale the moment a skill is added, and the thing that would remind
#      you is the same passive signal that already failed once. Commit a skill
#      and it is asserted automatically.
#
#      Consequence for the volatility axis: the MECHANISM lives here in Nix
#      (deploy-speed); WHAT COUNTS AS DOCTRINE lives in git inside the soul
#      volume (thought-speed). Neither leaks into the other.
#
#      Precisely: no PRIVATE doctrine name appears in this PUBLIC repo. The one
#      hardcoded list in the script — compliance/opportunity/risk — is the
#      deliberate exception, and naming those three costs nothing because they
#      are already public in the claude-shared flake. They are also the only
#      entries that CANNOT be derived: they live outside both private repos, so
#      no `git ls-files` reaches them. The derived half is the half that grows.
#
#   2. Drift — a skill on disk that was never committed — is FATAL, not a
#      warning. This host is headless. Nobody reads a journal warning; that is
#      precisely the class of signal that let four days pass. A hard failure is
#      a ten-second fix.
#
#   3. Worktree cleanliness is NEVER checked. A dirty tree mid-edit is normal;
#      a missing file never is. A guard that cries wolf during ordinary work
#      gets muted within a fortnight, and a muted guard is worse than none —
#      it returns you to silence while feeling covered.
#
# The logic lives in sancta-doctrine-guard.sh rather than inline here so that
# tests/sancta-doctrine-guard.nix can exercise its branches against fixture
# trees. Tools come from PATH: systemd `path` here, nativeBuildInputs there.
#
# WHAT IT DOES NOT PROVE: correctness. A committed file edited to garbage will
# not fire. This proves existence and recoverability only. Named, not hidden.

{ config, lib, pkgs, ... }:

let
  inherit (lib) mkIf mkOption mkEnableOption types;
  cfg = config.services.sancta-doctrine-guard;
  soulRoot = toString config.services.sancta-soul-volume.mountPoint;
  guardScript = ./sancta-doctrine-guard.sh;
in
{
  options.services.sancta-doctrine-guard = {
    enable = mkEnableOption "Sancta doctrine guard (assert the authored substrate is present and recoverable)";

    user = mkOption {
      type = types.str;
      default = "sancta";
      description = "Account that owns the soul volume and the doctrine repos.";
    };

    onCalendar = mkOption {
      type = types.str;
      default = "*-*-* 09:00:00";
      description = ''
        systemd OnCalendar. Daily by default: the 2026-07-21 loss went four days
        undetected, and a daily check bounds that window to ~24h. Cheap enough
        (two `git ls-files` and a handful of stat calls) that a tighter cadence
        would buy nothing.
      '';
    };

    randomizedDelaySec = mkOption {
      type = types.str;
      default = "10m";
      description = "systemd RandomizedDelaySec, so the guard never lands exactly on another unit's minute.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.sancta-soul-volume.enable or false;
        message = "services.sancta-doctrine-guard requires services.sancta-soul-volume — it asserts content ON that mount.";
      }
      {
        # onFailure below targets sancta-soul-mirror-alert@, which is declared
        # inside sancta-soul-mirror's own `mkIf cfg.enable`. Enable this guard
        # on a host with the volume but not the mirror and systemd resolves
        # OnFailure= to a non-existent unit: it records a failed transient job
        # and the alert script never runs, so a real failure never reaches the
        # feed. That is silently-lost-signal — the exact thing this module was
        # written to end — so it fails at BUILD time instead.
        assertion = config.services.sancta-soul-mirror.enable or false;
        message = "services.sancta-doctrine-guard requires services.sancta-soul-mirror — it raises alerts through that module's sancta-soul-mirror-alert@ template, which does not exist when the mirror is disabled.";
      }
    ];

    systemd.services.sancta-doctrine-guard = {
      description = "Sancta doctrine guard (assert the authored substrate is present and recoverable)";
      # Reuse the EXISTING alert path rather than inventing a second one. That
      # handler derives all of its user-facing text from the unit name it is
      # passed (%N), so an alert raised here names this unit — including the
      # journalctl hint. Hardcoded "soul-mirror" wording there would send an
      # operator to an idle journal, which is the signal-gets-missed failure
      # this whole unit exists to close.
      onFailure = [ "sancta-soul-mirror-alert@%N.service" ];
      after = [ "sancta-soul-mount.service" ];
      requires = [ "sancta-soul-mount.service" ];
      unitConfig.ConditionPathIsMountPoint = soulRoot;
      path = with pkgs; [
        git
        jq
        diffutils
        util-linux
        gnugrep
        coreutils
      ];
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        ExecStart = "${pkgs.bash}/bin/bash ${guardScript}";
        Environment = [
          "SANCTA_DOCTRINE_ROOT=${soulRoot}"
          # Belt and braces beside ConditionPathIsMountPoint above; the unit
          # gate is the real one, this only makes the script safe standalone.
          "SANCTA_DOCTRINE_REQUIRE_MOUNT=1"
          "HOME=${builtins.dirOf soulRoot}"
        ];
        TimeoutStartSec = "5m";
        Nice = 15;
        IOSchedulingClass = "idle";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = false;
        # Read-only over the whole soul volume: this unit asserts, it never
        # repairs. Anything that could write is out of scope by construction.
        ReadOnlyPaths = [ soulRoot ];
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        LockPersonality = true;
        # No network. It reads local files and nothing else.
        RestrictAddressFamilies = [ "AF_UNIX" ];
        SystemCallFilter = [ "@system-service" ];
      };
    };

    systemd.timers.sancta-doctrine-guard = {
      description = "Daily Sancta doctrine guard";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.onCalendar;
        Persistent = true;
        RandomizedDelaySec = cfg.randomizedDelaySec;
      };
    };
  };
}
