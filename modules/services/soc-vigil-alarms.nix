# soc-vigil-alarms — the SOC alarms that need root, reported to vigil
# without granting vigil anything.
#
# The SOC plan: "Vigil fires only on: a CrowdSec ban on a tailnet/LAN address,
# an auditd hit on /run/agenix or sudoers, disk over threshold." Disk is a plain
# vigil `disk` contract (vigil-contracts/disk-root.toml). These two cannot be:
# the audit log is root-only, cscli/fail2ban-client need the engines'
# credentials, and vigil on sancta-choir executes no commands (cmdAllow = []).
#
# Root oneshots classify on five-minute timers. Vigil reads their outcomes
# through age contracts, without access to the audit log or engine credentials.
# Audit hits hold the hit stamp red for auditHold. An independent watchdog
# pages on stale evaluator success, short audit retention, and any coverage
# gap whose marker still awaits operator acknowledgement.
# Ban hits and evaluator health have separate paging stamps.
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption types;
  cfg = config.services.soc-vigil-alarms;
  stateDir = "soc-vigil-alarms";
  script = ./soc-vigil-alarms.py;
  bansStampScript = ./soc-bans-stamp.sh;
  python = "${pkgs.python3}/bin/python3";

  # The nixpkgs crowdsec module's wrapper (it adds -c=<its generated config>).
  cscli = lib.findFirst (p: (p.name or "") == "cscli") null config.environment.systemPackages;

  # The same list soc-in-a-box hands fail2ban as ignoreIP and CrowdSec as its
  # whitelist (module-eval asserts the CrowdSec half). One source.
  neverBan = config.services.fail2ban.ignoreIP;

  # The watch rules the trail must have loaded, taken from the one place they
  # are declared (soc-in-a-box's security.audit.rules) as PATH:PERM:KEY.
  watchedKeys = [ "agenix-secrets" "sudoers" ];
  expectedWatches = lib.concatMap
    (rule:
      let m = builtins.match "-w ([^ ]+) -p ([rwxa]+) -k ([a-z-]+)" rule;
      in lib.optional (m != null && builtins.elem (builtins.elemAt m 2) watchedKeys)
        "${builtins.elemAt m 0}:${builtins.elemAt m 1}:${builtins.elemAt m 2}")
    config.security.audit.rules;

  common = {
    Type = "oneshot";
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

    paging = {
      audit = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether a soc-audit rule hit is sent to Telegram. Off, so hits
          land in the journal and on the dashboard only. The switch itself is
          `page` in hosts/sancta-choir/vigil-contracts/soc-audit.toml (vigil
          contracts are static files); tests/module-eval.nix fails if the two
          disagree.
        '';
      };
      bans = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether a red soc-bans contract is sent to Telegram. Mirrors
          `page` in vigil-contracts/soc-bans.toml (pinned by module-eval).
        '';
      };
    };

    auditDisk = {
      warnGiB = mkOption {
        type = types.ints.positive;
        default = 10;
        description = "Free GiB on the audit log's filesystem below which the audit evaluator logs a WARN line (still clean).";
      };
      failGiB = mkOption {
        type = types.ints.positive;
        default = 5;
        description = "Free GiB below which the audit evaluator reports an evaluator error: auditd suspends writing on a full disk while staying active.";
      };
      inodeFailPercent = mkOption {
        type = types.numbers.between 0 100;
        default = 5;
        description = "Free-inode percentage below which the audit evaluator reports an evaluator error.";
      };
    };

    namedAccounts = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "alexandru" "agent" ];
      description = ''
        User names whose activity the audit evaluator reports as soc-audit
        hits: every root exec by the account (audit key root-exec, matched on
        the login uid) and every successful login session (USER_LOGIN or
        USER_START records). Names, not uids: the evaluator resolves them with
        getpwnam on every run, and a name that does not resolve is an
        evaluator error. Empty (the default) turns the rule off. Report-only
        like the rest of soc-audit while paging.audit is false. The change
        that adds the named OpenSSH accounts (PR #664) sets this to
        [ "alexandru" "agent" ].
      '';
    };

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
      default = "/var/lib/${stateDir}/audit-hits-clean";
      description = "Audit alarm outcome as one mtime; read by vigil-contracts/soc-audit.toml (module-eval pins the equality).";
    };

    bansHealthStampPath = mkOption {
      type = types.str;
      readOnly = true;
      default = "/var/lib/${stateDir}/bans-health-clean";
      description = "Ban evaluator health as one mtime; read by vigil-contracts/soc-bans-health.toml (module-eval pins the equality).";
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
        assertion = lib.length expectedWatches == lib.length watchedKeys;
        message = "services.soc-vigil-alarms: security.audit.rules must hold one `-w PATH -p PERM -k KEY` rule per watched key (${lib.concatStringsSep ", " watchedKeys}).";
      }
      {
        assertion = lib.all (n: config.users.users ? ${n}) cfg.namedAccounts;
        message = "services.soc-vigil-alarms.namedAccounts: every name must be a declared user (users.users); unknown: ${lib.concatStringsSep ", " (lib.filter (n: !(config.users.users ? ${n})) cfg.namedAccounts)}";
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
        ExecStart = lib.escapeShellArgs ([
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
          # Trail health (auditctl -s / -l): auditing enabled with a live
          # auditd, no events lost within a boot, and exactly the declared
          # agenix-secrets and sudoers watches loaded (--expect-watch below).
          "--auditctl"
          "${pkgs.audit}/bin/auditctl"
          "--require-active"
          "auditd.service"
          "--require-active"
          "audit-rules-nixos.service"
          "--hold"
          (toString cfg.auditHold)
          # Two timer periods (one failed run in between is normal and must not
          # read as lost coverage) + TimeoutStartSec + AccuracySec + slack.
          "--max-gap"
          "900"
          "--disk-warn-bytes"
          (toString (cfg.auditDisk.warnGiB * 1073741824))
          "--disk-fail-bytes"
          (toString (cfg.auditDisk.failGiB * 1073741824))
          "--inode-fail-percent"
          (toString cfg.auditDisk.inodeFailPercent)
        ] ++ lib.concatMap (w: [ "--expect-watch" w ]) expectedWatches
        ++ lib.concatMap (n: [ "--named-account" n ]) cfg.namedAccounts);
        # The checkpoint and last-hit files live in $STATE_DIRECTORY (set by
        # StateDirectory=), so no off-store path appears in ExecStart.
        ExecStopPost = "${python} ${script} audit-stamp";
        Environment = [ "SANCTA_DOCTRINE_STAMP=${cfg.auditStampPath}" ];
        # AUDIT_CONTROL queries auditctl over netlink. DAC_OVERRIDE lets us
        # append to the existing root-owned 0400, +a F15 evidence file.
        CapabilityBoundingSet = [ "CAP_AUDIT_CONTROL" "CAP_DAC_OVERRIDE" ];
        PrivateNetwork = true;
        RestrictAddressFamilies = [ "AF_UNIX" "AF_NETLINK" ];
      };
    };

    systemd.services.soc-audit-watchdog = {
      description = "SOC audit evaluator liveness, coverage acknowledgement and retained log age";
      serviceConfig = common // {
        ExecStart = "${python} ${script} audit-watchdog";
        CapabilityBoundingSet = "";
        PrivateNetwork = true;
      };
    };

    systemd.services.soc-alarm-bans = {
      description = "SOC alarm: CrowdSec decision or fail2ban ban on a home address";
      after = [ "crowdsec.service" "fail2ban.service" ];
      serviceConfig = common // {
        # Two stamps: a ban turns soc-bans red (pages); an evaluator error
        # turns the separate soc-bans-health paging contract red.
        ExecStopPost = "${pkgs.bash}/bin/bash ${bansStampScript}";
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
          "SOC_HEALTH_STAMP=${cfg.bansHealthStampPath}"
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
        # cscli embeds a WebAssembly runtime (wazero) whose compiler maps
        # executable memory; with MemoryDenyWriteExecute it panics
        # ("mmapExecutable: permission denied") and the evaluator can never
        # read decisions. Off for this unit only; every other line of the
        # shared hardening stays, and soc-alarm-audit keeps it on.
        MemoryDenyWriteExecute = false;
        # fail2ban's control socket (AF_UNIX) and CrowdSec's LAPI on loopback.
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
        IPAddressDeny = "any";
        IPAddressAllow = "localhost";
      };
    };

    systemd.timers.soc-audit-watchdog = timer "Check liveness and retention independently of the audit evaluator";
    systemd.timers.soc-alarm-audit = timer "SOC alarm: audit trail, every 5 minutes";
    systemd.timers.soc-alarm-bans = timer "SOC alarm: home-address bans, every 5 minutes";
  };
}
