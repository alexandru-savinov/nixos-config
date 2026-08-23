# Committed, human-maintained contract for systemd units whose ExecStart-family
# points at a path OUTSIDE /nix/store — read alongside tests/execstart-path-
# contract.nix, which explains WHY this has to be a committed manifest rather
# than something derived from the script's real bytes at build time (short
# version: the script lives on a LUKS volume that is not present in a Nix
# build sandbox, and CI never passes --impure — see that file's header for the
# full, tested chain of reasoning, recon 2026-08-20).
#
# Each entry under `hosts.<host>.<scope>.<unit>` (scope = "system" or "user",
# unit name WITHOUT the ".service" suffix) says: which interpreter the
# shebang names (or `null` if the unit's ExecStart already invokes the
# interpreter via a full /nix/store path, so there is no $PATH lookup for the
# interpreter itself — e.g. sancta-gallery's `${pkgs.nodejs}/bin/node
# <script>`), and which EXTERNAL commands (bare names resolved via $PATH —
# NOT absolute paths, NOT shell builtins) the script invokes. Filled in BY
# HAND by reading the real script. It can go stale the moment someone edits
# the script without updating this file — nix eval has no way to notice that
# on its own. The runtime probe (wq-tick's execstart-contract-check handler,
# INDEX repo, committed separately) exists specifically to close that gap: it
# re-derives the same facts from the live script on sancta-choir, on a
# schedule, and reports drift.
#
# RECON 2026-08-21 (adversarial review of PR #568, all-verb / all-scope
# widen): tests/execstart-path-contract.nix now reads the unit's actual
# RENDERED text (`config.systemd.units."<n>.service".text` /
# `config.systemd.user.units."<n>.service".text`) across all 7 Exec verbs
# (ExecStartPre/Start/StartPost/Stop/StopPost/Reload/Condition) and both
# system + user scope, on all 3 hosts — see that file's header for exactly
# what "in scope" means now (any Exec* line whose PROGRAM token is non-store,
# OR whose later token is an absolute non-store path — the latter closes the
# "store-path wrapper" escape a narrower first version had). That recon is
# what produced the entries and vendor exceptions below; it superset the
# 2026-08-20 recon this file originally shipped with (that one only checked
# ExecStart/Pre/Post/Stop and only the first token — see PR #568 review).
#
# If a future PR adds a new custom unit with a non-/nix/store Exec* reference
# and does not add an entry here, tests/execstart-path-contract.nix fails the
# build with UNDECLARED. If a declared unit's Exec* references stop being
# non-store entirely (e.g. refactored to a pure store-path wrapper with no
# off-store argument), the SAME check fails with ORPHANED-CONTRACT — a
# manifest entry that stops covering anything is a hard stop too, not a
# silent gap.

{
  hosts = {
    # sancta-statusline-refresh — modules/services/sancta-statusline-refresh.nix.
    # Contract read off /var/lib/sancta/.claude/index/bin/statusline-refresh in
    # full (208 lines) on sancta-choir, 2026-08-20. Every BARE external command
    # it invokes, in order of first appearance in the script:
    #   mktemp   — state-dir sibling temp file (atomic-rename setup)
    #   gh       — pr list / pr view / api graphql (his open-PR "asks")
    #   jq       — four call sites (parsing gh output, building/merging state)
    #   systemctl — is-failed / is-active / show (unit status for the bar)
    #   node     — --input-type=module, node:sqlite read of orchestrator/queue.db
    #   grep     — `grep -c '^sq'` over `sidequest list` output
    #   date     — `-u +%Y-%m-%dT%H:%M:%SZ` for the `updated` timestamp
    #   chmod    — 644 on the temp file before the atomic rename
    #   mv       — `-f`, the atomic same-filesystem rename itself
    #   dirname  — computes the temp file's sibling directory for mktemp
    #   rm       — the `trap 'rm -f "$TMP"' EXIT` cleanup
    # `cd`/`pwd`/`read`/`trap`/`[`/`[[` are bash builtins — deliberately NOT
    # listed, a missing builtin is not a $PATH failure and this contract does
    # not reason about them. `$sqbin` (index/bin/sidequest) is invoked by
    # absolute path ($HERE-derived), never looked up on $PATH — it is not a
    # contract command here, and this file does not recurse into ITS
    # dependencies (see tests/execstart-path-contract.nix, "what this does not
    # cover", for why that recursion is out of scope).
    #
    # NOTE on falsifiability (adversarial review, 2026-08-21): mktemp, chmod,
    # mv, dirname, rm, date (coreutils) and grep (gnugrep) and systemctl
    # (systemd) are provided by NixOS's OWN unconditional
    # `systemd.services.<n>.path` defaults — they are appended to $PATH for
    # EVERY service regardless of what this module's own `path =` lists, so
    # in NORMAL operation these 7 commands can never be individually
    # falsified by a module edit. That is a true platform fact, not a checker
    # gap — the checker states it out loud in its report line rather than
    # pretending all declared commands are equally load-bearing. What CAN
    # falsify all of them at once is `environment.PATH` being overridden or
    # unset entirely (the #564 class one level up), which the checker reads
    # from the unit's REAL rendered text and so does catch (self-test
    # "REGRESSION: environment.PATH override must be flagged").
    sancta-choir = {
      system = {
        sancta-statusline-refresh = {
          interpreter = "bash";
          commands = [
            "mktemp"
            "gh"
            "jq"
            "systemctl"
            "node"
            "grep"
            "date"
            "chmod"
            "mv"
            "dirname"
            "rm"
          ];
        };

        # sancta-gallery — modules/services/sancta-gallery.nix. ExecStart is
        # `${pkgs.nodejs}/bin/node ${cfg.galleryDir}/server.mjs` — the
        # INTERPRETER (node) is already a full /nix/store path (no $PATH
        # lookup needed for it, hence `interpreter = null`), but the script
        # argument itself is off-store (soul volume), so the unit is in scope
        # by this checker's "later non-store absolute token" rule. Read
        # /var/lib/sancta/.claude/index/gallery/server.mjs in full (56 lines,
        # 2026-08-21): no `child_process`/`exec`/`spawn` call anywhere — a
        # pure Node http static-file server with a publish-gate check. It
        # shells out to NOTHING, so `commands = []` is a real fact, not an
        # oversight. If that script ever grows a subprocess call, this entry
        # must grow with it — the runtime probe cannot see this one either
        # (it only reads statusline-refresh today; extending it is future
        # work, named in the PR body's limits section).
        sancta-gallery = {
          interpreter = null;
          commands = [ ];
        };

        # sancta-wq-tick — modules/services/sancta-wq-tick.nix. ExecStart is
        # `${pkgs.util-linux}/bin/flock … <lockfile> <script>`: the PROGRAM
        # token is a store path, but both later tokens are off-store absolute
        # paths, so the unit is in scope by the "later non-store absolute
        # token" rule. The interpreter is NOT null here, unlike sancta-gallery:
        # the script is invoked directly, so its `#!/usr/bin/env node` shebang
        # makes `env` resolve `node` through this unit's $PATH — the same
        # lookup sancta-statusline-refresh's `bash` interpreter goes through.
        #
        # THIS ENTRY IS TRANSITIVE, AND THAT IS A DELIBERATE DEPARTURE from the
        # "does not recurse into a child script's dependencies" rule stated on
        # sancta-statusline-refresh above. The rule is right there and wrong
        # here, for a structural reason: bin/wq-tick is a DISPATCHER. Its own
        # body resolves only five commands through $PATH (curl, systemctl, git,
        # cat, plus `node` as interpreter); everything else it does, it does by
        # invoking bin/sancta-reconnect, bin/memory-index, bin/statusline-refresh
        # and bin/distil by absolute path — as CHILD PROCESSES OF THIS UNIT,
        # inheriting exactly this unit's PATH. A non-recursive contract here
        # would declare five commands and cover almost nothing that actually
        # runs, and would pass green while a PATH edit broke the queue at 3am.
        # (The recursion is one level deep and terminates: the only script
        # those children invoke by absolute path in turn is bin/sidequest, read
        # in full 2026-08-22 — pure node `fs`, shells out to nothing.)
        #
        # Read on sancta-choir 2026-08-22: bin/wq-tick (246 lines) and every
        # handler it dispatches. Which command comes from where:
        #   curl      — wq-tick `freshness` (gallery + membrane liveness)
        #   systemctl — wq-tick `mirror-check`; also 4 call sites in
        #               bin/statusline-refresh (is-failed / is-active / show)
        #   git       — wq-tick `execstart-contract-check` (fetch + show)
        #   cat       — wq-tick `witness-age` (reads witness/requests.jsonl)
        #   node      — ALSO a command, not only the interpreter:
        #               bin/memory-index has its own `#!/usr/bin/env node`
        #               shebang, and bin/statusline-refresh runs `node
        #               --input-type=module` for its node:sqlite queue read
        #   bash      — interpreter of bin/sancta-reconnect and bin/distil,
        #               both `#!/usr/bin/env bash`, both $PATH-resolved
        #   pgrep, ps — bin/sancta-reconnect (`pgrep -f "claude --resume …"`,
        #               `ps -o ppid=` for the ancestry safe-set)
        #   tr        — bin/sancta-reconnect (trims the ppid output)
        #   mktemp, chmod, mv, dirname, rm, date, jq, gh, grep
        #             — bin/statusline-refresh's atomic write + gh/jq pipeline
        #               (identical to its own entry above, because wq-tick runs
        #               that exact script through its `statusline-refresh`
        #               handler)
        #   ls, sort, tail, basename — bin/distil `check` (last sealed version,
        #               age, threshold scan). Its `seal` path also uses
        #               sha256sum/cut/cp/git/wc — NOT declared, because wq-tick
        #               only ever dispatches `distil check`; if a handler ever
        #               dispatches `seal`, this entry must grow.
        #
        # NOT declared, on purpose: `claude` and `sleep`, reached only on
        # bin/sancta-reconnect's re-exec path, which the handler's
        # SANCTA_RECONNECT_KILLONLY=1 returns before — and `claude` is not a
        # nixpkgs package at all, so declaring it could never be satisfied.
        # `kill`, `mapfile`, `echo`, `cd`, `[`, `trap` are bash builtins, same
        # exclusion as above. `flock` and `test` are invoked by full store path
        # from the unit itself, so neither is a $PATH lookup.
        # sancta-transcript-archive — modules/services/sancta-transcript-archive.nix.
        # ExecStart is `${pkgs.util-linux}/bin/flock … <lockfile> <script>`:
        # store-path PROGRAM token, two off-store absolute tokens after it, so
        # in scope by the "later non-store absolute token" rule — same shape as
        # sancta-wq-tick. The interpreter is NOT null: the script is invoked
        # directly and its `#!/usr/bin/env bash` shebang makes `env` resolve
        # `bash` through this unit's $PATH.
        #
        # NOT transitive, and that is a fact about the script rather than a
        # narrower rule: bin/transcript-archive is a leaf. It invokes no other
        # script by absolute path (read in full, 230 lines, 2026-08-23) — unlike
        # bin/wq-tick above, which is a dispatcher and therefore had to declare
        # its children's commands too.
        #
        # Every BARE external command it invokes, in order of first appearance:
        #   date       — now_iso, `date -u +%s`, and the `date -u -d @<mtime>`
        #                that derives the object's YYYY/MM time key
        #   sha256sum  — plaintext hash (idempotence), ciphertext hash (the
        #                object's NAME), manifest hash (snapshot bookkeeping)
        #   cut        — takes the hash off sha256sum's output
        #   find       — `find "$SRC" -type f -name '*.jsonl' -print0` scan
        #   sort       — `sort -z`, stable NUL-delimited scan order
        #   stat       — `-c %Y` (mtime, the closed-session rule) and `-c %s`
        #   mkdir      — state/published dirs and each YYYY/MM subdir
        #   chmod      — 700 on the dirs, 600 on every object and the manifest
        #   age        — the encryption itself (`-R <recipients file>`)
        #   mv         — the tmp+rename that lands every object atomically
        #   rm         — removes a tmp object when age produced empty bytes
        #   basename   — derives the `session` field for the manifest row
        #   jq         — reads archived hashes out of the manifest, writes every
        #                row, the heartbeat, the snapshot bookkeeping and INDEX.md
        # `read`, `mapfile`, `echo`, `printf`, `[`, `case` are bash builtins —
        # deliberately not listed (the recipients-file line counter is written
        # in pure bash for exactly this reason: it adds no PATH dependency).
        # `flock` and `test` come from the unit itself by full store path, so
        # neither is a $PATH lookup.
        sancta-transcript-archive = {
          interpreter = "bash";
          commands = [
            "date"
            "sha256sum"
            "cut"
            "find"
            "sort"
            "stat"
            "mkdir"
            "chmod"
            "age"
            "mv"
            "rm"
            "basename"
            "jq"
          ];
        };

        sancta-wq-tick = {
          interpreter = "node";
          commands = [
            "node"
            "bash"
            "curl"
            "systemctl"
            "git"
            "gh"
            "jq"
            "cat"
            "grep"
            "pgrep"
            "ps"
            "tr"
            "mktemp"
            "chmod"
            "mv"
            "dirname"
            "rm"
            "date"
            "ls"
            "sort"
            "tail"
            "basename"
          ];
        };
      };
      user = { };
    };

    # No custom non-store-path units found on either aarch64 host at recon
    # time (2026-08-21, nix eval on both, all 7 verbs, both scopes). Kept as
    # explicit empty entries — not omitted — so a reviewer sees these hosts
    # were considered, not skipped, and so classifyStale has a real attrset
    # to compare against rather than `{}` defaulting silently.
    rpi5-full = {
      system = { };
      user = { };
    };
    rpi5 = {
      system = { };
      user = { };
    };
  };

  # Units with a non-store Exec* reference that this repo does not own and
  # does not declare a contract for — verified by recon (2026-08-21, all 3
  # hosts, all 7 verbs):
  #   systemd-tmpfiles-resetup — ships from nixpkgs; identical bare
  #     `systemd-tmpfiles --create --remove --exclude-prefix=/dev` on all
  #     three hosts; resolves through systemd's own compiled DEFAULT_PATH,
  #     not through this unit's declared path=/PATH=.
  #   generate-shutdown-ramfs — nixpkgs' initrd-ng module; ExecStart's second
  #     token is `/run/initramfs`, a runtime MOUNT TARGET, not a script.
  #   lastlog2-import — nixpkgs' lastlog2 module; ExecStartPost is
  #     `mv /var/log/lastlog /var/log/lastlog.migrated` — both non-store
  #     tokens are DATA FILE paths, not commands looked up on $PATH.
  #   reload-systemd-vconsole-setup — NixOS's own generated
  #     X-Restart-Triggers reload mechanism; ExecReload is
  #     `/run/current-system/systemd/bin/systemctl restart
  #     systemd-vconsole-setup` — `/run/current-system/systemd` is a
  #     deterministic symlink into the BOOTED system's own systemd, refreshed
  #     by every activation; not a script this repo authors or could break by
  #     editing `path=`.
  #   sshd / sshd@ — nixpkgs' openssh module; ExecStart's non-store token is
  #     `/etc/ssh/sshd_config`, a CONFIG FILE argument, not a $PATH-resolved
  #     command.
  #   bluetooth — nixpkgs' bluetooth module (rpi5-full only); ExecStart's
  #     non-store token is `/etc/bluetooth/main.conf`, a CONFIG FILE argument
  #     to `bluetoothd` (already invoked via full /nix/store path). Newly
  #     visible ONLY after the 2026-08-21 quote-aware-tokenizer fix (PR #568
  #     review, thread live at execstart-path-contract.nix:~205) — the prior
  #     naive `splitString " "` tokenizer split `"/etc/bluetooth/main.conf"`
  #     on no internal space (this one has none) but still failed to strip
  #     the surrounding quote characters, so the token read as
  #     `"/etc/bluetooth/main.conf"` (leading `"`) and never matched
  #     `hasPrefix "/"` — a real, live silent-miss on this exact repo, not a
  #     hypothetical one, confirming the review finding.
  #   home-assistant — nixpkgs' home-assistant module (rpi5-full only);
  #     ExecStart's non-store token is `/var/lib/hass`, a DATA DIRECTORY
  #     argument to `hass` (already invoked via full /nix/store path);
  #     ExecReload's `kill "-HUP" $MAINPID` has no off-store token at all
  #     (`$MAINPID` is a systemd-substituted PID, not a path). Same
  #     newly-visible-after-the-tokenizer-fix history as bluetooth above.
  # Excluding these BY NAME, each with its own reason above, is the honest
  # choice — excluding by a shared pattern (e.g. "not sancta-*") would also
  # silently hide a real future sancta-owned unit that happened to match.
  vendorExceptions = [
    "systemd-tmpfiles-resetup"
    "generate-shutdown-ramfs"
    "lastlog2-import"
    "reload-systemd-vconsole-setup"
    "sshd"
    "sshd@"
    "bluetooth"
    "home-assistant"
  ];

  # Maintainer-curated map: nixpkgs package `pname` (verified empirically —
  # `nix eval .#nixosConfigurations.sancta-choir.pkgs --apply '...v.pname...'`
  # 2026-08-20 — NOT assumed from the `with pkgs; [ … ]` attribute name, which
  # can differ: `pkgs.bash`'s pname is `bash-interactive`, not `bash`) ->
  # external command names it is known to provide. NOT exhaustive by design —
  # extend it the day a unit's real PATH= gains a package this check needs to
  # recognize. This is exactly the class of hand-maintained fact that #564
  # itself got wrong once (assuming coreutils provides `hostname`; it doesn't
  # — net-tools/inetutils does) — kept deliberately small and per-command
  # rather than trusted-by-category, so a wrong entry is one line to audit,
  # and an unrecognized package simply satisfies nothing (fails closed on the
  # command, never silently credits a package that isn't listed here).
  provides = {
    "bash-interactive" = [ "bash" "sh" ];
    "bash" = [ "bash" "sh" ]; # in case a future module pulls plain (non-interactive) bash
    "nodejs" = [ "node" "npm" "npx" "corepack" ];
    "gh" = [ "gh" ];
    "jq" = [ "jq" ];
    "systemd" = [ "systemctl" "systemd-run" "journalctl" "loginctl" "systemd-tmpfiles" ];
    "gnugrep" = [ "grep" "egrep" "fgrep" ];
    "coreutils" = [
      "mktemp"
      "dirname"
      "chmod"
      "mv"
      "rm"
      "date"
      "cat"
      "cp"
      "ls"
      "mkdir"
      "rmdir"
      "touch"
      "basename"
      "printf"
      "sort"
      # `tail` added 2026-08-22: sancta-wq-tick's contract declared it (bin/distil
      # `check` takes the newest sealed version with `sort | tail -1`) and the
      # checker FAILED the build with "PATH= does not provide: tail" even though
      # coreutils has always shipped it — the map was simply short. Verified the
      # way this file's header demands, not from memory:
      # `ls $(nix eval --raw .#nixosConfigurations.sancta-choir.pkgs.coreutils)/bin`
      # → tail present (coreutils-9.8). A missing entry fails CLOSED like this,
      # which is the intended direction: a wrong `provides` line can only refuse
      # a real command, never credit an absent one.
      "tail"
      "uniq"
      "tr"
      "cut"
      "wc"
      "test"
      # `sha256sum` and `stat` added 2026-08-23 for sancta-transcript-archive
      # (object naming by ciphertext hash; mtime/size for the closed-session
      # rule and the manifest row). Verified the way this file's header demands
      # — from the real store path, not from memory:
      # `ls $(nix eval --raw .#nixosConfigurations.sancta-choir.pkgs.coreutils)/bin`
      # → both present (coreutils-9.8).
      "sha256sum"
      "stat"
    ];
    "findutils" = [ "find" "xargs" ];
    "gnused" = [ "sed" ];
    "net-tools" = [ "hostname" "ifconfig" "netstat" "route" ];
    "inetutils" = [ "hostname" "ping" "telnet" "ftp" ];
    "util-linux" = [ "mount" "umount" "lsblk" "blkid" "fdisk" ];
    "curl" = [ "curl" ];
    "git" = [ "git" ];
    # Added 2026-08-23 for sancta-transcript-archive. pname verified
    # empirically, as this file's header demands:
    # `nix eval --raw .#nixosConfigurations.sancta-choir.pkgs.age.pname` → "age"
    # (the attribute name and the pname agree here, which is exactly the thing
    # that cannot be assumed — pkgs.bash's pname is "bash-interactive").
    # Binaries listed from the real store path: age, age-keygen (plus plugin
    # binaries this repo does not use).
    "age" = [ "age" "age-keygen" ];
    # Added 2026-08-22 for sancta-wq-tick (bin/sancta-reconnect's `pgrep -f` +
    # `ps -o ppid=`). pname verified empirically, as this file's header demands:
    # `nix eval .#nixosConfigurations.sancta-choir.pkgs --apply 'p: p.procps.pname'`
    # → "procps" (NOT "procps-ng", which is what the upstream project calls
    # itself and what a from-memory entry would plausibly have said).
    "procps" = [ "ps" "pgrep" "pkill" "top" "kill" ];
  };

  # Commands satisfied by NixOS's OWN unconditional systemd.services.<n>.path
  # defaults, appended to every service's PATH regardless of the module's own
  # declared `path =` — see the falsifiability note on sancta-statusline-refresh
  # above. Report-only annotation, not a pass/fail input.
  alwaysPresentPnames = [ "coreutils" "findutils" "gnugrep" "gnused" "systemd" ];
}
