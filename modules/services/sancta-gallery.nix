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
  };

  config = lib.mkIf cfg.enable {
    systemd.services.sancta-gallery = {
      description = "Sancta Gallery — read-only static viewer with publish gate";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      # If the (deliberately non-store) server script is missing, stay
      # inactive rather than crash-loop.
      unitConfig.ConditionPathExists = "${cfg.galleryDir}/server.mjs";

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
      };

      serviceConfig = {
        Type = "simple";
        User = "nixos";
        Group = "users";
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
        IPAddressAllow = [
          "127.0.0.1/32"
          "::1/128"
        ];
        IPAddressDeny = "any";
      };
    };
  };
}
