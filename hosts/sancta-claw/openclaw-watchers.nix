{ pkgs, ... }:

let
  # Extracted into a let-binding so the rendered body can be exposed via
  # `system.build.openclawHealthProbeBody` for the module-eval test
  # (mirrors openclawBrowserConfigBody / smokeTestBody — pure eval, no IFD).
  openclawHealthProbeBody = ''
    set -uo pipefail
    STATE_FILE="/var/lib/openclaw/.health-failures"
    ANNOUNCED_FILE="/var/lib/openclaw/.zdr-migration-announced"
    MAX_FAILURES=3
    OC_CONFIG="/var/lib/openclaw/.openclaw/openclaw.json"

    if curl -sf -o /dev/null --max-time 10 http://127.0.0.1:18789/healthz; then
      PREV_FAILURES=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
      echo 0 > "$STATE_FILE"

      # First-success Telegram alert after migration: fires once when the
      # gateway transitions from a failing state back to healthy AND the
      # one-shot announcement marker does not yet exist. Subsequent green
      # probes are silent. Marker is plain `touch` — survives reboots.
      if [ "$PREV_FAILURES" -gt 0 ] && [ ! -f "$ANNOUNCED_FILE" ]; then
        TOKEN=$(jq -r '.channels.telegram.token // empty' "$OC_CONFIG" 2>/dev/null || true)
        CHAT_ID=$(jq -r '.channels.telegram.chatId // "364749075"' "$OC_CONFIG" 2>/dev/null || echo 364749075)
        PRIMARY=$(jq -r '.agents.defaults.model.primary // "unknown"' "$OC_CONFIG" 2>/dev/null || echo unknown)
        # Only mark "announced" after a real send. If the Telegram token is
        # missing (config not yet imperative-injected), retry on the next
        # green probe rather than silencing forever.
        if [ -n "$TOKEN" ]; then
          curl -sf -X POST \
            "https://api.telegram.org/bot$TOKEN/sendMessage" \
            -d "chat_id=$CHAT_ID" \
            -d "text=✅ [sancta-claw] OpenClaw is healthy on free+ZDR ladder: primary=$PRIMARY" \
            --max-time 10 || true
          touch "$ANNOUNCED_FILE"
        fi
      fi
      exit 0
    fi

    FAILURES=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
    FAILURES=$((FAILURES + 1))
    echo "$FAILURES" > "$STATE_FILE"

    if [ "$FAILURES" -ge "$MAX_FAILURES" ]; then
      # Crash-loop detection: if we've restarted 3+ times in 30 minutes,
      # stop restarting and alert instead. Prevents infinite restart loops
      # when gateway crashes due to bad config (learned from PR #398 incident).
      RESTART_LOG_DIR="/var/lib/openclaw/.health-restarts"
      CRASH_LOOP_MAX=3
      CRASH_LOOP_WINDOW_MIN=30
      mkdir -p "$RESTART_LOG_DIR"

      # Count restarts within the window
      RECENT_RESTARTS=$(find "$RESTART_LOG_DIR" -maxdepth 1 -type f -mmin "-$CRASH_LOOP_WINDOW_MIN" 2>/dev/null | wc -l)

      NOW=$(date +%s)
      TOKEN=$(jq -r '.channels.telegram.token // empty' "$OC_CONFIG" 2>/dev/null || true)
      CHAT_ID=$(jq -r '.channels.telegram.chatId // "364749075"' "$OC_CONFIG" 2>/dev/null || echo 364749075)
      PRIMARY=$(jq -r '.agents.defaults.model.primary // "unknown"' "$OC_CONFIG" 2>/dev/null || echo unknown)

      if [ "$RECENT_RESTARTS" -ge "$CRASH_LOOP_MAX" ]; then
        echo "Crash loop detected ($RECENT_RESTARTS restarts in $CRASH_LOOP_WINDOW_MIN min). NOT restarting." >&2
        # Alert: manual intervention needed
        if [ -n "$TOKEN" ]; then
          curl -sf -X POST \
            "https://api.telegram.org/bot$TOKEN/sendMessage" \
            -d "chat_id=$CHAT_ID" \
            -d "text=🔴 OpenClaw crash loop detected ($RECENT_RESTARTS restarts in ''${CRASH_LOOP_WINDOW_MIN}min) on primary=$PRIMARY. Auto-restart STOPPED. Manual intervention needed." \
            --max-time 10 || true
        fi
        exit 1
      fi

      echo "Gateway unhealthy after $FAILURES consecutive checks, restarting..." >&2
      echo 0 > "$STATE_FILE"
      touch "$RESTART_LOG_DIR/$NOW"
      systemctl restart openclaw

      # Clean up old restart log entries (older than window)
      find "$RESTART_LOG_DIR" -maxdepth 1 -type f -mmin "+$CRASH_LOOP_WINDOW_MIN" -delete 2>/dev/null || true

      # Notify via Telegram
      if [ -n "$TOKEN" ]; then
        curl -sf -X POST \
          "https://api.telegram.org/bot$TOKEN/sendMessage" \
          -d "chat_id=$CHAT_ID" \
          -d "text=⚠️ OpenClaw gateway was unhealthy ($FAILURES consecutive failures) on primary=$PRIMARY. Auto-restarted. ($((RECENT_RESTARTS + 1))/$CRASH_LOOP_MAX before crash-loop lockout)" \
          --max-time 10 || true
      fi
    fi
  '';
in
{
  # Expose the rendered probe body so the module-eval test can grep for
  # the `.zdr-migration-announced` marker without IFD. Same approach as
  # system.build.openclawBrowserConfigBody / smokeTestBody.
  system.build.openclawHealthProbeBody = openclawHealthProbeBody;

  # ── Restart trigger (no sudo, no NoNewPrivileges change) ────────────────
  # Kuzea self-restart via file-based trigger:
  #   touch /var/lib/openclaw/restart-trigger
  # The path unit fires, the watcher service (root) deletes the file and
  # restarts openclaw. NoNewPrivileges=true on openclaw.service is preserved.
  systemd.paths.openclaw-restart-watcher = {
    description = "Watch for Kuzea self-restart trigger";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathExists = "/var/lib/openclaw/restart-trigger";
      Unit = "openclaw-restart-watcher.service";
    };
  };

  systemd.services.openclaw-restart-watcher = {
    description = "Restart openclaw service on agent request";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "openclaw-do-restart" ''
        rm -f /var/lib/openclaw/restart-trigger
        systemctl restart openclaw
      '';
    };
  };

  # ── NixOS rebuild trigger (no sudo needed) ──────────────────────────────
  # Kuzea can trigger a full nixos-rebuild switch by:
  #   touch /var/lib/openclaw/rebuild-trigger
  # The path unit fires, the service (root) pulls latest config and rebuilds.
  # This allows Kuzea to apply merged PRs without waiting for autoUpgrade.
  systemd.paths.nixos-rebuild-watcher = {
    description = "Watch for NixOS rebuild trigger";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathExists = "/var/lib/openclaw/rebuild-trigger";
      Unit = "nixos-rebuild-watcher.service";
    };
  };

  systemd.services.nixos-rebuild-watcher = {
    description = "Rebuild NixOS on agent request";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "nixos-do-rebuild" ''
        set -euo pipefail
        rm -f /var/lib/openclaw/rebuild-trigger

        # Pull latest config
        cd /var/lib/openclaw/nixos-config
        ${pkgs.git}/bin/git fetch origin main
        ${pkgs.git}/bin/git checkout main
        ${pkgs.git}/bin/git reset --hard origin/main

        # Rebuild (full path required — systemd services have minimal PATH)
        /run/current-system/sw/bin/nixos-rebuild switch --flake /var/lib/openclaw/nixos-config#sancta-claw 2>&1 | tee /var/lib/openclaw/rebuild.log

        # Notify Kuzea
        echo "$(date -Iseconds) rebuild completed" >> /var/lib/openclaw/rebuild.log
      '';
      TimeoutStartSec = "10min";
    };
  };

  # ── Gateway health check (auto-restart on degradation) ─────────────────
  systemd.timers.openclaw-health-check = {
    description = "OpenClaw gateway health probe timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "1min";
    };
  };

  systemd.services.openclaw-health-check = {
    description = "OpenClaw gateway health probe";
    after = [ "openclaw.service" ];
    path = [
      pkgs.curl
      pkgs.jq
      pkgs.coreutils
    ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "openclaw-health-probe" openclawHealthProbeBody;
    };
  };
}
