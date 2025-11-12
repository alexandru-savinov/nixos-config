{ config, pkgs, lib, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../common.nix
    ../../modules/system/host.nix
    ../../modules/system/networking.nix
    ../../modules/users/root.nix
    ../../modules/services/copilot.nix
  ];

  # Hostname - keep current production hostname
  networking.hostName = "sancta-gw";
  networking.domain = "";

  # SSH authorized keys - NOTE: Store actual keys in secrets management
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPw5RFrFfZQUWlyfGSU1Q8BlEHnvIdBtcnCn+uYtEzal nixos-sancta-gw"
  ];
}
