# Disaster Recovery — sancta-claw

## Prerequisites

- SSH private key `nixos-sancta-choir` (stored in Bitwarden)
- Access to Hetzner Cloud console (hetzner.com)
- A working machine with `nix` installed (laptop, rpi5, etc.)

## Quick Recovery (2 commands)

### Step 1: Create new VPS in Hetzner Cloud

- Login to Hetzner Cloud console
- Create server: CX22 (or CX33), Nuremberg (nbg1), Ubuntu 24.04
- Note the new IP address

### Step 2: Install NixOS + config

```bash
nix run github:nix-community/nixos-anywhere -- \
  --flake github:alexandru-savinov/nixos-config#sancta-claw \
  root@NEW_IP
```

This will:

- Partition disk (via disko — GPT: 1M BIOS boot, 256M ESP, rest ext4 root on `/dev/sda`)
- Install NixOS with full sancta-claw config
- Configure Tailscale, OpenClaw, all services

### Step 3: Update host key in agenix

The new VPS has a new SSH host key. Secrets won't decrypt until you re-encrypt:

```bash
# Get new host key
ssh-keyscan NEW_IP | grep ed25519

# Update secrets/secrets.nix: replace sancta-claw pub key
# Re-encrypt all secrets
cd secrets && agenix -r -i /path/to/nixos-sancta-choir

# Push and rebuild
git push
ssh root@NEW_IP "nixos-rebuild switch --flake github:alexandru-savinov/nixos-config#sancta-claw"
```

### Step 4: Restore workspace

OpenClaw workspace lives in `/var/lib/openclaw/` and contains mutable state
(MEMORY.md, SOUL.md, `.openclaw/`, git repos). Restore from rpi5 backup:

```bash
ssh root@rpi5 "restic -r /backups/restic/sancta-claw restore latest --target /tmp/restore"
rsync -az root@rpi5:/tmp/restore/backups/staging/ root@NEW_IP:/var/lib/openclaw/
ssh root@NEW_IP "chown -R openclaw:openclaw /var/lib/openclaw && systemctl restart openclaw"
```

### Step 5: Verify

```bash
# SSH works
ssh root@NEW_IP "hostname"

# Secrets decrypted
ssh root@NEW_IP "ls /run/agenix/"

# Tailscale connected
ssh root@NEW_IP "tailscale status"

# OpenClaw running
ssh root@NEW_IP "systemctl status openclaw"
```

## Post-Recovery Checklist

- [ ] NixOS boots, SSH works
- [ ] Agenix secrets decrypted (`ls /run/agenix/`)
- [ ] Tailscale connected (`tailscale status`)
- [ ] OpenClaw running, Kuzea responds in Telegram
- [ ] Workspace restored (MEMORY.md, SOUL.md present)
- [ ] Cron jobs active
- [ ] CalDAV, Todoist, GitHub functional

## DNS & IP Changes

- Tailscale MagicDNS: automatic, no changes needed
- If using direct IP anywhere: update to new VPS IP (current: `46.225.168.24`)
- Public IP recorded in MEMORY.md — update after recovery
- Update `hosts/sancta-claw/configuration.nix` networking section with new IP

## Troubleshooting

### Secrets don't decrypt

- Verify `nixos-sancta-choir` private key is correct
- Check `secrets/secrets.nix` has the new host key
- Run `agenix -r` and rebuild

### Tailscale won't connect

- Check auth key is not expired in Tailscale admin
- Generate new reusable key if needed
- Re-encrypt with agenix

### OpenClaw won't start

- Check `journalctl -u openclaw -f`
- Verify `openclaw.json` exists in `/var/lib/openclaw/.openclaw/`
- Check node version: `node --version`
- Memory limit is 6GB — check with `systemctl status openclaw`

### Build fails on VPS (OOM)

- CX22 has 4GB RAM — use `--max-jobs 1 --cores 1` for builds
- CX33 has 8GB — usually fine, 12GB swap is configured
- See `MIGRATION-RESUME.md` for detailed boot failure recovery

## Architecture

```
Hetzner CX33 (sancta-claw)
├── NixOS (declarative config from github:alexandru-savinov/nixos-config)
├── Disko partitioning (GPT: boot + ESP + ext4 root on /dev/sda)
├── Agenix secrets (encrypted in repo, decrypted at boot)
├── Tailscale VPN (auto-connect via auth key)
├── OpenClaw + Kuzea (workspace in /var/lib/openclaw)
├── Auto-upgrade (daily at 04:30 UTC)
└── backup-pull user (rsync read-only for rpi5)

RPi5 (rpi5-full)
├── Daily restic backup (pull from sancta-claw)
├── Encrypted repo at /backups/restic/sancta-claw
└── Staging on tmpfs (no unencrypted data on disk)

Recovery key: nixos-sancta-choir (SSH ed25519)
├── Stored in: Bitwarden
├── Can decrypt: all agenix secrets
└── Can re-encrypt: for new host keys
```

## Agenix Secrets (sancta-claw scope)

| Secret | Runtime Path |
|--------|-------------|
| CalDAV iCloud | `/run/agenix/kuzea-caldav-credentials` |
| GitHub PAT | `/run/agenix/kuzea-github-token` |
| Todoist API | `/run/agenix/kuzea-todoist-credentials` |
| Airtable PAT | `/run/agenix/kuzea-airtable-credentials` |
| Tailscale auth | `/run/agenix/tailscale-auth-key` |

## Estimated Recovery Time

| Step | Time |
|------|------|
| VPS creation | ~2 min |
| nixos-anywhere install | ~10 min |
| Agenix re-encryption + rebuild | ~5 min |
| Workspace restore | ~2 min |
| **Total** | **~20 min** (excluding Hetzner account login) |

## Cost

- Test VPS (CX22, 10 min): ~€0.01
- Production VPS (CX33): ~€15/month
