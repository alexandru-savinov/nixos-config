{ config, pkgs, lib, ... }:

{
  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # Networking
  networking.hostName = lib.mkForce "sancta-choir";
  networking.useDHCP = false;
  networking.interfaces.eth0 = {
    useDHCP = false;
    ipv4.addresses = [{
      address = "116.203.223.113";
      prefixLength = 32;
    }];
  };
  networking.defaultGateway = {
    address = "172.31.1.1";
    interface = "eth0";
  };
  networking.nameservers = [ "185.12.64.1" "185.12.64.2" ];

  # Additional route for Hetzner Cloud gateway
  networking.localCommands = ''
    ${pkgs.iproute2}/bin/ip route add 172.31.1.1 dev eth0 || true
  '';

  # SSH
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  # Users - SSH key
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPw5RFrFfZQUWlyfGSU1Q8BlEHnvIdBtcnCn+uYtEzal nixos-sancta-choir"
  ];

  # VSCode Server support
  services.vscode-server.enable = true;

  # Firewall
  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 ];

  # System packages (basic utilities in common.nix)
  environment.systemPackages = with pkgs; [
    helix
    tmux
    htop
    tree
    ripgrep
    fd
    btop
    nodejs_22
    gh
    github-copilot-cli
    # Nix development tools
    nixpkgs-fmt
    nil # Nix language server
  ];

  # Time zone
  time.timeZone = "UTC";

  # Locale
  i18n.defaultLocale = "en_US.UTF-8";
}
