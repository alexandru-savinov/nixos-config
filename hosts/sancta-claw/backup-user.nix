# Restricted backup-pull user for remote rsync access
#
# rpi5 connects as this user to pull backups via rsync.
# Access is locked down via:
#   - rrsync: read-only rsync restricted to /var/lib/openclaw
#   - SSH restrict: no port forwarding, no agent, no PTY
#   - nologin shell: no interactive access
#
# The SSH public key must be added after generating the keypair:
#   ssh-keygen -t ed25519 -C "rpi5-backup" -f /tmp/rpi5-backup
#   agenix -e secrets/rpi5-backup-ssh-key.age  # paste private key
#   # Then replace PUBKEY_PLACEHOLDER below with the .pub content

{ pkgs, lib, config, ... }:

{
  assertions = [{
    assertion = !lib.strings.hasInfix "PUBKEY_PLACEHOLDER"
      (builtins.concatStringsSep " " config.users.users.backup-pull.openssh.authorizedKeys.keys);
    message = "backup-user: replace PUBKEY_PLACEHOLDER in hosts/sancta-claw/backup-user.nix with actual ed25519 public key";
  }];

  users.users.backup-pull = {
    isSystemUser = true;
    group = "openclaw";
    home = "/var/empty";
    shell = "${pkgs.shadow}/bin/nologin";
    openssh.authorizedKeys.keys = [
      # restrict: disables port forwarding, agent forwarding, PTY, X11
      # command: forces rrsync read-only, limited to /var/lib/openclaw
      # PUBKEY_PLACEHOLDER: replace with actual ed25519 public key after generation
      ''restrict,command="${pkgs.rrsync}/bin/rrsync -ro /var/lib/openclaw" PUBKEY_PLACEHOLDER''
    ];
  };
}
