# OpenClaw ZDR Proxy
#
# Local Flask sidecar proxy that enforces OpenRouter Zero Data Retention (ZDR)
# at every request. Sits between the OpenClaw agent and OpenRouter, injecting
# `provider.zdr = true` and validating the request model against a fail-closed
# allow-list fetched from `https://openrouter.ai/api/v1/endpoints/zdr`.
#
# Binds to 127.0.0.1 only — accessed by the local OpenClaw service. No
# Tailscale Serve, no firewall changes.
#
# This file declares the option surface and import hook only. The systemd
# unit and Flask implementation are added in subsequent tasks.

{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.openclaw-zdr-proxy;
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
        Path to a file containing the OpenRouter API key as
        `OPENROUTER_API_KEY=sk-...`. Loaded via systemd `EnvironmentFile`.
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

  config = mkIf cfg.enable { };
}
