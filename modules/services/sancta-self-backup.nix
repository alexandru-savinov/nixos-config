# Sancta Self-Backup — DURABLE weekly self-backup as a hardened systemd
# timer + service. Replaces the fragile session-cron (which dies with the
# session and expires after 7 days — the exact failure mode that killed the
# heartbeat for 2 days, and that let restic silently fail since ~Jun-10).
#
# This mirrors the just-proven MANUAL backup exactly:
#   1. tar the self (index + memory + CLAUDE.md), excluding regenerable
#      gallery renders, then gzip.
#   2. Encrypt with `age -R` to TWO recipients (LOAD-BEARING, not
#      recovery-only):
#        - the age recovery key (age1zex0…), and
#        - Alexandru's ssh-ed25519 public key.
#      A restore test on 2026-07-07 proved a RECOVERY-ONLY archive was
#      UNRESTORABLE with the ssh key he actually holds — dual-recipient is
#      the fix. Both are PUBLIC keys, so the service holds NO decryption
#      capability: even if this host is fully compromised, it cannot decrypt
#      its own backups.
#   3. Write to /home/nixos/backups/sancta-self-<YYYY-MM-DD>.tar.gz.age,
#      chmod 600, umask 077.
#   4. Push OFF-DEVICE to root@sancta-claw:/root/dr/ and VERIFY the remote
#      sha256 matches the local sha256 end-to-end. On mismatch: fail loudly,
#      non-zero — a backup whose off-device copy differs is not a backup.
#   5. Prune: keep only the last 4 weekly archives, locally AND on the remote.
#   6. On success: ONE feed line via `node …/iphone/feed`. On ANY failure
#      (encrypt / push / hash-mismatch / prune): exit non-zero so OnFailure
#      fires a LOUD feed alert (mirrors the heartbeat tripwire — a backup that
#      silently fails is the exact anti-pattern restic just demonstrated).
#   7. systemd timer: OnCalendar weekly, Persistent=true (a missed run after
#      downtime catches up).
#
# Off-device SSH auth (HARDENED):
#   The push uses a DEDICATED ssh key delivered via agenix
#   (sancta-selfbackup-push-ssh-key.age — private, decrypted only on this
#   host). Its matching PUBLIC key is authorized on sancta-claw for a
#   restricted `sancta-selfbackup` user whose forced command is a fixed
#   allowlist wrapper (put / sha256 / list / prune), confined to one
#   directory. No private key is ever baked into git or the nix store; the
#   only secret is the agenix-delivered key. See
#   hosts/sancta-claw/sancta-selfbackup-receiver.nix for the remote half.
#
# One-time (Alexandru's hand), post-merge:
#   * If the push key is NEW: generate it, add the private half to agenix
#     (agenix -e secrets/sancta-selfbackup-push-ssh-key.age), set the public
#     half in hosts/sancta-claw/sancta-selfbackup-receiver.nix, rebuild BOTH
#     hosts. Until the key file exists the service self-suppresses (no-auth)
#     so merging + rebuilding rpi5-full first is safe.
#   * Then: sudo nixos-rebuild switch --flake .#rpi5-full
#   First real backup fires after the rebuild + the next OnCalendar. The
#   manual 2026-07-07 archive already exists off-device as the current copy.

{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkOption mkIf types escapeShellArg concatStringsSep;
  cfg = config.services.sancta-self-backup;

  inherit (pkgs) coreutils gnutar gzip age openssh nodejs;
  cu = "${coreutils}/bin";

  # ── The backup script (runs as cfg.user). Uses only store-path binaries so
  # ProtectSystem=strict + a scoped PATH cannot surprise it at runtime. ──────
  #
  # recipientArgs: one `-R <file>` / `-r <recipient>` pair per recipient. age
  # accepts `-r` for an inline recipient string (works for both the age1…
  # recovery pubkey AND an ssh-ed25519 pubkey — age natively encrypts to ssh
  # recipients). Using -r with the literal strings keeps both recipients
  # visible in the generated unit (a review of the unit is a review of the
  # actual recipients) and needs no recipients file on disk.
  recipientFlags =
    concatStringsSep " "
      (map (r: "-r ${escapeShellArg r}") cfg.recipients);

  backupScript = pkgs.writeShellScript "sancta-self-backup" ''
    set -euo pipefail
    umask 077

    OUTDIR=${escapeShellArg cfg.localDir}
    REMOTE=${escapeShellArg cfg.remoteUser}@${escapeShellArg cfg.remoteHost}
    REMOTE_DIR=${escapeShellArg cfg.remoteDir}
    KEEP=${toString cfg.keep}
    DATE=$(${cu}/date +%F)
    BASENAME="sancta-self-$DATE.tar.gz.age"
    OUT="$OUTDIR/$BASENAME"

    ${cu}/mkdir -p "$OUTDIR"
    ${cu}/chmod 700 "$OUTDIR"

    # ── 0. No-auth self-suppression: safe to merge+rebuild BEFORE the push
    # key file exists. The agenix secret path is passed as $SSH_KEY; if it is
    # unset or the file is absent/empty, self-suppress (exit 0, no failure) so
    # merging + rebuilding rpi5-full BEFORE the key is provisioned does not
    # storm OnFailure alerts. The remote push simply doesn't happen yet.
    SSH_KEY=${escapeShellArg cfg.sshKeyFile}
    if [ ! -s "$SSH_KEY" ]; then
      echo "no push ssh key present ($SSH_KEY) — self-suppressing (reason: no-auth); no backup pushed" >&2
      exit 0
    fi
    # The committed .age ships a benign PLACEHOLDER until Alexandru provisions
    # the real key (so agenix activation + eval succeed pre-provision). A
    # placeholder is not a usable OpenSSH private key: self-suppress (no-auth)
    # rather than attempt a doomed push that would (correctly) fail loud every
    # week before the key exists. Once the real key is placed, this passes.
    if ! ${pkgs.gnugrep}/bin/grep -q "BEGIN OPENSSH PRIVATE KEY" "$SSH_KEY"; then
      echo "push ssh key is a placeholder / not an OpenSSH private key — self-suppressing (reason: no-auth)" >&2
      exit 0
    fi

    SSH="${openssh}/bin/ssh -i $SSH_KEY -o BatchMode=yes -o StrictHostKeyChecking=${
      if cfg.knownHostsFile != null then "yes -o UserKnownHostsFile=${cfg.knownHostsFile}" else "accept-new"
    } -o ConnectTimeout=30"

    # ── 1. tar the self, EXCLUDING regenerable gallery renders, then gzip.
    # --dereference (-h): CLAUDE.md is a home-manager symlink into the nix
    # store — without -h the archive would capture a dangling link, not the
    # file's content. --ignore-failed-read tolerates a source that vanished
    # mid-run (e.g. a temp file) without aborting the whole backup.
    # Excludes are relative to each source root.
    echo "=== tar + gzip → $OUT ==="
    ${gnutar}/bin/tar \
      --dereference \
      --ignore-failed-read \
      --exclude='gallery/*.png' \
      --exclude='gallery/*.gif' \
      --exclude='gallery/*-preview.txt' \
      -cf - \
      -C ${escapeShellArg (builtins.dirOf cfg.indexDir)} ${escapeShellArg (builtins.baseNameOf cfg.indexDir)} \
      -C ${escapeShellArg (builtins.dirOf cfg.memoryDir)} ${escapeShellArg (builtins.baseNameOf cfg.memoryDir)} \
      -C ${escapeShellArg (builtins.dirOf cfg.claudeMd)} ${escapeShellArg (builtins.baseNameOf cfg.claudeMd)} \
      | ${gzip}/bin/gzip \
      | ${age}/bin/age ${recipientFlags} -o "$OUT.tmp"

    ${cu}/chmod 600 "$OUT.tmp"
    ${cu}/mv "$OUT.tmp" "$OUT"
    ${cu}/chmod 600 "$OUT"

    if [ ! -s "$OUT" ]; then
      echo "ERROR: encrypted archive is empty — aborting" >&2
      exit 1
    fi

    LOCAL_SHA=$(${cu}/sha256sum "$OUT" | ${cu}/cut -d' ' -f1)
    echo "local sha256: $LOCAL_SHA"

    # ── 4. Push OFF-DEVICE via the restricted forced-command wrapper. The
    # remote side dispatches on $SSH_ORIGINAL_COMMAND over a fixed allowlist
    # (put / sha256 / list / prune), all confined to REMOTE_DIR.
    echo "=== push → $REMOTE:$REMOTE_DIR/$BASENAME ==="
    $SSH "$REMOTE" "put $BASENAME" < "$OUT"

    # ── 4b. VERIFY end-to-end: remote sha256 MUST equal local. A backup whose
    # off-device copy differs is not a backup — fail loudly + non-zero.
    REMOTE_SHA=$($SSH "$REMOTE" "sha256 $BASENAME" | ${cu}/cut -d' ' -f1)
    echo "remote sha256: $REMOTE_SHA"
    if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
      echo "ERROR: off-device sha256 MISMATCH (local=$LOCAL_SHA remote=$REMOTE_SHA) — backup NOT verified" >&2
      exit 1
    fi
    echo "off-device copy verified (sha256 match)"

    # ── 5. Prune: keep only the last $KEEP weekly archives, locally AND
    # remotely. Local prune here; remote prune via the wrapper.
    echo "=== prune (keep last $KEEP) ==="
    # List oldest-first by name (YYYY-MM-DD sorts chronologically), drop all
    # but the newest $KEEP, rm the rest locally. Capture the delete list first
    # (|| true only guards the head/pipe when there is nothing to prune — an
    # empty list is fine), then rm WITHOUT swallowing failures: a prune that
    # cannot delete an old archive must fail the run, not be silently ignored.
    OLD_LIST=$(${cu}/ls -1 "$OUTDIR"/sancta-self-*.tar.gz.age 2>/dev/null \
      | ${pkgs.coreutils}/bin/sort \
      | ${pkgs.coreutils}/bin/head -n -"$KEEP" || true)
    if [ -n "$OLD_LIST" ]; then
      while IFS= read -r old; do
        [ -n "$old" ] || continue
        echo "pruning local: $old"
        ${cu}/rm -f "$old"
      done <<< "$OLD_LIST"
    fi

    # Remote prune is idempotent and self-contained in the wrapper.
    $SSH "$REMOTE" "prune $KEEP"

    # ── 6. Success feed line (ONE line). Never fatal to the backup itself:
    # the archive is already safely off-device + verified at this point, so a
    # feed-write hiccup must not flip a good backup into a reported failure.
    echo "=== feed line ==="
    if [ -x ${escapeShellArg cfg.feedTool} ]; then
      ${nodejs}/bin/node ${escapeShellArg cfg.feedTool} \
        "💾 self-backup" \
        "weekly · dual-recipient age · off-device sancta-claw · sha256 ✓ · keep $KEEP" \
        || echo "WARNING: feed line failed (backup itself is OK)" >&2
    else
      echo "WARNING: feed tool ${cfg.feedTool} not executable — skipping feed line" >&2
    fi

    echo "=== sancta-self-backup OK: $OUT (verified off-device) ==="
  '';

  # ── OnFailure alert: a failed backup is surfaced LOUDLY into the feed, never
  # swallowed. Mirrors the heartbeat tripwire pattern. Runs as the same user so
  # it can write the feed. %i carries the failed unit name.
  alertScript = pkgs.writeShellScript "sancta-self-backup-alert" ''
    set -euo pipefail
    TS=$(${cu}/date -Iseconds)
    msg="❌ SELF-BACKUP FAILURE: ''${1:-sancta-self-backup} failed at $TS on $(${cu}/hostname)"
    echo "$msg" | ${pkgs.systemd}/bin/systemd-cat -t sancta-self-backup-alert -p err

    # Loud feed alert (the durable, human-visible signal). Never fatal.
    if [ -x ${escapeShellArg cfg.feedTool} ]; then
      ${nodejs}/bin/node ${escapeShellArg cfg.feedTool} \
        "❌ self-backup FAILED" \
        "$msg · journalctl -u sancta-self-backup" \
        || echo "WARNING: feed alert line failed" >&2
    fi
  '';
in
{
  options.services.sancta-self-backup = {
    enable = mkEnableOption "Durable weekly Sancta self-backup (dual-recipient age, off-device, hash-verified)";

    user = mkOption {
      type = types.str;
      default = "nixos";
      description = ''
        User the backup runs as. Must be able to READ all backup sources
        (index + memory + CLAUDE.md, all nixos-owned) and WRITE {option}`localDir`.
        Since the service only ENCRYPTS to public keys, it holds no decryption
        capability regardless of who it runs as.
      '';
    };

    indexDir = mkOption {
      type = types.str;
      default = "/home/nixos/.claude/index";
      description = "The meaning-index directory (gallery renders excluded).";
    };

    memoryDir = mkOption {
      type = types.str;
      default = "/home/nixos/.claude/projects/-home-nixos/memory";
      description = "The auto-memory directory.";
    };

    claudeMd = mkOption {
      type = types.str;
      default = "/home/nixos/.claude/CLAUDE.md";
      description = ''
        The global CLAUDE.md. May be a symlink into the nix store
        (home-manager); the tar dereferences it to capture content, not the link.
      '';
    };

    localDir = mkOption {
      type = types.str;
      default = "/home/nixos/backups";
      description = "Local directory for the encrypted archives (mode 700).";
    };

    recipients = mkOption {
      type = types.listOf types.str;
      default = [
        # The age recovery key (private half on rpi5:/root/dr + Bitwarden).
        "age1zex0chkw9swv62khuw73lftpcagu6t7d8vqa2h9mmnm23249hpuqx8f2kt"
        # Alexandru's ssh-ed25519 public key — LOAD-BEARING. A restore test on
        # 2026-07-07 proved a recovery-only archive was UNRESTORABLE with the
        # ssh key he actually holds; dual-recipient is the fix. Keep BOTH.
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPw5RFrFfZQUWlyfGSU1Q8BlEHnvIdBtcnCn+uYtEzal"
      ];
      description = ''
        age recipients (PUBLIC keys) the archive is encrypted to. MANDATORY
        dual-recipient: the age recovery key AND Alexandru's ssh pubkey. Both
        being public means the service holds NO decryption capability — even a
        fully compromised host cannot decrypt its own backups.
      '';
    };

    remoteHost = mkOption {
      type = types.str;
      default = "sancta-claw";
      description = "Off-device host (Tailscale hostname or IP) to push to.";
    };

    remoteUser = mkOption {
      type = types.str;
      # MUST match the account the receiver authorizes the push key on. The
      # receiver (hosts/sancta-claw/sancta-selfbackup-receiver.nix) authorizes
      # the restricted forced-command key on ROOT (so it can write /root/dr,
      # matching the proven manual root@sancta-claw:/root/dr push). The key's
      # capability is collapsed to the put/sha256/list/prune wrapper regardless
      # of the account, so this being root does not grant a shell.
      default = "root";
      description = ''
        SSH user on the remote whose forced command is a fixed
        put/sha256/list/prune allowlist confined to {option}`remoteDir`. Must
        match the account the push key is authorized on in
        hosts/sancta-claw/sancta-selfbackup-receiver.nix (root by default).
      '';
    };

    remoteDir = mkOption {
      type = types.str;
      default = "/root/dr";
      description = ''
        Off-device destination directory. The remote wrapper confines all
        operations to this directory.
      '';
    };

    sshKeyFile = mkOption {
      # str, NOT path: a runtime path to an agenix-delivered file. A Nix path
      # literal would copy the private key into the world-readable store — the
      # one thing we must never do. String means the PATH is referenced, never
      # the contents.
      type = types.str;
      description = ''
        Path to the SSH PRIVATE key for the off-device push (from agenix,
        decrypted only on this host). NEVER a store path. When the file is
        absent/empty the service self-suppresses (no-auth) so merging +
        rebuilding BEFORE the key is provisioned is safe.
      '';
    };

    knownHostsFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Optional known_hosts file for StrictHostKeyChecking=yes. When null,
        accept-new is used (TOFU on first connect).
      '';
    };

    feedTool = mkOption {
      type = types.str;
      default = "/home/nixos/.claude/index/iphone/feed";
      description = ''
        Path to the `feed` tool (node script). One success line on success;
        one loud alert line on failure. Never fatal to the backup itself.
      '';
    };

    feedDir = mkOption {
      type = types.str;
      default = "/home/nixos/.claude/index/iphone";
      description = ''
        Directory the feed tool writes feed.json into. Scoped as a
        ReadWritePath so the hardened service (ProtectSystem=strict) can append
        its one feed line. Must be the directory CONTAINING {option}`feedTool`.
      '';
    };

    keep = mkOption {
      type = types.int;
      default = 4;
      description = "Number of weekly archives to keep (local AND remote).";
    };

    onCalendar = mkOption {
      type = types.str;
      default = "Sun *-*-* 03:43:00";
      description = "systemd OnCalendar expression (weekly by default).";
    };

    randomizedDelaySec = mkOption {
      type = types.str;
      default = "30min";
      description = "RandomizedDelaySec for the timer.";
    };
  };

  config = mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d ${cfg.localDir} 0700 ${cfg.user} - -"
    ];

    systemd.services.sancta-self-backup = {
      description = "Durable weekly Sancta self-backup (dual-recipient age, off-device, hash-verified)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      # Template instance carries the failed unit name via %N → the alert's %i,
      # so the feed line names the actual unit that failed (not a hardcoded
      # fallback). Mirrors the restic backup-failure-alert@ pattern.
      onFailure = [ "sancta-self-backup-alert@%N.service" ];

      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        ExecStart = backupScript;
        # A large tar+gzip+age+push can exceed the 90s host default; give it
        # generous headroom so it is not SIGTERM'd mid-run (which would fire a
        # false OnFailure alert).
        TimeoutStartSec = "2h";
        Nice = 15;
        IOSchedulingClass = "idle";

        # ── Hardening. The service only READS the backup sources and ENCRYPTS
        # to public keys, so it holds no decryption capability. Scope its
        # writable surface to localDir only; sources are read-only.
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        # ProtectHome would hide the sources (under /home) and the feed tool;
        # instead scope precisely with ReadOnlyPaths + ReadWritePaths below.
        ProtectHome = false;
        ReadOnlyPaths = [ cfg.indexDir cfg.memoryDir cfg.claudeMd ];
        ReadWritePaths = [ cfg.localDir cfg.feedDir ];
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        LockPersonality = true;
        # ssh push needs INET; UNIX for local plumbing. No other families.
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        SystemCallFilter = [ "@system-service" ];
        # The agenix mount for OTHER secrets is not this service's business.
        InaccessiblePaths = [ "-/run/agenix.d" ];
      };
    };

    systemd.timers.sancta-self-backup = {
      description = "Timer for the durable weekly Sancta self-backup";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.onCalendar;
        Persistent = true;
        RandomizedDelaySec = cfg.randomizedDelaySec;
      };
    };

    # ── OnFailure: loud feed alert, never swallowed ─────────────────────────
    # Template ("@") service: the OnFailure instance name (%N of the failed
    # unit) arrives as %i → $1, so the alert names the real failed unit.
    systemd.services."sancta-self-backup-alert@" = {
      description = "Surface a failed self-backup into the feed (OnFailure hook) for %i";
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
