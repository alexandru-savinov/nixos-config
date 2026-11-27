{ config, pkgs, ... }:
let
  allowedPorts = [ 3001 5678 8123 ];
  allowedServices = [ ];
  script = mode: "${pkgs.bash}/bin/bash ${./rpi5-serve.sh} ${mode}";
  common = {
    after = [ "tailscaled.service" ];
    environment.TS = "${config.services.tailscale.package}/bin/tailscale";
    path = [ pkgs.coreutils pkgs.jq ];
    serviceConfig.Type = "oneshot";
  };
in
{
  systemd.services.rpi5-serve-tidy = common // {
    description = "Remove retired rpi5 Tailscale Serve node handlers";
    wantedBy = [ "multi-user.target" ];
    wants = [ "tailscaled.service" ];
    serviceConfig = common.serviceConfig // {
      ExecStart = script "tidy";
      RemainAfterExit = true;
      TimeoutStartSec = "3min";
    };
  };

  systemd.services.rpi5-serve-allowlist = common // {
    description = "Check rpi5 Tailscale Serve against its allowlist";
    after = common.after ++ [ "rpi5-serve-tidy.service" ];
    onFailure = [ "vigil-failed.service" ];
    environment = common.environment // {
      ALLOWED_PORTS = builtins.toJSON allowedPorts;
      ALLOWED_SERVICES = builtins.toJSON allowedServices;
    };
    serviceConfig = common.serviceConfig // {
      ExecStart = script "allowlist";
      TimeoutStartSec = "30s";
    };
  };

  systemd.timers.rpi5-serve-allowlist = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "15min";
    };
  };
}
