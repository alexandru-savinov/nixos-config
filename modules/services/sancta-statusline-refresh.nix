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
# THE SCRIPT LIVES IN THIS REPO, NOT ON THE SOUL VOLUME.
# The gallery module points ExecStart at a program on the mutable volume, so it
# owns WHETHER the thing runs but not WHAT runs, and a rebuild cannot reproduce
# it. Not repeating that here: the script is in-tree, materialised into the
# store, and a rebuild reproduces it byte for byte.
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
  stateFile = "${soulRoot}/index/statusline-state.json";
  refreshScript = ./sancta-statusline-refresh.sh;
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
        "sancta-worker"
        "sancta-gallery"
        "sancta-doctrine-guard.timer"
        "sancta-membrane-gateway"
      ];
      description = ''
        Units the bar reports on. Anything not `active` shows in its "down"
        field. A unit ABSENT from this list is not tracked at all and will never
        appear — so removing one here is a decision to stop watching it, not a
        cosmetic change.
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
      path = with pkgs; [
        gh
        jq
        systemd
        gnugrep
        coreutils
      ];
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        ExecStart = "${pkgs.bash}/bin/bash ${refreshScript}";
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
        # ONE writable path. This unit updates a single file and has no business
        # touching anything else on the volume; everything it reads — the gh
        # credentials, the sidequest log — it reads without needing write access.
        ReadWritePaths = [ stateFile ];
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
