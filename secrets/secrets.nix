let
  # Personal keys for editing secrets
  # This is the authorized key already in your configuration.nix
  root-sancta-choir = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPw5RFrFfZQUWlyfGSU1Q8BlEHnvIdBtcnCn+uYtEzal nixos-sancta-choir";

  # Raspberry Pi 5 host key
  rpi5 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBjZXKDY8Ve/wfMHpjsJGR7guDQFndGoNxDZKXegEfjr root@rpi5";

  # sancta-choir VPS host key (Hetzner cx33, x86_64)
  sancta-choir = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMhS/MNrRr4FLmfWv2jNWz7WTr/AnD9fD3keXltRWXe root@sancta-choir";

  # sancta-claw stable age identity for DR — NOT tied to SSH host key.
  # Decoupled from host identity so nixos-anywhere + --extra-files enables
  # secret decryption on first boot without re-keying.
  # Private key stored on: rpi5:/root/dr/recovery-sancta-claw.key + Bitwarden
  sancta-claw = "age1zex0chkw9swv62khuw73lftpcagu6t7d8vqa2h9mmnm23249hpuqx8f2kt";

  # hermes-claw stable recovery key for DR — NOT tied to SSH host key.
  # Same decoupling rationale as sancta-claw: shipped via nixos-anywhere
  # --extra-files to /root/.age/recovery.key on first boot.
  # Private key stored on: rpi5:/root/dr/recovery-hermes-claw.key (matches
  # sancta-claw's pattern). Add to Bitwarden as a second copy for full DR.
  # SHA-256: 54e9bca5983b1fecf61cef237315a2b7af89c9d6cd825ba13abe69745bc0bc41
  hermes-claw = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFtsTISx+ZrSicSwy54zo/ZBd7DG8vemMQxOMZzJyFOY hermes-claw recovery key";

  # Combine users who can edit
  users = [ root-sancta-choir ];

  # Systems that can decrypt shared secrets
  systems = [
    rpi5
    sancta-choir
  ];

  # All keys (for secrets shared across all hosts)
  allKeys = users ++ systems;

  # allKeys + sancta-claw (for secrets shared across all hosts including the VPS)
  allPlusClaw = allKeys ++ [ sancta-claw ];

  # allKeys + sancta-claw + hermes-claw (for secrets shared with both claw VPSes)
  allPlusBoth = allPlusClaw ++ [ hermes-claw ];

  # Keys for Kuzea-specific secrets (sancta-claw + owner machines)
  # rpi5 included so Alexandru can edit/re-encrypt from rpi5-full
  clawKeys = users ++ [
    sancta-claw
    rpi5
  ];
in
{
  # Tailscale - shared across all hosts (including sancta-claw + hermes-claw)
  "tailscale-auth-key.age".publicKeys = allPlusBoth;

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
  "openrouter-api-key.age".publicKeys = allPlusBoth;

  # OpenRouter virtual keys (Sancta Port). Two-tier prd/dev staging.
  # prd: raw key format (owui, openclaw+zdr-proxy, n8n).
  # dev: env-file format (hermes, OPENROUTER_API_KEY=...).
  # Coexists with openrouter-api-key.age until cleanup task.
  "sancta-port-openrouter-prd.age".publicKeys = users ++ [ sancta-choir sancta-claw rpi5 ];
  "sancta-port-openrouter-dev.age".publicKeys = users ++ [ hermes-claw ];
  "tavily-api-key.age".publicKeys = allKeys;

  # Tavily API key for Kuzea web search (separate from open-webui)
  "kuzea-tavily-api-key.age".publicKeys = clawKeys;

  # n8n workflow automation - shared across all hosts
  "n8n-encryption-key.age".publicKeys = allKeys;
  "n8n-admin-password.age".publicKeys = allKeys;
  # n8n API key for Claude Code MCP integration
  # Generate in n8n: Settings > API > Create API Key
  "n8n-api-key.age".publicKeys = allKeys;

  # OpenAI API key (for TTS/STT + OpenClaw memory embeddings on sancta-claw)
  "openai-api-key.age".publicKeys = allPlusClaw;

  # Telegram bot token for n8n workflow notifications (tender monitor, etc.)
  "telegram-bot-token.age".publicKeys = allKeys;

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

  # Telegram credentials for backup failure alerts (TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID)
  # EnvironmentFile format — only rpi5 needs this (runs the backup service)
  "backup-telegram-env.age".publicKeys = users ++ [ rpi5 ];

  # ── Home Assistant secrets (rpi5 only) ─────────────────────────────────
  # WARNING: registering a key here is INERT — it does NOT create the .age
  # file. The .age must be created with `agenix -e` BEFORE any host config
  # declares `age.secrets.home-assistant-token` (or -secrets) pointing at it,
  # otherwise agenix activation fails the whole nixos-rebuild switch.
  # This is the Phase A chicken-and-egg fix: keys registered now, but
  # host wiring (in hosts/rpi5-full/configuration.nix) is deferred until
  # after the human onboarding checkpoint (see plan-home-assistant.md Task 5).
  #
  # Long-Lived Access Token for hass-cli + HA MCP — minted in HA UI after
  # owner onboarding (Profile → Security → Long-lived access tokens)
  "home-assistant-token.age".publicKeys = users ++ [ rpi5 ];
  # NOTE: home-assistant-secrets.age is intentionally NOT registered — HA's own
  # secrets.yaml is unused here, and registering a key without creating its .age
  # is a footgun (a future host config wiring age.secrets before `agenix -e`
  # creates the file would fail activation). Re-add the line AND create the .age
  # in the same change if you ever need HA !secret values.

  # ── Zero_kuzea secrets (NullClaw bot on dedicated VPS) ─────────────────
  # Uses sancta-claw recovery key (same trust level, both are throwaway VPS)
  # Telegram bot token for Zero_kuzea bot — also re-keyed for hermes-claw
  # so the Hermes Agent on hermes-claw can decrypt the same plaintext.
  "zero-kuzea-telegram-bot-token.age".publicKeys = clawKeys ++ [ hermes-claw ];

  # Anthropic API key (setup key from OpenClaw Pro subscription)
  "anthropic-api-key.age".publicKeys = clawKeys;

  # ── Hermes Agent combined env file (hermes-claw) ─────────────────────
  # KEY=VALUE format for the upstream NixOS module's environmentFiles.
  # Contains OPENROUTER_API_KEY + TELEGRAM_BOT_TOKEN (same plaintext as
  # the per-value secrets above, combined into one env file).
  "hermes-env.age".publicKeys = users ++ [ rpi5 hermes-claw ];
}
