---
allowed-tools: Bash(sudo:*), Bash(id:*), Bash(ls:*), Bash(grim:*), Bash(magick:*), Read(*)
description: Capture a screenshot of the NixFrame display
---

# NixFrame Screenshot

Capture a screenshot of the NixFrame digital photo frame display and show it.

## Arguments

Optional region argument: $ARGUMENTS

Valid regions:
- (empty) — Full display (3840x2160)
- `forecast` — Bottom forecast bar only (3040x280)
- `sidebar` — Right sidebar clock area only (800x2160)

## Steps

Execute these steps in order:

### 1. Discover the nixframe Sway session

Run this as a single bash command to discover the environment:

```bash
NIXFRAME_UID=$(id -u nixframe) && \
SWAYSOCK=$(ls /run/user/$NIXFRAME_UID/sway-ipc.*.sock 2>/dev/null | head -1) && \
WAYLAND=$(ls /run/user/$NIXFRAME_UID/wayland-* 2>/dev/null | grep -v '\.lock$' | head -1) && \
echo "UID=$NIXFRAME_UID SWAYSOCK=$SWAYSOCK WAYLAND=$(basename $WAYLAND)"
```

If no Sway socket is found, tell the user that NixFrame's Sway session is not running.

### 2. Capture the screenshot

Using the UID, SWAYSOCK, and WAYLAND_DISPLAY discovered above, capture a full screenshot:

```bash
sudo -u nixframe \
  SWAYSOCK=<socket-path> \
  WAYLAND_DISPLAY=<wayland-display> \
  XDG_RUNTIME_DIR=/run/user/<uid> \
  grim /tmp/nixframe-screenshot.png
```

### 3. Crop to region (if specified)

Based on the region argument (`$ARGUMENTS`):

- If empty or "full": skip cropping, use the full screenshot
- If "forecast": crop to the bottom forecast bar
  ```bash
  magick /tmp/nixframe-screenshot.png -crop 3040x280+0+1880 /tmp/nixframe-screenshot.png
  ```
- If "sidebar": crop to the right sidebar
  ```bash
  magick /tmp/nixframe-screenshot.png -crop 800x2160+3040+0 /tmp/nixframe-screenshot.png
  ```

### 4. Display the screenshot

Use the Read tool to display `/tmp/nixframe-screenshot.png`. This will render the image visually.

### 5. Brief description

After showing the image, provide a one-line description of what's visible (e.g., "Forecast bar showing 5 slots with weather icons for Tomorrow").

## Notes

- The nixframe user runs Sway on a dedicated VT (tty7) driving an HDMI-connected Samsung 4K TV
- Display layout: 3840x2160, sidebar 800px on right, forecast bar 280px at bottom (3040px wide)
- grim is already installed system-wide
- Requires sudo access to run commands as the nixframe user
