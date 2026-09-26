# sancta-absent-guard — give the house's absence guard a clock.
#
# THE DEFECT, MEASURED 2026-09-26
# -------------------------------
# /var/lib/sancta/.claude/index/bin/absent-guard is the one thing that asks
# "WHEN DID THIS LAST PRODUCE ANYTHING?" of every producer in the house. It was
# written on 2026-08-02 after five signals stopped together and nothing noticed,
# because an absent signal reads exactly like a calm one unless something is
# holding a clock against it.
#
# Nothing was holding a clock against IT. `systemctl list-timers --all` and
# `list-units` on sancta-choir show no unit for absent-guard at all — it was
# never scheduled, only ever run by a live session happening to call it. The
# same coincidence-instead-of-a-clock that sancta-wq-tick was built to end.
# The guard says the quiet part itself, in its own producer row:
#
#   "THIS GUARD ITSELF has not completed a run — the count on the bar is not
#    being recomputed, so a green count means nothing."
#
# and on the night this module was written it was reporting exactly that about
# itself: `absent-guard` stale at 26h against its own max of 6h. A watchman
# with no clock is not a sleeping watchman, it is a tool lying in a drawer.
#
# THIS MODULE IS THE CLOCK, NOT THE BRAIN — same split as sancta-wq-tick and
# sancta-statusline-refresh, for the same reason. The producer table
# (index/producers.json), the age arithmetic, the MISSING-outranks-STALE
# ordering and every `means:` sentence live in exactly ONE place: the INDEX
# repo on the soul volume. This module supplies the cadence, the environment,
# the sandbox, and the translation of the guard's exit code into a red unit.
# A rebuild of this repo cannot change what the guard CONSIDERS absent.
#
# THE ALARM IS THE FAILING UNIT (borrowed from sancta-archive-deadman, and only
# that part). The guard exits 0 ok / 1 stale / 2 missing-or-internal-failure —
# read off its own header and its own tail, not assumed. Anything non-zero
# fails this unit: red in `systemctl --failed`, the guard's full report in the
# journal, and — because the unit is listed in services.sancta-statusline-
# refresh.units — one line on the status bar. No feed line and no onFailure
# chain: every alert path in this house runs through a tool on the soul volume,
# and a guard whose alarm depends on the substrate it is watching is not a
# guard.
#
# WHY THIS ONE IS MOUNT-GATED AND THE DEAD-MAN IS NOT
# ---------------------------------------------------
# Do not "make these consistent". They are deliberately opposite, and each
# direction is load-bearing:
#
#   sancta-archive-deadman has NO ConditionPathIsMountPoint because its whole
#   job is to be the one watcher that still speaks when the LUKS volume fails
#   to unlock. Its evidence (the archive heartbeat) lives OUTSIDE the volume
#   precisely so it can. That absence of a gate is pinned by
#   tests/module-eval.nix — adding a gate there rebuilds the defect it closes.
#
#   THIS unit is the other kind. Every input it has is ON the soul volume: the
#   guard script, the producer table, and every producer path the table names.
#   Without the mount it cannot read one honest byte — it would report seven
#   MISSING producers and mean only "the volume is not here", which is a
#   different alarm that a different unit (the dead-man) already owns and owns
#   better. So it is gated like the rest of the soul family: skipped, not red,
#   when the volume is absent. A red unit that means something other than what
#   it says trains its reader to ignore it.
#
# THE CADENCE RELATION, CHECKED AT RUNTIME
# ----------------------------------------
# The guard watches itself: a completed run writes index/absent-last.json, and
# the table has a row for that file with max_age 6h. So a timer SLOWER than the
# guard's own max_age makes the guard permanently report itself stale — the
# clock would manufacture the very alarm it was installed to silence. That is a
# relation between two settings that live in two different repos, which is the
# exact shape this house has been bitten by before (2026-07-31: "the class
# hides in RELATIONS between settings, so make the relation an assertion").
# It cannot be asserted at eval time — producers.json is on a LUKS volume no
# Nix build sandbox can read — so the wrapper asserts it at RUNTIME, on every
# beat, against the live table, and fails loudly if it no longer holds.
#
# WHAT THIS DOES NOT PROVE
# ------------------------
# Scheduling the guard does not revive anything it watches. On the day this
# landed the guard was reporting `northstar` MISSING, `dreams` stale 48d and
# `ledger` stale 34d — all true, none of them fixed by a timer. This unit will
# be RED from its first beat, and that redness is the feature: it makes those
# three silences impossible to miss instead of impossible to see. It also does
# not prove the unit ACTIVATES on the real host — eval and dry-build prove
# evaluability, never activation (scar, 2026-08-07). The first real beat is the
# first proof.

{ config, lib, pkgs, ... }:

let
  inherit (lib) mkIf mkOption mkEnableOption types;
  cfg = config.services.sancta-absent-guard;

  soulRoot = toString config.services.sancta-soul-volume.mountPoint;
  indexRoot = "${soulRoot}/index";

  cu = "${pkgs.coreutils}/bin";

  # The env contract (SANCTA_ABSENT_*) exists so the SAME store script can be
  # driven against fixtures — a stub guard and a hand-written producer table,
  # both directions, red and green — before it ever judges the real one. The
  # unit below pins the real values; tests/module-eval.nix pins the pinning and
  # tests/sancta-absent-guard.nix exercises every arm.
  checkScript = pkgs.writeShellScript "sancta-absent-guard-check" ''
    set -uo pipefail

    # The guard arrives as argv[1], not as an environment variable, ON PURPOSE:
    # an off-store absolute path in the Exec* line is what puts this unit in
    # scope for tests/execstart-path-contract.nix, which then forces a
    # committed $PATH contract for the guard's own commands. Hiding the path in
    # Environment= would make the unit look pure-store and silently drop it out
    # of that check — the #564 class (a script whose shebang interpreter was
    # not on PATH) with better paperwork.
    GUARD="''${1:?usage: sancta-absent-guard-check <absolute path to bin/absent-guard>}"
    TABLE="''${SANCTA_ABSENT_PRODUCERS:?SANCTA_ABSENT_PRODUCERS unset}"
    INTERVAL="''${SANCTA_ABSENT_INTERVAL_SEC:?SANCTA_ABSENT_INTERVAL_SEC unset}"

    reasons=""
    flag() { reasons="''${reasons:+$reasons; }$1"; }

    # age word (12h, 2d, 90s…) → seconds, in pure bash. Deliberately a copy of
    # the guard's own grammar rather than a call into it: this must still be
    # able to say "your table is unreadable" when the guard cannot run.
    secs() {
      local v="$1" n="''${1%[smhd]}" u="''${1: -1}"
      case "$v" in *[0-9]) printf '%s' "$v"; return 0;; esac
      case "$n" in ""|*[!0-9]*) return 1;; esac
      case "$u" in
        s) printf '%s' "$n" ;;
        m) printf '%s' "$(( n * 60 ))" ;;
        h) printf '%s' "$(( n * 3600 ))" ;;
        d) printf '%s' "$(( n * 86400 ))" ;;
        *) return 1 ;;
      esac
    }

    # (a) THE GUARD ITSELF. ExecStartPre already tests -x, but this branch is
    # what the fixture tests drive, and "could not ask" must never read as
    # healthy: a missing guard is the loudest possible absence, since it is the
    # thing that would have reported all the others.
    if [ ! -x "$GUARD" ]; then
      flag "absent-guard is missing or not executable at $GUARD — nothing is holding a clock against any producer"
      echo "ABSENT-GUARD: $reasons" >&2
      exit 1
    fi

    # (b) THE CADENCE RELATION (see the module header). A timer slower than the
    # guard's own max_age makes the guard report ITSELF stale forever, and the
    # clock becomes the alarm's cause. Read from the LIVE table on every beat,
    # because the table is in the other repo and can change without this one.
    if ! selfMax="$(${pkgs.jq}/bin/jq -er '
          [ .producers[]? | select(.name == "absent-guard") | .max_age ] | .[0] // error("no absent-guard row")
        ' "$TABLE" 2>/dev/null)"; then
      flag "producer table $TABLE has no readable absent-guard row — the guard's SELF-watch is gone, so a completed run no longer proves anything ran"
    elif ! selfSec="$(secs "$selfMax")"; then
      flag "absent-guard's own max_age '$selfMax' in $TABLE is not an age this checker can read — refusing to guess"
    elif [ "$INTERVAL" -gt "$selfSec" ]; then
      flag "TIMER TOO SLOW: this unit beats every ''${INTERVAL}s but absent-guard's own max_age is $selfMax (''${selfSec}s) — the guard would report itself stale between beats and the clock would be manufacturing the alarm"
    fi

    # (c) RUN IT. Exit codes per bin/absent-guard's own header and tail:
    #     0 = ok, 1 = at least one STALE producer, 2 = MISSING producer OR an
    #     internal failure of the guard (its die() path, which deliberately
    #     exits 2 so a broken guard reads as alarming rather than as silence).
    report="$("$GUARD" 2>&1)"
    rc=$?

    case "$rc" in
      0) ;;
      1) flag "absent-guard exit 1 — at least one producer is STALE (details above)" ;;
      2) flag "absent-guard exit 2 — a producer is MISSING, or the guard itself failed (details above)" ;;
      *) flag "absent-guard exited $rc, which is not one of its documented statuses (0/1/2) — treating an unknown answer as a failure, never as health" ;;
    esac

    # The report goes to the journal in BOTH directions. An ok verdict that
    # does not carry the timestamps it saw is an opinion (the guard's own rule
    # 3, paid for by an audit that reported "0 violations" over a channel dead
    # 17 days).
    if [ -n "$reasons" ]; then
      printf '%s\n' "$report" >&2
      echo "ABSENT-GUARD: $reasons" >&2
      exit 1
    fi

    printf '%s\n' "$report"
    echo "absent-guard OK: every producer inside its max_age; beat ''${INTERVAL}s <= self max_age $selfMax"
  '';
in
{
  options.services.sancta-absent-guard = {
    enable = mkEnableOption "scheduled run of the house's absence guard (fails red when any producer is MISSING or STALE)";

    guardScript = mkOption {
      type = types.str;
      default = "${indexRoot}/bin/absent-guard";
      defaultText = "\${services.sancta-soul-volume.mountPoint}/index/bin/absent-guard";
      description = ''
        The guard on the soul volume. Unlike sancta-archive-deadman's
        soulMount, this one IS derived from the soul-volume option: this unit
        has no reason to exist in a world where the volume is gone, and the
        mount gate below says so.
      '';
    };

    producersTable = mkOption {
      type = types.str;
      default = "${indexRoot}/producers.json";
      defaultText = "\${services.sancta-soul-volume.mountPoint}/index/producers.json";
      description = ''
        The cadence table the guard reads. Named here only so the wrapper can
        check the ONE relation that spans the two repos — that this timer is
        not slower than the guard's own max_age row. The wrapper never parses
        any other row; deciding what is absent stays entirely in the guard.
      '';
    };

    intervalSeconds = mkOption {
      type = types.ints.positive;
      default = 7200;
      description = ''
        Seconds between beats, and the SINGLE source for the cadence — the
        timer is built from this number and the runtime relation check is made
        against this same number, so the two cannot drift apart. 2h against the
        guard's 6h self-window leaves room for two missed beats plus the
        randomized delay before the guard would report itself stale. Raising it
        above the `absent-guard` row's max_age in producers.json makes the unit
        fail on its next beat, by design.
      '';
    };

    randomizedDelaySec = mkOption {
      type = types.str;
      default = "5min";
      description = "systemd RandomizedDelaySec, so this does not start on the same second as the other sancta timers. Kept far below the headroom between intervalSeconds and the guard's self max_age.";
    };

    user = mkOption {
      type = types.str;
      default = "sancta";
      description = "Account the guard runs as. Must own index/ — the guard writes its completion marker there (see ReadWritePaths below).";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        # The relation, made structural. A guard or a table moved off the soul
        # volume would be silently skipped forever by the mount gate below:
        # ConditionPathIsMountPoint is a SKIP, not a failure, so a unit whose
        # real inputs live elsewhere would go quiet with nothing red anywhere —
        # the exact silence this module exists to end.
        assertion =
          lib.hasPrefix "${soulRoot}/" cfg.guardScript
          && lib.hasPrefix "${soulRoot}/" cfg.producersTable;
        message = "services.sancta-absent-guard.guardScript (${cfg.guardScript}) and .producersTable (${cfg.producersTable}) must live under the soul mount (${soulRoot}) — this unit is gated on that mount, so inputs outside it would never be read and the unit would be skipped in silence.";
      }
    ];

    systemd.services.sancta-absent-guard = {
      description = "Run the Sancta absence guard (its FAILURE is the alarm: a producer has gone quiet)";

      # THE MOUNT GATE — the deliberate opposite of sancta-archive-deadman.
      # See the module header for why these two must NOT be made consistent.
      # Pinned in both directions by tests/module-eval.nix.
      after = [ "sancta-soul-mount.service" ];
      requires = [ "sancta-soul-mount.service" ];
      unitConfig.ConditionPathIsMountPoint = soulRoot;

      # THE PATH CONTRACT, transitive by one level and no further: the wrapper
      # calls every tool of its own by full store path, so this list exists
      # entirely for the CHILD — bin/absent-guard, read in full 2026-09-26:
      #   bash      — its `#!/usr/bin/env bash` shebang, resolved via $PATH
      #               (this is the #564 shape: the interpreter itself)
      #   dirname   — `$(dirname -- "''${BASH_SOURCE[0]}")` to find its root
      #   jq        — parses producers.json, writes absent-last.json
      #   date      — `+%s`, `-u -d @<ts>`, the verdict's own timestamp
      #   find      — newest file anywhere under a producer DIRECTORY (the
      #               dreams/ case: a fresh directory mtime over nine days of
      #               nothing is a lie about the contents)
      #   sort,head — pick the newest of those
      #   stat      — `-c %Y` for a producer that is a file or a glob
      #   mv, rm    — the tmp+rename that lands the completion marker
      # `printf`, `echo`, `read`, `shopt`, `command`, `[`, `case` are bash
      # builtins and are deliberately not provisioned. Mirrored as a committed
      # contract in tests/execstart-path-contracts.nix.
      path = with pkgs; [
        bash
        coreutils
        findutils
        jq
      ];

      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;

        # Same guard as wq-tick, for the same blind spot: the guard is not a
        # store path, so no static check can prove it resolves. Fail here with
        # a plain message rather than inside the wrapper's own argv handling.
        ExecStartPre = "${cu}/test -x ${cfg.guardScript}";
        ExecStart = "${checkScript} ${cfg.guardScript}";

        Environment = [
          "SANCTA_ABSENT_PRODUCERS=${cfg.producersTable}"
          "SANCTA_ABSENT_INTERVAL_SEC=${toString cfg.intervalSeconds}"
          # The guard derives its root from its own BASH_SOURCE, so it finds
          # the table and the marker without HOME — but it is a bash script in
          # a systemd unit and HOME-less shells have bitten this house before
          # (wq-tick's queue.mjs). State it rather than be right by luck.
          "HOME=${builtins.dirOf soulRoot}"
        ];

        TimeoutStartSec = "2min";
        Nice = 15;
        IOSchedulingClass = "idle";

        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = false;
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

        # THE WRITABLE SET, and its honest cost.
        #
        # The guard writes exactly one thing: index/absent-last.json, its
        # completion marker, via mktemp-sibling + rename. That marker IS the
        # self-watch — the table's own `absent-guard` row points at it — so it
        # cannot be relocated from this repo, and a tmp+rename needs the
        # CONTAINING directory writable, not the file (the 2026-08-20 lesson,
        # and the register-history EROFS scar that turned a wq-tick handler
        # into a green "measured but NOT recorded").
        #
        # That containing directory is index/ itself, so this grant is WIDER
        # than sancta-wq-tick's carefully enumerated list, and saying otherwise
        # would be the lie. Narrowing it means moving the marker under its own
        # subdirectory — an INDEX-repo change (the marker path, the producers
        # row and this list would all move together), named here and not done
        # here, because this repo must not reach into that one.
        #
        # `-` prefix: with ProtectSystem=strict systemd bind-mounts the entry
        # and a missing path fails the unit START, before the wrapper can emit
        # its own honest error. The mount gate already covers the normal
        # absence; this covers a mounted volume with no index/ yet.
        ReadWritePaths = [ "-${indexRoot}/" ];
      };
    };

    systemd.timers.sancta-absent-guard = {
      description = "Clock for the Sancta absence guard (every intervalSeconds; must stay under the guard's own max_age)";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # OnBootSec + OnUnitActiveSec rather than OnCalendar, so the cadence is
        # ONE number that both the timer and the runtime relation check read.
        # A calendar expression plus a separate seconds value is two settings
        # that can drift, which is the bug class this module is built around.
        # The boot beat covers the downtime case OnCalendar's Persistent= would:
        # a host that was off is exactly when producers went quiet unnoticed.
        OnBootSec = "10min";
        OnUnitActiveSec = "${toString cfg.intervalSeconds}s";
        RandomizedDelaySec = cfg.randomizedDelaySec;
        AccuracySec = "1min";
      };
    };
  };
}
