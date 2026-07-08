# Off-device receiver for the durable Sancta self-backup (push half).
#
# rpi5-full pushes weekly dual-recipient-age archives here via a DEDICATED
# ssh key (agenix: secrets/sancta-selfbackup-push-ssh-key.age, private half
# decrypted only on rpi5). This host authorizes the matching PUBLIC key with
# a FORCED COMMAND that dispatches on $SSH_ORIGINAL_COMMAND over a fixed
# allowlist — put / sha256 / list / prune — all confined to /root/dr. The key
# can do NOTHING else: no shell, no port/agent/X11 forwarding, no PTY, no
# arbitrary command.
#
# Target is /root/dr (matching the proven manual `root@sancta-claw:/root/dr/`
# push and co-located with the DR recovery keys). The forced command runs on
# the root account so it can write that directory, but `restrict` +
# `command=` collapse that key's capability to exactly the four sub-commands
# below — a review of the wrapper is a review of everything the key can do.
#
# PLACEHOLDER: replace SANCTA_SELFBACKUP_PUBKEY_PLACEHOLDER with the real
# public key AFTER (Alexandru's hand, one-time):
#   ssh-keygen -t ed25519 -C "rpi5 -> sancta-claw sancta-self-backup" -f /tmp/ssb
#   agenix -e secrets/sancta-selfbackup-push-ssh-key.age   # paste /tmp/ssb (private)
#   # set backupPushPubKey below to the /tmp/ssb.pub content, then rebuild BOTH hosts
#
# The wrapper is intentionally tiny and auditable:
#   put <name>    — read stdin → /root/dr/<name> (basename-sanitized), 0600
#   sha256 <name> — print `sha256sum` of /root/dr/<name>
#   list          — list /root/dr/sancta-self-*.tar.gz.age
#   prune <keep>  — keep newest <keep> archives, rm the rest

{ pkgs, ... }:

let
  # Replace with the real ed25519 PUBLIC key (see header). Until then this is
  # an inert placeholder — no real key is authorized, and the rpi5 service
  # self-suppresses (no-auth) because its private key does not yet exist.
  backupPushPubKey = "SANCTA_SELFBACKUP_PUBKEY_PLACEHOLDER";

  remoteDir = "/root/dr";

  # ── G1: STALENESS DEAD-MAN'S-SWITCH (receiver-owned) ────────────────────
  # OnFailure on the rpi5 pusher fires ONLY when the unit RUNS and exits
  # non-zero — it can NEVER fire for the #1 backup killer: the run never
  # happening (rpi5 off, timer gone, state wiped). A dead rpi5 cannot alert
  # on itself, so the RECEIVER (this always-on VPS) owns the staleness check:
  # if the newest /root/dr/sancta-self-*.age is older than a threshold
  # (default 8 days = weekly cadence + one missed beat), FAIL LOUD.
  #
  # "Loud" here, per the human gate: no NEW outward notifier is built. It is
  #   (1) a journal ERROR line (systemd-cat -p err), and
  #   (2) a durable STAMP FILE the human can see, and
  #   (3) a BEST-EFFORT reuse of the EXISTING Telegram channel — the same
  #       token/chat-id already read at runtime from the OpenClaw config by
  #       hosts/sancta-claw/openclaw-watchers.nix (no new secret, no new
  #       channel; silently skipped if the token is absent).
  # (2) always fires so staleness is visible even with no Telegram token.
  stalenessThresholdDays = 8;
  stampFile = "/root/dr/.selfbackup-staleness-alert";
  ocConfig = "/var/lib/openclaw/.openclaw/openclaw.json";

  stalenessScript = pkgs.writeShellScript "sancta-selfbackup-staleness-check" ''
    set -uo pipefail
    DIR=${remoteDir}
    THRESHOLD_DAYS=${toString stalenessThresholdDays}
    STAMP=${stampFile}
    OC_CONFIG=${ocConfig}

    NEWEST=$(${pkgs.coreutils}/bin/ls -1t "$DIR"/sancta-self-*.tar.gz.age 2>/dev/null \
      | ${pkgs.coreutils}/bin/head -n 1 || true)

    fail_loud() {
      msg="$1"
      echo "$msg" | ${pkgs.systemd}/bin/systemd-cat -t sancta-selfbackup-staleness -p err
      # Durable, human-visible marker (always). Overwrite with the latest state.
      ${pkgs.coreutils}/bin/printf '%s %s\n' "$(${pkgs.coreutils}/bin/date -Iseconds)" "$msg" > "$STAMP" || true
      # Best-effort reuse of the EXISTING Telegram channel (openclaw-watchers
      # pattern). No new secret/channel; skipped silently if token is absent.
      TOKEN=$(${pkgs.jq}/bin/jq -r '.channels.telegram.botToken // empty' "$OC_CONFIG" 2>/dev/null || true)
      CHAT_ID=$(${pkgs.jq}/bin/jq -r '.channels.telegram.chatId // "364749075"' "$OC_CONFIG" 2>/dev/null || echo 364749075)
      if [ -n "$TOKEN" ]; then
        ${pkgs.curl}/bin/curl -sf -X POST \
          "https://api.telegram.org/bot$TOKEN/sendMessage" \
          -d "chat_id=$CHAT_ID" \
          -d "text=🔴 [sancta-claw] $msg" \
          --max-time 10 || true
      fi
      exit 1
    }

    if [ -z "$NEWEST" ]; then
      fail_loud "self-backup STALE: NO archive found in $DIR — the backup may have never landed or was wiped"
    fi

    NOW=$(${pkgs.coreutils}/bin/date +%s)
    MTIME=$(${pkgs.coreutils}/bin/stat -c %Y "$NEWEST")
    AGE_DAYS=$(( (NOW - MTIME) / 86400 ))
    echo "newest archive: $(${pkgs.coreutils}/bin/basename "$NEWEST") — age ''${AGE_DAYS}d (threshold ''${THRESHOLD_DAYS}d)"

    if [ "$AGE_DAYS" -gt "$THRESHOLD_DAYS" ]; then
      fail_loud "self-backup STALE: newest archive is ''${AGE_DAYS}d old (> ''${THRESHOLD_DAYS}d) — rpi5 pusher may be dead/off/timer-gone"
    fi

    # Fresh again → clear any prior stale marker so it reflects current state.
    ${pkgs.coreutils}/bin/rm -f "$STAMP" 2>/dev/null || true
    echo "self-backup fresh (''${AGE_DAYS}d ≤ ''${THRESHOLD_DAYS}d) — dead-man's-switch OK"
  '';

  # Forced-command wrapper: the ONLY thing this key can execute. Dispatches on
  # $SSH_ORIGINAL_COMMAND; every path is basename-confined to remoteDir; any
  # unrecognised command is rejected non-zero.
  wrapper = pkgs.writeShellScript "sancta-selfbackup-wrapper" ''
    set -euo pipefail
    DIR=${remoteDir}
    ${pkgs.coreutils}/bin/mkdir -p "$DIR"
    ${pkgs.coreutils}/bin/chmod 700 "$DIR"

    # Split $SSH_ORIGINAL_COMMAND SAFELY: `read -ra` into an explicit array
    # instead of an unquoted `set -- $cmd`, so no IFS metacharacter in the
    # (attacker-influencable) command participates in word-splitting/globbing
    # before the allowlist below is applied. Defense-in-depth on top of the
    # safe_name / digit-only checks.
    _args=()
    read -ra _args <<< "''${SSH_ORIGINAL_COMMAND:-}"
    set -- ''${_args[@]+"''${_args[@]}"}
    action=''${1:-}

    # Reject any path component that could escape remoteDir. Only a plain
    # basename is ever accepted; strip any directory part defensively.
    safe_name() {
      n=$(${pkgs.coreutils}/bin/basename -- "$1")
      case "$n" in
        sancta-self-*.tar.gz.age) printf '%s' "$n" ;;
        *) echo "rejected name: $1" >&2; exit 2 ;;
      esac
    }

    case "$action" in
      put)
        name=$(safe_name "''${2:?put needs a name}")
        # stdin → file, owner-only.
        ${pkgs.coreutils}/bin/install -m 600 /dev/stdin "$DIR/$name"
        echo "stored $name"
        ;;
      sha256)
        name=$(safe_name "''${2:?sha256 needs a name}")
        ${pkgs.coreutils}/bin/sha256sum "$DIR/$name"
        ;;
      list)
        ${pkgs.coreutils}/bin/ls -1 "$DIR"/sancta-self-*.tar.gz.age 2>/dev/null || true
        ;;
      prune)
        keep=''${2:?prune needs a keep count}
        # Digits only AND >= 1. keep=0 is rejected: `head -n -0` returns ALL
        # lines (prunes nothing), which would silently mean "keep everything"
        # under a name that reads like "delete all" — refuse the ambiguity.
        case "$keep" in *[!0-9]*) echo "bad keep: $keep" >&2; exit 2 ;; esac
        if [ "$keep" -lt 1 ]; then echo "keep must be >= 1: $keep" >&2; exit 2; fi
        # || true guards only the "nothing to prune" case (head over an empty
        # list); the rm loop below does NOT swallow failures, so a delete that
        # cannot complete surfaces non-zero to the pushing rpi5 (which fails the
        # backup run loud) rather than being silently reported as pruned.
        old_list=$(${pkgs.coreutils}/bin/ls -1 "$DIR"/sancta-self-*.tar.gz.age 2>/dev/null \
          | ${pkgs.coreutils}/bin/sort \
          | ${pkgs.coreutils}/bin/head -n -"$keep" || true)
        if [ -n "$old_list" ]; then
          while IFS= read -r old; do
            [ -n "$old" ] || continue
            echo "pruning remote: $old"
            ${pkgs.coreutils}/bin/rm -f "$old"
          done <<< "$old_list"
        fi
        echo "pruned (kept $keep)"
        ;;
      *)
        echo "unknown command: $cmd" >&2
        exit 2
        ;;
    esac
  '';
in
{
  users.users.root.openssh.authorizedKeys.keys = [
    # restrict: no port/agent/X11 forwarding, no PTY. command=: the key can
    # ONLY invoke the wrapper (put/sha256/list/prune, confined to /root/dr).
    ''restrict,command="${wrapper}" ${backupPushPubKey}''
  ];

  systemd.tmpfiles.rules = [
    "d ${remoteDir} 0700 root root -"
  ];

  # ── G1: staleness dead-man's-switch — receiver-owned, runs daily ─────────
  # Daily is intentional: the check itself must not depend on the rpi5 push
  # cadence. It flags loud within one day of crossing the threshold. Runs as
  # root (reads /root/dr + the OpenClaw config for the existing Telegram token).
  systemd.services.sancta-selfbackup-staleness = {
    description = "Staleness dead-man's-switch for the off-device self-backup (receiver-owned)";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = stalenessScript;
      # Read /root/dr + the OpenClaw config; write only the stamp file in
      # /root/dr. No decryption, no secret handling of its own.
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ remoteDir ];
      ReadOnlyPaths = [ ocConfig ];
      PrivateTmp = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
      SystemCallFilter = [ "@system-service" ];
    };
  };

  systemd.timers.sancta-selfbackup-staleness = {
    description = "Daily staleness check for the off-device self-backup";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 06:30:00";
      Persistent = true;
      RandomizedDelaySec = "30min";
    };
  };
}
