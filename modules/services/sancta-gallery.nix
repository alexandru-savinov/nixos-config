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
# the painter/publish pipeline. Consequences for hardening:
#   - ProtectHome must NOT be set (it would hide the entire gallery from the
#     unit's mount namespace and the service could never start).
#   - The unit runs as User=nixos (the index owner), same as the nohup
#     process it replaces. Keep the rest of the sandbox sane but functional.
#   - Binding stays 127.0.0.1 (server default); `tailscale serve` already
#     proxies it onto the tailnet with TLS.
{ pkgs, ... }:
let
  galleryDir = "/home/nixos/.claude/index/gallery";
in
{
  systemd.services.sancta-gallery = {
    description = "Sancta Gallery — read-only static viewer with publish gate";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    environment = {
      # The publish gate: server refuses any artifact without a <file>.passed
      # sidecar (written by publish.mjs after the non-leak PII test passes).
      GALLERY_PUBLISH_GATE = "1";
    };

    serviceConfig = {
      Type = "simple";
      User = "nixos";
      Group = "users";
      WorkingDirectory = galleryDir;
      ExecStart = "${pkgs.nodejs}/bin/node ${galleryDir}/server.mjs";
      Restart = "always";
      RestartSec = 5;

      # Hardening — sane but functional. No ProtectHome (see header: the
      # gallery lives under /home). The server is read-only over the gallery
      # dir; ProtectSystem=strict makes the rest of the filesystem read-only
      # and we grant no write paths at all (the server never writes).
      NoNewPrivileges = true;
      ProtectSystem = "strict";
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
    };
  };
}
