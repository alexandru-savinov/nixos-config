# sancta-statusline-refresh — keep the status bar's cached state true.
#
# WHY THIS EXISTS
# ---------------
# The Claude Code status bar is the only surface on screen that never scrolls
# away, so it shows Alexandru's open asks — PRs waiting on his hand, sidequests,
# units that should be running and are not. It runs on EVERY prompt, which means
# it must be instant: one file read, no network, no systemctl, no gh.
#
# That design has a second half, and on 2026-08-01 only the first half existed.
# The bar rendered a 15-hour-old snapshot while looking current: six asks when
# there were fourteen, and a unit down that it never mentioned. Nothing was
# broken in any way a check could see — the renderer worked perfectly on stale
# input. This unit is the missing half.
#
# THIS MODULE IS THE CLOCK, NOT THE BRAIN (amended 2026-08-19).
# The refresh LOGIC (oneshot ok-at-rest handling, live `stale` = queue
# dead-letter + overdue, writing the field into state) lives in exactly ONE
# place: /var/lib/sancta/.claude/index/bin/statusline-refresh, on the soul
# volume, in the INDEX repo — not here. An earlier version of this module
# carried its own 145-line embedded copy of that logic. Two copies of the same
# refresh logic in two repos is a two-writers problem: they drift the moment
# either one is edited alone, and the drift is invisible until the bar and
# whatever else reads the INDEX repo's copy disagree about what "stale" means.
# This module now supplies only the clock (the timer + cadence), the contract
# (the three env vars below), and the environment (mount-gate + PATH) — never
# the logic. A rebuild of this repo cannot regress the refresh behavior,
# because it no longer contains any.
#
# THE WORKS-BY-LUCK TRAP: because ExecStart now points at a path on the soul
# volume instead of a Nix store path, `tests/unit-script-refs.nix` — the check
# built to catch exactly this class of bug (a script reference that does not
# resolve) — CANNOT see it. It only realises and scans `/nix/store/...`
# references; a `/var/lib/sancta/...` path is invisible to it by construction,
# the same way `${pkg}/bin/typo` was invisible to `nix build --dry-run` before
# that check existed. The mount-gate (ConditionPathIsMountPoint, below) plus an
# explicit `ExecStartPre` existence+executable check on the script itself are
# what replace that guard for this one unit: if the volume is mounted but the
# INDEX repo hasn't deployed the script (or it lost its execute bit), the unit
# fails loudly and immediately instead of silently no-op'ing or crashing deep
# inside a partially-run refresh.
#
# NO OnFailure ALERT, DELIBERATELY.
# Every other soul unit raises sancta-soul-mirror-alert@ on failure, and that is
# right for units that run daily or weekly and whose failure is silent. This one
# runs every quarter of an hour and talks to GitHub over the network; a transient
# 5xx would alert. A guard that cries wolf during ordinary work gets muted within
# a fortnight, and a muted guard is worse than none.
#
# It does not need one, because the failure is SELF-REPORTING: the script leaves
# the old file untouched on any error, and the bar prints how old that file is
# once it passes twelve hours. The signal arrives on the surface the operator is
# already looking at, at the moment it starts to matter, and it costs nothing
# when the cause was one bad request.
#
# WHAT IT DOES NOT PROVE: that the numbers are RIGHT. It proves they are recent.
# A wrong-but-fresh count would pass this unit and the bar alike.

{ config, lib, pkgs, ... }:

let
  inherit (lib) mkIf mkOption mkEnableOption types concatStringsSep;
  cfg = config.services.sancta-statusline-refresh;
  soulRoot = toString config.services.sancta-soul-volume.mountPoint;
  # 2026-08-20: moved from index/statusline-state.json into its own
  # directory. Reproduced live: with ProtectSystem=strict and
  # ReadWritePaths naming a single FILE, the refresher's atomic-write
  # pattern (mktemp a sibling temp file, then mv -f into place) fails —
  # rename(2) needs write access on the containing DIRECTORY, not just the
  # file being replaced. Least-privilege (one writable file) and atomicity
  # (rename) cannot both be satisfied by a ReadWritePaths entry that names
  # a single file; one of the two had to give. See stateDir below for the
  # resolution and why it is still least-privilege.
  stateDir = "${soulRoot}/index/statusline";
  stateFile = "${stateDir}/state.json";
  # The single source of the refresh logic. Deliberately NOT a Nix store path —
  # see "THE WORKS-BY-LUCK TRAP" above for why that is a real, named tradeoff
  # rather than an oversight.
  refreshScript = "${soulRoot}/index/bin/statusline-refresh";
in
{
  options.services.sancta-statusline-refresh = {
    enable = mkEnableOption "Refresh the cached state rendered by the Claude Code status bar";

    user = mkOption {
      type = types.str;
      default = "sancta";
      description = ''
        Account that owns the soul volume. It must be the same account whose
        `gh` credentials are used, since the refresher reads open PRs — running
        as anyone else silently produces an empty ask list, which renders as a
        clear queue rather than as a failure.
      '';
    };

    repo = mkOption {
      type = types.str;
      default = "alexandru-savinov/nixos-config";
      description = "owner/name of the repository whose open PRs count as asks waiting on him.";
    };

    units = mkOption {
      type = types.listOf types.str;
      default = [
        "sancta-gallery.service"
        "sancta-doctrine-guard.service"
        "sancta-soul-mirror.timer"
      ];
      description = ''
        Units the bar reports on. A unit ABSENT from this list is not tracked at
        all and will never appear — so removing one here is a decision to stop
        watching it, not a cosmetic change.

        `sancta-doctrine-guard.service` is `Type=oneshot` with no
        `RemainAfterExit`, so it is `inactive` BY DESIGN after a successful run —
        that is not "down". This is intentionally kept in the default rather than
        dropped (review finding, 2026-08-19): the INDEX repo's
        `bin/statusline-refresh` — the one place the reader logic for this file
        lives, see the module header — maps a unit through `systemctl is-failed`
        first, then treats `inactive` + `Result=success` + `Type=oneshot` as
        `"ok-at-rest"` rather than `down`; only `is-failed` or any OTHER
        non-active/non-ok-at-rest state lands in the bar's "down" field. Removing
        this oneshot from the default would have silently stopped watching a unit
        worth watching, to work around a bug that is already fixed on the reader
        side. If this module is ever pointed at a different oneshot unit that
        does NOT set `Result=success` cleanly on its normal exit path, verify the
        reader-side mapping still holds before adding it here — the mapping lives
        outside this repo and this option cannot assert it.
      '';
    };

    onCalendar = mkOption {
      type = types.str;
      default = "*:0/15";
      description = ''
        systemd OnCalendar. Every fifteen minutes: the bar's own staleness marker
        only appears after twelve hours, so the cadence has to be far below that
        for the number to mean "now" rather than "recently". Each run costs one
        `gh pr list` plus two calls per open PR.
      '';
    };

    randomizedDelaySec = mkOption {
      type = types.str;
      default = "90s";
      description = "systemd RandomizedDelaySec, so refreshes do not land on the same second as other timers.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.sancta-soul-volume.enable or false;
        message = "services.sancta-statusline-refresh requires services.sancta-soul-volume — the state file it rewrites lives on that mount.";
      }
      {
        # The bar renders whatever this writes. If the tracked list is empty the
        # bar's "down" field can never populate, and a host with dead units looks
        # identical to a healthy one — the exact silent-pass this module family
        # exists to prevent. Fail at build time rather than ship a bar that
        # cannot report.
        assertion = cfg.units != [ ];
        message = "services.sancta-statusline-refresh.units must not be empty — an empty list makes a host with dead units render identically to a healthy one.";
      }
    ];

    systemd.services.sancta-statusline-refresh = {
      description = "Refresh the Sancta status bar's cached state";
      after = [
        "sancta-soul-mount.service"
        "network-online.target"
      ];
      requires = [ "sancta-soul-mount.service" ];
      wants = [ "network-online.target" ];
      unitConfig.ConditionPathIsMountPoint = soulRoot;
      # The module still owns the ENVIRONMENT the externally-sourced script runs
      # in — that is provisioning, not logic. The INDEX repo's script expects
      # these tools on PATH (gh for the ask list, jq for JSON, systemd for unit
      # status, coreutils for the ExecStartPre existence check below).
      path = with pkgs; [
        # bash FIRST, and not optional: the refresh script's shebang is
        # `#!/usr/bin/env bash`, so the INTERPRETER itself is resolved through
        # this PATH. While the script lived here as a `writeShellScript`, Nix
        # baked an absolute bash into the shebang and PATH never mattered. It
        # does now: the unit exited 127 on its first real run and the missing
        # command was the interpreter, not any tool. Same shape as "THE
        # WORKS-BY-LUCK TRAP" above, one level deeper — the store-ref check
        # cannot see ExecStart, and nothing at all sees what its shebang needs.
        bash
        # nodejs: the script derives `stale` (queue dead-letter + overdue
        # periodic tasks) by reading orchestrator/queue.db via node:sqlite.
        # Without it the value degrades to -1, rendered "⚠ stale ?" — a bar that
        # cannot count its own staleness is the frozen-keeper class this unit
        # exists to prevent.
        nodejs
        gh
        jq
        systemd
        gnugrep
        coreutils
      ];
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        # See "THE WORKS-BY-LUCK TRAP" above: ExecStart is not a store path, so
        # the usual static store-ref check cannot see it. This is the guard that
        # replaces it — fail loudly, before the timer fires the real work, if
        # the soul volume is mounted but the script itself is missing or lost
        # its execute bit (a partial INDEX-repo deploy, a bad chmod, etc.).
        ExecStartPre = "${pkgs.coreutils}/bin/test -x ${refreshScript}";
        ExecStart = refreshScript;
        Environment = [
          "SANCTA_STATUSLINE_STATE=${stateFile}"
          "SANCTA_STATUSLINE_REPO=${cfg.repo}"
          "SANCTA_STATUSLINE_UNITS=${concatStringsSep " " cfg.units}"
          "HOME=${builtins.dirOf soulRoot}"
        ];
        # Bounded well under the timer interval: a run that outlives its own
        # cadence would stack refreshes rather than replace them.
        TimeoutStartSec = "3m";
        Nice = 15;
        IOSchedulingClass = "idle";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = false;
        # THE DIRECTORY, not the file (changed 2026-08-20 — see stateDir/stateFile
        # above for the failure this fixes). ReadWritePaths naming a single FILE
        # is what broke: the refresher's atomic-write pattern is mktemp a sibling
        # temp file in the same directory, then `mv -f` it over the target —
        # rename(2) requires write permission on the containing DIRECTORY, not
        # merely on the file being replaced. Reproduced live: with the old
        # single-file ReadWritePaths and the state directory chmod 555, the
        # refresher's own mktemp failed with "Permission denied" and the unit
        # exited 1, leaving the state untouched every 15 minutes.
        #
        # STILL least-privilege, not a widening: `stateDir` (index/statusline/)
        # holds exactly ONE file — state.json — and nothing else, by construction
        # (it was carved out of index/ specifically so this grant could stay
        # narrow). Compare the alternative rejected below: naming
        # `"${soulRoot}/index"` would put the INDEX repo's `bin/`,
        # `orchestrator/queue.db` and everything else under it inside the
        # writable scope. Naming `stateDir` gives the unit exactly the same
        # practical reach it always had — one file's worth of blast radius —
        # while finally matching what rename(2) actually needs.
        #
        # `-` prefix, not a bare path (review finding, 2026-08-19; still applies
        # to a directory the same way it applied to the file): with
        # ProtectSystem=strict, systemd bind-mounts each ReadWritePaths entry
        # into the unit's private mount namespace, and a bare path that does not
        # exist on the host makes that bind-mount — and so unit start — fail
        # BEFORE the script ever runs. In practice `stateDir` should exist
        # whenever the INDEX repo is checked out at all (state.json is a
        # committed file inside it, so git materializes the directory), but `-`
        # costs nothing and keeps the same fresh-host safety margin the
        # single-file version had: the unit still starts, and the script's own
        # check ("cannot read $STATE") produces the honest error instead of
        # systemd's opaque bind-mount failure.
        ReadWritePaths = [ "-${stateDir}/" ];
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        LockPersonality = true;
        # Network IS required here, unlike the doctrine guard: the ask list comes
        # from GitHub. No IPAddressAllow narrowing — GitHub's ranges are neither
        # fixed nor short, and a deny-list of everything-else that goes stale is
        # a boundary in name only.
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        SystemCallFilter = [ "@system-service" ];
      };
    };

    systemd.timers.sancta-statusline-refresh = {
      description = "Keep the Sancta status bar's cached state fresh";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.onCalendar;
        # Persistent: after a reboot the bar would otherwise render whatever the
        # file held before the machine went down, with no marker until twelve
        # hours had passed. Catch up once, immediately.
        Persistent = true;
        RandomizedDelaySec = cfg.randomizedDelaySec;
      };
    };
  };
}
