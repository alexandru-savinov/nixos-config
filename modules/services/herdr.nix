{ config, pkgs, lib, ... }:

# herdr — terminal workspace manager for AI coding agents.
#
# Runs the herdr *server* on this host (always-on, supervised) so long-running
# agent sessions live on the VPS and survive the Mac going to sleep. Attach from
# the Mac with:  herdr --remote root@<this-host>
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
in
{
  options.customModules.herdr = {
    enable = lib.mkEnableOption "herdr terminal workspace server for AI coding agents";
  };

  config = lib.mkIf config.customModules.herdr.enable {
    # herdr CLI on PATH — required so `herdr --remote root@host` finds the binary
    # on the remote, and so you can run `herdr` locally on the box.
    environment.systemPackages = [ herdr ];

    # Always-on, supervised server. Runs as root with HOME=/root so it owns
    # /root/.config/herdr/herdr.sock — the same socket `herdr --remote root@host`
    # uses — so the remote client ATTACHES to this server instead of spawning a
    # rival. Restart=on-failure + WantedBy=multi-user.target give auto-restart on
    # crash and return-after-reboot. `herdr server` runs in the foreground, so
    # Type=simple lets systemd track it directly.
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
      environment.HOME = "/root";
      serviceConfig = {
        Type = "simple";
        User = "root";
        WorkingDirectory = "/root";
        ExecStart = "${lib.getExe herdr} server";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}
