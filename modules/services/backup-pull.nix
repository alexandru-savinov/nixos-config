# Pull-based backup from remote host via rsync + restic
#
# Architecture: rpi5 pulls backups FROM sancta-claw (not push).
# sancta-claw doesn't need to know about rpi5 — better security.
#
# Flow:
#   1. rsync from remote host → tmpfs staging (unencrypted, ephemeral)
#   2. restic backup staging → local encrypted repository
#   3. restic forget --prune (retention policy)
#   4. cleanup staging
#
# Usage:
#   services.backup-pull = {
#     enable = true;
#     remoteHost = "sancta-claw";
#     remotePaths = [ "/var/lib/openclaw" ];
#     sshKeyFile = config.age.secrets.rpi5-backup-ssh-key.path;
#     resticPasswordFile = config.age.secrets.restic-password.path;
#   };

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.backup-pull;
in
{
  options.services.backup-pull = {
    enable = mkEnableOption "Pull-based backup from remote host";

    remoteHost = mkOption {
      type = types.str;
      description = "SSH host to pull from (Tailscale hostname or IP).";
    };

    remoteUser = mkOption {
      type = types.str;
      default = "backup-pull";
      description = "SSH user on remote host (should have rrsync read-only access).";
    };

    remotePaths = mkOption {
      type = types.listOf types.str;
      description = ''
        Paths to rsync from remote host. These are relative to the rrsync
        root on the remote (e.g. "/" means the rrsync-configured directory).
      '';
    };

    sshKeyFile = mkOption {
      type = types.path;
      description = "Path to SSH private key for remote access (from agenix).";
    };

    resticPasswordFile = mkOption {
      type = types.path;
      description = "Path to restic repository password file (from agenix).";
    };

    repository = mkOption {
      type = types.str;
      default = "/backups/restic/sancta-claw";
      description = "Local path for the restic repository.";
    };

    stagingDir = mkOption {
      type = types.str;
      default = "/backups/staging";
      description = "Tmpfs staging directory for unencrypted data.";
    };

    stagingSize = mkOption {
      type = types.str;
      default = "512M";
      description = "Size limit for the tmpfs staging mount.";
    };

    excludePatterns = mkOption {
      type = types.listOf types.str;
      default = [
        "sessions/"
        "*.log"
        ".cache/"
        "node_modules/"
      ];
      description = "Patterns to exclude from rsync.";
    };

    timerOnCalendar = mkOption {
      type = types.str;
      default = "*-*-* 03:00:00";
      description = "systemd OnCalendar expression for backup schedule.";
    };
  };

  config = mkIf cfg.enable {
    # Tmpfs staging — data never persists on rpi5 disk unencrypted
    fileSystems.${cfg.stagingDir} = {
      device = "tmpfs";
      fsType = "tmpfs";
      options = [ "size=${cfg.stagingSize}" "mode=0700" ];
    };

    # Ensure restic repo parent directory exists
    systemd.tmpfiles.rules = [
      "d ${dirOf cfg.repository} 0700 root root -"
    ];

    # Restic backup using NixOS built-in module
    services.restic.backups.sancta-claw = {
      initialize = true;
      repository = cfg.repository;
      passwordFile = cfg.resticPasswordFile;
      paths = [ cfg.stagingDir ];

      timerConfig = {
        OnCalendar = cfg.timerOnCalendar;
        Persistent = true;
        RandomizedDelaySec = "15min";
      };

      pruneOpts = [
        "--keep-daily 7"
        "--keep-weekly 4"
        "--keep-monthly 12"
        "--keep-yearly 1"
      ];

      # rsync pull before backup
      backupPrepareCommand = let
        excludeArgs = concatMapStringsSep " " (p: "--exclude='${p}'") cfg.excludePatterns;
        rsyncPaths = concatMapStringsSep " " (p: "${cfg.remoteUser}@${cfg.remoteHost}:${p}") cfg.remotePaths;
      in ''
        echo "=== Pulling backup from ${cfg.remoteHost} ==="
        ${pkgs.rsync}/bin/rsync -az --delete \
          -e "${pkgs.openssh}/bin/ssh -i ${cfg.sshKeyFile} -o StrictHostKeyChecking=accept-new -o BatchMode=yes" \
          ${excludeArgs} \
          ${rsyncPaths} \
          ${cfg.stagingDir}/
        echo "=== rsync complete, starting restic backup ==="
      '';

      # Clean staging after backup (success or failure)
      backupCleanupCommand = ''
        echo "=== Cleaning staging directory ==="
        rm -rf ${cfg.stagingDir}/*
      '';

      extraBackupArgs = [ "--exclude-caches" ];
    };

    # Weekly integrity check (Sunday 05:00)
    systemd.services.restic-check-sancta-claw = {
      description = "Restic repository integrity check (sancta-claw)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.restic}/bin/restic -r ${cfg.repository} --password-file ${cfg.resticPasswordFile} check";
        Nice = 19;
        IOSchedulingClass = "idle";
      };
    };

    systemd.timers.restic-check-sancta-claw = {
      description = "Weekly restic integrity check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "Sun *-*-* 05:00:00";
        Persistent = true;
        RandomizedDelaySec = "30min";
      };
    };

    # OnFailure alert — logs prominently for monitoring
    systemd.services.restic-backups-sancta-claw = {
      unitConfig.OnFailure = [ "backup-failure-alert@%n.service" ];
    };

    systemd.services."backup-failure-alert@" = {
      description = "Backup failure alert for %i";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "backup-alert" ''
          echo "BACKUP FAILURE: $1 failed at $(date -Iseconds)" | systemd-cat -t backup-alert -p err
        '';
      };
    };
  };
}
