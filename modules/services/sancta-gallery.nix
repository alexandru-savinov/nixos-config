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
#   - The unit runs as User=nixos (the index owner), same as the nohup
#     process it replaces.
#   - Binding stays 127.0.0.1:8739 (server default) and is ENFORCED at the
#     systemd level (SocketBindAllow tcp:8739 only + IPAddressAllow
#     loopback only), so even a modified server.mjs cannot silently listen
#     on 0.0.0.0 or another port. `tailscale serve` already proxies it onto
#     the tailnet with TLS (the proxy connects over loopback, which stays
#     allowed). Declaring the serve rule is intentionally out of scope here
#     (per the 2026-07-11 authorization).
{ config
, lib
, pkgs
, ...
}:
let
  cfg = config.services.sancta-gallery;
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
        assertion = cfg.bind != "0.0.0.0" && cfg.bind != "::";
        message = "services.sancta-gallery.bind must not be a wildcard address — the gallery is loopback- or tailnet-only by construction, never by firewall.";
      }
    ];

    systemd.services.sancta-gallery = {
      description = "Sancta Gallery — read-only static viewer with publish gate";
      after = [ "network.target" ]
        ++ lib.optional (cfg.requiresMount != null) "sancta-soul-mount.service";
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
      startLimitIntervalSec = 60;
      startLimitBurst = 5;

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
        RestartSec = 5;

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
      // lib.optionalAttrs (cfg.bind == "127.0.0.1" || cfg.bind == "::1") {
        # Loopback shape (the 2026-07-11 authorization): packets may go nowhere
        # but loopback, so even a modified server.mjs cannot reach the network.
        # `tailscale serve` proxies from the same host over loopback.
        IPAddressAllow = [
          "127.0.0.1/32"
          "::1/128"
        ];
        IPAddressDeny = "any";
      }
      // lib.optionalAttrs (cfg.bind != "127.0.0.1" && cfg.bind != "::1") {
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
