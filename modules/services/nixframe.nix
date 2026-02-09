# NixFrame — Digital Photo Frame for Raspberry Pi 5
#
# Displays a rotating slideshow on HDMI-A-2 with a clock/date sidebar.
# Photos are uploaded via n8n webhook (mobile-friendly web form).
#
# Components:
#   getty auto-login (VT 7) → Sway compositor → imv slideshow + Eww sidebar
#   n8n webhooks → validate → convert → atomic save → systemd.paths reload
#
# Display isolation:
#   VT 1: root auto-login + btop (plain console, output depends on fbcon)
#   VT 7: nixframe auto-login + Sway (configured to target HDMI-A-2 only)
#   Sway takes GPU control when VT 7 is active, returns it on VT switch.
#
# Usage in host configuration:
#   services.nixframe.enable = true;
#   # All defaults match RPi5 + Samsung 4K TV on HDMI-A-2
#
# Access upload form via Tailscale HTTPS:
#   https://rpi5.tail4249a9.ts.net:5678/webhook/nixframe-ui

{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.nixframe;
  weatherCfg = cfg.weather;

  # Width of forecast bar = display width minus sidebar, so it doesn't render under the sidebar
  forecastWidth =
    let
      parts = lib.splitString "x" cfg.resolution;
    in
    lib.toInt (builtins.head parts) - cfg.sidebarWidth;

  # Forecast script — fetches wttr.in JSON, caches it, outputs one field.
  # Called as: nixframe-forecast-slot <slot-index> <field>
  # Fields: label, temp, desc, feels
  forecastScript = pkgs.writeShellScript "nixframe-forecast-slot" ''
    set -euo pipefail

    # Slot definitions: wttr.in hourly[] indices for 06,12,15,18,21
    SLOTS=(2 4 5 6 7)
    LABELS=("Morning" "Midday" "Afternoon" "Evening" "Night")

    SLOT_IDX="''${1:-0}"
    FIELD="''${2:-label}"
    if [ "$SLOT_IDX" -lt 0 ] || [ "$SLOT_IDX" -gt 4 ]; then
      echo "Error: slot index must be 0-4" >&2
      exit 1
    fi

    # Fallback values for when cache is missing or entry is null.
    # Space " " (not empty "") prevents GTK 0-height label under `all: unset` CSS.
    fallback_value() {
      case "$FIELD" in
        label) echo "''${LABELS[$SLOT_IDX]}" ;;
        temp)  echo "--" ;;
        desc)  echo "No data" ;;
        feels) echo " " ;;
        *)     echo "Error: unknown field '$FIELD'" >&2; exit 1 ;;
      esac
    }

    # After 18:00, show tomorrow's forecast instead of today's.
    # wttr.in returns .weather[0]=today, .weather[1]=tomorrow
    HOUR=$(${pkgs.coreutils}/bin/date +%-H)
    if [ "$HOUR" -ge 18 ]; then
      DAY_IDX=1
      # Get tomorrow's short day name for labels (e.g. "Mon")
      TOMORROW=$(${pkgs.coreutils}/bin/date -d '+1 day' +%a)
    else
      DAY_IDX=0
      TOMORROW=""
    fi

    CACHE_DIR="/var/lib/nixframe/.cache"
    CACHE="$CACHE_DIR/weather-full.json"
    mkdir -p "$CACHE_DIR"

    # Fetch if cache missing or >30min old
    # Use flock to prevent concurrent fetches (all 20 defpolls fire at once on startup)
    # and atomic mv to prevent partial reads.
    # stat can fail if the file is deleted between -f check and stat call (TOCTOU);
    # default to 0 so the fetch proceeds.
    CACHE_AGE=$(${pkgs.coreutils}/bin/stat -c %Y "$CACHE" 2>/dev/null || echo 0)
    NOW=$(${pkgs.coreutils}/bin/date +%s)
    if [ "$CACHE_AGE" -eq 0 ] || [ $(( NOW - CACHE_AGE )) -gt 1800 ]; then
      (
        ${pkgs.util-linux}/bin/flock -n 9 || exit 0  # Another slot is already fetching
        # Re-check after acquiring lock (another process may have just written)
        CACHE_AGE2=$(${pkgs.coreutils}/bin/stat -c %Y "$CACHE" 2>/dev/null || echo 0)
        NOW2=$(${pkgs.coreutils}/bin/date +%s)
        if [ "$CACHE_AGE2" -eq 0 ] || [ $(( NOW2 - CACHE_AGE2 )) -gt 1800 ]; then
          TMP="$CACHE_DIR/.weather-full.tmp.$$"
          trap 'rm -f "$TMP"' EXIT
          RESPONSE=$(${pkgs.curl}/bin/curl -sf --max-time 10 'https://wttr.in/${weatherCfg.location}?format=j1' 2>&1 || true)
          if echo "$RESPONSE" | ${pkgs.jq}/bin/jq -e '.weather' >/dev/null 2>&1; then
            echo "$RESPONSE" > "$TMP"
            ${pkgs.coreutils}/bin/mv -f "$TMP" "$CACHE"
          elif [ -n "$RESPONSE" ]; then
            echo "WARNING: wttr.in returned invalid data: ''${RESPONSE:0:200}" >&2
          else
            echo "WARNING: wttr.in fetch failed (network error or timeout)" >&2
          fi
        fi
      ) 9>"$CACHE_DIR/.weather.lock"
    fi

    # "day" field doesn't need cache — just returns the context label
    if [ "$FIELD" = "day" ]; then
      if [ "$DAY_IDX" -eq 1 ]; then
        echo "Tomorrow, $TOMORROW"
      else
        echo "Today"
      fi
      exit 0
    fi

    if [ ! -f "$CACHE" ]; then
      fallback_value
      exit 0
    fi

    IDX=''${SLOTS[$SLOT_IDX]}
    ENTRY=$(${pkgs.jq}/bin/jq -r ".weather[$DAY_IDX].hourly[$IDX] // empty" "$CACHE")

    # Guard against null/missing entries (e.g. tomorrow's data not yet available)
    if [ -z "$ENTRY" ] || [ "$ENTRY" = "null" ]; then
      fallback_value
      exit 0
    fi

    case "$FIELD" in
      label) echo "''${LABELS[$SLOT_IDX]}" ;;
      temp)  echo "$(echo "$ENTRY" | ${pkgs.jq}/bin/jq -r '.tempC // "--"')°C" ;;
      desc)  echo "$(echo "$ENTRY" | ${pkgs.jq}/bin/jq -r '.weatherDesc[0].value // "No data"')" ;;
      feels) echo "Feels $(echo "$ENTRY" | ${pkgs.jq}/bin/jq -r '.FeelsLikeC // "--"')°C" ;;
      *)     echo "Error: unknown field '$FIELD'" >&2; exit 1 ;;
    esac
  '';

  # Placeholder SVG for when no photos exist yet
  placeholderImage = pkgs.writeText "nixframe-placeholder.svg" ''
    <svg xmlns="http://www.w3.org/2000/svg" width="1920" height="1080" viewBox="0 0 1920 1080">
      <rect width="1920" height="1080" fill="#1a1a2e"/>
      <text x="960" y="480" text-anchor="middle" font-family="sans-serif"
            font-size="64" fill="#e0e0e0">NixFrame</text>
      <text x="960" y="560" text-anchor="middle" font-family="sans-serif"
            font-size="32" fill="#888">Upload photos to get started</text>
      <text x="960" y="620" text-anchor="middle" font-family="monospace"
            font-size="24" fill="#667eea">https://rpi5.tail4249a9.ts.net:5678/webhook/nixframe-ui</text>
    </svg>
  '';

  # Convert placeholder SVG to PNG at build time
  placeholderPng = pkgs.runCommand "nixframe-placeholder.png"
    {
      nativeBuildInputs = [ pkgs.imagemagick ];
    } ''
    convert ${placeholderImage} -resize 1920x1080 $out
  '';

  # Forecast slot definitions — single source of truth for labels and initial values.
  # Used to generate both defpoll declarations and widget boxes in ewwYuck.
  forecastSlots = [
    { idx = 0; label = "Morning"; }
    { idx = 1; label = "Midday"; }
    { idx = 2; label = "Afternoon"; }
    { idx = 3; label = "Evening"; }
    { idx = 4; label = "Night"; }
  ];

  mkDefpoll = name: initial: cmd:
    ''(defpoll ${name} :interval "300s" :initial "${initial}" "${cmd}")'';

  # Generated defpoll declarations for all forecast variables.
  # :initial values prevent GTK 0-height label bug under `all: unset` CSS.
  forecastDefpolls = concatStringsSep "\n" (
    [ (mkDefpoll "forecast-day" "Today" "${forecastScript} 0 day") ]
    ++ concatMap (slot: [
      (mkDefpoll "forecast-${toString slot.idx}-label" slot.label "${forecastScript} ${toString slot.idx} label")
      (mkDefpoll "forecast-${toString slot.idx}-temp" "--" "${forecastScript} ${toString slot.idx} temp")
      (mkDefpoll "forecast-${toString slot.idx}-desc" " " "${forecastScript} ${toString slot.idx} desc")
      (mkDefpoll "forecast-${toString slot.idx}-feels" " " "${forecastScript} ${toString slot.idx} feels")
    ]) forecastSlots
  );

  # Generated widget boxes for each forecast time slot
  forecastSlotWidgets = concatMapStringsSep "\n    " (slot:
    let i = toString slot.idx; in
    ''(box :class "forecast-slot" :orientation "v" :spacing 4
      (label :class "forecast-label" :text forecast-${i}-label)
      (label :class "forecast-temp"  :text forecast-${i}-temp)
      (label :class "forecast-desc"  :text forecast-${i}-desc)
      (label :class "forecast-feels" :text forecast-${i}-feels))''
  ) forecastSlots;

  # Eww widget definition (yuck)
  ewwYuck = pkgs.writeText "eww-nixframe.yuck" ''
    (defpoll clock-time :interval "1s" "date +%H:%M")
    (defpoll clock-date :interval "60s" "date '+%A, %B %-d'")

    (defwindow sidebar
      :monitor 0
      :geometry (geometry :width "${toString cfg.sidebarWidth}px" :height "100%" :anchor "center right")
      :stacking "fg"
      :exclusive true
      :focusable false
      (box :class "sidebar" :orientation "v" :valign "center" :space-evenly false :spacing 20
        (label :class "clock" :text clock-time)
        (label :class "date"  :text clock-date)))

    ${optionalString weatherCfg.enable ''
    ${forecastDefpolls}

    (defwindow forecast
      :monitor 0
      :geometry (geometry :width "${toString forecastWidth}px" :height "${toString weatherCfg.forecastHeight}px" :anchor "bottom center")
      :stacking "fg"
      :exclusive true
      :focusable false
      (box :class "forecast-bar" :orientation "h" :halign "fill" :space-evenly false
        (box :class "forecast-day-box" :orientation "v" :valign "center"
          (label :class "forecast-day" :text forecast-day))
        (box :orientation "h" :halign "fill" :space-evenly true :hexpand true
        ${forecastSlotWidgets})))
    ''}
  '';

  # Eww styling (scss)
  ewwScss = pkgs.writeText "eww-nixframe.scss" ''
    * {
      all: unset;
      font-family: "Noto Sans", sans-serif;
    }

    .sidebar {
      background-color: rgba(0, 0, 0, 0.75);
      padding: 40px;
    }

    .clock {
      font-size: 200px;
      font-weight: 700;
      color: #ffffff;
    }

    .date {
      font-size: 60px;
      font-weight: 400;
      color: #cccccc;
    }

    ${optionalString weatherCfg.enable ''
    .forecast-bar {
      background-color: rgba(0, 0, 0, 0.90);
      padding: 16px 40px;
    }

    .forecast-slot {
      padding: 6px 38px;
      border-left: 2px solid rgba(196, 168, 130, 0.25);
    }

    .forecast-slot:first-child {
      border-left: none;
    }

    .forecast-day-box {
      padding: 0 24px 0 0;
    }

    .forecast-day {
      font-size: 28px;
      font-weight: 600;
      color: #c4a882;
      letter-spacing: 2px;
      padding-left: 38px;
    }

    .forecast-label {
      font-size: 30px;
      font-weight: 500;
      color: #a89478;
      letter-spacing: 1px;
    }

    .forecast-temp {
      font-size: 64px;
      font-weight: 700;
      color: #eba63c;
      margin-top: 2px;
    }

    .forecast-desc {
      font-size: 30px;
      color: #ecdcc8;
      margin-top: 2px;
    }

    .forecast-feels {
      font-size: 36px;
      font-weight: 500;
      color: #b89070;
      margin-top: 4px;
    }
    ''}
  '';

  # imv wrapper script — starts slideshow with crash backoff
  imvStart = pkgs.writeShellScript "nixframe-imv-start" ''
    # Ensure only one imv-start instance runs at a time.
    # If an old script from a prior sway session holds the lock, kill its imv
    # and wait for it to exit (the swaymsg check will make it exit on next loop).
    LOCKFILE="/run/user/$(id -u)/.imv-start.lock"
    exec 8>"$LOCKFILE"
    if ! ${pkgs.util-linux}/bin/flock -n 8; then
      echo "Lock held by old imv-start, killing stale imv to reclaim..." >&2
      ${pkgs.procps}/bin/pkill -u "$(id -u)" imv-wayland 2>/dev/null || true
      sleep 3
      if ! ${pkgs.util-linux}/bin/flock -n 8; then
        echo "FATAL: Still locked after kill, cannot start imv." >&2
        exit 1
      fi
    fi

    PHOTO_DIR="${cfg.photoDir}"

    # Ensure placeholder exists if no photos uploaded yet
    if [ -z "$(ls -A "$PHOTO_DIR"/*.jpg "$PHOTO_DIR"/*.jpeg "$PHOTO_DIR"/*.png "$PHOTO_DIR"/*.webp 2>/dev/null)" ]; then
      if ! cp ${placeholderPng} "$PHOTO_DIR/000-placeholder.png"; then
        echo "ERROR: Failed to copy placeholder image to $PHOTO_DIR" >&2
      fi
    fi

    # Start imv as tiled window (NOT fullscreen — respects Eww exclusive zone)
    # Crash backoff: if imv crashes rapidly 5 times, stop to avoid CPU burn
    FAIL_COUNT=0
    MAX_FAILS=5
    while true; do
      # Exit if Sway is gone. Use swaymsg instead of checking socket file
      # existence, because stale sway sockets persist after sway exits.
      # Timeout prevents hang if sway is stuck (e.g. GPU deadlock).
      if [ -n "$SWAYSOCK" ] && ! ${pkgs.coreutils}/bin/timeout 5 ${pkgs.sway}/bin/swaymsg -t get_version >/dev/null 2>&1; then
        echo "Sway not responding ($SWAYSOCK), exiting." >&2
        exit 0
      fi

      START_TIME=$(date +%s)
      ${pkgs.imv}/bin/imv -t ${toString cfg.slideshowInterval} "$PHOTO_DIR"
      EXIT_CODE=$?
      RUNTIME=$(( $(date +%s) - START_TIME ))

      if [ $EXIT_CODE -ne 0 ]; then
        echo "imv exited with code $EXIT_CODE after ''${RUNTIME}s" >&2
        if [ $RUNTIME -lt 10 ]; then
          FAIL_COUNT=$((FAIL_COUNT + 1))
          echo "Rapid failure $FAIL_COUNT/$MAX_FAILS" >&2
          if [ $FAIL_COUNT -ge $MAX_FAILS ]; then
            echo "FATAL: imv crashed $MAX_FAILS times rapidly. Giving up. Check GPU/display configuration." >&2
            exit 1
          fi
        else
          FAIL_COUNT=0
        fi
      else
        FAIL_COUNT=0
      fi
      sleep 5
    done
  '';

  # Eww wrapper script — starts daemon then opens sidebar (no crash-recovery loop).
  # Previous version had a while-true loop that caused "blipping" — the old script
  # from a prior sway session held the flock with a stale SWAYSOCK, and its loop
  # kept killing/restarting the daemon every ~20 seconds.
  ewwStart = pkgs.writeShellScript "nixframe-eww-start" ''
    # Setup eww config directory
    mkdir -p "$HOME/.config/eww"
    ln -sf ${ewwYuck} "$HOME/.config/eww/eww.yuck"
    ln -sf ${ewwScss} "$HOME/.config/eww/eww.scss"

    # Ensure only one eww-start instance runs at a time.
    # If an old script from a previous sway session is still running,
    # kill its eww daemon (which makes the old script's wait return and exit),
    # then take the lock.
    LOCKFILE="/run/user/$(id -u)/.eww-start.lock"
    exec 8>"$LOCKFILE"
    if ! ${pkgs.util-linux}/bin/flock -n 8; then
      echo "Lock held by old eww-start, killing stale daemon to reclaim..." >&2
      ${pkgs.eww}/bin/eww kill 2>&1 || true
      sleep 2
      if ! ${pkgs.util-linux}/bin/flock -n 8; then
        echo "FATAL: Still locked after kill, cannot start eww." >&2
        exit 1
      fi
    fi

    # Clean up stale sway sockets from previous sessions (after flock,
    # so only the lock holder touches sockets). Only remove sockets
    # whose embedded PID is no longer alive.
    if [ -n "$SWAYSOCK" ]; then
      for sock in /run/user/$(id -u)/sway-ipc.*.sock; do
        [ "$sock" = "$SWAYSOCK" ] && continue
        # Extract PID from socket name: sway-ipc.<UID>.<PID>.sock
        SOCK_PID=$(echo "$sock" | ${pkgs.gnused}/bin/sed -n 's/.*sway-ipc\.[0-9]*\.\([0-9]*\)\.sock/\1/p')
        if [ -n "$SOCK_PID" ] && ! kill -0 "$SOCK_PID" 2>/dev/null; then
          rm -f "$sock" 2>/dev/null
        fi
      done
    fi

    # Clean up on signals (sway exit sends SIGHUP/SIGTERM to children)
    cleanup() {
      echo "Signal received, shutting down eww..." >&2
      ${pkgs.eww}/bin/eww kill 2>&1 || true
      exit 0
    }
    trap cleanup SIGTERM SIGHUP SIGINT

    # Kill any stale eww daemon from a prior run
    ${pkgs.eww}/bin/eww kill 2>&1 || true
    sleep 1

    # Start eww daemon in foreground-mode (backgrounded so we can open windows)
    ${pkgs.eww}/bin/eww daemon --no-daemonize &
    EWW_PID=$!

    # Wait for eww daemon IPC to be ready before opening windows.
    # Without this, `eww open` spawns a NEW daemon (race condition),
    # causing duplicate windows and stacked exclusive zones.
    EWW_READY=false
    for i in $(seq 1 20); do
      if ${pkgs.eww}/bin/eww ping 2>/dev/null; then
        EWW_READY=true
        break
      fi
      sleep 0.5
    done
    if [ "$EWW_READY" = false ]; then
      echo "WARNING: eww daemon did not respond to ping after 10s, attempting to open windows anyway" >&2
    fi

    if ! ${pkgs.eww}/bin/eww open sidebar; then
      echo "WARNING: eww open sidebar failed" >&2
    fi
    ${optionalString weatherCfg.enable ''
    if ! ${pkgs.eww}/bin/eww open forecast; then
      echo "WARNING: eww open forecast failed" >&2
    fi
    ''}

    # Block until eww daemon exits. No restart loop — the daemon is stable.
    # If sway restarts, it sends SIGHUP → cleanup trap fires → clean exit.
    wait $EWW_PID
    EWW_EXIT=$?
    echo "eww daemon exited (code $EWW_EXIT), script ending." >&2
    exit $EWW_EXIT
  '';

  # Generated Sway config
  swayConfig = pkgs.writeText "sway-nixframe.conf" ''
    # Target HDMI-A-2 for photo frame display
    output ${cfg.output} {
      resolution ${cfg.resolution}
      bg #000000 solid_color
    }

    # Window styling — no borders for clean photo display
    default_border none
    default_floating_border none
    bar { mode invisible }

    # Disable DPMS screen blanking — always-on display
    output * dpms on
    exec swaymsg output '*' dpms on

    # imv: tiled window, fills remaining space after Eww exclusive zone
    for_window [app_id="imv"] border none

    # Launch photo slideshow and sidebar
    exec ${imvStart}
    exec ${ewwStart}

    # Emergency exit (via SSH: swaymsg exit)
    bindsym Ctrl+Shift+q exit
  '';
in
{
  options.services.nixframe = {
    enable = mkEnableOption "NixFrame digital photo frame";

    photoDir = mkOption {
      type = types.path;
      default = "/var/lib/nixframe/photos";
      description = "Directory for photo storage.";
    };

    slideshowInterval = mkOption {
      type = types.int;
      default = 60;
      description = "Seconds between photo transitions.";
    };

    output = mkOption {
      type = types.str;
      default = "HDMI-A-2";
      description = "Sway output name for the display.";
    };

    resolution = mkOption {
      type = types.str;
      default = "3840x2160";
      description = "Display resolution (Sway picks best refresh rate).";
    };

    sidebarWidth = mkOption {
      type = types.int;
      default = 800;
      description = "Width of the Eww clock/date sidebar in pixels.";
    };

    vt = mkOption {
      type = types.int;
      default = 7;
      description = "Virtual terminal for nixframe auto-login (avoids conflict with TTY1 btop).";
    };

    weather = {
      enable = mkEnableOption "weather forecast bar at the bottom of the display";

      location = mkOption {
        type = types.str;
        default = "Chisinau";
        description = "Location for wttr.in weather queries.";
      };

      forecastHeight = mkOption {
        type = types.int;
        default = 280;
        description = "Height of the bottom forecast bar in pixels.";
      };
    };
  };

  config = mkIf cfg.enable {
    # ──────────────────────────────────────────────────────────────
    # User and group
    # ──────────────────────────────────────────────────────────────
    users.users.nixframe = {
      isNormalUser = true;
      group = "nixframe";
      extraGroups = [ "video" "input" ]; # DRM access for GPU rendering + libinput for Sway
      home = "/var/lib/nixframe";
      homeMode = "0750"; # Group traverse so n8n (in nixframe group) can reach photos/
      createHome = true;
      description = "NixFrame photo frame display user";
    };

    users.groups.nixframe = { };

    # Add n8n user to nixframe group so n8n can write photos
    users.users.n8n.extraGroups = mkIf config.services.n8n-tailscale.enable [ "nixframe" ];

    # ──────────────────────────────────────────────────────────────
    # Directories
    # ──────────────────────────────────────────────────────────────
    systemd.tmpfiles.rules = [
      # Home dir needs group traverse (0750) so n8n can reach photos/
      "d /var/lib/nixframe 0750 nixframe nixframe -"
      "d ${cfg.photoDir} 0775 nixframe nixframe -"
      # Seed the trigger file so systemd.paths has something to watch on first boot
      "f ${cfg.photoDir}/.trigger 0664 nixframe nixframe -"
    ] ++ optionals weatherCfg.enable [
      "d /var/lib/nixframe/.cache 0750 nixframe nixframe -"
    ];

    # ──────────────────────────────────────────────────────────────
    # GPU / Display prerequisites
    # ──────────────────────────────────────────────────────────────
    hardware.graphics.enable = true;

    # Sway PAM/polkit/dbus integration (provides security.pam.services.sway)
    programs.sway.enable = true;

    # Fonts for Eww sidebar
    fonts.packages = [ pkgs.noto-fonts ];

    # ──────────────────────────────────────────────────────────────
    # Auto-login on VT 7
    # ──────────────────────────────────────────────────────────────
    systemd.services."getty@tty${toString cfg.vt}" = {
      overrideStrategy = "asDropin";
      serviceConfig.ExecStart = [
        "" # Clear the default ExecStart
        "@${pkgs.util-linux}/sbin/agetty agetty --autologin nixframe --noclear %I $TERM"
      ];
    };

    # Auto-start Sway when nixframe logs into tty7
    # Similar to btop auto-start on tty1, but uses 'exec' to replace the shell
    # so that Sway exit triggers re-login and automatic restart.
    # NixOS concatenates interactiveShellInit from all modules (types.lines);
    # the tty + user guards ensure Sway only launches for nixframe on tty7.
    programs.bash.interactiveShellInit = ''
      if [[ "$(tty)" == "/dev/tty${toString cfg.vt}" ]] && [[ "$(whoami)" == "nixframe" ]] && [[ -z "$NIXFRAME_RUNNING" ]]; then
        export NIXFRAME_RUNNING=1
        exec ${pkgs.sway}/bin/sway --config ${swayConfig}
      fi
    '';

    # ──────────────────────────────────────────────────────────────
    # Photo watcher — reload imv when photos change
    # ──────────────────────────────────────────────────────────────
    systemd.paths.nixframe-photo-watcher = {
      description = "Watch NixFrame photo directory for changes";
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        # Watch a trigger file instead of the directory itself.
        # Atomic rename() replaces the inode, causing systemd to lose the
        # inotify watch on the new file (systemd bug #20934). The n8n upload
        # workflow writes this trigger file after each photo save.
        PathModified = "${cfg.photoDir}/.trigger";
        Unit = "nixframe-photo-refresh.service";
      };
    };

    systemd.services.nixframe-photo-refresh = {
      description = "Reload imv after photo directory changes";
      serviceConfig = {
        Type = "oneshot";
        # Run as nixframe user so imv-msg can find the IPC socket
        # at $XDG_RUNTIME_DIR/imv-$PID.sock
        User = "nixframe";
        Group = "nixframe";
        ExecStart = pkgs.writeShellScript "nixframe-refresh-imv" ''
          export XDG_RUNTIME_DIR="/run/user/$(id -u)"
          # Use newest imv PID (pgrep -n) to avoid stale processes
          IMV_PID=$(${pkgs.procps}/bin/pgrep -n -u nixframe imv || true)
          if [ -n "$IMV_PID" ]; then
            if ! ${pkgs.imv}/bin/imv-msg "$IMV_PID" close all 2>&1; then
              echo "WARNING: imv-msg 'close all' failed for PID $IMV_PID" >&2
            fi
            if ! ${pkgs.imv}/bin/imv-msg "$IMV_PID" open "${cfg.photoDir}" 2>&1; then
              echo "WARNING: imv-msg 'open' failed for PID $IMV_PID" >&2
            fi
          else
            echo "WARNING: imv is not running. Photo refresh skipped. Display may be down." >&2
          fi
        '';
      };
    };

    # ──────────────────────────────────────────────────────────────
    # Photo cleanup timer — remove orphaned temp files
    # ──────────────────────────────────────────────────────────────
    systemd.timers.nixframe-cleanup = {
      description = "Clean up NixFrame temporary files";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
      };
    };

    systemd.services.nixframe-cleanup = {
      description = "Remove orphaned NixFrame temp files";
      serviceConfig = {
        Type = "oneshot";
        User = "nixframe";
        Group = "nixframe";
      };
      script = ''
        PHOTO_DIR="${cfg.photoDir}"
        if [ -d "$PHOTO_DIR" ]; then
          # Remove temp files older than 1 hour (failed uploads)
          DELETED=$(${pkgs.findutils}/bin/find "$PHOTO_DIR" -name '.tmp-*' -mmin +60 -delete -print | ${pkgs.coreutils}/bin/wc -l)
          echo "NixFrame cleanup: removed $DELETED orphaned temp files"
        else
          echo "WARNING: Photo directory $PHOTO_DIR does not exist" >&2
          exit 1
        fi
      '';
    };

    # ──────────────────────────────────────────────────────────────
    # Packages
    # ──────────────────────────────────────────────────────────────
    environment.systemPackages = with pkgs; [
      imv # Photo viewer
      eww # Widget sidebar
      sway # Compositor (for swaymsg CLI from SSH)
      imagemagick # HEIC conversion + EXIF orient (used by n8n workflow)
    ];
  };
}
