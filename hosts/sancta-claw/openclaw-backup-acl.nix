{ pkgs, ... }:

{
  # ── Backup ACL: ensure backup-pull can read openclaw data ──────────────
  # tmpfiles 'a+' sets default ACL on the directory (new files inherit it),
  # but existing files need a one-time recursive fix on each activation.
  systemd.services.openclaw-backup-acl = {
    description = "Set group-read ACLs on openclaw home for backup-pull";
    after = [ "systemd-tmpfiles-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.acl}/bin/setfacl -R -m g:openclaw:rX -m d:g:openclaw:rX /var/lib/openclaw";
    };
  };
}
