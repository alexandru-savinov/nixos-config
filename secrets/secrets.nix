let
  # Personal keys for editing secrets
  # This is the authorized key already in your configuration.nix
  root-sancta-choir = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPw5RFrFfZQUWlyfGSU1Q8BlEHnvIdBtcnCn+uYtEzal nixos-sancta-choir";

  # Raspberry Pi 5 host key
  rpi5 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBjZXKDY8Ve/wfMHpjsJGR7guDQFndGoNxDZKXegEfjr root@rpi5";

  # sancta-claw stable age identity for DR — NOT tied to SSH host key.
  # Decoupled from host identity so nixos-anywhere + --extra-files enables
  # secret decryption on first boot without re-keying.
  # Private key stored on: rpi5:/root/dr/recovery-sancta-claw.key + Bitwarden
  sancta-claw = "age1zex0chkw9swv62khuw73lftpcagu6t7d8vqa2h9mmnm23249hpuqx8f2kt";

  # Combine users who can edit
  users = [ root-sancta-choir ];

  # Systems that can decrypt shared secrets
  systems = [ rpi5 ];

  # All keys (for secrets shared across all hosts)
  allKeys = users ++ systems;

  # Keys for Kuzea-specific secrets (sancta-claw + owner machines)
  # rpi5 included so Alexandru can edit/re-encrypt from rpi5-full
  clawKeys = users ++ [ sancta-claw rpi5 ];
in
{
  # Tailscale - shared across all hosts (including sancta-claw)
  "tailscale-auth-key.age".publicKeys = allKeys ++ [ sancta-claw ];

  # ── Kuzea secrets (sancta-claw only, least privilege) ──────────────────
  # Encrypt on sancta-choir: agenix -e secrets/kuzea-caldav-credentials.age
  # Format: CALDAV_USER=apple-id@example.com\nCALDAV_PASSWORD=xxxx-xxxx-xxxx-xxxx
  "kuzea-caldav-credentials.age".publicKeys = clawKeys;

  # GitHub fine-grained PAT (Contents+PR read/write on nixos-config only)
  # Generate: github.com/settings/personal-access-tokens
  "kuzea-github-token.age".publicKeys = clawKeys;

  # Todoist API token for todoist-natural-language skill (PR #295)
  "kuzea-todoist-credentials.age".publicKeys = clawKeys;

  # Airtable Personal Access Token (read/write, direct api.airtable.com)
  # Generate: airtable.com/create/tokens (scopes: records:read/write, schema:read)
  "kuzea-airtable-credentials.age".publicKeys = clawKeys;

  # Open-WebUI secrets - shared across sancta-choir and rpi5
  "open-webui-secret-key.age".publicKeys = allKeys;
  "openrouter-api-key.age".publicKeys = allKeys ++ [ sancta-claw ];
  "tavily-api-key.age".publicKeys = allKeys;

  # n8n workflow automation - shared across all hosts
  "n8n-encryption-key.age".publicKeys = allKeys;
  "n8n-admin-password.age".publicKeys = allKeys;
  # n8n API key for Claude Code MCP integration
  # Generate in n8n: Settings > API > Create API Key
  "n8n-api-key.age".publicKeys = allKeys;

  # OpenAI API key (for TTS/STT - separate from OpenRouter)
  "openai-api-key.age".publicKeys = allKeys;

  # E2E test credentials - shared across all hosts for testing
  "e2e-test-api-key.age".publicKeys = allKeys;

  # UniFi Network MCP - controller password for AI-assisted network management
  "unifi-password.age".publicKeys = allKeys;

  # CalDAV credentials for NixFrame calendar (Apple ID + app-specific password)
  "caldav-credentials.age".publicKeys = allKeys;

  # ── Backup infrastructure (disaster recovery) ───────────────────────────
  # WARNING: .age files must be created BEFORE deploying rpi5-full with backup enabled.
  # Without them, agenix activation fails on rpi5. Do NOT rebuild rpi5 until provisioned.
  #
  # Restic repository password — shared between sancta-claw (backup source)
  # and rpi5 (backup destination where restic repo lives)
  # Create: agenix -e secrets/restic-password.age
  "restic-password.age".publicKeys = clawKeys;

  # SSH private key for rpi5 → sancta-claw backup pull
  # Generate: ssh-keygen -t ed25519 -C "rpi5-backup" -f /tmp/rpi5-backup
  # The public key goes in hosts/sancta-claw/backup-user.nix (replace PUBKEY_PLACEHOLDER)
  # Only rpi5 needs to decrypt this (it holds the private key)
  "rpi5-backup-ssh-key.age".publicKeys = users ++ [ rpi5 ];

  # ── Zero_kuzea secrets (NullClaw bot on dedicated VPS) ─────────────────
  # Uses sancta-claw recovery key (same trust level, both are throwaway VPS)
  # Telegram bot token for Zero_kuzea bot
  "zero-kuzea-telegram-bot-token.age".publicKeys = clawKeys;
}
