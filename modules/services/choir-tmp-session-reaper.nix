# Session-aware /tmp reaper for choir (see choir-tmp-session-reaper.sh).
#
# Why not tmpfiles age alone: a per-file age on /tmp/claude-* would hollow out
# a live-but-idle build tree file by file. They are removed whole, only when
# dead AND idle (see the .sh header for the liveness rules).
#
{ config, lib, pkgs, ... }:

let
  cfg = config.choirTmpReaper;
  scriptText = ''
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.findutils pkgs.gnugrep pkgs.util-linux pkgs.glibc.bin ]}
    export DRY_RUN=${if cfg.dryRun then "1" else "0"}
    export IDLE_DAYS=${toString cfg.idleDays}
    export ALERT_GIB=${toString cfg.alertGiB}
    export EXCLUDE_SESSIONS=${lib.escapeShellArg (lib.concatStringsSep " " cfg.excludeSessions)}
  '' + builtins.readFile ./choir-tmp-session-reaper.sh;
in
{
  options.choirTmpReaper = {
    dryRun = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Log what would be removed without deleting. Flip to false after reviewing the first runs.";
    };
    idleDays = lib.mkOption { type = lib.types.ints.positive; default = 7; description = "A session tree and its transcript must both be idle this many days."; };
    alertGiB = lib.mkOption { type = lib.types.ints.positive; default = 10; description = "Journal WARN when one session directory exceeds this size."; };
    excludeSessions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Session id prefixes that are never reaped, even when stale.";
    };
    scriptText = lib.mkOption { type = lib.types.str; readOnly = true; internal = true; default = scriptText; };
  };

  config = {
    # Once the reaper really deletes (dryRun = false), exempt Claude session
    # trees from systemd's stock /tmp file aging (tmp.conf: `q /tmp … 10d`),
    # which would otherwise delete individual old files inside live or
    # resumable sessions; whole-tree removal then is this reaper's job alone.
    # While it only logs, stock aging stays in place, so this module changes
    # nothing about what is deleted. The arming change must also decide on the
    # trees the reaper refuses (claude-0, unknown uids, other depths).
    systemd.tmpfiles.rules = lib.mkIf (!cfg.dryRun) [ "x /tmp/claude-*" ];

    systemd.services.choir-tmp-session-reaper = {
      description = "Remove dead, idle Claude session trees from /tmp";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "choir-tmp-session-reaper" scriptText;
        Nice = 19;
        IOSchedulingClass = "idle";
        MemoryMax = "512M";
        # Root only to read /proc and drop to the owner uid; no PrivateTmp, it
        # must see the real /tmp.
      };
    };

    # 01:45 daily: after the Sun 01:00 optimise slot starts, before the 02:30 GC.
    systemd.timers.choir-tmp-session-reaper = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnCalendar = "*-*-* 01:45:00"; RandomizedDelaySec = "10min"; Persistent = true; };
    };
  };
}
