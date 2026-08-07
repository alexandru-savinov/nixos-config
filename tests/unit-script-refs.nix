# Store-reference existence check for sancta systemd unit scripts.
#
# WHY THIS EXISTS (the learning, put in code — 2026-08-07):
#   `nix build --dry-run` on a toplevel returned exit 0 and I called the config
#   "boot-safe". Then `switch-to-configuration switch` failed with exit 4 because
#   sancta-soul-mirror-alert ran `$(${coreutils}/bin/hostname)` — and `hostname`
#   is NOT in coreutils (it's in `nettools`/the `hostname` package). The shell
#   exec'd a store path that does not exist → 127 → the unit failed.
#
#   Eval and build could not catch it: `${pkgs.coreutils}/bin/hostname` is pure
#   STRING INTERPOLATION. Nix substitutes the coreutils store path and embeds the
#   text; it never dereferences the path. `writeShellScript` writes the bytes;
#   the derivation realises fine. The reference "works by luck" until something
#   RUNS it. Only activation (switch-to-configuration / a booted VM) executes the
#   script — which is why the failure was invisible to every static check.
#
#   This test closes that gap statically: it realises each sancta unit's
#   ExecStart-family scripts and asserts EVERY `/nix/store/<hash>-…` path they
#   reference actually exists. A referenced store path that is missing is almost
#   always a `${pkg}/bin/typo` bug — caught here, in CI, before a deploy, instead
#   of at `switch` on the live host.
#
# Run: nix build .#checks.<system>.unit-script-refs

{ pkgs
, nixpkgs
, self
,
}:

let
  lib = nixpkgs.lib;
  services = self.nixosConfigurations.sancta-choir.config.systemd.services;

  # sancta-owned units (services + the @-template instances)
  sanctaNames = lib.filter (n: lib.hasPrefix "sancta" n) (lib.attrNames services);

  toList = x: if x == null then [ ] else if lib.isList x then x else [ x ];

  cmdsOf =
    n:
    let
      sc = services.${n}.serviceConfig or { };
    in
    toList (sc.ExecStartPre or null)
    ++ toList (sc.ExecStart or null)
    ++ toList (sc.ExecStartPost or null)
    ++ toList (sc.ExecReload or null)
    ++ toList (sc.ExecStop or null)
    ++ toList (sc.ExecStopPost or null);

  # Raw Exec* command strings for every sancta unit. An entry may be a plain
  # string ("@/nix/store/…-script %N") OR a bare derivation (`ExecStart =
  # writeShellScript …`); `toString` normalises both. CRUCIAL: we keep the FULL
  # strings and never run splitString/match on them, because those string ops
  # strip the store-path *context* — and without context Nix never realises the
  # script into the check's sandbox, so grep would read an absent file and the
  # check would pass on nothing. Concatenating the toString'd values carries the
  # combined context, so every referenced script is a real build input.
  cmdList = map toString (lib.concatMap cmdsOf sanctaNames);
  cmds = lib.concatStringsSep "\n" cmdList;
in
pkgs.runCommand "sancta-unit-script-refs"
{
  # `cmds` carries the store-path context of every referenced script, so Nix
  # realises them all into this derivation's sandbox (readable below).
  inherit cmds;
  nCmds = toString (builtins.length cmdList);
} ''
    # Store-path token: 32 base32 chars, name, then valid store-path chars only.
    # The class naturally excludes space, paren, quotes and dollar, so there is no
    # shell-quoting to smuggle through the Nix indented string (an earlier quoted
    # class was mangled and matched nothing — a check that could not fail, which
    # is exactly why the negative self-test below exists).
    re='/nix/store/[a-z0-9]{32}-[a-zA-Z0-9._+/-]*'

    scan() { # $1=file — appends any missing refs to $2, increments $checked
      local f="$1"
      local ref
      for ref in $(grep -aoE "$re" "$f" | sort -u); do
        checked=$((checked + 1))
        if [ ! -e "$ref" ]; then echo "✗ MISSING: $ref  (in $f)"; fail=1; fi
      done
    }

    # ── NEGATIVE ARM: prove the detector actually fires ─────────────────────
    # A check that cannot be shown to fail is worthless. Feed it a fixture with a
    # store path that certainly does not exist; the scan MUST flag it.
    printf 'x=$(/nix/store/0000000000000000000000000000000a-bogus-9.9/bin/nope)\n' > probe.txt
    fail=0; checked=0
    scan probe.txt > /dev/null
    if [ "$fail" -ne 1 ] || [ "$checked" -lt 1 ]; then
      echo "SELF-TEST FAILED: the detector did not flag a known-missing store ref — the check cannot fail, so it proves nothing." >&2
      exit 1
    fi
    echo "self-test ok: detector flags a known-missing store ref"

    # Guard against a silently-empty scan (extraction returned no commands).
    if [ "$nCmds" -lt 1 ]; then
      echo "SELF-TEST FAILED: collected 0 unit commands — extraction is broken, nothing was actually checked." >&2
      exit 1
    fi

    # ── REAL SCAN ───────────────────────────────────────────────────────────
    # Each line is a full Exec* command. Strip systemd prefix chars (@ ! : + ~ -),
    # take the first token as the program, and — if it is a store path — scan it.
    # IFS=newline keeps the loop in THIS shell so the counters survive (a pipe
    # would subshell them away). Store paths contain no spaces.
    fail=0; checked=0; scanned=0
    OLDIFS=$IFS; IFS='
  '
    for line in $cmds; do
      [ -n "$line" ] || continue
      prog=$(printf '%s' "$line" | sed -E 's/^[@!:+~-]+//' | awk '{print $1}')
      case "$prog" in
        /nix/store/*) ;;
        *) continue ;;
      esac
      if [ ! -r "$prog" ]; then
        echo "✗ UNREADABLE: $prog — script is not a build input (context lost); the scan would be blind." >&2
        fail=1; continue
      fi
      # Only scan shell scripts we author (shebang). ELF binaries (node, bash, …)
      # embed store-path strings — RPATHs, data files like bashdb — that are NOT
      # command references and may legitimately not exist as files; flagging those
      # is noise. The bug class we hunt lives in writeShellScript-authored units.
      [ "$(head -c 2 "$prog" 2>/dev/null)" = "#!" ] || continue
      scanned=$((scanned + 1))
      scan "$prog"
    done
    IFS=$OLDIFS

    if [ "$scanned" -lt 1 ]; then
      echo "SELF-TEST FAILED: 0 store-path scripts were actually read — the scan proved nothing." >&2
      exit 1
    fi
    echo "sancta-unit-script-refs: read $scanned script(s), $checked store-ref(s)"
    if [ "$fail" -ne 0 ]; then
      echo "FAILED — a sancta unit script references a store path that does not exist." >&2
      echo "This is the class that passes eval+build and only fails at switch/runtime" >&2
      echo "(e.g. a coreutils/bin/hostname reference — hostname is not in coreutils)." >&2
      exit 1
    fi
    echo "all referenced store paths exist"
    echo ok > $out
''
