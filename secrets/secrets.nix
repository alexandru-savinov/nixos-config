let
  # Personal keys for editing secrets
  # This is the authorized key already in your configuration.nix
  root-sancta-choir = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPw5RFrFfZQUWlyfGSU1Q8BlEHnvIdBtcnCn+uYtEzal nixos-sancta-choir";

  # System host keys (can decrypt on the target system)
  sancta-choir = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILkqRZZKLsSV7L67Rzh38UDU6F2GeMmgyiVLlQgS70zP root@sancta-choir";

  # Raspberry Pi 5 host key
  # IMPORTANT: Replace this placeholder after first boot!
  # Get the key with: ssh-keyscan -t ed25519 <rpi5-ip> 2>/dev/null | awk '{print $2 " " $3}'
  # Or on the Pi: cat /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $1 " " $2}'
  rpi5 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAa root@rpi5-placeholder";

  # Combine users who can edit
  users = [ root-sancta-choir ];

  # Systems that can decrypt
  systems = [ sancta-choir rpi5 ];

  # All keys (for secrets shared across all hosts)
  allKeys = users ++ systems;

  # Keys for sancta-choir only
  sanctaChoirKeys = users ++ [ sancta-choir ];
in
{
  # Tailscale - shared across all hosts
  "tailscale-auth-key.age".publicKeys = allKeys;

  # Open-WebUI secrets - shared across sancta-choir and rpi5
  "open-webui-secret-key.age".publicKeys = allKeys;
  "openrouter-api-key.age".publicKeys = allKeys;
  "tavily-api-key.age".publicKeys = allKeys;

  # OIDC client secret - sancta-choir only (tsidp not on rpi5)
  "oidc-client-secret.age".publicKeys = sanctaChoirKeys;

  # OpenCode API key (Open WebUI API key for LLM gateway)
  "opencode-api-key.age".publicKeys = sanctaChoirKeys;
}
