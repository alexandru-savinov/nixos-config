# choir-store-gc — generation-count store GC for a small VPS (7 GB RAM, one disk).
#
# Replaces nix.gc.automatic (kept false): rather than "older than N days", keep
# the newest N system generations, delete the rest, then collect garbage.
#
# The booted generation (/run/booted-system) and the current one are never
# deleted, however old: see choir-store-gc.sh.
#
# Schedule: daily 02:30 (+ up to 20 min random delay), so it ends well before
# the soul jobs (03:50 mirror, 04:20 transcript archive) and the 05:15 vulnix
# run, and clear of the weekly nix-optimise slot (Sun 01:00, see choir config).
#
# DEAD-MAN GUARD: the unit has ConditionPathExists=!/run/deploy-deadman-armed.
# The deploy procedure creates that file while a rollback is armed. While it
# exists this unit is skipped, so the previous generation (the rollback
# target) is never deleted underneath an in-flight deploy. /run is a tmpfs, so
# a stale marker does not survive a reboot.
{ config, lib, pkgs, ... }:

let
  cfg = config.choirStoreGc;
  profile = "/nix/var/nix/profiles/system";

  scriptText = ''
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.gnugrep pkgs.gnused pkgs.nix ]}
    export KEEP=${toString cfg.keepGenerations}
    export PROFILE=${profile}
  '' + builtins.readFile ./choir-store-gc.sh;
  gcScript = pkgs.writeShellScript "choir-store-gc" scriptText;
in
{
  options.choirStoreGc.keepGenerations = lib.mkOption {
    type = lib.types.ints.positive;
    default = 10;
    description = "Number of newest system generations to keep (the booted and current generations are kept in addition).";
  };

  # Script source, exposed so tests can pin it without building the derivation.
  options.choirStoreGc.scriptText = lib.mkOption {
    type = lib.types.str;
    readOnly = true;
    internal = true;
    default = scriptText;
  };

  config = {
    systemd.services.choir-store-gc = {
      description = "Prune old system generations and collect garbage";
      unitConfig.ConditionPathExists = "!/run/deploy-deadman-armed";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = gcScript;
        Nice = 19;
        IOSchedulingClass = "idle";
        # 7 GB host: collecting a large store is mostly I/O, cap RAM so it
        # cannot push the sancta workers into OOM.
        MemoryMax = "1G";
      };
    };

    systemd.timers.choir-store-gc = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 02:30:00";
        RandomizedDelaySec = "20min";
        Persistent = true;
      };
    };
  };
}
