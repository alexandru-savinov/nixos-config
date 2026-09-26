{ pkgs }:

pkgs.testers.runNixOSTest {
  name = "agterm-sancta-scope";
  nodes.machine = { ... }: {
    imports = [ ../modules/services/sancta-session-scope.nix ];
    virtualisation.memorySize = 768;
    users.users.fixture = {
      isNormalUser = true;
      uid = 1000;
      linger = true;
    };
    system.stateVersion = "25.11";
  };
  testScript = ''
    start_all()
    machine.wait_for_unit("user@1000.service")
    user = "runuser -u fixture -- env XDG_RUNTIME_DIR=/run/user/1000 "
    machine.succeed(user + "systemd-run --user --scope --unit=agt-mvp-sancta-fixture sleep 300 >/tmp/scope.log 2>&1 &")
    machine.wait_until_succeeds(user + "systemctl --user is-active agt-mvp-sancta-fixture.scope")
    expected = {
        "MemoryHigh": "4294967296",
        "MemoryMax": "5368709120",
        "MemorySwapMax": "2147483648",
        "OOMPolicy": "continue",
        "TimeoutStopUSec": "45s",
    }
    for key, value in expected.items():
        actual = machine.succeed(user + "systemctl --user show agt-mvp-sancta-fixture.scope -p " + key + " --value").strip()
        assert actual == value, (key, actual, value)
    dropins = machine.succeed(user + "systemctl --user show agt-mvp-sancta-fixture.scope -p DropInPaths --value")
    assert "agt-mvp-sancta-.scope.d/50-resource-policy.conf" in dropins, dropins
    machine.succeed(user + "systemctl --user stop agt-mvp-sancta-fixture.scope")
  '';
}
