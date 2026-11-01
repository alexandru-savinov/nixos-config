# Loopback-only SOC sensors read by Vigil's crowdsec, osquery and anomaly checkers.
# Vigil stays the only speaker: every sensor has its own alerting off, and nothing here
# enforces anything (no bouncer, no osquery distributed or write features).
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkIf mkMerge mkOption types;
  vigil = config.services.vigil;
  cfg = vigil.sensors;

  # 8080, the upstream default, is Open-WebUI on both hosts.
  crowdsecPort = 8088;
  crowdsecCredentials = "/var/lib/vigil/crowdsec.yaml";
  netdataPort = 19999;
  osqueryResults = "/var/log/osquery/osqueryd.snapshots.log";

  # The anomaly checker needs the tick in whole seconds; services.vigil.interval is a
  # systemd span. Null when it cannot be read, which the assertion below rejects.
  intervalSeconds =
    let
      parts = builtins.match "([0-9]+) *(s|sec|m|min|h)?" vigil.interval;
      unit = builtins.elemAt parts 1;
      factor = { s = 1; sec = 1; m = 60; min = 60; h = 3600; };
    in
    if parts == null then null
    else lib.toInt (builtins.head parts) * (if unit == null then 1 else factor.${unit});

  # Row keys are fixed by OSQUERY_QUERIES in pkgs/vigil/lib/checks.mjs.
  # - listening_ports: LEFT JOIN so a socket with no resolvable owner still reports, and
  #   the family filter drops AF_UNIX rows, which all read port 0.
  # - suid_bins: the suid_bin table only walks /bin, /sbin, /usr/*bin, /usr/local/*bin and
  #   /tmp (osquery 5.21.0, tables/system/posix/suid_bin.cpp), which is nothing on NixOS, so
  #   read the wrapper directory. mode is four octal digits; 2000 and up is setuid or setgid.
  osqueryQueries = {
    listening_ports = "SELECT DISTINCT lp.port, lp.protocol, COALESCE(p.name, '') AS name FROM listening_ports AS lp LEFT JOIN processes AS p USING (pid) WHERE lp.port != 0 AND lp.family IN (2, 10);";
    local_users = "SELECT username FROM users;";
    suid_bins = "SELECT path FROM file WHERE directory = '${config.security.wrapperDir}' AND CAST(mode AS INTEGER) >= 2000;";
    etc_fim = "SELECT target_path FROM file_events;";
  };
in
{
  options.services.vigil.sensors = {
    crowdsec.enable = mkEnableOption "the CrowdSec detection engine, with no bouncer";
    osquery = {
      enable = mkEnableOption "the osquery daemon with the vigil query pack";
      interval = mkOption { type = types.ints.positive; default = 300; description = "Seconds between runs of each pack query."; };
    };
    netdata.enable = mkEnableOption "Netdata with ML anomaly detection";
  };

  config = mkMerge [
    (mkIf (cfg.crowdsec.enable || cfg.osquery.enable || cfg.netdata.enable) {
      assertions = [
        { assertion = vigil.enable; message = "vigil: services.vigil.sensors requires services.vigil.enable"; }
      ];
    })

    (mkIf cfg.crowdsec.enable {
      services.crowdsec = {
        enable = true;
        hub.collections = [ "crowdsecurity/linux" ];
        localConfig.acquisitions = [{
          source = "journalctl";
          journalctl_filter = [ "_SYSTEMD_UNIT=sshd.service" ];
          labels.type = "syslog";
        }];
        # No capi or console credentials, so the Central API and enrolment stay off, and
        # localConfig.notifications stays empty. The default profile's decisions go nowhere.
        settings = {
          lapi.credentialsFile = "/var/lib/crowdsec/state/local_api_credentials.yaml";
          general = {
            api.server = { enable = true; listen_uri = "127.0.0.1:${toString crowdsecPort}"; };
            prometheus.enabled = false;
          };
        };
      };
      systemd.services.crowdsec = {
        # The journalctl source execs journalctl from PATH, and upstream forces path empty.
        path = lib.mkForce [ pkgs.systemd ];
        serviceConfig.MemoryMax = "256M";
      };
      # The cscli wrapper reads $USER under set -u and hands root to sudo. It has to run as
      # crowdsec anyway, or root would own what it adds beside the live SQLite database, and
      # crowdsec cannot write the vigil state directory, hence stdout into a root-written file.
      systemd.services.vigil-crowdsec-register = {
        description = "Register the vigil machine with the CrowdSec local API";
        wantedBy = [ "crowdsec.service" ];
        after = [ "crowdsec.service" "systemd-tmpfiles-setup.service" ];
        environment.USER = "crowdsec";
        path = [ pkgs.coreutils pkgs.gnugrep pkgs.util-linux ];
        serviceConfig = { Type = "oneshot"; UMask = "0077"; Restart = "on-failure"; RestartSec = "30s"; };
        script = ''
          [ -e ${crowdsecCredentials} ] && exit 0
          staged=$(mktemp ${crowdsecCredentials}.XXXXXX)
          trap 'rm -f "$staged"' EXIT
          runuser -u crowdsec -- /run/current-system/sw/bin/cscli machines add vigil --auto -f - --force > "$staged"
          grep -q '^password: ' "$staged"
          # vigil owns this directory and could swap the staged name for a symlink.
          chmod 0400 "$staged"
          chown -h vigil:vigil "$staged"
          mv "$staged" ${crowdsecCredentials}
        '';
      };
      systemd.services.vigil.environment.VIGIL_CROWDSEC_CREDENTIALS = crowdsecCredentials;
      # Same user as the checker, so the responder needs the file masked explicitly.
      systemd.services."vigil-tick@".serviceConfig.InaccessiblePaths = [ "-${crowdsecCredentials}" ];
    })

    (mkIf cfg.osquery.enable {
      services.osquery = {
        enable = true;
        flags = {
          disable_events = "false";
          enable_file_events = "true";
          # Snapshot logs are never rotated by default. Rotation empties the file, so a tick
          # landing right after one can read a query as absent until its next run.
          logger_rotate = "true";
          logger_rotate_max_files = "2";
          # Below MemoryMax, so the watchdog restarts its worker before the cgroup kills it.
          watchdog_memory_limit = "100";
        };
        settings = {
          file_paths.etc = [ "/etc/%%" ];
          packs.vigil.queries = lib.mapAttrs
            (_: query: { inherit query; inherit (cfg.osquery) interval; snapshot = true; })
            osqueryQueries;
        };
      };
      systemd.services.osqueryd.serviceConfig = {
        # Root as before: only the group changes, so logs land root:vigil 0640 (logger_mode).
        Group = "vigil";
        MemoryMax = "128M";
      };
      systemd.services.vigil.environment = {
        VIGIL_OSQUERY_RESULTS = osqueryResults;
        VIGIL_OSQUERY_INTERVAL = toString cfg.osquery.interval;
      };
    })

    (mkIf cfg.netdata.enable {
      assertions = [
        { assertion = intervalSeconds != null && intervalSeconds > 0; message = "vigil: services.vigil.interval must be whole seconds, minutes or hours for the anomaly checker"; }
      ];
      # Claiming is the only way out to Netdata Cloud: ACLK waits forever on an unclaimed agent.
      services.netdata = {
        enable = true;
        claimTokenFile = null;
        config = {
          web."bind to" = "127.0.0.1:${toString netdataPort}";
          db = {
            mode = "dbengine";
            "storage tiers" = "1";
            "dbengine tier 0 retention size" = "256MiB";
          };
          ml.enabled = "yes";
          health.enabled = "no";
          # Both listen on their own ports and nothing here feeds them.
          plugins = { statsd = "no"; otel = "no"; };
        };
      };
      systemd.services.netdata.serviceConfig.MemoryMax = "400M";
      systemd.services.vigil.environment = {
        VIGIL_NETDATA_URL = "http://127.0.0.1:${toString netdataPort}";
        VIGIL_ANOMALY_INTERVAL = toString intervalSeconds;
      };
    })
  ];
}
