# Home Assistant MCP Server for Claude Code
#
# Wires the community voska/hass-mcp MCP server into ~/.claude.json for each
# configured user, so Claude Code can query Home Assistant state and call
# services via the bundled `hass-mcp` stdio server.
#
# Source:  https://github.com/voska/hass-mcp
# PyPI:    hass-mcp   (resolved at MCP-spawn time by uvx, NOT at deploy)
#
# Two operational modes:
# 1. Documentation-only (tokenFile = null): MCP entry is written without
#    HA_TOKEN; the server can launch but cannot authenticate. This is the
#    Phase A state used while waiting for the human onboarding checkpoint.
# 2. Full mode (tokenFile set): the LLAT is read at runtime and injected as
#    the HA_TOKEN env var on the MCP entry. The token file is read by the
#    oneshot, never embedded in the nix store.
#
# Pattern mirrored from modules/services/n8n-mcp-claude.nix so that the
# per-user oneshot MERGES into .mcpServers (preserving entries like n8n-mcp,
# context7, unifi-mcp) instead of overwriting them.
#
# Token bootstrap (manual, see plan-home-assistant.md Task 5):
#   1. Complete owner onboarding at https://rpi5.tail4249a9.ts.net:8123
#   2. Profile → Security → Long-lived access tokens → Create Token
#   3. cd <worktree>/secrets && agenix -e home-assistant-token.age
#   4. Wire `tokenFile = config.age.secrets.home-assistant-token.path;` in
#      the host config (only after the .age exists in the worktree).

{ config
, pkgs
, lib
, ...
}:

with lib;

let
  cfg = config.services.home-assistant-mcp-claude;

  # Base MCP server entry. HA_TOKEN is added at runtime by the oneshot when
  # tokenFile is set; leaving it absent means the server runs unauthenticated.
  mkMcpConfigBase = {
    command = "${pkgs.uv}/bin/uvx";
    # Pin the hass-mcp version: this process is handed the HA LLAT, so running an
    # unversioned PyPI package (whatever uvx resolves as latest at spawn time) is
    # a supply-chain risk. --from pins the version; the trailing arg is the cmd.
    args = [ "--from" "hass-mcp==${cfg.version}" "hass-mcp" ];
    env = {
      HA_URL = cfg.haUrl;
    };
  };

  # Per-user oneshot script: read or initialise ~/.claude.json, optionally
  # inject HA_TOKEN, then patch ONLY the .mcpServers["home-assistant"] key.
  generateMcpConfigScript = user: pkgs.writeShellScript "home-assistant-mcp-config-${user}" ''
        set -euo pipefail

        USER_HOME=$(eval echo "~${user}")
        CONFIG_FILE="$USER_HOME/.claude.json"

        # Serialize concurrent writers: this oneshot and n8n-mcp-config-${user}
        # both read-modify-write ~/.claude.json and start in parallel under
        # multi-user.target. Hold an exclusive lock for the whole RMW so a reboot
        # can't lose-update the file (drop an MCP server) or read it truncated.
        exec 9>"$CONFIG_FILE.lock"
        ${pkgs.util-linux}/bin/flock 9

        if [ -f "$CONFIG_FILE" ]; then
          EXISTING_CONFIG=$(cat "$CONFIG_FILE")
          EXISTING_CONFIG=$(echo "$EXISTING_CONFIG" | ${pkgs.jq}/bin/jq 'if .mcpServers == null then .mcpServers = {} else . end')
        else
          EXISTING_CONFIG='{"mcpServers":{}}'
        fi

        HA_MCP_CONFIG=$(cat <<'MCPEOF'
    ${builtins.toJSON mkMcpConfigBase}
    MCPEOF
    )

        # Inject HA_TOKEN at runtime if the token file is present.
        # Guarded so the oneshot succeeds in Phase A (no token yet).
        ${optionalString (cfg.tokenFile != null) ''
          if [ -f "${cfg.tokenFile}" ]; then
            TOKEN=$(cat "${cfg.tokenFile}")
            HA_MCP_CONFIG=$(echo "$HA_MCP_CONFIG" | ${pkgs.jq}/bin/jq --arg t "$TOKEN" '.env.HA_TOKEN = $t')
          else
            echo "WARNING: token file not found: ${cfg.tokenFile}" >&2
            echo "hass-mcp will run in documentation-only mode" >&2
          fi
        ''}

        # Merge into existing config (preserving other MCP servers), written
        # atomically (temp + mv) so an earlyoom kill mid-write can't truncate
        # ~/.claude.json. flock above serializes writers; mv makes the swap atomic.
        TMP=$(mktemp "$CONFIG_FILE.XXXXXX")
        echo "$EXISTING_CONFIG" | ${pkgs.jq}/bin/jq --argjson ha "$HA_MCP_CONFIG" '.mcpServers["home-assistant"] = $ha' > "$TMP"
        chown "${user}:$(id -gn "${user}" 2>/dev/null || echo "${user}")" "$TMP"
        chmod 600 "$TMP"
        mv -f "$TMP" "$CONFIG_FILE"

        echo "home-assistant MCP configured for ${user} in $CONFIG_FILE"
  '';
in
{
  options.services.home-assistant-mcp-claude = {
    enable = mkEnableOption "Home Assistant MCP server for Claude Code";

    version = mkOption {
      type = types.str;
      default = "0.4.1";
      description = ''
        Pinned hass-mcp PyPI release. The MCP server runs with the HA LLAT, so
        the version is pinned rather than running whatever uvx resolves as latest
        (supply-chain hardening). NOTE: this is the PyPI release number (0.x.y),
        NOT the server's self-reported serverInfo version (e.g. "Hass-MCP 1.27.2").
        Bump deliberately after validating a new release.
      '';
    };

    users = mkOption {
      type = types.listOf types.str;
      default = [ "nixos" ];
      example = [ "nixos" "root" ];
      description = ''
        List of users to configure hass-mcp for.
        MCP config is merged into ~/.claude.json for each user.
      '';
    };

    haUrl = mkOption {
      type = types.str;
      default = "http://127.0.0.1:8123";
      description = ''
        URL of the Home Assistant instance the MCP server should talk to.
        Defaults to the local loopback listener (HA binds 127.0.0.1 only).
      '';
    };

    tokenFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/run/agenix/home-assistant-token";
      description = ''
        Path to a file containing a Home Assistant Long-Lived Access Token.
        When null, hass-mcp is configured in documentation-only mode (no
        HA_TOKEN injected). Use agenix for secret management:

          tokenFile = config.age.secrets.home-assistant-token.path;

        Mint the token in the HA UI: Profile → Security → Long-lived access
        tokens → Create Token.
      '';
    };
  };

  config = mkIf cfg.enable {
    systemd.services = listToAttrs (map
      (user: {
        name = "home-assistant-mcp-config-${user}";
        value = {
          description = "Configure hass-mcp for Claude Code (${user})";
          # agenix here is an activation script, not a real systemd unit;
          # the after entry is harmless and kept for parity with n8n-mcp-claude.nix.
          # Real ordering is provided by wantedBy = multi-user.target.
          after = [ "network.target" "agenix.service" ];
          wantedBy = [ "multi-user.target" ];

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = generateMcpConfigScript user;
          };
        };
      })
      cfg.users);
  };
}
