# Vigil's SOC sensors on one node, read through the real checker: each contract goes
# verde at rest, picat on a planted event, and NECITIT when its sensor stops.
#
# Netdata clamps `min training window` to 900 s (src/ml/ml_config.cc, 2.8.4), so the plan's
# shorter window does not exist and this test waits out the 15 minutes. Ticks are driven by
# hand, and they keep running through the wait so training sees their CPU spikes as normal.
{ pkgs }:
let
  inherit (pkgs) lib;

  # The real hub files at a fixed revision: cscli hub update needs the network, and the point
  # is that this acquisition feeds these parsers, not that a stand-in scenario fires.
  hubRev = "22393a8bd820a3f6033b114adbefacca9cd120a2";
  hubFile = hash: path: pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/crowdsecurity/hub/${hubRev}/${path}";
    inherit hash;
  };
  hubLink = stage: hash: path:
    "L+ /etc/crowdsec/${stage}/${baseNameOf path} - - - - ${hubFile hash path}";

  # A flat load stops being anomalous within seconds: Netdata models the difference between
  # samples (`num samples to diff`, default 1), so only the edges of a step score high.
  burn = pkgs.writeShellScript "cpu-burn" ''
    while true; do
      ${lib.getExe pkgs.stress-ng} --cpu 0 --timeout 4s --quiet
      ${pkgs.coreutils}/bin/sleep 4
    done
  '';
in
pkgs.testers.runNixOSTest {
  name = "vigil-soc";
  # Netdata's training floor alone is 15 minutes of this.
  globalTimeout = 3000;

  nodes.machine = { lib, pkgs, ... }: {
    imports = [ ../modules/services/vigil.nix ];

    virtualisation = { memorySize = 2048; cores = 2; diskSize = 2048; };

    environment.systemPackages = [ pkgs.sshpass pkgs.iproute2 ];
    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = true;
        # 10.x otherwise refuses the source after three failures, before ten can land.
        PerSourcePenalties = "no";
      };
    };

    # A token the sender rejects without trying the network, so the outbox holds the events.
    environment.etc."vigil-telegram".text = ''
      TELEGRAM_BOT_TOKEN=offline
      TELEGRAM_CHAT_ID=0
    '';

    services.vigil = {
      enable = true;
      expectedContracts = 7;
      listenAddress = "100.64.0.1";
      telegramEnvFile = "/etc/vigil-telegram";
      interval = "30s";
      sensors = {
        crowdsec.enable = true;
        netdata.enable = true;
        osquery = { enable = true; interval = 30; };
      };
    };
    systemd.timers.vigil.enable = false;

    # Offline form of the module's setup script, which aborts on cscli hub update. An empty
    # index is a valid hub: everything below is a local item.
    services.crowdsec.hub.collections = lib.mkForce [ ];
    systemd.services.crowdsec.serviceConfig.ExecStartPre = lib.mkForce [
      " "
      (pkgs.writeShellScript "crowdsec-offline-setup" ''
        set -eu
        ${pkgs.coreutils}/bin/mkdir -p /var/lib/crowdsec/state/hub
        echo '{}' > /var/lib/crowdsec/state/hub/.index.json
        if [ ! -s /var/lib/crowdsec/state/local_api_credentials.yaml ]; then
          /run/current-system/sw/bin/cscli machine add machine --auto
        fi
      '')
    ];
    systemd.tmpfiles.rules = [
      (hubLink "parsers/s00-raw" "sha256-a02UIEVeedoyipvsB+6O5mP0m5GpluiZFBHbQacpTtA=" "parsers/s00-raw/crowdsecurity/syslog-logs.yaml")
      (hubLink "parsers/s01-parse" "sha256-BF/0x4lYiL7PFhqGZuwXPEW1jlLypyWDoD8itAIDOQ0=" "parsers/s01-parse/crowdsecurity/sshd-logs.yaml")
      (hubLink "parsers/s02-enrich" "sha256-P1Gmw4m78cOPSdiCS2v/2aJl0Pp4qYr3FiglYBmEeVE=" "parsers/s02-enrich/crowdsecurity/dateparse-enrich.yaml")
      (hubLink "parsers/s02-enrich" "sha256-lAMi3uoldpg4iYFSm71Zpi3JY+TdSJ20T8y/0SeQOl0=" "parsers/s02-enrich/crowdsecurity/whitelists.yaml")
      (hubLink "scenarios" "sha256-JC82aE1mu64wROV2t8//72LVMjRl8/dPh5IxZ8bZM1Y=" "scenarios/crowdsecurity/ssh-bf.yaml")
    ];

    # Models are built at about one per second, so train the two watched charts and nothing
    # else, or the gate on untrained metrics adds minutes per thousand metrics.
    services.netdata.config.ml."charts to skip from training" = "!system.cpu !system.ram *";
  };

  testScript = ''
    import json
    import time

    OSQUERY = ["porturi-noi", "utilizatori-noi", "suid-nou", "etc-schimbat"]
    ANOMALY = ["cpu-anomalie", "mem-anomalie"]
    ALL = ["ssh-bruteforce"] + OSQUERY + ANOMALY
    # Whitelisted by the hub for loopback and every private range, so a test-net address.
    ATTACKER = "203.0.113.7"


    def tick():
        machine.succeed("systemctl start vigil.service")
        machine.succeed("journalctl --sync")
        # The cursor limits this to the run above: a finished oneshot keeps no InvocationID.
        lines = machine.succeed(
            "journalctl -u vigil.service -o cat --no-pager --cursor-file=/tmp/vigil.cursor"
        ).splitlines()
        rows = [json.loads(line) for line in lines if line.startswith('{"nume"')]
        verdicts = {row["nume"]: row for row in rows}
        assert sorted(verdicts) == sorted(ALL), verdicts
        return verdicts


    def summary(rows, names):
        return {name: (rows[name]["verdict"], rows[name]["motiv"]) for name in names}


    def settle(expected, timeout, names=None, pause=10):
        """Tick until every named contract holds its verdict, or fail showing the last row."""
        names = ALL if names is None else names
        deadline = time.monotonic() + timeout
        while True:
            rows = tick()
            if all(rows[name]["verdict"] == expected for name in names):
                return rows
            if time.monotonic() > deadline:
                raise Exception(f"want {expected}: {summary(rows, names)}")
            machine.sleep(pause)


    def incidents():
        return json.loads(machine.succeed("cat /var/lib/vigil/incidents.json"))["contracts"]


    start_all()

    with subtest("sensors come up on loopback"):
        machine.wait_for_unit("sshd.service")
        machine.wait_for_unit("crowdsec.service")
        machine.wait_for_unit("osqueryd.service")
        machine.wait_for_unit("netdata.service")
        machine.wait_for_file("/var/lib/vigil/crowdsec.yaml")
        mode = machine.succeed("stat -c '%U %a' /var/lib/vigil/crowdsec.yaml").strip()
        assert mode == "vigil 400", mode
        machine.wait_for_open_port(8088)
        machine.wait_for_open_port(19999)
        sockets = machine.succeed("ss -ltnH")
        for port in ["8088", "19999"]:
            assert f"127.0.0.1:{port}" in sockets, sockets
            assert f"0.0.0.0:{port}" not in sockets, sockets
            assert f"*:{port}" not in sockets, sockets

    with subtest("at rest: the fast contracts read verde, untrained models do not"):
        first = settle("verde", 180, ["ssh-bruteforce"] + OSQUERY)
        for name in ANOMALY:
            assert first[name]["verdict"] == "NECITIT", summary(first, ANOMALY)

    with subtest("failed ssh logins fire ssh-bruteforce and open an incident"):
        machine.succeed(f"ip addr add {ATTACKER}/32 dev lo")
        for _ in range(10):
            machine.execute(
                "sshpass -p wrong ssh -o StrictHostKeyChecking=no"
                " -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password"
                f" -o NumberOfPasswordPrompts=1 -b {ATTACKER} intruder@{ATTACKER} true"
            )
        rows = settle("picat", 120, ["ssh-bruteforce"])
        assert rows["ssh-bruteforce"]["motiv"] == "crowdsec-alerts", rows["ssh-bruteforce"]
        assert incidents()["ssh-bruteforce"]["open"], incidents()["ssh-bruteforce"]

    with subtest("a new listener fires porturi-noi, and closing it clears the verdict"):
        machine.succeed("systemd-run --unit=planted-listener ${pkgs.netcat-openbsd}/bin/nc -lk 4444")
        machine.wait_for_open_port(4444)
        rows = settle("picat", 120, ["porturi-noi"])
        assert any(key.startswith("4444/6/") for key in rows["porturi-noi"]["detaliu"]), rows
        machine.succeed("systemctl stop planted-listener")
        settle("verde", 120, ["porturi-noi"])

    with subtest("a change under /etc fires etc-schimbat"):
        machine.succeed("touch /etc/vigil-soc-planted")
        rows = settle("picat", 120, ["etc-schimbat"], pause=5)
        assert any("vigil-soc-planted" in key for key in rows["etc-schimbat"]["detaliu"]), rows

    with subtest("once trained, the anomaly contracts read verde"):
        settle("verde", 1500, ANOMALY, pause=15)

    with subtest("an oscillating CPU load fires cpu-anomalie and opens an incident"):
        machine.succeed("systemd-run --unit=cpu-burn ${burn}")
        deadline = time.monotonic() + 240
        while not incidents()["cpu-anomalie"]["open"]:
            rows = tick()
            print(summary(rows, ANOMALY), incidents()["cpu-anomalie"])
            assert time.monotonic() < deadline, summary(rows, ANOMALY)
            machine.sleep(10)
        machine.succeed("systemctl stop cpu-burn")

    with subtest("stopping each sensor reads NECITIT, never verde"):
        machine.succeed("systemctl stop crowdsec.service")
        rows = tick()
        assert rows["ssh-bruteforce"]["verdict"] == "NECITIT", rows["ssh-bruteforce"]

        machine.succeed("systemctl stop netdata.service")
        rows = tick()
        for name in ANOMALY:
            assert rows[name]["verdict"] == "NECITIT", rows[name]

        # A snapshot stays valid for two intervals, by contract.
        machine.succeed("systemctl stop osqueryd.service")
        machine.sleep(2 * 30 + 5)
        rows = tick()
        for name in OSQUERY:
            assert rows[name]["verdict"] == "NECITIT", rows[name]
  '';
}
