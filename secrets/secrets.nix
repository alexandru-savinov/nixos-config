let
  # Personal keys for editing secrets
  # This is the authorized key already in your configuration.nix
  root-sancta-choir = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPw5RFrFfZQUWlyfGSU1Q8BlEHnvIdBtcnCn+uYtEzal nixos-sancta-choir";

  # System host keys (can decrypt on the target system)
  sancta-choir = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILkqRZZKLsSV7L67Rzh38UDU6F2GeMmgyiVLlQgS70zP root@sancta-choir";

  # Combine users who can edit
  users = [ root-sancta-choir ];

  # Systems that can decrypt
  systems = [ sancta-choir ];

  # All keys (for most secrets)
  allKeys = users ++ systems;
in
{
  # Production secrets
  "open-webui-secret-key.age".publicKeys = allKeys;
  "openrouter-api-key.age".publicKeys = allKeys;
  "oidc-client-secret.age".publicKeys = allKeys;
  "tailscale-auth-key.age".publicKeys = allKeys;
  "tavily-api-key.age".publicKeys = allKeys;
}
