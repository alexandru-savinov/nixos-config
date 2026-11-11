# Host security monitoring in one file: the Linux audit trail (auditd) plus
# CrowdSec reading sshd from the journal, with a firewall bouncer that applies
# CrowdSec's local decisions to the host firewall (Vigil horizon phase 4,
# council-gated). CrowdSec is the only sshd banning engine on a host that
# imports this file: fail2ban's sshd jail must be off (asserted below).
#
# Import it in a host's configuration.nix; there is no separate enable switch.
# Everything stays on the host: auditd writes to /var/log/audit, CrowdSec's
# local API listens on loopback only, and the Central API / console are off.
{ config, lib, ... }:

let
  cfg = config.sancta.soc;
  bouncer = config.services.crowdsec-firewall-bouncer;
  fw = config.networking.firewall;

  # Local API on loopback. Not 8080: that port is the conventional loopback
  # target for Tailscale Serve in this repo, and LAPI must never sit behind it.
  lapiListen = "127.0.0.1:8095";

  # The tailnet ranges: choir's admin path. A ban here is a lockout that only
  # the Hetzner web console can undo, so every assertion below is pinned to
  # these two constants, not to whatever the neverBan list currently holds.
  adminPath = [
    "100.64.0.0/10"
    "fd7a:115c:a1e0::/48"
  ];

  isV6 = lib.hasInfix ":";
  neverBanV4 = lib.filter (c: !isV6 c) cfg.neverBan;
  neverBanV6 = lib.filter isV6 cfg.neverBan;

  # ── Firewall-level exemption (independent of CrowdSec's whitelist) ──────
  #
  # The CrowdSec whitelist parser below only filters events the parsers see.
  # It does NOT filter `cscli decisions add`, a decision imported from a list,
  # or a future scenario on another acquisition. So the firewall itself
  # refuses to apply any CrowdSec drop to these ranges:
  #
  #   nixos-fw (rule 1) -> sancta-crowdsec-gate
  #     -i lo / -i tailscale0 / -s <every neverBan range>  -> RETURN
  #     everything else                                    -> sancta-crowdsec-bans
  #   sancta-crowdsec-bans  <- the bouncer inserts its jump to CROWDSEC_CHAIN
  #                            here (iptables_chains), and nowhere else.
  #
  # The bouncer's set-match DROP rules live in CROWDSEC_CHAIN, and the only
  # way into it is through the gate's RETURNs. An address in neverBan can be
  # in a CrowdSec ipset and still never be dropped.
  #
  # The bans chain is created once and never flushed here: the bouncer owns
  # its content, and a firewall reload (which flushes only nixos-* chains and
  # this gate) leaves the bouncer's jump in place. If the chain were missing
  # when the bouncer starts, the bouncer logs an error and blocks nothing:
  # fail-open, never a lockout.
  gateChain = "sancta-crowdsec-gate";
  bansChain = "sancta-crowdsec-bans";
  tsIface = config.services.tailscale.interfaceName;

  gateCommands = ''
    # ── soc-in-a-box: CrowdSec bans, gated by the neverBan list ──
    ip46tables -N ${bansChain} 2>/dev/null || true
    ip46tables -F ${gateChain} 2>/dev/null || true
    ip46tables -N ${gateChain} 2>/dev/null || true
    ip46tables -A ${gateChain} -i lo -j RETURN
    ip46tables -A ${gateChain} -i ${tsIface} -j RETURN
    ${lib.concatMapStrings (c: ''
      iptables -w -A ${gateChain} -s ${c} -j RETURN
    '') neverBanV4}
    ${lib.optionalString config.networking.enableIPv6 (lib.concatMapStrings (c: ''
      ip6tables -w -A ${gateChain} -s ${c} -j RETURN
    '') neverBanV6)}
    ip46tables -A ${gateChain} -j ${bansChain}
    ip46tables -I nixos-fw 1 -j ${gateChain}
  '';

  # What the assertion reads back: the RENDERED firewall script, so a list
  # override, a mkForce'd extraCommands or a reordering all show up here.
  fwLines = lib.splitString "\n" fw.extraCommands;
  lineIndex = needle:
    let
      hits = lib.filter (i: lib.hasInfix needle (lib.elemAt fwLines i)) (lib.range 0 (lib.length fwLines - 1));
    in
    if hits == [ ] then null else lib.head hits;
  returnIdx = cidr: lineIndex "-A ${gateChain} -s ${cidr} -j RETURN";
  jumpToBansIdx = lineIndex "-A ${gateChain} -j ${bansChain}";
  gateHookIdx = lineIndex "-I nixos-fw 1 -j ${gateChain}";
  # fail2ban renders a jail as `{ enabled = jail.enabled; } // jail.settings`
  # (nixpkgs fail2ban.nix, mkJailConfig), so settings.enabled wins when set.
  fail2banSshdJailOn =
    let
      j = config.services.fail2ban.jails.sshd or null;
    in
    if j == null then false
    else if builtins.isString j then j != ""
    else j.settings.enabled or j.enabled;

  adminPathRendered = lib.filter (c: config.networking.enableIPv6 || !isV6 c) adminPath;
  gateExemptsAdminPath =
    jumpToBansIdx != null
    && gateHookIdx != null
    && lib.all
      (c:
        let i = returnIdx c; in i != null && i < jumpToBansIdx)
      adminPathRendered;
in
{
  options.sancta.soc.neverBan = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    internal = true;
    description = ''
      Address ranges no banning engine may ever act on: the tailnet (CGNAT +
      Tailscale ULA), loopback, and private LAN ranges. One list for the
      CrowdSec whitelist, the firewall gate in front of the bouncer, and
      fail2ban's ignoreIP, so an exemption cannot exist in one and be missing
      in another. An option only so the module-eval negative arms can remove
      a range and watch the assertion fire.
    '';
    default = [
      "100.64.0.0/10"
      "fd7a:115c:a1e0::/48"
      "127.0.0.0/8"
      "::1/128"
      "10.0.0.0/8"
      "172.16.0.0/12"
      "192.168.0.0/16"
    ];
  };

  config = {
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
    # One banning engine for sshd: CrowdSec, through the firewall bouncer
    # below. fail2ban's sshd jail (hosts/common.nix) must be off on any host
    # that imports this file (the host turns it off; asserted below), so the
    # two never stack bans on the admin path. A banned IP shows in
    # `cscli decisions list`, and its drop in `iptables -L CROWDSEC_CHAIN -v`.
    # ignoreIP stays set so that fail2ban, if a host ever runs it for another
    # jail, inherits the same exemption list.
    services.fail2ban.ignoreIP = cfg.neverBan;

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
              cidr = cfg.neverBan;
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

    # ── Firewall bouncer: local LAPI decisions -> host firewall ─────────────
    #
    # API key: registerBouncer.enable defaults to services.crowdsec.enable, so
    # the module's crowdsec-firewall-bouncer-register oneshot runs
    # `cscli bouncers add` on the host at first start and keeps the key in
    # /var/lib/crowdsec-firewall-bouncer-register/ (0077 umask, DynamicUser);
    # the bouncer reads it through LoadCredential. No secret in the repo, no
    # agenix file, nothing in the Nix store (api_key renders as a placeholder).
    #
    # Mode: iptables. choir's firewall is the iptables backend
    # (networking.nftables.enable = false), so nftables mode would put the
    # bouncer's drop in a separate nft table where no gate could precede it.
    services.crowdsec-firewall-bouncer = {
      enable = true;
      settings = {
        mode = "iptables";
        api_url = "http://${lapiListen}";
        deny_action = "DROP";
        # The ONLY chain the bouncer hooks; see gateCommands above. The module
        # default is INPUT (lib.mkDefault), which would sit in front of the gate.
        iptables_chains = [ bansChain ];
      };
    };

    networking.firewall.extraCommands = gateCommands;

    # Start after the firewall has created the bans chain (boot order already
    # puts the firewall before network-pre.target; this makes it explicit).
    systemd.services.crowdsec-firewall-bouncer.after = [ "firewall.service" ];

    assertions = [
      {
        assertion = lib.all (c: lib.elem c cfg.neverBan) adminPath;
        message = "soc-in-a-box: the neverBan list must contain the tailnet ranges ${toString adminPath} (choir's admin path).";
      }
      {
        assertion = fw.enable && fw.backend == "iptables" && !config.networking.nftables.enable
          && bouncer.settings.mode == "iptables";
        message = "soc-in-a-box: the CrowdSec bouncer must run in iptables mode on the iptables firewall; the neverBan gate exists only there.";
      }
      {
        assertion = gateExemptsAdminPath;
        message = "soc-in-a-box: the firewall gate in front of the CrowdSec bouncer must RETURN the tailnet ranges ${toString adminPath} before jumping to ${bansChain}, and be hooked first in nixos-fw.";
      }
      {
        assertion = bouncer.settings.iptables_chains == [ bansChain ]
          && (bouncer.settings.iptables_v4_chains or [ ]) == [ ]
          && (bouncer.settings.iptables_v6_chains or [ ]) == [ ];
        message = "soc-in-a-box: the CrowdSec bouncer may hook only ${bansChain} (behind the neverBan gate), never INPUT or any other chain.";
      }
      {
        assertion = bouncer.settings.api_url == "http://${lapiListen}"
          && bouncer.registerBouncer.enable
          && bouncer.secrets.apiKeyPath == null
          && bouncer.settings.api_key == "@API_KEY_FILE@";
        message = "soc-in-a-box: the CrowdSec bouncer must talk to the loopback LAPI only, with a host-minted key (registerBouncer), never a key in the Nix store.";
      }
      {
        assertion = !(config.services.fail2ban.enable && fail2banSshdJailOn);
        message = "soc-in-a-box: fail2ban's sshd jail must be off where CrowdSec bans; two engines stack bans on the admin path.";
      }
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
        # Meaningful whenever fail2ban runs at all (any jail, any host that
        # turns it back on), vacuous only when it is off.
        assertion = !config.services.fail2ban.enable
          || lib.all (cidr: lib.elem cidr config.services.fail2ban.ignoreIP) adminPath;
        message = "soc-in-a-box: fail2ban must never ban the tailnet (the admin path).";
      }
    ];
  };
}
