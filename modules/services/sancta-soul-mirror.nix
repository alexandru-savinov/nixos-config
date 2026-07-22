# Sancta SOUL-MIRROR — the choir→rpi5 reverse backup (migration design Phase 4).
#
# The LIVING soul now lives on sancta-choir at /var/lib/sancta/.claude (a LUKS
# mount). This service is the PRODUCER half: it runs ON sancta-choir, tars a
# curated ALLOWLIST of the soul-bearing roots (NOT the whole mount — see below),
# gzips, encrypts with `age -r` to TWO recipients, and pushes the ciphertext to
# the rpi5 VAULT over the tailnet. Deliberately modelled on the proven
# services.sancta-self-backup (restore-tested 2026-07-07) — same dual-recipient
# design, same self-suppression, same hardening — re-homed onto the cloud host
# and pointed home. It is a SIBLING, not a replacement: the existing rpi5→
# sancta-claw self-backup is left untouched so there is no cutover gap.
#
# SHAPE 2 — ZERO-KNOWLEDGE VAULT (Alexandru's decision, council-gated
# 2026-07-22, log council-20260722T063331Z-27a171):
#   * Dual-recipient age (recovery pubkey + Alexandru's ssh pubkey) → the
#     PRODUCER (choir) holds NO decryption capability: even a fully compromised
#     choir cannot read its own soul archives.
#   * The rpi5 vault holds ONLY ciphertext and NO recovery key → a root
#     compromise of the home-facing rpi5 still cannot open the soul. The leak is
#     UNREPRESENTABLE, not merely forbidden.
#   * Therefore the weekly at-rest verify here does the KEYLESS remote-sha
#     bit-rot check only; the decrypt smoke-test self-suppresses because no
#     recovery key is present on choir. The actual restore-drill (decrypt +
#     reconstitute + assert soul-present/secrets-absent) is run by Alexandru's
#     hand on a keyed host — see soul-mirror-restore-drill.sh in the soul.
#
# ALLOWLIST, not denylist (kills the exclusion-drift failure mode): the soul
# volume also holds live secrets (.credentials.json, .claude.json), 334 MB of
# raw session transcripts, and 401 MB of regenerable renders. An allowlist of
# soul-bearing roots excludes secrets BY CONSTRUCTION (a new ephemeral dir is
# not backed up unless explicitly added); within each root, regenerable renders
# are pattern-excluded. The mechanism (allowlist keeps soul + drops secrets,
# dual-recipient restore, forced-command receiver, prune) is proven end-to-end
# in index/backups/soul-mirror-proof.sh (9/9, throwaway keys).
#
# One-time (Alexandru's hand), post-merge:
#   a. Generate the NEW soul-mirror recovery key OFF rpi5 (option B):
#        age-keygen -o /tmp/soul-mirror-recovery.key
#      Store the PRIVATE key in Bitwarden + copy to a keyed host that is NOT
#      rpi5 (e.g. sancta-claw:/root/.age/), then shred the /tmp copy. Put its
#      PUBLIC key (age-keygen -y /tmp/soul-mirror-recovery.key) as the first
#      `recipients` entry above, replacing age1d3qlm08ncrd5ksk4mzypzlx7n8lge2yqd0ejsfvcanz03a9g3csqq2pwtq.
#   b. Generate the push key + agenix — the push key is choir→rpi5:
#        ssh-keygen -t ed25519 -C "sancta-choir -> rpi5 soul-mirror" -f /tmp/sm
#        agenix -e secrets/sancta-soul-mirror-push-ssh-key.age   # paste /tmp/sm (private)
#   c. Set backupPushPubKey in hosts/rpi5-full/soul-mirror-receiver.nix to /tmp/sm.pub
#   d. Rebuild rpi5-full (receiver) FIRST, then sancta-choir (producer).
# Until BOTH the push key and the recovery recipient are provisioned, the
# producer self-suppresses (no-auth / unprovisioned-recovery) — safe to merge
# + rebuild before provisioning.

{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkOption mkIf types escapeShellArg concatStringsSep concatMapStringsSep;
  cfg = config.services.sancta-soul-mirror;

  inherit (pkgs) coreutils gnutar gzip age openssh nodejs;
  cu = "${coreutils}/bin";

  # The producer user's REAL home (sancta → /var/lib/sancta, NOT /home/sancta).
  # In the accept-new fallback ssh persists the host key to $HOME/.ssh; this must
  # be a ReadWritePath under ProtectSystem=strict or the key can't persist and it
  # re-TOFUs every run. Derive from the declared user so it can never drift.
  sshDir = "${config.users.users.${cfg.user}.home}/.ssh";

  etcKnownHosts = "/etc/sancta-soul-mirror/known_hosts";
  effectiveKnownHosts =
    if cfg.knownHostsEntry != "" then etcKnownHosts else cfg.knownHostsFile;

  recipientFlags =
    concatStringsSep " " (map (r: "-r ${escapeShellArg r}") cfg.recipients);

  # tar `-C soulRoot <root>` for each allowlisted root, plus the exclude
  # patterns (relative to soulRoot). Every root is included from the ONE volume
  # root so restore reconstitutes the tree under a single top level.
  includeArgs = concatMapStringsSep " " escapeShellArg cfg.sourceRoots;
  excludeArgs = concatMapStringsSep " " (p: "--exclude=${escapeShellArg p}") cfg.excludePatterns;

  backupScript = pkgs.writeShellScript "sancta-soul-mirror" ''
    set -euo pipefail
    umask 077

    OUTDIR=${escapeShellArg cfg.localDir}
    REMOTE=${escapeShellArg cfg.remoteUser}@${escapeShellArg cfg.remoteHost}
    KEEP=${toString cfg.keep}
    DATE=$(${cu}/date +%F)
    BASENAME="sancta-soul-$DATE.tar.gz.age"
    OUT="$OUTDIR/$BASENAME"

    ${cu}/mkdir -p "$OUTDIR"; ${cu}/chmod 700 "$OUTDIR"

    # ── no-auth self-suppression (safe to merge+rebuild before the key exists).
    SSH_KEY=${escapeShellArg cfg.sshKeyFile}
    if [ ! -s "$SSH_KEY" ]; then
      echo "no push ssh key ($SSH_KEY) — self-suppressing (no-auth)" >&2; exit 0
    fi
    if ! ${openssh}/bin/ssh-keygen -y -f "$SSH_KEY" >/dev/null 2>&1; then
      echo "push ssh key is a placeholder / unusable — self-suppressing (no-auth)" >&2; exit 0
    fi

    # ── recovery-recipient provisioning guard (option B): refuse to run while
    # any recipient is still an unprovisioned placeholder — never silently drop
    # to a single ssh-only recipient. Safe to merge/deploy before provisioning.
    RECIPIENTS=( ${lib.concatMapStringsSep " " escapeShellArg cfg.recipients} )
    for r in "''${RECIPIENTS[@]}"; do
      case "$r" in
        age1*|ssh-*) ;;
        *) echo "recovery recipient not provisioned ($r) — self-suppressing (unprovisioned-recovery)" >&2; exit 0 ;;
      esac
    done

    SSH="${openssh}/bin/ssh -i $SSH_KEY -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=${
      if effectiveKnownHosts != null then "yes -o UserKnownHostsFile=${effectiveKnownHosts}" else "accept-new"
    } -o ConnectTimeout=30"

    # ── tar the ALLOWLIST from the ONE soul root, exclude regenerables, gzip,
    # age to BOTH recipients. --dereference so CLAUDE.md (a store symlink) is
    # captured as content. Only ciphertext ever leaves this host.
    echo "=== tar(allowlist) + gzip + age → $OUT ==="
    ${gnutar}/bin/tar \
      --dereference --ignore-failed-read \
      ${excludeArgs} \
      -C ${escapeShellArg cfg.soulRoot} \
      -cf - ${includeArgs} \
      | ${gzip}/bin/gzip \
      | ${age}/bin/age ${recipientFlags} -o "$OUT.tmp"

    ${cu}/chmod 600 "$OUT.tmp"; ${cu}/mv "$OUT.tmp" "$OUT"; ${cu}/chmod 600 "$OUT"
    [ -s "$OUT" ] || { echo "ERROR: empty archive — aborting" >&2; exit 1; }

    LOCAL_SHA=$(${cu}/sha256sum "$OUT" | ${cu}/cut -d' ' -f1)
    echo "local sha256: $LOCAL_SHA"

    # ── push to the rpi5 vault via the forced-command wrapper (put/sha256/
    # list/prune, confined to remoteDir). Only ciphertext crosses the wire.
    echo "=== push → $REMOTE ($BASENAME) ==="
    $SSH "$REMOTE" "put $BASENAME" < "$OUT"

    # ── verify end-to-end: the vault's sha256 MUST equal ours (a backup whose
    # off-device copy differs is not a backup — fail loud, non-zero).
    REMOTE_SHA=$($SSH "$REMOTE" "sha256 $BASENAME" | ${cu}/cut -d' ' -f1)
    echo "remote sha256: $REMOTE_SHA"
    if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
      echo "ERROR: off-device sha256 MISMATCH (local=$LOCAL_SHA remote=$REMOTE_SHA)" >&2; exit 1
    fi
    echo "off-device copy verified (sha256 match)"

    # ── prune AFTER verify (never before a good new archive is confirmed both
    # ends): keep newest $KEEP locally on choir AND remotely on rpi5.
    echo "=== prune (keep last $KEEP) ==="
    OLD_LIST=$(${cu}/ls -1 "$OUTDIR"/sancta-soul-*.tar.gz.age 2>/dev/null \
      | ${coreutils}/bin/sort | ${coreutils}/bin/head -n -"$KEEP" || true)
    if [ -n "$OLD_LIST" ]; then
      while IFS= read -r old; do [ -n "$old" ] || continue
        echo "pruning local: $old"; ${cu}/rm -f "$old"; done <<< "$OLD_LIST"
    fi
    $SSH "$REMOTE" "prune $KEEP"

    # ── one success feed line (never fatal to an already-verified backup).
    if [ -x ${escapeShellArg cfg.feedTool} ]; then
      ${nodejs}/bin/node ${escapeShellArg cfg.feedTool} \
        "💾 soul-mirror" \
        "weekly · dual-recipient age · choir→rpi5 vault · sha256 ✓ · keep $KEEP" \
        || echo "WARNING: feed line failed (backup is OK)" >&2
    fi
    echo "=== sancta-soul-mirror OK: $OUT (verified off-device) ==="
  '';

  alertScript = pkgs.writeShellScript "sancta-soul-mirror-alert" ''
    set -euo pipefail
    TS=$(${cu}/date -Iseconds)
    msg="❌ SOUL-MIRROR FAILURE: ''${1:-sancta-soul-mirror} failed at $TS on $(${cu}/hostname)"
    echo "$msg" | ${pkgs.systemd}/bin/systemd-cat -t sancta-soul-mirror-alert -p err
    if [ -x ${escapeShellArg cfg.feedTool} ]; then
      ${nodejs}/bin/node ${escapeShellArg cfg.feedTool} \
        "❌ soul-mirror FAILED" "$msg · journalctl -u sancta-soul-mirror" \
        || echo "WARNING: feed alert line failed" >&2
    fi
  '';

  # KEYLESS at-rest bit-rot check: ask the vault for its sha256 of the newest
  # archive and compare to the newest LOCAL sha. No recovery key on choir (shape
  # 2) → NO decrypt here. Detects silent rot of the off-device copy without a
  # re-fetch. The decrypt restore-drill is Alexandru's hand on a keyed host.
  verifyScript = pkgs.writeShellScript "sancta-soul-mirror-verify" ''
    set -euo pipefail
    OUTDIR=${escapeShellArg cfg.localDir}
    REMOTE=${escapeShellArg cfg.remoteUser}@${escapeShellArg cfg.remoteHost}
    SSH_KEY=${escapeShellArg cfg.sshKeyFile}

    NEWEST=$(${cu}/ls -1 "$OUTDIR"/sancta-soul-*.tar.gz.age 2>/dev/null \
      | ${coreutils}/bin/sort | ${cu}/tail -n 1 || true)
    if [ -z "$NEWEST" ] || [ ! -s "$NEWEST" ]; then
      echo "no local archive to verify — self-suppressing" >&2; exit 0; fi
    if [ ! -s "$SSH_KEY" ] || ! ${openssh}/bin/ssh-keygen -y -f "$SSH_KEY" >/dev/null 2>&1; then
      echo "no usable push key — self-suppressing bit-rot check" >&2; exit 0; fi

    BASENAME=$(${cu}/basename "$NEWEST")
    LOCAL_SHA=$(${cu}/sha256sum "$NEWEST" | ${cu}/cut -d' ' -f1)
    SSH="${openssh}/bin/ssh -i $SSH_KEY -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=${
      if effectiveKnownHosts != null then "yes -o UserKnownHostsFile=${effectiveKnownHosts}" else "accept-new"
    } -o ConnectTimeout=30"
    REMOTE_SHA=$($SSH "$REMOTE" "sha256 $BASENAME" | ${cu}/cut -d' ' -f1)
    echo "local=$LOCAL_SHA remote=$REMOTE_SHA ($BASENAME)"
    if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
      echo "ERROR: off-device REMOTE bit-rot — sha256 mismatch on $BASENAME" >&2; exit 1; fi
    echo "=== sancta-soul-mirror-verify OK: $BASENAME (no bit-rot) ==="
  '';
in
{
  options.services.sancta-soul-mirror = {
    enable = mkEnableOption "Sancta soul-mirror producer (choir→rpi5 dual-recipient age, zero-knowledge vault)";

    user = mkOption {
      type = types.str;
      default = "sancta";
      description = "User the producer runs as; must READ the soul volume and WRITE localDir. Only encrypts to public keys → holds no decryption capability.";
    };

    soulRoot = mkOption {
      type = types.str;
      default = "/var/lib/sancta/.claude";
      description = "The soul volume root (the LUKS mount). All sourceRoots are relative to this and tar'd from here as one top level.";
    };

    sourceRoots = mkOption {
      type = types.listOf types.str;
      default = [
        "index"
        "projects/-home-nixos/memory"
        "skills"
        "commands"
        "hooks"
        "agents"
        "CLAUDE.md"
        "settings.json"
      ];
      description = ''
        ALLOWLIST of soul-bearing paths (relative to soulRoot) to back up.
        Allowlist, NOT denylist: live secrets (.credentials.json, .claude.json),
        raw session transcripts, caches and plugins are excluded BY CONSTRUCTION
        (absent from the list). Raw transcripts (projects/*/*.jsonl, ~334 MB) are
        deliberately NOT included — memory is the durable distillation; add them
        here only by explicit choice.
      '';
    };

    excludePatterns = mkOption {
      type = types.listOf types.str;
      default = [
        "index/gallery/*.png"
        "index/gallery/*.gif"
        "index/gallery/*-preview.txt"
        "index/painter/raw"
        "index/painter/*.png"
        "index/painter/*/*.png"
        "index/painter/sky/.roots"
        "index/northstar/venv"
      ];
      description = "Regenerable renders/artifacts to exclude WITHIN the allowlisted roots (relative to soulRoot).";
    };

    recipients = mkOption {
      type = types.listOf types.str;
      default = [
        # SHAPE 2 / OPTION B (Alexandru's decision, 2026-07-22): a NEW
        # soul-mirror-specific age recovery key whose PRIVATE half is kept OFF
        # rpi5 (Bitwarden + a keyed host that is NOT the vault). This is what
        # makes the vault genuinely zero-knowledge: the existing recovery key
        # age1zex0… was DELIBERATELY dropped here because its private half lives
        # on rpi5 (/root/dr/recovery-sancta-claw.key for the self-backup verify),
        # which would let rpi5 root decrypt the soul it stores. Replace this
        # sentinel with the new recovery PUBLIC key (age1…) BY HAND. Until then
        # the producer self-suppresses (unprovisioned-recovery) — it will NOT
        # silently fall back to a single ssh-only recipient.
        "age1d3qlm08ncrd5ksk4mzypzlx7n8lge2yqd0ejsfvcanz03a9g3csqq2pwtq"
        # Alexandru's ssh pubkey — its private half is NEVER on rpi5. The second,
        # independent restore path (so recovery does not hinge on one key alone).
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPw5RFrFfZQUWlyfGSU1Q8BlEHnvIdBtcnCn+uYtEzal"
      ];
      description = ''
        age recipients (PUBLIC keys) the soul archive is encrypted to. Both
        public → the producer holds NO decryption capability. Option B: a NEW
        soul-mirror recovery key kept OFF rpi5 (NOT the age1zex0… key whose
        private half is on rpi5) AND Alexandru's ssh pubkey. The producer
        self-suppresses while any recipient is still an unprovisioned placeholder.
      '';
    };

    localDir = mkOption {
      type = types.str;
      default = "/var/lib/sancta/soul-mirror";
      description = "Local dir for the producer's own ciphertext copies (mode 700). choir cannot decrypt these either.";
    };

    remoteHost = mkOption { type = types.str; default = "rpi5"; description = "The vault host (Tailscale name)."; };
    remoteUser = mkOption { type = types.str; default = "root"; description = "Vault user whose forced command is put/sha256/list/prune confined to remoteDir."; };

    sshKeyFile = mkOption {
      type = types.str;
      description = "Path to the SSH PRIVATE push key (from agenix, decrypted only on choir). NEVER a store path. Absent/placeholder → self-suppress (no-auth).";
    };

    knownHostsFile = mkOption { type = types.nullOr types.str; default = null; description = "Optional known_hosts for StrictHostKeyChecking=yes; else accept-new."; };
    knownHostsEntry = mkOption { type = types.str; default = ""; description = "Declarative known_hosts line for the vault; when set, pins the host key (closes TOFU). `ssh-keyscan -t ed25519 rpi5`."; };

    feedTool = mkOption { type = types.str; default = "/var/lib/sancta/.claude/index/iphone/feed"; description = "feed tool (node); one line on success, one loud line on failure. Never fatal."; };
    feedDir = mkOption { type = types.str; default = "/var/lib/sancta/.claude/index/iphone"; description = "Directory the feed tool writes into (ReadWritePath for the hardened unit)."; };

    keep = mkOption { type = types.ints.positive; default = 4; description = "Weekly archives to keep (local AND remote, >=1)."; };
    onCalendar = mkOption { type = types.str; default = "Sun *-*-* 03:50:00"; description = "systemd OnCalendar (weekly)."; };
    randomizedDelaySec = mkOption { type = types.str; default = "30min"; description = "Timer RandomizedDelaySec."; };

    verify = {
      enable = mkOption { type = types.bool; default = true; description = "Enable the weekly KEYLESS at-rest remote bit-rot check (shape 2: no decrypt on choir)."; };
      onCalendar = mkOption { type = types.str; default = "Mon *-*-* 04:20:00"; description = "OnCalendar for the bit-rot check (one day after the backup)."; };
    };
  };

  config = mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d ${cfg.localDir} 0700 ${cfg.user} - -"
      "d ${sshDir} 0700 ${cfg.user} - -"
    ];

    environment.etc = lib.mkIf (cfg.knownHostsEntry != "") {
      "sancta-soul-mirror/known_hosts" = { text = cfg.knownHostsEntry + "\n"; mode = "0444"; };
    };

    systemd.services.sancta-soul-mirror = {
      description = "Sancta soul-mirror producer (choir→rpi5 dual-recipient age, zero-knowledge)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      onFailure = [ "sancta-soul-mirror-alert@%N.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        ExecStart = backupScript;
        TimeoutStartSec = "2h";
        Nice = 15;
        IOSchedulingClass = "idle";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = false;
        ReadOnlyPaths = [ cfg.soulRoot ];
        ReadWritePaths = [ cfg.localDir cfg.feedDir sshDir ];
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        LockPersonality = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        SystemCallFilter = [ "@system-service" ];
      };
    };

    systemd.timers.sancta-soul-mirror = {
      description = "Weekly Sancta soul-mirror producer";
      wantedBy = [ "timers.target" ];
      timerConfig = { OnCalendar = cfg.onCalendar; Persistent = true; RandomizedDelaySec = cfg.randomizedDelaySec; };
    };

    systemd.services.sancta-soul-mirror-verify = mkIf cfg.verify.enable {
      description = "Weekly keyless at-rest bit-rot check of the newest soul archive";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      onFailure = [ "sancta-soul-mirror-alert@%N.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        ExecStart = verifyScript;
        TimeoutStartSec = "20min";
        Nice = 19;
        IOSchedulingClass = "idle";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = false;
        ReadOnlyPaths = [ cfg.localDir ];
        ReadWritePaths = [ sshDir ];
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        LockPersonality = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        SystemCallFilter = [ "@system-service" ];
      };
    };

    systemd.timers.sancta-soul-mirror-verify = mkIf cfg.verify.enable {
      description = "Timer for the weekly soul-mirror bit-rot check";
      wantedBy = [ "timers.target" ];
      timerConfig = { OnCalendar = cfg.verify.onCalendar; Persistent = true; RandomizedDelaySec = cfg.randomizedDelaySec; };
    };

    systemd.services."sancta-soul-mirror-alert@" = {
      description = "Surface a failed soul-mirror run into the feed for %i";
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        ExecStart = "${alertScript} %i";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = false;
        ReadWritePaths = [ cfg.feedDir ];
        PrivateTmp = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        SystemCallFilter = [ "@system-service" ];
      };
    };
  };
}
