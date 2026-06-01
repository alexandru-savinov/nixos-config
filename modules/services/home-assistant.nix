{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.home-assistant-tailscale;
in
{
  options.services.home-assistant-tailscale = {
    enable = mkEnableOption "Home Assistant with Tailscale Serve";

    port = mkOption {
      type = types.port;
      default = 8123;
      description = "Port for Home Assistant to listen on (localhost only).";
    };

    timeZone = mkOption {
      type = types.str;
      default = "Europe/Bucharest";
      description = "IANA time zone for Home Assistant.";
    };

    secretsFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Path to an agenix-decrypted secrets.yaml. When set, a forced symlink
        is created at /var/lib/hass/secrets.yaml via systemd.tmpfiles "L+",
        keeping plaintext out of the nix store. Leave null until the agenix
        .age file actually exists in the repo (declaring an age.secrets entry
        for a missing .age file makes activation fail).
      '';
    };

    tailscaleServe = {
      enable = mkEnableOption "Tailscale Serve HTTPS front for Home Assistant";

      httpsPort = mkOption {
        type = types.port;
        default = 8123;
        description = "HTTPS port for Tailscale Serve to expose.";
      };
    };
  };

  config = mkIf cfg.enable {
    # Native Home Assistant module. We deliberately do NOT set
    # extraComponents / extraPackages / package / customComponents here:
    # keeping them at the module default guarantees a binary-cache hit and
    # avoids a large local aarch64 Python rebuild that can OOM the 4GB Pi.
    # Only `config` is set, which is a cheap YAML render.
    services.home-assistant = {
      enable = true;
      # Pin explicitly (defense-in-depth): never open 8123 to the network — access
      # is exclusively via the Tailscale Serve HTTPS proxy. Don't rely on the
      # upstream module default in case it ever changes.
      openFirewall = false;
      config = {
        homeassistant = {
          time_zone = cfg.timeZone;
        };

        default_config = { };

        # Reverse-proxy hardening: behind any reverse proxy HA returns 400
        # unless both use_x_forwarded_for and trusted_proxies are set.
        # Same-host tailscale serve presents loopback as the source.
        http = {
          server_host = [ "127.0.0.1" "::1" ];
          server_port = cfg.port;
          use_x_forwarded_for = true;
          trusted_proxies = [ "127.0.0.1" "::1" ];
        };

        # Recorder tuning for SQLite write load on the Pi.
        recorder = {
          purge_keep_days = 5;
          commit_interval = 30;
        };
      };
    };

    # Resource limits on the 4GB Pi.
    systemd.services.home-assistant.serviceConfig = {
      MemoryHigh = "768M";
      MemoryMax = "1G";
      CPUQuota = "150%";
      Nice = 7;
    };

    # Optional agenix-decrypted secrets.yaml — symlinked into /var/lib/hass
    # via tmpfiles L+ so plaintext stays out of the nix store. Gated on
    # secretsFile != null so absence does not break the build.
    systemd.tmpfiles.rules = mkIf (cfg.secretsFile != null) [
      "L+ /var/lib/hass/secrets.yaml - - - - ${cfg.secretsFile}"
    ];

    # Tailscale Serve oneshot — pattern copied from gatus.nix.
    systemd.services."tailscale-serve-home-assistant" = mkIf cfg.tailscaleServe.enable {
      description = "Configure Tailscale Serve for Home Assistant HTTPS access";
      after = [
        "network-online.target"
        "tailscaled.service"
        "home-assistant.service"
      ];
      wants = [ "network-online.target" ];
      requires = [
        "tailscaled.service"
        "home-assistant.service"
      ];
      wantedBy = [ "multi-user.target" ];
      # PartOf propagates home-assistant's STOP and RESTART to this oneshot, but
      # NOT a plain START. So home-assistant.service also `wants` this unit (added
      # below) — that restores the serve mapping on every HA start (boot, restart,
      # or start-after-stop), closing the gap where a stop→start left HTTPS dark
      # until a manual restart.
      partOf = [ "home-assistant.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        set -euo pipefail

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

        # Wait for home-assistant to be listening. HA's first cold boot on the
        # 4GB Pi (Python + default_config integrations) can exceed a minute, so
        # allow 180s — gatus's 60s is too tight for HA on this hardware.
        timeout=180
        while ! ${pkgs.netcat}/bin/nc -z 127.0.0.1 ${toString cfg.port} 2>/dev/null; do
          timeout=$((timeout - 1))
          if [ $timeout -le 0 ]; then
            echo "ERROR: home-assistant not listening on port ${toString cfg.port} after 180 seconds"
            exit 1
          fi
          sleep 1
        done

        # Idempotent: only configure if not already set for this port.
        if ! ${pkgs.tailscale}/bin/tailscale serve status 2>/dev/null | grep -qE "https?://.*:${toString cfg.tailscaleServe.httpsPort}( |$)"; then
          echo "Configuring Tailscale Serve for Home Assistant..."
          if ! ${pkgs.tailscale}/bin/tailscale serve --bg --https ${toString cfg.tailscaleServe.httpsPort} http://127.0.0.1:${toString cfg.port}; then
            echo "ERROR: Failed to configure Tailscale Serve for Home Assistant"
            exit 1
          fi
          echo "Tailscale Serve configured successfully"
        else
          echo "Tailscale Serve already configured for Home Assistant"
        fi
      '';

      preStop = ''
        echo "Removing Tailscale Serve configuration for Home Assistant..."
        ${pkgs.tailscale}/bin/tailscale serve --bg --https ${toString cfg.tailscaleServe.httpsPort} off || true
      '';
    };

    # Make HA's own start pull the serve oneshot (PartOf above only propagates
    # stop/restart, not start), so HTTPS is reconfigured on every HA start.
    systemd.services.home-assistant.wants =
      mkIf cfg.tailscaleServe.enable [ "tailscale-serve-home-assistant.service" ];

    # Access Home Assistant via Tailscale HTTPS:
    #   https://<hostname>.<tailnet>.ts.net:<tailscaleServe.httpsPort>
    # Service binds to 127.0.0.1 only - no direct network access possible.
  };
}
