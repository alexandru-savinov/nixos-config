{ config, pkgs, ... }:
let
  allowedPorts = [ 3001 5678 8123 ];
  allowedServices = [ ];
  allowlistName = "rpi5-serve-allowlist";
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
    description = "Remove all handlers on the retired ports from the rpi5 Tailscale Serve node config";
    wantedBy = [ "multi-user.target" ];
    wants = [ "tailscaled.service" ];
    path = common.path ++ [ pkgs.curl ];
    serviceConfig = common.serviceConfig // {
      ExecStart = script "tidy";
      RemainAfterExit = true;
      TimeoutStartSec = "3min";
    };
  };

  systemd.services.rpi5-serve-allowlist = common // {
    description = "Check rpi5 Tailscale Serve against its allowlist";
    after = common.after ++ [ "rpi5-serve-tidy.service" ];
    onFailure = [ "vigil-failed@${allowlistName}.service" ];
    environment = common.environment // {
      ALLOWED_PORTS = builtins.toJSON allowedPorts;
      ALLOWED_SERVICES = builtins.toJSON allowedServices;
    };
    # A healthy allowlist check rearms its own alert.
    postStart = ''
      exec ${pkgs.util-linux}/bin/setpriv --reuid vigil --regid vigil --clear-groups -- \
        ${pkgs.coreutils}/bin/rm -f /var/lib/vigil/nota-sent/${allowlistName}
    '';
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
