{ config, pkgs, lib, ... }:

# herdr — terminal workspace manager for AI coding agents.
#
# Runs the herdr *server* on this host (always-on, supervised) so long-running
# agent sessions live on the VPS and survive the Mac going to sleep. The server
# runs as a dedicated unprivileged `herdr` user (not root); attach from the Mac
# with:  herdr --remote herdr@<this-host>
#
# Packaging: the upstream prebuilt release binary is statically linked
# (verified `file`: "static-pie linked", no INTERP segment, no NEEDED libs), so
# it runs directly on NixOS with no autoPatchelfHook. Pinned to v0.6.10 to match
# the Mac's Homebrew herdr (client/server version parity for `herdr --remote`).

let
  herdr = pkgs.stdenvNoCC.mkDerivation rec {
    pname = "herdr";
    version = "0.6.10";

    src = pkgs.fetchurl {
      url = "https://github.com/ogulcancelik/herdr/releases/download/v${version}/herdr-linux-x86_64";
      hash = "sha256-eNKY1aHvB2tGB+jjyS2Y9d6fDLMNrzGqkQoabpq7T6E=";
    };

    dontUnpack = true;

    installPhase = ''
      runHook preInstall
      install -Dm755 $src $out/bin/herdr
      runHook postInstall
    '';

    meta = {
      description = "Terminal workspace manager for AI coding agents (prebuilt static release binary)";
      homepage = "https://github.com/ogulcancelik/herdr";
      license = lib.licenses.agpl3Only;
      mainProgram = "herdr";
      platforms = [ "x86_64-linux" ];
      sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    };
  };

  # Fixed-flake deploy wrapper — the ONLY nixos-rebuild path the herdr user can
  # sudo. Pins the flake to the canonical (CI-checked, merged) config and takes
  # NO user arguments, so an agent in a pane cannot run
  # `sudo nixos-rebuild --flake github:attacker/...` to root the box; risky
  # changes must go through PR -> CI -> merge before they can be deployed here.
  herdr-deploy = pkgs.writeShellScriptBin "herdr-deploy" ''
    set -euo pipefail
    exec /run/current-system/sw/bin/nixos-rebuild switch \
      --flake github:alexandru-savinov/nixos-config#sancta-choir
  '';
in
{
  options.customModules.herdr = {
    enable = lib.mkEnableOption "herdr terminal workspace server for AI coding agents";

    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = config.users.users.root.openssh.authorizedKeys.keys;
      defaultText = lib.literalExpression "config.users.users.root.openssh.authorizedKeys.keys";
      description = ''
        SSH public keys allowed to attach as the herdr user
        (`herdr --remote herdr@host`). Defaults to root's authorized keys, so
        whoever already manages this VPS can attach.
      '';
    };
  };

  config = lib.mkIf config.customModules.herdr.enable {
    # herdr CLI on PATH — required so `herdr --remote herdr@host` finds the binary
    # on the remote, and so you can run `herdr` locally on the box. herdr-deploy
    # is the sudo-allowed fixed-flake deploy wrapper (see the sudo rule below).
    environment.systemPackages = [
      herdr
      herdr-deploy
    ];

    # Dedicated unprivileged user the server runs as and that you SSH in as to
    # attach (`herdr --remote herdr@host`). Mirrors the openclaw/nullclaw pattern:
    # keeping the long-lived, opaque prebuilt binary off root shrinks the blast
    # radius of a compromise. The attach socket lives under this user's HOME at
    # /var/lib/herdr/.config/herdr/herdr.sock.
    users.users.herdr = {
      isSystemUser = true;
      group = "herdr";
      # Read journal logs without sudo (replaces the old `sudo journalctl` rule).
      extraGroups = [ "systemd-journal" ];
      home = "/var/lib/herdr";
      createHome = true;
      shell = pkgs.bash;
      openssh.authorizedKeys.keys = config.customModules.herdr.authorizedKeys;
    };
    users.groups.herdr = { };

    # Scoped, auditable escalation. Agent panes run as the unprivileged herdr
    # user and get passwordless sudo for ONLY two things:
    #   - herdr-deploy: the fixed-flake wrapper above (no user args), so deploys
    #     are constrained to the canonical CI-checked config — NOT raw
    #     `nixos-rebuild`, which would accept `--flake github:attacker/...` and
    #     hand a pane full root.
    #   - nixos-collect-garbage: prunes old generations; not a code-exec vector.
    # Log access is via the systemd-journal group (no sudo). Broad `systemctl` is
    # intentionally NOT granted — `sudo systemctl stop sshd` / `start
    # emergency.target` would be a trivial lockout/escalation; a redeploy via
    # herdr-deploy restarts changed units.
    security.sudo.extraRules = [
      {
        users = [ "herdr" ];
        commands = [
          {
            command = "/run/current-system/sw/bin/herdr-deploy";
            options = [ "NOPASSWD" ];
          }
          {
            command = "/run/current-system/sw/bin/nixos-collect-garbage";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];

    # Always-on, supervised server running as the unprivileged herdr user with
    # HOME=/var/lib/herdr so it owns /var/lib/herdr/.config/herdr/herdr.sock — the
    # socket `herdr --remote herdr@host` attaches to, so the remote client ATTACHES
    # to this server instead of spawning a rival. Restart=on-failure +
    # WantedBy=multi-user.target give auto-restart on crash and return-after-reboot.
    # `herdr server` runs in the foreground, so Type=simple lets systemd track it.
    systemd.services.herdr-server = {
      description = "herdr terminal workspace server (AI coding agents)";
      wantedBy = [ "multi-user.target" ];
      # herdr shells out to curl at startup to refresh its agent-state detection
      # manifest (idle/working/blocked) and to check for updates, so order after
      # real connectivity — network.target only means networking *started*, not
      # that an interface has a routable IP / DNS. Match every other networked
      # service in this repo (qdrant, n8n, openclaw, gatus, ...) that waits on
      # network-online.target; otherwise those boot-time fetches race the network.
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      # curl must be on the unit's PATH or the manifest refresh / update check
      # fail at startup; agent detection is herdr's headline feature on this host.
      path = [ pkgs.curl ];
      environment.HOME = "/var/lib/herdr";
      serviceConfig = {
        Type = "simple";
        User = "herdr";
        Group = "herdr";
        WorkingDirectory = "/var/lib/herdr";
        ExecStart = "${lib.getExe herdr} server";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}
