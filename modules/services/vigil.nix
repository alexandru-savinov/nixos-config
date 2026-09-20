{ config, lib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkOption mkIf types;
  cfg = config.services.vigil;
  package = pkgs.callPackage ../../pkgs/vigil.nix { };
  schema = import ./vigil-schema.nix { inherit lib; };
  directoryType = types.mkOptionType {
    name = "vigilContractDirectory";
    description = "Nix path or absolute runtime path string";
    check = value: builtins.isPath value || builtins.isString value && lib.hasPrefix "/" value;
    merge = lib.mergeEqualOption;
  };
  publicDirs = builtins.filter builtins.isPath cfg.contractsDirs;
  publicBundle = import ../../pkgs/vigil-public-contracts.nix {
    inherit pkgs;
    vigil = package;
    directories = publicDirs;
  };
  checkedDirs = (lib.imap1 (index: _: "${publicBundle}/${toString index}") publicDirs)
    ++ builtins.filter builtins.isString cfg.contractsDirs;
  files = lib.concatMap
    (directory: map (name: directory + "/${name}")
      (builtins.filter (name: lib.hasSuffix ".toml" name) (builtins.attrNames (builtins.readDir directory))))
    publicDirs;
  contracts = map schema.parse files;
  names = map (contract: contract.nume) contracts;
  environment = {
    VIGIL_BIN = "${package}/bin/vigil";
    VIGIL_SYSTEMCTL = "${pkgs.systemd}/bin/systemctl";
    VIGIL_CMD_ALLOW = builtins.toJSON cfg.cmdAllow;
    VIGIL_SAY = if cfg.telegramEnvFile == null then "0" else "1";
    HASS_URL = if cfg.hassUrl == null then "" else cfg.hassUrl;
    VIGIL_HASS_TOKEN_FILE = if cfg.hassTokenFile == null then "" else toString cfg.hassTokenFile;
  };
  sandbox = {
    User = "vigil";
    Group = "vigil";
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    NoNewPrivileges = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    RestrictSUIDSGID = true;
    RestrictRealtime = true;
    LockPersonality = true;
    RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
    UMask = "0077";
  };
  writable = sandbox // {
    StateDirectory = "vigil";
    StateDirectoryMode = "0755";
  } // lib.optionalAttrs (cfg.telegramEnvFile != null) {
    EnvironmentFile = cfg.telegramEnvFile;
  };
in
{
  options.services.vigil = {
    enable = mkEnableOption "deterministic checks, incident delivery and peer freshness";
    contractsDirs = mkOption { type = types.listOf directoryType; default = [ ]; description = "Public Nix directories and private runtime directory strings."; };
    expectedContracts = mkOption { type = types.ints.unsigned; description = "Exact number of public, evaluation-visible contracts."; };
    expectedRuntimeContracts = mkOption { type = types.ints.unsigned; default = 0; description = "Exact number of private runtime contracts."; };
    telegramEnvFile = mkOption { type = types.nullOr types.path; default = null; description = "Runtime EnvironmentFile containing TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID; null selects row-only mode."; };
    hassTokenFile = mkOption { type = types.nullOr types.path; default = null; description = "Runtime bearer-token file readable by vigil."; };
    hassUrl = mkOption { type = types.nullOr types.str; default = null; description = "Home Assistant base URL."; };
    tickPort = mkOption { type = types.port; default = 8747; description = "Tailnet freshness socket port."; };
    listenAddress = mkOption { type = types.str; description = "This host's numeric Tailscale IPv4 address."; };
    cmdAllow = mkOption { type = types.listOf (types.strMatching "/.+"); default = [ ]; description = "Absolute executables permitted by cmd contracts."; };
    interval = mkOption { type = types.str; default = "5min"; description = "Systemd interval between check starts."; };
  };
  config = mkIf cfg.enable {
    assertions = [
      { assertion = cfg.expectedContracts == builtins.length files; message = "vigil: expectedContracts must equal the public TOML file count"; }
      { assertion = builtins.length names == builtins.length (lib.unique names); message = "vigil: duplicate public contract name in ${lib.concatMapStringsSep ", " toString files}"; }
      { assertion = schema.tailnet cfg.listenAddress; message = "vigil: listenAddress must be in 100.64.0.0/10"; }
      { assertion = cfg.telegramEnvFile != null || lib.all (c: c.nivel != "incident" && c.nume != "channel") contracts; message = "vigil: incident/channel contracts require telegramEnvFile (${lib.concatMapStringsSep ", " toString files})"; }
      { assertion = cfg.hassTokenFile != null && cfg.hassUrl != null || lib.all (c: c.verifica != "hass-state") contracts; message = "vigil: hass-state requires hassTokenFile and hassUrl (${lib.concatMapStringsSep ", " toString files})"; }
    ];
    users.groups.vigil = { };
    users.users.vigil = { isSystemUser = true; group = "vigil"; };
    environment.systemPackages = [ package ];
    system.build.vigilContracts = publicBundle;
    systemd.tmpfiles.rules = [
      "d /var/lib/vigil 0755 vigil vigil -"
      "d /var/lib/vigil/outbox 0750 vigil vigil -"
      "d /var/lib/vigil/rows 0750 vigil vigil -"
      "d /var/lib/vigil/nota-sent 0750 vigil vigil -"
      "d /var/lib/vigil/ack 0775 vigil users -"
    ];
    systemd.services.vigil = {
      description = "Vigil deterministic checks";
      inherit environment;
      path = [ pkgs.coreutils pkgs.systemd ];
      onFailure = [ "vigil-failed.service" ];
      serviceConfig = writable // {
        Type = "oneshot";
        ExecStart = "${package}/bin/vigil check ${lib.escapeShellArgs checkedDirs} --expect ${toString (cfg.expectedContracts + cfg.expectedRuntimeContracts)}";
        ExecStopPost = "${package}/bin/vigil tick write";
        TimeoutStartSec = "4min30s";
        TimeoutStopSec = "15s";
        SuccessExitStatus = "1 2";
      };
    };
    systemd.services.vigil-failed = {
      description = "Vigil internal failure notification";
      inherit environment;
      serviceConfig = writable // {
        Type = "oneshot";
        ExecStart = "${package}/bin/vigil failed";
        TimeoutStartSec = "30s";
      };
    };
    systemd.timers.vigil = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "2min"; OnUnitActiveSec = cfg.interval; };
    };
    systemd.sockets.vigil-tick = {
      description = "Vigil freshness socket on the tailnet";
      wantedBy = [ "sockets.target" ];
      after = [ "tailscaled.service" ];
      wants = [ "tailscaled.service" ];
      socketConfig = {
        ListenStream = "${cfg.listenAddress}:${toString cfg.tickPort}";
        FreeBind = true;
        Accept = true;
        IPAddressAllow = [ "100.64.0.0/10" "fd7a:115c:a1e0::/48" ];
        IPAddressDeny = "any";
      };
    };
    systemd.services."vigil-tick@" = {
      description = "Vigil freshness response";
      environment.STATE_DIRECTORY = "/var/lib/vigil";
      serviceConfig = sandbox // {
        ExecStart = "${package}/bin/vigil tick serve";
        StandardInput = "socket";
        StandardOutput = "socket";
        StandardError = "journal";
        RuntimeMaxSec = "5s";
      };
    };
  };
}
