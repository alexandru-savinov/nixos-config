# Declarative restore script for sancta-claw disaster recovery
#
# Restores OpenClaw workspace from the latest restic backup on rpi5.
# The script SSHs to rpi5, runs restic restore, and rsyncs files back.
#
# Usage:
#   sudo /etc/sancta-claw/restore.sh [rpi5-hostname]
#
# Prerequisites:
#   - SSH access from sancta-claw root to rpi5
#   - restic repo exists on rpi5 at /backups/restic/sancta-claw
#   - restic password file at /run/agenix/restic-password on rpi5

{ pkgs, ... }:

let
  restoreScript = pkgs.writeShellApplication {
    name = "sancta-claw-restore";
    runtimeInputs = with pkgs; [ openssh rsync coreutils ];
    excludeShellChecks = [ "SC2029" ]; # Variables intentionally expand locally for SSH
    text = ''
      set -euo pipefail

      RPI5="''${1:-rpi5}"

      echo "=== sancta-claw disaster recovery ==="
      echo "Restoring from latest backup on $RPI5..."
      echo ""

      # Verify SSH connectivity to rpi5.
      # On a fresh VPS (DR scenario), the new SSH host key is unknown to rpi5.
      # Use SSH agent forwarding to authenticate: ssh -A root@NEW_IP /etc/sancta-claw/restore.sh rpi5
      # Or run the restore from rpi5 in push mode (see DISASTER-RECOVERY.md).
      if ! ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "root@$RPI5" true 2>/dev/null; then
        echo "ERROR: Cannot SSH to root@$RPI5"
        echo ""
        echo "On a fresh VPS, the SSH key is not authorized on rpi5."
        echo "Options:"
        echo "  1. Use SSH agent forwarding: ssh -A root@THIS_VPS /etc/sancta-claw/restore.sh $RPI5"
        echo "  2. Run restore from rpi5 in push mode (see docs/DISASTER-RECOVERY.md)"
        echo "  3. Ensure Tailscale is connected and SSH keys are configured"
        exit 1
      fi

      # Create temp restore dir on rpi5
      REMOTE_RESTORE_DIR=$(ssh "root@$RPI5" mktemp -d /tmp/restore-XXXXXX)
      [[ -n "$REMOTE_RESTORE_DIR" ]] || { echo "ERROR: failed to create remote temp dir"; exit 1; }
      [[ "$REMOTE_RESTORE_DIR" =~ ^/tmp/restore-[A-Za-z0-9]+$ ]] || { echo "ERROR: unexpected path format: $REMOTE_RESTORE_DIR"; exit 1; }
      echo "Remote restore dir: $REMOTE_RESTORE_DIR"

      # Restore latest snapshot on rpi5
      echo "Running restic restore on $RPI5..."
      ssh "root@$RPI5" "restic -r /backups/restic/sancta-claw \
        --password-file /run/agenix/restic-password \
        restore latest --target \"$REMOTE_RESTORE_DIR\""

      # Verify restore produced non-empty data before syncing
      RESTORE_SRC="$REMOTE_RESTORE_DIR/backups/staging"
      FILE_COUNT=$(ssh "root@$RPI5" "find '$RESTORE_SRC' -type f 2>/dev/null | wc -l")
      if [ "$FILE_COUNT" -lt 1 ]; then
        echo "ERROR: restore source is empty or missing ($FILE_COUNT files in $RESTORE_SRC)"
        echo "Aborting to prevent data loss from rsync --delete on empty source."
        ssh "root@$RPI5" "rm -rf $REMOTE_RESTORE_DIR"
        exit 1
      fi
      echo "Found $FILE_COUNT files in restore source."

      # Rsync restored files back to sancta-claw
      echo "Syncing restored files to /var/lib/openclaw/..."
      rsync -az --delete \
        "root@$RPI5:$REMOTE_RESTORE_DIR/backups/staging/" \
        /var/lib/openclaw/

      # Clean up remote temp dir
      ssh "root@$RPI5" "rm -rf $REMOTE_RESTORE_DIR"

      # Fix ownership
      chown -R openclaw:openclaw /var/lib/openclaw/

      echo ""
      echo "=== Restore complete ==="
      echo "Run: systemctl restart openclaw"
      echo "Then: /etc/sancta-claw/smoke-test.sh"
    '';
  };
in
{
  environment.etc."sancta-claw/restore.sh" = {
    source = "${restoreScript}/bin/sancta-claw-restore";
    mode = "0755";
  };
}
