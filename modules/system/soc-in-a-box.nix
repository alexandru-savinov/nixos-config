# Host security monitoring in one file: the Linux audit trail (auditd) plus
# CrowdSec reading sshd from the journal, with a local firewall bouncer.
#
# Import it in a host's configuration.nix; there is no separate enable switch.
# Everything stays on the host: auditd writes to /var/log/audit, CrowdSec's
# local API listens on loopback only, and the Central API / console are off.
{ config, lib, ... }:

let
  # Local API on loopback. Not 8080: that port is the conventional loopback
  # target for Tailscale Serve in this repo, and LAPI must never sit behind it.
  lapiListen = "127.0.0.1:8095";

  # Address ranges CrowdSec must never ban: the tailnet (CGNAT + Tailscale
  # ULA), loopback, and private LAN ranges.
  neverBan = [
    "100.64.0.0/10"
    "fd7a:115c:a1e0::/48"
    "127.0.0.0/8"
    "::1/128"
    "10.0.0.0/8"
    "172.16.0.0/12"
    "192.168.0.0/16"
  ];
in
{
  # ── auditd: kernel audit trail with a hard size cap ─────────────────────
  security.auditd = {
    enable = true;
    settings = {
      # 4 files x 8 MiB, rotated: the audit log never exceeds ~32 MiB.
      max_log_file = 8;
      num_logs = 4;
      max_log_file_action = "rotate";
      # Low-disk behaviour (MiB of free space on /var/log/audit's filesystem):
      # warn to syslog first, then stop writing audit records. Never halt or
      # drop to single-user mode.
      space_left = 1024;
      space_left_action = "syslog";
      admin_space_left = 512;
      admin_space_left_action = "suspend";
      disk_full_action = "suspend";
      disk_error_action = "syslog";
    };
  };

  security.audit = {
    enable = true;
    # On audit subsystem errors, log to the kernel ring buffer; never panic.
    failureMode = "printk";
    backlogLimit = 8192;
    # Messages per second before the failure mode applies.
    rateLimit = 200;
    rules = [
      # 1. agenix-decrypted secrets: any read, write or attribute change.
      #    /run/agenix is a symlink into this directory; watch the real tree.
      "-w ${config.age.secretsMountPoint} -p rwa -k agenix-secrets"

      # 2. sudo policy changes.
      "-w /etc/sudoers -p wa -k sudoers"
      "-w /etc/sudoers.d -p wa -k sudoers"

      # 3. sshd configuration changes.
      "-w /etc/ssh/sshd_config -p wa -k sshd-config"

      # 4. account database changes, one key for the group.
      "-w /etc/passwd -p wa -k identity"
      "-w /etc/shadow -p wa -k identity"
      "-w /etc/group -p wa -k identity"

      # 5. commands run as root by a real logged-in user (sudo and friends).
      "-a always,exit -F arch=b64 -S execve -F euid=0 -F auid>=1000 -F auid!=unset -k root-exec"
    ];
  };

  # ── CrowdSec: sshd detection from the journal, local decisions only ─────
  services.crowdsec = {
    enable = true;
    openFirewall = false;

    hub = {
      collections = [ "crowdsecurity/sshd" ];
      # journalctl output is syslog-formatted; these parse it before the
      # sshd parser runs.
      parsers = [
        "crowdsecurity/syslog-logs"
        "crowdsecurity/dateparse-enrich"
      ];
    };

    localConfig = {
      acquisitions = [
        {
          source = "journalctl";
          journalctl_filter = [ "_SYSTEMD_UNIT=sshd.service" ];
          labels.type = "syslog";
        }
      ];

      parsers.s02Enrich = [
        {
          name = "local/never-ban-own-networks";
          description = "Never act on the tailnet, loopback or private LAN ranges";
          whitelist = {
            reason = "own networks";
            cidr = neverBan;
          };
        }
      ];
    };

    settings = {
      # Written by `cscli machine add --auto` on first start (module setup).
      lapi.credentialsFile = "/var/lib/crowdsec/state/local_api_credentials.yaml";

      general = {
        api.server = {
          enable = true;
          listen_uri = lapiListen;
          # No Central API: no community blocklist pull, no signal sharing,
          # no console. A null online_client is CrowdSec's "CAPI disabled".
          online_client = null;
        };
        # Metrics stay on loopback (read by `cscli metrics`).
        prometheus = {
          listen_addr = "127.0.0.1";
          listen_port = 6060;
        };
      };

      console.configuration = {
        share_manual_decisions = false;
        share_custom = false;
        share_tainted = false;
        share_context = false;
        console_management = false;
      };
    };
  };

  # Firewall bouncer: applies local LAPI decisions to the host firewall. It
  # registers itself against the local API (module default), so its API key
  # is generated on the host at first start; nothing is stored in the repo.
  services.crowdsec-firewall-bouncer = {
    enable = true;
    settings.api_url = "http://${lapiListen}";
  };

  assertions = [
    {
      assertion = lib.hasPrefix "127.0.0.1:" config.services.crowdsec.settings.general.api.server.listen_uri;
      message = "soc-in-a-box: the CrowdSec local API must listen on 127.0.0.1 only.";
    }
    {
      assertion = config.services.crowdsec.settings.general.api.server.online_client == null
        && config.services.crowdsec.settings.capi.credentialsFile == null
        && config.services.crowdsec.settings.console.tokenFile == null;
      message = "soc-in-a-box: CrowdSec Central API and console must stay disabled.";
    }
  ];
}
