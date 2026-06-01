# UniFi Network MCP Server
#
# This module provides the unifi-network-mcp server for AI-assisted network management.
# It wraps the Python package and provides two operational modes:
#
# 1. **stdio mode** (default): For Claude Code/Desktop integration via config file
#    - No systemd service runs
#    - Claude Code invokes the binary directly
#    - Configure in Claude Desktop's claude_desktop_config.json
#
# 2. **service mode**: Run as a persistent HTTP SSE server
#    - Useful for remote access or multiple clients
#    - Requires tailscaleServe.enable for HTTPS access
#
# Usage in host configuration:
#   services.unifi-mcp = {
#     enable = true;
#     host = "192.168.1.1";
#     username = "admin";
#     passwordFile = config.age.secrets.unifi-password.path;
#   };
#
# For Claude Code integration (stdio mode), add to ~/.config/claude/claude_desktop_config.json:
#   {
#     "mcpServers": {
#       "unifi": {
#         "command": "unifi-network-mcp",
#         "env": {
#           "UNIFI_HOST": "192.168.1.1",
#           "UNIFI_USERNAME": "admin",
#           "UNIFI_PASSWORD": "<your-password>",
#           "UNIFI_VERIFY_SSL": "false"
#         }
#       }
#     }
#   }

{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.unifi-mcp;

  # Python package for unifi-network-mcp
  unifiMcpPkg = pkgs.python313Packages.buildPythonApplication rec {
    pname = "unifi-network-mcp";
    version = "0.6.4";
    pyproject = true;

    src = pkgs.fetchFromGitHub {
      owner = "sirkirby";
      repo = "unifi-network-mcp";
      rev = "v${version}";
      hash = "sha256-BdcAw9r6JO0Gn4VWOTQmna5HUKoLWfgYEznQkP9E+3E=";
    };

    build-system = [ pkgs.python313Packages.hatchling ];

    dependencies = with pkgs.python313Packages; [
      aiounifi
      mcp
      httpx
      pydantic
      python-dotenv
    ];

    meta = {
      description = "MCP server for UniFi Network Controller";
      homepage = "https://github.com/sirkirby/unifi-network-mcp";
      license = licenses.mit;
    };
  };

  dockerImage = "ghcr.io/sirkirby/unifi-network-mcp:latest";

  portStr = toString cfg.port;
  ssePortStr = toString cfg.service.ssePort;
  httpsPortStr = toString cfg.tailscaleServe.httpsPort;

  # Base unifi MCP entry, WITHOUT the runtime-injected password.
  # - useDocker=true : command=docker, args=[run ... -e KEY=VAL ...]; the
  #   "-e UNIFI_PASSWORD=<pw>" pair AND the trailing image are appended at
  #   runtime by the oneshot (image must stay last for `docker run`).
  # - useDocker=false: command="unifi-network-mcp" (PATH; package added to
  #   systemPackages when !useDocker), env={...}; oneshot sets
  #   .env.UNIFI_PASSWORD at runtime.
  # command/env/args mirror the existing `unifi-mcp-config` print command.
  mkMcpConfigBase =
    if cfg.useDocker then {
      command = "${pkgs.docker}/bin/docker";
      args = [
        "run"
        "--rm"
        "-i"
        "-e"
        "UNIFI_HOST=${cfg.host}"
        "-e"
        "UNIFI_PORT=${portStr}"
        "-e"
        "UNIFI_USERNAME=${cfg.username}"
        "-e"
        "UNIFI_SITE=${cfg.site}"
        "-e"
        "UNIFI_VERIFY_SSL=${boolToString cfg.verifySsl}"
        "-e"
        "UNIFI_CONTROLLER_TYPE=${cfg.controllerType}"
        "-e"
        "UNIFI_TOOL_REGISTRATION=${cfg.toolRegistration}"
        # NOTE: "-e UNIFI_PASSWORD=<pw>" and the trailing ${dockerImage} are
        # appended at runtime by the oneshot. The -e flag order is irrelevant
        # to `docker run`; the image stays the last positional arg, so the
        # container env is identical to the print command (verified).
      ];
    } else {
      command = "unifi-network-mcp";
      env = {
        UNIFI_HOST = cfg.host;
        UNIFI_PORT = portStr;
        UNIFI_USERNAME = cfg.username;
        UNIFI_SITE = cfg.site;
        UNIFI_VERIFY_SSL = boolToString cfg.verifySsl;
        UNIFI_CONTROLLER_TYPE = cfg.controllerType;
        UNIFI_TOOL_REGISTRATION = cfg.toolRegistration;
        # UNIFI_PASSWORD is injected at runtime by the oneshot.
      };
    };

  # Per-user oneshot: read or initialise ~/.claude.json, inject UNIFI_PASSWORD
  # from cfg.passwordFile at runtime, then patch ONLY .mcpServers["unifi"]
  # (MERGE — preserves n8n-mcp, home-assistant, context7, ...). Hardened with
  # flock + atomic mktemp/mv, mirroring the n8n / home-assistant siblings.
  #
  # INDENTATION IS LOAD-BEARING: body lines are indented 8 spaces; the three
  # heredoc lines (`${builtins.toJSON mkMcpConfigBase}`, `MCPEOF`, `)`) are
  # indented exactly 4 spaces so that after Nix '' common-leading-whitespace
  # stripping `MCPEOF` lands at column 0 and closes the <<'MCPEOF' (non-<<-)
  # heredoc. Do NOT re-indent these three lines (nix fmt leaves '' bodies
  # alone, but re-verify after running it).
  generateMcpConfigScript = user: pkgs.writeShellScript "unifi-mcp-config-${user}" ''
        set -euo pipefail

        USER_HOME=$(eval echo "~${user}")
        CONFIG_FILE="$USER_HOME/.claude.json"

        # Serialize concurrent writers: this oneshot and the n8n /
        # home-assistant MCP oneshots all read-modify-write ~/.claude.json and
        # start in parallel under multi-user.target. Hold an exclusive lock for
        # the whole RMW so a reboot can't lose-update the file (drop an MCP
        # server) or read it truncated.
        exec 9>"$CONFIG_FILE.lock"
        ${pkgs.util-linux}/bin/flock 9

        # Read existing config or start with empty object. ~/.claude.json holds
        # user settings (tips, stats) AND mcpServers.
        if [ -f "$CONFIG_FILE" ]; then
          EXISTING_CONFIG=$(cat "$CONFIG_FILE")
          EXISTING_CONFIG=$(echo "$EXISTING_CONFIG" | ${pkgs.jq}/bin/jq 'if .mcpServers == null then .mcpServers = {} else . end')
        else
          EXISTING_CONFIG='{"mcpServers":{}}'
        fi

        # Base unifi entry (no password yet).
        UNIFI_MCP_CONFIG=$(cat <<'MCPEOF'
    ${builtins.toJSON mkMcpConfigBase}
    MCPEOF
    )

        # Inject the UniFi password at RUNTIME from the agenix secret. Never
        # baked into the nix store. Fail loudly if missing/empty (the entry
        # would be useless without it). passwordFile is a required types.path,
        # so it is unconditional (no optionalString wrapper, unlike the
        # nullable apiKeyFile/tokenFile of the siblings).
        if [ ! -f "${cfg.passwordFile}" ]; then
          echo "ERROR: UniFi password file not found: ${cfg.passwordFile}" >&2
          exit 1
        fi
        PASSWORD=$(cat "${cfg.passwordFile}")
        if [ -z "$PASSWORD" ]; then
          echo "ERROR: UniFi password file is empty: ${cfg.passwordFile}" >&2
          exit 1
        fi

        ${if cfg.useDocker then ''
          # Docker shape: append "-e UNIFI_PASSWORD=<pw>" then the image as the
          # final positional arg (image must stay last for `docker run`).
          UNIFI_MCP_CONFIG=$(echo "$UNIFI_MCP_CONFIG" | ${pkgs.jq}/bin/jq \
            --arg pw "$PASSWORD" --arg img "${dockerImage}" \
            '.args += ["-e", ("UNIFI_PASSWORD=" + $pw), $img]')
        '' else ''
          # Non-Docker shape: set .env.UNIFI_PASSWORD.
          UNIFI_MCP_CONFIG=$(echo "$UNIFI_MCP_CONFIG" | ${pkgs.jq}/bin/jq \
            --arg pw "$PASSWORD" '.env.UNIFI_PASSWORD = $pw')
        ''}

        # Merge into existing config (preserving other MCP servers), written
        # atomically (temp + mv) so an earlyoom kill mid-write can't truncate
        # ~/.claude.json. flock above serializes writers; mv makes the swap atomic.
        TMP=$(mktemp "$CONFIG_FILE.XXXXXX")
        echo "$EXISTING_CONFIG" | ${pkgs.jq}/bin/jq --argjson unifi "$UNIFI_MCP_CONFIG" '.mcpServers["unifi"] = $unifi' > "$TMP"
        chown "${user}:$(id -gn "${user}" 2>/dev/null || echo "${user}")" "$TMP"
        chmod 600 "$TMP"
        mv -f "$TMP" "$CONFIG_FILE"

        echo "unifi MCP configured for ${user} in $CONFIG_FILE"
  '';

in
{
  options.services.unifi-mcp = {
    enable = mkEnableOption "UniFi Network MCP server for AI-assisted network management";

    users = mkOption {
      type = types.listOf types.str;
      default = [ "nixos" ];
      example = [ "nixos" "root" ];
      description = ''
        List of users to configure the unifi MCP server for.
        For each user a per-user oneshot merges the `unifi` entry into
        ~/.claude.json (preserving other MCP servers like n8n-mcp,
        home-assistant, context7). Runs whenever services.unifi-mcp.enable is
        set (stdio mode for Claude Code), independent of service.enable
        (the HTTP/SSE mode).
      '';
    };

    package = mkOption {
      type = types.package;
      default = unifiMcpPkg;
      description = "The unifi-network-mcp package to use.";
    };

    # ===================
    # Connection Settings
    # ===================

    host = mkOption {
      type = types.str;
      example = "192.168.1.1";
      description = "UniFi controller hostname or IP address.";
    };

    port = mkOption {
      type = types.port;
      default = 443;
      description = "UniFi controller port.";
    };

    username = mkOption {
      type = types.str;
      default = "admin";
      description = "UniFi controller username.";
    };

    passwordFile = mkOption {
      type = types.path;
      example = "/run/secrets/unifi-password";
      description = ''
        Path to file containing the UniFi controller password.
        Use agenix for secret management.
      '';
    };

    site = mkOption {
      type = types.str;
      default = "default";
      description = "UniFi site name.";
    };

    verifySsl = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to verify SSL certificates.
        Set to false for self-signed certificates (common on UDM/Cloud Key).
      '';
    };

    controllerType = mkOption {
      type = types.enum [ "auto" "proxy" "direct" ];
      default = "auto";
      description = ''
        UniFi controller type detection mode:
        - auto: Automatically detect (recommended)
        - proxy: Use UniFi OS proxy API (UDM, UDM Pro, Cloud Key Gen2+)
        - direct: Use standard controller API (self-hosted, Cloud Key Gen1)
      '';
    };

    # ===================
    # Tool Registration
    # ===================

    toolRegistration = mkOption {
      type = types.enum [ "lazy" "eager" "meta-only" ];
      default = "lazy";
      description = ''
        Tool registration mode:
        - lazy (default): 3 meta-tools visible, others load on demand (~200 tokens)
        - eager: All 67+ tools registered immediately (~5,000 tokens)
        - meta-only: Only meta-tools, requires manual discovery
      '';
    };

    # ===================
    # Permissions
    # ===================

    permissions = {
      networksCreate = mkOption {
        type = types.bool;
        default = false;
        description = "Allow creating networks/VLANs (high-risk).";
      };

      networksUpdate = mkOption {
        type = types.bool;
        default = false;
        description = "Allow modifying networks/VLANs (high-risk).";
      };

      networksDelete = mkOption {
        type = types.bool;
        default = false;
        description = "Allow deleting networks/VLANs (high-risk).";
      };

      wlanCreate = mkOption {
        type = types.bool;
        default = false;
        description = "Allow creating WLANs (high-risk).";
      };

      wlanUpdate = mkOption {
        type = types.bool;
        default = false;
        description = "Allow modifying WLANs (high-risk).";
      };

      wlanDelete = mkOption {
        type = types.bool;
        default = false;
        description = "Allow deleting WLANs (high-risk).";
      };

      deviceReboot = mkOption {
        type = types.bool;
        default = false;
        description = "Allow rebooting devices.";
      };

      firewallManage = mkOption {
        type = types.bool;
        default = true;
        description = "Allow managing firewall rules.";
      };

      portForwardManage = mkOption {
        type = types.bool;
        default = true;
        description = "Allow managing port forwarding rules.";
      };

      trafficRouteManage = mkOption {
        type = types.bool;
        default = true;
        description = "Allow managing traffic routes.";
      };

      qosManage = mkOption {
        type = types.bool;
        default = true;
        description = "Allow managing QoS rules.";
      };
    };

    # ===================
    # Service Mode
    # ===================

    service = {
      enable = mkEnableOption "Run as a persistent HTTP SSE service (alternative to stdio mode)";

      ssePort = mkOption {
        type = types.port;
        default = 8765;
        description = "Port for HTTP SSE endpoint.";
      };
    };

    tailscaleServe = {
      enable = mkEnableOption "Tailscale Serve for HTTPS access (requires service.enable)";

      httpsPort = mkOption {
        type = types.port;
        default = 8765;
        description = "HTTPS port for Tailscale Serve.";
      };
    };

    # ===================
    # Docker Mode
    # ===================

    useDocker = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Use Docker container instead of native Python package.
        Docker is more reliable for complex Python dependencies.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.tailscaleServe.enable -> cfg.service.enable;
        message = "services.unifi-mcp.tailscaleServe.enable requires services.unifi-mcp.service.enable";
      }
    ];

    # Enable Docker only when running as a service in container mode
    # stdio mode uses the binary directly and never needs Docker
    virtualisation.docker.enable = mkIf (cfg.useDocker && (cfg.enable || cfg.service.enable)) true;

    # Generate environment file for both modes
    environment.etc."unifi-mcp/env.template".text = ''
      UNIFI_HOST=${cfg.host}
      UNIFI_PORT=${portStr}
      UNIFI_USERNAME=${cfg.username}
      UNIFI_SITE=${cfg.site}
      UNIFI_VERIFY_SSL=${boolToString cfg.verifySsl}
      UNIFI_CONTROLLER_TYPE=${cfg.controllerType}
      UNIFI_TOOL_REGISTRATION=${cfg.toolRegistration}
      UNIFI_PERMISSIONS_NETWORKS_CREATE=${boolToString cfg.permissions.networksCreate}
      UNIFI_PERMISSIONS_NETWORKS_UPDATE=${boolToString cfg.permissions.networksUpdate}
      UNIFI_PERMISSIONS_NETWORKS_DELETE=${boolToString cfg.permissions.networksDelete}
      UNIFI_PERMISSIONS_WLAN_CREATE=${boolToString cfg.permissions.wlanCreate}
      UNIFI_PERMISSIONS_WLAN_UPDATE=${boolToString cfg.permissions.wlanUpdate}
      UNIFI_PERMISSIONS_WLAN_DELETE=${boolToString cfg.permissions.wlanDelete}
      UNIFI_PERMISSIONS_DEVICE_REBOOT=${boolToString cfg.permissions.deviceReboot}
      UNIFI_PERMISSIONS_FIREWALL_MANAGE=${boolToString cfg.permissions.firewallManage}
      UNIFI_PERMISSIONS_PORT_FORWARD_MANAGE=${boolToString cfg.permissions.portForwardManage}
      UNIFI_PERMISSIONS_TRAFFIC_ROUTE_MANAGE=${boolToString cfg.permissions.trafficRouteManage}
      UNIFI_PERMISSIONS_QOS_MANAGE=${boolToString cfg.permissions.qosManage}
    '';

    systemd.services = mkMerge [
      {
        # Service mode: Run as persistent HTTP SSE server (UNCHANGED body).
        unifi-mcp = mkIf cfg.service.enable {
          description = "UniFi Network MCP Server (HTTP SSE mode)";
          after = [ "network-online.target" ] ++ lib.optionals cfg.useDocker [ "docker.service" ];
          wants = [ "network-online.target" ];
          requires = mkIf cfg.useDocker [ "docker.service" ];
          wantedBy = [ "multi-user.target" ];

          serviceConfig = {
            Type = "simple";
            Restart = "on-failure";
            RestartSec = 10;
            RuntimeDirectory = "unifi-mcp";
            RuntimeDirectoryMode = "0700";
            EnvironmentFile = "-/run/unifi-mcp/env";

            ExecStartPre = [
              ("+" + pkgs.writeShellScript "unifi-mcp-setup-env" ''
                set -euo pipefail

                ENV_FILE="/run/unifi-mcp/env"
                cp /etc/unifi-mcp/env.template "$ENV_FILE"

                # Add password from secret file
                if [[ ! -f "${cfg.passwordFile}" ]]; then
                  echo "ERROR: Password file not found: ${cfg.passwordFile}" >&2
                  exit 1
                fi
                PASSWORD=$(cat "${cfg.passwordFile}")
                if [[ -z "$PASSWORD" ]]; then
                  echo "ERROR: Password file is empty: ${cfg.passwordFile}" >&2
                  exit 1
                fi
                echo "UNIFI_PASSWORD=$PASSWORD" >> "$ENV_FILE"

                # Enable SSE mode
                echo "UNIFI_ENABLE_SSE=true" >> "$ENV_FILE"
                echo "UNIFI_SSE_PORT=${ssePortStr}" >> "$ENV_FILE"

                chmod 600 "$ENV_FILE"
              '')
            ];

            ExecStart =
              if cfg.useDocker then
                "${pkgs.docker}/bin/docker run --rm --name unifi-mcp --env-file /run/unifi-mcp/env -p 127.0.0.1:${ssePortStr}:${ssePortStr} ${dockerImage}"
              else
                "${cfg.package}/bin/unifi-network-mcp";

            ExecStop = mkIf cfg.useDocker "${pkgs.docker}/bin/docker stop unifi-mcp";
          };
        };

        # Tailscale Serve for HTTPS access (UNCHANGED body).
        tailscale-serve-unifi-mcp = mkIf (cfg.service.enable && cfg.tailscaleServe.enable) {
          description = "Configure Tailscale Serve for UniFi MCP HTTPS access";
          after = [
            "network-online.target"
            "tailscaled.service"
            "unifi-mcp.service"
          ];
          wants = [ "network-online.target" ];
          requires = [
            "tailscaled.service"
            "unifi-mcp.service"
          ];
          wantedBy = [ "multi-user.target" ];
          partOf = [ "unifi-mcp.service" ];

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };

          script = ''
            # Wait for tailscaled to be ready
            timeout=60
            while ! ${pkgs.tailscale}/bin/tailscale status &>/dev/null; do
              timeout=$((timeout - 1))
              if [ $timeout -le 0 ]; then
                echo "ERROR: tailscaled not ready after 60 seconds"
                exit 1
              fi
              sleep 1
            done

            # Wait for unifi-mcp to be listening
            timeout=60
            while ! ${pkgs.netcat}/bin/nc -z 127.0.0.1 ${ssePortStr} 2>/dev/null; do
              timeout=$((timeout - 1))
              if [ $timeout -le 0 ]; then
                echo "ERROR: unifi-mcp not listening on port ${ssePortStr} after 60 seconds"
                exit 1
              fi
              sleep 1
            done

            # Configure Tailscale Serve
            if ! ${pkgs.tailscale}/bin/tailscale serve status 2>/dev/null | grep -q "https:${httpsPortStr}"; then
              echo "Configuring Tailscale Serve for UniFi MCP..."
              ${pkgs.tailscale}/bin/tailscale serve --bg --https ${httpsPortStr} http://127.0.0.1:${ssePortStr}
            else
              echo "Tailscale Serve already configured for UniFi MCP"
            fi
          '';

          preStop = ''
            echo "Removing Tailscale Serve configuration for UniFi MCP..."
            ${pkgs.tailscale}/bin/tailscale serve --bg --https ${httpsPortStr} off || true
          '';
        };
      }

      # Self-healing per-user oneshot(s): re-merge the `unifi` entry into
      # ~/.claude.json on every boot/deploy (stdio mode for Claude Code). Runs on
      # cfg.enable, independent of cfg.service.enable (the HTTP/SSE mode).
      (listToAttrs (map
        (user: {
          name = "unifi-mcp-config-${user}";
          value = {
            description = "Configure unifi MCP for Claude Code (${user})";
            # agenix here is an activation script, not a real systemd unit; the
            # after entry is harmless and kept for parity with the n8n /
            # home-assistant MCP oneshots. Real ordering is multi-user.target.
            after = [ "network.target" "agenix.service" ];
            wantedBy = [ "multi-user.target" ];

            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = generateMcpConfigScript user;
            };
          };
        })
        cfg.users))
    ];

    # Helper script to generate Claude Code MCP config
    # Also include the package when not using Docker
    environment.systemPackages =
      (optional (!cfg.useDocker) cfg.package)
      ++ [
        (pkgs.writeShellScriptBin "unifi-mcp-config" ''
                  set -euo pipefail

                  if [[ ! -f "${cfg.passwordFile}" ]]; then
                    echo "ERROR: Password file not found. Cannot generate config." >&2
                    exit 1
                  fi

                  PASSWORD=$(cat "${cfg.passwordFile}")

                  cat <<EOF
          {
            "mcpServers": {
              "unifi": {
                "command": "${if cfg.useDocker then "${pkgs.docker}/bin/docker" else "unifi-network-mcp"}",
                ${if cfg.useDocker then ''
                "args": [
                  "run", "--rm", "-i",
                  "-e", "UNIFI_HOST=${cfg.host}",
                  "-e", "UNIFI_PORT=${portStr}",
                  "-e", "UNIFI_USERNAME=${cfg.username}",
                  "-e", "UNIFI_PASSWORD=$PASSWORD",
                  "-e", "UNIFI_SITE=${cfg.site}",
                  "-e", "UNIFI_VERIFY_SSL=${boolToString cfg.verifySsl}",
                  "-e", "UNIFI_CONTROLLER_TYPE=${cfg.controllerType}",
                  "-e", "UNIFI_TOOL_REGISTRATION=${cfg.toolRegistration}",
                  "${dockerImage}"
                ]
                '' else ''
                "env": {
                  "UNIFI_HOST": "${cfg.host}",
                  "UNIFI_PORT": "${portStr}",
                  "UNIFI_USERNAME": "${cfg.username}",
                  "UNIFI_PASSWORD": "$PASSWORD",
                  "UNIFI_SITE": "${cfg.site}",
                  "UNIFI_VERIFY_SSL": "${boolToString cfg.verifySsl}",
                  "UNIFI_CONTROLLER_TYPE": "${cfg.controllerType}",
                  "UNIFI_TOOL_REGISTRATION": "${cfg.toolRegistration}"
                }
                ''}
              }
            }
          }
          EOF
        '')
      ];
  };
}
