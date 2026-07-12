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

  # Path of the NixOS-managed known_hosts materialized from knownHostsEntry.
  etcKnownHosts = "/etc/sancta-self-backup/known_hosts";

  # Effective known_hosts source: a declaratively-pinned entry wins (closes
  # the TOFU window entirely), else an operator-supplied file, else null →
  # accept-new (TOFU on first connect only, then pinned in the user's own
  # known_hosts which persists across runs — PrivateTmp does not touch $HOME).
  effectiveKnownHosts =
    if cfg.knownHostsEntry != "" then
      etcKnownHosts
    else
      cfg.knownHostsFile;

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
    # PARSE-validate with `ssh-keygen -y` (derive-pubkey, no secret printed):
    # the first live run (2026-07-12) proved a header-only grep is NOT enough —
    # the placeholder .age contained the literal "BEGIN OPENSSH PRIVATE KEY"
    # header, passed the old grep gate, and the push proceeded with an
    # unloadable key.
    if ! ${openssh}/bin/ssh-keygen -y -f "$SSH_KEY" >/dev/null 2>&1; then
      echo "push ssh key is a placeholder / not a usable OpenSSH private key — self-suppressing (reason: no-auth)" >&2
      exit 0
    fi

    # -o IdentitiesOnly=yes is LOAD-BEARING, not hygiene: without it, ssh also
    # offers the user's DEFAULT identities (~/.ssh/id_ed25519). On the first
    # live run that fallback key WAS authorized on root@sancta-claw (DR key,
    # NO forced command), so sshd ran a plain login shell which tried to
    # execute `put <name>` as a command → `bash: line 1: put: command not
    # found`, exit 127. The receiver contract (put/sha256/list/prune) only
    # exists behind the DEDICATED key's forced-command wrapper — so offer that
    # key and NOTHING else.
    SSH="${openssh}/bin/ssh -i $SSH_KEY -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=${
      if effectiveKnownHosts != null then "yes -o UserKnownHostsFile=${effectiveKnownHosts}" else "accept-new"
    } -o ConnectTimeout=30"

    # ── 1. tar the self, EXCLUDING regenerable artifacts, then gzip.
    # --dereference (-h): CLAUDE.md is a home-manager symlink into the nix
    # store — without -h the archive would capture a dangling link, not the
    # file's content. --ignore-failed-read tolerates a source that vanished
    # mid-run (e.g. a temp file) without aborting the whole backup.
    # Excludes are relative to each source root.
    #
    # Ratified spec excludes (regenerable gallery art):
    #   gallery/*.png, gallery/*.gif, gallery/*-preview.txt
    # Extensions beyond the ratified trio — all REGENERABLE, none is "the
    # self". The first live run (2026-07-12) produced a 483 MB tar stream vs
    # the ~110 MB spec-compliant archive; the extra was:
    #   northstar/venv          — 266 MB pip venv (qiskit); `pip install`
    #                             recreates it; the self is chsh.py+result.json
    #                             which STAY in the archive.
    #   painter/catalog3d/raw   — 33 MB downloaded HYG star database
    #                             (hygdata_v41.csv, public dataset); the
    #                             derived guarded catalog + scripts STAY.
    #   painter/sky/*.png       — regenerable sky renders (same class as
    #                             gallery art); the scene .json sources STAY.
    #   painter/sky/.roots      — GC-root SYMLINKS into the nix store
    #                             (stellarium, xvfb-run). THE actual 373 MB:
    #                             --dereference (needed for CLAUDE.md) follows
    #                             them and inhales the whole Stellarium package.
    #                             Created 2026-07-11 19:37 — the night before
    #                             the first timer run — which is why the manual
    #                             2026-07-07 archive was spec-sized and the
    #                             first automated run was not.
    echo "=== tar + gzip → $OUT ==="
    ${gnutar}/bin/tar \
      --dereference \
      --ignore-failed-read \
      --exclude='gallery/*.png' \
      --exclude='gallery/*.gif' \
      --exclude='gallery/*-preview.txt' \
      --exclude='northstar/venv' \
      --exclude='painter/catalog3d/raw' \
      --exclude='painter/sky/*.png' \
      --exclude='painter/sky/.roots' \
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

  # ── G2: at-rest verify + decrypt smoke-test (the LIFE check). Runs as root
  # (needs the recovery private key). Two independent proofs on the newest
  # archive, either failing loud (non-zero → OnFailure alert):
  #   (a) REMOTE bit-rot: ask the receiver for its sha256 of the newest remote
  #       archive (via the same put/sha256/list/prune wrapper) and compare to
  #       the local sha256. A mismatch means the off-device copy rotted after
  #       write — the write-time hash can never catch this.
  #   (b) DECRYPT smoke-test: `age -d -i <recovery-key> <newest local .age>
  #       | tar -tzf - >/dev/null` — list-only, NO extract, NO plaintext to
  #       disk. Proves the archive still opens with the recovery key and the
  #       tar stream is intact (guards silent age/gzip/tar corruption).
  # Trade-off (documented per spec): we do NOT re-fetch the full remote copy
  # weekly (heavy over Tailscale for a ~100 MB archive). Instead we do the
  # remote-sha comparison (cheap, catches remote rot) + a decrypt smoke-test of
  # the local most-recent archive (catches decrypt/tar corruption). A remote
  # decrypt would need a full re-fetch; the sha comparison is the proportionate
  # bit-rot detector, and the local decrypt proves restorability of the copy
  # the recovery key must open.
  verifyScript = pkgs.writeShellScript "sancta-self-backup-verify" ''
    set -euo pipefail
    umask 077

    OUTDIR=${escapeShellArg cfg.localDir}
    REMOTE=${escapeShellArg cfg.remoteUser}@${escapeShellArg cfg.remoteHost}
    REC_KEY=${escapeShellArg cfg.verify.recoveryKeyFile}
    SSH_KEY=${escapeShellArg cfg.sshKeyFile}

    # ── Self-suppression: safe to enable before provisioning. If there is no
    # local archive yet, no usable push key, or no recovery key, this is a
    # no-op (exit 0) rather than a false failure — mirrors the backup script's
    # no-auth self-suppression so enabling it pre-provision does not storm
    # OnFailure alerts.
    NEWEST=$(${cu}/ls -1 "$OUTDIR"/sancta-self-*.tar.gz.age 2>/dev/null \
      | ${pkgs.coreutils}/bin/sort | ${cu}/tail -n 1 || true)
    if [ -z "$NEWEST" ] || [ ! -s "$NEWEST" ]; then
      echo "no local archive to verify in $OUTDIR — self-suppressing (nothing to check)" >&2
      exit 0
    fi
    if [ ! -s "$REC_KEY" ]; then
      echo "no recovery key present ($REC_KEY) — self-suppressing decrypt smoke-test" >&2
      exit 0
    fi

    BASENAME=$(${cu}/basename "$NEWEST")
    LOCAL_SHA=$(${cu}/sha256sum "$NEWEST" | ${cu}/cut -d' ' -f1)
    echo "verifying newest archive: $BASENAME (local sha256: $LOCAL_SHA)"

    # ── (a) REMOTE bit-rot check. Only when a usable push key exists; otherwise
    # skip just this half (the remote copy can't be reached pre-provision) but
    # still run the local decrypt smoke-test below.
    # Same gate as the backup script: `ssh-keygen -y` PARSE-validation (a
    # header-only grep passed on a placeholder key, 2026-07-12) and
    # IdentitiesOnly=yes (never fall back to an unrestricted default identity
    # — the receiver contract lives behind the dedicated key's forced command).
    if [ -s "$SSH_KEY" ] && ${openssh}/bin/ssh-keygen -y -f "$SSH_KEY" >/dev/null 2>&1; then
      SSH="${openssh}/bin/ssh -i $SSH_KEY -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=${
        if effectiveKnownHosts != null then "yes -o UserKnownHostsFile=${effectiveKnownHosts}" else "accept-new"
      } -o ConnectTimeout=30"
      echo "=== remote sha256 (bit-rot check) → $REMOTE:$BASENAME ==="
      REMOTE_SHA=$($SSH "$REMOTE" "sha256 $BASENAME" | ${cu}/cut -d' ' -f1)
      echo "remote sha256: $REMOTE_SHA"
      if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
        echo "ERROR: off-device REMOTE bit-rot — sha256 mismatch (local=$LOCAL_SHA remote=$REMOTE_SHA) on $BASENAME" >&2
        exit 1
      fi
      echo "remote copy still matches (no bit-rot)"
    else
      echo "no usable push key — skipping remote bit-rot check (still running decrypt smoke-test)" >&2
    fi

    # ── (b) DECRYPT smoke-test. List-only; no plaintext ever hits disk. A
    # pipeline failure (age decrypt OR tar list) fails the run loud. set -o
    # pipefail (set above via set -euo pipefail) makes either stage's non-zero
    # propagate.
    echo "=== decrypt smoke-test (list-only, no extract) → $BASENAME ==="
    if ! ${age}/bin/age -d -i "$REC_KEY" "$NEWEST" 2>/dev/null \
        | ${gnutar}/bin/tar -tzf - >/dev/null 2>&1; then
      echo "ERROR: decrypt smoke-test FAILED — $BASENAME did not decrypt+list cleanly with the recovery key" >&2
      exit 1
    fi
    echo "decrypt smoke-test OK — archive opens and tar stream is intact"

    echo "=== sancta-self-backup-verify OK: $BASENAME (at-rest verified, still decryptable) ==="
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
        Optional known_hosts file for StrictHostKeyChecking=yes. When null (and
        {option}`knownHostsEntry` is also empty) accept-new is used (TOFU on
        first connect only, then pinned in this file). Prefer
        {option}`knownHostsEntry` for a fully declarative pin.
      '';
    };

    knownHostsEntry = mkOption {
      type = types.str;
      default = "";
      description = ''
        SSH known_hosts line for the remote push host, e.g.
        "sancta-claw ssh-ed25519 AAAA...". When set, it is materialized to
        /etc/sancta-self-backup/known_hosts and StrictHostKeyChecking=yes is
        used, CLOSING the TOFU/MITM window entirely (the host key is pinned
        declaratively — no first-connect trust). Get the value with:
        `ssh-keyscan -t ed25519 <host>`. Mirrors services.backup-pull.
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
      # positive: keep=0 would mean `head -n -0` keeps ALL (prunes nothing) —
      # a confusing no-op; forbid it at eval time.
      type = types.ints.positive;
      default = 4;
      description = "Number of weekly archives to keep (local AND remote, >= 1).";
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

    # ── G2: recurring AT-REST verify + decrypt smoke-test (LIFE check) ───────
    # The write-time sha256 above proves pushed==local at BIRTH; it does NOT
    # prove the off-device copy is still intact (bit-rot) or that the archive
    # still DECRYPTS. This separate timer re-checks the LIVING backup:
    #   (a) remote sha256 (via the same forced-command wrapper's `sha256`) ==
    #       the sha256 the pusher recorded → detects silent bit-rot of the
    #       off-device copy without a full re-fetch.
    #   (b) `age -d -i <recovery-key> <newest local .age> | tar -tzf - >/dev/null`
    #       — a LIST-ONLY decrypt smoke-test that proves the archive still opens
    #       and the tar stream is intact, with NO plaintext written to disk.
    # Mirrors services.backup-pull's weekly restic-check: separate timer +
    # service + loud OnFailure.
    verify = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Enable the recurring at-rest verify + decrypt smoke-test (the LIFE
          check). Runs as root (needs the recovery private key). Self-suppresses
          (no-op exit 0) until both a recovery key and an archive exist, so it
          is safe to enable before provisioning.
        '';
      };

      recoveryKeyFile = mkOption {
        type = types.str;
        default = "/root/dr/recovery-sancta-claw.key";
        description = ''
          Path to the age RECOVERY PRIVATE key used ONLY to prove the newest
          archive still decrypts (list-only, no extract). This is the same
          key the DR tooling uses (rpi5:/root/dr/recovery-sancta-claw.key,
          also in Bitwarden); its public half is the first recipient in
          {option}`recipients`. Referenced by PATH, never copied into the store.
          When absent, the smoke-test self-suppresses (no-op).
        '';
      };

      onCalendar = mkOption {
        type = types.str;
        # One day after the weekly backup (Sun 03:43) so a fresh archive is in
        # place to verify; mirrors backup-pull's separate Sunday check timer.
        default = "Mon *-*-* 04:17:00";
        description = "systemd OnCalendar for the at-rest verify (weekly by default).";
      };
    };
  };

  config = mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d ${cfg.localDir} 0700 ${cfg.user} - -"
      # Ensure ~/.ssh exists so that, in the accept-new fallback, the accepted
      # host key PERSISTS to ~/.ssh/known_hosts across runs — turning TOFU into
      # a one-time-first-connect trust rather than a per-run window. (For a
      # fully closed window, set knownHostsEntry to pin the key declaratively.)
      "d /home/${cfg.user}/.ssh 0700 ${cfg.user} - -"
    ]
    # The G2 verify runs as root and, in the accept-new fallback, persists the
    # host key to /root/.ssh/known_hosts — ensure that dir exists too.
    ++ lib.optional cfg.verify.enable "d /root/.ssh 0700 root - -";

    # Declarative host-key pin (closes the TOFU/MITM window) when an entry is
    # provided. StrictHostKeyChecking=yes then reads exactly this file.
    environment.etc = lib.mkIf (cfg.knownHostsEntry != "") {
      "sancta-self-backup/known_hosts" = {
        text = cfg.knownHostsEntry + "\n";
        mode = "0444";
      };
    };

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
        # ProtectHome=false is a DELIBERATE, scoped trade-off (not forgotten
        # hardening): the backup sources, the feed tool, and ~/.ssh all live
        # under /home, so hiding /home would break the service. ProtectSystem=
        # strict still makes the WHOLE filesystem (including /home) read-only
        # except the explicit ReadWritePaths below, and ReadOnlyPaths pins the
        # sources; so the effective writable surface is exactly localDir +
        # feedDir + ~/.ssh, no wider. The isolation is done by the path scoping,
        # not by ProtectHome.
        ProtectHome = false;
        ReadOnlyPaths = [ cfg.indexDir cfg.memoryDir cfg.claudeMd ];
        # localDir + feedDir for the archive and the feed line; ~/.ssh so the
        # accept-new fallback can PERSIST the accepted host key to known_hosts
        # (otherwise ProtectSystem=strict makes /home read-only and every run
        # re-TOFUs). With knownHostsEntry set, known_hosts is read from /etc and
        # this path is merely unused.
        ReadWritePaths = [
          cfg.localDir
          cfg.feedDir
          "/home/${cfg.user}/.ssh"
        ];
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
        # NOTE on OTHER agenix secrets: we deliberately do NOT add an
        # InaccessiblePaths entry for /run/agenix. Agenix decrypts each secret
        # to /run/agenix/<name> with per-secret 0400 owner-only modes, so this
        # service (running as cfg.user) already cannot read any secret it does
        # not own — including secrets owned by root or other service users. Its
        # OWN push key (cfg.sshKeyFile → /run/agenix/…) MUST stay readable, so
        # blocking /run/agenix wholesale would break the backup. The earlier
        # `-/run/agenix.d` entry was a no-op (wrong path) that gave a false
        # sense of isolation; the real isolation is the per-secret file mode.
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

    # ── G2: recurring at-rest verify + decrypt smoke-test (the LIFE check) ──
    # A separate weekly timer+service (mirrors services.backup-pull's
    # restic-check): remote bit-rot sha comparison + a list-only decrypt
    # smoke-test of the newest archive. Runs as ROOT (needs the recovery
    # private key at cfg.verify.recoveryKeyFile). Fails loud → the SAME
    # OnFailure alert as the backup, so a dead/rotting backup is surfaced into
    # the feed, never swallowed.
    systemd.services.sancta-self-backup-verify = mkIf cfg.verify.enable {
      description = "At-rest verify + decrypt smoke-test of the newest Sancta self-backup (LIFE check)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      onFailure = [ "sancta-self-backup-alert@%N.service" ];

      serviceConfig = {
        Type = "oneshot";
        # Root: reads the recovery PRIVATE key (0600 root) to prove the archive
        # still decrypts, and the push key (0400 nixos, root-readable) for the
        # remote sha check. No plaintext is ever written to disk.
        User = "root";
        ExecStart = verifyScript;
        # decrypt+tar-list of a ~100 MB archive plus an SSH round-trip can
        # exceed the 90s default; give headroom so it is not SIGTERM'd mid-run
        # (which would fire a false OnFailure alert).
        TimeoutStartSec = "1h";
        Nice = 19;
        IOSchedulingClass = "idle";

        # ── Hardening. The verify only READS (archive, recovery key, push key)
        # and pipes through age|tar to /dev/null — it writes nothing. Scope it
        # tight; no ReadWritePaths for the archive dir.
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = false;
        ReadOnlyPaths = [ cfg.localDir cfg.verify.recoveryKeyFile ];
        # /root/.ssh so the accept-new fallback can persist the host key across
        # runs (root runs this); unused when knownHostsEntry pins the key.
        ReadWritePaths = [ "/root/.ssh" ];
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        LockPersonality = true;
        # ssh round-trip needs INET; UNIX for local plumbing. No other families.
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        SystemCallFilter = [ "@system-service" ];
      };
    };

    systemd.timers.sancta-self-backup-verify = mkIf cfg.verify.enable {
      description = "Timer for the weekly Sancta self-backup at-rest verify (LIFE check)";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.verify.onCalendar;
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
