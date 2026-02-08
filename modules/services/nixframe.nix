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

  # Forecast script — fetches wttr.in JSON, caches it, outputs one slot's data.
  # Called as: nixframe-forecast-slot <slot-index>
  # Returns 4 lines: label, temp, description, feels-like
  forecastScript = pkgs.writeShellScript "nixframe-forecast-slot" ''
    set -euo pipefail

    # Slot definitions: wttr.in hourly[] indices for 06,12,15,18,21
    SLOTS=(2 4 5 6 7)
    LABELS=("Morning" "Midday" "Afternoon" "Evening" "Night")

    SLOT_IDX="''${1:-0}"
    if [ "$SLOT_IDX" -lt 0 ] || [ "$SLOT_IDX" -gt 4 ]; then
      echo "Error: slot index must be 0-4" >&2
      exit 1
    fi

    CACHE_DIR="/var/lib/nixframe/.cache"
    CACHE="$CACHE_DIR/weather-full.json"
    mkdir -p "$CACHE_DIR"

    # Fetch if cache missing or >30min old
    # Use flock to prevent concurrent fetches (all 5 defpolls fire at once on startup)
    # and atomic mv to prevent partial reads
    NOW=$(${pkgs.coreutils}/bin/date +%s)
    if [ ! -f "$CACHE" ] || [ $(( NOW - $(${pkgs.coreutils}/bin/stat -c %Y "$CACHE") )) -gt 1800 ]; then
      (
        ${pkgs.util-linux}/bin/flock -n 9 || exit 0  # Another slot is already fetching
        # Re-check after acquiring lock (another process may have just written)
        if [ ! -f "$CACHE" ] || [ $(( $(${pkgs.coreutils}/bin/date +%s) - $(${pkgs.coreutils}/bin/stat -c %Y "$CACHE") )) -gt 1800 ]; then
          RESPONSE=$(${pkgs.curl}/bin/curl -sf --max-time 10 'https://wttr.in/${weatherCfg.location}?format=j1' 2>/dev/null || true)
          if [ -n "$RESPONSE" ]; then
            TMP="$CACHE_DIR/.weather-full.tmp.$$"
            echo "$RESPONSE" > "$TMP"
            ${pkgs.coreutils}/bin/mv -f "$TMP" "$CACHE"
          fi
        fi
      ) 9>"$CACHE_DIR/.weather.lock"
    fi

    if [ ! -f "$CACHE" ]; then
      echo "''${LABELS[$SLOT_IDX]}"
      echo "--"
      echo "No data"
      echo ""
      exit 0
    fi

    IDX=''${SLOTS[$SLOT_IDX]}
    ENTRY=$(${pkgs.jq}/bin/jq -r ".weather[0].hourly[$IDX]" "$CACHE")
    TEMP=$(echo "$ENTRY" | ${pkgs.jq}/bin/jq -r '.tempC')
    DESC=$(echo "$ENTRY" | ${pkgs.jq}/bin/jq -r '.weatherDesc[0].value')
    FEELS=$(echo "$ENTRY" | ${pkgs.jq}/bin/jq -r '.FeelsLikeC')

    echo "''${LABELS[$SLOT_IDX]}"
    echo "''${TEMP}°C"
    echo "$DESC"
    echo "Feels ''${FEELS}°C"
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
    (defpoll forecast-0 :interval "1800s" "${forecastScript} 0")
    (defpoll forecast-1 :interval "1800s" "${forecastScript} 1")
    (defpoll forecast-2 :interval "1800s" "${forecastScript} 2")
    (defpoll forecast-3 :interval "1800s" "${forecastScript} 3")
    (defpoll forecast-4 :interval "1800s" "${forecastScript} 4")

    (defwindow forecast
      :monitor 0
      :geometry (geometry :width "100%" :height "${toString weatherCfg.forecastHeight}px" :anchor "bottom center")
      :stacking "fg"
      :exclusive true
      :focusable false
      (box :class "forecast-bar" :orientation "h" :halign "fill" :space-evenly true
        (label :class "forecast-slot" :text forecast-0)
        (box :class "forecast-divider")
        (label :class "forecast-slot" :text forecast-1)
        (box :class "forecast-divider")
        (label :class "forecast-slot" :text forecast-2)
        (box :class "forecast-divider")
        (label :class "forecast-slot" :text forecast-3)
        (box :class "forecast-divider")
        (label :class "forecast-slot" :text forecast-4)))
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
      background-color: rgba(30, 25, 20, 0.80);
      padding: 15px 40px;
    }

    .forecast-slot {
      padding: 0 20px;
      font-size: 36px;
      color: #e8a948;
    }

    .forecast-divider {
      min-width: 1px;
      background-color: rgba(196, 168, 130, 0.3);
    }
    ''}
  '';

  # imv wrapper script — starts slideshow with crash backoff
  imvStart = pkgs.writeShellScript "nixframe-imv-start" ''
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
      # Exit if Sway is gone (e.g. after nixos-rebuild restarts getty@tty7).
      # Without this check, orphaned imv spins at 100% CPU on a dead POLLHUP socket.
      if [ -n "$SWAYSOCK" ] && [ ! -e "$SWAYSOCK" ]; then
        echo "Sway socket gone ($SWAYSOCK), exiting." >&2
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

  # Eww wrapper script — starts daemon then opens sidebar with crash backoff
  ewwStart = pkgs.writeShellScript "nixframe-eww-start" ''
    # Setup eww config directory
    mkdir -p "$HOME/.config/eww"
    ln -sf ${ewwYuck} "$HOME/.config/eww/eww.yuck"
    ln -sf ${ewwScss} "$HOME/.config/eww/eww.scss"

    # Start eww daemon, then open sidebar
    # Crash backoff: if eww crashes rapidly 5 times, stop to avoid CPU burn
    FAIL_COUNT=0
    MAX_FAILS=5
    while true; do
      # Exit if Sway is gone (e.g. after nixos-rebuild restarts getty@tty7)
      if [ -n "$SWAYSOCK" ] && [ ! -e "$SWAYSOCK" ]; then
        echo "Sway socket gone ($SWAYSOCK), exiting." >&2
        ${pkgs.eww}/bin/eww kill 2>&1 || true
        exit 0
      fi

      # Kill any stale eww instance from previous iteration or prior run
      ${pkgs.eww}/bin/eww kill 2>&1 || true
      sleep 1

      START_TIME=$(date +%s)
      ${pkgs.eww}/bin/eww daemon --no-daemonize &
      EWW_PID=$!
      sleep 2
      if ! ${pkgs.eww}/bin/eww open sidebar; then
        echo "WARNING: eww open sidebar failed" >&2
      fi
      ${optionalString weatherCfg.enable ''
      if ! ${pkgs.eww}/bin/eww open forecast; then
        echo "WARNING: eww open forecast failed" >&2
      fi
      ''}
      # Wait for eww daemon to exit (crash recovery)
      wait $EWW_PID
      EXIT_CODE=$?
      RUNTIME=$(( $(date +%s) - START_TIME ))

      if [ $EXIT_CODE -ne 0 ]; then
        echo "eww exited with code $EXIT_CODE after ''${RUNTIME}s" >&2
        if [ $RUNTIME -lt 10 ]; then
          FAIL_COUNT=$((FAIL_COUNT + 1))
          echo "Rapid failure $FAIL_COUNT/$MAX_FAILS" >&2
          if [ $FAIL_COUNT -ge $MAX_FAILS ]; then
            echo "FATAL: eww crashed $MAX_FAILS times rapidly. Giving up. Check display configuration." >&2
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
        default = 160;
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
