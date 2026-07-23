# Soul-mirror VAULT (puller half) — the rpi5 end of the choir↔rpi5 soul-mirror.
#
# REWORKED 2026-07-22 (push→pull, tailnet ACL correction): the tailnet ACL is
# choir=source-only / rpi5=home-reaches-out — "home/rpi5 reaches OUT to
# cloud/choir, cloud never reaches IN". A choir→rpi5 push (the OLD design)
# violated that invariant (it needed choir→rpi5, which the ACL forbids). This
# rework flips it: rpi5 now PULLS the already-encrypted archives FROM choir
# over rpi5→choir:22, which the ACL already allows. choir makes ZERO outbound
# connections of its own — see modules/services/sancta-soul-mirror.nix, whose
# only network-facing surface now is a READ-ONLY rrsync endpoint that THIS
# host connects TO, never the reverse.
#
# This host rsyncs choir's local vault (cfg.remoteDir on choir, i.e. the
# producer's `localDir`) into ITS OWN vault (cfg.vaultDir) via a DEDICATED
# pull ssh key (agenix: secrets/soul-mirror-pull-ssh-key.age, private half
# decrypted only on rpi5). The matching PUBLIC key is authorized on choir
# behind a restricted READ-ONLY rrsync forced command (see pullPubKey in
# sancta-soul-mirror.nix) — that key can read ciphertext out of one directory
# and nothing else: no write, no shell, no other path.
#
# Archives are persisted DIRECTLY as the .age files pulled from choir — NO
# restic, NO re-encryption. The payload is already age-ciphertext; wrapping it
# in another encrypted-backup layer would be pure overhead and would also
# complicate restore (a restore must be able to `age -d` the file straight out
# of this vault, unwrapped). This vault dir is a separate namespace from
# /root/dr (the rpi5→sancta-claw self-backup vault) so the two never collide.
#
# ZERO-KNOWLEDGE (shape 2, UNCHANGED by this rework): this host holds ONLY
# ciphertext and NO recovery key. A root compromise of the home-facing rpi5
# still cannot open the soul. Restore is done off-host with the recovery key
# (Bitwarden / a keyed host) — never here.
#
# PROVISIONING (his-hand, one-time):
#   a. Generate the pull key ON (or for) rpi5:
#        ssh-keygen -t ed25519 -C "rpi5 -> sancta-choir soul-mirror pull" -f /tmp/smp
#   b. Put the PRIVATE half into agenix (only rpi5 decrypts it):
#        agenix -e secrets/soul-mirror-pull-ssh-key.age   # paste /tmp/smp (private)
#   c. Put the PUBLIC half (/tmp/smp.pub) into
#      services.sancta-soul-mirror.pullPubKey on sancta-choir.
#   d. Rebuild BOTH hosts (either order — both self-suppress/stay-inert until
#      their respective half of the key pair is real).
#   e. The recovery age key is UNCHANGED and stays off-rpi5 — this rework only
#      changes which host dials out, not restore capability.
#
# RETIRED: the OLD choir→rpi5 PUSH key (agenix sancta-soul-mirror-push-ssh-key,
# authorized here as `backupPushPubKey` under root with a put/sha256/list/
# prune forced command) is gone. This host no longer authorizes ANY inbound
# key from choir — choir cannot reach in, full stop.

{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkOption mkIf types escapeShellArg;
  cfg = config.services.soul-mirror-pull;

  inherit (pkgs) coreutils openssh rsync;
  cu = "${coreutils}/bin";

  etcKnownHosts = "/etc/soul-mirror-pull/known_hosts";
  effectiveKnownHosts =
    if cfg.knownHostsEntry != "" then etcKnownHosts else cfg.knownHostsFile;

  pullScript = pkgs.writeShellScript "soul-mirror-pull" ''
    set -euo pipefail
    umask 077

    VAULT=${escapeShellArg cfg.vaultDir}
    REMOTE=${escapeShellArg cfg.remoteUser}@${escapeShellArg cfg.remoteHost}
    REMOTE_DIR=${escapeShellArg cfg.remoteDir}
    KEEP=${toString cfg.keep}
    SSH_KEY=${escapeShellArg cfg.sshKeyFile}

    ${cu}/mkdir -p "$VAULT"; ${cu}/chmod 700 "$VAULT"

    # ── no-auth self-suppression (safe to merge+rebuild before the key exists).
    if [ ! -s "$SSH_KEY" ]; then
      echo "no pull ssh key ($SSH_KEY) — self-suppressing (no-auth)" >&2; exit 0
    fi
    if ! ${openssh}/bin/ssh-keygen -y -f "$SSH_KEY" >/dev/null 2>&1; then
      echo "pull ssh key is a placeholder / unusable — self-suppressing (no-auth)" >&2; exit 0
    fi

    SSH="${openssh}/bin/ssh -i $SSH_KEY -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=${
      if effectiveKnownHosts != null then "yes -o UserKnownHostsFile=${effectiveKnownHosts}" else "accept-new"
    } -o ConnectTimeout=30"

    # ── rsync PULL: rpi5 initiates → choir's read-only rrsync endpoint
    # (confined to REMOTE_DIR) → this vault. Only ciphertext crosses the wire;
    # persisted DIRECTLY, no re-encryption. choir's endpoint rejects writes and
    # any path outside REMOTE_DIR, so this can only ever read what choir
    # deliberately published there.
    echo "=== rsync pull ← $REMOTE:$REMOTE_DIR ==="
    ${rsync}/bin/rsync -az \
      -e "$SSH" \
      "$REMOTE:$REMOTE_DIR" "$VAULT/"

    # ── prune: keep newest $KEEP in THIS vault. Independent of choir's own
    # local retention — rpi5 owns its own count on its own schedule.
    echo "=== prune vault (keep last $KEEP) ==="
    OLD_LIST=$(${cu}/ls -1 "$VAULT"/sancta-soul-*.tar.gz.age 2>/dev/null \
      | ${cu}/sort | ${cu}/head -n -"$KEEP" || true)
    if [ -n "$OLD_LIST" ]; then
      while IFS= read -r old; do [ -n "$old" ] || continue
        echo "pruning vault: $old"; ${cu}/rm -f "$old"; done <<< "$OLD_LIST"
    fi

    echo "=== soul-mirror-pull OK: vault=$VAULT (age-ciphertext only, zero-knowledge) ==="
  '';

  # ── staleness dead-man's-switch (receiver-owned, UNCHANGED by the rework):
  # a dead/off choir, a missing timer, or a broken tailnet all look the same
  # from here — no fresh archive lands. So THIS host (always-on) flags loud if
  # the newest archive in the vault is older than the threshold, regardless of
  # whether it's the puller failing or choir never having produced one.
  stalenessThresholdDays = 8;
  stampFile = "${cfg.vaultDir}/.soul-mirror-staleness-alert";
  ocConfig = "/var/lib/openclaw/.openclaw/openclaw.json";

  stalenessScript = pkgs.writeShellScript "soul-mirror-staleness-check" ''
    set -uo pipefail
    DIR=${cfg.vaultDir}; THRESHOLD_DAYS=${toString stalenessThresholdDays}
    STAMP=${stampFile}; OC_CONFIG=${ocConfig}
    NEWEST=$(${cu}/ls -1t "$DIR"/sancta-soul-*.tar.gz.age 2>/dev/null \
      | ${cu}/head -n 1 || true)
    fail_loud() {
      msg="$1"
      echo "$msg" | ${pkgs.systemd}/bin/systemd-cat -t soul-mirror-staleness -p err
      ${cu}/printf '%s %s\n' "$(${cu}/date -Iseconds)" "$msg" > "$STAMP" || true
      TOKEN=$(${pkgs.jq}/bin/jq -r '.channels.telegram.botToken // empty' "$OC_CONFIG" 2>/dev/null || true)
      CHAT_ID=$(${pkgs.jq}/bin/jq -r '.channels.telegram.chatId // "364749075"' "$OC_CONFIG" 2>/dev/null || echo 364749075)
      if [ -n "$TOKEN" ]; then
        ${pkgs.curl}/bin/curl -sf -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
          -d "chat_id=$CHAT_ID" -d "text=🔴 [rpi5] $msg" --max-time 10 || true
      fi
      exit 1
    }
    if [ -z "$NEWEST" ]; then
      fail_loud "soul-mirror STALE: NO archive in $DIR — never landed or wiped"; fi
    NOW=$(${cu}/date +%s); MTIME=$(${cu}/stat -c %Y "$NEWEST")
    AGE_DAYS=$(( (NOW - MTIME) / 86400 ))
    echo "newest: $(${cu}/basename "$NEWEST") — age ''${AGE_DAYS}d (threshold ''${THRESHOLD_DAYS}d)"
    if [ "$AGE_DAYS" -gt "$THRESHOLD_DAYS" ]; then
      fail_loud "soul-mirror STALE: newest is ''${AGE_DAYS}d old (> ''${THRESHOLD_DAYS}d) — choir producer or the pull may be dead/off"; fi
    ${cu}/rm -f "$STAMP" 2>/dev/null || true
    echo "soul-mirror fresh (''${AGE_DAYS}d ≤ ''${THRESHOLD_DAYS}d) — dead-man's-switch OK"
  '';
in
{
  options.services.soul-mirror-pull = {
    enable = mkEnableOption "Sancta soul-mirror puller (rpi5 pulls the choir vault via rsync over a restricted read-only endpoint)";

    sshKeyFile = mkOption {
      type = types.str;
      description = "Path to the SSH PRIVATE pull key (from agenix, decrypted only on rpi5). NEVER a store path. Absent/placeholder → self-suppress (no-auth).";
    };

    remoteHost = mkOption {
      type = types.str;
      # Public IP, not a Tailscale name — sancta-choir runs Tailscale SSH which
      # would intercept a tailscale0 connection and bypass the rrsync -ro
      # forced-command restriction (see PR body / backup-pull's identical
      # pattern for sancta-claw).
      default = "116.203.223.113";
      description = "The producer host to pull from. MUST be reachable WITHOUT going through Tailscale SSH on sancta-choir — that interception authenticates by tailnet identity and does not consult authorized_keys, so it would bypass the rrsync -ro forced-command restriction entirely. Use the public IP (matches services.backup-pull.remoteHost's identical pattern for sancta-claw), not a Tailscale name.";
    };
    remoteUser = mkOption { type = types.str; default = "sancta"; description = "Account on remoteHost the pull key is authorized under (must match services.sancta-soul-mirror.user there)."; };
    remoteDir = mkOption {
      type = types.str;
      default = "/";
      description = ''
        Source path passed to rsync, INTERPRETED RELATIVE TO THE RESTRICTED
        ROOT choir's rrsync forced command already chdirs into (that root IS
        services.sancta-soul-mirror.localDir there — currently
        /var/lib/sancta/soul-mirror). "/" means "everything under that root".
        Do NOT set this to an absolute filesystem path like the producer's
        localDir itself — rrsync 3.4.1 re-anchors an absolute path UNDER the
        restricted root (so "/var/lib/sancta/soul-mirror" would look for
        var/lib/sancta/soul-mirror *inside* the vault) and the pull silently
        finds nothing. Trailing slash matters (rsync "copy contents of dir"
        semantics) — keep one if overriding to a subdir.
      '';
    };

    vaultDir = mkOption { type = types.str; default = "/var/lib/soul-mirror"; description = "Local vault dir on rpi5 for the pulled ciphertext (mode 700). NO recovery key ever lives here (zero-knowledge)."; };

    keep = mkOption { type = types.ints.positive; default = 4; description = "Archives to keep in the rpi5 vault (>=1), independent of choir's own retention."; };
    onCalendar = mkOption { type = types.str; default = "Sun *-*-* 05:30:00"; description = "systemd OnCalendar for the pull (after choir's weekly producer run + margin)."; };
    randomizedDelaySec = mkOption { type = types.str; default = "30min"; description = "Timer RandomizedDelaySec."; };

    knownHostsFile = mkOption { type = types.nullOr types.str; default = null; description = "Optional known_hosts for StrictHostKeyChecking=yes; else accept-new."; };
    knownHostsEntry = mkOption { type = types.str; default = ""; description = "Declarative known_hosts line for choir; when set, pins the host key (closes TOFU). `ssh-keyscan -t ed25519 sancta-choir`."; };
  };

  config = mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d ${cfg.vaultDir} 0700 root root -"
      # accept-new fallback persists the host key to /root/.ssh/known_hosts;
      # unused (but harmless) once knownHostsEntry pins it declaratively.
      "d /root/.ssh 0700 root root -"
    ];

    environment.etc = lib.mkIf (cfg.knownHostsEntry != "") {
      "soul-mirror-pull/known_hosts" = { text = cfg.knownHostsEntry + "\n"; mode = "0444"; };
    };

    systemd.services.soul-mirror-pull = {
      description = "Sancta soul-mirror puller (rpi5 → choir read-only rrsync endpoint)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        ExecStart = pullScript;
        TimeoutStartSec = "2h";
        Nice = 15;
        IOSchedulingClass = "idle";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = false;
        ReadWritePaths = [ cfg.vaultDir "/root/.ssh" ];
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

    systemd.timers.soul-mirror-pull = {
      description = "Weekly Sancta soul-mirror pull (rpi5 ← choir)";
      wantedBy = [ "timers.target" ];
      timerConfig = { OnCalendar = cfg.onCalendar; Persistent = true; RandomizedDelaySec = cfg.randomizedDelaySec; };
    };

    systemd.services.soul-mirror-staleness = {
      description = "Staleness dead-man's-switch for the choir↔rpi5 soul-mirror (receiver-owned)";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = stalenessScript;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ cfg.vaultDir ];
        ReadOnlyPaths = [ ocConfig ];
        PrivateTmp = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        SystemCallFilter = [ "@system-service" ];
      };
    };

    systemd.timers.soul-mirror-staleness = {
      description = "Daily staleness check for the soul-mirror";
      wantedBy = [ "timers.target" ];
      timerConfig = { OnCalendar = "*-*-* 06:40:00"; Persistent = true; RandomizedDelaySec = "30min"; };
    };
  };
}
