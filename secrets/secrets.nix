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

  # All keys (for most secrets)
  allKeys = users ++ systems;

  # Keys for sancta-choir only (excluding rpi5)
  sanctaChoirKeys = users ++ [ sancta-choir ];

  # Keys for rpi5 only
  rpi5Keys = users ++ [ rpi5 ];
in
{
  # Production secrets - shared across all hosts
  "tailscale-auth-key.age".publicKeys = allKeys;

  # Secrets for sancta-choir only
  "open-webui-secret-key.age".publicKeys = sanctaChoirKeys;
  "openrouter-api-key.age".publicKeys = sanctaChoirKeys;
  "oidc-client-secret.age".publicKeys = sanctaChoirKeys;
  "tavily-api-key.age".publicKeys = sanctaChoirKeys;
}
