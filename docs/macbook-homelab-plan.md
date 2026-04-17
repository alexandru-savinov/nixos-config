# MacBook → Homelab: Access Plan + Secrets Tier Refactor

**Status**: plan only — no `.nix` files changed yet.
**Branch**: `claude/add-macbook-homelab-UiRY1`.
**Scope**: give the MacBook the same day-to-day access as rpi5/sancta-choir/sancta-claw (Tailscale, SSH, agenix editing), while cleaning up the secrets recipient model.

---

## 1. Goals

1. MacBook joins the tailnet and can SSH as `root` into every NixOS host.
2. MacBook can edit agenix secrets with **its own** identity — never the bootstrap/admin key.
3. Stop the "admin key = sancta-choir host key" conflation. Split identities.
4. Trim stale and over-provisioned recipients (zero-kuzea removed; `restic-password` scoped to rpi5 only).
5. Preserve the "iPhone → SSH rpi5 → Claude Code → `agenix -e`" editing workflow.
6. Leave clean hooks for a future YubiKey break-glass and a future IdP (family users).

## 2. Current state (what's off)

Reference: `secrets/secrets.nix` on `main`.

- `root-sancta-choir` is listed in `users` (humans who edit) **and** is the live SSH host key of sancta-choir. Compromise of that one key = fleet-wide compromise across two trust layers.
- `allKeys`, `allPlusClaw`, `clawKeys` are set-algebra names — you must evaluate the union in your head to answer "who can decrypt X?".
- `zero-kuzea` has no agenix recipient at all, yet `zero-kuzea-telegram-bot-token.age` is declared. The host is being retired anyway → delete the secret with it.
- `restic-password.age` lists sancta-claw as a recipient, but only rpi5 ever runs `restic`. Dead-weight recipient.
- Mac has no identity in the model.

## 3. Target model ("Shape C" — service bundles)

### 3.1 Identity axes

```nix
# Humans/devices that can EDIT (agenix -e)
editors = {
  admin   = "ssh-ed25519 AAA... offline-admin";   # dormant: Bitwarden + USB only
  macbook = "ssh-ed25519 AAA... macbook-alex";    # new
  # Future slots: additional personal devices, YubiKey.
};

# Hosts that DECRYPT at boot
hosts = {
  rpi5        = "ssh-ed25519 AAA... root@rpi5";
  sanctaChoir = "ssh-ed25519 AAA... root@sancta-choir";  # NEW: its own key
  sanctaClaw  = "age1zex...";                            # DR-stable age identity
};

# rpi5 plays both roles: host key AND editor terminal (iPhone + Claude Code path).
canEdit = builtins.attrValues editors ++ [ hosts.rpi5 ];
```

### 3.2 Service bundles

Each bundle = `canEdit ++ <hosts that decrypt this service's secrets at boot>`.

| Bundle | Members (beyond `canEdit`) | Purpose |
|--------|---------------------------|---------|
| `fleet` | `sanctaChoir`, `sanctaClaw` | Anything every host needs (Tailscale auth) |
| `n8n` | — | Runs on rpi5 only |
| `homelabApps` | — | UniFi, NixFrame calendar, Tavily, etc. (rpi5 only) |
| `testing` | — | e2e + open-webui-secret (rpi5 only; currently inactive) |
| `llmApis` | `sanctaClaw` | OpenAI + OpenRouter shared by n8n (rpi5) and OpenClaw (sancta-claw) |
| `kuzea` | `sanctaClaw` | Anthropic, Airtable, GitHub PAT, Todoist, Kuzea CalDAV, Kuzea Tavily |
| `backup` | — | restic repo lives on rpi5 (sancta-claw does NOT need these) |

### 3.3 Secret → bundle mapping

```nix
# Fleet
"tailscale-auth-key.age".publicKeys = fleet;

# n8n
"n8n-encryption-key.age".publicKeys = n8n;
"n8n-admin-password.age".publicKeys = n8n;
"n8n-api-key.age".publicKeys        = n8n;
"telegram-bot-token.age".publicKeys = n8n;   # workflow alerts

# Homelab apps
"unifi-password.age".publicKeys     = homelabApps;
"caldav-credentials.age".publicKeys = homelabApps;   # NixFrame calendar
"tavily-api-key.age".publicKeys     = homelabApps;

# Testing / inactive Open-WebUI
"open-webui-secret-key.age".publicKeys = testing;
"e2e-test-api-key.age".publicKeys      = testing;

# Shared LLM APIs
"openrouter-api-key.age".publicKeys = llmApis;
"openai-api-key.age".publicKeys     = llmApis;

# Kuzea (sancta-claw workload)
"anthropic-api-key.age".publicKeys          = kuzea;
"kuzea-github-token.age".publicKeys         = kuzea;
"kuzea-airtable-credentials.age".publicKeys = kuzea;
"kuzea-todoist-credentials.age".publicKeys  = kuzea;
"kuzea-caldav-credentials.age".publicKeys   = kuzea;
"kuzea-tavily-api-key.age".publicKeys       = kuzea;

# Backup (rpi5 only)
"restic-password.age".publicKeys     = backup;
"rpi5-backup-ssh-key.age".publicKeys = backup;
"backup-telegram-env.age".publicKeys = backup;
```

**Deleted**: `zero-kuzea-telegram-bot-token.age` (host being retired).

### 3.4 Diff vs current model

| Secret | Today's recipients | Shape C | Net effect |
|--------|-------------------|---------|-----------|
| all editors | `root-sancta-choir` (admin + host dual-role) | `editors.admin` + `editors.macbook` + rpi5-as-editor | admin becomes cold; Mac gains own identity |
| `tailscale-auth-key` | admin + rpi5 + sancta-claw | + sancta-choir (own host key) + Mac | sancta-choir stops free-riding on the admin key |
| `anthropic-api-key` | admin + rpi5 + sancta-claw | + Mac (editor), same runtime hosts | +Mac editor |
| `restic-password` | admin + rpi5 + sancta-claw | admin + Mac + rpi5 | sancta-claw loses access (never used it) |
| `rpi5-backup-ssh-key` | admin + rpi5 | + Mac | +Mac editor |
| `zero-kuzea-telegram-bot-token` | admin + rpi5 + sancta-claw | — | deleted |

## 4. Redundancy model ("if my Mac dies")

Three layers, in order of daily use:

| Layer | Identity | Where it lives | Trigger |
|-------|----------|----------------|---------|
| L1 daily | `editors.macbook` | Mac `~/.ssh/id_ed25519_homelab` | normal use |
| L2 fallback | rpi5 host key (via iPhone → SSH → Claude Code) | rpi5 `/etc/ssh/` | Mac offline/broken |
| L3 DR | `editors.admin` | Bitwarden + offline USB | L1+L2 both lost |

Future: add `editors.yubikey`; optionally split into `editors.daily` vs `editors.breakGlass` so the admin + YubiKey entries are only on high-sensitivity secrets.

## 5. Migration sequence

Execute in this order — deviations break decryption.

### Phase A — prep (no host changes)

1. Create feature branch: done (`claude/add-macbook-homelab-UiRY1`).
2. On the Mac: `ssh-keygen -t ed25519 -C "macbook-alexandru" -f ~/.ssh/id_ed25519_homelab`.
3. Capture pubkeys we'll need:
   - `~/.ssh/id_ed25519_homelab.pub` → goes into `editors.macbook`.
   - On sancta-choir, read `/etc/ssh/ssh_host_ed25519_key.pub` → goes into `hosts.sanctaChoir` (its *own* key, currently unused as a recipient).
   - rpi5 host pubkey is already in the model.
4. Archive the admin key (`nixos-sancta-choir`) into Bitwarden + offline USB. This is `editors.admin`. It stays dormant after this phase.

### Phase B — Nix edits (still on branch, not deployed)

Files touched:
- `secrets/secrets.nix` — rewritten to Shape C (identities + bundles + mappings). Inline comments retained and updated.
- `modules/system/host.nix` — split so sancta-choir uses its own host key and a shared `authorizedKeys` list.
- `modules/system/admin-keys.nix` (new, small) — central list of SSH pubkeys authorized as `root` on every host. Imported by each host's `configuration.nix`. Contains: `editors.macbook`, `editors.admin`, plus any existing keys we keep (TBD per host).
- `hosts/sancta-choir/configuration.nix` — drop the inline `authorizedKeys.keys` literal, import `admin-keys.nix` instead.
- `hosts/rpi5/configuration.nix` — same (replace the hard-coded `nixos-sancta-choir` entry with the shared list).
- `hosts/sancta-claw/configuration.nix` — same (verify current authorized key situation first).
- `hosts/zero-kuzea/*` — leave alone; host is being retired and is out of scope for this branch.

Re-encrypt all secrets:
```bash
cd nixos-config
nix develop                # brings in agenix
agenix -r                  # re-encrypts every .age to the new recipient list
git add secrets/ modules/ hosts/
git commit -m "refactor(secrets): Shape C bundles + split sancta-choir host key + add macbook editor"
```

### Phase C — deploy (order matters)

Risk: sancta-choir's **new** host key becomes an agenix recipient, so first boot after deploy needs that key already present on disk. Since it's been there all along (it's just `/etc/ssh/ssh_host_ed25519_key`), the deploy is safe — we're just *telling agenix to use it*. No key rotation on the host itself.

Recommended order:
1. **rpi5** first (lowest blast radius, you're comfortable with it, and failure is easy to recover via console).
   ```bash
   nixos-rebuild switch \
     --target-host root@rpi5.tail4249a9.ts.net \
     --flake .#rpi5-full
   ```
2. **sancta-choir** next. Watch the agenix activation log — this is the host whose identity changed most structurally (it now uses its own SSH host key rather than piggybacking on the admin key).
   ```bash
   nixos-rebuild switch \
     --target-host root@sancta-choir.tail4249a9.ts.net \
     --flake .#sancta-choir
   ```
3. **sancta-claw** last. Kuzea secrets must still decrypt — this is where we confirm the `kuzea` bundle is intact.
   ```bash
   nixos-rebuild switch \
     --target-host root@sancta-claw.tail4249a9.ts.net \
     --flake .#sancta-claw
   ```

### Phase D — verify

For each host, after switch:
```bash
systemctl status 'agenix-*' --no-pager
ls /run/agenix                 # all expected secrets materialized
journalctl -u tailscaled -n 50 # tailnet still up
```

Service-specific smoke tests:
- rpi5: `https://rpi5.tail4249a9.ts.net:5678` (n8n) loads; `https://rpi5.tail4249a9.ts.net:3001` (Gatus) reports green.
- sancta-claw: `https://sancta-claw.tail4249a9.ts.net:18789/healthz` returns 200.
- sancta-choir: can still SSH + any services it runs come up clean.

From the Mac (new identity only):
```bash
eval "$(ssh-agent)" && ssh-add ~/.ssh/id_ed25519_homelab
for h in rpi5 sancta-choir sancta-claw; do
  ssh -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519_homelab root@$h.tail4249a9.ts.net hostname
done

# Prove Mac can edit without the admin key
AGENIX_IDENTITY=~/.ssh/id_ed25519_homelab agenix -e secrets/telegram-bot-token.age
```

Decryption sanity on each host:
```bash
cat /run/agenix/tailscale-auth-key   # on all three hosts
cat /run/agenix/anthropic-api-key    # sancta-claw only
cat /run/agenix/restic-password      # rpi5 only
```

### Phase E — retire the admin key from the Mac

Only after Phase D passes:
```bash
# Secure-delete admin key from Mac; confirm Bitwarden copy first.
srm -v ~/.ssh/id_ed25519_sancta-choir_master  # or equivalent
```

### Phase F — docs

- Update `SECRETS-ROTATION.md` with:
  - new identity names (`editors.admin`, `editors.macbook`, per-host keys)
  - "admin key is break-glass only" policy
  - rpi5 is an authorized editor (iPhone path)
- Update `README.md` "Hosts" section to mention the Mac and the three-layer redundancy model.

## 6. Rollback

Failure mode → response:

| Symptom | Response |
|---------|----------|
| Agenix activation fails on a host | Revert that host's config to previous generation: `nixos-rebuild switch --rollback`. Investigate on branch. |
| Mac key lost mid-migration | Use iPhone → rpi5 → re-run `agenix -r` from rpi5 to re-add a fresh Mac key. rpi5 is a full editor. |
| Both Mac and rpi5 unreachable | Restore `editors.admin` from Bitwarden onto any trusted machine; it's still in the recipient list; edits continue. |
| Accidentally bricked recipient list (no one can decrypt X) | `git revert` the `secrets.nix` commit; `nixos-rebuild switch --rollback` on affected hosts. Age files are just text — revertible. |

## 7. Deliberately out of scope

- **zero-kuzea retirement**: separate branch. We only *remove* the orphaned `zero-kuzea-telegram-bot-token.age` secret here.
- **YubiKey break-glass**: leave `editors.admin` as a dormant keypair for now. When the YubiKey lands, add `editors.yubikey`, optionally split into `editors.daily` / `editors.breakGlass` and narrow high-sensitivity secrets (e.g., `anthropic-api-key`, `kuzea-github-token`) to the break-glass tier.
- **Family / IdP layer**: agenix is *not* the right layer for family users. When the degoogle push happens, introduce an IdP (Authentik, Authelia, or Pocket-ID with passkeys) on rpi5 or sancta-choir, give it its own bundle in Shape C (e.g., `authentikPg`, `authentikSecret`), and point web apps (Open-WebUI, Jellyfin, Nextcloud, etc.) at it via OIDC. Family members become rows in that IdP's database — never recipients in `secrets.nix`.

## 8. Open items to decide before implementation

- [ ] **Bundle granularity of `homelabApps`**: keep lumped (simple), or split into `unifi` / `nixframe` / `tavily` (more declarative, more lines). User deferred the call.
- [ ] **Where `admin-keys.nix` should live**: `modules/system/admin-keys.nix` vs `modules/users/admin-keys.nix`. The keys are about *login*, so `modules/users/` is probably better.
- [ ] **Do we remove the per-host `authorizedKeys.keys` literal entirely, or leave the old key for a grace period?** Safer to keep it one deploy cycle, then remove in a follow-up commit.
- [ ] **Deploy order confirmation**: rpi5 → sancta-choir → sancta-claw feels right; if there's a reason to flip sancta-choir and sancta-claw, note it here.

## 9. Success criteria

- Mac can SSH into every host as `root` using `~/.ssh/id_ed25519_homelab`.
- Mac can `agenix -e` and re-encrypt any secret with its own identity.
- Every host's `systemctl status agenix-*` is green post-deploy.
- Admin key deleted from the Mac disk; Bitwarden copy verified.
- `secrets/secrets.nix` reads top-down as intent (identities → bundles → mappings), no more set-algebra.
- `zero-kuzea-telegram-bot-token.age` removed.
