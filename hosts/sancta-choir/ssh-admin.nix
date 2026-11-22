# sancta-choir: named admin and agent accounts over OpenSSH on the tailnet.
#
# Adds two normal accounts and a second sshd listener (port 2222) that is
# reachable only through tailscale0. Nothing existing is changed or turned
# off: port 22 (public, used by the soul-mirror pull), Tailscale SSH and the
# root/herdr/sancta key files stay exactly as they were.
#
# Keys come from the options below (default: none, so nobody can log in until
# a key is added). Every key is rendered with a `from=` source restriction to
# the tailnet ranges; callers pass plain public keys only.
{ config, lib, ... }:

let
  cfg = config.sancta-choir.adminKeys;

  tailnetFrom = "100.64.0.0/10,fd7a:115c:a1e0::/48";
  restrict = key: "from=\"${tailnetFrom}\" ${key}";

  # A plain public key starts with its key type, never with options.
  keyTypePattern = "(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\\.com|sk-ecdsa-sha2-nistp256@openssh\\.com) .*";
  isPlainKey = key: builtins.match keyTypePattern key != null;

  listenerPort = 2222;
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
  };

  config = {
    assertions = [
      {
        assertion = lib.all isPlainKey (cfg.owner ++ cfg.agent);
        message = "sancta-choir.adminKeys: every key must be a plain public key (key type first, no options); the module prepends the from= restriction itself.";
      }
    ];

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
    # itself gated by the key + from= restriction above.
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

        Match LocalPort ${toString listenerPort}
          AllowUsers alexandru agent
          PermitRootLogin no
      '';
    };
  };
}
