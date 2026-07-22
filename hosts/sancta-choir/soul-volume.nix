# sancta-choir — ENCRYPTED SOUL VOLUME for ~/.claude (LUKS-on-loopback-file).
#
# ══════════════════════════════════════════════════════════════════════════
# STAGING NOTE (Sancta→sancta-choir migration): AUTHORED first, deployed via
# the normal PR → CI → main → herdr-deploy path. Merging the PR is fine and
# expected; what must NOT happen from this repo alone is first-time creation —
# the loopback image is created by hand and the units remain absent until a key
# is wired. Once armed, a missing/wrong image fails closed and is never created,
# truncated, formatted, or replaced by this module. No real key material is
# written by this repo.
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
# device + one clean dm-crypt boundary and reuses the LUKS idioms already in
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
  mapperPath = "/dev/mapper/${cfg.mapperName}";
  testFaultAck = "sancta-soul-crash-window-v1";

  # Deterministic booted-VM fault interposer. Production units do not set
  # either environment variable, and module-eval locks that invariant. The
  # control file lets one disposable VM exercise multiple causal windows.
  maybeInjectTestFault = point: ''
    if [ "''${SANCTA_SOUL_TEST_FAULT_ACK:-}" = ${lib.escapeShellArg testFaultAck} ] \
      && [ -n "''${SANCTA_SOUL_TEST_FAULT_FILE:-}" ] \
      && [ -f "''${SANCTA_SOUL_TEST_FAULT_FILE:-}" ] \
      && [ "$(${pkgs.coreutils}/bin/cat -- \
        "''${SANCTA_SOUL_TEST_FAULT_FILE}")" = ${lib.escapeShellArg point} ]; then
      echo "TEST ONLY: injected soul-volume fault at ${point}" >&2
      exit 97
    fi
  '';

  verifyImageTarget = pkgs.writeShellScript "sancta-soul-verify-image-target" ''
    set -euo pipefail

    if [ -L ${lib.escapeShellArg (toString cfg.imagePath)} ] \
      || [ ! -f ${lib.escapeShellArg (toString cfg.imagePath)} ]; then
      echo "soul image must be an existing non-symlink regular file: ${cfg.imagePath}" >&2
      exit 1
    fi
    actual_image="$(${pkgs.coreutils}/bin/readlink -f -- \
      ${lib.escapeShellArg (toString cfg.imagePath)})"
    if [ "$actual_image" != ${lib.escapeShellArg (toString cfg.imagePath)} ]; then
      echo "refusing non-canonical soul image path: ${cfg.imagePath}" >&2
      exit 1
    fi
  '';

  verifyMountTarget = pkgs.writeShellScript "sancta-soul-verify-mount-target" ''
    set -euo pipefail

    if [ -L ${lib.escapeShellArg (toString cfg.mountPoint)} ] \
      || [ ! -d ${lib.escapeShellArg (toString cfg.mountPoint)} ]; then
      echo "soul mount target must be an existing non-symlink directory: ${cfg.mountPoint}" >&2
      exit 1
    fi
    actual_target="$(${pkgs.coreutils}/bin/readlink -f -- \
      ${lib.escapeShellArg (toString cfg.mountPoint)})"
    if [ "$actual_target" != ${lib.escapeShellArg (toString cfg.mountPoint)} ]; then
      echo "refusing non-canonical soul mount target: ${cfg.mountPoint}" >&2
      exit 1
    fi
  '';

  verifyMapper = pkgs.writeShellScript "sancta-soul-verify-mapper" ''
    set -euo pipefail
    export LC_ALL=C

    ${verifyImageTarget}
    if [ ! -e ${lib.escapeShellArg mapperPath} ]; then
      echo "expected mapper ${mapperPath} is missing" >&2
      exit 1
    fi

    expected_image="$(${pkgs.coreutils}/bin/readlink -f -- \
      ${lib.escapeShellArg (toString cfg.imagePath)})"
    mapper_status="$(${pkgs.cryptsetup}/bin/cryptsetup status \
      ${lib.escapeShellArg cfg.mapperName})" || {
      echo "unable to inspect mapper ${cfg.mapperName}" >&2
      exit 1
    }
    mapper_devices="$(printf '%s\n' "$mapper_status" \
      | ${pkgs.gawk}/bin/awk '$1 == "device:" { print $2 }')"
    mapper_device_count="$(printf '%s\n' "$mapper_devices" \
      | ${pkgs.gawk}/bin/awk 'NF { count++ } END { print count + 0 }')"
    if [ "$mapper_device_count" -ne 1 ]; then
      echo "mapper ${cfg.mapperName} must report exactly one backing device" >&2
      exit 1
    fi
    mapper_device="$(printf '%s\n' "$mapper_devices" \
      | ${pkgs.gawk}/bin/awk 'NF { print; exit }')"
    backing_files="$(${pkgs.util-linux}/bin/losetup \
      --noheadings --raw --output BACK-FILE -- "$mapper_device" \
      2>/dev/null || true)"
    backing_file_count="$(printf '%s\n' "$backing_files" \
      | ${pkgs.gawk}/bin/awk 'NF { count++ } END { print count + 0 }')"
    if [ "$backing_file_count" -ne 1 ]; then
      echo "mapper ${cfg.mapperName} must resolve to exactly one loopback file" >&2
      exit 1
    fi
    backing_file="$(printf '%s\n' "$backing_files" \
      | ${pkgs.gawk}/bin/awk 'NF { print; exit }')"
    actual_image="$(${pkgs.coreutils}/bin/readlink -f -- \
      "$backing_file" 2>/dev/null || true)"
    if [ -z "$actual_image" ] || [ "$actual_image" != "$expected_image" ]; then
      echo "refusing unexpected mapper ${cfg.mapperName} backing" >&2
      exit 1
    fi
  '';

  verifyMount = pkgs.writeShellScript "sancta-soul-verify-mount" ''
    set -euo pipefail

    ${verifyMountTarget}
    ${verifyMapper}
    if ! ${pkgs.util-linux}/bin/mountpoint -q \
      ${lib.escapeShellArg (toString cfg.mountPoint)}; then
      echo "expected mountpoint ${cfg.mountPoint} is not mounted" >&2
      exit 1
    fi
    expected_source="$(${pkgs.coreutils}/bin/readlink -f -- \
      ${lib.escapeShellArg mapperPath})"
    source_output="$(${pkgs.util-linux}/bin/findmnt -rn -o SOURCE \
      --mountpoint ${lib.escapeShellArg (toString cfg.mountPoint)})" || {
      echo "unable to inspect mounted source at ${cfg.mountPoint}" >&2
      exit 1
    }
    source_count="$(printf '%s\n' "$source_output" \
      | ${pkgs.gawk}/bin/awk 'NF { count++ } END { print count + 0 }')"
    if [ "$source_count" -ne 1 ]; then
      echo "expected exactly one mounted source at ${cfg.mountPoint}" >&2
      exit 1
    fi
    actual_source="$(${pkgs.coreutils}/bin/readlink -f -- \
      "$source_output" 2>/dev/null || true)"
    if [ -z "$actual_source" ] || [ "$actual_source" != "$expected_source" ]; then
      echo "refusing unexpected mounted source at ${cfg.mountPoint}" >&2
      exit 1
    fi
  '';
in
{
  options.services.sancta-soul-volume = {
    enable = lib.mkEnableOption "sancta-choir encrypted soul volume (LUKS-on-loopback)";

    imagePath = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/sancta-soul/soul.img";
      description = ''
        Path to the LUKS2 loopback container file on the existing ext4 root.
        HIS-HAND: created ONCE, out of band, by Alexandru (see init commands).
        This module never creates or truncates it — it only opens + mounts it.
        Once a key is wired, a missing image fails the unit and its dependents
        without creating, replacing, or formatting anything.
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
      # The Sancta worker's ~/.claude substrate. Matches sancta-worker.nix
      # CLAUDE_CONFIG_DIR (/var/lib/sancta/.claude).
      default = "/var/lib/sancta/.claude";
      description = ''
        Where the decrypted soul volume is mounted — the Sancta user's
        ~/.claude. Owned by the sancta-worker user so `claude -p` reads/writes
        its config + state there, on encrypted storage.
      '';
    };

    owner = lib.mkOption {
      type = lib.types.str;
      default = "sancta";
      description = "User that owns the mounted soul volume (the sancta-worker user).";
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
      {
        # The owner user is not declared by THIS module (sancta-worker.nix
        # declares `sancta`). Make the cross-module coupling explicit so
        # enabling the volume without the worker (or with a typo'd owner)
        # fails at eval, not at tmpfiles activation.
        assertion = lib.hasAttr cfg.owner config.users.users;
        message = ''
          services.sancta-soul-volume.owner ("${cfg.owner}") is not a declared
          user on this host. Declare it (sancta-worker.nix declares "sancta")
          or set `owner` to an existing user.
        '';
      }
    ];

    # Parent dir for the loopback image on the existing ext4 root. Root-owned;
    # the image itself is his-hand.
    systemd.tmpfiles.rules = [
      "d /var/lib/sancta-soul 0700 root root -"
      # Mount point pre-created so the first mount has a target; owned by the
      # sancta worker user. (Contents replaced by the volume once mounted.)
      "d ${cfg.mountPoint} 0700 ${cfg.owner} ${cfg.owner} -"
    ];

    # ── OPEN: cryptsetup luksOpen the loopback image → /dev/mapper/<name> ────
    # INERT-BY-DEFAULT: the unit is absent until a key is wired. Once armed, a
    # missing image or mismatched pre-existing mapper fails loudly so dependents
    # cannot mistake another device for the soul. This service never formats.
    systemd.services.sancta-soul-open = lib.mkIf (cfg.keyFile != null) {
      description = "Open sancta-choir encrypted soul volume (LUKS loopback)";
      after = [ "local-fs.target" ];
      before = [ "sancta-soul-mount.service" ];
      requiredBy = [ "sancta-soul-mount.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "sancta-soul-open" ''
          set -euo pipefail

          ${verifyImageTarget}

          # Crash-recovery: never close or reuse an unexpected live mapper.
          # Failing requires explicit operator review and cannot disrupt an
          # unrelated mapping that happens to have the configured name.
          if [ -e ${lib.escapeShellArg mapperPath} ]; then
            ${verifyMapper}
          fi
          if [ ! -e ${lib.escapeShellArg mapperPath} ]; then
            ${pkgs.cryptsetup}/bin/cryptsetup luksOpen \
              --key-file ${lib.escapeShellArg (toString cfg.keyFile)} \
              ${lib.escapeShellArg (toString cfg.imagePath)} \
              ${lib.escapeShellArg cfg.mapperName}
            ${maybeInjectTestFault "after-mapper-open"}
          fi
          ${verifyMapper}
        '';
        ExecStop = pkgs.writeShellScript "sancta-soul-close" ''
          set -euo pipefail
          if [ ! -e ${lib.escapeShellArg mapperPath} ]; then
            exit 0
          fi
          # Never close a mapping with the same name unless it still resolves
          # to the configured loopback image.
          ${verifyMapper}
          ${pkgs.cryptsetup}/bin/cryptsetup luksClose \
            ${lib.escapeShellArg cfg.mapperName}
          # cryptsetup owns the loop it auto-attached and is responsible for
          # releasing it. Never detach `losetup -j image` results here: another
          # loop may legitimately reference the same file, and guessing during
          # teardown is more dangerous than surfacing a leaked loop for review.
        '';
      };
    };

    # ── MOUNT: /dev/mapper/<name> → ~/.claude ───────────────────────────────
    # A systemd oneshot service (not fileSystems.*) because the backing device is a
    # dynamically-opened mapper, not a boot-time-known disk — keeping it out of
    # fileSystems.* means a missing/locked volume never blocks boot.
    systemd.services.sancta-soul-mount = lib.mkIf (cfg.keyFile != null) {
      description = "Mount sancta-choir soul volume at ~/.claude";
      after = [ "sancta-soul-open.service" ];
      requires = [ "sancta-soul-open.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "sancta-soul-mount" ''
          set -euo pipefail

          ${verifyMountTarget}
          if ! ${pkgs.util-linux}/bin/mountpoint -q ${lib.escapeShellArg (toString cfg.mountPoint)}; then
            # Refuse to mount over a NON-EMPTY dir: mounting would silently
            # shadow (hide, not destroy) any state already written to the bare
            # path — for a soul/state dir that is a silent availability loss.
            # The underlying dir is tmpfiles-created empty; anything else there
            # means something wrote before the volume mounted — surface it.
            if [ -n "$(${pkgs.coreutils}/bin/ls -A ${lib.escapeShellArg (toString cfg.mountPoint)} 2>/dev/null)" ]; then
              echo "refusing to mount over non-empty ${cfg.mountPoint} (would shadow existing data)" >&2
              exit 1
            fi
            ${pkgs.util-linux}/bin/mount ${lib.escapeShellArg mapperPath} \
              ${lib.escapeShellArg (toString cfg.mountPoint)}
            ${maybeInjectTestFault "after-mount"}
          fi
          # A mountpoint alone is insufficient: reject a pre-mounted tmpfs,
          # bind mount, or other mapper before changing ownership or allowing
          # Home Manager/worker/gateway dependents to run.
          ${verifyMount}
          # ext4's root inode owns the visible mount-point metadata, so tmpfiles'
          # mode on the covered directory is not enough. Enforce both invariants
          # after every start, including when the filesystem was already mounted.
          ${pkgs.coreutils}/bin/chown ${cfg.owner}:${cfg.owner} \
            ${lib.escapeShellArg (toString cfg.mountPoint)}
          ${pkgs.coreutils}/bin/chmod 0700 \
            ${lib.escapeShellArg (toString cfg.mountPoint)}
        '';
        ExecStop = pkgs.writeShellScript "sancta-soul-umount" ''
          set -euo pipefail
          if ! ${pkgs.util-linux}/bin/mountpoint -q \
            ${lib.escapeShellArg (toString cfg.mountPoint)}; then
            exit 0
          fi
          # Never unmount a filesystem that replaced the configured soul.
          ${verifyMount}
          ${pkgs.util-linux}/bin/umount ${lib.escapeShellArg (toString cfg.mountPoint)}
        '';
      };
    };

    # Re-run the exact source/image check for every dependent start transaction.
    # The mount service remains active after boot, so depending on it alone would
    # not notice an operator-side replacement that happened later.
    systemd.services.sancta-soul-verify = lib.mkIf (cfg.keyFile != null) {
      description = "Verify sancta-choir soul mapper and mount source";
      after = [ "sancta-soul-mount.service" ];
      requires = [ "sancta-soul-mount.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = verifyMount;
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
