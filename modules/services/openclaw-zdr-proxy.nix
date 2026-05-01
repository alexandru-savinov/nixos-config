# OpenClaw ZDR Proxy
#
# Local Flask sidecar proxy that enforces OpenRouter Zero Data Retention (ZDR)
# at every request. Sits between the OpenClaw agent and OpenRouter, injecting
# `provider.zdr = true` and validating the request model against a fail-closed
# allow-list fetched from `https://openrouter.ai/api/v1/endpoints/zdr`.
#
# Binds to 127.0.0.1 only — accessed by the local OpenClaw service. No
# Tailscale Serve, no firewall changes.

{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.openclaw-zdr-proxy;

  proxyPkg = import ./openclaw-zdr-proxy { inherit pkgs; };

  # Materialise the raw agenix key into an EnvironmentFile-compatible
  # `KEY=VALUE` line at /run/openclaw-zdr-proxy/env. The agenix file holds
  # the raw key (other consumers like n8n on rpi5 expect this format), so
  # the translation must happen at unit-start time.
  setupEnvScript = pkgs.writeShellScript "openclaw-zdr-proxy-setup-env" ''
    set -euo pipefail
    KEY_FILE="${cfg.apiKeyFile}"
    if [ ! -r "$KEY_FILE" ]; then
      echo "ERROR: OpenRouter API key file not readable: $KEY_FILE" >&2
      exit 1
    fi
    KEY="$(${pkgs.coreutils}/bin/tr -d '\n' < "$KEY_FILE")"
    if [ -z "$KEY" ]; then
      echo "ERROR: OpenRouter API key file is empty: $KEY_FILE" >&2
      exit 1
    fi
    umask 077
    ${pkgs.coreutils}/bin/install -m 0600 /dev/null /run/openclaw-zdr-proxy/env
    echo "OPENROUTER_API_KEY=$KEY" > /run/openclaw-zdr-proxy/env
  '';
in
{
  options.services.openclaw-zdr-proxy = {
    enable = mkEnableOption "OpenClaw ZDR enforcement proxy (local sidecar)";

    port = mkOption {
      type = types.port;
      default = 5780;
      description = "Localhost port the proxy listens on.";
    };

    apiKeyFile = mkOption {
      type = types.path;
      description = ''
        Path to a file containing the OpenRouter API key (raw value, no
        `KEY=` prefix). The unit's `ExecStartPre` translates it into a
        systemd `EnvironmentFile` at `/run/openclaw-zdr-proxy/env`.
        Typically `config.age.secrets.openrouter-api-key.path`.
      '';
    };

    upstreamUrl = mkOption {
      type = types.str;
      default = "https://openrouter.ai/api/v1";
      description = "OpenRouter API base URL the proxy forwards to.";
    };

    allowListCacheTtl = mkOption {
      type = types.int;
      default = 3600;
      description = ''
        Seconds to cache the ZDR allow-list before refreshing. The proxy
        fails closed: if upstream refresh fails AND cache is older than
        2 * this value, all requests return 503.
      '';
    };
  };

  config = mkIf cfg.enable {
    systemd.services.openclaw-zdr-proxy = {
      description = "OpenClaw ZDR enforcement proxy (OpenRouter sidecar)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      environment = {
        OPENCLAW_ZDR_PROXY_PORT = toString cfg.port;
        OPENCLAW_ZDR_UPSTREAM = cfg.upstreamUrl;
        OPENCLAW_ZDR_CACHE_TTL = toString cfg.allowListCacheTtl;
      };

      serviceConfig = {
        User = "openclaw";
        Group = "openclaw";
        RuntimeDirectory = "openclaw-zdr-proxy";
        RuntimeDirectoryMode = "0700";
        EnvironmentFile = "/run/openclaw-zdr-proxy/env";

        ExecStartPre = [ setupEnvScript ];
        ExecStart = "${proxyPkg}/bin/openclaw-zdr-proxy";

        Restart = "on-failure";
        RestartSec = 5;

        # Sandboxing — proxy is stateless and only needs outbound HTTPS
        # plus a localhost listener; everything else can be locked down.
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        ReadWritePaths = [ ];
      };
    };
  };
}
