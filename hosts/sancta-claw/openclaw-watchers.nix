{ pkgs, ... }:

{
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
      ExecStart = pkgs.writeShellScript "openclaw-health-probe" ''
        set -uo pipefail
        STATE_FILE="/var/lib/openclaw/.health-failures"
        MAX_FAILURES=3
        OC_CONFIG="/var/lib/openclaw/.openclaw/openclaw.json"

        if curl -sf -o /dev/null --max-time 10 http://127.0.0.1:18789/healthz; then
          echo 0 > "$STATE_FILE"
          exit 0
        fi

        FAILURES=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
        FAILURES=$((FAILURES + 1))
        echo "$FAILURES" > "$STATE_FILE"

        if [ "$FAILURES" -ge "$MAX_FAILURES" ]; then
          echo "Gateway unhealthy after $FAILURES consecutive checks, restarting..." >&2
          echo 0 > "$STATE_FILE"
          systemctl restart openclaw

          # Notify via Telegram — read bot token from openclaw.json (always present).
          TOKEN=$(jq -r '.channels.telegram.token // empty' "$OC_CONFIG" 2>/dev/null || true)
          CHAT_ID=$(jq -r '.channels.telegram.chatId // "364749075"' "$OC_CONFIG" 2>/dev/null || echo 364749075)
          if [ -n "$TOKEN" ]; then
            curl -sf -X POST \
              "https://api.telegram.org/bot$TOKEN/sendMessage" \
              -d "chat_id=$CHAT_ID" \
              -d "text=⚠️ OpenClaw gateway was unhealthy ($FAILURES consecutive failures). Auto-restarted." \
              --max-time 10 || true
          fi
        fi
      '';
    };
  };
}
