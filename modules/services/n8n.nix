# n8n Workflow Automation with Tailscale Access
#
# This module wraps the native NixOS n8n service with:
# - Agenix secret management for N8N_ENCRYPTION_KEY
# - Tailscale-only network access (no public internet)
# - SQLite storage (default, no PostgreSQL setup needed)
# - Security hardening (execution pruning, env access blocking, concurrency limits)
# - HTTPS via Tailscale Serve (automatic TLS certificates)
#
# Usage in host configuration:
#   services.n8n-tailscale = {
#     enable = true;
#     encryptionKeyFile = config.age.secrets.n8n-encryption-key.path;
#     tailscaleServe.enable = true;
#   };
#
# Access via Tailscale HTTPS: https://<hostname>.tail<hex>.ts.net:5678

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

    # ===================
    # Declarative Config Options
    # ===================

    credentialsFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = literalExpression "config.age.secrets.n8n-credentials.path";
      description = ''
        Path to JSON file containing n8n credential overwrites.
        The file is copied to /run/n8n/credentials.json at startup.

        Format: { "credentialType": { "field": "value", ... }, ... }

        Common credential types:
          - httpHeaderAuth: { "name": "Header-Name", "value": "header-value" }
          - httpBasicAuth: { "user": "...", "password": "..." }
          - oAuth2Api: { "clientId": "...", "clientSecret": "..." }
          - slackApi: { "accessToken": "xoxb-..." }
          - telegramApi: { "accessToken": "123:ABC..." }

        SECURITY: Use agenix, NOT a file in the Nix store!
          credentialsFile = config.age.secrets.n8n-credentials.path;
      '';
    };

    workflows = mkOption {
      type = types.listOf types.path;
      default = [ ];
      example = literalExpression "[ ./workflows/backup.json ]";
      description = ''
        List of workflow JSON files to import on service startup.

        IMPORTANT: Each workflow JSON MUST have a stable "id" field!
        Without an ID, n8n generates a random one, causing duplicates on re-import.

        Workflows are imported as-is, including their "active" state.
        Set "active": true in JSON for scheduled/webhook workflows to run.

        Export from n8n UI: Menu → Download workflow.
      '';
    };

    workflowsDir = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = literalExpression "../../n8n-workflows";
      description = ''
        Directory containing workflow JSON files (*.json) to import.
        All JSON files in this directory are imported on startup.

        Same requirements as 'workflows': each file must have stable "id" field.
      '';
    };

    extraEnvironment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = literalExpression ''{ N8N_TEMPLATES_ENABLED = "false"; }'';
      description = ''
        Additional environment variables for n8n.
        Useful for enabling features not covered by this module.

        Example: Enable public API for external integrations:
          extraEnvironment.N8N_PUBLIC_API_DISABLED = "false";
      '';
    };

    tailscaleServe = {
      enable = mkEnableOption "Tailscale Serve for HTTPS access";

      httpsPort = mkOption {
        type = types.port;
        default = 5678;
        description = "HTTPS port for Tailscale Serve to expose.";
      };
    };
  };

  config = mkIf cfg.enable {
    # Security assertion: prevent credentials in Nix store (world-readable!)
    assertions = [
      {
        assertion = cfg.credentialsFile == null ||
          !(hasPrefix "/nix/store" (toString cfg.credentialsFile));
        message = ''
          services.n8n-tailscale.credentialsFile points to the Nix store!
          Files in /nix/store are WORLD-READABLE. Your credentials would be exposed.

          Use agenix instead:
            age.secrets.n8n-credentials.file = ./secrets/n8n-credentials.age;
            services.n8n-tailscale.credentialsFile = config.age.secrets.n8n-credentials.path;
        '';
      }
    ];

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
    };

    # Configure systemd service with environment variables
    # Uses ExecStartPre with "+" prefix to run as root before DynamicUser kicks in
    systemd.services.n8n = {
      serviceConfig = {
        RuntimeDirectory = "n8n";
        RuntimeDirectoryMode = "0700";
        # Dash prefix: don't fail if file missing (allows service to start during initial setup)
        # ExecStartPre with set -euo pipefail ensures file is created with proper error handling
        EnvironmentFile = "-/run/n8n/env";
        # Run setup as root (+ prefix), then main process as DynamicUser
        # The file is made world-readable briefly, but /run/n8n dir is 0700 (DynamicUser only)
        ExecStartPre = [
          ("+" + pkgs.writeShellScript "n8n-setup-env" ''
            set -euo pipefail

            ENV_FILE="/run/n8n/env"
            : > "$ENV_FILE"

            # Port configuration
            echo "N8N_PORT=${toString cfg.port}" >> "$ENV_FILE"

            # Bind to localhost only - access is via Tailscale Serve (HTTPS)
            echo "N8N_LISTEN_ADDRESS=127.0.0.1" >> "$ENV_FILE"

            # Privacy settings
            echo "N8N_DIAGNOSTICS_ENABLED=false" >> "$ENV_FILE"
            echo "N8N_VERSION_NOTIFICATIONS_ENABLED=false" >> "$ENV_FILE"

            # Security: disable public API by default (access via UI)
            echo "N8N_PUBLIC_API_DISABLED=true" >> "$ENV_FILE"

            # Encryption key (if provided)
            ${optionalString (cfg.encryptionKeyFile != null) ''
              if [[ ! -f "${cfg.encryptionKeyFile}" ]]; then
                echo "ERROR: Encryption key file not found: ${cfg.encryptionKeyFile}" >&2
                exit 1
              fi
              ENCRYPTION_KEY=$(cat "${cfg.encryptionKeyFile}")
              if [[ -z "$ENCRYPTION_KEY" ]]; then
                echo "ERROR: Encryption key file is empty: ${cfg.encryptionKeyFile}" >&2
                exit 1
              fi
              echo "N8N_ENCRYPTION_KEY=$ENCRYPTION_KEY" >> "$ENV_FILE"
            ''}

            # Credentials file (if provided)
            ${optionalString (cfg.credentialsFile != null) ''
              if [[ ! -f "${cfg.credentialsFile}" ]]; then
                echo "ERROR: Credentials file not found: ${cfg.credentialsFile}" >&2
                exit 1
              fi
              # Validate JSON syntax before copying (fail fast)
              if ! ${pkgs.jq}/bin/jq empty "${cfg.credentialsFile}" 2>/dev/null; then
                echo "ERROR: Credentials file is not valid JSON: ${cfg.credentialsFile}" >&2
                exit 1
              fi
              # Copy to runtime dir - chmod 644 is safe because dir is 0700
              cp "${cfg.credentialsFile}" /run/n8n/credentials.json
              chmod 644 /run/n8n/credentials.json
              echo "CREDENTIALS_OVERWRITE_DATA_FILE=/run/n8n/credentials.json" >> "$ENV_FILE"
              echo "Credentials file configured: /run/n8n/credentials.json"
            ''}

            # Execution pruning settings
            echo "EXECUTIONS_DATA_PRUNE=${boolToString cfg.executionsPrune.enable}" >> "$ENV_FILE"
            echo "EXECUTIONS_DATA_MAX_AGE=${toString cfg.executionsPrune.maxAge}" >> "$ENV_FILE"
            echo "EXECUTIONS_DATA_PRUNE_MAX_COUNT=${toString cfg.executionsPrune.maxCount}" >> "$ENV_FILE"

            # Security: Block env access in Code nodes
            echo "N8N_BLOCK_ENV_ACCESS_IN_NODE=${boolToString cfg.blockEnvAccessInCode}" >> "$ENV_FILE"

            # Concurrency limit
            echo "N8N_CONCURRENCY_PRODUCTION_LIMIT=${toString cfg.concurrencyLimit}" >> "$ENV_FILE"

            # Extra environment variables (values escaped to prevent shell injection)
            ${concatStringsSep "\n" (mapAttrsToList (name: value: ''
              echo "${name}=${escapeShellArg value}" >> "$ENV_FILE"
            '') cfg.extraEnvironment)}

            # Make readable only by DynamicUser (600 + dir 0700 = secure)
            chmod 600 "$ENV_FILE"
          '')
        ];
      };
    };

    # Separate service for workflow import and active state sync
    # This fixes issue #99: SQLite sync was running as root instead of n8n user
    # Uses DynamicUser for least-privilege; StateDirectory ensures proper ownership
    systemd.services.n8n-workflow-sync = mkIf (cfg.workflows != [ ] || cfg.workflowsDir != null) {
      description = "Import n8n workflows and sync active states";
      after = [ "n8n.service" ];
      requires = [ "n8n.service" ];
      wantedBy = [ "multi-user.target" ];

      # DynamicUser drops root privileges; systemd chowns StateDirectory on service start
      # Note: This is a oneshot that runs after n8n, so no concurrent access issues
      serviceConfig = {
        Type = "oneshot";
        DynamicUser = true;
        StateDirectory = "n8n";
        # Need read access to workflow JSON files in Nix store
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        # Use same environment file as main n8n service for encryption key
        EnvironmentFile = "-/run/n8n/env";
      };

      # n8n needs N8N_USER_FOLDER to know where config/database is stored
      # Without this, it defaults to $HOME/.n8n which fails with DynamicUser
      environment = {
        N8N_USER_FOLDER = "/var/lib/n8n/.n8n";
      };

      path = [ pkgs.curl pkgs.jq pkgs.sqlite pkgs.n8n ];

      script = ''
        set -euo pipefail

        # Wait for n8n to be FULLY ready (not just port open)
        echo "Waiting for n8n to be ready..."
        timeout=120
        while ! curl -sf http://127.0.0.1:${toString cfg.port}/healthz >/dev/null 2>&1; do
          # Fallback: also accept 200 from root path
          if curl -sf http://127.0.0.1:${toString cfg.port}/ >/dev/null 2>&1; then
            break
          fi
          timeout=$((timeout - 1))
          if [ $timeout -le 0 ]; then
            echo "ERROR: n8n not ready after 120 seconds, cannot import workflows" >&2
            echo "  Check: systemctl status n8n / journalctl -u n8n" >&2
            exit 1
          fi
          sleep 1
        done

        # Brief delay for database initialization
        sleep 2

        echo "Importing declarative workflows..."
        import_failed=0

        # Import individual workflow files
        ${concatMapStringsSep "\n" (wf: ''
          echo "Importing: ${wf}"
          if ! import_output=$(n8n import:workflow --input="${wf}" 2>&1); then
            echo "ERROR: Failed to import ${wf}" >&2
            echo "  n8n output: $import_output" >&2
            import_failed=1
          fi
        '') cfg.workflows}

        # Import all workflows from directory
        ${optionalString (cfg.workflowsDir != null) ''
          for wf in ${cfg.workflowsDir}/*.json; do
            if [ -f "$wf" ]; then
              echo "Importing: $wf"
              if ! import_output=$(n8n import:workflow --input="$wf" 2>&1); then
                echo "ERROR: Failed to import $wf" >&2
                echo "  n8n output: $import_output" >&2
                import_failed=1
              fi
            fi
          done
        ''}

        if [ "$import_failed" -eq 1 ]; then
          echo "ERROR: One or more workflow imports failed" >&2
          exit 1
        fi

        echo "Workflow import complete: all workflows imported successfully"

        # Sync active state from JSON files to database
        # n8n import doesn't update active state of existing workflows
        echo "Syncing workflow active states..."
        DB_PATH="/var/lib/n8n/.n8n/database.sqlite"

        sync_active_state() {
          local wf_file="$1"
          local wf_id wf_active

          # Extract id and active from JSON
          wf_id=$(jq -r '.id // empty' "$wf_file")
          wf_active=$(jq -r '.active // false' "$wf_file")

          if [ -z "$wf_id" ]; then
            echo "  WARNING: No id in $wf_file, skipping active sync"
            return
          fi

          # Convert JSON boolean to SQLite integer
          if [ "$wf_active" = "true" ]; then
            active_int=1
          else
            active_int=0
          fi

          # Update database (runs as DynamicUser, not root)
          sqlite3 "$DB_PATH" \
            "UPDATE workflow_entity SET active=$active_int WHERE id='$wf_id';"
          echo "  Set $wf_id active=$wf_active"
        }

        # Sync individual workflow files
        ${concatMapStringsSep "\n" (wf: ''
          sync_active_state "${wf}"
        '') cfg.workflows}

        # Sync all workflows from directory
        ${optionalString (cfg.workflowsDir != null) ''
          for wf in ${cfg.workflowsDir}/*.json; do
            if [ -f "$wf" ]; then
              sync_active_state "$wf"
            fi
          done
        ''}

        echo "Workflow active state sync complete"
      '';
    };

    # Tailscale Serve configuration for HTTPS access
    systemd.services.tailscale-serve-n8n = mkIf cfg.tailscaleServe.enable {
      description = "Configure Tailscale Serve for n8n HTTPS access";
      after = [
        "network-online.target"
        "tailscaled.service"
        "n8n.service"
      ];
      wants = [ "network-online.target" ];
      requires = [
        "tailscaled.service"
        "n8n.service"
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

        # Wait for n8n to be listening (timeout: 60 seconds)
        # The 'after' directive only waits for service start, not port availability
        timeout=60
        while ! ${pkgs.netcat}/bin/nc -z 127.0.0.1 ${toString cfg.port} 2>/dev/null; do
          timeout=$((timeout - 1))
          if [ $timeout -le 0 ]; then
            echo "ERROR: n8n not listening on port ${toString cfg.port} after 60 seconds"
            exit 1
          fi
          sleep 1
        done

        # Check if serve is already configured for this port
        if ! ${pkgs.tailscale}/bin/tailscale serve status 2>/dev/null | grep -q "https:${toString cfg.tailscaleServe.httpsPort}"; then
          echo "Configuring Tailscale Serve for n8n..."
          ${pkgs.tailscale}/bin/tailscale serve --bg --https ${toString cfg.tailscaleServe.httpsPort} http://127.0.0.1:${toString cfg.port}
        else
          echo "Tailscale Serve already configured for n8n"
        fi
      '';

      preStop = ''
        echo "Removing Tailscale Serve configuration for n8n..."
        ${pkgs.tailscale}/bin/tailscale serve --bg --https ${toString cfg.tailscaleServe.httpsPort} off || true
      '';
    };

    # Access n8n via Tailscale HTTPS (requires tailscaleServe.enable = true):
    #   https://<hostname>.<tailnet>.ts.net:5678
    # Service binds to localhost only for security - no direct network access possible
  };
}
