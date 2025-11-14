{ config, pkgs, lib, ... }:

{
  # tsidp - Tailscale OIDC Identity Provider - DISABLED
  # Currently not accessible due to tsnet isolation on same host
  # The sancta-choir Tailscale daemon cannot see the idp tsnet node
  # Future: Deploy on separate machine
  services.tsidp.enable = false;

  # Instructions for setting up the auth key:
  # 1. Generate auth key at https://login.tailscale.com/admin/settings/keys
  #    - Make it reusable
  #    - Add tag (e.g., tag:idp)
  # 2. Create the environment file:
  #    echo "TS_AUTHKEY=tskey-auth-xxxxx" | sudo tee /var/lib/secrets/tsidp-env
  #    sudo chmod 600 /var/lib/secrets/tsidp-env
}
