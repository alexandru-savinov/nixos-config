# Stage-4 dead-man (STAGE-4 plan, Mythos ruling): installed, never scheduled.
# The operator arms it as a transient timer during the stage-4 window.
{ config, pkgs, ... }:

let
  choirSshRevert = pkgs.writeShellScriptBin "choir-ssh-revert" ''
    export TS=${config.services.tailscale.package}/bin/tailscale
    export SYSTEMCTL=${config.systemd.package}/bin/systemctl
    export JQ=${pkgs.jq}/bin/jq
    export LOGGER=${pkgs.util-linux}/bin/logger
    export SLEEP=${pkgs.coreutils}/bin/sleep
    export TIMEOUT=${pkgs.coreutils}/bin/timeout
    export TRIES=10
    exec ${pkgs.bash}/bin/bash ${./choir-ssh-revert.sh}
  '';
in
{
  environment.systemPackages = [ choirSshRevert ];
}
