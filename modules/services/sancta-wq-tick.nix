# sancta-wq-tick — give the work queue a heartbeat that does not need a human.
#
# WHY THIS EXISTS
# ---------------
# /var/lib/sancta/.claude/index/bin/wq-tick is the queue's beat: one tick claims
# up to three due tasks, runs the mechanical handler for each kind, and
# re-schedules the next occurrence. The maintenance the house depends on lives in
# those handlers — soul-mirror unit health, MEMORY.md parity, witness requests
# rotting past seven days, statusline freshness, ExecStart contract drift.
#
# Until now the only thing that ran it was a LIVE SESSION happening to call it.
# That is not a clock, it is a coincidence, and it failed exactly the way a
# coincidence fails: silently, on the nights nobody was at the keyboard. The
# statusline's own `stale` counter read 7 on both 2026-08-21 and 2026-08-22 —
# seven overdue tasks, twice, with nothing reporting that the beat itself had
# stopped. Nothing was broken in a way any check could see: the queue was
# healthy, the handlers were correct, and no one was calling them.
#
# THIS MODULE IS THE CLOCK, NOT THE BRAIN.
# Same split as sancta-statusline-refresh, and for the same reason: the tick
# LOGIC (which handlers exist, what each one probes, backoff, dead-letter) lives
# in exactly ONE place — the INDEX repo's bin/wq-tick on the soul volume. This
# module supplies only the cadence, the environment (PATH + HOME), the sandbox,
# and the mutual exclusion. A rebuild of this repo cannot change what a tick
# DOES, because this repo does not contain any of it.
#
# THE WORKS-BY-LUCK TRAP (inherited, named again on purpose):
# ExecStart points at a path on the soul volume, not at /nix/store, so
# tests/unit-script-refs.nix is structurally blind to it — it only scans store
# references. The replacements are the same three this repo already settled on
# for that class: ConditionPathIsMountPoint (don't run at all without the
# volume), an ExecStartPre `test -x` on the real script, and a committed entry
# in tests/execstart-path-contracts.nix so the PATH contract is checked at eval
# time. None of them prove the tick WORKS — see "WHAT THIS DOES NOT PROVE".
#
# NO OnFailure ALERT, DELIBERATELY — same argument as statusline-refresh: this
# runs every half hour and talks to the network (gh, curl, git fetch); a
# transient 5xx would page. The failure is self-reporting instead: a handler
# that fails backs off into the queue's dead-letter, and the dead-letter count
# is already rendered on the status bar. The signal arrives on the surface that
# is already being looked at.
#
# WHAT THIS DOES NOT PROVE: that any handler produces a CORRECT answer, or that
# the unit activates on the real host. Eval and dry-build prove evaluability,
# never activation (scar, 2026-08-07). The first real tick is the first proof.

{ config, lib, pkgs, ... }:

let
  inherit (lib) mkIf mkOption mkEnableOption types;
  cfg = config.services.sancta-wq-tick;
  soulRoot = toString config.services.sancta-soul-volume.mountPoint;
  indexRoot = "${soulRoot}/index";
  tickScript = "${indexRoot}/bin/wq-tick";

  # The queue itself: queue.db plus SQLite's WAL sidecars (-wal, -shm), the STOP
  # file the tick reads, and the lock below. WAL is why this must be the
  # DIRECTORY and not the .db file: a WAL writer creates and renames sibling
  # files, which needs write on the containing directory, not on the database.
  orchestratorDir = "${indexRoot}/orchestrator";

  # The statusline-refresh HANDLER (not the unit of the same name) writes here,
  # via mktemp-a-sibling-then-mv. rename(2) needs directory write — this repo
  # already reproduced that failure live on 2026-08-20 and moved the file into
  # its own directory for exactly this reason.
  statuslineDir = "${indexRoot}/statusline";

  lockFile = "${orchestratorDir}/wq-tick.lock";

  # The clone the `execstart-contract-check` handler reads the committed
  # manifest out of, via `git show origin/main:…` rather than the working tree
  # (the clone is routinely checked out to some other branch) — which means it
  # runs `git fetch` first, and that is why this path's .git has to be writable.
  #
  # A CONSTANT, NOT AN OPTION, and deliberately so (review finding, 2026-08-22).
  # The first version of this module made it configurable, which was a promise
  # it could not keep: the path is hard-coded on the OTHER side too, as
  # `const REPO = "/var/lib/sancta/repos/nixos-config"` inside bin/wq-tick's
  # execstart-contract-check handler, and nothing passes this value across.
  # Overriding the option would therefore have moved the writable grant to a
  # new clone while the handler kept fetching in the old one — whose .git is
  # then read-only under ProtectSystem=strict, so the drift probe fails or
  # quietly reads a stale ref. An option that silently means something other
  # than what it says is worse than a constant that says where its twin lives.
  # Making it genuinely configurable needs the handler to read the path from
  # the environment: an INDEX-repo change, named here, not done here. Until
  # then this literal and that `const REPO` must be edited together.
  contractRepo = "/var/lib/sancta/repos/nixos-config";
in
{
  options.services.sancta-wq-tick = {
    enable = mkEnableOption "Beat the Sancta work queue on a timer instead of only when a session happens to run it";

    user = mkOption {
      type = types.str;
      default = "sancta";
      description = ''
        Account that owns the soul volume, the queue database and the `gh`
        credentials the statusline handler needs. Running as anyone else does
        not fail loudly — it produces a tick that claims nothing and reports
        success, which is the failure mode this whole module exists to end.
      '';
    };

    onCalendar = mkOption {
      type = types.str;
      default = "*:0/30";
      description = ''
        systemd OnCalendar. Every thirty minutes: the queue's own maintenance
        periods are hours-to-days, so the beat only has to be fine-grained
        enough that a due task is picked up in the same hour it comes due. One
        tick claims at most three tasks (MAX in bin/wq-tick), so the cadence
        also sets the drain rate — a backlog of nine due tasks takes three
        beats, an hour and a half, to clear.
      '';
    };

    randomizedDelaySec = mkOption {
      type = types.str;
      default = "120s";
      description = "systemd RandomizedDelaySec, so the beat does not land on the same second as sancta-statusline-refresh (which it also drives through a handler).";
    };

    timeoutStartSec = mkOption {
      type = types.str;
      default = "5m";
      description = ''
        Upper bound for one tick. bin/wq-tick gives each handler a 60s
        execFileSync timeout and claims at most three per beat, so a healthy
        worst case is a little over three minutes; five leaves headroom without
        approaching the thirty-minute cadence. A run that outlived its own
        cadence would stack beats rather than replace them — which is what the
        lock below is for.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.sancta-soul-volume.enable or false;
        message = "services.sancta-wq-tick requires services.sancta-soul-volume — the queue database, the tick script and every handler it dispatches live on that mount.";
      }
      {
        # bin/wq-tick reaches the queue through orchestrator/queue.mjs, which
        # imports `node:sqlite`. On a nodejs without it the unit would
        # evaluate, build, activate, and then fail at the first import — every
        # half hour, on a host nobody is watching. A nixpkgs bump that moved
        # `pkgs.nodejs` backwards is not hypothetical enough to leave unasserted.
        #
        # THE FLOOR IS 22.13, NOT 22 AND NOT 22.5 (review finding, 2026-08-22 —
        # the first version of this assertion said "22", which would have passed
        # on a nodejs that still fails at runtime). Three facts, kept apart by
        # how well each is established:
        #   MEASURED here, on this host: `node -e 'require("node:sqlite")'` on
        #     22.22.0 loads with no flag (only an ExperimentalWarning).
        #   DOCUMENTED upstream: node:sqlite landed in 22.5.0 gated behind
        #     --experimental-sqlite, and the gate was lifted during the 22.13.x
        #     line.
        #   RELEVANT to us: queue.mjs passes NO flag and ExecStart adds none, so
        #     what this unit needs is the UNFLAGGED point, not the introduction
        #     point. A 22.5–22.12 nodejs satisfies "has node:sqlite" and still
        #     dies here, which is why the floor is not 22.5.
        # 22.13 is therefore the lowest version this module is willing to claim.
        # Only 22.22.0 has actually been run; if the gate in fact lifted later
        # than 22.13, this floor is too generous — erring one release-line
        # strict is the safe direction and is cheap, since nixpkgs is well past
        # it.
        assertion = lib.versionAtLeast pkgs.nodejs.version "22.13";
        message = "services.sancta-wq-tick needs nodejs >= 22.13 for unflagged node:sqlite (orchestrator/queue.mjs passes no --experimental-sqlite); pkgs.nodejs is ${pkgs.nodejs.version}.";
      }
    ];

    systemd.services.sancta-wq-tick = {
      description = "Beat the Sancta work queue (claim + run due maintenance tasks)";
      after = [
        "sancta-soul-mount.service"
        "network-online.target"
      ];
      requires = [ "sancta-soul-mount.service" ];
      wants = [ "network-online.target" ];
      unitConfig.ConditionPathIsMountPoint = soulRoot;

      # THE PATH CONTRACT. bin/wq-tick is a dispatcher: almost nothing it needs
      # is called by wq-tick itself, it is called by the handler scripts wq-tick
      # invokes by absolute path — and those children inherit exactly this PATH.
      # So the honest contract here is the TRANSITIVE one. Enumerated by reading
      # every handler in bin/wq-tick and every script it dispatches (2026-08-22):
      #
      #   nodejs   — wq-tick's own `#!/usr/bin/env node` interpreter, plus
      #              bin/memory-index (node) and the `node --input-type=module`
      #              node:sqlite read inside bin/statusline-refresh
      #   bash     — interpreter of bin/sancta-reconnect and bin/distil
      #   curl     — freshness handler (gallery + membrane liveness probes)
      #   systemd  — mirror-check (`systemctl show` / `is-active`) and the same
      #              three calls inside bin/statusline-refresh
      #   git      — execstart-contract-check (`git fetch` + `git show`)
      #   gh       — bin/statusline-refresh: pr list / pr view / api graphql
      #   jq       — bin/statusline-refresh: parses and merges the state JSON
      #   gnugrep  — bin/statusline-refresh's sidequest count, bin/distil's
      #              threshold scan of gallery/meridianele.mjs
      #   procps   — bin/sancta-reconnect: `pgrep -f` and `ps -o ppid=`
      #   coreutils— cat (witness-age) plus mktemp/chmod/mv/dirname/rm/date
      #              (statusline-refresh's atomic write), ls/sort/tail/basename/
      #              date (distil check), tr (sancta-reconnect), and the
      #              ExecStartPre `test` below
      #
      # `claude` and `sleep` are reached only on bin/sancta-reconnect's
      # re-exec path, which SANCTA_RECONNECT_KILLONLY=1 (set by the handler)
      # returns before — deliberately not provisioned, and `claude` is not a
      # nixpkgs package at all.
      path = with pkgs; [
        nodejs
        bash
        curl
        systemd
        git
        gh
        jq
        gnugrep
        procps
        coreutils
      ];

      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;

        # Same guard as statusline-refresh, for the same blind spot: ExecStart
        # is not a store path, so no static check can prove it resolves. Fail
        # loudly here rather than deep inside a half-run tick.
        ExecStartPre = "${pkgs.coreutils}/bin/test -x ${tickScript}";

        # MUTUAL EXCLUSION, and exactly what it is worth.
        # `-E 0` makes a lock conflict exit 0: a beat skipped because another
        # beat is still running is the system working, not a failure, and a
        # unit that goes red every time it is busy trains its reader to ignore
        # it. Real exit codes still pass through untouched.
        #
        # What this DOES cover: timer-beat vs timer-beat, if a tick ever
        # outlives its cadence. What it does NOT cover: a live session running
        # bin/wq-tick by hand — that process takes no lock, because the lock is
        # declared here and not inside the script (the script lives in the
        # INDEX repo, which this repo must not reach into). That residual
        # overlap is bounded rather than unhandled: queue.mjs claims every task
        # inside BEGIN IMMEDIATE against a UNIQUE index on active rows, so two
        # concurrent beats can never claim the SAME task — the worst case is
        # two different tasks running at once, which is what a queue is for.
        # Closing it properly means teaching bin/wq-tick to take this same
        # lock; that is an INDEX-repo change, named here, not done here.
        ExecStart = "${pkgs.util-linux}/bin/flock --nonblock --conflict-exit-code 0 ${lockFile} ${tickScript}";

        # bin/wq-tick exits 3 when it finds orchestrator/STOP — a deliberate
        # halt written by a human or by the guard, not an error. Without this
        # the STOP file would paint the unit failed every half hour and the
        # status bar would report a broken clock while the clock was obeying
        # an instruction.
        SuccessExitStatus = "3";

        Environment = [
          # queue.mjs derives DEFAULT_DB from $HOME (.claude/index/orchestrator/
          # queue.db). systemd gives a service no HOME by default, and the
          # fallback inside queue.mjs is "/var/lib/sancta" — right by luck on
          # this host, which is not a thing to depend on. State it.
          "HOME=${builtins.dirOf soulRoot}"
        ];

        TimeoutStartSec = cfg.timeoutStartSec;
        Nice = 15;
        IOSchedulingClass = "idle";

        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = false;

        # THE WRITABLE SET — derived by reading every handler, not by guessing,
        # and deliberately NOT "all of index/".
        #
        #   orchestrator/  — the queue itself. Every claim/done/fail/add is a
        #                    write, and WAL means -wal/-shm siblings plus the
        #                    flock file, so the grant has to be the directory.
        #   statusline/    — the statusline-refresh HANDLER's atomic write
        #                    (mktemp sibling + rename). Directory, for the same
        #                    rename(2) reason this repo already hit on
        #                    2026-08-20.
        #   <contractRepo>/.git — `git fetch origin main` in the contract-drift
        #                    handler. Without it the fetch fails, `git show
        #                    origin/main:…` silently reads whatever was fetched
        #                    last, and the drift probe validates the live script
        #                    against a frozen snapshot — a check that cannot
        #                    fail, which is worse than no check. Scoped to .git:
        #                    the handler never touches the working tree, and
        #                    granting the repo root would let it.
        #
        # Everything else the handlers touch is READ-ONLY, verified by reading
        # each one: memory-index runs `--check` (compares, never writes; only
        # `--sync` writes), witness-age `cat`s requests.jsonl, distil runs
        # `check` (the writing `seal` path is never dispatched), sancta-reconnect
        # under KILLONLY only signals processes, and the sidequest log is read
        # by statusline-refresh, never written. If a future handler starts
        # appending anywhere else under index/, this list must grow with it —
        # a widened grant is a decision, not a shrug.
        #
        # `-` prefix on each: with ProtectSystem=strict systemd bind-mounts
        # every entry into the unit's namespace and a missing path fails the
        # START, before the script can produce its own honest error. On a fresh
        # host statusline/ plausibly does not exist yet.
        ReadWritePaths = [
          "-${orchestratorDir}/"
          "-${statuslineDir}/"
          "-${contractRepo}/.git/"
        ];

        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        LockPersonality = true;

        # Network is REQUIRED and deliberately un-narrowed. Three handlers need
        # it: freshness curls the gallery over the tailnet (100.64.0.0/10) and
        # the membrane on loopback, statusline-refresh talks to GitHub through
        # gh, and execstart-contract-check fetches over https. An IPAddressAllow
        # list covering GitHub's ranges would go stale and start failing beats
        # at 3am — a boundary in name only, which this repo has already refused
        # once for the same reason (sancta-statusline-refresh).
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        SystemCallFilter = [ "@system-service" ];
      };
    };

    systemd.timers.sancta-wq-tick = {
      description = "Keep the Sancta work queue beating without a live session";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.onCalendar;
        # Persistent is the whole point of the incident this fixes. Without it a
        # host that was down — or a beat that was simply missed — resumes at the
        # next half hour with the overdue tasks still overdue and nothing saying
        # so. With it, systemd catches the missed beat up once, immediately, and
        # the queue drains instead of accumulating the way it did on the nights
        # of 2026-08-21 and 2026-08-22.
        Persistent = true;
        RandomizedDelaySec = cfg.randomizedDelaySec;
      };
    };
  };
}
