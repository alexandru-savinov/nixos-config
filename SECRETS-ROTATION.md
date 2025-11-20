# Secret Rotation Procedures

## Overview
This document describes how to rotate secrets managed by agenix in the nixos-config repository.

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
cat /tmp/new-secret.txt | nix run github:ryantm/agenix#agenix -- -e secret-name.age

# Verify decryption works
nix run github:ryantm/agenix#agenix -- -d secret-name.age -i /etc/ssh/ssh_host_ed25519_key

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
  nix run github:ryantm/agenix#agenix -- -e open-webui-secret-key.age

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
  nix run github:ryantm/agenix#agenix -- -e openrouter-api-key.age

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
  nix run github:ryantm/agenix#agenix -- -e oidc-client-secret.age

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
  nix run github:ryantm/agenix#agenix -- -e tailscale-auth-key.age

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
nix run github:ryantm/agenix#agenix -- -d open-webui-secret-key.age -i /etc/ssh/ssh_host_ed25519_key > /tmp/secret-backup/open-webui.txt
# ... repeat for other secrets

# 2. Generate and encrypt new secrets
head -c 32 /dev/urandom | base64 | tr -d '\n' | \
  nix run github:ryantm/agenix#agenix -- -e open-webui-secret-key.age

# Get new API key from OpenRouter
echo -n "sk-or-v1-NEW_KEY" | \
  nix run github:ryantm/agenix#agenix -- -e openrouter-api-key.age

# Generate new OIDC secret (if using OAuth)
head -c 32 /dev/urandom | xxd -p -c 64 | \
  nix run github:ryantm/agenix#agenix -- -e oidc-client-secret.age

# Get new Tailscale auth key
echo -n "tskey-auth-NEW_KEY" | \
  nix run github:ryantm/agenix#agenix -- -e tailscale-auth-key.age

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

Add the new secret:
```nix
{
  "new-secret.age".publicKeys = allKeys;
}
```

### 2. Create and Encrypt
```bash
echo -n "secret-value" | \
  nix run github:ryantm/agenix#agenix -- -e new-secret.age
```

### 3. Update Configuration
```nix
# In hosts/sancta-choir/configuration.nix
age.secrets.new-secret = {
  file = "${self}/secrets/new-secret.age";
  owner = "root";
  group = "root";
  mode = "0400";
};
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
nix run github:ryantm/agenix#agenix -- -d secrets/secret-name.age -i /etc/ssh/ssh_host_ed25519_key

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
