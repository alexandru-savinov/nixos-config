# Restricted backup-pull user for remote rsync access
#
# rpi5 connects as this user to pull backups via rsync.
# Access is locked down via:
#   - rrsync: read-only rsync restricted to /var/lib/openclaw
#   - SSH restrict: no port forwarding, no agent, no PTY
#   - nologin shell: no interactive access
#
# To enable backups:
#   1. ssh-keygen -t ed25519 -C "rpi5-backup" -f /tmp/rpi5-backup
#   2. agenix -e secrets/rpi5-backup-ssh-key.age  # paste private key
#   3. Set backupPubKey below to the .pub content
#   4. Rebuild sancta-claw

{ pkgs, lib, config, ... }:

let
  # Replace with the actual ed25519 public key after generation.
  # Leave empty until then — no invalid entries in authorized_keys.
  backupPubKey = "";
in
{
  users.users.backup-pull = {
    isSystemUser = true;
    group = "openclaw";
    home = "/var/empty";
    shell = "${pkgs.shadow}/bin/nologin";
    openssh.authorizedKeys.keys = lib.optionals (backupPubKey != "") [
      # restrict: disables port forwarding, agent forwarding, PTY, X11
      # command: forces rrsync read-only, limited to /var/lib/openclaw
      ''restrict,command="${pkgs.rrsync}/bin/rrsync -ro /var/lib/openclaw" ${backupPubKey}''
    ];
  };
}
