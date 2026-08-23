# sancta-transcript-archive — the verbatim conversation gets a second copy.
#
# WHY THIS EXISTS
# ---------------
# /var/lib/sancta/.claude/projects/**/*.jsonl is the raw transcript of every
# session — 530 MB today, growing about half a gigabyte a month. It lives on
# exactly ONE LUKS volume on this host, and the weekly soul-mirror tar
# deliberately excludes it (see sancta-soul-mirror.nix's sourceRoots comment:
# "memory is the durable distillation"). One volume, one copy, no second leg.
# This unit is the clock for the producer that ends that: closed sessions
# become age-encrypted, content-named objects under the mirror's ALREADY
# PUBLISHED directory, so rpi5's existing pull carries them home with no new
# key, no new endpoint and no change to the pull mechanics.
#
# Design: docs/plans/2026-08-22-transcript-archive-design.md.
#
# THIS MODULE IS THE CLOCK, NOT THE BRAIN — same split as
# sancta-statusline-refresh and sancta-wq-tick, for the same reason. Every rule
# about what counts as a closed session, how objects are named, when the
# manifest snapshot is refreshed, lives in ONE place: index/bin/transcript-
# archive on the soul volume, in the INDEX repo. This module supplies the
# cadence, the sandbox, the PATH, the mount gate and the recipients. A rebuild
# of this repo cannot change what an archive run DOES, because this repo does
# not contain any of it.
#
# THE WORKS-BY-LUCK TRAP (inherited, named again): ExecStart points at a path
# on the soul volume, so tests/unit-script-refs.nix — which only realises and
# scans /nix/store references — is structurally blind to it. The three
# replacements this repo already settled on for that class all apply here:
# ConditionPathIsMountPoint (don't run at all without the volume), an
# ExecStartPre `test -x` on the real script, and a committed entry in
# tests/execstart-path-contracts.nix so the PATH contract is checked at eval
# time (plus the wq-tick runtime probe, which reads the script's real bytes).
#
# THE RECIPIENTS ARE PASSED AS A FILE, AND THAT IS NOT A STYLE CHOICE.
# A recipient can contain a SPACE: the mirror's second recipient is an
# `ssh-ed25519 AAAA…` public key. The producer's original contract was a
# space-separated environment variable, and with the real list that hands age
# the bare word `ssh-ed25519` as a recipient of its own — reproduced
# 2026-08-23, before this module was written: `age: error: malformed SSH
# recipient: "ssh-ed25519": ssh: no key found`. A recipients FILE (age -R, one
# per line) is the only shape that can represent the list we actually have.
# The file is a world-readable store path, which is correct rather than
# tolerated: it holds PUBLIC keys only, exactly as they already appear in this
# repo's source.
#
# WHAT THIS DOES NOT PROVE: that a run archives anything, or that the objects
# reach rpi5. Eval and dry-build prove evaluability, never activation. The
# producer's own fixture test proves the mechanism (51 assertions, throwaway
# keys, round-trip decrypt); the wq-tick `archive-check` guard is what watches
# the live one.

{ config, lib, pkgs, ... }:

let
  inherit (lib) mkIf mkOption mkEnableOption types concatStringsSep;
  cfg = config.services.sancta-transcript-archive;
  mirror = config.services.sancta-soul-mirror;
  soulRoot = toString config.services.sancta-soul-volume.mountPoint;

  archiveScript = "${soulRoot}/index/bin/transcript-archive";
  lockFile = "${cfg.stateDir}/transcript-archive.lock";

  # ONE source of recipients (design decision, revmux-574 MINOR): read straight
  # off the mirror's option rather than re-declaring a parallel list here. Two
  # lists in two modules drift the moment either is edited alone, and the drift
  # is invisible until a restore needs the key that only one of them had.
  recipients = mirror.recipients;

  recipientsFile = pkgs.writeText "sancta-transcript-archive-recipients" (
    concatStringsSep "\n" recipients + "\n"
  );
in
{
  options.services.sancta-transcript-archive = {
    enable = mkEnableOption "Archive closed session transcripts as age-encrypted objects under the published mirror dir";

    user = mkOption {
      type = types.str;
      default = "sancta";
      description = ''
        Account that owns the soul volume and the mirror's published directory.
        It must be the SAME user the mirror publishes as (services.sancta-soul-
        mirror.user), since the objects land inside that 0700 directory —
        running as anyone else fails at the first write rather than silently,
        which is the direction this whole module family prefers.
      '';
    };

    sourceDir = mkOption {
      type = types.str;
      default = "${soulRoot}/projects";
      description = "Transcript source tree. READ-ONLY to this unit — see the ReadWritePaths comment for why no explicit ReadOnlyPaths entry is used.";
    };

    publishedDir = mkOption {
      type = types.str;
      default = "${mirror.localDir}/soul-archive";
      description = ''
        Where the CIPHERTEXT objects (and the encrypted manifest snapshot) are
        written. Under the mirror's localDir on purpose: rpi5's forced command
        is `rrsync -ro <localDir>` and its puller asks for `remoteDir = "/"`,
        so a subdirectory rides the existing pull with zero changes on rpi5.
        Proven behaviourally, not assumed — see the design doc's transport
        section (recursion into subdirs is not disabled; a sibling directory,
        a `..` traversal and a write-back are all refused).

        The corollary is the sharp one: rpi5 pulls EVERYTHING under here, so
        nothing in clear may ever be written to this directory. That is what
        the stateDir/publishedDir assertion below enforces.
      '';
    };

    stateDir = mkOption {
      type = types.str;
      default = "/var/lib/sancta/transcript-archive";
      description = ''
        The choir-ONLY state: the canonical plaintext MANIFEST.jsonl, the
        last-run.json heartbeat, last-snapshot.json and the derived INDEX.md.
        Deliberately OUTSIDE publishedDir — those files carry project names,
        session ids, sizes and a timeline, and anything under the published
        directory leaves this host on the next pull.
      '';
    };

    closedAfterSec = mkOption {
      type = types.ints.positive;
      default = 172800;
      description = "A *.jsonl written to within this many seconds is LIVE and is never touched. 48h — the whole answer to \"the source changed mid-read\". COUPLED to the archive-check guard: the soul repo's wq-tick handler reads the same SANCTA_ARCHIVE_CLOSED_AFTER value (its missing-session alarm fires at this threshold + 24h of margin for one missed daily beat), so tuning this option moves the guard with it — but tests/module-eval.nix pins the exact env string, so change BOTH together.";
    };

    onCalendar = mkOption {
      type = types.str;
      default = "*-*-* 04:20:00";
      description = ''
        systemd OnCalendar. DAILY, not weekly: the archive's own guard alarms
        when the heartbeat is older than two days, so the cadence has to leave
        room for exactly one missed beat before the alarm means something. It
        sits after the weekly mirror's 03:50 slot so the two never contend for
        the same disk on a 2-core VPS.
      '';
    };

    randomizedDelaySec = mkOption {
      type = types.str;
      default = "20min";
      description = "systemd RandomizedDelaySec, so this does not start on the same second as the other soul timers.";
    };

    timeoutStartSec = mkOption {
      type = types.str;
      default = "4h";
      description = ''
        Upper bound for one run. Steady state is minutes (only sessions closed
        since the last beat are encrypted), but the FIRST run has 530 MB of
        backlog to sha256 and encrypt at Nice 15 with idle I/O priority. A
        timeout that kills the first run leaves an archive that never starts.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.sancta-soul-volume.enable or false;
        message = "services.sancta-transcript-archive requires services.sancta-soul-volume — the transcripts it reads and the script it runs both live on that mount.";
      }
      {
        # The published directory, its 0700 tmpfiles rule and the read-only
        # rrsync endpoint that carries these objects to rpi5 are ALL the
        # mirror's. Without it enabled, this unit would faithfully write
        # ciphertext into a directory nothing serves and nothing pulls — a
        # backup that exists only on the host it is backing up.
        assertion = mirror.enable;
        message = "services.sancta-transcript-archive requires services.sancta-soul-mirror — publishedDir lives under the mirror's localDir, and the mirror owns the rrsync endpoint rpi5 pulls from.";
      }
      {
        # ≥2, not "every entry looks like a key" (revmux-574 MINOR). The
        # mirror's own assertion is a prefix test, and `builtins.all` over an
        # EMPTY or single-entry list passes it — so reusing the list without
        # this check would let a one-recipient archive ship, which is one lost
        # key away from unreadable. The producer re-checks at runtime; this is
        # the half that fails at build time, where it costs nothing.
        assertion = builtins.length recipients >= 2;
        message = "services.sancta-transcript-archive: services.sancta-soul-mirror.recipients must have at least 2 entries (got ${toString (builtins.length recipients)}) — a single-recipient archive is one lost key from unreadable.";
      }
      {
        # The zero-knowledge invariant, made structural. rpi5's puller asks for
        # `remoteDir = "/"`, so EVERYTHING under the published directory leaves
        # this host. The canonical manifest, the heartbeat and INDEX.md are
        # plaintext metadata — project names, session ids, sizes, a timeline.
        # A config edit that moved stateDir under publishedDir would publish
        # all of it, silently and with every check still green.
        assertion = !(lib.hasPrefix "${mirror.localDir}/" "${cfg.stateDir}/");
        message = "services.sancta-transcript-archive.stateDir (${cfg.stateDir}) must NOT be under the published mirror dir (${mirror.localDir}) — rpi5 pulls everything published, and the manifest/INDEX/heartbeat are plaintext metadata.";
      }
      {
        # The other half of the same fact: objects written OUTSIDE the
        # published tree would never be pulled at all, and the archive would
        # look healthy on this host while no second copy existed anywhere.
        assertion = lib.hasPrefix "${mirror.localDir}/" "${cfg.publishedDir}/";
        message = "services.sancta-transcript-archive.publishedDir (${cfg.publishedDir}) must be under services.sancta-soul-mirror.localDir (${mirror.localDir}) — that directory is the ONLY thing rpi5's forced rrsync command can reach.";
      }
    ];

    # Both directories exist before the first beat, at 0700, owned by the
    # archiving user. Not cosmetic: under ProtectSystem=strict the parent
    # (mirror.localDir) is read-only to this unit, so a first run on a fresh
    # host could not create publishedDir itself.
    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0700 ${cfg.user} - -"
      "d ${cfg.publishedDir} 0700 ${cfg.user} - -"
    ];

    systemd.services.sancta-transcript-archive = {
      description = "Archive closed Sancta transcripts (age-encrypted, content-named, append-only)";

      # Loud on failure, unlike statusline-refresh and wq-tick. Those two run
      # every 15/30 minutes and talk to the network, where a transient 5xx
      # would page and a paging guard gets muted. This one runs daily, touches
      # no network at all, and its failure means the second copy silently
      # stopped being made — the exact class the mirror's alert path exists for.
      onFailure = [ "sancta-soul-mirror-alert@%N.service" ];

      # THE MOUNT GATE (revmux-574 MAJOR). Without it, a volume that failed to
      # unlock after a reboot leaves the bare underlay directory in place: the
      # scan finds no transcripts and — but for the producer's own empty-source
      # guard — would exit 0 "healthy", with the archive-check guard reading the
      # same emptiness and confirming the lie. `requires` alone is not enough:
      # a ConditionPathExists-skipped mount unit counts as satisfied for
      # Requires=, which is why every soul-reading unit in this repo carries the
      # mountpoint condition too.
      after = [ "sancta-soul-mount.service" ];
      requires = [ "sancta-soul-mount.service" ];
      unitConfig.ConditionPathIsMountPoint = soulRoot;

      # THE PATH CONTRACT — enumerated by reading bin/transcript-archive, not
      # by guessing, and committed in tests/execstart-path-contracts.nix where
      # eval checks it against this rendered PATH:
      #   bash      — the interpreter itself: the script's shebang is
      #               `#!/usr/bin/env bash`, so bash is resolved through THIS
      #               PATH (a store-path ExecStart would have hidden that; the
      #               statusline unit exited 127 on its first real run for
      #               exactly this reason, and the missing command was the
      #               interpreter, not a tool).
      #   age       — the encryption itself, `age -R <recipients> -o …`
      #   jq        — manifest rows, snapshot bookkeeping, INDEX.md, heartbeat
      #   coreutils — date, sha256sum, cut, sort, stat, mkdir, chmod, mv, rm,
      #               basename, and the ExecStartPre `test` below
      #   findutils — the `find … -print0` scan of the source tree
      path = with pkgs; [
        bash
        age
        jq
        coreutils
        findutils
      ];

      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;

        # The replacement for the store-ref check that cannot see this
        # ExecStart: fail loudly if the volume is mounted but the INDEX repo
        # has not deployed the script (or it lost its execute bit).
        ExecStartPre = "${pkgs.coreutils}/bin/test -x ${archiveScript}";

        # MUTUAL EXCLUSION, and exactly what it is worth. `--nonblock` so a
        # beat never queues behind a running one; `--conflict-exit-code 0`
        # because a beat skipped while a hand-run is in flight is the system
        # working, not a failure — and a unit that goes red whenever it is busy
        # trains its reader to ignore it. Real exit codes still pass through.
        # What it does NOT cover: a hand-run started OUTSIDE the unit takes no
        # lock, since the lock is declared here and not in the script (which
        # lives in the INDEX repo). The residual overlap is bounded rather than
        # unhandled: the producer names every object after its own ciphertext
        # hash and appends manifest rows with a single sub-PIPE_BUF `>>`, so
        # two concurrent runs can duplicate work but cannot corrupt or
        # overwrite anything.
        ExecStart = "${pkgs.util-linux}/bin/flock --nonblock --conflict-exit-code 0 ${lockFile} ${archiveScript}";

        Environment = [
          "SANCTA_ARCHIVE_SOURCE=${cfg.sourceDir}"
          "SANCTA_ARCHIVE_PUBLISHED=${cfg.publishedDir}"
          "SANCTA_ARCHIVE_STATE=${cfg.stateDir}"
          "SANCTA_ARCHIVE_CLOSED_AFTER=${toString cfg.closedAfterSec}"
          # The FILE form, not the space-separated one — see the module header.
          # A store path holding public keys only.
          "SANCTA_ARCHIVE_RECIPIENTS_FILE=${recipientsFile}"
        ];

        TimeoutStartSec = cfg.timeoutStartSec;
        Nice = 15;
        IOSchedulingClass = "idle";

        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = false;

        # THE WRITABLE SET — exactly the two archive directories, and nothing
        # else. The SOURCE TREE IS ABSENT FROM THIS LIST ON PURPOSE, and that
        # is what makes "never delete, move or rewrite a transcript" a property
        # of the sandbox rather than a promise in a script: with
        # ProtectSystem=strict the entire hierarchy is read-only except what is
        # named here, so /var/lib/sancta/.claude/projects is read-only by
        # construction. No redundant ReadOnlyPaths entry for it — this repo
        # already found (2026-08-22, rpi5 pull probe) that a ReadOnlyPaths line
        # under ProtectSystem=strict is eliminated as a no-op, so writing one
        # here would read as a guard while doing nothing. The falsifiable form
        # of the same claim lives in tests/module-eval.nix, which asserts the
        # source is under neither writable path.
        #
        # Directories, not files: the producer writes tmp siblings and renames
        # them, and rename(2) needs write on the containing directory (this
        # repo reproduced that live on 2026-08-20). `-` prefixed so a fresh
        # host — where tmpfiles has not run yet — fails inside the script with
        # an honest error instead of failing the bind-mount before it starts.
        ReadWritePaths = [
          "-${cfg.publishedDir}/"
          "-${cfg.stateDir}/"
        ];

        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        LockPersonality = true;

        # NO NETWORK, and this one can afford to say so. The producer reads
        # local files, encrypts to public keys and writes local files; rpi5
        # dials IN for the transport. AF_UNIX only — anything that tried to
        # send a transcript anywhere would fail at the socket.
        RestrictAddressFamilies = [ "AF_UNIX" ];
        SystemCallFilter = [ "@system-service" ];
      };
    };

    systemd.timers.sancta-transcript-archive = {
      description = "Daily archive of closed Sancta transcripts";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.onCalendar;
        # Persistent: a host that was down — or a beat missed for any reason —
        # otherwise waits a full day, and the guard's two-day heartbeat
        # threshold turns a single missed beat into an alarm. Catch up once,
        # immediately.
        Persistent = true;
        RandomizedDelaySec = cfg.randomizedDelaySec;
      };
    };
  };
}
