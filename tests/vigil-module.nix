{ lib, evalConfig, shouldFail }:
let
  schema = import ../modules/services/vigil-schema.nix { inherit lib; };
  fixtures = builtins.fromJSON (builtins.readFile ../pkgs/vigil/schema-fixtures.json);
  base = {
    services.vigil = {
      enable = true;
      contractsDirs = [ ../hosts/rpi5-full/vigil-contracts "/run/vigil-contracts" ];
      expectedContracts = 7;
      expectedRuntimeContracts = 3;
      listenAddress = "100.106.93.87";
      telegramEnvFile = "/run/agenix/telegram";
    };
  };
  modules = [ ../modules/services/vigil.nix base ];
  fixtureModules = directory: count: modules ++ [{
    services.vigil = {
      contractsDirs = lib.mkForce [ directory ];
      expectedContracts = lib.mkForce count;
      expectedRuntimeContracts = lib.mkForce 0;
      telegramEnvFile = lib.mkForce null;
    };
  }];
  config = evalConfig { inherit modules; };
  rowOnly = evalConfig { modules = fixtureModules ./fixtures/vigil/row-only 1; };
  service = config.systemd.services.vigil;
  failure = config.systemd.services.vigil-failed;
  tick = config.systemd.services."vigil-tick@";
  socket = config.systemd.sockets.vigil-tick;
  timer = config.systemd.timers.vigil;
  checks = {
    row-only = builtins.seq rowOnly.system.build.toplevel.drvPath
      (rowOnly.systemd.services.vigil.environment.VIGIL_SAY == "0"
        && !(rowOnly.systemd.services.vigil.serviceConfig ? EnvironmentFile));
    schema-parity = lib.all
      (fixture:
        (builtins.tryEval (builtins.deepSeq (schema.parseSource fixture.name fixture.source) true)).success == (fixture.evalAccept or fixture.accept)
      )
      fixtures;
    evaluation = builtins.seq config.system.build.toplevel.drvPath true;
    user = config.users.users.vigil.isSystemUser && config.users.users.vigil.group == "vigil";
    no-journal-grant = config.users.users.vigil.extraGroups == [ ];
    package-installed = lib.any (package: (package.pname or "") == "vigil") config.environment.systemPackages;
    public-runtime-count = lib.hasSuffix "--expect 10" service.serviceConfig.ExecStart;
    mandatory-public-build-gate = lib.hasInfix
      (builtins.unsafeDiscardStringContext "${config.system.build.vigilContracts}/1")
      service.serviceConfig.ExecStart;
    runtime-path-not-imported = builtins.isString (builtins.elemAt config.services.vigil.contractsDirs 1);
    user-and-state = service.serviceConfig.User == "vigil" && service.serviceConfig.StateDirectory == "vigil";
    result-codes = service.serviceConfig.SuccessExitStatus == "1 2";
    stop-post = lib.hasSuffix "/bin/vigil tick write" service.serviceConfig.ExecStopPost;
    deadlines = service.serviceConfig.TimeoutStartSec == "4min30s" && failure.serviceConfig.TimeoutStartSec == "30s";
    failure-unprivileged = failure.serviceConfig.User == "vigil" && failure.serviceConfig.StateDirectory == "vigil";
    failure-environment = lib.all (key: failure.environment.${key} == service.environment.${key})
      [ "VIGIL_BIN" "VIGIL_SYSTEMCTL" "VIGIL_CMD_ALLOW" "VIGIL_SAY" "HASS_URL" "VIGIL_HASS_TOKEN_FILE" ]
    && failure.serviceConfig.EnvironmentFile == service.serviceConfig.EnvironmentFile;
    failure-complete-event = lib.hasSuffix "/bin/vigil failed" failure.serviceConfig.ExecStart;
    timer-enabled = timer.wantedBy == [ "timers.target" ] && timer.timerConfig.OnBootSec == "2min";
    socket-enabled = socket.wantedBy == [ "sockets.target" ];
    socket-bind = socket.socketConfig.ListenStream == "100.106.93.87:8747" && socket.socketConfig.FreeBind && socket.socketConfig.Accept;
    socket-acl = socket.socketConfig.IPAddressAllow == [ "100.64.0.0/10" "fd7a:115c:a1e0::/48" ] && socket.socketConfig.IPAddressDeny == "any";
    socket-ordering = builtins.elem "tailscaled.service" socket.after && builtins.elem "tailscaled.service" socket.wants;
    tick-read-only = tick.environment.STATE_DIRECTORY == "/var/lib/vigil" && !(tick.serviceConfig ? StateDirectory) && tick.serviceConfig.ProtectSystem == "strict";
    tick-protocol = tick.serviceConfig.StandardInput == "socket" && tick.serviceConfig.StandardOutput == "socket" && tick.serviceConfig.StandardError == "journal";
    state-parent = builtins.elem "d /var/lib/vigil 0755 vigil vigil -" config.systemd.tmpfiles.rules;
    ack-permissions = builtins.elem "d /var/lib/vigil/ack 0775 vigil users -" config.systemd.tmpfiles.rules;
    no-fabricated-success = lib.all (line: !(lib.hasInfix "last-channel-ok" line)) config.systemd.tmpfiles.rules;
    wrong-public-count = shouldFail "vigil-count" { modules = modules ++ [{ services.vigil.expectedContracts = lib.mkForce 6; }]; };
    wildcard-listener = shouldFail "vigil-listen" { modules = modules ++ [{ services.vigil.listenAddress = lib.mkForce "0.0.0.0"; }]; };
    missing-telegram = shouldFail "vigil-telegram" { modules = modules ++ [{ services.vigil.telegramEnvFile = lib.mkForce null; }]; };
    channel-needs-telegram = shouldFail "vigil-channel" { modules = fixtureModules ./fixtures/vigil/channel 1; };
    hass-needs-token = shouldFail "vigil-hass" { modules = fixtureModules ./fixtures/vigil/hass 1; };
    duplicate-name = shouldFail "vigil-duplicate" { modules = fixtureModules ./fixtures/vigil/duplicate 2; };
  };
  failures = builtins.attrNames (lib.filterAttrs (_: value: !value) checks);
in
if failures == [ ] then true else throw "Vigil module checks failed: ${builtins.toJSON failures}"
