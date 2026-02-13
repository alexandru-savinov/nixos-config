# OpenClaw — AI Programming Partner (Task Execution Engine)
#
# Uses Claude Code CLI (`claude -p`) in one-shot mode to process tasks.
# Tasks arrive via a file-based inbox (systemd.path watcher) or manual trigger.
#
# Flow:
#   Task file → /var/lib/openclaw/inbox/
#   systemd.path → openclaw-task-runner.service
#   claude -p "task" --allowedTools "..." → works in git clone
#   Results → /var/lib/openclaw/results/<task-id>/output.json
#   Optional → POST notification to n8n webhook
#
# Security:
#   - Dedicated openclaw user with restricted sudo (build wrapper only)
#   - Network restricted via nftables (Anthropic API + GitHub only)
#   - All secrets loaded from agenix via ExecStartPre (never in Nix store)
#   - Claude Code tools whitelist limits filesystem/shell access
#
# Usage in host configuration:
#   services.openclaw = {
#     enable = true;
#     anthropicApiKeyFile = config.age.secrets.anthropic-api-key.path;
#     githubTokenFile = config.age.secrets.github-token.path;
#   };

{ config, pkgs, lib, claude-code, ... }:

with lib;

let
  cfg = config.services.openclaw;

  claudeCodePkg = claude-code.packages.${pkgs.system}.default;

  # Sudo wrapper script that ONLY allows specific safe commands
  openclawSudo = pkgs.writeShellScript "openclaw-sudo" ''
    set -euo pipefail

    # Log every invocation for audit trail
    echo "openclaw-sudo: invoked with args: $*" >&2

    ALLOWED_TARGETS="${concatStringsSep " " cfg.allowedBuildTargets}"

    case "''${1:-}" in
      build)
        TARGET="''${2:-}"
        if [ -z "$TARGET" ]; then
          echo "ERROR: build requires a target argument" >&2
          exit 1
        fi
        # Validate target against allowlist
        FOUND=0
        for allowed in $ALLOWED_TARGETS; do
          if [ "$TARGET" = "$allowed" ]; then
            FOUND=1
            break
          fi
        done
        if [ "$FOUND" -ne 1 ]; then
          echo "ERROR: target '$TARGET' is not in allowedBuildTargets: $ALLOWED_TARGETS" >&2
          exit 1
        fi
        echo "openclaw-sudo: running nixos-rebuild build --flake /var/lib/openclaw/nixos-config#$TARGET" >&2
        exec ${pkgs.nixos-rebuild}/bin/nixos-rebuild build --flake "/var/lib/openclaw/nixos-config#$TARGET"
        ;;
      check)
        echo "openclaw-sudo: running nix flake check" >&2
        exec ${pkgs.nix}/bin/nix flake check /var/lib/openclaw/nixos-config
        ;;
      fmt)
        echo "openclaw-sudo: running nix fmt" >&2
        exec ${pkgs.nix}/bin/nix fmt /var/lib/openclaw/nixos-config
        ;;
      *)
        echo "ERROR: unknown command '''${1:-}'. Allowed: build <target>, check, fmt" >&2
        exit 1
        ;;
    esac
  '';

  # Task runner script
  taskRunnerScript = pkgs.writeShellScript "openclaw-task-runner" ''
    set -euo pipefail

    INBOX="/var/lib/openclaw/inbox"
    RESULTS="/var/lib/openclaw/results"
    COMPLETED="/var/lib/openclaw/completed"
    FAILED="/var/lib/openclaw/failed"

    # Pick the oldest task file
    TASK_FILE=$(${pkgs.findutils}/bin/find "$INBOX" -maxdepth 1 -type f -name '*.task' -printf '%T+ %p\n' 2>/dev/null | ${pkgs.coreutils}/bin/sort | ${pkgs.coreutils}/bin/head -n1 | ${pkgs.coreutils}/bin/cut -d' ' -f2-)

    if [ -z "$TASK_FILE" ]; then
      echo "No task files found in $INBOX"
      exit 0
    fi

    echo "Processing task: $TASK_FILE"

    # Generate task ID from filename + timestamp
    TASK_BASENAME=$(${pkgs.coreutils}/bin/basename "$TASK_FILE" .task)
    TASK_ID="$(${pkgs.coreutils}/bin/date +%Y%m%d-%H%M%S)-$TASK_BASENAME"
    RESULT_DIR="$RESULTS/$TASK_ID"
    ${pkgs.coreutils}/bin/mkdir -p "$RESULT_DIR" "$FAILED"

    # Move task out of inbox BEFORE processing (prevents OOM restart loops)
    PROCESSING_FILE="$RESULT_DIR/$(${pkgs.coreutils}/bin/basename "$TASK_FILE")"
    ${pkgs.coreutils}/bin/mv "$TASK_FILE" "$PROCESSING_FILE"

    # Read task content
    TASK_CONTENT=$(${pkgs.coreutils}/bin/cat "$PROCESSING_FILE")

    if [ -z "$TASK_CONTENT" ]; then
      echo "ERROR: Task file is empty: $PROCESSING_FILE" >&2
      echo '{"error": "empty task file"}' > "$RESULT_DIR/output.json"
      ${pkgs.coreutils}/bin/mv "$PROCESSING_FILE" "$FAILED/"
      exit 1
    fi

    # Build allowedTools argument
    ALLOWED_TOOLS="${concatStringsSep "," cfg.allowedTools}"

    # Build claude command
    CLAUDE_ARGS=( -p "$TASK_CONTENT" )
    CLAUDE_ARGS+=( --allowedTools "$ALLOWED_TOOLS" )
    CLAUDE_ARGS+=( --max-turns ${toString cfg.maxTurns} )
    CLAUDE_ARGS+=( --model "${cfg.model}" )
    CLAUDE_ARGS+=( --output-format json )

    ${optionalString (cfg.maxBudgetUsd > 0) ''
      CLAUDE_ARGS+=( --max-budget-usd ${toString cfg.maxBudgetUsd} )
    ''}

    ${optionalString (cfg.systemPrompt != null) ''
      CLAUDE_ARGS+=( --system-prompt ${escapeShellArg cfg.systemPrompt} )
    ''}

    ${optionalString (cfg.mcpConfigFile != null) ''
      CLAUDE_ARGS+=( --mcp-config "${cfg.mcpConfigFile}" )
    ''}

    echo "Running claude with args: ''${CLAUDE_ARGS[*]}"
    echo "Working directory: /var/lib/openclaw/nixos-config"

    # Run Claude Code CLI, capture output
    EXIT_CODE=0
    ${claudeCodePkg}/bin/claude "''${CLAUDE_ARGS[@]}" \
      > "$RESULT_DIR/output.json" \
      2> "$RESULT_DIR/stderr.log" \
      || EXIT_CODE=$?

    echo "Claude exited with code: $EXIT_CODE"

    # Add metadata to results
    ${pkgs.jq}/bin/jq -n \
      --arg task_id "$TASK_ID" \
      --arg task_file "$(${pkgs.coreutils}/bin/basename "$PROCESSING_FILE")" \
      --arg exit_code "$EXIT_CODE" \
      --arg timestamp "$(${pkgs.coreutils}/bin/date -Iseconds)" \
      '{task_id: $task_id, task_file: $task_file, exit_code: ($exit_code | tonumber), timestamp: $timestamp}' \
      > "$RESULT_DIR/metadata.json"

    # Move to completed or failed based on exit code
    if [ "$EXIT_CODE" -eq 0 ]; then
      ${pkgs.coreutils}/bin/mv "$PROCESSING_FILE" "$COMPLETED/"
    else
      ${pkgs.coreutils}/bin/mv "$PROCESSING_FILE" "$FAILED/"
    fi

    ${optionalString (cfg.notifications.n8nWebhookUrl != null) ''
      # POST result summary to n8n webhook
      SUMMARY=$(${pkgs.jq}/bin/jq -c '{task_id: .task_id, exit_code: .exit_code, timestamp: .timestamp}' "$RESULT_DIR/metadata.json")
      ${pkgs.curl}/bin/curl -sf -X POST \
        -H "Content-Type: application/json" \
        -d "$SUMMARY" \
        "${cfg.notifications.n8nWebhookUrl}" \
        || echo "WARNING: Failed to send notification to n8n webhook" >&2
    ''}

    echo "Task $TASK_ID completed (exit code: $EXIT_CODE)"
  '';

  # Git setup script
  gitSetupScript = pkgs.writeShellScript "openclaw-git-setup" ''
    set -euo pipefail

    REPO_DIR="/var/lib/openclaw/nixos-config"

    # Configure git identity
    ${pkgs.git}/bin/git config --global user.name "OpenClaw Bot"
    ${pkgs.git}/bin/git config --global user.email "openclaw@sancta-choir"

    ${optionalString (cfg.githubTokenFile != null) ''
      # Configure credential helper for HTTPS with GH_TOKEN
      # GH_TOKEN is set via EnvironmentFile
      ${pkgs.git}/bin/git config --global credential.helper \
        '!f() { echo "username=x-access-token"; echo "password=$GH_TOKEN"; }; f'
    ''}

    if [ ! -d "$REPO_DIR/.git" ]; then
      echo "Cloning repository: ${cfg.repoUrl}"
      ${pkgs.git}/bin/git clone --branch "${cfg.repoBranch}" "${cfg.repoUrl}" "$REPO_DIR"
    else
      echo "Repository exists, updating..."
      cd "$REPO_DIR"
      ${pkgs.git}/bin/git fetch origin
      ${pkgs.git}/bin/git checkout "${cfg.repoBranch}"
      ${pkgs.git}/bin/git pull --ff-only origin "${cfg.repoBranch}" || {
        echo "WARNING: Fast-forward pull failed, resetting to origin/${cfg.repoBranch}" >&2
        ${pkgs.git}/bin/git reset --hard "origin/${cfg.repoBranch}"
      }
    fi

    echo "Git setup complete"
  '';

  # DNS resolver script for nftables sets (separate IPv4/IPv6)
  nftDnsScript = pkgs.writeShellScript "openclaw-nft-dns-update" ''
    set -euo pipefail

    # Collect IPv4 addresses
    V4_ELEMENTS=""
    for domain in ${concatStringsSep " " (map escapeShellArg cfg.networkRestriction.allowedDomains)}; do
      IPS=$(${pkgs.dnsutils}/bin/dig +short "$domain" A 2>/dev/null || true)
      for ip in $IPS; do
        if echo "$ip" | ${pkgs.gnugrep}/bin/grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
          [ -n "$V4_ELEMENTS" ] && V4_ELEMENTS="$V4_ELEMENTS, "
          V4_ELEMENTS="$V4_ELEMENTS$ip"
        fi
      done
    done

    # Collect IPv6 addresses
    V6_ELEMENTS=""
    for domain in ${concatStringsSep " " (map escapeShellArg cfg.networkRestriction.allowedDomains)}; do
      IPS6=$(${pkgs.dnsutils}/bin/dig +short "$domain" AAAA 2>/dev/null || true)
      for ip in $IPS6; do
        if echo "$ip" | ${pkgs.gnugrep}/bin/grep -qE '^[0-9a-f:]+$'; then
          [ -n "$V6_ELEMENTS" ] && V6_ELEMENTS="$V6_ELEMENTS, "
          V6_ELEMENTS="$V6_ELEMENTS$ip"
        fi
      done
    done

    # Update IPv4 set
    if [ -n "$V4_ELEMENTS" ]; then
      ${pkgs.nftables}/bin/nft flush set inet openclaw-restrict allowed_dns_ips_v4 2>/dev/null || true
      ${pkgs.nftables}/bin/nft add element inet openclaw-restrict allowed_dns_ips_v4 "{ $V4_ELEMENTS }" 2>/dev/null || true
      echo "Updated nftables IPv4 set: $V4_ELEMENTS"
    fi

    # Update IPv6 set
    if [ -n "$V6_ELEMENTS" ]; then
      ${pkgs.nftables}/bin/nft flush set inet openclaw-restrict allowed_dns_ips_v6 2>/dev/null || true
      ${pkgs.nftables}/bin/nft add element inet openclaw-restrict allowed_dns_ips_v6 "{ $V6_ELEMENTS }" 2>/dev/null || true
      echo "Updated nftables IPv6 set: $V6_ELEMENTS"
    fi

    if [ -z "$V4_ELEMENTS" ] && [ -z "$V6_ELEMENTS" ]; then
      echo "WARNING: No IPs resolved for allowed domains" >&2
    fi
  '';

  # Cleanup script
  cleanupScript = pkgs.writeShellScript "openclaw-cleanup" ''
    set -euo pipefail

    echo "Cleaning up OpenClaw completed/failed tasks and results older than 30 days..."

    COMPLETED="/var/lib/openclaw/completed"
    FAILED="/var/lib/openclaw/failed"
    RESULTS="/var/lib/openclaw/results"

    if [ -d "$COMPLETED" ]; then
      DELETED=$(${pkgs.findutils}/bin/find "$COMPLETED" -maxdepth 1 -type f -mtime +30 -delete -print | ${pkgs.coreutils}/bin/wc -l)
      echo "Removed $DELETED completed task files"
    fi

    if [ -d "$FAILED" ]; then
      DELETED=$(${pkgs.findutils}/bin/find "$FAILED" -maxdepth 1 -type f -mtime +30 -delete -print | ${pkgs.coreutils}/bin/wc -l)
      echo "Removed $DELETED failed task files"
    fi

    if [ -d "$RESULTS" ]; then
      DELETED=$(${pkgs.findutils}/bin/find "$RESULTS" -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rm -rf {} + -print | ${pkgs.coreutils}/bin/wc -l)
      echo "Removed $DELETED result directories"
    fi

    echo "Cleanup complete"
  '';

in
{
  options.services.openclaw = {
    enable = mkEnableOption "OpenClaw AI programming partner";

    anthropicApiKeyFile = mkOption {
      type = types.path;
      description = "Path to file containing Anthropic API key (agenix).";
    };

    githubTokenFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Path to file containing GitHub fine-grained PAT for PR creation.";
    };

    repoUrl = mkOption {
      type = types.str;
      default = "https://github.com/alexandru-savinov/nixos-config.git";
      description = "Git repository URL to clone (HTTPS, uses GH_TOKEN for auth).";
    };

    repoBranch = mkOption {
      type = types.str;
      default = "main";
      description = "Default branch to track.";
    };

    allowedTools = mkOption {
      type = types.listOf types.str;
      default = [
        "Read"
        "Edit"
        "Write"
        "Glob"
        "Grep"
        "Bash(git *)"
        "Bash(gh *)"
        "Bash(nix fmt)"
        "Bash(nix flake check)"
        "Bash(nixos-rebuild build *)"
      ];
      description = "Claude Code --allowedTools whitelist.";
    };

    maxTurns = mkOption {
      type = types.int;
      default = 50;
      description = "Maximum agent turns per task (--max-turns).";
    };

    maxBudgetUsd = mkOption {
      type = types.number;
      default = 5.0;
      description = "Maximum cost per task in USD (--max-budget-usd).";
    };

    model = mkOption {
      type = types.str;
      default = "sonnet";
      description = "Claude model to use (--model).";
    };

    systemPrompt = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "System prompt for Claude Code (--system-prompt). If null, uses CLAUDE.md from repo.";
    };

    mcpConfigFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Path to MCP configuration JSON for Claude Code.";
    };

    resourceLimits = {
      memoryMax = mkOption {
        type = types.str;
        default = "4G";
        description = "Maximum memory for task runner.";
      };

      cpuQuota = mkOption {
        type = types.str;
        default = "200%";
        description = "CPU quota for task runner.";
      };
    };

    tailscaleServe = {
      enable = mkEnableOption "Tailscale Serve HTTPS proxy for task submission API";

      httpsPort = mkOption {
        type = types.port;
        default = 8443;
        description = "HTTPS port for OpenClaw task submission.";
      };
    };

    notifications = {
      n8nWebhookUrl = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "n8n webhook URL to POST task completion notifications.";
      };
    };

    allowedBuildTargets = mkOption {
      type = types.listOf types.str;
      default = [ "sancta-choir" ];
      description = "Allowed nixos-rebuild --flake targets (prevents building arbitrary configs).";
    };

    networkRestriction = {
      enable = mkEnableOption "per-UID nftables network restrictions" // { default = true; };

      allowedDomains = mkOption {
        type = types.listOf types.str;
        default = [ "api.github.com" "github.com" "api.anthropic.com" ];
        description = "Domains the openclaw user is allowed to reach.";
      };

      anthropicIpRanges = mkOption {
        type = types.listOf types.str;
        default = [ "160.79.104.0/23" ];
        description = "Known Anthropic API IPv4 ranges (static).";
      };

      anthropicIpv6Ranges = mkOption {
        type = types.listOf types.str;
        default = [ "2607:6bc0::/48" ];
        description = "Known Anthropic API IPv6 ranges (static).";
      };
    };
  };

  config = mkIf cfg.enable {
    # Security assertions: prevent secrets in Nix store (world-readable!)
    assertions = [
      {
        assertion = !(hasPrefix "/nix/store" (toString cfg.anthropicApiKeyFile));
        message = ''
          services.openclaw.anthropicApiKeyFile points to the Nix store!
          Files in /nix/store are WORLD-READABLE. Your API key would be exposed.

          Use agenix instead:
            age.secrets.anthropic-api-key.file = ./secrets/anthropic-api-key.age;
            services.openclaw.anthropicApiKeyFile = config.age.secrets.anthropic-api-key.path;
        '';
      }
      {
        assertion = cfg.githubTokenFile == null ||
          !(hasPrefix "/nix/store" (toString cfg.githubTokenFile));
        message = ''
          services.openclaw.githubTokenFile points to the Nix store!
          Files in /nix/store are WORLD-READABLE. Your token would be exposed.

          Use agenix instead:
            age.secrets.github-token.file = ./secrets/github-token.age;
            services.openclaw.githubTokenFile = config.age.secrets.github-token.path;
        '';
      }
      {
        assertion = cfg.mcpConfigFile == null ||
          !(hasPrefix "/nix/store" (toString cfg.mcpConfigFile));
        message = ''
          services.openclaw.mcpConfigFile points to the Nix store!
          Files in /nix/store are WORLD-READABLE. Your MCP config may contain secrets.
          Use agenix or a runtime directory instead.
        '';
      }
      {
        assertion = cfg.allowedBuildTargets != [ ];
        message = ''
          services.openclaw.allowedBuildTargets must not be empty.
          At least one build target must be specified for the sudo wrapper.
        '';
      }
      {
        assertion = !cfg.networkRestriction.enable || cfg.networkRestriction.allowedDomains != [ ];
        message = ''
          services.openclaw.networkRestriction.allowedDomains must not be empty
          when network restrictions are enabled.
        '';
      }
    ];

    # ──────────────────────────────────────────────────────────────
    # User and group
    # ──────────────────────────────────────────────────────────────
    users.users.openclaw = {
      isSystemUser = true;
      group = "openclaw";
      home = "/var/lib/openclaw";
      description = "OpenClaw AI programming partner";
      shell = pkgs.bash;
    };

    users.groups.openclaw = { };

    # ──────────────────────────────────────────────────────────────
    # Directories
    # ──────────────────────────────────────────────────────────────
    systemd.tmpfiles.rules = [
      "d /var/lib/openclaw 0700 openclaw openclaw -"
      "d /var/lib/openclaw/inbox 0700 openclaw openclaw -"
      "d /var/lib/openclaw/results 0700 openclaw openclaw -"
      "d /var/lib/openclaw/completed 0700 openclaw openclaw -"
      "d /var/lib/openclaw/failed 0700 openclaw openclaw -"
    ];

    # ──────────────────────────────────────────────────────────────
    # Sudo wrapper — restricted commands only
    # ──────────────────────────────────────────────────────────────
    security.sudo.extraRules = [
      {
        users = [ "openclaw" ];
        commands = [
          {
            command = "${openclawSudo}";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];

    # ──────────────────────────────────────────────────────────────
    # Git setup service (oneshot)
    # ──────────────────────────────────────────────────────────────
    systemd.services.openclaw-git-setup = {
      description = "Clone/update OpenClaw git repository";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "openclaw";
        Group = "openclaw";
        WorkingDirectory = "/var/lib/openclaw";
        EnvironmentFile = "-/run/openclaw/env";
        ExecStart = gitSetupScript;

        # Run secret setup as root (+ prefix) before git operations
        ExecStartPre = [
          ("+" + pkgs.writeShellScript "openclaw-git-setup-env" ''
            set -euo pipefail

            mkdir -p /run/openclaw
            ENV_FILE="/run/openclaw/env"
            : > "$ENV_FILE"

            # Anthropic API key
            if [ ! -f "${cfg.anthropicApiKeyFile}" ]; then
              echo "ERROR: Anthropic API key file not found: ${cfg.anthropicApiKeyFile}" >&2
              exit 1
            fi
            ANTHROPIC_KEY=$(cat "${cfg.anthropicApiKeyFile}")
            if [ -z "$ANTHROPIC_KEY" ]; then
              echo "ERROR: Anthropic API key file is empty: ${cfg.anthropicApiKeyFile}" >&2
              exit 1
            fi
            echo "ANTHROPIC_API_KEY=$ANTHROPIC_KEY" >> "$ENV_FILE"

            # Isolate Claude config directory
            echo "CLAUDE_CONFIG_DIR=/var/lib/openclaw/.claude" >> "$ENV_FILE"

            # GitHub token (if provided)
            ${optionalString (cfg.githubTokenFile != null) ''
              if [ ! -f "${cfg.githubTokenFile}" ]; then
                echo "ERROR: GitHub token file not found: ${cfg.githubTokenFile}" >&2
                exit 1
              fi
              GH_TOKEN=$(cat "${cfg.githubTokenFile}")
              if [ -z "$GH_TOKEN" ]; then
                echo "ERROR: GitHub token file is empty: ${cfg.githubTokenFile}" >&2
                exit 1
              fi
              echo "GH_TOKEN=$GH_TOKEN" >> "$ENV_FILE"
            ''}

            chmod 600 "$ENV_FILE"
            chown openclaw:openclaw "$ENV_FILE"
          '')
        ];
      };

      path = [ pkgs.git pkgs.gh ];
    };

    # ──────────────────────────────────────────────────────────────
    # Task runner service (oneshot, triggered by path watcher)
    # ──────────────────────────────────────────────────────────────
    systemd.services.openclaw-task-runner = {
      description = "OpenClaw task runner (Claude Code CLI)";
      after = [ "openclaw-git-setup.service" ];
      requires = [ "openclaw-git-setup.service" ];

      serviceConfig = {
        Type = "oneshot";
        User = "openclaw";
        Group = "openclaw";
        WorkingDirectory = "/var/lib/openclaw/nixos-config";
        EnvironmentFile = "-/run/openclaw/env";
        ExecStartPre = pkgs.writeShellScript "openclaw-check-env" ''
          set -euo pipefail
          if [ ! -f /run/openclaw/env ]; then
            echo "ERROR: Environment file not found. openclaw-git-setup may have failed." >&2
            exit 1
          fi
        '';
        ExecStart = taskRunnerScript;

        # Resource limits
        MemoryMax = cfg.resourceLimits.memoryMax;
        CPUQuota = cfg.resourceLimits.cpuQuota;

        # Security hardening
        ProtectHome = true;
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        NoNewPrivileges = true;

        # Timeout for long-running tasks (30 minutes)
        TimeoutStartSec = "1800";
      };

      path = [
        claudeCodePkg
        pkgs.git
        pkgs.gh
        pkgs.curl
        pkgs.jq
        pkgs.nix
      ];
    };

    # ──────────────────────────────────────────────────────────────
    # Path watcher — triggers task runner on new inbox files
    # ──────────────────────────────────────────────────────────────
    systemd.paths.openclaw-task-watcher = {
      description = "Watch OpenClaw inbox for new task files";
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathExists = "/var/lib/openclaw/inbox";
        DirectoryNotEmpty = "/var/lib/openclaw/inbox";
        Unit = "openclaw-task-runner.service";
      };
    };

    # ──────────────────────────────────────────────────────────────
    # Cleanup timer — daily removal of old tasks and results
    # ──────────────────────────────────────────────────────────────
    systemd.timers.openclaw-cleanup = {
      description = "Clean up old OpenClaw completed tasks and results";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
      };
    };

    systemd.services.openclaw-cleanup = {
      description = "Remove OpenClaw completed tasks and results older than 30 days";
      serviceConfig = {
        Type = "oneshot";
        User = "openclaw";
        Group = "openclaw";
      };
      script = "${cleanupScript}";
    };

    # ──────────────────────────────────────────────────────────────
    # Tailscale Serve (optional)
    # ──────────────────────────────────────────────────────────────
    # Phase 2: This service is a placeholder. A task submission HTTP server
    # must be implemented before Tailscale Serve can proxy to it.
    systemd.services.tailscale-serve-openclaw = mkIf cfg.tailscaleServe.enable {
      description = "Configure Tailscale Serve for OpenClaw task submission";
      after = [
        "network-online.target"
        "tailscaled.service"
      ];
      wants = [ "network-online.target" ];
      requires = [ "tailscaled.service" ];
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
          echo "Configuring Tailscale Serve for OpenClaw..."
          # Placeholder: will proxy to a task submission HTTP server when added
          echo "NOTE: Tailscale Serve port ${toString cfg.tailscaleServe.httpsPort} reserved for OpenClaw"
          echo "A task submission HTTP server must be added to use this endpoint"
        else
          echo "Tailscale Serve already configured for OpenClaw"
        fi
      '';

      preStop = ''
        echo "Removing Tailscale Serve configuration for OpenClaw..."
        ${pkgs.tailscale}/bin/tailscale serve --bg --https ${toString cfg.tailscaleServe.httpsPort} off || true
      '';
    };

    # ──────────────────────────────────────────────────────────────
    # nftables network restriction (optional, enabled by default)
    # ──────────────────────────────────────────────────────────────
    networking.nftables.enable = mkIf cfg.networkRestriction.enable (mkDefault true);

    networking.nftables.tables.openclaw-restrict = mkIf cfg.networkRestriction.enable {
      family = "inet";
      content = ''
        set anthropic_ips {
          type ipv4_addr
          flags interval
          elements = { ${concatStringsSep ", " cfg.networkRestriction.anthropicIpRanges} }
        }

        set anthropic_ips_v6 {
          type ipv6_addr
          flags interval
          elements = { ${concatStringsSep ", " cfg.networkRestriction.anthropicIpv6Ranges} }
        }

        set allowed_dns_ips_v4 {
          type ipv4_addr
          flags interval
        }

        set allowed_dns_ips_v6 {
          type ipv6_addr
          flags interval
        }

        chain output {
          type filter hook output priority 0; policy accept;

          # Only apply restrictions to the openclaw user
          meta skuid != "openclaw" accept

          # Allow loopback
          oifname "lo" accept

          # Allow Tailscale
          oifname "tailscale0" accept

          # Allow DNS (needed for resolution)
          tcp dport 53 accept
          udp dport 53 accept

          # Allow HTTPS to Anthropic IPs (static, IPv4 + IPv6)
          tcp dport 443 ip daddr @anthropic_ips accept
          tcp dport 443 ip6 daddr @anthropic_ips_v6 accept

          # Allow HTTPS to dynamically resolved IPs (GitHub etc., IPv4 + IPv6)
          tcp dport 443 ip daddr @allowed_dns_ips_v4 accept
          tcp dport 443 ip6 daddr @allowed_dns_ips_v6 accept

          # Drop and log everything else from openclaw
          log prefix "openclaw-blocked: " drop
        }
      '';
    };

    # DNS resolution timer — updates nftables sets every 5 minutes
    systemd.timers.openclaw-nft-dns = mkIf cfg.networkRestriction.enable {
      description = "Resolve OpenClaw allowed domains for nftables";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "30s";
        OnCalendar = "*:0/5"; # Every 5 minutes
        Persistent = true;
      };
    };

    systemd.services.openclaw-nft-dns = mkIf cfg.networkRestriction.enable {
      description = "Update OpenClaw nftables sets with resolved domain IPs";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = "${nftDnsScript}";
    };
  };
}
