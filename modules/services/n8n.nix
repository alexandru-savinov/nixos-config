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

{ config, pkgs, lib, self, ... }:

with lib;

let
  cfg = config.services.n8n-tailscale;

  # Python environment with genanki for APKG generation
  # Used by image-to-anki workflow to create Anki deck files
  pythonWithGenanki = pkgs.python3.withPackages (ps: [
    ps.genanki
  ]);

  # APKG generator script for n8n workflows
  # Uses self from flake to reference the script file
  generateApkgScript = pkgs.writeScriptBin "generate-apkg" ''
    #!${pythonWithGenanki}/bin/python3
    ${builtins.readFile "${self}/scripts/generate-apkg.py"}
  '';
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

    openrouterApiKeyFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = literalExpression "config.age.secrets.openrouter-api-key.path";
      description = ''
        Path to file containing OpenRouter API key.
        This is injected as OPENROUTER_API_KEY environment variable.

        Workflows can reference it using the expression:
          Bearer {{ $env.OPENROUTER_API_KEY }}

        Use agenix for secret management:
          openrouterApiKeyFile = config.age.secrets.openrouter-api-key.path;
      '';
    };

    adminPasswordFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = literalExpression "config.age.secrets.n8n-admin-password.path";
      description = ''
        Path to file containing the n8n admin user password.
        Required for declarative community package installation via REST API.

        The admin user (admin@localhost.com) password is set on each service start.
        This enables the n8n-community-packages service to authenticate and
        install packages programmatically.

        Use agenix for secret management:
          adminPasswordFile = config.age.secrets.n8n-admin-password.path;
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

    webhookHealthCheck = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "image-to-anki-ui";
      description = ''
        Webhook path to verify after workflow sync completes.

        n8n reports workflows as "activated" before webhooks are actually
        registered internally. This causes 404 errors if webhooks are hit
        immediately after n8n starts.

        Set this to a known webhook path (without /webhook/ prefix) to wait
        until that webhook responds before considering workflow sync complete.
        The health check polls the webhook with GET requests until it returns
        a non-404 response or times out after 60 seconds.
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

    communityPackages = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "n8n-nodes-zip" "@n8n/n8n-nodes-langchain" ];
      description = ''
        List of n8n community packages to install from npm.
        These are installed on service start and available to workflows.

        Common packages:
          - n8n-nodes-zip: ZIP file creation/extraction
          - n8n-nodes-convert-image: Image format conversion

        Note: Packages are installed via npm in /var/lib/n8n/.n8n/nodes/

        LIMITATION: n8n 1.x expects packages installed via its internal
        package manager. Declaratively installed packages may trigger
        "missing packages" warnings. For best results, install community
        packages via n8n UI (Settings > Community nodes).
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
    # Create static n8n user and group for consistent file ownership
    # This prevents SQLite database lock conflicts between n8n and n8n-workflow-sync services
    users.users.n8n = {
      isSystemUser = true;
      group = "n8n";
      description = "n8n workflow automation service user";
      home = "/var/lib/n8n";
      # Note: Don't use createHome - StateDirectory handles directory creation
    };

    users.groups.n8n = { };

    # Security assertions: prevent secrets in Nix store (world-readable!)
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
      {
        assertion = cfg.openrouterApiKeyFile == null ||
          !(hasPrefix "/nix/store" (toString cfg.openrouterApiKeyFile));
        message = ''
          services.n8n-tailscale.openrouterApiKeyFile points to the Nix store!
          Files in /nix/store are WORLD-READABLE. Your API key would be exposed.

          Use agenix instead:
            age.secrets.openrouter-api-key.file = ./secrets/openrouter-api-key.age;
            services.n8n-tailscale.openrouterApiKeyFile = config.age.secrets.openrouter-api-key.path;
        '';
      }
      {
        assertion = cfg.adminPasswordFile == null ||
          !(hasPrefix "/nix/store" (toString cfg.adminPasswordFile));
        message = ''
          services.n8n-tailscale.adminPasswordFile points to the Nix store!
          Files in /nix/store are WORLD-READABLE. Your admin password would be exposed.

          Use agenix instead:
            age.secrets.n8n-admin-password.file = ./secrets/n8n-admin-password.age;
            services.n8n-tailscale.adminPasswordFile = config.age.secrets.n8n-admin-password.path;
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
    # Uses ExecStartPre with "+" prefix to run as root for secret file setup
    systemd.services.n8n = {
      serviceConfig = {
        # Use static n8n user instead of DynamicUser to ensure consistent file ownership
        # This prevents SQLite database lock conflicts with n8n-workflow-sync service
        DynamicUser = mkForce false; # Explicitly disable to ensure User/Group take effect
        User = "n8n";
        Group = "n8n";
        StateDirectory = "n8n";
        RuntimeDirectory = "n8n";
        RuntimeDirectoryMode = "0700";
        # Dash prefix: don't fail if file missing (allows service to start during initial setup)
        # ExecStartPre with set -euo pipefail ensures file is created with proper error handling
        EnvironmentFile = "-/run/n8n/env";
        # Run setup as root (+ prefix) for reading secrets, then main process as n8n user
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

                        # OpenRouter API key (if provided)
                        ${optionalString (cfg.openrouterApiKeyFile != null) ''
                          if [[ ! -f "${cfg.openrouterApiKeyFile}" ]]; then
                            echo "ERROR: OpenRouter API key file not found: ${cfg.openrouterApiKeyFile}" >&2
                            exit 1
                          fi
                          OPENROUTER_KEY=$(cat "${cfg.openrouterApiKeyFile}")
                          if [[ -z "$OPENROUTER_KEY" ]]; then
                            echo "ERROR: OpenRouter API key file is empty: ${cfg.openrouterApiKeyFile}" >&2
                            exit 1
                          fi
                          echo "OPENROUTER_API_KEY=$OPENROUTER_KEY" >> "$ENV_FILE"
                          echo "OpenRouter API key configured for workflow expressions"
                        ''}

                        # Admin password (if provided) - for REST API authentication
                        ${optionalString (cfg.adminPasswordFile != null) ''
                          if [[ ! -f "${cfg.adminPasswordFile}" ]]; then
                            echo "ERROR: Admin password file not found: ${cfg.adminPasswordFile}" >&2
                            exit 1
                          fi
                          ADMIN_PASSWORD=$(cat "${cfg.adminPasswordFile}")
                          if [[ -z "$ADMIN_PASSWORD" ]]; then
                            echo "ERROR: Admin password file is empty: ${cfg.adminPasswordFile}" >&2
                            exit 1
                          fi

                          # Generate bcrypt hash using python
                          ADMIN_HASH=$(${pkgs.python3.withPackages (ps: [ps.bcrypt])}/bin/python3 -c "
            import bcrypt
            import sys
            password = sys.stdin.read().strip().encode()
            hash = bcrypt.hashpw(password, bcrypt.gensalt(10))
            print(hash.decode())
            " <<< "$ADMIN_PASSWORD")

                          # Update admin user password in database (create user if not exists)
                          DB_PATH="/var/lib/n8n/.n8n/database.sqlite"
                          if [[ -f "$DB_PATH" ]]; then
                            # Check if admin user exists
                            ADMIN_EXISTS=$(${pkgs.sqlite}/bin/sqlite3 "$DB_PATH" \
                              "SELECT COUNT(*) FROM user WHERE email='admin@localhost.com';")

                            if [[ "$ADMIN_EXISTS" -eq 0 ]]; then
                              # Create admin user with generated UUID
                              ADMIN_ID=$(${pkgs.util-linux}/bin/uuidgen)
                              ${pkgs.sqlite}/bin/sqlite3 "$DB_PATH" "
                                INSERT INTO user (id, email, firstName, lastName, password, role, disabled, createdAt, updatedAt)
                                VALUES ('$ADMIN_ID', 'admin@localhost.com', 'Admin', 'User', '$ADMIN_HASH', 'global:owner', 0, datetime('now'), datetime('now'));
                              "
                              echo "Created admin user: admin@localhost.com"
                            else
                              # Update existing admin password
                              ${pkgs.sqlite}/bin/sqlite3 "$DB_PATH" \
                                "UPDATE user SET password='$ADMIN_HASH', updatedAt=datetime('now') WHERE email='admin@localhost.com';"
                              echo "Updated admin user password"
                            fi
                          else
                            echo "Database not yet created, admin password will be set on first n8n run"
                          fi
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

                        # Community packages - enable support (actual installation via REST API service)
                        ${optionalString (cfg.communityPackages != []) ''
                          echo "N8N_COMMUNITY_PACKAGES_ENABLED=true" >> "$ENV_FILE"

                          # Create nodes directory for community packages
                          NODES_DIR="/var/lib/n8n/.n8n/nodes"
                          mkdir -p "$NODES_DIR"
                          chown n8n:n8n "$NODES_DIR"
                        ''}

                        # Fix npm cache ownership (ExecStartPre runs as root, but n8n needs write access)
                        if [[ -d "/var/lib/n8n/.npm" ]]; then
                          chown -R n8n:n8n /var/lib/n8n/.npm
                        fi

                        # Create APKG output directory for generate-apkg script used by image-to-anki workflow
                        # Uses /var/lib/n8n (StateDirectory) for persistence and security (no shared /tmp)
                        APKG_DIR="/var/lib/n8n/anki-decks"
                        mkdir -p "$APKG_DIR"
                        if ! chown n8n:n8n "$APKG_DIR"; then
                          echo "ERROR: Failed to set ownership of $APKG_DIR to n8n:n8n" >&2
                          exit 1
                        fi
                        echo "APKG output directory configured: $APKG_DIR"

                        # Make readable only by n8n user (600 + dir 0700 = secure)
                        chmod 600 "$ENV_FILE"
          '')
        ];
      };

      # Add nodejs and utilities to PATH for n8n's internal community package installer
      # n8n's package installer calls: npm pack, tar -xzf, and shell utilities
      # Also includes generate-apkg script for APKG deck generation in workflows
      path = [ pkgs.nodejs pkgs.gnutar pkgs.gzip pkgs.coreutils pkgs.bash generateApkgScript ];
    };

    # Separate service for workflow import and active state sync
    # CRITICAL: Must use same static user as main n8n service to avoid SQLite lock conflicts
    # Using DynamicUser here creates a different temporary UID, causing database permission errors
    # See issue #127 for detailed problem description
    systemd.services.n8n-workflow-sync = mkIf (cfg.workflows != [ ] || cfg.workflowsDir != null) {
      description = "Import n8n workflows and sync active states";
      after = [ "n8n.service" ];
      requires = [ "n8n.service" ];
      wantedBy = [ "multi-user.target" ];

      # Use static n8n user matching main service to prevent database ownership conflicts
      # StateDirectory creates /var/lib/n8n with n8n:n8n ownership on first run
      serviceConfig = {
        Type = "oneshot";
        User = "n8n";
        Group = "n8n";
        StateDirectory = "n8n";
        # Need read access to workflow JSON files in Nix store
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        # Use same environment file as main n8n service for encryption key
        EnvironmentFile = "-/run/n8n/env";
      };

      # n8n needs N8N_USER_FOLDER to know where config/database is stored
      # Without this, it defaults to $HOME/.n8n which may not be writable
      # Note: n8n creates .n8n subdirectory inside N8N_USER_FOLDER
      environment = {
        N8N_USER_FOLDER = "/var/lib/n8n";
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

          # Update database (runs as n8n user, not root)
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

        ${optionalString (cfg.webhookHealthCheck != null) ''
          # Verify webhooks are actually registered (not just "activated")
          # n8n logs "Activated workflow" before webhooks are ready to receive requests
          echo "Verifying webhook registration for: ${cfg.webhookHealthCheck}"
          webhook_timeout=60
          webhook_ready=0
          while [ $webhook_timeout -gt 0 ]; do
            http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
              "http://127.0.0.1:${toString cfg.port}/webhook/${cfg.webhookHealthCheck}" 2>/dev/null || echo "000")
            # Any response except 404 means webhook is registered
            # (200=success, 405=wrong method, 500=error, but NOT 404=not found)
            if [ "$http_code" != "404" ] && [ "$http_code" != "000" ]; then
              echo "Webhook health check passed (HTTP $http_code) after $((60 - webhook_timeout))s"
              webhook_ready=1
              break
            fi
            webhook_timeout=$((webhook_timeout - 1))
            sleep 1
          done

          if [ $webhook_ready -eq 0 ]; then
            echo "WARNING: Webhook ${cfg.webhookHealthCheck} not ready after 60s (still returning 404)"
            echo "  Webhooks may not be registered yet. Check: journalctl -u n8n"
            # Don't fail - webhook might be legitimately disabled or have different path
          fi
        ''}
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
      # PartOf ensures this service restarts when n8n restarts
      # Without this, Requires= only stops this service but doesn't restart it
      partOf = [ "n8n.service" ];

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

    # Community packages installation via REST API
    # Requires adminPasswordFile to authenticate with n8n
    systemd.services.n8n-community-packages = mkIf (cfg.communityPackages != [ ] && cfg.adminPasswordFile != null) {
      description = "Install n8n community packages via REST API";
      after = [ "n8n.service" ];
      requires = [ "n8n.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Run as root to read password file and restart n8n
      };

      path = [ pkgs.curl pkgs.jq ];

      script = ''
        set -euo pipefail

        N8N_URL="http://127.0.0.1:${toString cfg.port}"
        COOKIE_JAR="/tmp/n8n-community-packages-cookies.$$"
        trap "rm -f $COOKIE_JAR" EXIT

        # Read admin password
        ADMIN_PASSWORD=$(cat "${cfg.adminPasswordFile}")

        # Wait for n8n to be ready
        echo "Waiting for n8n to be ready..."
        timeout=120
        while ! curl -sf "$N8N_URL/healthz" >/dev/null 2>&1; do
          timeout=$((timeout - 1))
          if [ $timeout -le 0 ]; then
            echo "ERROR: n8n not ready after 120 seconds"
            exit 1
          fi
          sleep 1
        done
        sleep 5  # Extra delay for full initialization

        # Login to get session cookie
        echo "Authenticating with n8n..."
        LOGIN_RESPONSE=$(curl -s -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
          -X POST \
          -H "Content-Type: application/json" \
          -d "{\"emailOrLdapLoginId\":\"admin@localhost.com\",\"password\":\"$ADMIN_PASSWORD\"}" \
          "$N8N_URL/rest/login" 2>&1)

        if ! echo "$LOGIN_RESPONSE" | jq -e '.data.id' >/dev/null 2>&1; then
          echo "ERROR: Failed to authenticate with n8n"
          echo "Response: $LOGIN_RESPONSE"
          exit 1
        fi
        echo "Authentication successful"

        # Get currently installed packages
        echo "Checking installed packages..."
        INSTALLED_RESPONSE=$(curl -s -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
          "$N8N_URL/rest/community-packages" 2>&1)

        INSTALLED_PACKAGES=$(echo "$INSTALLED_RESPONSE" | jq -r '.data[].packageName // empty' 2>/dev/null || echo "")

        # Install missing packages
        PACKAGES_INSTALLED=0
        for pkg in ${concatStringsSep " " cfg.communityPackages}; do
          if echo "$INSTALLED_PACKAGES" | grep -qx "$pkg"; then
            echo "Package $pkg already installed"
          else
            echo "Installing package: $pkg"
            INSTALL_RESPONSE=$(curl -s -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
              -X POST \
              -H "Content-Type: application/json" \
              -d "{\"name\":\"$pkg\"}" \
              "$N8N_URL/rest/community-packages" 2>&1)

            if echo "$INSTALL_RESPONSE" | jq -e '.data.packageName' >/dev/null 2>&1; then
              echo "Successfully installed: $pkg"
              PACKAGES_INSTALLED=1
            else
              echo "WARNING: Failed to install $pkg"
              echo "Response: $INSTALL_RESPONSE"
            fi
          fi
        done

        # Restart n8n if packages were installed (to load new nodes)
        if [ "$PACKAGES_INSTALLED" -eq 1 ]; then
          echo "Restarting n8n to load new community packages..."
          ${pkgs.systemd}/bin/systemctl restart n8n.service
          echo "n8n restarted"
        fi

        echo "Community packages installation complete"
      '';
    };

    # Access n8n via Tailscale HTTPS (requires tailscaleServe.enable = true):
    #   https://<hostname>.<tailnet>.ts.net:5678
    # Service binds to localhost only for security - no direct network access possible
  };
}
