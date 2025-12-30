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

    extraEnvironment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = literalExpression ''
        {
          N8N_LOG_LEVEL = "info";
          N8N_METRICS = "true";
        }
      '';
      description = "Additional environment variables for n8n.";
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

      # n8n configuration via environment variables
      environment = mkMerge [
        {
          # Core settings
          N8N_PORT = toString cfg.port;
          N8N_USER_FOLDER = cfg.stateDir;

          # Privacy settings
          N8N_DIAGNOSTICS_ENABLED = "false";
          N8N_VERSION_NOTIFICATIONS_ENABLED = "false";

          # Security: disable public API by default (access via UI)
          N8N_PUBLIC_API_DISABLED = "true";
        }
        cfg.extraEnvironment
      ];
    };

    # Load encryption key from file at runtime
    systemd.services.n8n = mkIf (cfg.encryptionKeyFile != null) {
      preStart = ''
        SECRETS_FILE="/run/n8n/secrets.env"
        mkdir -p /run/n8n
        : > "$SECRETS_FILE"
        echo "N8N_ENCRYPTION_KEY=$(cat ${cfg.encryptionKeyFile})" >> "$SECRETS_FILE"
        chmod 600 "$SECRETS_FILE"
      '';

      serviceConfig = {
        RuntimeDirectory = "n8n";
        EnvironmentFile = "-/run/n8n/secrets.env";
      };
    };

    # Allow access only via Tailscale interface
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ cfg.port ];
  };
}
