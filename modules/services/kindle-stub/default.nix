{ config
, pkgs
, lib
, ...
}:

# Answers the Kindle's Wi-Fi connectivity check for the isolated «kindle» VLAN,
# and serves one book to read on it.
#
# A Kindle will not stay on a network until it fetches
# http://spectrum.s3.amazonaws.com/kindle-wifi/wifistub-eink.html and finds a
# fixed UUID in it. That VLAN has no internet, so the UniFi gateway points that
# hostname at this host (static DNS record) and this service answers locally.
# Amazon no longer serves the -eink file, so both paths return the UUID body
# of the original wifistub.html. "/check" shows whether the caller is on the
# kindle subnet.
#
# The reader: a shelf of public-domain books, each from a pinned ru.wikisource
# revision, turned into paged HTML at build time by build.js:
#   «Пятнадцатилетний капитан», Jules Verne, tr. Игнатий Петров (1934)
#   «Капитанская дочка», Александр Пушкин (1836)
# "/" is the shelf; "/b/<slug>" resumes a book; "/r/<id>" is a chapter
# ("1-1".."2-20" for the Captain, "d-1".."d-15" for the Daughter) or a
# contents page ("index", "d-index"). Each page keeps its book's position in
# localStorage and also sends it to "/pos", which stores it per book under
# StateDirectory, so a wiped Kindle browser still resumes. "/img/<name>.jpg"
# serves the pictures pictures.json places in the text (public-domain
# engravings and drawings, each credited under it) and the shelf covers.
# Every other path is 404.
#
# The picture files are not in the store (about 20 MB of JPEGs would bloat
# this public repo): they live in imagesDir, prepared once by hand. A picture
# missing there is a 404 and the page shows its caption only.
#
# Depends on controller state that is NOT in this repo: the kindle network
# and firewall rules, plus static DNS records for spectrum.s3.amazonaws.com
# and k.lan pointing at this host.

let
  cfg = config.customModules.kindleStub;

  subnetPrefix =
    lib.concatStringsSep "." (lib.take 3 (lib.splitString "." (builtins.head (lib.splitString "/" cfg.allowedSubnet)))) + ".";

  wifistub = pkgs.writeText "kindle-wifistub.html"
    "<html>\n<body>\n81ce4465-7167-4dcb-835b-dcc9e44c112a\n</body>\n</html>\n";

  reader = import ./reader.nix { inherit pkgs; };

  listenAddress = "${cfg.bindAddress}:${toString cfg.port}";
  fwRule = "-p tcp -s ${cfg.allowedSubnet} -d ${cfg.bindAddress} --dport ${toString cfg.port} -j nixos-fw-accept";
  kindleOnly = {
    IPAddressAllow = [ cfg.allowedSubnet ];
    IPAddressDeny = "any";
  };
in
{
  options.customModules.kindleStub = {
    enable = lib.mkEnableOption "the Kindle Wi-Fi check stub for the isolated kindle VLAN";

    bindAddress = lib.mkOption {
      type = lib.types.strMatching "[0-9]{1,3}(\\.[0-9]{1,3}){3}";
      description = "Local IPv4 address reached by the Kindle. Use its VLAN address when the host has one.";
    };

    allowedSubnet = lib.mkOption {
      type = lib.types.str;
      default = "192.168.30.0/24";
      description = ''
        The only source subnet allowed through this host's firewall to reach
        the stub. Must be a /24: the check page derives its "on the kindle
        network" test from the first three octets.
      '';
    };

    imagesDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/kindle-reader-images";
      description = "Directory holding the JPEGs listed in pictures.json (readable by any user).";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 80;
      description = "Port the Kindle fetches its connectivity check on. Kindles expect plain HTTP on 80.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.bindAddress != "0.0.0.0";
        message = "customModules.kindleStub.bindAddress must name a single local address.";
      }
      {
        assertion = !config.networking.nftables.enable;
        message = "customModules.kindleStub opens its port with iptables extraCommands, which the nftables firewall backend ignores.";
      }
    ];

    systemd.sockets.kindle-stub = {
      description = "Kindle Wi-Fi check stub listener on ${listenAddress}";
      wantedBy = [ "sockets.target" ];
      # PID 1 binds even port 80 and passes the socket to unprivileged Node.
      # Filter here as well as on the service: inherited sockets use this unit's filter.
      socketConfig = kindleOnly // {
        ListenStream = listenAddress;
        FreeBind = true; # The LAN address may arrive by DHCP after sockets.target.
      };
    };

    systemd.services.kindle-stub = {
      description = "Kindle Wi-Fi check stub for the kindle VLAN";
      wantedBy = [ "multi-user.target" ];
      partOf = [ "kindle-stub.socket" ];
      # NixOS switches skip socket-only changes. Restart both units so the
      # eager service starts with the new listener.
      restartTriggers = [ config.systemd.units."kindle-stub.socket".unit ];
      notSocketActivated = true;
      environment = {
        # systemd creates it; with DynamicUser it lives at /var/lib/private/kindle-reader.
        STATE_DIR = "/var/lib/kindle-reader";
        READER_DIR = "${reader}";
        WIFISTUB = "${wifistub}";
        SUBNET_PREFIX = subnetPrefix;
        IMG_DIR = cfg.imagesDir;
      };
      serviceConfig = kindleOnly // {
        ExecStart = "${lib.getExe pkgs.nodejs} ${./server.js}";
        Sockets = "kindle-stub.socket";
        StateDirectory = "kindle-reader";
        StateDirectoryMode = "0700";
        Restart = "always";
        RestartSec = 5;

        DynamicUser = true;
        CapabilityBoundingSet = "";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        SystemCallArchitectures = "native";
      };
    };

    networking.firewall.extraCommands = "iptables -I nixos-fw ${fwRule}";
    networking.firewall.extraStopCommands = "iptables -D nixos-fw ${fwRule} 2>/dev/null || true";
  };
}
