{ lib, ... }:

{
  # Hetzner Cloud networking configuration
  networking.useDHCP = false;
  networking.usePredictableInterfaceNames = lib.mkForce false;
  networking.dhcpcd.enable = false;

  networking.nameservers = [ "8.8.8.8" "185.12.64.1" "185.12.64.2" ];

  # Interface configuration for Hetzner Cloud
  networking.interfaces.eth0 = {
    useDHCP = false;
    ipv4.addresses = [{
      address = "116.203.223.113";
      prefixLength = 32;
    }];
    ipv6.addresses = [{
      address = "fe80::9000:6ff:febb:9603";
      prefixLength = 64;
    }];
    ipv4.routes = [{ address = "172.31.1.1"; prefixLength = 32; }];
  };

  networking.defaultGateway = {
    address = "172.31.1.1";
    interface = "eth0";
  };

  # MAC address binding
  services.udev.extraRules = ''
    ATTR{address}=="92:00:06:bb:96:03", NAME="eth0"
  '';
}
