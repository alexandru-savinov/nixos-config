{ config, lib, pkgs, ... }:
# Shared-memory commons — single-owner ingest service + librarian.
# Writers (any agent) POST /write over Tailscale, or drop a file into the inbox
# on the same host. The librarian is the sole DB writer. Auth is a no-op-allow
# seam today (Tailscale node identity stamped; deny-by-default slots in later).
let
  cfg = config.services.sharedMemory;
  src = ./.; # server.js + librarian.js live beside this module
in
{
  options.services.sharedMemory = {
    enable = lib.mkEnableOption "shared-memory commons (ingest + librarian)";
    bindIp = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "IP the ingest HTTP service binds. Set to the host's Tailscale IP for mesh access.";
    };
    port = lib.mkOption { type = lib.types.port; default = 8730; };
    stateDir = lib.mkOption { type = lib.types.str; default = "/var/lib/shared-memory"; };
    user = lib.mkOption { type = lib.types.str; default = "shared-memory"; };
    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open the ingest port on the Tailscale interface ONLY (never the public one).";
    };
    tailscaleInterface = lib.mkOption { type = lib.types.str; default = "tailscale0"; };
    librarianInterval = lib.mkOption { type = lib.types.str; default = "60s"; };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user} = { isSystemUser = true; group = cfg.user; };
    users.groups.${cfg.user} = { };

    systemd.services.shared-memory = {
      description = "Shared-memory commons — HTTP ingest (single owner)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "tailscaled.service" ];
      wants = [ "network-online.target" ];
      environment = { SM_BIND_IP = cfg.bindIp; SM_PORT = toString cfg.port; SM_STATE = cfg.stateDir; };
      path = [ pkgs.sqlite pkgs.tailscale ];
      serviceConfig = {
        ExecStart = "${pkgs.nodejs}/bin/node ${src}/server.js";
        User = cfg.user;
        Group = cfg.user;
        StateDirectory = baseNameOf cfg.stateDir;
        Restart = "on-failure";
        RestartSec = 3;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        ReadWritePaths = [ cfg.stateDir ];
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
      };
    };

    systemd.services.shared-memory-librarian = {
      description = "Shared-memory commons — librarian (inbox -> SQLite, sole writer)";
      environment = { SM_STATE = cfg.stateDir; };
      path = [ pkgs.sqlite ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.nodejs}/bin/node ${src}/librarian.js";
        User = cfg.user;
        Group = cfg.user;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ReadWritePaths = [ cfg.stateDir ];
      };
    };
    systemd.timers.shared-memory-librarian = {
      description = "Run the shared-memory librarian periodically";
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "30s"; OnUnitActiveSec = cfg.librarianInterval; AccuracySec = "5s"; };
    };
    # inotify nudge: ingest promptly when the inbox changes
    systemd.paths.shared-memory-librarian = {
      description = "Nudge the librarian when the inbox changes";
      wantedBy = [ "multi-user.target" ];
      pathConfig = { PathChanged = "${cfg.stateDir}/inbox"; Unit = "shared-memory-librarian.service"; };
    };

    networking.firewall.interfaces.${cfg.tailscaleInterface} =
      lib.mkIf cfg.openFirewall { allowedTCPPorts = [ cfg.port ]; };
  };
}
