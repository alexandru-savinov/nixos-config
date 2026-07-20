# sancta-choir — ENCRYPTED SOUL VOLUME for ~/.claude (LUKS-on-loopback-file).
#
# ══════════════════════════════════════════════════════════════════════════
# STAGING NOTE (Sancta→sancta-choir membrane migration): AUTHORED, not deployed.
# Closing check is that it EVALUATES (`nix eval`), NOT that it builds/runs a
# real machine. Do NOT nixos-rebuild switch / deploy / merge from here. No real
# key material is written by this repo.
# ══════════════════════════════════════════════════════════════════════════
#
# WHY LOOPBACK-FILE LUKS (not disko / not re-imaging):
# sancta-choir's root is a LIVE, plain ext4 /dev/sda1 (see
# hardware-configuration.nix). We must NOT re-partition or re-image it. So the
# encrypted "soul" for Sancta's ~/.claude substrate lives inside a single
# LUKS2-encrypted *file* (a loopback container) that sits ON the existing ext4
# root — the least-destructive dedicated-encrypted-volume mechanism that
# evaluates cleanly and needs no disk surgery. gocryptfs was the alternative
# (no fixed-size preallocation, per-file overhead) but LUKS gives a real block
# device + one clean fscrypt boundary and reuses the LUKS idioms already in
# this repo (sancta-claw / sancta-core).
#
# ── KEY DELIVERY (HIS-HAND — no real key in this repo) ─────────────────────
# The volume is unlocked at boot from a keyfile at `cfg.keyFile`. Two options,
# both his-hand; default is (a):
#   (a) agenix secret  — declare `soul-volume-key.age` (a random passphrase),
#       point `keyFile` at `config.age.secrets.soul-volume-key.path`. Unlock is
#       then fully automatic on boot (agenix decrypts with the host SSH key).
#   (b) hand-placed keyfile — Alexandru scp's a keyfile to a chmod-600 path
#       (e.g. /root/.soul/soul.key) out of band; set `keyFile` to that path.
#       Nothing about the key ever transits chat or the Nix store.
#
# See the bottom of this file + configuration.nix for the EXACT hand commands
# to (1) create the keyfile, (2) format the loopback container the first time,
# and (3) confirm it mounts.
{ config, pkgs, lib, ... }:

let
  cfg = config.services.sancta-soul-volume;
in
{
  options.services.sancta-soul-volume = {
    enable = lib.mkEnableOption "sancta-choir encrypted soul volume (LUKS-on-loopback) — STUB";

    imagePath = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/sancta-soul/soul.img";
      description = ''
        Path to the LUKS2 loopback container file on the existing ext4 root.
        HIS-HAND: created ONCE, out of band, by Alexandru (see init commands).
        This module never creates or truncates it — it only opens + mounts it,
        and only if it already exists (ConditionPathExists), so a deploy on a
        box where the image is missing is a no-op, never destructive.
      '';
    };

    keyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "config.age.secrets.soul-volume-key.path";
      description = ''
        Path to the keyfile that unlocks the LUKS container. HIS-HAND: either an
        agenix secret path (option a) or a hand-placed chmod-600 keyfile
        (option b). null keeps the whole volume INERT (the open service is
        skipped) until Alexandru wires a real key — the safe default.
      '';
    };

    mapperName = lib.mkOption {
      type = lib.types.str;
      default = "sancta-soul";
      description = "Name of the /dev/mapper device the LUKS container opens as.";
    };

    mountPoint = lib.mkOption {
      type = lib.types.path;
      # The membrane worker's ~/.claude substrate. Matches membrane-worker.nix
      # CLAUDE_CONFIG_DIR (/var/lib/sancta/.claude).
      default = "/var/lib/sancta/.claude";
      description = ''
        Where the decrypted soul volume is mounted — the Sancta user's
        ~/.claude. Owned by the membrane-worker user so `claude -p` reads/writes
        its config + state there, on encrypted storage.
      '';
    };

    owner = lib.mkOption {
      type = lib.types.str;
      default = "sancta";
      description = "User that owns the mounted soul volume (the membrane-worker user).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        # Secure-by-construction: a keyfile from the store would be world-
        # readable. Require agenix / hand-placed paths only.
        assertion = cfg.keyFile == null
          || !(lib.hasPrefix "/nix/store" (toString cfg.keyFile));
        message = ''
          services.sancta-soul-volume.keyFile points into /nix/store
          (world-readable). Use an agenix secret path or a hand-placed keyfile.
        '';
      }
    ];

    # Parent dir for the loopback image on the existing ext4 root. Root-owned;
    # the image itself is his-hand.
    systemd.tmpfiles.rules = [
      "d /var/lib/sancta-soul 0700 root root -"
      # Mount point pre-created so the first mount has a target; owned by the
      # membrane user. (Contents replaced by the volume once mounted.)
      "d ${cfg.mountPoint} 0700 ${cfg.owner} ${cfg.owner} -"
    ];

    # ── OPEN: cryptsetup luksOpen the loopback image → /dev/mapper/<name> ────
    # INERT-BY-DEFAULT: skipped unless BOTH the image exists AND a key is wired.
    # Never formats — luksOpen on a non-LUKS or missing file just fails cleanly
    # (and ConditionPathExists guards it), so this can NEVER wipe the root.
    systemd.services.sancta-soul-open = lib.mkIf (cfg.keyFile != null) {
      description = "Open sancta-choir encrypted soul volume (LUKS loopback) — STUB";
      after = [ "local-fs.target" ];
      before = [ "sancta-soul-mount.service" ];
      requiredBy = [ "sancta-soul-mount.service" ];
      unitConfig.ConditionPathExists = cfg.imagePath;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "sancta-soul-open" ''
          set -euo pipefail
          if [ ! -e /dev/mapper/${cfg.mapperName} ]; then
            ${pkgs.cryptsetup}/bin/cryptsetup luksOpen \
              --key-file ${lib.escapeShellArg (toString cfg.keyFile)} \
              ${lib.escapeShellArg (toString cfg.imagePath)} ${cfg.mapperName}
          fi
        '';
        ExecStop = pkgs.writeShellScript "sancta-soul-close" ''
          set -euo pipefail
          ${pkgs.cryptsetup}/bin/cryptsetup luksClose ${cfg.mapperName} || true
        '';
      };
    };

    # ── MOUNT: /dev/mapper/<name> → ~/.claude ───────────────────────────────
    # A systemd mount unit (not fileSystems.*) because the backing device is a
    # dynamically-opened mapper, not a boot-time-known disk — keeping it out of
    # fileSystems.* means a missing/locked volume never blocks boot.
    systemd.services.sancta-soul-mount = lib.mkIf (cfg.keyFile != null) {
      description = "Mount sancta-choir soul volume at ~/.claude — STUB";
      after = [ "sancta-soul-open.service" ];
      requires = [ "sancta-soul-open.service" ];
      unitConfig.ConditionPathExists = "/dev/mapper/${cfg.mapperName}";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "sancta-soul-mount" ''
          set -euo pipefail
          if ! ${pkgs.util-linux}/bin/mountpoint -q ${lib.escapeShellArg (toString cfg.mountPoint)}; then
            ${pkgs.util-linux}/bin/mount /dev/mapper/${cfg.mapperName} \
              ${lib.escapeShellArg (toString cfg.mountPoint)}
            ${pkgs.coreutils}/bin/chown ${cfg.owner}:${cfg.owner} \
              ${lib.escapeShellArg (toString cfg.mountPoint)}
          fi
        '';
        ExecStop = pkgs.writeShellScript "sancta-soul-umount" ''
          set -euo pipefail
          ${pkgs.util-linux}/bin/umount ${lib.escapeShellArg (toString cfg.mountPoint)} || true
        '';
      };
    };
  };

  # ══════════════════════════════════════════════════════════════════════════
  # HIS-HAND — FIRST-TIME INITIALIZATION (run on sancta-choir, as root, ONCE):
  #
  #   # 0. (option a) put a random key in agenix, OR (option b) place a keyfile:
  #   #    (a) cd secrets && agenix -e soul-volume-key.age   # paste random bytes
  #   #    (b) install -m600 <(head -c64 /dev/urandom | base64) /root/.soul/soul.key
  #
  #   # 1. create a fixed-size sparse image on the existing ext4 root (e.g. 4 GiB):
  #   install -d -m700 /var/lib/sancta-soul
  #   truncate -s 4G /var/lib/sancta-soul/soul.img
  #
  #   # 2. LUKS-format it with the SAME key the module will unlock with:
  #   cryptsetup luksFormat --type luks2 \
  #     --key-file /run/agenix/soul-volume-key /var/lib/sancta-soul/soul.img
  #     #                    ^ (option b: use your hand-placed keyfile path)
  #
  #   # 3. open + make an ext4 filesystem inside it, then close:
  #   cryptsetup luksOpen --key-file /run/agenix/soul-volume-key \
  #     /var/lib/sancta-soul/soul.img sancta-soul
  #   mkfs.ext4 /dev/mapper/sancta-soul
  #   cryptsetup luksClose sancta-soul
  #
  #   # 4. flip the module on (set services.sancta-soul-volume.keyFile), deploy,
  #   #    and confirm it mounted (CLOSING CHECK, his hand / the Witness):
  #   systemctl start sancta-soul-open sancta-soul-mount
  #   mountpoint /var/lib/sancta/.claude && echo "SOUL MOUNTED"
  # ══════════════════════════════════════════════════════════════════════════
}
