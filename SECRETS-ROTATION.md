# Secret Rotation Procedures

## Overview
This document describes how to rotate secrets managed by agenix in the nixos-config repository.

## ⚠️ Critical: agenix "fails open" on host-key rotation

`agenix -e` / `agenix -r` re-encrypts a secret to the recipient set **declared
in `secrets.nix`**, using the running host's SSH **host key** to first *decrypt*
the existing ciphertext. If that host key has rotated away from the key the
`.age` file was encrypted to, agenix **cannot decrypt the old content and
re-encrypts EMPTY plaintext** to the new recipients. The result looks
well-formed (valid `age-encryption.org/v1` header, valid recipient stanzas) but
carries zero useful bytes — and there is **no error**: the failure only surfaces
later when the consuming service breaks.

This happened in this repo: re-imaging `rpi5` (the `nixos-raspberrypi` switch,
`e5339b1`/#57) rotated its host key and corrupted five secrets, followed by a
restore → re-corrupt → restore thrash (#60/#61/#62). Corrupted files collapsed
to a uniform ~432 bytes (a 32-byte ciphertext = the age STREAM tag for a
zero-length payload).

**Rules to avoid a recurrence:**

1. **Re-encrypt a secret ONLY from a host whose *current* SSH host key still
   matches one of that secret's recipient stanzas.** Re-imaged a host? Do not
   run `agenix -e`/`-r` on it until its new key is added as a recipient *and*
   the files were re-encrypted from a host that could still decrypt them.
2. **Recipient lists serve two roles** — they must cover both the runtime host
   *and* every machine you EDIT from (this is why `secrets.nix` keeps `rpi5` in
   `clawKeys`, the `eff778c` fix).
3. **Disposable VPS hosts encrypt to a stable `age1…` recovery identity**
   decoupled from the SSH host key (`age.identityPaths = /root/.age/recovery.key`
   on sancta-claw / hermes-claw / zero-kuzea), so a re-image decrypts on first
   boot with no re-keying.
4. **CI guards this mechanically** — `scripts/check-secret-recipients.sh` (run in
   `.github/workflows/check.yml`) flags recipient drift (on-disk `-> ` stanza
   count vs declared `publicKeys`) and the empty-plaintext signature, read-only,
   without ever decrypting.

### Risk posture: `rpi5` / `rpi5-full` / `sancta-choir` (decision, #448)

These three hosts still use their **SSH host key** as the agenix recipient
(`secrets/secrets.nix:7`), so they remain exposed to the fail-open mode above on
a future re-image — unlike the three VPS hosts, which carry a standalone
recovery key. **Current decision: accepted risk**, mitigated by (a) the CI drift
guard, (b) this documented procedure, and (c) keeping a decrypting host available
before any re-image. Giving `rpi5` the same `recovery.key` + `age.identityPaths`
treatment is tracked by the agenix recipient-model refactor in **#414**; revisit
the posture there rather than ad hoc.

### Reconciling recipient drift (manual, host-gated)

`scripts/check-secret-recipients.sh` currently WARNs on a known drift:
`secrets/hermes-env.age` is encrypted on-disk to **5** recipients but
`secrets.nix` declares **3** (`users ++ [ rpi5 hermes-claw ]`). To reconcile,
**on a host whose key matches a current stanza** (e.g. `rpi5`):

```bash
cd secrets && agenix -e hermes-env.age   # re-saves to the 3 declared recipients
# verify: grep -ac '^-> ' hermes-env.age  → 3
```

Then remove `hermes-env.age` from `KNOWN_PENDING_DRIFT` in the guard script.
**Do not** run this from a host (like a darwin laptop) that cannot decrypt the
file — that is exactly the fail-open trap above.

## Prerequisites
- SSH access to the host machine
- SSH key authorized in `secrets/secrets.nix`
- Access to `/etc/ssh/ssh_host_ed25519_key` (host key) or your personal SSH key

## General Rotation Process

### 1. Generate New Secret
```bash
# Example: Generate a new random secret (32 bytes, base64-encoded)
head -c 32 /dev/urandom | base64 | tr -d '\n' > /tmp/new-secret.txt
```

### 2. Encrypt with Agenix
```bash
cd /root/nixos-config/secrets

# Encrypt the new secret
cat /tmp/new-secret.txt | nix run github:ryantm/agenix/0.15.0#agenix -- -e secret-name.age

# Verify decryption works
nix run github:ryantm/agenix/0.15.0#agenix -- -d secret-name.age -i /etc/ssh/ssh_host_ed25519_key

# Clean up temporary file
rm /tmp/new-secret.txt
```

### 3. Deploy New Secret
```bash
cd /root/nixos-config

# Add the updated secret to git
git add -f secrets/secret-name.age

# Build and deploy
nixos-rebuild switch --flake .#sancta-choir

# Verify the service restarted successfully
systemctl status service-name.service
```

## Service-Specific Rotation

### Open-WebUI Secret Key (JWT Signing)
**Warning:** Rotating this will invalidate all active user sessions.

```bash
cd /root/nixos-config/secrets

# Generate new JWT secret
head -c 32 /dev/urandom | base64 | tr -d '\n' | \
  nix run github:ryantm/agenix/0.15.0#agenix -- -e open-webui-secret-key.age

# Deploy
cd /root/nixos-config
git add -f secrets/open-webui-secret-key.age
nixos-rebuild switch --flake .#sancta-choir

# All users will need to log in again
```

### OpenRouter API Key
**Note:** Generate new key at https://openrouter.ai/keys

```bash
cd /root/nixos-config/secrets

# Encrypt new API key
echo -n "sk-or-v1-YOUR_NEW_KEY_HERE" | \
  nix run github:ryantm/agenix/0.15.0#agenix -- -e openrouter-api-key.age

# Deploy
cd /root/nixos-config
git add -f secrets/openrouter-api-key.age
nixos-rebuild switch --flake .#sancta-choir

# Verify Open-WebUI can still access LLMs
journalctl -u open-webui.service -n 50
```

### OIDC Client Secret
**Note:** This is used for Tailscale OAuth (currently disabled).

```bash
cd /root/nixos-config/secrets

# Encrypt new client secret (get from tsidp configuration)
echo -n "YOUR_NEW_CLIENT_SECRET" | \
  nix run github:ryantm/agenix/0.15.0#agenix -- -e oidc-client-secret.age

# Deploy
cd /root/nixos-config
git add -f secrets/oidc-client-secret.age
nixos-rebuild switch --flake .#sancta-choir
```

### Tailscale Auth Key
**Note:** Generate reusable auth key at https://login.tailscale.com/admin/settings/keys

```bash
cd /root/nixos-config/secrets

# Encrypt new auth key
echo -n "tskey-auth-xxxxx-yyyyyyyy" | \
  nix run github:ryantm/agenix/0.15.0#agenix -- -e tailscale-auth-key.age

# Deploy
cd /root/nixos-config
git add -f secrets/tailscale-auth-key.age
nixos-rebuild switch --flake .#sancta-choir

# Verify Tailscale is still connected
tailscale status
```

## Emergency: Rotate All Secrets

```bash
cd /root/nixos-config/secrets

# 1. Backup current secrets (optional)
mkdir -p /tmp/secret-backup
nix run github:ryantm/agenix/0.15.0#agenix -- -d open-webui-secret-key.age -i /etc/ssh/ssh_host_ed25519_key > /tmp/secret-backup/open-webui.txt
# ... repeat for other secrets

# 2. Generate and encrypt new secrets
head -c 32 /dev/urandom | base64 | tr -d '\n' | \
  nix run github:ryantm/agenix/0.15.0#agenix -- -e open-webui-secret-key.age

# Get new API key from OpenRouter
echo -n "sk-or-v1-NEW_KEY" | \
  nix run github:ryantm/agenix/0.15.0#agenix -- -e openrouter-api-key.age

# Generate new OIDC secret (if using OAuth)
head -c 32 /dev/urandom | xxd -p -c 64 | \
  nix run github:ryantm/agenix/0.15.0#agenix -- -e oidc-client-secret.age

# Get new Tailscale auth key
echo -n "tskey-auth-NEW_KEY" | \
  nix run github:ryantm/agenix/0.15.0#agenix -- -e tailscale-auth-key.age

# 3. Deploy all at once
cd /root/nixos-config
git add -f secrets/*.age
nixos-rebuild switch --flake .#sancta-choir

# 4. Verify all services
systemctl status open-webui.service
systemctl status tailscaled.service
tailscale status
```

## Adding New Secrets

### 1. Update secrets.nix
```bash
cd /root/nixos-config/secrets
nano secrets.nix
```

Add the new secret to the attribute set (before the closing `}`):
```nix
{
  # Existing secrets...
  "existing-secret.age".publicKeys = allKeys;
  
  # Add your new secret:
  "new-secret.age".publicKeys = allKeys;
}
```

### 2. Create and Encrypt
```bash
echo -n "secret-value" | \
  nix run github:ryantm/agenix/0.15.0#agenix -- -e new-secret.age
```

### 3. Update Configuration
```nix
# In hosts/sancta-choir/configuration.nix
age.secrets.new-secret.file = "${self}/secrets/new-secret.age";
# Defaults: owner=root, group=root, mode=0400

# Only use extended syntax if you need non-default values:
# age.secrets.new-secret = {
#   file = "${self}/secrets/new-secret.age";
#   owner = "myuser";
#   group = "mygroup";
#   mode = "0440";
# };
```

### 4. Use in Service
```nix
# Reference the secret path
secretFile = config.age.secrets.new-secret.path;
# This resolves to: /run/agenix/new-secret
```

## Troubleshooting

### Secret Won't Decrypt
```bash
# Check if secret is in secrets.nix
cat /root/nixos-config/secrets/secrets.nix

# Try decrypting manually with host key
nix run github:ryantm/agenix/0.15.0#agenix -- -d secrets/secret-name.age -i /etc/ssh/ssh_host_ed25519_key

# Check agenix service logs
journalctl -u agenix.service -n 50
```

### Service Won't Start After Rotation
```bash
# Check if secret was decrypted
ls -la /run/agenix/

# Check service environment
systemctl show service-name.service -p EnvironmentFiles

# Check service logs
journalctl -u service-name.service -n 50

# Rollback to previous generation if needed
nixos-rebuild switch --rollback
```

### Permission Denied Errors
```bash
# Check secret permissions
ls -la /run/agenix/secret-name

# Verify owner/group in configuration
grep -A5 "secrets.secret-name" /root/nixos-config/hosts/sancta-choir/configuration.nix

# Check if service user has access
sudo -u service-user cat /run/agenix/secret-name
```

## Best Practices

1. **Always verify** new secrets decrypt before deploying
2. **Test in build** before switch: `nixos-rebuild build --flake .#sancta-choir`
3. **Keep backups** of old secrets until new ones are verified
4. **Rotate regularly**:
   - JWT secrets: Every 90 days
   - API keys: When compromised or every 6 months
   - Auth keys: When compromised or when team members leave
5. **Never commit** plaintext secrets to git
6. **Use reusable** Tailscale auth keys (can be revoked)
7. **Document** which services will be affected by rotation

## References
- Agenix GitHub: https://github.com/ryantm/agenix
- NixOS Wiki: https://nixos.wiki/wiki/Agenix
- Tailscale Auth Keys: https://login.tailscale.com/admin/settings/keys
- OpenRouter API Keys: https://openrouter.ai/keys
