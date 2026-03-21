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

let
  inherit (lib) mkEnableOption mkOption mkIf types concatMapStringsSep escapeShellArg;
  cfg = config.services.backup-pull;
  # Derive service name from remote host (sanitized for systemd)
  backupName = builtins.replaceStrings [ "." ] [ "-" ] cfg.remoteHost;
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

    knownHostsEntry = mkOption {
      type = types.str;
      default = "";
      description = ''
        SSH known_hosts line for the remote host (e.g. "sancta-claw ssh-ed25519 AAAA...").
        When set, StrictHostKeyChecking=yes is used instead of accept-new.
        Get it with: ssh-keyscan -t ed25519 <host>
      '';
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

    telegramEnvFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Path to EnvironmentFile with TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID.
        When set, backup failure alerts are sent via Telegram.
        File format: KEY=value (one per line).
      '';
    };
  };

  config = mkIf cfg.enable {
    # Tmpfs staging — data never persists on rpi5 disk unencrypted
    fileSystems.${cfg.stagingDir} = {
      device = "tmpfs";
      fsType = "tmpfs";
      options = [ "size=${cfg.stagingSize}" "mode=0700" ];
    };

    # Pre-seed known_hosts for strict host key checking
    environment.etc."backup-pull/known_hosts" = mkIf (cfg.knownHostsEntry != "") {
      text = cfg.knownHostsEntry + "\n";
      mode = "0644";
    };

    # Ensure directories exist (staging dir created by fileSystems tmpfs mount)
    systemd.tmpfiles.rules = [
      "d /backups 0700 root root -"
      "d ${dirOf cfg.repository} 0700 root root -"
    ];

    # Restic backup using NixOS built-in module
    services.restic.backups.${backupName} = {
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
      backupPrepareCommand =
        let
          excludeArgs = concatMapStringsSep " " (p: "--exclude=${escapeShellArg p}") cfg.excludePatterns;
          rsyncPaths = concatMapStringsSep " " (p: escapeShellArg "${cfg.remoteUser}@${cfg.remoteHost}:${p}") cfg.remotePaths;
          sshHostKeyOpts =
            if cfg.knownHostsEntry != "" then
              "-o StrictHostKeyChecking=yes -o UserKnownHostsFile=/etc/backup-pull/known_hosts"
            else
              "-o StrictHostKeyChecking=accept-new";
        in
        ''
          set -euo pipefail
          echo "=== Pulling backup from ${cfg.remoteHost} ==="
          ${pkgs.rsync}/bin/rsync -az --delete \
            -e "${pkgs.openssh}/bin/ssh -i ${cfg.sshKeyFile} ${sshHostKeyOpts} -o BatchMode=yes" \
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
    systemd.services."restic-check-${backupName}" = {
      description = "Restic repository integrity check (${cfg.remoteHost})";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      unitConfig.OnFailure = [ "backup-failure-alert@%N.service" ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.restic}/bin/restic -r ${cfg.repository} --password-file ${cfg.resticPasswordFile} check";
        Nice = 19;
        IOSchedulingClass = "idle";
      };
    };

    systemd.timers."restic-check-${backupName}" = {
      description = "Weekly restic integrity check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "Sun *-*-* 05:00:00";
        Persistent = true;
        RandomizedDelaySec = "30min";
      };
    };

    # OnFailure alert — logs + Telegram notification
    systemd.services."restic-backups-${backupName}" = {
      unitConfig = {
        OnFailure = [ "backup-failure-alert@%N.service" ];
        RequiresMountsFor = [ cfg.stagingDir ];
      };
    };


    systemd.services."backup-failure-alert@" = {
      description = "Backup failure alert for %i";
      serviceConfig = {
        Type = "oneshot";
        ExecStart =
          let
            telegramCmd =
              if cfg.telegramEnvFile != null then
                ''
                  ${pkgs.curl}/bin/curl -sf -X POST \
                    "https://api.telegram.org/bot''${TELEGRAM_BOT_TOKEN}/sendMessage" \
                    -H "Content-Type: application/json" \
                    -d "{\"chat_id\":\"''${TELEGRAM_CHAT_ID}\",\"text\":\"$msg\"}" \
                    || echo "WARNING: Telegram notification failed"
                ''
              else
                "";
          in
          "${pkgs.bash}/bin/bash -c ${lib.escapeShellArg ''
            msg="❌ BACKUP FAILURE: %i failed at $(date -Iseconds) on $(hostname)"
            echo "$msg" | ${pkgs.systemd}/bin/systemd-cat -t backup-alert -p err
            ${telegramCmd}
          ''}";
        EnvironmentFile = lib.mkIf (cfg.telegramEnvFile != null) cfg.telegramEnvFile;
      };
    };
  };
}
