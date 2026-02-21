let
  # Personal keys for editing secrets
  # This is the authorized key already in your configuration.nix
  root-sancta-choir = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPw5RFrFfZQUWlyfGSU1Q8BlEHnvIdBtcnCn+uYtEzal nixos-sancta-choir";

  # System host keys (can decrypt on the target system)
  sancta-kuzea = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILkqRZZKLsSV7L67Rzh38UDU6F2GeMmgyiVLlQgS70zP root@sancta-choir";

  # Raspberry Pi 5 host key
  rpi5 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBjZXKDY8Ve/wfMHpjsJGR7guDQFndGoNxDZKXegEfjr root@rpi5";

  # sancta-claw VPS host key (Hetzner CX33, nbg1-dc3)
  sancta-claw = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGPSg59xhgMmUcxRS9Yw76z57DiVib3kXHyw52RAThcs";

  # Combine users who can edit
  users = [ root-sancta-choir ];

  # Systems that can decrypt
  systems = [ sancta-kuzea rpi5 ];

  # All keys (for secrets shared across all hosts)
  allKeys = users ++ systems;
in
{
  # Tailscale - shared across all hosts (including sancta-claw)
  "tailscale-auth-key.age".publicKeys = allKeys ++ [ sancta-claw ];

  # Open-WebUI secrets - shared across sancta-choir and rpi5
  "open-webui-secret-key.age".publicKeys = allKeys;
  "openrouter-api-key.age".publicKeys = allKeys;
  "tavily-api-key.age".publicKeys = allKeys;

  # n8n workflow automation - shared across all hosts
  "n8n-encryption-key.age".publicKeys = allKeys;
  "n8n-admin-password.age".publicKeys = allKeys;
  # n8n API key for Claude Code MCP integration
  # Generate in n8n: Settings > API > Create API Key
  "n8n-api-key.age".publicKeys = allKeys;

  # OIDC client secret - legacy (was sancta-choir only, tsidp removed from kuzea)
  "oidc-client-secret.age".publicKeys = allKeys;

  # OpenAI API key (for TTS/STT - separate from OpenRouter)
  "openai-api-key.age".publicKeys = allKeys;

  # E2E test credentials - shared across all hosts for testing
  "e2e-test-api-key.age".publicKeys = allKeys;

  # UniFi Network MCP - controller password for AI-assisted network management
  "unifi-password.age".publicKeys = allKeys;

  # OpenClaw AI programming partner
  "anthropic-api-key.age".publicKeys = allKeys;
  "openclaw-github-token.age".publicKeys = allKeys;

  # CalDAV credentials for NixFrame calendar (Apple ID + app-specific password)
  "caldav-credentials.age".publicKeys = allKeys;
}
