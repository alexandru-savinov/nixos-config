# Soul-mirror VAULT (receiver half) — the rpi5 end of the choir→rpi5 backup.
#
# sancta-choir pushes weekly dual-recipient-age soul archives here via a
# DEDICATED ssh key (agenix: secrets/sancta-soul-mirror-push-ssh-key.age,
# private half decrypted only on choir). This host authorizes the matching
# PUBLIC key with a FORCED COMMAND dispatching on $SSH_ORIGINAL_COMMAND over a
# fixed allowlist — put / sha256 / list / prune — all confined to the vault
# dir. The key can do nothing else: no shell, no forwarding, no PTY.
#
# ZERO-KNOWLEDGE (shape 2): this host holds ONLY ciphertext and NO recovery key.
# A root compromise of the home-facing rpi5 cannot open the soul. Restore is
# done off-host with the recovery key (Bitwarden / a keyed host) — never here.
# Cloned from hosts/sancta-claw/sancta-selfbackup-receiver.nix; the mechanism is
# proven in index/backups/soul-mirror-proof.sh (9/9).
#
# PLACEHOLDER: replace ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILtw8J4mXitlVP7rk/WWSW4T4d4xP+8Ix71rnifahVpK with the real push
# PUBLIC key AFTER (Alexandru's hand, one-time — see sancta-soul-mirror.nix).

{ pkgs, ... }:

let
  backupPushPubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILtw8J4mXitlVP7rk/WWSW4T4d4xP+8Ix71rnifahVpK";

  # Distinct from /root/dr (the self-backup vault) — the soul-mirror is a
  # separate subsystem with its own namespace, so the two never collide.
  vaultDir = "/var/lib/soul-mirror";

  # ── staleness dead-man's-switch (receiver-owned): OnFailure on the choir
  # producer can NEVER fire for the #1 backup killer — the run never happening
  # (choir off, timer gone, tailnet down). So the receiver flags loud if the
  # newest archive is older than the threshold. Best-effort reuse of the
  # existing Telegram channel; always writes a durable stamp file.
  stalenessThresholdDays = 8;
  stampFile = "${vaultDir}/.soul-mirror-staleness-alert";
  ocConfig = "/var/lib/openclaw/.openclaw/openclaw.json";

  stalenessScript = pkgs.writeShellScript "soul-mirror-staleness-check" ''
    set -uo pipefail
    DIR=${vaultDir}; THRESHOLD_DAYS=${toString stalenessThresholdDays}
    STAMP=${stampFile}; OC_CONFIG=${ocConfig}
    NEWEST=$(${pkgs.coreutils}/bin/ls -1t "$DIR"/sancta-soul-*.tar.gz.age 2>/dev/null \
      | ${pkgs.coreutils}/bin/head -n 1 || true)
    fail_loud() {
      msg="$1"
      echo "$msg" | ${pkgs.systemd}/bin/systemd-cat -t soul-mirror-staleness -p err
      ${pkgs.coreutils}/bin/printf '%s %s\n' "$(${pkgs.coreutils}/bin/date -Iseconds)" "$msg" > "$STAMP" || true
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
    NOW=$(${pkgs.coreutils}/bin/date +%s); MTIME=$(${pkgs.coreutils}/bin/stat -c %Y "$NEWEST")
    AGE_DAYS=$(( (NOW - MTIME) / 86400 ))
    echo "newest: $(${pkgs.coreutils}/bin/basename "$NEWEST") — age ''${AGE_DAYS}d (threshold ''${THRESHOLD_DAYS}d)"
    if [ "$AGE_DAYS" -gt "$THRESHOLD_DAYS" ]; then
      fail_loud "soul-mirror STALE: newest is ''${AGE_DAYS}d old (> ''${THRESHOLD_DAYS}d) — choir producer may be dead/off"; fi
    ${pkgs.coreutils}/bin/rm -f "$STAMP" 2>/dev/null || true
    echo "soul-mirror fresh (''${AGE_DAYS}d ≤ ''${THRESHOLD_DAYS}d) — dead-man's-switch OK"
  '';

  wrapper = pkgs.writeShellScript "soul-mirror-wrapper" ''
    set -euo pipefail
    DIR=${vaultDir}
    ${pkgs.coreutils}/bin/mkdir -p "$DIR"; ${pkgs.coreutils}/bin/chmod 700 "$DIR"
    _args=(); read -ra _args <<< "''${SSH_ORIGINAL_COMMAND:-}"
    set -- ''${_args[@]+"''${_args[@]}"}; action=''${1:-}
    safe_name() {
      n=$(${pkgs.coreutils}/bin/basename -- "$1")
      case "$n" in
        sancta-soul-*.tar.gz.age) printf '%s' "$n" ;;
        *) echo "rejected name: $1" >&2; exit 2 ;;
      esac
    }
    case "$action" in
      put)    name=$(safe_name "''${2:?put needs a name}")
              ${pkgs.coreutils}/bin/install -m 600 /dev/stdin "$DIR/$name"; echo "stored $name" ;;
      sha256) name=$(safe_name "''${2:?sha256 needs a name}")
              ${pkgs.coreutils}/bin/sha256sum "$DIR/$name" ;;
      list)   ${pkgs.coreutils}/bin/ls -1 "$DIR"/sancta-soul-*.tar.gz.age 2>/dev/null || true ;;
      prune)  keep=''${2:?prune needs a keep count}
              case "$keep" in *[!0-9]*) echo "bad keep: $keep" >&2; exit 2 ;; esac
              if [ "$keep" -lt 1 ]; then echo "keep must be >= 1: $keep" >&2; exit 2; fi
              old_list=$(${pkgs.coreutils}/bin/ls -1 "$DIR"/sancta-soul-*.tar.gz.age 2>/dev/null \
                | ${pkgs.coreutils}/bin/sort | ${pkgs.coreutils}/bin/head -n -"$keep" || true)
              if [ -n "$old_list" ]; then
                while IFS= read -r old; do [ -n "$old" ] || continue
                  echo "pruning remote: $old"; ${pkgs.coreutils}/bin/rm -f "$old"; done <<< "$old_list"
              fi
              echo "pruned (kept $keep)" ;;
      *) echo "unknown command" >&2; exit 2 ;;
    esac
  '';
in
{
  users.users.root.openssh.authorizedKeys.keys = [
    ''restrict,command="${wrapper}" ${backupPushPubKey}''
  ];

  systemd.tmpfiles.rules = [ "d ${vaultDir} 0700 root root -" ];

  systemd.services.soul-mirror-staleness = {
    description = "Staleness dead-man's-switch for the choir→rpi5 soul-mirror (receiver-owned)";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = stalenessScript;
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ vaultDir ];
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
}
