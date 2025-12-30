# n8n Workflow Automation with Tailscale Access
#
# This module wraps the native NixOS n8n service with:
# - Agenix secret management for N8N_ENCRYPTION_KEY
# - Tailscale-only network access (no public internet)
# - SQLite storage (default, no PostgreSQL setup needed)
#
# Usage in host configuration:
#   services.n8n-tailscale = {
#     enable = true;
#     encryptionKeyFile = config.age.secrets.n8n-encryption-key.path;
#   };
#
# Access via Tailscale: http://<tailscale-ip>:5678 or http://<hostname>.tail<hex>.ts.net:5678

{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.n8n-tailscale;
in
{
  options.services.n8n-tailscale = {
    enable = mkEnableOption "n8n workflow automation with Tailscale access";

    port = mkOption {
      type = types.port;
      default = 5678;
      description = "Port for n8n web interface.";
    };

    encryptionKeyFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/run/secrets/n8n-encryption-key";
      description = ''
        Path to file containing N8N_ENCRYPTION_KEY.
        This key encrypts all credentials stored in n8n.
        Generate with: openssl rand -hex 32
        Use agenix for secret management.
        WARNING: If null, credentials will not be encrypted (insecure).
      '';
    };

    stateDir = mkOption {
      type = types.path;
      default = "/var/lib/n8n";
      description = "Directory for n8n data (SQLite database, files, etc).";
    };

    extraSettings = mkOption {
      type = types.attrs;
      default = { };
      example = literalExpression ''
        {
          log.level = "info";
          metrics.enable = true;
        }
      '';
      description = "Additional n8n settings (see n8n documentation).";
    };
  };

  config = mkIf cfg.enable {
    # Warn if no encryption key file is provided
    warnings = optional (cfg.encryptionKeyFile == null) ''
      services.n8n-tailscale.encryptionKeyFile is not set!
      All credentials stored in n8n will NOT be encrypted.
      This is INSECURE for production use.
      Generate a key: openssl rand -hex 32
      Store it with agenix.
    '';

    # Enable native n8n service
    services.n8n = {
      enable = true;
      openFirewall = false; # We manage firewall ourselves for Tailscale

      # n8n configuration via settings (maps to environment variables)
      # See: https://docs.n8n.io/hosting/environment-variables/
      # Note: userFolder is set via N8N_USER_FOLDER env var by native module
      settings = mkMerge [
        {
          # Core settings
          port = cfg.port;

          # Privacy settings
          diagnostics.enabled = false;
          versionNotifications.enabled = false;

          # Security: disable public API by default (access via UI)
          publicApi.disabled = true;
        }
        cfg.extraSettings
      ];
    };

    # Load encryption key from file at runtime
    # Uses ExecStartPre with "+" prefix to run as root before DynamicUser kicks in
    systemd.services.n8n = mkIf (cfg.encryptionKeyFile != null) {
      serviceConfig = {
        RuntimeDirectory = "n8n";
        RuntimeDirectoryMode = "0700";
        EnvironmentFile = "-/run/n8n/secrets.env";
        # Run secret setup as root (+ prefix), then main process as DynamicUser
        # The file is made world-readable briefly, but /run/n8n dir is 0700 (DynamicUser only)
        ExecStartPre = [
          ("+" + pkgs.writeShellScript "n8n-setup-secrets" ''
            SECRETS_FILE="/run/n8n/secrets.env"
            : > "$SECRETS_FILE"
            echo "N8N_ENCRYPTION_KEY=$(cat ${cfg.encryptionKeyFile})" >> "$SECRETS_FILE"
            # Make readable by DynamicUser (directory already restricts access)
            chmod 644 "$SECRETS_FILE"
          '')
        ];
      };
    };

    # Allow access only via Tailscale interface
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ cfg.port ];
  };
}
