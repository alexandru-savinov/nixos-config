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
# absence, weekly, as zero-knowledge ciphertext.
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
#   1. Assertions are DERIVED from `git ls-files`, never typed here. A
#      hand-maintained list of "files that must exist" is the 2026-07-21 bug
#      wearing a new hat: it goes stale the moment a skill is added, and the
#      thing that would remind you is the same passive signal that already
#      failed once. Commit a skill and it is asserted automatically.
#
#      Consequence for the volatility axis: the MECHANISM lives here in Nix
#      (deploy-speed); WHAT COUNTS AS DOCTRINE lives in git inside the soul
#      volume (thought-speed). Neither leaks into the other, and no skill name
#      ever appears in this PUBLIC repo.
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
# WHAT IT DOES NOT PROVE: correctness. A committed file edited to garbage will
# not fire. This proves existence and recoverability only. Named, not hidden.

{ config, lib, pkgs, ... }:

let
  inherit (lib) mkIf mkOption mkEnableOption types escapeShellArg;
  cfg = config.services.sancta-doctrine-guard;
  soulRoot = toString config.services.sancta-soul-volume.mountPoint;

  guardScript = pkgs.writeShellScript "sancta-doctrine-guard" ''
    set -uo pipefail

    CLAUDE=${escapeShellArg soulRoot}
    SKILLS="$CLAUDE/skills"
    LENSES="$CLAUDE/lenses"

    GIT=${pkgs.git}/bin/git
    JQ=${pkgs.jq}/bin/jq
    DIFF=${pkgs.diffutils}/bin/diff
    MOUNTPOINT=${pkgs.util-linux}/bin/mountpoint

    # git must not take the index lock: the unit runs with ReadOnlyPaths on the
    # soul volume, so an index refresh would fail the run for the wrong reason.
    export GIT_OPTIONAL_LOCKS=0

    fails=0
    miss() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }
    note() { printf 'ok:   %s\n' "$*"; }

    # 0. The volume itself. The unit is ConditionPathIsMountPoint-gated, but the
    #    script must also be safe to run by hand where nothing gates it.
    if ! "$MOUNTPOINT" -q "$CLAUDE"; then
      echo "SKIP: $CLAUDE is not a mountpoint — soul volume not mounted" >&2
      exit 0
    fi

    # 1. Tracked: derived from git, never typed.
    for repo in "$SKILLS" "$LENSES"; do
      if [ ! -d "$repo/.git" ]; then
        miss "not a git repo: $repo"
        continue
      fi
      n=0
      while IFS= read -r f; do
        n=$((n + 1))
        [ -s "$repo/$f" ] || miss "missing or empty: $repo/$f"
      done < <("$GIT" -C "$repo" --no-optional-locks ls-files)
      [ "$n" -gt 0 ] || miss "no tracked files at all in $repo"
      note "$(basename "$repo"): $n tracked entries asserted"
    done

    # 2. Drift — FATAL. Only real directories count; the home-manager symlinks
    #    are wiring, not doctrine, and are correctly out of scope.
    committed=$("$GIT" -C "$SKILLS" --no-optional-locks ls-files -- '*/SKILL.md' 2>/dev/null | sort)
    ondisk=$(cd "$SKILLS" 2>/dev/null && for d in */; do
      b="''${d%/}"
      [ -L "$b" ] && continue
      [ -f "$b/SKILL.md" ] && echo "$b/SKILL.md"
    done | sort)

    if [ "$committed" != "$ondisk" ]; then
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        case "$line" in
          \>*) miss "skill on disk but NEVER COMMITTED: ''${line#> }" ;;
          \<*) miss "skill committed but missing from disk: ''${line#< }" ;;
        esac
      done < <("$DIFF" <(echo "$committed") <(echo "$ondisk") | ${pkgs.gnugrep}/bin/grep -E '^[<>]')
    else
      note "drift: committed set == on-disk set"
    fi

    # 3. Present: lives outside both repos. Small, static — this list does NOT
    #    grow when a skill is added; that half is derived above.
    for p in "$CLAUDE/settings.json" "$CLAUDE/CLAUDE.md"; do
      [ -s "$p" ] || miss "missing or empty: $p"
    done
    # The three PUBLIC voting assessors, reached THROUGH the council symlink and
    # never via a hardcoded target, so the contract survives claude-shared being
    # relaid out internally.
    for a in compliance opportunity risk; do
      p="$SKILLS/council/assessors/$a.md"
      [ -s "$p" ] || miss "missing or empty public assessor: council/assessors/$a.md"
    done

    # 4. The settings.json hook block.
    #    `jq -e '.hooks.UserPromptSubmit'` PASSES on {"UserPromptSubmit":[]} —
    #    jq -e fails only on null/false. An empty array is the most likely shape
    #    of the 2026-07-25 10:32 regression, where a settings writer preserved
    #    the key and dropped the contents. `length > 0` is the fix; verified in
    #    both directions before this shipped.
    if [ -s "$CLAUDE/settings.json" ]; then
      "$JQ" -e '(.hooks.UserPromptSubmit // []) | length > 0' "$CLAUDE/settings.json" >/dev/null 2>&1 \
        || miss "settings.json lost hooks.UserPromptSubmit (empty or absent)"
    fi

    if [ "$fails" -gt 0 ]; then
      printf '\nsancta-doctrine-guard: %d assertion(s) FAILED\n' "$fails" >&2
      exit 1
    fi
    printf '\nsancta-doctrine-guard: all assertions hold\n'
    exit 0
  '';
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
    ];

    systemd.services.sancta-doctrine-guard = {
      description = "Sancta doctrine guard (assert the authored substrate is present and recoverable)";
      # Reuse the EXISTING alert path rather than inventing a second one.
      onFailure = [ "sancta-soul-mirror-alert@%N.service" ];
      after = [ "sancta-soul-mount.service" ];
      requires = [ "sancta-soul-mount.service" ];
      unitConfig.ConditionPathIsMountPoint = soulRoot;
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        ExecStart = guardScript;
        # git wants a HOME; without it `git -C` warns and can behave oddly.
        Environment = [ "HOME=${builtins.dirOf soulRoot}" ];
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
