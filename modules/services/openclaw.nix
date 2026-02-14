# OpenClaw — AI Programming Partner (Task Execution Engine)
#
# Uses Claude Code CLI (`claude -p`) in one-shot mode to process tasks.
# Tasks arrive via a file-based inbox (systemd.path watcher) or manual trigger.
#
# Flow:
#   Boot → openclaw-git-setup.service (clone repo, provision secrets)
#   Task file → /var/lib/openclaw/inbox/
#   systemd.path → openclaw-task-runner.service (processes all queued tasks)
#   claude -p "task" --allowedTools "..." → works in git clone
#   Results → /var/lib/openclaw/results/<task-id>/output.json
#   Optional → POST notification to n8n webhook
#
# Security:
#   - Dedicated openclaw user with restricted sudo (build wrapper only)
#   - Network restricted via nftables (Anthropic API + GitHub + DNS resolvers)
#   - Secret values loaded at runtime from agenix paths into /run/openclaw/env
#   - Claude Code tools whitelist limits filesystem/shell access
#
# Usage in host configuration:
#   services.openclaw = {
#     enable = true;
#     anthropicApiKeyFile = config.age.secrets.anthropic-api-key.path;
#     githubTokenFile = config.age.secrets.openclaw-github-token.path;
#   };

{ config, pkgs, lib, claude-code ? null, ... }:

with lib;

let
  cfg = config.services.openclaw;

  # Static UID/GID so nftables can reference by number at build time
  # (username lookup fails in CI where the openclaw user doesn't exist)
  openclawUid = 991;
  openclawGid = 991;

  claudeCodePkg =
    if claude-code != null
    then claude-code.packages.${pkgs.system}.default
    else null;

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
        echo "ERROR: unknown command: ''${1:-}. Allowed: build <target>, check, fmt" >&2
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

    # Move current task to failed/ on unexpected errors (jq crash, disk full, etc.)
    PROCESSING_FILE=""
    trap '
      if [ -n "$PROCESSING_FILE" ] && [ -f "$PROCESSING_FILE" ]; then
        ${pkgs.coreutils}/bin/mv "$PROCESSING_FILE" "$FAILED/" 2>&1 || echo "ERROR: ERR trap failed to move $PROCESSING_FILE to $FAILED/" >&2
      fi
    ' ERR

    # Process all available tasks (DirectoryNotEmpty only triggers on transition)
    while true; do
      TASK_FILE=$(${pkgs.findutils}/bin/find "$INBOX" -maxdepth 1 -type f -name '*.task' -printf '%T+ %p\n' | ${pkgs.coreutils}/bin/sort | ${pkgs.coreutils}/bin/head -n1 | ${pkgs.coreutils}/bin/cut -d' ' -f2-)

      if [ -z "$TASK_FILE" ]; then
        break
      fi

      echo "Processing task: $TASK_FILE"

      # Generate task ID from filename + timestamp
      TASK_BASENAME=$(${pkgs.coreutils}/bin/basename "$TASK_FILE" .task)
      TASK_ID="$(${pkgs.coreutils}/bin/date +%Y%m%d-%H%M%S)-$TASK_BASENAME"
      RESULT_DIR="$RESULTS/$TASK_ID"
      ${pkgs.coreutils}/bin/mkdir -p "$RESULT_DIR" "$FAILED"

      # Move task out of inbox BEFORE processing. Without this, an OOM kill would
      # leave the task in inbox, DirectoryNotEmpty would re-trigger, and it would
      # OOM again in a loop.
      PROCESSING_FILE="$RESULT_DIR/$(${pkgs.coreutils}/bin/basename "$TASK_FILE")"
      ${pkgs.coreutils}/bin/mv "$TASK_FILE" "$PROCESSING_FILE"

      TASK_CONTENT=$(${pkgs.coreutils}/bin/cat "$PROCESSING_FILE")

      if [ -z "$TASK_CONTENT" ]; then
        echo "ERROR: Task file is empty: $PROCESSING_FILE" >&2
        echo '{"error": "empty task file"}' > "$RESULT_DIR/output.json"
        ${pkgs.coreutils}/bin/mv "$PROCESSING_FILE" "$FAILED/"
        PROCESSING_FILE=""
        continue
      fi

      ALLOWED_TOOLS="${concatStringsSep "," cfg.allowedTools}"

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

      EXIT_CODE=0
      ${claudeCodePkg}/bin/claude "''${CLAUDE_ARGS[@]}" \
        > "$RESULT_DIR/output.json" \
        2> "$RESULT_DIR/stderr.log" \
        || EXIT_CODE=$?

      echo "Claude exited with code: $EXIT_CODE"

      ${pkgs.jq}/bin/jq -n \
        --arg task_id "$TASK_ID" \
        --arg task_file "$(${pkgs.coreutils}/bin/basename "$PROCESSING_FILE")" \
        --arg exit_code "$EXIT_CODE" \
        --arg timestamp "$(${pkgs.coreutils}/bin/date -Iseconds)" \
        '{task_id: $task_id, task_file: $task_file, exit_code: ($exit_code | tonumber), timestamp: $timestamp}' \
        > "$RESULT_DIR/metadata.json.tmp" \
        && ${pkgs.coreutils}/bin/mv "$RESULT_DIR/metadata.json.tmp" "$RESULT_DIR/metadata.json"

      if [ "$EXIT_CODE" -eq 0 ]; then
        ${pkgs.coreutils}/bin/mv "$PROCESSING_FILE" "$COMPLETED/"
      else
        ${pkgs.coreutils}/bin/mv "$PROCESSING_FILE" "$FAILED/"
      fi

      ${optionalString (cfg.notifications.n8nWebhookUrl != null) ''
        SUMMARY=$(${pkgs.jq}/bin/jq -c '{task_id: .task_id, exit_code: .exit_code, timestamp: .timestamp}' "$RESULT_DIR/metadata.json")
        HTTP_CODE=$(${pkgs.curl}/bin/curl --no-progress-meter -o /dev/null -w "%{http_code}" -X POST \
          -H "Content-Type: application/json" \
          -d "$SUMMARY" \
          "${cfg.notifications.n8nWebhookUrl}" 2>&1) \
          || echo "WARNING: Failed to notify n8n webhook (task $TASK_ID, HTTP $HTTP_CODE)" >&2
      ''}

      PROCESSING_FILE=""
      echo "Task $TASK_ID completed (exit code: $EXIT_CODE)"
    done

    echo "All inbox tasks processed"
  '';

  # Git setup script
  gitSetupScript = pkgs.writeShellScript "openclaw-git-setup" ''
    set -euo pipefail

    REPO_DIR="/var/lib/openclaw/nixos-config"

    # Configure git identity (skip if .gitconfig is read-only)
    if [ ! -w "/var/lib/openclaw/.gitconfig" ] && [ -f "/var/lib/openclaw/.gitconfig" ]; then
      echo "Using existing .gitconfig (read-only mount)"
    else
      ${pkgs.git}/bin/git config --global user.name "OpenClaw Bot"
      ${pkgs.git}/bin/git config --global user.email "openclaw@sancta-choir"

      ${optionalString (cfg.githubTokenFile != null) ''
        # Configure credential helper for HTTPS with GH_TOKEN
        # GH_TOKEN is set via EnvironmentFile
        ${pkgs.git}/bin/git config --global credential.helper \
          '!f() { echo "username=x-access-token"; echo "password=$GH_TOKEN"; }; f'
      ''}
    fi

    if [ ! -d "$REPO_DIR/.git" ]; then
      echo "Cloning repository: ${cfg.repoUrl}"
      ${pkgs.git}/bin/git clone --branch "${cfg.repoBranch}" "${cfg.repoUrl}" "$REPO_DIR"
    else
      echo "Repository exists, updating..."
      cd "$REPO_DIR"
      ${pkgs.git}/bin/git fetch origin
      ${pkgs.git}/bin/git checkout "${cfg.repoBranch}"
      ${pkgs.git}/bin/git pull --ff-only origin "${cfg.repoBranch}" || {
        echo "ERROR: Fast-forward pull failed. Local state has diverged from origin/${cfg.repoBranch}." >&2
        echo "Current HEAD: $(${pkgs.git}/bin/git rev-parse HEAD)" >&2
        echo "Unpushed commits:" >&2
        ${pkgs.git}/bin/git log --oneline "origin/${cfg.repoBranch}..HEAD" >&2 || true
        echo "Manual intervention required. Refusing to reset --hard." >&2
        exit 1
      }
    fi

    echo "Git setup complete"
  '';

  # DNS resolver script for nftables sets
  nftDnsScript = pkgs.writeShellScript "openclaw-nft-dns-update" ''
        set -euo pipefail

        V4_ELEMENTS=""
        V6_ELEMENTS=""

        for domain in ${concatStringsSep " " (map escapeShellArg cfg.networkRestriction.allowedDomains)}; do
          # IPv4 — per-domain failure is OK, but log it
          IPS=$(${pkgs.dnsutils}/bin/dig +short "$domain" A 2>/dev/null) || {
            echo "WARNING: Failed to resolve $domain A record" >&2
            IPS=""
          }
          for ip in $IPS; do
            if echo "$ip" | ${pkgs.gnugrep}/bin/grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
              [ -n "$V4_ELEMENTS" ] && V4_ELEMENTS="$V4_ELEMENTS, "
              V4_ELEMENTS="$V4_ELEMENTS$ip"
            fi
          done

          # IPv6 — stricter regex requiring colon-separated hex groups
          IPS6=$(${pkgs.dnsutils}/bin/dig +short "$domain" AAAA 2>/dev/null) || {
            echo "WARNING: Failed to resolve $domain AAAA record" >&2
            IPS6=""
          }
          for ip in $IPS6; do
            if echo "$ip" | ${pkgs.gnugrep}/bin/grep -qE '^([0-9a-f]{1,4}:)+[0-9a-f]{1,4}$'; then
              [ -n "$V6_ELEMENTS" ] && V6_ELEMENTS="$V6_ELEMENTS, "
              V6_ELEMENTS="$V6_ELEMENTS$ip"
            fi
          done
        done

        if [ -z "$V4_ELEMENTS" ] && [ -z "$V6_ELEMENTS" ]; then
          echo "ERROR: No IPs resolved for any allowed domain. nftables sets are empty." >&2
          exit 1
        fi

        # Atomic update — flush+add in a single nft transaction to avoid empty-set window
        if [ -n "$V4_ELEMENTS" ]; then
          ${pkgs.nftables}/bin/nft -f - <<NFT_EOF
    flush set inet openclaw-restrict allowed_dns_ips_v4
    add element inet openclaw-restrict allowed_dns_ips_v4 { $V4_ELEMENTS }
    NFT_EOF
          echo "Updated nftables IPv4 set: $V4_ELEMENTS"
        fi

        if [ -n "$V6_ELEMENTS" ]; then
          ${pkgs.nftables}/bin/nft -f - <<NFT_EOF
    flush set inet openclaw-restrict allowed_dns_ips_v6
    add element inet openclaw-restrict allowed_dns_ips_v6 { $V6_ELEMENTS }
    NFT_EOF
          echo "Updated nftables IPv6 set: $V6_ELEMENTS"
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
    # Assertions: require claude-code flake input + prevent secrets in Nix store
    assertions = [
      {
        assertion = claude-code != null;
        message = ''
          The openclaw module requires the claude-code flake input via specialArgs.

          Add to flake inputs:
            claude-code.url = "github:sadjow/claude-code-nix";

          Then pass to specialArgs:
            specialArgs = { inherit claude-code; };
        '';
      }
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
      uid = openclawUid;
      group = "openclaw";
      home = "/var/lib/openclaw";
      description = "OpenClaw AI programming partner";
      shell = pkgs.bash;
    };

    users.groups.openclaw = {
      gid = openclawGid;
    };

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
        EnvironmentFile = "/run/openclaw/env";
        ExecStart = gitSetupScript;

        # Run secret setup as root (+ prefix) before git operations
        ExecStartPre = [
          ("+" + pkgs.writeShellScript "openclaw-git-setup-env" ''
            set -euo pipefail

            ${pkgs.coreutils}/bin/mkdir -p /run/openclaw
            ENV_FILE="/run/openclaw/env"
            : > "$ENV_FILE"

            # Anthropic API key
            if [ ! -f "${cfg.anthropicApiKeyFile}" ]; then
              ${pkgs.coreutils}/bin/echo "ERROR: Anthropic API key file not found: ${cfg.anthropicApiKeyFile}" >&2
              exit 1
            fi
            ANTHROPIC_KEY=$(${pkgs.coreutils}/bin/tr -d '\n' < "${cfg.anthropicApiKeyFile}")
            if [ -z "$ANTHROPIC_KEY" ]; then
              ${pkgs.coreutils}/bin/echo "ERROR: Anthropic API key file is empty: ${cfg.anthropicApiKeyFile}" >&2
              exit 1
            fi
            printf 'ANTHROPIC_API_KEY=%s\n' "$ANTHROPIC_KEY" >> "$ENV_FILE"

            # Isolate Claude config directory
            ${pkgs.coreutils}/bin/echo "CLAUDE_CONFIG_DIR=/var/lib/openclaw/.claude" >> "$ENV_FILE"

            # GitHub token (if provided)
            ${optionalString (cfg.githubTokenFile != null) ''
              if [ ! -f "${cfg.githubTokenFile}" ]; then
                ${pkgs.coreutils}/bin/echo "ERROR: GitHub token file not found: ${cfg.githubTokenFile}" >&2
                exit 1
              fi
              GH_TOKEN=$(${pkgs.coreutils}/bin/tr -d '\n' < "${cfg.githubTokenFile}")
              if [ -z "$GH_TOKEN" ]; then
                ${pkgs.coreutils}/bin/echo "ERROR: GitHub token file is empty: ${cfg.githubTokenFile}" >&2
                exit 1
              fi
              printf 'GH_TOKEN=%s\n' "$GH_TOKEN" >> "$ENV_FILE"
            ''}

            ${pkgs.coreutils}/bin/chmod 600 "$ENV_FILE"
            ${pkgs.coreutils}/bin/chown openclaw:openclaw "$ENV_FILE"
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
        EnvironmentFile = "/run/openclaw/env";
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
        ${pkgs.tailscale}/bin/tailscale serve --bg --https ${toString cfg.tailscaleServe.httpsPort} off \
          || echo "WARNING: Failed to remove Tailscale Serve route for port ${toString cfg.tailscaleServe.httpsPort}" >&2
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
          meta skuid != ${toString openclawUid} accept

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
