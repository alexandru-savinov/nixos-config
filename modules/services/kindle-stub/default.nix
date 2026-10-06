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
# The reader: «Пятнадцатилетний капитан», Jules Verne, Russian translation by
# Игнатий Петров (1934, public domain), from a pinned ru.wikisource revision,
# turned into paged HTML at build time by build.js. "/" resumes the last read
# position; "/r/<id>" is a chapter ("1-1".."2-20") or "index" (contents).
# The page keeps the position in localStorage and also sends it to "/pos",
# which stores it under StateDirectory, so a wiped Kindle browser still
# resumes. Every other path is 404.
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

  # https://ru.wikisource.org/wiki/Пятнадцатилетний_капитан_(Верн;_Петров), revision 5648532 (2025-09-10).
  bookText = pkgs.fetchurl {
    name = "pyatnadcatiletniy-kapitan-5648532.wiki";
    url = "https://ru.wikisource.org/w/index.php?title=%D0%9F%D1%8F%D1%82%D0%BD%D0%B0%D0%B4%D1%86%D0%B0%D1%82%D0%B8%D0%BB%D0%B5%D1%82%D0%BD%D0%B8%D0%B9_%D0%BA%D0%B0%D0%BF%D0%B8%D1%82%D0%B0%D0%BD_(%D0%92%D0%B5%D1%80%D0%BD;_%D0%9F%D0%B5%D1%82%D1%80%D0%BE%D0%B2)&oldid=5648532&action=raw";
    hash = "sha256-d0AwVZ8mMntCwc332ExSPII1VWOSJh6SQWmeRXIaUlw=";
  };

  reader = pkgs.runCommand "kindle-reader" { nativeBuildInputs = [ pkgs.nodejs ]; } ''
    node ${./build.js} ${bookText} ${./page.tpl.html} $out
  '';

  fwRule = "-p tcp -s ${cfg.allowedSubnet} --dport ${toString cfg.port} -j nixos-fw-accept";
in
{
  options.customModules.kindleStub = {
    enable = lib.mkEnableOption "the Kindle Wi-Fi check stub for the isolated kindle VLAN";

    allowedSubnet = lib.mkOption {
      type = lib.types.str;
      default = "192.168.30.0/24";
      description = ''
        The only source subnet allowed through this host's firewall to reach
        the stub. Must be a /24: the check page derives its "on the kindle
        network" test from the first three octets.
      '';
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
        assertion = !config.networking.nftables.enable;
        message = "customModules.kindleStub opens its port with iptables extraCommands, which the nftables firewall backend ignores.";
      }
    ];

    systemd.services.kindle-stub = {
      description = "Kindle Wi-Fi check stub for the kindle VLAN";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      environment = {
        PORT = toString cfg.port;
        # systemd creates it; with DynamicUser it lives at /var/lib/private/kindle-reader.
        STATE_DIR = "/var/lib/kindle-reader";
        READER_DIR = "${reader}";
        WIFISTUB = "${wifistub}";
        SUBNET_PREFIX = subnetPrefix;
      };
      serviceConfig = {
        ExecStart = "${lib.getExe pkgs.nodejs} ${./server.js}";
        StateDirectory = "kindle-reader";
        StateDirectoryMode = "0700";
        Restart = "always";
        RestartSec = 5;

        DynamicUser = true;
        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
        CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
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
