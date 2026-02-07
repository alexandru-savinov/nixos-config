# NixFrame — Digital Photo Frame on Raspberry Pi 5

A low-RAM digital photo frame and family dashboard running on the existing RPi5 NixOS configuration, displaying photos on a Samsung 4K TV with a clock/date sidebar.

## Vision

When the family turns on the TV, it defaults to the RPi5's HDMI input showing a rotating slideshow of family photos with a clean sidebar displaying the time and date. Family members upload photos from their phones via a simple web form. The whole system is declarative, reproducible, and uses under 200MB of RAM alongside the existing services.

## Hardware

- **Raspberry Pi 5** (4GB RAM, NVMe SSD root)
- **Samsung 4K TV** on HDMI-A-1 (3840x2160, confirmed connected)
- **Ethernet** connection
- **GPU ready**: vc4 + v3d kernel modules loaded, DRM devices available

## Constraints

NixFrame **coexists** with the existing rpi5-full services (Open-WebUI, n8n, Qdrant, Gatus). Current RAM usage leaves ~1.6GB available. The display stack targets ~80-140MB total.

| Component | Estimated RAM |
|-----------|--------------|
| Sway compositor | ~30-50MB |
| imv photo viewer | ~20-40MB |
| Eww sidebar widgets | ~30-50MB |
| **Total** | **~80-140MB** |

## Architecture

```
Boot → greetd (VT 1) → auto-login nixframe user → Sway compositor
                                                      ├── imv (fullscreen photo slideshow)
                                                      └── Eww (sidebar: clock + date)

Phone → n8n webhook (GET)  → HTML upload form
     → n8n webhook (POST) → atomic write to /var/lib/nixframe/photos/
                                    ↓
                        systemd path unit detects change
                                    ↓
                        imv-msg adds new photo to running slideshow
```

### Display Layout

```
┌──────────────────────────────────────────────────────────────────┐
│                                                                  │
│                                                 ┌──────────────┐│
│                                                 │              ││
│                                                 │   14:35      ││
│              📷 Photo                           │              ││
│              (fills remaining space)             │   Saturday   ││
│                                                 │   February 7 ││
│                                                 │              ││
│                                                 └──────────────┘│
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
         3040px (photo area)              800px (Eww sidebar)
                          3840px total (4K)
```

## Software Stack

| Component | Package | Role |
|-----------|---------|------|
| **Compositor** | Sway | Wayland compositor, manages layout |
| **Login manager** | greetd | Auto-login nixframe user, starts Sway |
| **Photo viewer** | imv | Fullscreen slideshow with `-t 60` (60s per photo) |
| **Widgets** | Eww | gtk-layer-shell sidebar with exclusive zone |
| **Photo upload** | n8n (existing) | Two webhook workflows: UI form + upload handler |
| **Fonts** | Noto Sans | Readable on 4K TV from couch distance |

### Why These Choices

- **Sway over Cage**: Sway gives us scriptable IPC (`swaymsg`) for future remote management. Cage locks us into single-app mode.
- **imv over swayimg**: imv has built-in slideshow (`-t N`) and IPC support. swayimg requires external scripting for auto-advance.
- **Eww over Waybar/AGS**: Eww uses gtk-layer-shell for pixel-perfect sidebar positioning with exclusive zones. Waybar is designed for status bars, not custom widgets. AGS is heavier (~30-50MB more).
- **greetd over getty auto-login**: greetd creates a proper PAM/logind session with DRM device access. A bare getty + `.bash_profile` approach lacks seat management.

## NixOS Module Design

### Module: `modules/services/nixframe.nix`

```nix
services.nixframe = {
  enable = true;
  # All defaults match our requirements:
  #   photosDir = "/var/lib/nixframe/photos"
  #   slideshowInterval = 60  (seconds)
  #   output = "HDMI-A-1"
  #   resolution = "3840x2160@60Hz"
};
```

### What the Module Provides

| Subsystem | Details |
|-----------|---------|
| **greetd** | VT 1, auto-login `nixframe` user, launches `sway --config <generated>` |
| **Sway config** | HDMI-A-1 at 4K, no borders/bar/idle, execs imv wrapper + eww |
| **imv wrapper** | Bash loop: checks for photos (falls back to placeholder), runs `imv -f -t 60 dir/`, restarts on crash |
| **Eww config** | yuck + scss generated in Nix store, copied to `~nixframe/.config/eww/` at startup |
| **Eww startup** | Wrapper runs `eww daemon` before `eww open sidebar` (daemon required first) |
| **Photo watcher** | `systemd.paths` with `PathModified` → uses `imv-msg` IPC to add new photos without restarting |
| **User/group** | `nixframe` user (normal), `nixframe` group. `n8n` user added to group for photo writes |
| **Directories** | tmpfiles: `/var/lib/nixframe/photos` with 0775 group-writable |
| **Fonts** | `fonts.packages = [ noto-fonts ]` |
| **Sway PAM** | `programs.sway.enable = true` for polkit/dbus/logind integration |

### Interaction with Existing Config

| Concern | Resolution |
|---------|-----------|
| **btop on tty1** | greetd on VT 1 auto-disables getty@tty1 via systemd `Conflicts=`. btop bash hook is tty1+root-specific, doesn't affect nixframe user. |
| **n8n integration** | Existing `workflowsDir` auto-imports new workflow JSONs. `NODE_FUNCTION_ALLOW_BUILTIN` already set. |
| **n8n photo writes** | `n8n` user added to `nixframe` group → can write to 0775 photos directory |
| **SSH access** | Unaffected. greetd only controls local VT, not SSH sessions. |
| **HDMI hotplug** | Sway auto-disables output when TV switches away, re-enables when TV returns to HDMI input. |

### Generated Sway Config

```
output HDMI-A-1 {
  resolution 3840x2160@60Hz
  bg #000000 solid_color
}

default_border none
default_floating_border none
bar { mode invisible }

# Disable idle/screen blanking
seat * idle_timeout 0

# Launch photo slideshow and sidebar
exec nixframe-imv-start
exec nixframe-eww-start

# Emergency exit (via SSH: swaymsg Ctrl+Shift+q)
bindsym Ctrl+Shift+q exit
```

### Eww Sidebar

**Widget definition (yuck):**
```yuck
(defpoll clock-time :interval "1s" `date +%H:%M`)
(defpoll clock-date :interval "60s" `date '+%A, %B %-d'`)

(defwindow sidebar
  :monitor 0
  :geometry (geometry :width "800px" :height "100%" :anchor "center right")
  :stacking "fg"
  :exclusive true
  (box :class "sidebar" :orientation "v" :valign "center"
    (label :class "clock" :text clock-time)
    (label :class "date"  :text clock-date)))
```

**Styling (scss):**
- Background: `rgba(0, 0, 0, 0.75)` (translucent dark)
- Clock: 200px white Noto Sans bold
- Date: 60px light gray Noto Sans

The `exclusive: true` property reserves 800px on the right — Sway should prevent tiled windows from overlapping this area. **Note:** imv's `-f` (fullscreen) may ignore exclusive zones. If so, use Sway `for_window` rules to constrain imv to the remaining 3040px instead of `-f`. This must be tested before implementation.

## Photo Upload (n8n Webhooks)

Two workflows, following the existing `image-to-anki-*` pattern:

### `n8n-workflows/nixframe-ui.json` — Upload Form

```
GET /webhook/nixframe → Code node (HTML) → Respond to Webhook (text/html)
```

Mobile-friendly HTML form:
- "Choose Photo" button → phone camera/gallery picker (`accept="image/*"`)
- Image preview before upload
- Upload button → standard `<form>` multipart/form-data POST to `/webhook/nixframe-upload`
- Success/error feedback

Accessible at: `https://rpi5.tail4249a9.ts.net:5678/webhook/nixframe`

### `n8n-workflows/nixframe-upload.json` — Upload Handler

```
POST /webhook/nixframe-upload → Validate → If valid → Save Photo → Success Response
                                                    → Error Response
```

Processing:
1. Validate uploaded file (check MIME: jpeg/png/webp/heic, size <20MB)
2. Convert HEIC→JPEG if needed (ImageMagick, for iPhone compatibility)
3. Auto-orient using EXIF data (handles rotated phone photos)
4. Generate unique filename: `YYYY-MM-DDTHH-MM-SS_hash8.ext`
5. Write to temp file, then atomic `rename()` into `/var/lib/nixframe/photos/` (prevents race with systemd.paths watcher)
6. Set permissions 0664 (readable by nixframe group)
7. Respond with `{ success: true, filename }`

Security: filename sanitization, directory traversal prevention, MIME type validation.

**Why multipart/form-data instead of base64 JSON:** Standard file upload avoids the ~33% base64 size inflation. No client-side encoding JavaScript needed. n8n webhooks handle multipart natively. Supports larger original files without hitting payload limits.

## Files Changed

| File | Action | Description |
|------|--------|-------------|
| `modules/services/nixframe.nix` | **Create** | Main NixOS module (greetd + Sway + imv + Eww) |
| `n8n-workflows/nixframe-ui.json` | **Create** | Photo upload HTML form (n8n workflow) |
| `n8n-workflows/nixframe-upload.json` | **Create** | Photo upload handler (n8n workflow) |
| `hosts/rpi5-full/configuration.nix` | **Modify** | Add import + `services.nixframe.enable = true` |

## Verification

```bash
nix fmt
nix flake check
nixos-rebuild build --flake .#rpi5-full
```

After deploy:
1. `systemctl status greetd` — active on VT 1
2. TV shows black background + Eww sidebar (clock/date)
3. Visit `https://rpi5.tail4249a9.ts.net:5678/webhook/nixframe` from phone
4. Upload a test photo → appears on TV within 60 seconds

## Phase 2 (Not in MVP)

| Feature | Notes |
|---------|-------|
| iCloud Calendar | vdirsyncer + khal → Eww calendar widget. Needs app-specific password. |
| Weather widget | wttr.in API → Eww widget. Trivial once Eww sidebar is working. |
| Photo transitions | Would need mpv instead of imv, or a custom renderer. |
| HDMI CEC | Screen on/off via CEC protocol. Nice-to-have. |
| ~~HEIC conversion~~ | ~~Moved to MVP — most iPhones default to HEIC.~~ |
| Multiple albums | Album selection in upload form, subdirectories in photos dir. |
| Immich integration | Deploy on sancta-choir, replace n8n upload with Immich API sync. |
| REST management API | Thin wrapper around swaymsg + eww CLI for non-SSH management. |

## Open Questions for Discussion

1. **Photo ordering**: Should the slideshow be chronological (newest first), random, or oldest first? Currently alphabetical by timestamp-based filename (chronological).

2. **Sidebar toggle**: Should there be a way to hide the sidebar for full-screen photo mode? Could be controlled via `swaymsg` over SSH.

3. **Photo deletion**: Should the upload UI have a "manage photos" mode to remove photos, or is SSH-based file deletion sufficient?

4. **Upload size limits**: Using multipart/form-data (no base64 overhead), n8n's default 16MB payload limit supports most phone photos (3-8MB) directly. Should we increase the limit for edge cases?

5. **Auto-cleanup**: Should old photos be automatically deleted when disk usage exceeds a threshold? Or is manual management preferred?

6. **Multiple displays**: The Pi 5 has two HDMI outputs. Any interest in supporting a second display in the future?

7. **Screensaver mode**: Instead of static cycling, would animated transitions (fade/slide) between photos be worth the complexity of switching from imv to mpv?
