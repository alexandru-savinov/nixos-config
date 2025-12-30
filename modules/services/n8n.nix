# n8n Workflow Automation with Tailscale Access
#
# This module wraps the native NixOS n8n service with:
# - Agenix secret management for N8N_ENCRYPTION_KEY
# - Tailscale-only network access (no public internet)
# - SQLite storage (default, no PostgreSQL setup needed)
# - Security hardening (execution pruning, env access blocking, concurrency limits)
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

    # ===================
    # Hardening Options
    # ===================

    executionsPrune = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Enable automatic pruning of old execution data.
          CRITICAL for SQLite: Without this, the database grows unbounded
          and will eventually fill up disk space.
        '';
      };

      maxAge = mkOption {
        type = types.int;
        default = 168;
        description = "Hours to keep execution data before pruning (default: 7 days).";
      };

      maxCount = mkOption {
        type = types.int;
        default = 1000;
        description = "Maximum number of executions to retain regardless of age.";
      };
    };

    blockEnvAccessInCode = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Prevent Code nodes from accessing environment variables.
        SECURITY: When enabled, process.env cannot be read from Code nodes,
        protecting secrets like N8N_ENCRYPTION_KEY from being exfiltrated.
      '';
    };

    concurrencyLimit = mkOption {
      type = types.int;
      default = 5;
      description = ''
        Maximum number of concurrent workflow executions.
        Set lower (e.g., 2) for resource-constrained hosts like Raspberry Pi.
        Set to -1 for unlimited (not recommended).
      '';
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

    # Configure systemd service with environment variables
    # Uses ExecStartPre with "+" prefix to run as root before DynamicUser kicks in
    systemd.services.n8n = {
      serviceConfig = {
        RuntimeDirectory = "n8n";
        RuntimeDirectoryMode = "0700";
        EnvironmentFile = "-/run/n8n/env";
        # Run setup as root (+ prefix), then main process as DynamicUser
        # The file is made world-readable briefly, but /run/n8n dir is 0700 (DynamicUser only)
        ExecStartPre = [
          ("+" + pkgs.writeShellScript "n8n-setup-env" ''
            ENV_FILE="/run/n8n/env"
            : > "$ENV_FILE"

            # Encryption key (if provided)
            ${optionalString (cfg.encryptionKeyFile != null) ''
              echo "N8N_ENCRYPTION_KEY=$(cat ${cfg.encryptionKeyFile})" >> "$ENV_FILE"
            ''}

            # Execution pruning settings
            echo "EXECUTIONS_DATA_PRUNE=${boolToString cfg.executionsPrune.enable}" >> "$ENV_FILE"
            echo "EXECUTIONS_DATA_MAX_AGE=${toString cfg.executionsPrune.maxAge}" >> "$ENV_FILE"
            echo "EXECUTIONS_DATA_PRUNE_MAX_COUNT=${toString cfg.executionsPrune.maxCount}" >> "$ENV_FILE"

            # Security: Block env access in Code nodes
            echo "N8N_BLOCK_ENV_ACCESS_IN_NODE=${boolToString cfg.blockEnvAccessInCode}" >> "$ENV_FILE"

            # Concurrency limit
            echo "N8N_CONCURRENCY_PRODUCTION_LIMIT=${toString cfg.concurrencyLimit}" >> "$ENV_FILE"

            # Make readable by DynamicUser (directory already restricts access)
            chmod 644 "$ENV_FILE"
          '')
        ];
      };
    };

    # Allow access only via Tailscale interface
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ cfg.port ];
  };
}
