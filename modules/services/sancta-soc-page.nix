# sancta-soc-page — rebuild the private SOC page once a day.
#
# THE DEFECT
# ----------
# gallery/soc.html (the one-pane SOC view: choir host layer read live, open
# code-scanning alerts, the plan) was only ever rebuilt when a live session
# happened to run `node gallery/soc.mjs` and then `node gallery/publish.mjs`.
# Between those runs the page kept showing its last reading with nothing on it
# saying how old that reading was. A security page that silently stops being
# current reads exactly like a calm one.
#
# THIS MODULE IS THE CLOCK, NOT THE BRAIN — same split as sancta-wq-tick and
# sancta-absent-guard. What the page reads and how it renders live in the INDEX
# repo (gallery/soc.mjs); what may be served lives in the INDEX repo's PII gate
# (gallery/publish.mjs). This module supplies the cadence, the environment, the
# sandbox, and one store-backed wrapper (sancta-soc-page.sh) whose only job is
# the promotion rule: a page and its .passed token arrive together or not at
# all, and a refused page never replaces a served one. The wrapper's header
# carries the full argument; tests/sancta-soc-page.nix drives it in both
# directions.
#
# THE ALARM IS THE FAILING UNIT. Generator failure (soc.mjs fails closed on a
# broken repo read), gate FAIL (1) and gate CLOSED (2) all exit non-zero: red in
# `systemctl --failed`, the gate's report in the journal, one line on the status
# bar (the unit is in services.sancta-statusline-refresh.units on choir), and a
# feed alert through the soul mirror's alert template — the same onFailure path
# sancta-doctrine-guard uses.
#
# WHAT IT DOES NOT PROVE: that the page is RIGHT. It proves it was rebuilt from
# live reads and passed the gate. A reader soc.mjs cannot reach is rendered as
# "unread" by soc.mjs itself, never guessed — that honesty lives there.

{ config, lib, pkgs, ... }:

let
  inherit (lib) mkIf mkOption mkEnableOption types;
  cfg = config.services.sancta-soc-page;
  soulRoot = toString config.services.sancta-soul-volume.mountPoint;
  indexRoot = "${soulRoot}/index";
  galleryDir = "${indexRoot}/gallery";
  wrapper = ./sancta-soc-page.sh;
in
{
  options.services.sancta-soc-page = {
    enable = mkEnableOption "daily rebuild + gate of the private SOC gallery page";

    user = mkOption {
      type = types.str;
      default = "sancta";
      description = "Account that owns the INDEX repo and the `gh` auth the generator reads GitHub with.";
    };

    onCalendar = mkOption {
      type = types.str;
      default = "*-*-* 06:30:00";
      description = ''
        systemd OnCalendar. Daily: the code-scanning layer moves on the scale of
        days, and a page rebuilt every morning is never more than ~24h behind.
      '';
    };

    randomizedDelaySec = mkOption {
      type = types.str;
      default = "15m";
      description = "systemd RandomizedDelaySec, so the rebuild never lands on another unit's minute.";
    };

    timeoutStartSec = mkOption {
      type = types.str;
      default = "10m";
      description = ''
        One run is a handful of `gh api` calls (each with its own 20s timeout in
        soc.mjs, plus an un-timed paginated alerts read), `systemd-analyze
        security` (30s cap) and two gate passes. One hand run on choir with
        this unit's PATH and Environment took 7s (2026-11-10); ten leaves room for a slow GitHub without letting a
        hung read hold the lock forever.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.sancta-soul-volume.enable or false;
        message = "services.sancta-soc-page requires services.sancta-soul-volume — the generator, the gate and the page all live on that mount.";
      }
      {
        # onFailure targets sancta-soul-mirror-alert@, declared only when the
        # mirror is enabled. Without it OnFailure= resolves to nothing and a red
        # run never reaches the feed (sancta-doctrine-guard carries the long form
        # of this argument).
        assertion = config.services.sancta-soul-mirror.enable or false;
        message = "services.sancta-soc-page requires services.sancta-soul-mirror — it raises alerts through that module's sancta-soul-mirror-alert@ template.";
      }
      {
        assertion = cfg.user == (config.services.sancta-soul-mirror.user or cfg.user);
        message = "services.sancta-soc-page.user must equal services.sancta-soul-mirror.user — the shared alert template runs as the mirror's user.";
      }
      {
        # The page is promoted into the directory the gallery SERVES. If the two
        # ever pointed at different trees, this unit would go green every day
        # while the gallery kept serving a page nobody rebuilds.
        assertion =
          !(config.services.sancta-gallery.enable or false)
          || toString config.services.sancta-gallery.galleryDir == galleryDir;
        message = "services.sancta-soc-page promotes into ${galleryDir}, but services.sancta-gallery.galleryDir is ${toString (config.services.sancta-gallery.galleryDir or "")} — the rebuilt page would never be served.";
      }
    ];

    systemd.services.sancta-soc-page = {
      description = "Rebuild and gate the private SOC gallery page";
      onFailure = [ "sancta-soul-mirror-alert@%N.service" ];
      after = [
        "sancta-soul-mount.service"
        "network-online.target"
      ];
      requires = [ "sancta-soul-mount.service" ];
      wants = [ "network-online.target" ];
      unitConfig.ConditionPathIsMountPoint = soulRoot;

      # THE PATH CONTRACT, read off gallery/soc.mjs and the wrapper (2026-11-10):
      #   nodejs     — soc.mjs, publish.mjs, negru/poarta.mjs (child of soc.mjs)
      #   gh         — code-scanning alerts, repo settings, runs, PR states
      #   systemd    — `systemctl is-active`, `systemd-analyze security`
      #   iproute2   — `ss -ltnH` (listening-socket scopes)
      #   tailscale  — `tailscale status --json` (estate)
      #   util-linux — `last` (logins), `flock` (wrapper)
      #   jq, coreutils — the wrapper's post-promotion hash check, mktemp/mv
      # LAST: /run/current-system/sw. soc.mjs reports whether lynis/aide/nmap
      # are installed by looking them up on $PATH. With only the pinned list
      # above that probe would say "absent" for a tool the system does carry —
      # a false reading on a security page. The system profile is appended, not
      # prepended, so every tool named above still resolves to its pinned path.
      path = [
        pkgs.nodejs
        pkgs.gh
        config.systemd.package
        pkgs.iproute2
        config.services.tailscale.package
        pkgs.util-linux
        pkgs.jq
        pkgs.coreutils
        "/run/current-system/sw"
      ];

      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        # Store-backed wrapper: tests/unit-script-refs.nix can see it, and
        # tests/sancta-soc-page.nix drives this exact ExecStart.
        ExecStart = "${pkgs.bash}/bin/bash ${wrapper}";
        Environment = [
          "SANCTA_SOC_INDEX=${indexRoot}"
          "SANCTA_SOC_OUT_DIR=${galleryDir}"
          # gh reads its auth from $HOME/.config/gh; systemd gives no HOME.
          "HOME=${builtins.dirOf soulRoot}"
        ];
        TimeoutStartSec = cfg.timeoutStartSec;
        Nice = 15;
        IOSchedulingClass = "idle";

        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = false;
        # THE WRITABLE SET, read off soc.mjs + the wrapper:
        #   gallery/ — the stage dir, the two pages, their .passed tokens. A
        #     DIRECTORY grant because promotion is rename(2) into it. This is
        #     the gallery's whole served tree; the wrapper writes only the four
        #     names it promotes plus its own .soc-stage.* directory.
        #   soc-history.jsonl — soc.mjs's history(): writeFileSync in place
        #     (O_TRUNC on the bound inode, no tmp + rename), so a FILE grant
        #     holds. If soc.mjs ever moves to tmp + rename this grant stops
        #     working and must be re-argued as a directory. `-` so a missing
        #     file skips the bind instead of failing the start; soc.mjs then
        #     swallows the EROFS and the page still renders (sparklines stop).
        ReadWritePaths = [
          galleryDir
          "-${indexRoot}/soc-history.jsonl"
        ];
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        LockPersonality = true;
        # AF_INET/6: gh to GitHub (un-narrowed, for the reason sancta-wq-tick
        # gives — a GitHub IP list goes stale and fails runs at 6am).
        # AF_UNIX: systemd D-Bus, tailscaled's socket. AF_NETLINK: `ss`. Drop
        # NETLINK and `ss` fails, soc.mjs renders the listener panel "unread",
        # and the unit stays green — so it is pinned in tests/module-eval.nix.
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK"
        ];
        SystemCallFilter = [ "@system-service" ];
      };
    };

    systemd.timers.sancta-soc-page = {
      description = "Daily rebuild of the private SOC gallery page";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.onCalendar;
        Persistent = true;
        RandomizedDelaySec = cfg.randomizedDelaySec;
      };
    };
  };
}
