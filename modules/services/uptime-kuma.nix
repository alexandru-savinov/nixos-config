{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.uptime-kuma-tailscale;
in
{
  options.services.uptime-kuma-tailscale = {
    enable = mkEnableOption "Uptime Kuma with Tailscale access";

    port = mkOption {
      type = types.port;
      default = 3001;
      description = "Port for Uptime Kuma to listen on.";
    };

    backup = {
      enable = mkEnableOption "automatic database backups" // {
        default = true;
      };

      schedule = mkOption {
        type = types.str;
        default = "daily";
        description = "Backup schedule (systemd timer format).";
      };

      retention = mkOption {
        type = types.int;
        default = 7;
        description = "Number of days to retain backups.";
      };
    };

    tailscaleServe = {
      enable = mkEnableOption "Tailscale Serve for HTTPS access";

      httpsPort = mkOption {
        type = types.port;
        default = 3001;
        description = "HTTPS port for Tailscale Serve to expose.";
      };
    };
  };

  config = mkIf cfg.enable {
    # Enable Uptime Kuma service using native NixOS module
    # Bind to localhost only - access is via Tailscale Serve (HTTPS)
    # Note: No firewall rule needed - service only accessible via localhost
    services.uptime-kuma = {
      enable = true;
      settings = {
        HOST = "127.0.0.1";
        PORT = toString cfg.port;
      };
    };

    # Automatic database backups
    systemd.services.uptime-kuma-backup = mkIf cfg.backup.enable {
      description = "Backup Uptime Kuma database";
      after = [ "uptime-kuma.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = "uptime-kuma";
        Group = "uptime-kuma";
        ExecStart = pkgs.writeShellScript "uptime-kuma-backup" ''
          set -euo pipefail
          
          BACKUP_DIR="/var/lib/uptime-kuma/backups"
          DB_FILE="/var/lib/uptime-kuma/kuma.db"
          TIMESTAMP=$(${pkgs.coreutils}/bin/date +%Y%m%d-%H%M%S)
          
          # Create backup directory if it doesn't exist
          ${pkgs.coreutils}/bin/mkdir -p "$BACKUP_DIR"
          
          # Backup database if it exists
          if [ -f "$DB_FILE" ]; then
            ${pkgs.sqlite}/bin/sqlite3 "$DB_FILE" ".backup '$BACKUP_DIR/kuma-$TIMESTAMP.db'"
            echo "Backup created: kuma-$TIMESTAMP.db"
            
            # Clean up old backups
            ${pkgs.findutils}/bin/find "$BACKUP_DIR" -name "kuma-*.db" -mtime +${toString cfg.backup.retention} -delete
            echo "Cleaned up backups older than ${toString cfg.backup.retention} days"
          else
            echo "Database file not found, skipping backup"
          fi
        '';
      };
    };

    systemd.timers.uptime-kuma-backup = mkIf cfg.backup.enable {
      description = "Timer for Uptime Kuma database backups";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.backup.schedule;
        Persistent = true;
      };
    };

    # Tailscale Serve configuration for HTTPS access
    systemd.services.tailscale-serve-uptime-kuma = mkIf cfg.tailscaleServe.enable {
      description = "Configure Tailscale Serve for Uptime Kuma HTTPS access";
      after = [
        "network-online.target"
        "tailscaled.service"
        "uptime-kuma.service"
      ];
      wants = [ "network-online.target" ];
      requires = [
        "tailscaled.service"
        "uptime-kuma.service"
      ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        # Wait for tailscaled to be ready (timeout: 60 seconds)
        timeout=60
        while ! ${pkgs.tailscale}/bin/tailscale status &>/dev/null; do
          timeout=$((timeout - 1))
          if [ $timeout -le 0 ]; then
            echo "ERROR: tailscaled not ready after 60 seconds"
            exit 1
          fi
          sleep 1
        done

        # Check if serve is already configured for this port
        if ! ${pkgs.tailscale}/bin/tailscale serve status 2>/dev/null | grep -q "https:${toString cfg.tailscaleServe.httpsPort}"; then
          echo "Configuring Tailscale Serve for Uptime Kuma..."
          ${pkgs.tailscale}/bin/tailscale serve --bg --https ${toString cfg.tailscaleServe.httpsPort} http://127.0.0.1:${toString cfg.port}
        else
          echo "Tailscale Serve already configured for Uptime Kuma"
        fi
      '';

      preStop = ''
        echo "Removing Tailscale Serve configuration for Uptime Kuma..."
        ${pkgs.tailscale}/bin/tailscale serve --bg --https ${toString cfg.tailscaleServe.httpsPort} off || true
      '';
    };

    # Access Uptime Kuma via Tailscale HTTPS (requires tailscaleServe.enable = true):
    #   https://<hostname>.<tailnet>.ts.net:3001
    # Service binds to localhost only for security - no direct network access possible
  };
}
