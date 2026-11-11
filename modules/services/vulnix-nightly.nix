# Nightly vulnix scan of the running system: matches the closure of
# /run/current-system against the NVD and writes the result as JSON to
# /var/lib/vulnix/report.json. Observation only: nothing is patched,
# whitelisted or sent anywhere. Layer 2 of the SOC plan.
#
# Import it in a host's configuration.nix; there is no separate enable switch.
# The report is readable by the `vulnix` group and nobody else; a host adds
# the account that renders it to that group (choir: sancta).
#
# Findings stay on the host. The JSON goes to the report file only, never to
# stdout, so the journal carries vulnix's progress and errors but no CVE list.
# The only outbound traffic is the NVD feed download from vulnix's default
# mirror (GitHub release assets of fkie-cad/nvd-json-data-feeds).
#
# How vulnix 1.12.1 (the version at the pinned nixpkgs) reads the system:
# `--system` adds /nix/var/nix/gcroots/current-system, finds its deriver with
# `nix-store -qd` and walks it with `nix-store -qR`, then opens the .drv files
# straight from /nix/store. Both queries go to the nix daemon over its Unix
# socket, so the unit needs AF_UNIX and a nix client on PATH, and nothing
# else from the store but read access (which ProtectSystem=strict keeps).
#
# Exit codes (vulnix src/vulnix/output.py + main.py) are ambiguous on their
# own: 0 = no findings, 2 = findings, but 2 is also what vulnix returns on an
# internal RuntimeError and what click returns on a usage error, and an
# uncaught Python exception exits 1. So a run counts as a success only when
# the exit code AND the JSON agree: 0 with an empty array, 2 with a non-empty
# one. Anything else fails the unit and leaves the previous report in place.
{ config, pkgs, ... }:

let
  scan = pkgs.writeShellApplication {
    name = "vulnix-nightly";
    runtimeInputs = [
      pkgs.vulnix
      pkgs.jq
      pkgs.coreutils
      pkgs.findutils
      config.nix.package # same nix as the daemon; vulnix shells out to it
    ];
    text = ''
      state="$STATE_DIRECTORY"
      # The NVD database (ZODB; grows with the NVD) is the scanner's own.
      # vulnix bounds it itself: NVD.__exit__ calls db.pack() every 26th
      # successful run (Meta.should_pack, vulnix 1.12.1 nvd.py), dropping
      # old transactions, so nightly updates do not accumulate history.
      install -d -m 0700 "$state/cache"

      # Hard cap on top of that: if the cache is ever larger than
      # VULNIX_CACHE_CAP_MB (a missed pack, the Data.fs.old a pack leaves
      # behind, anything unforeseen), empty it and let this run rebuild it
      # from the feeds. It holds nothing that cannot be downloaded again.
      cap_mb="$VULNIX_CACHE_CAP_MB"
      used_mb=$(du -sm "$state/cache" | cut -f1)
      if [ "$used_mb" -gt "$cap_mb" ]; then
        echo "vulnix-nightly: cache is $used_mb MB, over the $cap_mb MB cap; emptying it for a cold rebuild" >&2
        find "$state/cache" -mindepth 1 -delete
      fi

      tmp=$(mktemp "$state/report.json.XXXXXX")
      trap 'rm -f "$tmp"' EXIT

      rc=0
      vulnix --system --json --cache-dir "$state/cache" >"$tmp" || rc=$?

      case "$rc" in
        0) shape='type == "array" and length == 0' ;;
        2) shape='type == "array" and length > 0' ;;
        *)
          echo "vulnix-nightly: vulnix exited $rc (error); previous report kept" >&2
          exit 1
          ;;
      esac
      if ! jq -e "$shape" "$tmp" >/dev/null 2>&1; then
        echo "vulnix-nightly: vulnix exited $rc without a matching JSON report (error); previous report kept" >&2
        exit 1
      fi

      chmod 0640 "$tmp"
      mv -f "$tmp" "$state/report.json"
      echo "vulnix-nightly: report written (vulnix exit $rc)"
    '';
  };
in
{
  users.users.vulnix = {
    isSystemUser = true;
    group = "vulnix";
    home = "/var/lib/vulnix";
  };
  users.groups.vulnix = { };

  systemd.services.vulnix = {
    description = "Nightly vulnix scan of the running system";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    environment = {
      HOME = "/var/lib/vulnix";
      # The store is read-only in this sandbox; talk to the daemon explicitly
      # instead of relying on nix's auto-detection.
      NIX_REMOTE = "daemon";
      # Upper bound for /var/lib/vulnix/cache in MB, enforced by the scan
      # script. A guess with room to spare, not a measured size (choir's
      # disk is 150 GB); going over it costs one cold rebuild, nothing else.
      VULNIX_CACHE_CAP_MB = "2048";
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${scan}/bin/vulnix-nightly";
      User = "vulnix";
      Group = "vulnix";

      # /var/lib/vulnix: 0750 so the vulnix group can traverse to the report
      # (0640); the cache subdirectory is created 0700 by the script.
      StateDirectory = "vulnix";
      StateDirectoryMode = "0750";
      UMask = "0027";

      # ── sandbox ──────────────────────────────────────────────────────
      NoNewPrivileges = true;
      CapabilityBoundingSet = "";
      AmbientCapabilities = "";
      ProtectSystem = "strict"; # /nix/store and /run/current-system stay readable
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectClock = true;
      ProtectHostname = true;
      ProtectProc = "invisible";
      RestrictNamespaces = true;
      RestrictSUIDSGID = true;
      RestrictRealtime = true;
      LockPersonality = true;
      RemoveIPC = true;
      # CPython without a JIT, no ctypes/cffi closures on this path, and the
      # nix client only queries the daemon.
      MemoryDenyWriteExecute = true;
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" ];
      # AF_UNIX: the nix daemon socket and nscd. AF_INET/AF_INET6: the feed.
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];

      # ── resources (choir is a small VPS; OOM matters) ────────────────
      # Measured on choir 2026-11-03 with the live feeds: Python's peak RSS is
      # ~4.2x the decompressed JSON (CVE-modified: 114 MB JSON -> 478 MB). A
      # cold cache loads six yearly feeds, the largest ~570 MB of JSON, so the
      # first run is estimated (not measured) near 3 GB; later nights read the
      # "modified" feed (~0.5 GB). MemoryHigh throttles before the hard cap;
      # MemoryMax kills this unit, not the host. OOMScoreAdjust makes it the
      # kernel's first choice under host-wide pressure.
      MemoryHigh = "3G";
      MemoryMax = "4G";
      MemorySwapMax = "2G";
      OOMScoreAdjust = 1000;
      CPUQuota = "50%";
      Nice = 19;
      IOSchedulingClass = "idle";
      # A cold cache downloads ~70 MB of feeds and parses them at half a core.
      TimeoutStartSec = "2h";
    };
  };

  # The SOC page reads `systemctl is-active vulnix.timer`; keep the name.
  systemd.timers.vulnix = {
    description = "Nightly vulnix scan of the running system";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # After the 03:50 soul mirror (Sundays) and the 04:20 transcript archive.
      OnCalendar = "*-*-* 05:15:00";
      RandomizedDelaySec = "30min";
      Persistent = true;
    };
  };
}
