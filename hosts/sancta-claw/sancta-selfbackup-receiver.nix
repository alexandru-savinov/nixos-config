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

  # Forced-command wrapper: the ONLY thing this key can execute. Dispatches on
  # $SSH_ORIGINAL_COMMAND; every path is basename-confined to remoteDir; any
  # unrecognised command is rejected non-zero.
  wrapper = pkgs.writeShellScript "sancta-selfbackup-wrapper" ''
    set -euo pipefail
    DIR=${remoteDir}
    ${pkgs.coreutils}/bin/mkdir -p "$DIR"
    ${pkgs.coreutils}/bin/chmod 700 "$DIR"

    cmd=''${SSH_ORIGINAL_COMMAND:-}
    set -- $cmd
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
        case "$keep" in *[!0-9]*) echo "bad keep: $keep" >&2; exit 2 ;; esac
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
}
