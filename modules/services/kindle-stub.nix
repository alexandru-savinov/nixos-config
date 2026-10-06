{ config
, pkgs
, lib
, ...
}:

# Answers the Kindle's Wi-Fi connectivity check for the isolated «kindle» VLAN.
#
# A Kindle will not stay on a network until it fetches
# http://spectrum.s3.amazonaws.com/kindle-wifi/wifistub-eink.html and finds a
# fixed UUID in it. That VLAN has no internet, so the UniFi gateway points that
# hostname at this host (static DNS record) and this service answers locally.
# Amazon no longer serves the -eink file, so both paths return the UUID body
# of the original wifistub.html. "/" and "/check" show whether the caller is
# on the kindle subnet. Every other path is 404.
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

  serveJs = pkgs.writeText "kindle-stub.js" ''
    const http = require("http");
    const fs = require("fs");
    const UUID = fs.readFileSync("${wifistub}");
    const ROUTES = {
      "/kindle-wifi/wifistub.html": UUID,
      "/kindle-wifi/wifistub-eink.html": UUID,
    };
    const PREFIX = "${subnetPrefix}";

    http.createServer(function (q, r) {
      var p = (q.url || "").split("?")[0];
      var ip = (q.socket.remoteAddress || "").replace("::ffff:", "");
      if (q.method === "GET" && ROUTES[p]) {
        r.writeHead(200, { "Content-Type": "text/html", "Content-Length": ROUTES[p].length });
        r.end(ROUTES[p]);
      } else if (q.method === "GET" && (p === "/" || p === "/check")) {
        var ok = ip.indexOf(PREFIX) === 0;
        var b = Buffer.from(
          "<html><body><h1>" + (ok ? "OK" : "NOT ISOLATED") + "</h1>" +
          "<p>You are " + ip + "</p>" +
          "<p>" + (ok ? "On the kindle network, served by rpi5." : "This device is NOT on the kindle network.") + "</p>" +
          "<p>" + new Date().toISOString().slice(0, 19) + "Z</p></body></html>");
        r.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Content-Length": b.length });
        r.end(b);
      } else {
        r.writeHead(404);
        r.end();
      }
      console.log(ip + " " + q.method + " " + q.url + " " + r.statusCode);
    // Not 127.0.0.1: the Kindle reaches this host over the LAN. The nixos-fw rule below is the gate.
    }).listen(${toString cfg.port}, "0.0.0.0");
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
      serviceConfig = {
        ExecStart = "${lib.getExe pkgs.nodejs} ${serveJs}";
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
