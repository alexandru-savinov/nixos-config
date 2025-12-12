{ config, pkgs, lib, ... }:

let
  cfg = config.services.open-webui;

in
{
  options.services.open-webui = with lib; {
    enable = mkEnableOption "open-webui";

    stateDir = mkOption {
      type = types.str;
      default = "/var/lib/open-webui";
      description = "State directory for open-webui";
    };

    # ... existing options ...
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      # Ensure SQLite DB directory exists for DATABASE_URL (e.g. ${cfg.stateDir}/data/open-webui.db)
      "d ${cfg.stateDir}/data 0750 open-webui open-webui - -"
    ];

    # ... existing config ...
  };
}
