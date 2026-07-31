# Sancta Gallery (Galeria) — declarative systemd unit for the Painter's
# read-only static viewer, so the publish gate can't silently die on reboot.
#
# Authorized: Alexandru 2026-07-11 (decisions 7+8). Risk finding
# council-20260711T174857Z-569898: the gallery must ALWAYS run with
# GALLERY_PUBLISH_GATE=1 so only .passed (non-leak-tested) artifacts are
# served — an ad-hoc nohup process loses that env var on reboot; this unit
# makes the gate structural.
#
# The server itself (server.mjs) is NOT in this repo: the gallery lives in
# Sancta's index under the home directory (~/.claude/index/gallery). That is
# deliberate — the pieces and their .passed sidecars are produced there by
# the painter/publish pipeline, so the content is mutable by design and
# cannot be a store path. Consequences for hardening:
#   - ProtectHome=true would hide the gallery entirely, so instead we use
#     ProtectHome="tmpfs" + BindReadOnlyPaths on ONLY the gallery dir: the
#     unit sees an empty /home except a read-only bind of the gallery.
#     Even a fully compromised server process cannot read SSH keys,
#     credentials, or anything else under /home.
#   - ConditionPathExists guards the mutable script: if server.mjs is
#     absent the unit stays inactive instead of crash-looping.
#   - The unit runs as the index owner (`user`/`group`): `nixos` on rpi5,
#     `sancta` on sancta-choir after the 2026-07-22 migration.
#   - The port is ALWAYS enforced at the systemd level (SocketBindAllow
#     tcp:8739 only), so even a modified server.mjs cannot silently listen
#     on another port.
#
# TWO BIND SHAPES (2026-07-26). `bind` selects between them and the
# IPAddressAllow branch follows it:
#
#   loopback (default, the 2026-07-11 authorization) — 127.0.0.1:8739 with
#     IPAddressAllow restricted to loopback, so even a compromised server
#     cannot reach the network. `tailscale serve` proxies it onto the tailnet
#     with TLS over loopback. Declaring the serve rule stays out of scope.
#
#   own origin (sancta-choir) — the server binds the tailnet address itself
#     and IPAddressAllow widens to the Tailscale CGNAT/ULA ranges only. Chosen
#     because on 2026-07-26 a page mounted as a PATH under serve's
#     `/ -> 127.0.0.1:8080` catch-all failed silently and the URL answered 200
#     with a DIFFERENT application: longest-prefix routing makes `/` the parent
#     of every path and an SPA history-fallback answers 200 to anything, so
#     composed they form a total function over the URL space in which no
#     mistake is representable. One owner per origin; a dead gallery then fails
#     as ECONNREFUSED, which cannot be mistaken for content.
#
#     This is a DELIBERATE deviation from the repo's documented norm (CLAUDE.md:
#     "services bind 127.0.0.1, accessed via Tailscale Serve HTTPS"). Traffic
#     stays inside WireGuard either way; what changes is that a wrong URL now
#     fails loudly instead of rendering someone else's page.
#
#   `bind` is delivered to the server as GALLERY_BIND, which server.mjs reads
#   (`const BIND = process.env.GALLERY_BIND || '127.0.0.1'`). That script is
#   mutable and outside this repo, so the binding is a CONTRACT with it, not
#   something this module can prove — see the closing check in the PR.
#
# THE OWN-ORIGIN SHAPE HAS A BOOT RACE (found 2026-07-30). A tailnet address is
# not a property of the host — it is assigned by tailscaled after it comes up.
# `After=network.target` says nothing about that, so at boot the server calls
# bind(100.94.191.54:8739) before the address exists and gets EADDRNOTAVAIL;
# Restart=always then burns startLimitBurst in ~25s and the unit ends up
# permanently failed. Every other tailnet-dependent unit in this repo already
# orders after `tailscaled.service` (home-assistant, n8n, gatus, open-webui,
# sancta-membrane-serve); this module, which binds the address DIRECTLY, was the
# only one that did not.
#
# The cure is ordering plus a probe, not ordering alone: tailscaled can be
# "active" before the address lands, and `FreeBind=` would make the bind succeed
# against an address that never arrives — a server that starts and answers nobody,
# which is the precise failure this module exists to make loud. So the probe
# performs the EXACT operation that fails (bind tcp:8739 on `bind`), retries, and
# then exits NON-ZERO so the unit fails and OnFailure fires.
#
# Note the probe must use port 8739: SocketBindDeny=any applies to ExecStartPre
# too, so probing an ephemeral port would be refused with EACCES rather than
# EADDRNOTAVAIL — the wait would return "ready" immediately and guard nothing.
{ config
, lib
, pkgs
, ...
}:
let
  cfg = config.services.sancta-gallery;

  isLoopback = cfg.bind == "127.0.0.1" || cfg.bind == "::1";

  # Seconds the probe waits for the tailnet address to be assigned before it
  # gives up and fails the unit. tailscaled's own consumers in this repo use a
  # 60s budget for the same wait.
  bindWaitSec = 60;

  # Restart cadence. These three are bound together by the rate-limit window
  # computed below — change one and the derived window follows, and the eval
  # test asserts the relation still holds.
  restartSec = 5;
  startLimitBurst = 5;

  # Probe: attempt the real bind. Exit 1 means ONLY "not here yet"; anything
  # else exits 0 so the real error surfaces from ExecStart. Kept as its own
  # file — not an inline heredoc — so tests/sancta-gallery-bind-probe.nix can
  # execute the same bytes the unit runs (the sancta-doctrine-guard.sh shape).
  bindProbe = ./sancta-gallery-bind-probe.js;

  waitForBind = pkgs.writeShellScript "sancta-gallery-wait-bind" ''
    set -eu
    deadline=$((SECONDS + ${toString bindWaitSec}))
    while :; do
      rc=0
      ${pkgs.nodejs}/bin/node ${bindProbe} || rc=$?
      [ "$rc" -eq 0 ] && break
      if [ "$rc" -ne 1 ]; then
        # Only exit 1 means "not here yet". Anything else is the probe itself
        # failing, and retrying a broken probe for a minute would report a
        # missing tailnet address that was never missing.
        echo "ERROR: sancta-gallery: bind probe failed internally (exit $rc) — this is NOT an absent tailnet address." >&2
        exit 1
      fi
      if [ "$SECONDS" -ge "$deadline" ]; then
        echo "ERROR: sancta-gallery: $GALLERY_BIND:8739 is still not bindable after ${toString bindWaitSec}s (EADDRNOTAVAIL) — the tailnet address never arrived. Check tailscaled." >&2
        exit 1
      fi
      sleep 1
    done
  '';
in
{
  options.services.sancta-gallery = {
    enable = lib.mkEnableOption "Sancta Gallery static viewer with publish gate";

    galleryDir = lib.mkOption {
      type = lib.types.path;
      default = "/home/nixos/.claude/index/gallery";
      description = "Directory holding server.mjs, the pieces and their .passed sidecars.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "nixos";
      description = "Account owning galleryDir. On sancta-choir the index owner is `sancta`, not `nixos`.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "users";
      description = "Primary group of `user`.";
    };

    bind = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        Address the server binds. Default loopback, proxied onto the tailnet by
        `tailscale serve` (the 2026-07-11 shape).

        A tailnet address may be given instead, and on sancta-choir that is the
        chosen shape — because on 2026-07-26 a page mounted as a PATH under
        `tailscale serve`'s catch-all silently failed and the URL returned 200
        with a DIFFERENT application's page. Longest-prefix routing makes `/` the
        parent of every path, and an SPA history-fallback answers 200 to
        anything; composed, no URL can produce an error, so no check can observe
        a mistake. Binding its own origin makes a dead gallery fail as
        ECONNREFUSED, which cannot be mistaken for content.

        A wildcard (0.0.0.0 / ::) is rejected by assertion: tailnet-only is a
        property of the binding, not of a firewall rule someone must remember.
      '';
    };

    requiresMount = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        If set, the unit requires that path to be a live mountpoint and refuses
        to start otherwise. On sancta-choir the gallery lives on the LUKS soul
        volume; serving 404s off the bare underlay would look merely empty
        instead of broken.
      '';
    };

    onFailureUnit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "sancta-soul-mirror-alert@%N.service";
      description = ''
        Optional unit to trigger on failure. Without it a crashed gallery is
        silent until someone notices the page is gone — the failure mode the
        hand-started processes had, kept by accident.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        # Not just "no wildcard": the bind must be an address IPAddressAllow
        # actually permits. Anything else fails CLOSED — the unit starts, binds,
        # and silently answers nobody, which is a quieter version of the exact
        # failure this module exists to make loud.
        assertion =
          cfg.bind == "127.0.0.1"
          || cfg.bind == "::1"
          || lib.hasPrefix "100." cfg.bind
          || lib.hasPrefix "fd7a:115c:a1e0:" cfg.bind;
        message = "services.sancta-gallery.bind must be loopback (127.0.0.1 / ::1) or a Tailscale address (100.64.0.0/10 or fd7a:115c:a1e0::/48) — those are the only ranges IPAddressAllow permits, so any other value would start, bind, and silently serve nobody. A wildcard is rejected by the same rule.";
      }
      {
        # The alert template is declared inside sancta-soul-mirror's own mkIf.
        # Point OnFailure at it on a host without the mirror and systemd resolves
        # it to a non-existent unit: it records a failed transient job and the
        # alert never runs — a crashed gallery then fails SILENTLY, which is the
        # exact failure mode this whole module exists to close.
        #
        # sancta-doctrine-guard.nix carries this same assertion, added one day
        # earlier for the same reason, and it was omitted here. Caught in review.
        assertion =
          !(lib.hasInfix "sancta-soul-mirror-alert" (toString (cfg.onFailureUnit or "")))
          || (config.services.sancta-soul-mirror.enable or false);
        message = "services.sancta-gallery.onFailureUnit points at sancta-soul-mirror-alert@, which is declared only when services.sancta-soul-mirror.enable = true. Enable the mirror, or use an alert unit that exists on this host.";
      }
    ];

    systemd.services.sancta-gallery = {
      description = "Sancta Gallery — read-only static viewer with publish gate";
      after = [ "network.target" ]
        ++ lib.optional (cfg.requiresMount != null) "sancta-soul-mount.service"
        # Own-origin shape only: the bind address is handed out by tailscaled,
        # so without this the boot order is a coin flip (see header).
        ++ lib.optional (!isLoopback) "tailscaled.service";
      wants = lib.optional (!isLoopback) "tailscaled.service";
      requires = lib.optional (cfg.requiresMount != null) "sancta-soul-mount.service";
      wantedBy = [ "multi-user.target" ];
      onFailure = lib.optional (cfg.onFailureUnit != null) cfg.onFailureUnit;

      # If the (deliberately non-store) server script is missing, stay
      # inactive rather than crash-loop.
      unitConfig = {
        ConditionPathExists = "${cfg.galleryDir}/server.mjs";
      } // lib.optionalAttrs (cfg.requiresMount != null) {
        # Unmounted volume → refuse to start rather than serve an empty
        # directory. A wrong answer is worse than no answer.
        ConditionPathIsMountPoint = toString cfg.requiresMount;
      };

      # Rate-limit restarts: a persistently crashing server ends up in a
      # loud `systemctl --failed` state instead of oscillating forever.
      #
      # The window must be WIDER than the time `startLimitBurst` attempts
      # actually take, or the limiter never trips. systemd resets the window
      # whenever the gap since its start exceeds the interval
      # (`ratelimit_below()`), so if one attempt costs more than the interval,
      # every attempt lands in a fresh window, the count never reaches the
      # burst, and the unit retries FOREVER without ever entering `failed` —
      # which means OnFailure never fires and the alert never comes. That is
      # this module's own silent-failure mode wearing a rate limiter.
      #
      # The loopback shape starts instantly, so 60s is fine. The own-origin
      # shape spends up to `bindWaitSec` in the probe plus RestartSec between
      # attempts, so the window is DERIVED from those numbers rather than
      # typed — a hand-picked constant here is the same bug with a new hat.
      # Caught in review on #554 by two independent reviewers.
      inherit startLimitBurst;
      startLimitIntervalSec =
        if isLoopback then 60 else (bindWaitSec + restartSec) * startLimitBurst;

      environment = {
        # The publish gate: server refuses any artifact without a
        # <file>.passed sidecar (written by publish.mjs after the non-leak
        # PII test passes). Trust boundary: env-var DELIVERY is structural
        # (survives reboot), but the gate CHECK lives in server.mjs —
        # mutable, outside the Nix store. Integrity of server.mjs is the
        # responsibility of the painter/publish pipeline (Sancta's index),
        # not of this unit.
        GALLERY_PUBLISH_GATE = "1";
        GALLERY_BIND = cfg.bind;
      };

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.galleryDir;
        ExecStart = "${pkgs.nodejs}/bin/node ${cfg.galleryDir}/server.mjs";
        Restart = "always";
        RestartSec = restartSec;

        # Hardening. The server only ever READS the gallery dir; it gets a
        # read-only view of exactly that and nothing else under /home (see
        # header). ProtectSystem=strict makes the rest of the filesystem
        # read-only with no write paths granted at all.
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = "tmpfs";
        BindReadOnlyPaths = [ cfg.galleryDir ];
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = false; # node JIT needs W^X off
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];

        # Enforce the loopback-only contract at the systemd level, not just
        # in server.mjs: the process may bind ONLY tcp:8739 and exchange
        # packets ONLY with loopback. tailscale serve proxies from the same
        # host over loopback, so the tailnet path keeps working.
        SocketBindAllow = "tcp:8739";
        SocketBindDeny = "any";
      }
      // lib.optionalAttrs isLoopback {
        # Loopback shape (the 2026-07-11 authorization): packets may go nowhere
        # but loopback, so even a modified server.mjs cannot reach the network.
        # `tailscale serve` proxies from the same host over loopback.
        IPAddressAllow = [
          "127.0.0.1/32"
          "::1/128"
        ];
        IPAddressDeny = "any";
      }
      // lib.optionalAttrs (!isLoopback) {
        # Wait for the address tailscaled hands out, and fail LOUD if it never
        # arrives. Ordering after tailscaled.service is necessary but not
        # sufficient: the unit can be active before the address is assigned.
        ExecStartPre = toString waitForBind;

        # The probe may spend up to bindWaitSec seconds; the 90s systemd default
        # would SIGTERM it mid-wait once ExecStart is added on top.
        TimeoutStartSec = bindWaitSec + 60;

        # Own-origin shape (sancta-choir): the process binds the tailnet address
        # itself, so loopback-only IP filtering would block the very traffic it
        # exists to serve. The port restriction above still holds — it may bind
        # tcp:8739 and nothing else — and the CGNAT range is the tailnet's own,
        # so this permits Tailscale peers and nothing on the public internet.
        IPAddressAllow = [
          "100.64.0.0/10"
          "fd7a:115c:a1e0::/48"
          "127.0.0.1/32"
          "::1/128"
        ];
        IPAddressDeny = "any";
      };
    };
  };
}
