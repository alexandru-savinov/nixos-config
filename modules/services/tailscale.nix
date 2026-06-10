{ config
, lib
, pkgs
, ...
}:

let
  cfg = config.services.tailscale-dns-watchdog;
in
{
  options.services.tailscale-dns-watchdog = {
    telegramEnvFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Optional EnvironmentFile with TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID
        (same format as services.backup-pull.telegramEnvFile). When set, the
        watchdog alerts the operator once per outage when the crash-loop
        breaker opens (restarts stopped, manual intervention needed).
        When null, breaker events are journal-only.
      '';
    };
  };

  config = {
    # Tailscale - Zero-config VPN
    services.tailscale = {
      enable = true;
      useRoutingFeatures = "client";
      openFirewall = true;
      authKeyFile = config.age.secrets.tailscale-auth-key.path;
      extraUpFlags = [
        "--ssh"
        "--accept-routes"
      ];
    };

    # Trust the Tailscale interface
    networking.firewall.trustedInterfaces = [ "tailscale0" ];

    systemd = {
      # Watchdog: restart tailscaled if its DNS proxy stops forwarding.
      # After an Ethernet link flap, Tailscale can lose its upstream resolver
      # config (Routes:{.:[]}) and never recover, returning SERVFAIL for all
      # non-Tailscale queries. This timer probes every 2 minutes and restarts
      # tailscaled after 3 consecutive failures (~4-6 min of DNS failure).
      #
      # Crash-loop circuit breaker (#450): a fixed retry interval is not a
      # breaker — against a persistent failure the old logic restarted
      # tailscaled every ~6 min forever. Mirrors the openclaw health-probe
      # pattern (hosts/sancta-claw/openclaw-watchers.nix): restart markers in
      # the StateDirectory, counted over a sliding window via `find -mmin`;
      # after CRASH_LOOP_MAX restarts in the window it STOPS restarting,
      # alerts the operator once, and only re-arms when markers age out
      # (half-open) or a probe succeeds.
      services.tailscale-dns-watchdog = {
        description = "Tailscale DNS forwarding watchdog";
        after = [ "tailscaled.service" ];
        path = [
          pkgs.dig
          pkgs.gnugrep
          pkgs.curl
        ];
        serviceConfig = {
          Type = "oneshot";
          StateDirectory = "tailscale-dns-watchdog";
          EnvironmentFile = lib.mkIf (cfg.telegramEnvFile != null) cfg.telegramEnvFile;
        };
        script = ''
          set -euo pipefail

          STATE_DIR="/var/lib/tailscale-dns-watchdog"
          FAIL_COUNT_FILE="$STATE_DIR/fail-count"
          RESTART_LOG_DIR="$STATE_DIR/restarts"
          BREAKER_ALERTED_FILE="$STATE_DIR/breaker-alerted"
          MAX_FAILURES=3
          CRASH_LOOP_MAX=3
          CRASH_LOOP_WINDOW_MIN=30

          # Best-effort operator alert; journal-only when no Telegram env is
          # configured (services.tailscale-dns-watchdog.telegramEnvFile).
          alert() {
            echo "$1" >&2
            if [ -n "''${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "''${TELEGRAM_CHAT_ID:-}" ]; then
              curl -sf -X POST \
                "https://api.telegram.org/bot''${TELEGRAM_BOT_TOKEN}/sendMessage" \
                -d "chat_id=''${TELEGRAM_CHAT_ID}" \
                -d "text=$1" \
                --max-time 10 || true
            fi
          }

          # Skip if Tailscale DNS is not active (100.100.100.100 not in resolv.conf)
          if ! grep -q '100.100.100.100' /etc/resolv.conf 2>/dev/null; then
            rm -f "$FAIL_COUNT_FILE" "$BREAKER_ALERTED_FILE"
            exit 0
          fi

          # Probe an external domain through Tailscale's DNS proxy (expect IPv4 A record)
          dig_output=$(dig +short +timeout=5 +tries=1 @100.100.100.100 google.com A 2>&1) || true
          if echo "$dig_output" | grep -q '^[0-9]'; then
            rm -f "$FAIL_COUNT_FILE" "$BREAKER_ALERTED_FILE"
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

          if [ "$count" -lt "$MAX_FAILURES" ]; then
            echo "tailscale-dns-watchdog: DNS probe failed ($count/$MAX_FAILURES)"
            exit 0
          fi

          # Eligible for restart — consult the windowed circuit breaker first.
          mkdir -p "$RESTART_LOG_DIR"
          find "$RESTART_LOG_DIR" -maxdepth 1 -type f -mmin "+$CRASH_LOOP_WINDOW_MIN" -delete 2>/dev/null || true
          RECENT_RESTARTS=$(find "$RESTART_LOG_DIR" -maxdepth 1 -type f -mmin "-$CRASH_LOOP_WINDOW_MIN" 2>/dev/null | wc -l)

          if [ "$RECENT_RESTARTS" -ge "$CRASH_LOOP_MAX" ]; then
            echo "tailscale-dns-watchdog: crash loop detected ($RECENT_RESTARTS tailscaled restarts in $CRASH_LOOP_WINDOW_MIN min without DNS recovery). NOT restarting." >&2
            # Alert once per outage; marker clears on the next successful probe.
            if [ ! -f "$BREAKER_ALERTED_FILE" ]; then
              alert "🔴 [${config.networking.hostName}] tailscale-dns-watchdog: crash loop — $RECENT_RESTARTS tailscaled restarts in ''${CRASH_LOOP_WINDOW_MIN}min without DNS recovery. Auto-restart STOPPED. Manual intervention needed."
              touch "$BREAKER_ALERTED_FILE"
            fi
            exit 1
          fi

          echo "tailscale-dns-watchdog: $count consecutive DNS failures (dig output: '$dig_output'), restarting tailscaled ($((RECENT_RESTARTS + 1))/$CRASH_LOOP_MAX in window before breaker opens)"
          # %N: marker names must be unique even for restarts within the same
          # second, or colliding names undercount the window (breaker never opens)
          touch "$RESTART_LOG_DIR/$(date +%s%N)"
          if systemctl restart tailscaled.service; then
            echo "tailscale-dns-watchdog: tailscaled restarted successfully"
            rm -f "$FAIL_COUNT_FILE"
          else
            echo "tailscale-dns-watchdog: ERROR - tailscaled restart failed" >&2
            exit 1
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
  };
}
