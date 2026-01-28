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
    version = "1.5.0";
    pyproject = true;

    src = pkgs.fetchFromGitHub {
      owner = "sirkirby";
      repo = "unifi-network-mcp";
      rev = "v${version}";
      hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; # Will need to update
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
      license = lib.licenses.mit;
    };
  };

  # Docker image for simpler deployment
  dockerImage = "ghcr.io/sirkirby/unifi-network-mcp:latest";
in
{
  options.services.unifi-mcp = {
    enable = mkEnableOption "UniFi Network MCP server for AI-assisted network management";

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

    # Enable Docker if using container mode
    virtualisation.docker.enable = mkIf cfg.useDocker true;

    # Generate environment file for both modes
    environment.etc."unifi-mcp/env.template".text = ''
      UNIFI_HOST=${cfg.host}
      UNIFI_PORT=${toString cfg.port}
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

    # Service mode: Run as persistent HTTP SSE server
    systemd.services.unifi-mcp = mkIf cfg.service.enable {
      description = "UniFi Network MCP Server (HTTP SSE mode)";
      after = [ "network-online.target" "docker.service" ];
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
            echo "UNIFI_SSE_PORT=${toString cfg.service.ssePort}" >> "$ENV_FILE"

            chmod 600 "$ENV_FILE"
          '')
        ];

        ExecStart = mkIf cfg.useDocker
          "${pkgs.docker}/bin/docker run --rm --name unifi-mcp --env-file /run/unifi-mcp/env -p 127.0.0.1:${toString cfg.service.ssePort}:${toString cfg.service.ssePort} ${dockerImage}";

        ExecStop = mkIf cfg.useDocker "${pkgs.docker}/bin/docker stop unifi-mcp";
      };
    };

    # Tailscale Serve for HTTPS access
    systemd.services.tailscale-serve-unifi-mcp = mkIf (cfg.service.enable && cfg.tailscaleServe.enable) {
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
      # PartOf ensures this service restarts when unifi-mcp restarts
      # Without this, Requires= only stops this service but doesn't restart it
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
        while ! ${pkgs.netcat}/bin/nc -z 127.0.0.1 ${toString cfg.service.ssePort} 2>/dev/null; do
          timeout=$((timeout - 1))
          if [ $timeout -le 0 ]; then
            echo "ERROR: unifi-mcp not listening on port ${toString cfg.service.ssePort} after 60 seconds"
            exit 1
          fi
          sleep 1
        done

        # Configure Tailscale Serve
        if ! ${pkgs.tailscale}/bin/tailscale serve status 2>/dev/null | grep -q "https:${toString cfg.tailscaleServe.httpsPort}"; then
          echo "Configuring Tailscale Serve for UniFi MCP..."
          ${pkgs.tailscale}/bin/tailscale serve --bg --https ${toString cfg.tailscaleServe.httpsPort} http://127.0.0.1:${toString cfg.service.ssePort}
        else
          echo "Tailscale Serve already configured for UniFi MCP"
        fi
      '';

      preStop = ''
        echo "Removing Tailscale Serve configuration for UniFi MCP..."
        ${pkgs.tailscale}/bin/tailscale serve --bg --https ${toString cfg.tailscaleServe.httpsPort} off || true
      '';
    };

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
                  "-e", "UNIFI_PORT=${toString cfg.port}",
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
                  "UNIFI_PORT": "${toString cfg.port}",
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
