# sancta-choir: named admin and agent accounts over OpenSSH on the tailnet.
#
# Named accounts (alexandru, agent, diag) plus sancta's workstation keys on a
# second sshd listener (port 2222) reachable only through tailscale0. Port 22
# (public) serves only the soul-mirror pull (sancta, forced command); root has
# no OpenSSH keys and PermitRootLogin is no (configuration.nix/networking.nix).
#
# Keys come from the options below; every key is rendered with a `from=`
# source restriction to the tailnet ranges; callers pass plain public keys
# only. These keys gate OpenSSH only. While Tailscale SSH is on, the accounts
# are reachable through it from the moment they exist, governed solely by the
# tailnet policy's `ssh` rules (outside this repo), which must admit only
# principals that already have root on this host. Stage 4 of the cutover
# removes Tailscale SSH and those rules.
{ config, lib, pkgs, ... }:

let
  cfg = config.sancta-choir.adminKeys;

  tailnetFrom = "100.64.0.0/10,fd7a:115c:a1e0::/48";
  restrict = key: "from=\"${tailnetFrom}\" ${key}";

  # A plain public key starts with its key type, never with options.
  keyTypePattern = "(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\\.com|sk-ecdsa-sha2-nistp256@openssh\\.com) .*";
  # One key per string: no newline (a second line would be a second, unrestricted key).
  isPlainKey = key: builtins.match keyTypePattern key != null && !(lib.hasInfix "\n" key) && !(lib.hasInfix "\r" key);

  listenerPort = 2222;

  # Stage 3a: keys for the `sancta` account used from one workstation. They
  # live in a SEPARATE file that sshd reads only for `sancta` on the second
  # listener, so they authenticate nowhere else (fail closed on port 22).
  sanctaKeyFile = "/etc/ssh/authorized_keys.sancta-2222";
  macFrom = lib.concatStringsSep "," cfg.macAddresses;
  pollLine = key: "restrict,command=\"${cfg.sanctaPollCommand}\",from=\"${macFrom}\" ${key}";
  sessionLine = key: "restrict,pty,port-forwarding,permitlisten=\"127.0.0.1:*\",from=\"${macFrom}\" ${key}";

  # Read-only diagnostics account. Its keys live in a SEPARATE file read only
  # for `diag` on the second listener; every key is forced into the dispatcher.
  diagKeyFile = "/etc/ssh/authorized_keys.diag-2222";
  choirDiag = pkgs.writeShellApplication {
    name = "choir-diag";
    runtimeInputs = with pkgs; [ coreutils systemd iproute2 util-linux tailscale procps ];
    text = builtins.readFile ./choir-diag.sh;
  };
  diagLine = key: "restrict,command=\"${lib.getExe choirDiag}\",from=\"${macFrom}\" ${key}";
  diagLines = map diagLine cfg.diag;
  sanctaLines = map pollLine cfg.sanctaPoll ++ map sessionLine cfg.sanctaSession;
in
{
  options.sancta-choir.adminKeys = {
    owner = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Plain public keys for the `alexandru` account (from= is added by this module).";
    };
    agent = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Plain public keys for the unprivileged `agent` account (from= is added by this module).";
    };
    sanctaPoll = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Plain public keys for the read-only status poll as `sancta` (key file ~/.ssh/id_ed25519_sancta_poll, comment sancta-status-poll@mac) (forced command, no pty, no forwarding; port 2222 only).";
    };
    sanctaPollCommand = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/sancta/.claude/index/bin/sancta-status-line";
      description = "The one command the poll key may run (forced; the client's own command is ignored).";
    };
    sanctaSession = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Plain public keys for interactive `sancta` sessions (key file ~/.ssh/id_ed25519_sancta_attach, comment sancta-attach@mac) (pty, remote forwarding to loopback only; port 2222 only).";
    };
    diag = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Plain public keys for the read-only `diag` account (forced command choir-diag, no pty, no forwarding; port 2222 only).";
    };
    macAddresses = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Tailnet addresses (IPv4 and IPv6) the workstation connects from; required when any sancta key is set.";
    };
  };

  config = {
    assertions = [
      {
        assertion = lib.all isPlainKey (cfg.owner ++ cfg.agent ++ cfg.sanctaPoll ++ cfg.sanctaSession ++ cfg.diag);
        message = "sancta-choir.adminKeys: every key must be a plain public key (key type first, no options); the module prepends the from= restriction itself.";
      }
      {
        assertion = (cfg.sanctaPoll ++ cfg.sanctaSession ++ cfg.diag) == [ ] || cfg.macAddresses != [ ];
        message = "sancta-choir.adminKeys: macAddresses must be non-empty when sanctaPoll, sanctaSession or diag has keys (from= is mandatory).";
      }
    ];

    # Absent (not empty) while no sancta key is configured: nothing new can
    # log in until keys are supplied.
    environment.etc."ssh/authorized_keys.sancta-2222" = lib.mkIf (sanctaLines != [ ]) {
      text = lib.concatStringsSep "\n" sanctaLines + "\n";
      mode = "0444";
      user = "root";
      group = "root";
    };

    environment.etc."ssh/authorized_keys.diag-2222" = lib.mkIf (diagLines != [ ]) {
      text = lib.concatStringsSep "\n" diagLines + "\n";
      mode = "0444";
      user = "root";
      group = "root";
    };

    users.users.alexandru = {
      isNormalUser = true;
      description = "Owner (named admin account)";
      extraGroups = [ "wheel" ];
      openssh.authorizedKeys.keys = map restrict cfg.owner;
    };

    # No account on this host has a password, so the default
    # wheelNeedsPassword = true would make sudo unusable for alexandru.
    # Scoped exception: passwordless sudo for this one user only (the wheel
    # group policy for everyone else is unchanged). Access to the account is
    # gated by the key + from= restriction above for OpenSSH. While Tailscale
    # SSH is on it is ALSO reachable through it, with no key, under the tailnet
    # policy's `ssh` rules: those must admit only principals that already have
    # root here, checked before deploy (see the header).
    security.sudo.extraRules = [
      {
        users = [ "alexandru" ];
        commands = [
          {
            command = "ALL";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];

    # Unprivileged agent account: no wheel, no sudo.
    users.users.agent = {
      isNormalUser = true;
      description = "Agent (unprivileged access account)";
      extraGroups = [ ];
      openssh.authorizedKeys.keys = map restrict cfg.agent;
    };

    # Read-only diagnostics account: no wheel, no sudo rule, no password, no
    # linger. systemd-journal gives journal read access. It has no global key
    # file entry, so it can never authenticate on port 22.
    users.users.diag = {
      isNormalUser = true;
      description = "Diagnostics (read-only, forced-command account)";
      extraGroups = [ "systemd-journal" ];
    };

    services.openssh = {
      settings = {
        LogLevel = "VERBOSE";
        KbdInteractiveAuthentication = false;
      };
      # Second listener. `ports` stays [ 22 ] (it also drives the firewall
      # opening), so 2222 is not opened publicly; it is reachable via
      # tailscale0, which the firewall trusts. Port 22 is untouched.
      # Match blocks must come last in sshd_config, hence mkAfter.
      extraConfig = lib.mkAfter ''
        Port ${toString listenerPort}

        # These two accounts: only the declarative, from=-restricted key file
        # (never a self-added ~/.ssh/authorized_keys), and never the public
        # port-22 listener.
        Match User alexandru,agent
          AuthorizedKeysFile /etc/ssh/authorized_keys.d/%u

        Match LocalPort 22
          DenyUsers alexandru agent diag

        # Must precede the generic 2222 block: the first match wins per keyword.
        Match User sancta LocalPort ${toString listenerPort}
          AuthorizedKeysFile ${sanctaKeyFile}
          AllowTcpForwarding remote
          AllowStreamLocalForwarding no
          GatewayPorts no
          PermitListen 127.0.0.1:*

        # Must also precede the generic block. Forced command comes from the key file.
        Match User diag LocalPort ${toString listenerPort}
          AuthorizedKeysFile ${diagKeyFile}
          AllowTcpForwarding no
          AllowStreamLocalForwarding no
          AllowAgentForwarding no
          PermitTTY no
          X11Forwarding no

        Match LocalPort ${toString listenerPort}
          AllowUsers alexandru agent sancta diag
          PermitRootLogin no
      '';
    };
  };
}
