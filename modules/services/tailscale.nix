{ config, pkgs, ... }:

{
  # Tailscale - Zero-config VPN for secure private networking
  services.tailscale = {
    enable = true;

    # Port for tunnel traffic
    port = 41641;

    # Interface name for the Tailscale network
    interfaceName = "tailscale0";

    # Enable client routing features (for using exit nodes, accepting routes)
    useRoutingFeatures = "client";

    # Open firewall for Tailscale UDP traffic
    openFirewall = true;

    # Declarative authentication with auth key from agenix
    authKeyFile = config.age.secrets.tailscale-auth-key.path;

    # Extra flags for 'tailscale up' command
    extraUpFlags = [
      "--ssh" # Enable Tailscale SSH
      "--accept-routes" # Accept subnet routes from other nodes
    ];
  };

  # Trust the Tailscale interface
  networking.firewall.trustedInterfaces = [ "tailscale0" ];

  systemd = {
    # Ensure tailscale directory exists with correct permissions
    tmpfiles.rules = [
      "d /var/lib/tailscale 0700 root root -"
    ];

    # Watchdog: restart tailscaled if its DNS proxy stops forwarding.
    # After an Ethernet link flap, Tailscale can lose its upstream resolver
    # config (Routes:{.:[]}) and never recover, returning SERVFAIL for all
    # non-Tailscale queries. This timer probes every 2 minutes and restarts
    # tailscaled after 3 consecutive failures (~4-6 min of DNS failure).
    services.tailscale-dns-watchdog = {
      description = "Tailscale DNS forwarding watchdog";
      after = [ "tailscaled.service" ];
      path = [ pkgs.dig pkgs.gnugrep ];
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "tailscale-dns-watchdog";
      };
      script = ''
        set -euo pipefail

        FAIL_COUNT_FILE="/var/lib/tailscale-dns-watchdog/fail-count"
        MAX_FAILURES=3

        # Skip if Tailscale DNS is not active (100.100.100.100 not in resolv.conf)
        if ! grep -q '100.100.100.100' /etc/resolv.conf 2>/dev/null; then
          rm -f "$FAIL_COUNT_FILE"
          exit 0
        fi

        # Probe an external domain through Tailscale's DNS proxy (expect IPv4 A record)
        dig_output=$(dig +short +timeout=5 +tries=1 @100.100.100.100 google.com A 2>&1) || true
        if echo "$dig_output" | grep -q '^[0-9]'; then
          rm -f "$FAIL_COUNT_FILE"
          exit 0
        fi

        # DNS probe failed — read and validate counter
        raw=$(cat "$FAIL_COUNT_FILE" 2>/dev/null || echo 0)
        if ! [[ "$raw" =~ ^[0-9]+$ ]]; then
          echo "tailscale-dns-watchdog: corrupt fail-count ('$raw'), resetting" >&2
          raw=0
        fi
        count=$((raw + 1))
        echo "$count" > "$FAIL_COUNT_FILE"

        if [ "$count" -ge "$MAX_FAILURES" ]; then
          echo "tailscale-dns-watchdog: $count consecutive DNS failures (dig output: '$dig_output'), restarting tailscaled"
          if systemctl restart tailscaled.service; then
            echo "tailscale-dns-watchdog: tailscaled restarted successfully"
            rm -f "$FAIL_COUNT_FILE"
          else
            echo "tailscale-dns-watchdog: ERROR - tailscaled restart failed" >&2
            exit 1
          fi
        else
          echo "tailscale-dns-watchdog: DNS probe failed ($count/$MAX_FAILURES)"
        fi
      '';
    };

    timers.tailscale-dns-watchdog = {
      description = "Run Tailscale DNS watchdog every 2 minutes";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "3min";
        OnUnitActiveSec = "2min";
      };
    };
  };
}
