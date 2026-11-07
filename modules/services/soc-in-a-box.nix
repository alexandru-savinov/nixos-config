# Host security monitoring in one file: the Linux audit trail (auditd) plus
# CrowdSec reading sshd from the journal. Detection only: there is no
# firewall bouncer here, so CrowdSec decisions are not applied to the host
# firewall. Banning is a later, council-gated step (Vigil horizon, phase 4).
#
# Import it in a host's configuration.nix; there is no separate enable switch.
# Everything stays on the host: auditd writes to /var/log/audit, CrowdSec's
# local API listens on loopback only, and the Central API / console are off.
{ config, lib, ... }:

let
  # Local API on loopback. Not 8080: that port is the conventional loopback
  # target for Tailscale Serve in this repo, and LAPI must never sit behind it.
  lapiListen = "127.0.0.1:8095";

  # Address ranges neither CrowdSec nor fail2ban may ever act on: the tailnet
  # (CGNAT + Tailscale ULA), loopback, and private LAN ranges. One list for
  # both engines, so an exemption cannot exist in one and be missing in the
  # other. The tailnet is choir's admin path; a ban there is a lockout that
  # only the Hetzner web console can undo.
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
      #    `auditctl -R` stops at the first rule the kernel rejects, and the
      #    unit's ExecStopPost then deletes every rule, so no watch here may
      #    be able to fail. A missing leaf does not fail: the kernel resolves
      #    a watch through its parent directory (kernel/audit_watch.c,
      #    audit_get_nd) and only a missing PARENT is an error. Every watched
      #    path below has a parent that always exists (/run, /etc, /etc/ssh).
      "-w ${config.age.secretsMountPoint} -p rwa -k agenix-secrets"

      # 2. sudo policy changes. The NixOS-generated /etc/sudoers has no
      #    @includedir, so it is the whole policy; adding a drop-in directory
      #    would first need a change to this watched file. (No sudoers.d watch:
      #    the path does not exist on NixOS, and a watch that fails to load
      #    can stop `auditctl -R` before the rules after it.)
      "-w /etc/sudoers -p wa -k sudoers"

      # 3. sshd configuration changes.
      "-w /etc/ssh/sshd_config -p wa -k sshd-config"

      # 4. account database changes, one key for the group.
      "-w /etc/passwd -p wa -k identity"
      "-w /etc/shadow -p wa -k identity"
      "-w /etc/group -p wa -k identity"

      # 5. commands run as root by a real logged-in user (sudo and friends),
      #    on both syscall ABIs.
      "-a always,exit -F arch=b64 -S execve -F euid=0 -F auid>=1000 -F auid!=unset -k root-exec"
      "-a always,exit -F arch=b32 -S execve -F euid=0 -F auid>=1000 -F auid!=unset -k root-exec"
    ];
  };

  # ── CrowdSec: sshd detection from the journal, local decisions only ─────
  #
  # One banning engine for sshd: fail2ban's sshd jail (hosts/common.nix) is
  # the only thing that blocks an address. CrowdSec reads the same journal
  # detect-only (no bouncer, see the header), so the two never stack bans on
  # the admin path. An IP fail2ban has banned shows in
  # `fail2ban-client status sshd`; an IP CrowdSec has only flagged (not
  # blocked) shows in `cscli decisions list`.
  services.fail2ban.ignoreIP = neverBan;

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
    {
      assertion = lib.all (cidr: lib.elem cidr config.services.fail2ban.ignoreIP) [
        "100.64.0.0/10"
        "fd7a:115c:a1e0::/48"
      ];
      message = "soc-in-a-box: fail2ban must never ban the tailnet (the admin path).";
    }
  ];
}
