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
# COVERAGE WIDENED 2026-08-19 (PR #558 review, HIGH + MEDIUM findings):
#   The original version only scanned `sancta-choir`. Two reviews on #558 found
#   (a) the identical unfixed bug in `sancta-self-backup.nix`'s alert script, and
#   (b) that a green check here proved nothing about any OTHER host — a false
#   sense of coverage is exactly the failure mode this check exists to prevent.
#
#   Real scan now covers every `x86_64-linux` host this check itself runs on
#   (`sancta-choir`, `sancta-claw`, `hermes-claw`, `zero-kuzea`) — Nix can both
#   EVAL and REALISE (build) their derivations here, so the store-ref existence
#   check is a real, load-bearing assertion for all four.
#
#   `rpi5-full` / `rpi5` (aarch64-linux) are named but DELIBERATELY EXCLUDED from
#   the real scan, and this is stated in the check's own output, not just here:
#   `config.systemd.services` evals fine cross-arch (Nix eval is architecture-
#   agnostic — proven via `nix eval .#nixosConfigurations.rpi5-full.config.
#   systemd.services`, 2026-08-19), but REALISING an aarch64-linux script
#   derivation from an `x86_64-linux` check build needs a real aarch64 builder.
#   Verified this host has none: `nix build` on a real rpi5-full ExecStart store
#   path fails with "no substituter that can build it" — not a cache miss, no
#   builder at all. flake.nix's own rpi5-full comment separately warns never to
#   build it under QEMU (some packages fail there). GitHub's default runners are
#   x86_64-only too, so CI can't do this either. Overstating coverage for a host
#   this check cannot actually build against would recreate the exact false-
#   confidence bug this check was written to close — so it says so, out loud,
#   every time it runs, instead of silently omitting the host.
#
# Run: nix build .#checks.<system>.unit-script-refs

{ pkgs
, nixpkgs
, self
,
}:

let
  lib = nixpkgs.lib;

  # Hosts this check can actually REALISE scripts for (see COVERAGE WIDENED
  # above) — all `x86_64-linux`, same architecture as `checks.x86_64-linux`.
  scannedHosts = [ "sancta-choir" "sancta-claw" "hermes-claw" "zero-kuzea" ];

  # Named for honesty in the output, never scanned for real — aarch64-linux,
  # no builder here (see COVERAGE WIDENED above).
  unscannedHosts = [ "rpi5-full" "rpi5" ];

  toList = x: if x == null then [ ] else if lib.isList x then x else [ x ];

  cmdsOf =
    services: n:
    let
      sc = services.${n}.serviceConfig or { };
    in
    toList (sc.ExecStartPre or null)
    ++ toList (sc.ExecStart or null)
    ++ toList (sc.ExecStartPost or null)
    ++ toList (sc.ExecReload or null)
    ++ toList (sc.ExecStop or null)
    ++ toList (sc.ExecStopPost or null);

  # Per scanned host: sancta-owned units (services + the @-template instances),
  # then their Exec* command strings. An entry may be a plain string
  # ("@/nix/store/…-script %N") OR a bare derivation (`ExecStart = writeShellScript
  # …`); `toString` normalises both. CRUCIAL: we keep the FULL strings and never
  # run splitString/match on them, because those string ops strip the store-path
  # *context* — and without context Nix never realises the script into the
  # check's sandbox, so grep would read an absent file and the check would pass
  # on nothing. Concatenating the toString'd values carries the combined
  # context, so every referenced script is a real build input.
  perHost = map
    (host:
      let
        services = self.nixosConfigurations.${host}.config.systemd.services;
        sanctaNames = lib.filter (n: lib.hasPrefix "sancta" n) (lib.attrNames services);
        cmdList = map toString (lib.concatMap (cmdsOf services) sanctaNames);
      in
      { inherit host; nUnits = builtins.length sanctaNames; inherit cmdList; }
    )
    scannedHosts;

  cmdList = lib.concatMap (h: h.cmdList) perHost;
  cmds = lib.concatStringsSep "\n" cmdList;

  # e.g. "sancta-choir=10 sancta-claw=1 hermes-claw=0 zero-kuzea=0"
  hostSummary = lib.concatStringsSep " " (map (h: "${h.host}=${toString h.nUnits}") perHost);
in
pkgs.runCommand "sancta-unit-script-refs"
{
  # `cmds` carries the store-path context of every referenced script, so Nix
  # realises them all into this derivation's sandbox (readable below).
  inherit cmds;
  nCmds = toString (builtins.length cmdList);
  nHostsScanned = toString (builtins.length scannedHosts);
  hostSummary = hostSummary;
  unscannedHosts = lib.concatStringsSep " " unscannedHosts;
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

    echo "hosts scanned (real build+scan): $hostSummary"
    echo "hosts NOT scanned (aarch64-linux, no builder here): $unscannedHosts"

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
    echo "sancta-unit-script-refs: read $scanned script(s), $checked store-ref(s) across $nHostsScanned host(s)"
    if [ "$fail" -ne 0 ]; then
      echo "FAILED — a sancta unit script references a store path that does not exist." >&2
      echo "This is the class that passes eval+build and only fails at switch/runtime" >&2
      echo "(e.g. a coreutils/bin/hostname reference — hostname is not in coreutils)." >&2
      exit 1
    fi
    echo "all referenced store paths exist"
    echo ok > $out
''
