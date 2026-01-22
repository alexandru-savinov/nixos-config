# n8n MCP Server for Claude Code
#
# This module configures the n8n-mcp MCP server for Claude Code integration.
# It provides AI assistants with comprehensive access to n8n node documentation
# and optionally enables workflow management via the n8n API.
#
# Features:
# - Smart node search (1,084+ nodes with 99% property coverage)
# - 2,646 pre-extracted workflow examples
# - Config validation before deployment
# - AI workflow validation (v2.17.0+)
#
# Two operational modes:
# 1. Documentation-only (default): Search nodes, validate configs, access templates
# 2. Full mode (with API key): Create/update/delete workflows, run executions
#
# Source: https://github.com/czlonkowski/n8n-mcp
# NPM Package: n8n-mcp
#
# =============================================================================
# SETUP INSTRUCTIONS FOR FULL MODE (with workflow management):
# =============================================================================
#
# 1. Generate an API key in n8n:
#    - Log in to n8n web UI (e.g., https://rpi5.tail4249a9.ts.net:5678)
#    - Go to: Settings > n8n API > Create an API key
#    - Label: "Claude MCP" (or any descriptive name)
#    - Expiration: Set as desired (or "Never")
#    - Copy the generated key (starts with "n8n_api_")
#
# 2. Store the API key in agenix:
#    cd /home/nixos/nixos-config/secrets
#    agenix -e n8n-api-key.age
#    # Paste the API key and save
#
# 3. Enable full mode in your host configuration:
#    services.n8n-mcp-claude = {
#      enable = true;
#      n8nUrl = "http://127.0.0.1:5678";
#      apiKeyFile = config.age.secrets.n8n-api-key.path;
#    };
#
# 4. Rebuild: sudo nixos-rebuild switch --flake .#rpi5-full
#
# NOTE: The API key persists in n8n's database. After a fresh n8n install,
#       you'll need to regenerate the key via the web UI and update agenix.
# =============================================================================
#
# Usage (documentation-only mode - no API key needed):
#   services.n8n-mcp-claude = {
#     enable = true;
#     users = [ "nixos" ];
#   };
#
# Usage (full workflow management mode):
#   services.n8n-mcp-claude = {
#     enable = true;
#     users = [ "nixos" ];
#     n8nUrl = "http://127.0.0.1:5678";
#     apiKeyFile = config.age.secrets.n8n-api-key.path;
#   };

{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.n8n-mcp-claude;

  # Build MCP server configuration (without API key - that's injected at runtime)
  mkMcpConfigBase = {
    command = "${pkgs.nodejs_22}/bin/npx";
    args = [ "-y" "n8n-mcp" ];
    env = {
      MCP_MODE = "stdio";
      LOG_LEVEL = "error";
      DISABLE_CONSOLE_OUTPUT = "true";
      N8N_MCP_TELEMETRY_DISABLED = boolToString cfg.disableTelemetry;
    } // optionalAttrs (cfg.n8nUrl != null) {
      N8N_API_URL = cfg.n8nUrl;
    };
  };

  # Full MCP config for documentation-only mode (no secrets)
  mkMcpConfigStatic = {
    mcpServers = {
      n8n-mcp = mkMcpConfigBase;
    };
  };

  # Script to generate MCP config with API key injected at runtime
  generateMcpConfigScript = user: pkgs.writeShellScript "n8n-mcp-config-${user}" ''
    set -euo pipefail

    USER_HOME=$(getent passwd "${user}" | cut -d: -f6)
    CONFIG_DIR="$USER_HOME/.config/claude"
    CONFIG_FILE="$CONFIG_DIR/mcp.json"

    # Create config directory if it doesn't exist
    mkdir -p "$CONFIG_DIR"

    # Read existing config or start fresh
    if [ -f "$CONFIG_FILE" ]; then
      EXISTING_CONFIG=$(cat "$CONFIG_FILE")
    else
      EXISTING_CONFIG='{"mcpServers":{}}'
    fi

    # Build n8n-mcp server config
    N8N_MCP_CONFIG=$(cat <<'MCPEOF'
${builtins.toJSON mkMcpConfigBase}
MCPEOF
)

    # Inject API key if provided
    ${optionalString (cfg.apiKeyFile != null) ''
      if [ -f "${cfg.apiKeyFile}" ]; then
        API_KEY=$(cat "${cfg.apiKeyFile}")
        N8N_MCP_CONFIG=$(echo "$N8N_MCP_CONFIG" | ${pkgs.jq}/bin/jq --arg key "$API_KEY" '.env.N8N_API_KEY = $key')
      else
        echo "WARNING: API key file not found: ${cfg.apiKeyFile}" >&2
        echo "n8n-mcp will run in documentation-only mode" >&2
      fi
    ''}

    # Merge into existing config (preserving other MCP servers like context7, unifi)
    echo "$EXISTING_CONFIG" | ${pkgs.jq}/bin/jq --argjson n8n "$N8N_MCP_CONFIG" '.mcpServers["n8n-mcp"] = $n8n' > "$CONFIG_FILE"

    # Set proper ownership
    chown "${user}:$(id -gn "${user}" 2>/dev/null || echo "${user}")" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"

    echo "n8n-mcp configured for ${user} at $CONFIG_FILE"
  '';
in
{
  options.services.n8n-mcp-claude = {
    enable = mkEnableOption "n8n MCP server for Claude Code";

    users = mkOption {
      type = types.listOf types.str;
      default = [ "nixos" ];
      example = [ "nixos" "root" ];
      description = ''
        List of users to configure n8n-mcp for.
        MCP config is written to ~/.config/claude/mcp.json for each user.
      '';
    };

    n8nUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "http://127.0.0.1:5678";
      description = ''
        URL of the n8n instance for workflow management.
        If null, n8n-mcp runs in documentation-only mode.
        Set to local n8n URL for full workflow management.

        For rpi5-full with local n8n: "http://127.0.0.1:5678"
        For remote n8n via Tailscale: "https://sancta-choir.tail4249a9.ts.net:5678"
      '';
    };

    apiKeyFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/run/agenix/n8n-api-key";
      description = ''
        Path to file containing the n8n API key.
        Required for workflow management operations.

        Use agenix for secret management:
          apiKeyFile = config.age.secrets.n8n-api-key.path;

        To generate an API key in n8n:
          Settings > API > Create API Key

        If null, n8n-mcp runs in documentation-only mode
        (search nodes, validate configs, access templates).
      '';
    };

    disableTelemetry = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Disable n8n-mcp telemetry collection.
        Enabled by default for privacy.
      '';
    };
  };

  config = mkIf cfg.enable {
    # For API key mode: Use systemd service to inject secret at runtime
    # This avoids putting secrets in the Nix store
    systemd.services = mkIf (cfg.apiKeyFile != null)
      (listToAttrs (map
        (user: {
          name = "n8n-mcp-config-${user}";
          value = {
            description = "Configure n8n-mcp for Claude Code (${user})";
            after = [ "network.target" ];
            wantedBy = [ "multi-user.target" ];

            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = generateMcpConfigScript user;
            };
          };
        })
        cfg.users));

    # For documentation-only mode (no API key): Use home-manager to write static config
    # This is simpler and works without systemd service at boot
    home-manager.users = mkIf (cfg.apiKeyFile == null)
      (listToAttrs (map
        (user: {
          name = user;
          value = {
            home.stateVersion = lib.mkDefault "24.05";
            xdg.configFile."claude/mcp.json".text = builtins.toJSON mkMcpConfigStatic;
          };
        })
        cfg.users));
  };
}
