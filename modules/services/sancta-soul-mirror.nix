# Sancta SOUL-MIRROR — the choir→rpi5 reverse backup (migration design Phase 4).
#
# The LIVING soul now lives on sancta-choir at /var/lib/sancta/.claude (a LUKS
# mount). This service is the PRODUCER half: it runs ON sancta-choir, tars a
# curated ALLOWLIST of the soul-bearing roots (NOT the whole mount — see below),
# gzips, encrypts with `age -r` to TWO recipients, and writes the ciphertext to
# a LOCAL vault directory (cfg.localDir). Deliberately modelled on the proven
# services.sancta-self-backup (restore-tested 2026-07-07) — same dual-recipient
# design, same hardening — re-homed onto the cloud host and pointed home.
#
# PULL, NOT PUSH (reworked 2026-07-22 — tailnet ACL correction): the tailnet
# ACL is choir=source-only / rpi5=home-reaches-out — "home/rpi5 reaches OUT to
# cloud/choir, cloud never reaches IN". A choir→rpi5 push violates that
# invariant. So this producer makes ZERO outbound connections: it only writes
# ciphertext to cfg.localDir and PRUNES ITS OWN local copies. rpi5 is the one
# that connects OUT (rpi5→choir:22, already ACL-permitted) and PULLS the
# archives — see hosts/rpi5-full/soul-mirror-pull.nix. This host exposes a
# READ-ONLY endpoint (below) for that pull: a restricted rrsync forced command
# on the `cfg.user` account, confined to cfg.localDir, no write, no shell. The
# choir→rpi5 PUSH key (sancta-soul-mirror-push-ssh-key.age) is RETIRED — this
# producer no longer holds or uses any outbound ssh key at all.
#
# SHAPE 2 — ZERO-KNOWLEDGE VAULT (Alexandru's decision, council-gated
# 2026-07-22, log council-20260722T063331Z-27a171):
#   * Dual-recipient age (recovery pubkey + Alexandru's ssh pubkey) → the
#     PRODUCER (choir) holds NO decryption capability: even a fully compromised
#     choir cannot read its own soul archives.
#   * The rpi5 vault holds ONLY ciphertext and NO recovery key → a root
#     compromise of the home-facing rpi5 still cannot open the soul. The leak is
#     UNREPRESENTABLE, not merely forbidden.
#   * There is no bit-rot verify service HERE any more: since rpi5 now
#     initiates every contact with choir, freshness/staleness is entirely
#     rpi5's to own (its dead-man's-switch in soul-mirror-pull.nix already
#     covers "the archive never arrived"). The decrypt restore-drill (decrypt +
#     reconstitute + assert soul-present/secrets-absent) remains Alexandru's
#     hand on a keyed host — see soul-mirror-restore-drill.sh in the soul.
#
# ALLOWLIST, not denylist (kills the exclusion-drift failure mode): the soul
# volume also holds live secrets (.credentials.json, .claude.json), 334 MB of
# raw session transcripts, and 401 MB of regenerable renders. An allowlist of
# soul-bearing roots excludes secrets BY CONSTRUCTION (a new ephemeral dir is
# not backed up unless explicitly added); within each root, regenerable renders
# are pattern-excluded. The mechanism (allowlist keeps soul + drops secrets,
# dual-recipient restore, prune) is proven end-to-end in
# index/backups/soul-mirror-proof.sh (9/9, throwaway keys) — the push/pull
# direction of the LAST leg (moving ciphertext choir→rpi5) is the only part
# that changed; tar+gzip+age+allowlist is untouched.
#
# PROVISIONED 2026-07-22 (Alexandru's hand): the recovery recipient below is a
# real age1… key whose PRIVATE half is OFF rpi5 (his Mac + Bitwarden). The
# OLD choir→rpi5 PUSH key (sancta-soul-mirror-push-ssh-key.age) is RETIRED by
# this rework and should be deleted from agenix once rpi5 confirms it no
# longer needs it (it never did anything rpi5 depended on).
#
# PROVISIONING (his-hand) for the NEW pull endpoint:
#   a. On rpi5, generate the PULL key:
#        ssh-keygen -t ed25519 -C "rpi5 -> sancta-choir soul-mirror pull" -f /tmp/smp
#      Put the PRIVATE half into agenix (decrypted only on rpi5):
#        agenix -e secrets/soul-mirror-pull-ssh-key.age   # paste /tmp/smp (private)
#   b. Set `pullPubKey` below (or via services.sancta-soul-mirror.pullPubKey on
#      the choir host config) to /tmp/smp.pub's content. Until this is a real
#      ssh-… key, the endpoint stays INERT — no key is ever authorized.
#   c. Rebuild sancta-choir (endpoint) FIRST, then rpi5-full (puller) — or
#      either order; the puller self-suppresses (no-auth) until its own key
#      exists, and the endpoint stays inert until pullPubKey is real, so there
#      is no unsafe ordering.
#   d. The recovery age key is UNCHANGED and still off-rpi5 — nothing about
#      restore capability changes in this rework, only which host dials out.
# A build assertion (config below) rejects any placeholder recipient, so an
# unprovisioned recovery key can never ship silently.

{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkOption mkIf types escapeShellArg concatStringsSep concatMapStringsSep;
  cfg = config.services.sancta-soul-mirror;

  inherit (pkgs) coreutils gnutar gzip age nodejs rrsync;
  cu = "${coreutils}/bin";

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
    KEEP=${toString cfg.keep}
    DATE=$(${cu}/date +%F)
    BASENAME="sancta-soul-$DATE.tar.gz.age"
    OUT="$OUTDIR/$BASENAME"

    ${cu}/mkdir -p "$OUTDIR"; ${cu}/chmod 700 "$OUTDIR"

    # (Recipient realness is enforced at BUILD time by a nix assertion in the
    # config block below — an unprovisioned/placeholder recipient fails the
    # build rather than being caught here at runtime over static values.)

    # ── tar the ALLOWLIST from the ONE soul root, exclude regenerables, gzip,
    # age to BOTH recipients. --dereference so CLAUDE.md (a store symlink) is
    # captured as content. Only ciphertext ever touches disk on this host, and
    # it NEVER leaves via any connection THIS host initiates — rpi5 pulls it.
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

    # ── prune: keep newest $KEEP LOCALLY only. This host has no visibility
    # into (and no connection to) whatever rpi5 currently holds — rpi5 prunes
    # its own vault copy independently, on its own schedule, after its own
    # pull succeeds. The two retention counts are deliberately decoupled.
    echo "=== prune (keep last $KEEP, local only) ==="
    OLD_LIST=$(${cu}/ls -1 "$OUTDIR"/sancta-soul-*.tar.gz.age 2>/dev/null \
      | ${coreutils}/bin/sort | ${coreutils}/bin/head -n -"$KEEP" || true)
    if [ -n "$OLD_LIST" ]; then
      while IFS= read -r old; do [ -n "$old" ] || continue
        echo "pruning local: $old"; ${cu}/rm -f "$old"; done <<< "$OLD_LIST"
    fi

    # ── one success feed line (never fatal to an already-written archive).
    if [ -x ${escapeShellArg cfg.feedTool} ]; then
      ${nodejs}/bin/node ${escapeShellArg cfg.feedTool} \
        "💾 soul-mirror" \
        "weekly · dual-recipient age · local vault (rpi5 pulls) · keep $KEEP" \
        || echo "WARNING: feed line failed (backup is OK)" >&2
    fi
    echo "=== sancta-soul-mirror OK: $OUT (local; awaiting rpi5 pull) ==="
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
in
{
  options.services.sancta-soul-mirror = {
    enable = mkEnableOption "Sancta soul-mirror producer (choir-local dual-recipient age vault; rpi5 pulls, zero-knowledge)";

    user = mkOption {
      type = types.str;
      default = "sancta";
      description = "User the producer runs as; must READ the soul volume and WRITE localDir. Only encrypts to public keys → holds no decryption capability. Also the account the read-only pull endpoint (pullPubKey) is authorized on.";
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
        # which would let rpi5 root decrypt the soul it stores. This is the
        # PROVISIONED recovery key (2026-07-22); a build assertion rejects any
        # placeholder here, so the archive can never ship with a single recipient.
        "age1d3qlm08ncrd5ksk4mzypzlx7n8lge2yqd0ejsfvcanz03a9g3csqq2pwtq"
        # Alexandru's ssh pubkey — its private half is NEVER on rpi5. The second,
        # independent restore path (so recovery does not hinge on one key alone).
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPw5RFrFfZQUWlyfGSU1Q8BlEHnvIdBtcnCn+uYtEzal"
      ];
      description = ''
        age recipients (PUBLIC keys) the soul archive is encrypted to. Both
        public → the producer holds NO decryption capability. Option B: a NEW
        soul-mirror recovery key kept OFF rpi5 (NOT the age1zex0… key whose
        private half is on rpi5) AND Alexandru's ssh pubkey. UNCHANGED by the
        push→pull rework.
      '';
    };

    localDir = mkOption {
      type = types.str;
      default = "/var/lib/sancta/soul-mirror";
      description = "Local vault dir for the producer's ciphertext copies (mode 700). choir cannot decrypt these either. This is exactly the directory the read-only pull endpoint (below) exposes to rpi5.";
    };

    pullPubKey = mkOption {
      type = types.str;
      default = "SOUL_MIRROR_PULL_PUBKEY_PLACEHOLDER";
      description = ''
        rpi5's PULL ssh PUBLIC key (ed25519), authorized on `cfg.user`'s
        authorized_keys with a RESTRICTED read-only rrsync forced command
        (`rrsync -ro localDir`, `restrict` — no shell, no write, no
        forwarding, no PTY). While this is the placeholder (not a real
        `ssh-…` key) the endpoint stays INERT: no key is authorized at all,
        so merging + rebuilding choir before rpi5's pull key exists is safe.
        The matching PRIVATE half lives in rpi5's agenix
        soul-mirror-pull-ssh-key.age — see hosts/rpi5-full/soul-mirror-pull.nix.
      '';
    };

    feedTool = mkOption { type = types.str; default = "/var/lib/sancta/.claude/index/iphone/feed"; description = "feed tool (node); one line on success, one loud line on failure. Never fatal."; };
    feedDir = mkOption { type = types.str; default = "/var/lib/sancta/.claude/index/iphone"; description = "Directory the feed tool writes into (ReadWritePath for the hardened unit)."; };

    keep = mkOption { type = types.ints.positive; default = 4; description = "Weekly archives to keep LOCALLY on choir (>=1). rpi5 keeps its own count independently."; };
    onCalendar = mkOption { type = types.str; default = "Sun *-*-* 03:50:00"; description = "systemd OnCalendar (weekly)."; };
    randomizedDelaySec = mkOption { type = types.str; default = "30min"; description = "Timer RandomizedDelaySec."; };
  };

  config = mkIf cfg.enable {
    # Fail the BUILD if any age recipient is not a real age1…/ssh-… PUBLIC key.
    # Recipients are static, so this is a build-time property checked at build
    # time — an unprovisioned/placeholder recovery recipient can never ship
    # silently (which would drop the archive to a single recipient or break
    # encryption).
    assertions = [{
      assertion = builtins.all
        (r: lib.hasPrefix "age1" r || lib.hasPrefix "ssh-" r)
        cfg.recipients;
      message = "services.sancta-soul-mirror.recipients: every entry must be a real age1…/ssh-… public key, not a placeholder.";
    }];

    systemd.tmpfiles.rules = [
      "d ${cfg.localDir} 0700 ${cfg.user} - -"
    ];

    # ── READ-ONLY pull endpoint for rpi5 ────────────────────────────────────
    # Authorizes rpi5's pull PUBLIC key on cfg.user with a restricted rrsync
    # forced command, read-only, confined to cfg.localDir: no write, no shell,
    # no forwarding, no PTY. Mirrors hosts/sancta-claw/backup-user.nix's
    # `rrsync -ro` pattern exactly. While pullPubKey is still the placeholder,
    # this authorizes NOTHING (empty list) — the endpoint is inert and safe to
    # merge/rebuild before rpi5's key exists.
    users.users.${cfg.user}.openssh.authorizedKeys.keys =
      mkIf (lib.hasPrefix "ssh-" cfg.pullPubKey) [
        ''restrict,command="${rrsync}/bin/rrsync -ro ${cfg.localDir}" ${cfg.pullPubKey}''
      ];

    systemd.services.sancta-soul-mirror = {
      description = "Sancta soul-mirror producer (choir-local dual-recipient age vault, zero-knowledge, no outbound connections)";
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
        ReadWritePaths = [ cfg.localDir cfg.feedDir ];
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        LockPersonality = true;
        # No network needed at all: this producer neither pushes nor verifies
        # remotely any more. AF_UNIX only (local plumbing / feed tool).
        RestrictAddressFamilies = [ "AF_UNIX" ];
        SystemCallFilter = [ "@system-service" ];
      };
    };

    systemd.timers.sancta-soul-mirror = {
      description = "Weekly Sancta soul-mirror producer";
      wantedBy = [ "timers.target" ];
      timerConfig = { OnCalendar = cfg.onCalendar; Persistent = true; RandomizedDelaySec = cfg.randomizedDelaySec; };
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
