{ pkgs }:

let
  vigil = pkgs.callPackage ../pkgs/vigil.nix { };
  deadman = ../hosts/sancta-choir/vigil-contracts/soc-audit-deadman.toml;
  # Keep the backdated 31-minute heartbeat on this boot without waiting in the VM.
  procStat = pkgs.writeText "soc-audit-test-proc-stat" "btime 1\n";
  capturePage = pkgs.writeShellScript "capture-soc-page" ''
    if [ "''${2:-}" != --chataction ]; then
      ${pkgs.coreutils}/bin/cat >> /tmp/soc-pages
    fi
  '';
in
pkgs.testers.runNixOSTest {
  name = "soc-audit";
  nodes.machine = { lib, ... }: {
    imports = [ ../modules/services/soc-vigil-alarms.nix ];
    virtualisation.memorySize = 1024;
    virtualisation.diskSize = 4096;
    system.stateVersion = "25.11";

    security.auditd = {
      enable = true;
      settings = {
        max_log_file = 64;
        num_logs = 8;
        max_log_file_action = "ROTATE";
      };
    };
    security.audit = {
      enable = true;
      rules = [
        "-w /run/agenix-canary -p rwa -k agenix-secrets"
        "-w /etc/sudoers -p wa -k sudoers"
      ];
    };
    systemd.services.audit-rules-nixos.after = [ "systemd-tmpfiles-setup.service" ];
    systemd.tmpfiles.rules = [
      "d /run/agenix-canary 0755 root root -"
      "f /run/agenix-canary/dummy 0644 root root - canary"
    ];

    services.crowdsec.enable = true;
    services.fail2ban.enable = true;
    services.fail2ban.ignoreIP = [ "100.64.0.0/10" ];
    systemd.services.crowdsec.wantedBy = lib.mkForce [ ];
    systemd.timers.soc-alarm-bans.wantedBy = lib.mkForce [ ];

    services.soc-vigil-alarms = {
      enable = true;
      auditDisk.warnGiB = 1;
      auditDisk.failGiB = 1;
    };
    systemd.services.soc-audit-watchdog.serviceConfig.BindReadOnlyPaths = [ "${procStat}:/proc/stat" ];
    systemd.timers.soc-audit-watchdog.timerConfig = {
      OnBootSec = lib.mkForce "1s";
      OnUnitActiveSec = lib.mkForce "2s";
      AccuracySec = lib.mkForce "1s";
    };
  };

  testScript = ''
    start_all()
    machine.wait_for_unit("auditd.service")
    machine.wait_for_unit("audit-rules-nixos.service")
    machine.wait_for_unit("soc-alarm-audit.timer")
    machine.wait_for_unit("soc-audit-watchdog.timer")

    with subtest("reading a dummy agenix file produces an actual audit ALARM"):
        machine.succeed("systemctl start soc-alarm-audit.service")
        machine.succeed("bash -c 'echo 1000 >/proc/self/loginuid; exec cat /run/agenix-canary/dummy'")
        # Give ausearch's event assembler time to close the event.
        machine.succeed("sleep 3")
        machine.fail("systemctl start soc-alarm-audit.service")
        machine.succeed("test \"$(systemctl show soc-alarm-audit.service -p ExecMainStatus --value)\" = 1")
        machine.succeed("journalctl -u soc-alarm-audit.service -o cat | grep '^ALARM audit ' | grep -F /run/agenix-canary/dummy")
        machine.succeed("test \"$(stat -c %Y /var/lib/soc-vigil-alarms/audit-hits-clean)\" = 1")

    with subtest("an independently running watchdog pages when the evaluator timer is stopped"):
        machine.succeed("systemctl stop soc-alarm-audit.timer")
        machine.fail("systemctl is-active --quiet soc-alarm-audit.timer")
        machine.succeed("systemctl is-active --quiet soc-audit-watchdog.timer")
        state = "/var/lib/soc-vigil-alarms"
        machine.wait_until_succeeds(f"test $(stat -c %Y {state}/audit-deadman-clean) -gt 1")
        machine.succeed(f"touch -d '31 minutes ago' {state}/audit-clean")
        machine.wait_until_succeeds(f"test $(stat -c %Y {state}/audit-deadman-clean) = 1")
        machine.succeed("mkdir -p /tmp/soc-contracts /tmp/soc-vigil")
        machine.succeed("cp ${deadman} /tmp/soc-contracts/deadman.toml")
        machine.fail("STATE_DIRECTORY=/tmp/soc-vigil VIGIL_SAY=1 VIGIL_BIN=${capturePage} ${vigil}/bin/vigil check /tmp/soc-contracts --expect 1")
        machine.succeed("grep -q '\"nume\":\"soc-audit-deadman\"' /tmp/soc-pages")
        machine.succeed("grep -q '\"tranzitie\":\"open\"' /tmp/soc-pages")
  '';
}
