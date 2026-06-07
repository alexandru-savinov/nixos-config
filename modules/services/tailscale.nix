{ config, pkgs, ... }:

let
  # Optional Telegram alert secret. Only rpi5 / rpi5-full wire
  # backup-telegram-env (secrets/secrets.nix); on every other host that imports
  # this module the path is simply absent and the watchdog degrades to a
  # journald(err) line plus a failed systemd unit as the operator signal — no
  # secret dependency is introduced fleet-wide.
  telegramEnvFile = "/run/agenix/backup-telegram-env";

  # Extracted into a let-binding so the rendered body can be exposed via
  # `system.build.tailscaleDnsWatchdogBody` for the module-eval test (pure
  # eval, no IFD) — mirrors hosts/sancta-claw/openclaw-watchers.nix.
  tailscaleDnsWatchdogBody = ''
    set -euo pipefail

    STATE_DIR="/var/lib/tailscale-dns-watchdog"
    FAIL_COUNT_FILE="$STATE_DIR/fail-count"
    RESTART_LOG_DIR="$STATE_DIR/restarts"
    MAX_FAILURES=3

    # Windowed circuit breaker. A fixed retry cadence is NOT a breaker: a
    # persistent DNS fault would otherwise restart tailscaled every ~6 min
    # forever with no upper bound (the failure mode learned fleet-wide from the
    # PR #398 openclaw incident, #450). Never restart more than CRASH_LOOP_MAX
    # times within CRASH_LOOP_WINDOW_MIN; then stop + alert until the markers
    # age out, after which restarts auto-resume.
    CRASH_LOOP_MAX=3
    CRASH_LOOP_WINDOW_MIN=30
    HOST="${config.networking.hostName}"

    mkdir -p "$RESTART_LOG_DIR"

    send_alert() {
      # Always log at err priority (systemd <3> prefix) so the message surfaces
      # in `journalctl -p err`; best-effort Telegram if this host carries the
      # optional backup-telegram-env secret. The hard, fleet-wide operator
      # signal is the unit entering `failed` (the exit 1 at each call site).
      echo "<3>tailscale-dns-watchdog: $1" >&2
      if [ -r "${telegramEnvFile}" ]; then
        (
          set +u
          . "${telegramEnvFile}"
          if [ -n "''${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "''${TELEGRAM_CHAT_ID:-}" ]; then
            curl -sf --max-time 10 -X POST \
              "https://api.telegram.org/bot''${TELEGRAM_BOT_TOKEN}/sendMessage" \
              -d "chat_id=''${TELEGRAM_CHAT_ID}" \
              -d "text=$1" >/dev/null || true
          fi
        )
      fi
    }

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

    # DNS probe failed — read and validate the consecutive-failure counter
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

    # Reached the restart threshold. Apply the windowed circuit breaker BEFORE
    # restarting: count restart markers dropped within the window.
    recent_restarts=$(find "$RESTART_LOG_DIR" -maxdepth 1 -type f -mmin "-$CRASH_LOOP_WINDOW_MIN" 2>/dev/null | wc -l)

    if [ "$recent_restarts" -ge "$CRASH_LOOP_MAX" ]; then
      # Crash loop: restarting is not restoring DNS. Stop restarting and alert.
      # `exit 1` fails the unit so the lockout is visible (systemctl --failed /
      # gatus). Markers age out after the window, then restarts auto-resume.
      send_alert "🔴 [$HOST] tailscaled DNS watchdog crash loop: $recent_restarts restarts in ''${CRASH_LOOP_WINDOW_MIN}min did not restore DNS. Auto-restart STOPPED — manual intervention needed. (dig: $dig_output)"
      exit 1
    fi

    # Under the cap — restart tailscaled, record the restart marker, reset the
    # consecutive-failure counter, and prune markers older than the window.
    echo "tailscale-dns-watchdog: $count consecutive DNS failures (dig output: '$dig_output'), restarting tailscaled ($((recent_restarts + 1))/$CRASH_LOOP_MAX before crash-loop lockout)"
    now=$(date +%s)
    if systemctl restart tailscaled.service; then
      echo "tailscale-dns-watchdog: tailscaled restarted successfully"
      rm -f "$FAIL_COUNT_FILE"
      touch "$RESTART_LOG_DIR/$now"
      find "$RESTART_LOG_DIR" -maxdepth 1 -type f -mmin "+$CRASH_LOOP_WINDOW_MIN" -delete 2>/dev/null || true
    else
      send_alert "⚠️ [$HOST] tailscaled restart FAILED after $count consecutive DNS probe failures. (dig: $dig_output)"
      exit 1
    fi
  '';
in
{
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
    # tailscaled after 3 consecutive failures (~4-6 min of DNS failure), bounded
    # by a windowed crash-loop breaker (see the script) so a persistent fault
    # cannot trigger an unbounded restart loop.
    services.tailscale-dns-watchdog = {
      description = "Tailscale DNS forwarding watchdog";
      after = [ "tailscaled.service" ];
      path = [
        pkgs.dig
        pkgs.gnugrep
        pkgs.coreutils
        pkgs.findutils
        pkgs.curl
      ];
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "tailscale-dns-watchdog";
      };
      script = tailscaleDnsWatchdogBody;
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

  # Expose the rendered watchdog body so the module-eval test can grep for the
  # crash-loop breaker without IFD (mirrors system.build.openclawHealthProbeBody).
  system.build.tailscaleDnsWatchdogBody = tailscaleDnsWatchdogBody;
}
