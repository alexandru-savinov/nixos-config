{ pkgs, ... }:

{
  # ── Tailscale Serve for OpenClaw UI ─────────────────────────────────────
  systemd.services.openclaw-tailscale-serve = {
    description = "Tailscale Serve for OpenClaw UI";
    after = [
      "network-online.target"
      "tailscaled.service"
      "openclaw.service"
    ];
    wants = [ "network-online.target" ];
    requires = [
      "tailscaled.service"
      "openclaw.service"
    ];
    wantedBy = [ "multi-user.target" ];
    # PartOf propagates stop/restart of openclaw to this unit
    partOf = [ "openclaw.service" ];

    # Skip if openclaw binary not installed (ConditionPathExists on openclaw.service
    # causes it to be skipped, but a skipped unit still satisfies Requires=)
    unitConfig.ConditionPathExists = "/var/lib/openclaw/.npm-global/bin/openclaw";

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # Two sequential 60s wait loops = 120s max; default 90s would kill us
      TimeoutStartSec = 150;
      NoNewPrivileges = true;
    };

    script = ''
      # Wait for tailscaled to be ready (timeout: 60 seconds)
      ts_timeout=60
      while ! ${pkgs.tailscale}/bin/tailscale status &>/dev/null; do
        ts_timeout=$((ts_timeout - 1))
        if [ $ts_timeout -le 0 ]; then
          echo "ERROR: tailscaled not ready after 60 seconds"
          exit 1
        fi
        sleep 1
      done

      # Wait for OpenClaw to be listening (timeout: 60 seconds)
      # The 'after' directive only waits for service start, not port availability
      port_timeout=60
      while ! ${pkgs.netcat}/bin/nc -z 127.0.0.1 18789 2>/dev/null; do
        port_timeout=$((port_timeout - 1))
        if [ $port_timeout -le 0 ]; then
          echo "ERROR: OpenClaw not listening on port 18789 after 60 seconds"
          exit 1
        fi
        sleep 1
      done

      # Check if serve is already configured for this port
      if ! ${pkgs.tailscale}/bin/tailscale serve status 2>/dev/null | grep -q "https:18789"; then
        echo "Configuring Tailscale Serve for OpenClaw..."
        ${pkgs.tailscale}/bin/tailscale serve --bg --https 18789 http://127.0.0.1:18789
      else
        echo "Tailscale Serve already configured for OpenClaw"
      fi
    '';

    preStop = ''
      echo "Removing Tailscale Serve configuration for OpenClaw..."
      ${pkgs.tailscale}/bin/tailscale serve --https 18789 off || true
    '';
  };
}
