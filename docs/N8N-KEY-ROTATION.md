# n8n encryption key rotation

`N8N_ENCRYPTION_KEY` (wired via `services.n8n-tailscale.encryptionKeyFile`,
agenix secret `n8n-encryption-key.age`) encrypts every credential stored in
n8n's database. Rotating it is **destructive for stored credentials**: n8n
has no built-in re-encryption — anything encrypted with the old key becomes
unreadable after the swap.

## When to rotate

- Suspected key compromise (the agenix file leaked decrypted, a host with
  decryption access was compromised, the key appeared in logs/console).
- A host key that could decrypt `n8n-encryption-key.age` rotated under
  unclear circumstances (see `docs/SECRETS-ROTATION.md` for the agenix
  fail-open trap — verify the secret still decrypts to 64 hex chars first).
- No scheduled rotation otherwise: rotating without cause only risks
  credential loss, and the key never leaves the host (delivered via agenix
  to `/run/agenix`, held in n8n's process env).

## Procedure

This deployment is declarative-first: credentials that matter should be in
the `credentialsFile` overwrite (or re-enterable from the services they
belong to). Inventory first:

```bash
# 1. List stored credentials (on rpi5)
sudo sqlite3 /var/lib/n8n/.n8n/database.sqlite \
  "SELECT id, name, type FROM credentials_entity;"

# 2. For anything not re-creatable, export via UI (Credentials → ⋯ → Export)
#    or note the upstream source (bot tokens, API keys) for re-entry.
```

Then rotate:

```bash
# 3. Generate the new key
openssl rand -hex 32

# 4. Replace the agenix secret (from a host whose SSH host key matches its
#    recipient stanza — see docs/SECRETS-ROTATION.md before doing this)
cd ~/nixos-config/secrets && agenix -e n8n-encryption-key.age

# 5. Stop n8n, wipe the now-undecryptable credentials, deploy, restart
sudo systemctl stop n8n
sudo sqlite3 /var/lib/n8n/.n8n/database.sqlite "DELETE FROM credentials_entity;"
sudo nixos-rebuild switch --flake .#rpi5-full   # ships the new key

# 6. Verify n8n is healthy with the new key
systemctl status n8n
curl -sf http://127.0.0.1:5678/healthz && echo OK

# 7. Re-enter credentials (UI) or re-import the declarative credentialsFile
#    (restart triggers CREDENTIALS_OVERWRITE_DATA_FILE re-application).
```

## Notes

- **Do not** delete the whole database — workflows, executions and settings
  are not encrypted with this key; only `credentials_entity` is affected.
- n8n refuses to start cleanly if the key changes while old credentials
  exist (decryption errors at credential use, not at boot) — that is why
  step 5 deletes them explicitly rather than leaving zombie rows.
- The `~/.n8n/config` file inside the state dir caches an encryption key
  for setups without the env var; this deployment always sets
  `N8N_ENCRYPTION_KEY` from the env file, which takes precedence.
- Upstream reference: https://docs.n8n.io/hosting/configuration/environment-variables/deployment/
  (`N8N_ENCRYPTION_KEY`).
