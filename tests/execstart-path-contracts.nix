# Committed, human-maintained contract for systemd units whose ExecStart-family
# points at a path OUTSIDE /nix/store — read alongside tests/execstart-path-
# contract.nix, which explains WHY this has to be a committed manifest rather
# than something derived from the script's real bytes at build time (short
# version: the script lives on a LUKS volume that is not present in a Nix
# build sandbox, and CI never passes --impure — see that file's header for the
# full, tested chain of reasoning, recon 2026-08-20).
#
# Each entry under `hosts.<host>.<unit>` says: which interpreter the shebang
# names, and which EXTERNAL commands (bare names resolved via $PATH — NOT
# absolute paths, NOT shell builtins) the script invokes. This is filled in BY
# HAND by reading the real script on the host that carries it. It can go
# stale the moment someone edits the script without updating this file — nix
# eval has no way to notice that on its own. The runtime probe (wq-tick's
# execstart-contract-check handler, INDEX repo, committed separately) exists
# specifically to close that gap: it re-derives the same facts from the live
# script on sancta-choir, on a schedule, and reports drift.
#
# THIS FILE COVERS EXACTLY THE UNITS RECON FOUND (2026-08-20, all 3 hosts,
# nix eval). If a future PR adds a new custom unit with a non-/nix/store
# ExecStart and does not add an entry here, tests/execstart-path-contract.nix
# fails the build with UNDECLARED — that is the point: the absence of an
# entry is a hard stop, not a silent gap.

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
    sancta-choir = {
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
    };

    # No custom non-store-path units found on either aarch64 host at recon
    # time (2026-08-20, nix eval on both). Kept as explicit empty entries —
    # not omitted — so a reviewer sees these hosts were considered, not
    # skipped, and so `classifyStale` (execstart-path-contract.nix) has a real
    # attrset to compare against rather than `{}` defaulting silently.
    rpi5-full = { };
    rpi5 = { };
  };

  # Units with a non-store ExecStart that this repo does not own and does not
  # declare a contract for. Verified by recon (2026-08-20): `systemd-
  # tmpfiles-resetup` ships from nixpkgs itself — identical bare
  # `systemd-tmpfiles --create --remove --exclude-prefix=/dev` on all three
  # hosts — and resolves through systemd's own compiled-in DEFAULT_PATH, NOT
  # through this unit's `path=`/`Environment=PATH`. That is a different
  # mechanism this check is not built to reason about (it would need to know
  # systemd's own compile-time default, not anything Nix-visible here).
  # Excluding it BY NAME, with this comment, is the honest choice — excluding
  # it silently (e.g. filtering all "systemd-*" units) would not be, because
  # it would also hide a REAL future sancta-owned unit that happened to start
  # with the same prefix.
  vendorExceptions = [ "systemd-tmpfiles-resetup" ];

  # Maintainer-curated map: nixpkgs package `pname` (verified empirically —
  # `nix eval .#nixosConfigurations.sancta-choir.pkgs --apply '...v.pname...'`
  # 2026-08-20 — NOT assumed from the `with pkgs; [ … ]` attribute name, which
  # can differ: `pkgs.bash`'s pname is `bash-interactive`, not `bash`) ->
  # external command names it is known to provide. NOT exhaustive by design —
  # extend it the day a module's `path` gains a package this check needs to
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
      "uniq"
      "tr"
      "cut"
      "wc"
      "test"
    ];
    "findutils" = [ "find" "xargs" ];
    "gnused" = [ "sed" ];
    "net-tools" = [ "hostname" "ifconfig" "netstat" "route" ];
    "inetutils" = [ "hostname" "ping" "telnet" "ftp" ];
    "util-linux" = [ "mount" "umount" "lsblk" "blkid" "fdisk" ];
    "curl" = [ "curl" ];
    "git" = [ "git" ];
  };
}
