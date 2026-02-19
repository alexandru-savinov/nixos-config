# Ephemeral Hetzner Cloud VPS — on-demand, short-lived instance
#
# Provisioned via nixos-anywhere with DHCP networking (IP unknown at config time).
# Tailscale auth key injected via --extra-files (no agenix on first boot).
#
# Usage:
#   nixos-anywhere --build-on-remote \
#     --extra-files /tmp/hetzner-extra \
#     --flake .#hetzner-ephemeral \
#     root@<ip>

{ config
, pkgs
, lib
, self
, claude-code
, ...
}:

{
  imports = [
    ../common.nix
    ../../modules/system/hetzner-cloud.nix
    ../../modules/system/hetzner-disko.nix
    ../../modules/system/dev-tools.nix
    ../../modules/users/root.nix
    ../../modules/services/claude.nix
  ];

  # Hetzner Cloud with DHCP (no static IP for ephemeral instances)
  hetzner-cloud.enable = true;

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # Enable development tools and Claude Code
  customModules.dev-tools.enable = true;
  customModules.claude.enable = true;

  # Hostname (overridden at create time via networking.hostName in --extra-files)
  networking.hostName = lib.mkDefault "hetzner-ephemeral";
  networking.domain = "";

  # Tailscale — bootstrapped via --extra-files auth key
  # The create script injects /etc/tailscale-auth-key via --extra-files.
  # This service reads it on first boot and authenticates with Tailscale.
  services.tailscale = {
    enable = true;
    port = 41641;
    interfaceName = "tailscale0";
    useRoutingFeatures = "client";
    openFirewall = true;
    extraUpFlags = [
      "--ssh"
      "--accept-routes"
    ];
  };

  # Trust Tailscale interface
  networking.firewall.trustedInterfaces = [ "tailscale0" ];

  # Bootstrap Tailscale with auth key from --extra-files
  # This runs once on first boot, reads the injected key, and authenticates.
  # After authentication, the key file is deleted (it's single-use anyway).
  systemd.services.tailscale-bootstrap = {
    description = "Bootstrap Tailscale with injected auth key";
    after = [ "tailscaled.service" "network-online.target" ];
    wants = [ "tailscaled.service" "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    # Only run if the key file exists (first boot only)
    unitConfig.ConditionPathExists = "/etc/tailscale-auth-key";

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      set -euo pipefail
      AUTH_KEY=$(cat /etc/tailscale-auth-key)
      ${pkgs.tailscale}/bin/tailscale up --auth-key="$AUTH_KEY" --ssh --accept-routes
      rm -f /etc/tailscale-auth-key
      echo "Tailscale bootstrap complete"
    '';
  };

  # SSH authorized keys for remote access
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPw5RFrFfZQUWlyfGSU1Q8BlEHnvIdBtcnCn+uYtEzal nixos-sancta-choir"
  ];

  # Time zone and locale
  time.timeZone = "Europe/Chisinau";
  i18n.defaultLocale = "en_US.UTF-8";

  # Override stateVersion from common.nix (new instance, use current release)
  system.stateVersion = lib.mkForce "25.05";
}
