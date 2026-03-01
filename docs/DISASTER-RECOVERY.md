# Disaster Recovery — sancta-claw

## Prerequisites

- Access to Hetzner Cloud console (hetzner.com)
- An **x86_64** machine with `nix` installed (sancta-claw itself, sancta-choir, or any x86_64 host)
- Recovery key + extra-files directory (stored on rpi5 at `/root/dr/`, transfer to install machine)
- Backup of recovery key in Bitwarden (fallback)

> **Architecture constraint:** nixos-anywhere **cannot** cross-build from aarch64 to x86_64. Do not run from rpi5 — use sancta-claw itself or any x86_64 machine. Transfer the extra-files from rpi5 first: `scp -r root@rpi5:/root/dr/extra-files /root/dr/`

## Quick Recovery (2 commands)

### Step 1: Create new VPS in Hetzner Cloud

- Login to Hetzner Cloud console
- **Upload your SSH public key** (from the machine that will run nixos-anywhere) under SSH Keys
- Create server: **CCX13** or larger (dedicated CPU, UEFI firmware), Nuremberg (nbg1), Ubuntu 24.04
- **Select the SSH key** you uploaded during server creation
- Note the new IP address

> **Important:** Use CCX server types (dedicated CPU). These use UEFI firmware. CX/CPX shared CPU types may work but are untested. The config installs GRUB for both BIOS and UEFI (PR #345).

> **SSH key required:** Hetzner injects the selected SSH key into the Ubuntu image. nixos-anywhere uses SSH to connect, so the install machine must have the matching private key. If using a non-default key path, add `-i /path/to/key` to the nixos-anywhere command.

### Step 2: Install NixOS (command 1)

From any x86_64 machine with nix + the recovery key extra-files:

```bash
nix run github:nix-community/nixos-anywhere -- \
  --extra-files /root/dr/extra-files \
  --flake github:alexandru-savinov/nixos-config#sancta-claw \
  root@NEW_IP
```

> Add `-i /path/to/key` if your SSH private key is not at the default path.

This will:

- Partition disk via disko (GPT: 1M BIOS boot, 256M ESP at `/boot`, rest ext4 root on `/dev/sda`)
- Place the age recovery key at `/root/.age/recovery.key` (from `--extra-files`)
- Install NixOS with full sancta-claw config
- On first boot: agenix decrypts secrets using the recovery key, Tailscale connects automatically

> **Note:** nixos-anywhere with disko **will reformat the disk** — all existing data is erased.

> **No IP/MAC config needed** — sancta-claw uses DHCP (PR #344).

> **No re-keying needed** — secrets are encrypted for a stable age key, not the SSH host key. The recovery key placed by `--extra-files` enables decryption on first boot.

### Step 3: Install OpenClaw + restore workspace (command 2)

```bash
# Install the openclaw binary (not in NixOS — installed via npm)
ssh root@NEW_IP "sudo -u openclaw NPM_CONFIG_PREFIX=/var/lib/openclaw/.npm-global npm install -g openclaw"

# Restore workspace from rpi5 backup (Tailscale must be connected first)
ssh -A root@NEW_IP /etc/sancta-claw/restore.sh rpi5

# Restart to pick up restored config
ssh root@NEW_IP "systemctl restart openclaw"
```

> `NPM_CONFIG_PREFIX` must match the service config. Without it, the binary lands in the wrong path and the openclaw service won't start (`ConditionPathExists` skips silently).

> **restore.sh** SSHs to rpi5 via Tailscale, runs `restic restore latest`, rsyncs files back to `/var/lib/openclaw/`, and fixes ownership. Requires Tailscale connected + restic backup on rpi5.

> **SSH agent forwarding (`-A`):** The new VPS has a fresh SSH host key — rpi5 doesn't know it. Use `ssh -A` to forward your SSH agent so restore.sh can authenticate to rpi5 using your key. Alternatively, run the restore from rpi5 (push mode — see below).

If restore.sh fails (e.g., no backup, Tailscale not connected, or SSH key issue):

```bash
# Alternative: restore from rpi5 (push mode)
# On rpi5:
RESTORE_DIR=$(mktemp -d /tmp/restore-XXXXXX)
sudo restic -r /backups/restic/sancta-claw --password-file /run/agenix/restic-password \
  restore latest --target "$RESTORE_DIR"
sudo rsync -az -e "ssh -o StrictHostKeyChecking=no" \
  "$RESTORE_DIR/backups/staging/" root@NEW_IP:/var/lib/openclaw/
ssh root@NEW_IP "chown -R openclaw:openclaw /var/lib/openclaw && systemctl restart openclaw"
sudo rm -rf "$RESTORE_DIR"

# Or configure from scratch (no backup):
ssh root@NEW_IP "sudo -u openclaw openclaw configure"   # interactive — Telegram token etc.
```

### Step 4: Verify

```bash
ssh root@NEW_IP /etc/sancta-claw/smoke-test.sh   # Automated health check
```

Or verify manually:

```bash
ssh root@NEW_IP "hostname"                    # SSH works
ssh root@NEW_IP "ls /run/agenix/"             # Secrets decrypted
ssh root@NEW_IP "tailscale status"            # Tailscale connected
ssh root@NEW_IP "systemctl status openclaw"   # OpenClaw running
```

## Post-Recovery Checklist

- [ ] NixOS boots via UEFI, SSH works
- [ ] Agenix secrets decrypted (`ls /run/agenix/`)
- [ ] Tailscale connected (`tailscale status`)
- [ ] OpenClaw running, Kuzea responds in Telegram
- [ ] Workspace restored (MEMORY.md, SOUL.md present)
- [ ] Cron jobs active
- [ ] CalDAV, Todoist, GitHub functional

## Recovery Key Management

### What is the recovery key?

A dedicated age identity key that replaces the SSH host key for secret decryption. Unlike SSH host keys (which change on every reinstall), this key is stable — enabling secrets to decrypt on first boot without re-keying.

### Access scope (no elevation)

The recovery key has **exactly the same scope** as the old SSH host key:
- 4 Kuzea secrets (caldav, github, todoist, airtable)
- Tailscale auth key
- Restic backup password

It **cannot** decrypt shared secrets (n8n, open-webui, openai, etc.) — those are `allKeys` only.

### Storage locations

| Location | Path | Purpose |
|----------|------|---------|
| rpi5 | `/root/dr/recovery-sancta-claw.key` | Primary — master copy of the private key |
| rpi5 | `/root/dr/extra-files/root/.age/recovery.key` | Ready-to-use extra-files directory |
| sancta-claw | `/root/.age/recovery.key` | Runtime — agenix reads this for decryption |
| sancta-claw | `/root/dr/extra-files/root/.age/recovery.key` | Copy for running nixos-anywhere from sancta-claw |
| Bitwarden | "sancta-claw recovery key" | Offline backup |

### Extra-files directory structure

The `--extra-files` directory mirrors the root filesystem of the target. nixos-anywhere copies it verbatim:

```
/root/dr/extra-files/
└── root/
    └── .age/
        └── recovery.key    # age private key (mode 0600)
```

This places the key at `/root/.age/recovery.key` on the new system, where `age.identityPaths` expects it.

### Rotating the recovery key

If the key is compromised, generate a new one:

```bash
# On rpi5
age-keygen -o /root/dr/recovery-sancta-claw-new.key
# Update secrets/secrets.nix with new public key
# Re-encrypt: use rage directly (agenix -r has a bug with the -o flag accumulator)
cd secrets && for f in *.age; do
  KEYS=$(nix-instantiate --json --eval --strict -E "(let r = import ./secrets.nix; in r.\"$f\".publicKeys)" | jq -r '.[]')
  RECIPIENTS=""; while IFS= read -r k; do RECIPIENTS="$RECIPIENTS -r \"$k\""; done <<< "$KEYS"
  sudo rage -d -i /etc/ssh/ssh_host_ed25519_key "$f" | eval rage $RECIPIENTS -o "/tmp/rekey-$f" && mv "/tmp/rekey-$f" "$f"
done
# Update extra-files, deploy to sancta-claw, store in Bitwarden
```

## DNS & IP Changes

- Tailscale MagicDNS: automatic, no changes needed
- If using direct IP anywhere: update to new VPS IP
- No networking config changes needed — DHCP handles everything (PR #344)

## Troubleshooting

### Secrets don't decrypt

- Verify `/root/.age/recovery.key` exists on sancta-claw
- Check `age.identityPaths` includes the key path
- If recovery key is lost: retrieve from Bitwarden, place at `/root/.age/recovery.key`

### Tailscale won't connect

- Check auth key is not expired in Tailscale admin
- Generate new reusable key if needed, re-encrypt with agenix

### OpenClaw won't start

- Check `journalctl -u openclaw -f`
- Verify `openclaw.json` exists in `/var/lib/openclaw/.openclaw/`
- Check node version: `node --version`
- Memory limit is 6GB — verify with `systemctl show openclaw | grep MemoryMax`

### VPS won't cold boot

- Hetzner CCX uses UEFI — GRUB must be installed for both BIOS and EFI (PR #345)
- Check: `boot.loader.grub.efiSupport = true` and `boot.loader.grub.efiInstallAsRemovable = true`
- ESP must be mounted at `/boot` (set in `disk-config.nix`)
- Use Hetzner rescue mode to inspect boot files: `ls /mnt/boot/EFI/BOOT/`

### nixos-anywhere fails with "lacks a signature by a trusted key"

- You are running nixos-anywhere from an **aarch64** machine (e.g., rpi5) to an x86_64 target
- This cannot work — nixos-anywhere needs matching architecture
- Solution: run from sancta-claw, sancta-choir, or any x86_64 machine
- Transfer extra-files first: `scp -r root@rpi5:/root/dr/extra-files /root/dr/`

### nixos-anywhere fails with "Permission denied"

- The VPS does not have the install machine's SSH key authorized
- Solution: upload the SSH public key to Hetzner Cloud, then select it when creating the VPS
- If the VPS already exists: use Hetzner rescue mode or delete and recreate with the correct key

### Tailscale auth key "does not exist" after install

- nixos-anywhere may use a **cached flake** if secrets were updated recently
- Verify: `cat /run/agenix/tailscale-auth-key` — compare with expected key
- Fix: run `nixos-rebuild switch --flake github:alexandru-savinov/nixos-config#sancta-claw --refresh` on the new VPS
- Or add `--refresh` to the nixos-anywhere command: `nix run ... --refresh -- ...`

### restore.sh can't SSH to rpi5

- The new VPS has a fresh SSH host key — rpi5 doesn't recognize it
- Solution 1: use SSH agent forwarding: `ssh -A root@NEW_IP /etc/sancta-claw/restore.sh rpi5`
- Solution 2: run the restore from rpi5 in push mode (see Step 3 alternative)
- Solution 3: copy your SSH private key to the VPS (less secure, temporary)

### Build fails on VPS (OOM)

- CCX13 has 8GB — usually fine, 12GB swap is configured
- Use `--max-jobs 1 --cores 1` for constrained environments

## Architecture

```
Hetzner CCX (sancta-claw)
├── NixOS (declarative config from github:alexandru-savinov/nixos-config)
├── Disko partitioning (GPT: 1M BIOS boot, 256M ESP at /boot, ext4 root)
├── GRUB dual-boot (BIOS i386-pc + UEFI x86_64-efi as removable)
├── Agenix secrets (age recovery key at /root/.age/recovery.key)
├── Tailscale VPN (auto-connect via auth key — works on first boot)
├── DHCP networking (no static IP/MAC config needed)
├── OpenClaw + Kuzea (workspace in /var/lib/openclaw)
├── Auto-upgrade (daily at 04:30 UTC)
└── backup-pull user (rsync read-only for rpi5)

RPi5 (rpi5-full)
├── Daily restic backup (pull from sancta-claw)
├── Encrypted repo at /backups/restic/sancta-claw
├── Staging on tmpfs (no unencrypted data on disk)
└── DR assets at /root/dr/ (recovery key + extra-files)

Recovery key: age identity (NOT SSH host key)
├── Public key in secrets/secrets.nix (sancta-claw variable)
├── Private key on: rpi5, sancta-claw, Bitwarden
├── Scope: clawKeys + tailscale only (6 secrets, no elevation)
└── Stable across reinstalls — no re-keying needed
```

## Agenix Secrets (sancta-claw scope)

| Secret | Runtime Path |
|--------|-------------|
| CalDAV iCloud | `/run/agenix/kuzea-caldav-credentials` |
| GitHub PAT | `/run/agenix/kuzea-github-token` |
| Todoist API | `/run/agenix/kuzea-todoist-credentials` |
| Airtable PAT | `/run/agenix/kuzea-airtable-credentials` |
| Tailscale auth | `/run/agenix/tailscale-auth-key` |
| Restic password | `/run/agenix/restic-password` |

## Estimated Recovery Time

| Step | Time |
|------|------|
| VPS creation | ~2 min |
| nixos-anywhere install (with --extra-files) | ~10 min |
| Workspace restore + OpenClaw install | ~3 min |
| **Total** | **~15 min** (excluding Hetzner account login) |

## Cost

- Test VPS (CCX13, 10 min): ~€0.02
- Production VPS (CCX13): ~€18/month
