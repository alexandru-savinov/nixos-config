# soc-vigil-alarms — the two SOC alarms that need root, reported to vigil
# without granting vigil anything.
#
# The SOC plan: "Vigil fires only on: a CrowdSec ban on a tailnet/LAN address,
# an auditd hit on /run/agenix or sudoers, disk over threshold." Disk is a plain
# vigil `disk` contract (vigil-contracts/disk-root.toml). These two cannot be:
# the audit log is root-only, cscli/fail2ban-client need the engines'
# credentials, and vigil on sancta-choir executes no commands (cmdAllow = []).
#
# So this is the doctrine-guard pattern, twice: a root oneshot on a 5-minute
# timer evaluates one rule (soc-vigil-alarms.py, where THE RULES are written
# out exactly and unit-tested from fixtures in tests/test_soc_vigil_alarms.py)
# and the shared stamp script (sancta-doctrine-guard-stamp.sh, reused, not
# copied) turns the exit status into one file mtime: now when clean, epoch+1s
# otherwise. vigil reads that with its file `age` check — a stat, nothing more.
#
#   soc-alarm-audit  -> auditStampPath -> vigil-contracts/soc-audit.toml
#   soc-alarm-bans   -> bansStampPath  -> vigil-contracts/soc-bans.toml
#
# NOISE IS THE DESIGN CONSTRAINT. Two choices carry it, both in the script:
#
#   * Audit fires only for a LOGIN auid, and never for this generation's
#     setup-etc.pl rewriting /etc/sudoers. Services reading their agenix
#     secrets at start (auid unset) and nixos-rebuild's activation (run via
#     systemd-run, auid unset) stay silent by construction.
#
#   * Audit is "since the last run" (ausearch --checkpoint): one event raises
#     the stamp red for `auditHold`, then it clears BY ITSELF. Not "red until
#     acknowledged": an ack path would be a new write surface into a root
#     unit's state, and vigil already keeps the incident it opened (it closes
#     only after 30 min of green), so the human has the event either way. The
#     hold exists because vigil ticks every 5 min and opens after
#     picat_dupa = 2 red ticks; a red stamp lasting a single 5-minute window
#     could fall between ticks and alarm nobody.
#
#   * Bans are STATE, not events: the stamp is red for as long as a home
#     address is banned/decided and clears when the ban expires or is lifted.
#
# Fail-closed: an engine that cannot be read (ausearch/cscli/fail2ban error)
# exits 2 and the stamp goes red too. picat_dupa = 2 absorbs one bad run
# (e.g. crowdsec restarting under a deploy); a detector that stays blind for
# two vigil ticks is reported, never trusted.
#
# Zero other notifications: no OnFailure= here. The only paths out are the
# vigil contracts and the status bar's unit list (configuration.nix).
{ config, lib, pkgs, modulesPath, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption types;
  cfg = config.services.soc-vigil-alarms;
  stateDir = "soc-vigil-alarms";
  script = ./soc-vigil-alarms.py;
  stampScript = ./sancta-doctrine-guard-stamp.sh;
  python = "${pkgs.python3}/bin/python3";

  # The activation's /etc writer for THIS generation. Copying the same nixpkgs
  # file under the same name yields the same content-addressed store path that
  # nixos/modules/system/etc/etc.nix (`${./setup-etc.pl}`) puts in the
  # activation script; (modulesPath alone is the nixpkgs source path, which
  # is NOT what argv shows);
  # tests/module-eval.nix pins that equality, so a nixpkgs that moves or
  # renames the file fails CI instead of turning every hand-run activation
  # into an incident.
  setupEtc = "${builtins.path {
    path = "${modulesPath}/system/etc/setup-etc.pl";
    name = "setup-etc.pl";
  }}";

  # The nixpkgs crowdsec module's wrapper (it adds -c=<its generated config>).
  cscli = lib.findFirst (p: (p.name or "") == "cscli") null config.environment.systemPackages;

  # The same list soc-in-a-box hands fail2ban as ignoreIP and CrowdSec as its
  # whitelist (module-eval asserts the CrowdSec half). One source.
  neverBan = config.services.fail2ban.ignoreIP;

  common = {
    Type = "oneshot";
    ExecStopPost = "${pkgs.bash}/bin/bash ${stampScript}";
    StateDirectory = stateDir;
    # 0755 so the unprivileged vigil user can stat the stamps; UMask keeps
    # every FILE (checkpoint, last-hit, stamps) 0600 — stat needs no read bit.
    StateDirectoryMode = "0755";
    UMask = "0077";
    TimeoutStartSec = "2m";
    Nice = 10;
    NoNewPrivileges = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    ProtectClock = true;
    ProtectHostname = true;
    RestrictNamespaces = true;
    RestrictSUIDSGID = true;
    RestrictRealtime = true;
    LockPersonality = true;
    MemoryDenyWriteExecute = true;
    SystemCallArchitectures = "native";
    SystemCallFilter = [ "@system-service" ];
  };

  timer = description: {
    inherit description;
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "3min";
      OnUnitActiveSec = "5min";
      AccuracySec = "30s";
    };
  };
in
{
  options.services.soc-vigil-alarms = {
    enable = mkEnableOption "SOC alarms for vigil: login access to secrets/sudoers, bans on home addresses";

    auditHold = mkOption {
      type = types.ints.between 600 3600;
      default = 900;
      description = ''
        Seconds the audit stamp stays red after the last hit. At least two
        vigil ticks (2 x 5 min) plus slack, so picat_dupa = 2 always sees it.
      '';
    };

    auditStampPath = mkOption {
      type = types.str;
      readOnly = true;
      default = "/var/lib/${stateDir}/audit-clean";
      description = "Audit alarm outcome as one mtime; read by vigil-contracts/soc-audit.toml (module-eval pins the equality).";
    };

    bansStampPath = mkOption {
      type = types.str;
      readOnly = true;
      default = "/var/lib/${stateDir}/bans-clean";
      description = "Ban alarm outcome as one mtime; read by vigil-contracts/soc-bans.toml (module-eval pins the equality).";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = config.security.auditd.enable && config.security.audit.enable
          && config.services.crowdsec.enable && config.services.fail2ban.enable;
        message = "services.soc-vigil-alarms evaluates soc-in-a-box's engines (auditd, CrowdSec, fail2ban); import modules/services/soc-in-a-box.nix.";
      }
      {
        assertion = cscli != null;
        message = "services.soc-vigil-alarms: no `cscli` wrapper in environment.systemPackages (the nixpkgs crowdsec module provides it).";
      }
      {
        assertion = neverBan != [ ];
        message = "services.soc-vigil-alarms: services.fail2ban.ignoreIP is empty, so no address counts as home.";
      }
    ];

    systemd.services.soc-alarm-audit = {
      description = "SOC alarm: login access to agenix secrets or /etc/sudoers (auditd)";
      after = [
        "auditd.service"
        "audit-rules-nixos.service"
      ];
      serviceConfig = common // {
        ExecStart = lib.escapeShellArgs [
          python
          "${script}"
          "audit"
          "--ausearch"
          "${pkgs.audit}/bin/ausearch"
          # The trail must be live for a quiet window to mean anything: auditd
          # running AND the rules loaded (audit-rules-nixos is RemainAfterExit;
          # when it fails its ExecStopPost deletes every rule). Checked by the
          # script, not by requires=, which would START a stopped auditd.
          "--systemctl"
          "${config.systemd.package}/bin/systemctl"
          "--require-active"
          "auditd.service"
          "--require-active"
          "audit-rules-nixos.service"
          "--hold"
          (toString cfg.auditHold)
          "--setup-etc"
          setupEtc
        ];
        # The checkpoint and last-hit files live in $STATE_DIRECTORY (set by
        # StateDirectory=), so no off-store path appears in ExecStart.
        Environment = [ "SANCTA_DOCTRINE_STAMP=${cfg.auditStampPath}" ];
        # Reads /var/log/audit (root-owned, so owner bits suffice: no caps).
        CapabilityBoundingSet = [ "" ];
        PrivateNetwork = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
      };
    };

    systemd.services.soc-alarm-bans = {
      description = "SOC alarm: CrowdSec decision or fail2ban ban on a home address";
      after = [ "crowdsec.service" "fail2ban.service" ];
      serviceConfig = common // {
        ExecStart = lib.escapeShellArgs [
          python
          "${script}"
          "bans"
          "--cscli"
          "${cscli}/bin/cscli"
          "--fail2ban-client"
          "${config.services.fail2ban.package}/bin/fail2ban-client"
          "--cidrs"
          (lib.concatStringsSep "," neverBan)
        ];
        Environment = [
          "SANCTA_DOCTRINE_STAMP=${cfg.bansStampPath}"
          # The nixpkgs cscli wrapper re-execs itself through sudo unless
          # $USER is the crowdsec user. Root needs no sudo (and a sudo every
          # 5 minutes would be journal noise), and without User= systemd sets
          # no $USER at all, which the wrapper's `set -u` would trip on.
          "USER=${config.services.crowdsec.user}"
        ];
        # cscli reads crowdsec's 0600 LAPI credentials as root-but-not-owner.
        # Read-only: ProtectSystem=strict leaves cscli no write anywhere, so
        # it can list decisions but not add or delete one.
        CapabilityBoundingSet = [ "CAP_DAC_READ_SEARCH" ];
        # fail2ban's control socket (AF_UNIX) and CrowdSec's LAPI on loopback.
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
        IPAddressDeny = "any";
        IPAddressAllow = "localhost";
      };
    };

    systemd.timers.soc-alarm-audit = timer "SOC alarm: audit trail, every 5 minutes";
    systemd.timers.soc-alarm-bans = timer "SOC alarm: home-address bans, every 5 minutes";
  };
}
