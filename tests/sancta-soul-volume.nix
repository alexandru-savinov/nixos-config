{ pkgs }:

let
  testLogin = "owner@example.com";
  testLoginHash = builtins.hashString "sha256" testLogin;
  testPassword = "test-membrane-password-0123456789abcdef";
  soulFaultAck = "sancta-soul-crash-window-v1";
  soulFaultEnvironment = {
    SANCTA_SOUL_TEST_FAULT_ACK = soulFaultAck;
    SANCTA_SOUL_TEST_FAULT_FILE = "/run/sancta-test/soul-fault";
  };
in
pkgs.testers.nixosTest {
  name = "sancta-soul-volume";

  nodes.machine = { lib, pkgs, ... }: {
    imports = [
      ../hosts/sancta-choir/soul-volume.nix
      ../hosts/sancta-choir/sancta-worker.nix
    ];

    _module.args.claude-code = {
      packages.${pkgs.system}.default = pkgs.writeShellScriptBin "claude" ''
        echo "test-only claude must not run" >&2
        exit 99
      '';
    };

    users.users.sancta = {
      isSystemUser = true;
      group = "sancta";
      home = "/var/lib/sancta";
      createHome = true;
    };
    users.groups.sancta = { };

    services.sancta-soul-volume = {
      enable = true;
      imagePath = "/var/lib/sancta-soul/soul.img";
      keyFile = "/run/sancta-test/soul.key";
      mapperName = "sancta-soul";
      mountPoint = "/var/lib/sancta/.claude";
      owner = "sancta";
    };

    services.sancta-worker = {
      enable = true;
      session = "vm-session";
      apiKeyFile = "/run/sancta-test/anthropic-key";
      authSecretFile = "/run/sancta-test/membrane-auth";
      operatorLoginSha256 = testLoginHash;
      port = 18743;
    };

    # Prepare only disposable test material before the production open unit.
    systemd.services.sancta-test-prepare = {
      description = "Create disposable LUKS soul fixture";
      before = [ "sancta-soul-open.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [
        pkgs.coreutils
        pkgs.cryptsetup
        pkgs.e2fsprogs
      ];
      script = ''
        set -euo pipefail
        install -d -m 0750 -o root -g sancta /run/sancta-test
        install -d -m 0700 -o root -g root /var/lib/sancta-soul
        install -d -m 0700 -o sancta -g sancta /var/lib/sancta/session
        printf '%s\n' 'disposable-soul-key' > /run/sancta-test/soul.key
        printf '%s\n' 'sk-ant-api-disposable-test-key' > /run/sancta-test/anthropic-key
        printf '%s\n' '${testPassword}' > /run/sancta-test/membrane-auth
        chown sancta:sancta /run/sancta-test/anthropic-key
        chmod 0400 /run/sancta-test/anthropic-key
        chmod 0600 /run/sancta-test/soul.key /run/sancta-test/membrane-auth
        touch /var/lib/sancta/session/vm-session

        if [ ! -f /var/lib/sancta-soul/soul.img ]; then
          truncate -s 128M /var/lib/sancta-soul/soul.img
          # Test-only bounded KDF avoids Argon2 memory/time variance in CI.
          cryptsetup luksFormat --batch-mode --type luks2 \
            --pbkdf pbkdf2 --iter-time 10 \
            --key-file /run/sancta-test/soul.key \
            /var/lib/sancta-soul/soul.img
          cryptsetup luksOpen \
            --key-file /run/sancta-test/soul.key \
            /var/lib/sancta-soul/soul.img sancta-soul-init
          mkfs.ext4 -q /dev/mapper/sancta-soul-init
          cryptsetup luksClose sancta-soul-init
        fi
      '';
    };

    systemd.services.sancta-soul-open = {
      after = [ "sancta-test-prepare.service" ];
      requires = [ "sancta-test-prepare.service" ];
      environment = soulFaultEnvironment;
    };

    systemd.services.sancta-soul-mount.environment = soulFaultEnvironment;

    # A lightweight stand-in for the real HM activation body, with the exact
    # production dependency/condition contract. Pure module-eval separately
    # locks the real host unit to the same wiring.
    systemd.services.home-manager-sancta = {
      description = "Sancta Home Manager ordering probe";
      wantedBy = [ "multi-user.target" ];
      after = [
        "sancta-soul-mount.service"
        "sancta-soul-verify.service"
      ];
      requires = [
        "sancta-soul-mount.service"
        "sancta-soul-verify.service"
      ];
      unitConfig.ConditionPathIsMountPoint = "/var/lib/sancta/.claude";
      serviceConfig = {
        Type = "oneshot";
        User = "sancta";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail
        if [ -e /run/sancta-test/fail-home-manager ]; then
          exit 23
        fi
        mkdir -p /var/lib/sancta/.claude/index
        touch /var/lib/sancta/.claude/.hm-succeeded
        touch /var/lib/sancta/session/.hm-ran
      '';
    };

    # Keep all production unit dependencies/conditions/hardening, replacing
    # only the paid Claude process with a readiness marker plus an idle process.
    systemd.services.sancta-worker.serviceConfig.ExecStart = lib.mkForce (
      pkgs.writeShellScript "sancta-worker-vm-probe" ''
        set -euo pipefail
        test -f "$CLAUDE_CONFIG_DIR/.hm-succeeded"
        touch "$SANCTA_WORKER_READY"
        exec ${pkgs.coreutils}/bin/sleep infinity
      ''
    );

    # Tailscale itself is outside this LUKS/systemd test. Preserve the real
    # gateway and replace only its Serve edge with a dependent oneshot marker.
    systemd.services.sancta-membrane-serve = {
      after = lib.mkForce [ "sancta-membrane.service" ];
      wants = lib.mkForce [ ];
      requires = lib.mkForce [ "sancta-membrane.service" ];
      script = lib.mkForce ''
        touch /run/sancta-test/serve-started
      '';
      preStop = lib.mkForce "";
    };

    environment.systemPackages = [
      pkgs.cryptsetup
      pkgs.curl
      pkgs.jq
      pkgs.util-linux
    ];

    virtualisation.memorySize = 1024;
  };

  testScript = ''
    import json

    MOUNT = "/var/lib/sancta/.claude"

    def stop_consumers():
        machine.succeed("systemctl stop sancta-membrane-serve.service")
        machine.succeed("systemctl stop sancta-membrane.service")
        machine.succeed("systemctl stop sancta-worker.service")
        machine.succeed("systemctl stop home-manager-sancta.service")
        machine.succeed("rm -f /run/sancta-test/serve-started")

    def stop_soul():
        machine.succeed("systemctl stop sancta-soul-verify.service")
        machine.succeed("systemctl stop sancta-soul-mount.service")
        machine.succeed("systemctl stop sancta-soul-open.service")

    def reset_units():
        machine.succeed("systemctl reset-failed")

    def assert_consumers_down():
        for unit in (
            "home-manager-sancta.service",
            "sancta-worker.service",
            "sancta-membrane.service",
            "sancta-membrane-serve.service",
        ):
            machine.fail(f"systemctl is-active --quiet {unit}")
        machine.succeed("test ! -e /var/lib/sancta/session/.hm-ran")
        machine.succeed("test ! -e /run/sancta-worker/ready")
        machine.succeed("test ! -e /run/sancta-test/serve-started")
        machine.fail("curl --connect-timeout 1 --silent http://127.0.0.1:18743/")

    def assert_mapper_backing(image):
        machine.succeed(
            """set -euo pipefail
            mapper_device="$(cryptsetup status sancta-soul | awk '$1 == "device:" { print $2 }')"
            test -n "$mapper_device"
            backing="$(losetup --noheadings --raw --output BACK-FILE -- "$mapper_device")"
            test "$(readlink -f -- "$backing")" = "$(readlink -f -- "%s")"
            """ % image
        )

    def assert_exact_mount():
        machine.succeed("test $(readlink -f $(findmnt -rn -o SOURCE --mountpoint /var/lib/sancta/.claude)) = $(readlink -f /dev/mapper/sancta-soul)")

    def assert_mount_metadata():
        machine.succeed("test \"$(stat -c '%U:%G %a' /var/lib/sancta/.claude)\" = 'sancta:sancta 700'")

    start_all()

    machine.wait_for_unit("home-manager-sancta.service")
    machine.wait_for_unit("sancta-worker.service")
    machine.wait_for_unit("sancta-membrane.service")
    machine.wait_for_unit("sancta-membrane-serve.service")
    machine.wait_for_open_port(18743)
    machine.succeed("test -f /var/lib/sancta/.claude/.hm-succeeded")
    machine.succeed("test -f /run/sancta-worker/ready")
    machine.succeed("test -f /run/sancta-test/serve-started")
    assert_exact_mount()
    assert_mount_metadata()
    assert_mapper_backing("/var/lib/sancta-soul/soul.img")
    machine.succeed("cryptsetup status sancta-soul | grep -Eq '^[[:space:]]*device:[[:space:]]+/dev/loop'")

    # A symlink target must fail before root mounts anything through it.
    stop_consumers()
    stop_soul()
    machine.succeed("rm -f /var/lib/sancta/session/.hm-ran")
    machine.succeed("rmdir /var/lib/sancta/.claude")
    machine.succeed("mkdir /run/sancta-test/redirect && ln -s /run/sancta-test/redirect /var/lib/sancta/.claude")
    machine.fail("systemctl start sancta-membrane-serve.service")
    assert_consumers_down()
    machine.succeed("test ! -e /var/lib/sancta/session/.hm-ran")
    machine.succeed("test ! -e /run/sancta-test/redirect/.hm-succeeded")
    machine.fail("mountpoint -q /run/sancta-test/redirect")
    machine.succeed("rm /var/lib/sancta/.claude && mkdir /var/lib/sancta/.claude && chown sancta:sancta /var/lib/sancta/.claude")
    machine.succeed("systemctl stop sancta-soul-open.service")
    reset_units()

    # An existing wrong filesystem is rejected and left untouched.
    machine.succeed("mount -t tmpfs tmpfs /var/lib/sancta/.claude")
    machine.fail("systemctl start sancta-membrane-serve.service")
    assert_consumers_down()
    machine.succeed("test ! -e /var/lib/sancta/session/.hm-ran")
    machine.succeed("test $(findmnt -rn -o FSTYPE --mountpoint /var/lib/sancta/.claude) = tmpfs")
    machine.succeed("test ! -e /var/lib/sancta/.claude/.hm-succeeded")
    machine.succeed("umount /var/lib/sancta/.claude")
    machine.succeed("systemctl stop sancta-soul-open.service")
    reset_units()

    # An existing mapper backed by another image fails without being closed.
    machine.succeed("truncate -s 128M /var/lib/sancta-soul/wrong.img")
    machine.succeed("cryptsetup luksFormat --batch-mode --type luks2 --pbkdf pbkdf2 --iter-time 10 --key-file /run/sancta-test/soul.key /var/lib/sancta-soul/wrong.img")
    machine.succeed("cryptsetup luksOpen --key-file /run/sancta-test/soul.key /var/lib/sancta-soul/wrong.img sancta-soul")
    machine.fail("systemctl start sancta-membrane-serve.service")
    assert_consumers_down()
    assert_mapper_backing("/var/lib/sancta-soul/wrong.img")
    machine.succeed("cryptsetup luksClose sancta-soul")
    reset_units()

    # A missing configured image fails and is never recreated.
    machine.succeed("mv /var/lib/sancta-soul/soul.img /var/lib/sancta-soul/soul.img.held")
    machine.fail("systemctl start sancta-membrane-serve.service")
    assert_consumers_down()
    machine.succeed("test ! -e /var/lib/sancta-soul/soul.img")
    machine.succeed("mv /var/lib/sancta-soul/soul.img.held /var/lib/sancta-soul/soul.img")
    reset_units()

    # The configured image path itself must be canonical, never a symlink.
    machine.succeed("mv /var/lib/sancta-soul/soul.img /var/lib/sancta-soul/soul.img.held")
    machine.succeed("ln -s soul.img.held /var/lib/sancta-soul/soul.img")
    machine.fail("systemctl start sancta-membrane-serve.service")
    assert_consumers_down()
    machine.succeed("test -L /var/lib/sancta-soul/soul.img")
    machine.succeed("rm /var/lib/sancta-soul/soul.img && mv /var/lib/sancta-soul/soul.img.held /var/lib/sancta-soul/soul.img")
    reset_units()

    # Crash immediately after cryptsetup creates the mapper. The failed start
    # leaves the exact mapper visible for diagnosis but no dependent available.
    machine.succeed("printf '%s\n' after-mapper-open > /run/sancta-test/soul-fault")
    machine.fail("systemctl start sancta-membrane-serve.service")
    assert_consumers_down()
    machine.fail("mountpoint -q /var/lib/sancta/.claude")
    machine.succeed("test -z \"$(ls -A /var/lib/sancta/.claude)\"")
    assert_mapper_backing("/var/lib/sancta-soul/soul.img")
    machine.succeed("journalctl -b -u sancta-soul-open.service --no-pager | grep -F 'TEST ONLY: injected soul-volume fault at after-mapper-open'")
    machine.succeed("rm /run/sancta-test/soul-fault")
    reset_units()
    machine.succeed("systemctl start sancta-membrane-serve.service")
    machine.wait_for_unit("home-manager-sancta.service")
    machine.wait_for_unit("sancta-worker.service")
    machine.wait_for_unit("sancta-membrane.service")
    machine.wait_for_unit("sancta-membrane-serve.service")
    assert_exact_mount()
    assert_mount_metadata()
    machine.succeed("test -e /var/lib/sancta/session/.hm-ran")
    stop_consumers()
    stop_soul()

    # Crash immediately after mount creates the filesystem attachment. The
    # exact mount remains for diagnosis; retry succeeds only through verifier.
    machine.succeed("rm -f /var/lib/sancta/session/.hm-ran")
    machine.succeed("printf '%s\n' after-mount > /run/sancta-test/soul-fault")
    machine.fail("systemctl start sancta-membrane-serve.service")
    assert_consumers_down()
    assert_exact_mount()
    assert_mapper_backing("/var/lib/sancta-soul/soul.img")
    machine.succeed("test ! -e /var/lib/sancta/session/.hm-ran")
    machine.succeed("journalctl -b -u sancta-soul-mount.service --no-pager | grep -F 'TEST ONLY: injected soul-volume fault at after-mount'")
    machine.succeed("rm /run/sancta-test/soul-fault")
    reset_units()
    machine.succeed("systemctl start sancta-membrane-serve.service")
    machine.wait_for_unit("home-manager-sancta.service")
    machine.wait_for_unit("sancta-worker.service")
    machine.wait_for_unit("sancta-membrane.service")
    machine.wait_for_unit("sancta-membrane-serve.service")
    assert_exact_mount()
    assert_mount_metadata()
    machine.succeed("test -e /var/lib/sancta/session/.hm-ran")
    stop_consumers()
    stop_soul()

    # With the long-lived mount unit still active, replace only the underlying
    # attachment. A new Serve transaction must rerun the non-remaining verifier
    # and reject the tmpfs without touching its sentinel or rerunning HM.
    machine.succeed("systemctl start home-manager-sancta.service")
    machine.succeed("systemctl stop home-manager-sancta.service")
    machine.succeed("rm -f /var/lib/sancta/session/.hm-ran")
    machine.succeed("umount /var/lib/sancta/.claude")
    machine.succeed("mount -t tmpfs tmpfs /var/lib/sancta/.claude")
    machine.succeed("printf '%s\n' verifier-sentinel > /var/lib/sancta/.claude/sentinel")
    machine.fail("systemctl start sancta-membrane-serve.service")
    assert_consumers_down()
    machine.succeed("test \"$(systemctl show sancta-soul-verify.service -p Result --value)\" = exit-code")
    machine.succeed("test \"$(cat /var/lib/sancta/.claude/sentinel)\" = verifier-sentinel")
    machine.succeed("test \"$(findmnt -rn -o FSTYPE --mountpoint /var/lib/sancta/.claude)\" = tmpfs")
    machine.succeed("test ! -e /var/lib/sancta/session/.hm-ran")
    machine.succeed("umount /var/lib/sancta/.claude")
    reset_units()
    machine.succeed("systemctl restart sancta-soul-mount.service")
    assert_exact_mount()
    assert_mount_metadata()

    # Replacement after activation: both stop and restart must refuse it and
    # surface failure rather than unmounting the unexpected filesystem.
    machine.succeed("systemctl start home-manager-sancta.service")
    machine.succeed("systemctl stop home-manager-sancta.service")
    machine.succeed("umount /var/lib/sancta/.claude")
    machine.succeed("mount -t tmpfs tmpfs /var/lib/sancta/.claude")
    machine.fail("systemctl stop sancta-soul-mount.service")
    machine.succeed("test $(findmnt -rn -o FSTYPE --mountpoint /var/lib/sancta/.claude) = tmpfs")
    machine.succeed("umount /var/lib/sancta/.claude")
    reset_units()
    machine.succeed("systemctl start sancta-soul-mount.service")
    machine.succeed("umount /var/lib/sancta/.claude")
    machine.succeed("mount -t tmpfs tmpfs /var/lib/sancta/.claude")
    machine.fail("systemctl restart sancta-soul-mount.service")
    machine.succeed("test $(findmnt -rn -o FSTYPE --mountpoint /var/lib/sancta/.claude) = tmpfs")
    machine.succeed("umount /var/lib/sancta/.claude")
    reset_units()
    machine.succeed("systemctl start sancta-soul-mount.service")
    machine.succeed("systemctl stop sancta-soul-mount.service")

    # Mapper replacement after activation is likewise never closed by either
    # stop or restart; assert the exact wrong backing survives both attempts.
    machine.succeed("cryptsetup luksClose sancta-soul")
    machine.succeed("cryptsetup luksOpen --key-file /run/sancta-test/soul.key /var/lib/sancta-soul/wrong.img sancta-soul")
    machine.fail("systemctl stop sancta-soul-open.service")
    assert_mapper_backing("/var/lib/sancta-soul/wrong.img")
    machine.succeed("cryptsetup luksClose sancta-soul")
    reset_units()
    machine.succeed("systemctl start sancta-soul-open.service")
    machine.succeed("cryptsetup luksClose sancta-soul")
    machine.succeed("cryptsetup luksOpen --key-file /run/sancta-test/soul.key /var/lib/sancta-soul/wrong.img sancta-soul")
    machine.fail("systemctl restart sancta-soul-open.service")
    assert_mapper_backing("/var/lib/sancta-soul/wrong.img")
    machine.succeed("cryptsetup luksClose sancta-soul")
    reset_units()

    # Failed Home Manager blocks the worker. The intentional status-only
    # gateway may run, but /send must return 503 without inbox/quota mutation.
    machine.succeed("touch /run/sancta-test/fail-home-manager")
    machine.fail("systemctl start sancta-worker.service")
    machine.succeed("test \"$(systemctl show home-manager-sancta.service -p Result --value)\" = exit-code")
    machine.succeed("test \"$(systemctl show home-manager-sancta.service -p ExecMainStatus --value)\" = 23")
    machine.fail("systemctl is-active --quiet sancta-worker.service")
    assert_exact_mount()
    machine.succeed("systemctl start sancta-membrane.service")
    machine.wait_for_open_port(18743)
    before = machine.succeed("sha256sum /var/lib/sancta/.claude/index/comm-inbox.jsonl /var/lib/sancta/.claude/index/comm-rate-limit.json 2>/dev/null || true")
    status = machine.succeed("curl -sS -o /run/sancta-test/send-response -w '%{http_code}' -u alexandru:${testPassword} -H 'Tailscale-User-Login: ${testLogin}' -H 'X-Sancta-Request: send' -H 'Content-Type: application/json' --data '{\"message\":\"hello\"}' http://127.0.0.1:18743/send").strip()
    assert status == "503", status
    response = json.loads(machine.succeed("cat /run/sancta-test/send-response"))
    assert response.get("error") == "worker unavailable", response
    assert response.get("worker", {}).get("status") in {"stopped", "failed"}, response
    after = machine.succeed("sha256sum /var/lib/sancta/.claude/index/comm-inbox.jsonl /var/lib/sancta/.claude/index/comm-rate-limit.json 2>/dev/null || true")
    assert before == after
    machine.succeed("test ! -e /run/sancta-worker/ready")
  '';
}
