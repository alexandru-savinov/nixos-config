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
    import shlex

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

    # The approved rollout creates the new backend before switching aliases.
    # Prove a manager reload applies the installed policy to a surviving scope.
    override = "/home/fixture/.config/systemd/user/agt-mvp-sancta-.scope.d"
    machine.succeed("mkdir -p " + override)
    initial = "\n".join([
        "[Scope]", "MemoryHigh=infinity", "MemoryMax=infinity",
        "MemorySwapMax=infinity", "OOMPolicy=stop", "TimeoutStopSec=90", "",
    ])
    machine.succeed("printf %s " + shlex.quote(initial) + " > " + override + "/50-resource-policy.conf")
    machine.succeed(user + "systemctl --user daemon-reload")
    scope = "agt-mvp-sancta-reload-fixture.scope"
    machine.succeed(user + "systemd-run --user --scope --unit=" + scope + " sleep 300 >/tmp/reload-scope.log 2>&1 &")
    machine.wait_until_succeeds(user + "systemctl --user is-active " + scope)
    before = machine.succeed("pgrep -u fixture -x sleep").strip()
    assert machine.succeed(user + "systemctl --user show " + scope + " -p MemoryMax --value").strip() == "infinity"
    machine.succeed("rm " + override + "/50-resource-policy.conf")
    machine.succeed(user + "systemctl --user daemon-reload")
    for key, value in expected.items():
        actual = machine.succeed(user + "systemctl --user show " + scope + " -p " + key + " --value").strip()
        assert actual == value, ("after reload", key, actual, value)
    cgroup = machine.succeed(user + "systemctl --user show " + scope + " -p ControlGroup --value").strip()
    for filename, value in {"memory.high": "4294967296", "memory.max": "5368709120", "memory.swap.max": "2147483648"}.items():
        assert machine.succeed("cat /sys/fs/cgroup" + cgroup + "/" + filename).strip() == value
    assert machine.succeed("pgrep -u fixture -x sleep").strip() == before
    machine.succeed(user + "systemctl --user stop " + scope)
  '';
}
