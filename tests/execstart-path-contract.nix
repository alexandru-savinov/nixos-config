# Declared-contract check for systemd units whose ExecStart-family points at a
# path OUTSIDE /nix/store — the same shape of bug that made
# sancta-statusline-refresh.service exit 127 on every timer tick (PR #564): the
# unit's `path=` listed gh/jq/systemd/gnugrep/coreutils but not bash, and
# bash is the shebang INTERPRETER the script needs to even start.
#
# WHY THIS CANNOT BE A tests/unit-script-refs.nix-STYLE CHECK
# -------------------------------------------------------------
# unit-script-refs.nix REALISES each script (a Nix store derivation) and greps
# its bytes for store-path references. That only works because the script IS
# a store path. This class of bug is different by construction: the script
# lives at /var/lib/sancta/.claude/index/bin/statusline-refresh, on a LUKS
# volume, and is NOT a Nix store path — there is nothing for a build sandbox
# to realise. Proven, not assumed, 2026-08-20 recon:
#   1. `nix build --impure --expr '... runCommand ... "cat /var/lib/sancta/…"'`
#      fails ENOENT — even ON THE HOST WHERE THE FILE DEMONSTRABLY EXISTS, a
#      sandboxed build sees only /nix/store + declared inputs, never arbitrary
#      host paths. `builtins.pathExists` at EVAL time on the same path
#      correctly returns true, proving this is the eval/build boundary, not a
#      fluke.
#   2. Even an eval-time `builtins.readFile` on that path needs `--impure`
#      (pure-eval-by-default rejects `/var/...` path literals outright), and
#      `grep -rn impure .github/workflows/` finds zero uses — CI never passes
#      it, so a check depending on it would never even reach "does the file
#      exist" before failing the pure-eval guard.
#   3. Even if `--impure` WERE passed, GitHub's runner is a different,
#      ephemeral machine with no LUKS soul volume mounted at all — ENOENT
#      either way.
# So: nothing wired into `checks.<system>.*` / `nix flake check` can ever read
# this script's real bytes. Pretending otherwise would recreate the exact
# false-confidence bug this whole check family exists to close.
#
# THE DESIGN THIS BECOMES INSTEAD
# --------------------------------
# Two halves, each honest about what it can and cannot see:
#   (a) THIS FILE — an eval-time check over a small, COMMITTED, human-written
#       contract (tests/execstart-path-contracts.nix): "this unit's script
#       needs interpreter X and commands [Y, Z, …]". It cross-references that
#       contract against the unit's Nix-visible `path=` (mapped through a
#       curated pname->commands table) and FAILS if the declared need is not
#       provided. It also fails if a non-store unit exists with NO declared
#       contract at all (UNDECLARED) — so a *future* PR that introduces a new
#       off-store unit cannot pass silently just because nobody thought to add
#       an entry.
#   (b) A RUNTIME PROBE (wq-tick's `execstart-contract-check` handler, INDEX
#       repo, committed separately — see the task this check was built under)
#       that reads the REAL script on sancta-choir, on a schedule, and checks
#       the committed contract still matches reality. That is the only piece
#       that can ever see the actual bytes; this file cannot, and does not
#       pretend to.
# This file proves internal consistency between the manifest and the module's
# `path=`. It does NOT prove the manifest is telling the truth about the
# script — only (b) can do that. Both halves are named here so the limit is
# never implicit.
#
# WHAT THIS DOES NOT COVER (state it, don't imply otherwise)
# ------------------------------------------------------------
#  - Scripts invoked BY a contract-covered script via an absolute/relative
#    path (not looked up on $PATH) are not recursed into. Example:
#    statusline-refresh calls `$HERE/sidequest` directly — a missing sidequest
#    binary is an ENOENT the script's own code already handles, not a $PATH
#    resolution failure, so it is out of scope for a $PATH contract by
#    definition, not by oversight.
#  - A unit whose Environment= carries a raw `PATH=...` override is NOT
#    reasoned about — this checker only understands the `path=` NixOS option.
#    Rather than silently trust or silently ignore such a unit, it FAILS
#    CLOSED with an explicit "cannot verify — raw PATH override" reason (self-
#    tested below).
#  - systemd's own compiled-in DEFAULT_PATH (what a BARE command with no
#    leading `/` resolves through, e.g. the vendor systemd-tmpfiles-resetup
#    unit present on every host) is a different resolution mechanism this
#    checker does not model; such units are named in an explicit exception
#    list (tests/execstart-path-contracts.nix `vendorExceptions`), never
#    silently filtered by a pattern that could also hide a real sancta unit.
#
# COVERAGE, STATED OUT LOUD
# ---------------------------
# Unlike unit-script-refs.nix, this check needs no REALISATION — it reads only
# Nix-visible option values (Exec* strings, `path=`, `serviceConfig.Environment`),
# the same category of fact module-eval.nix already treats as architecture-
# independent. So — verified by running it — this check evaluates all THREE
# configured hosts for real, including both aarch64 hosts this repo has no
# local builder for (sancta-choir, rpi5-full, rpi5). That is MORE coverage
# than unit-script-refs.nix gets, for a cheaper reason: there is nothing to
# build, only attributes to read.
#
# Run: nix build .#checks.x86_64-linux.execstart-path-contract -L

{ pkgs
, nixpkgs
, self
,
}:

let
  lib = nixpkgs.lib;
  data = import ./execstart-path-contracts.nix;

  # All configured hosts. Pure eval — see COVERAGE above for why all three are
  # safe and cheap to include, unlike the realisation-bound unit-script-refs.nix.
  allHosts = [ "sancta-choir" "rpi5-full" "rpi5" ];

  toList = x: if x == null then [ ] else if lib.isList x then x else [ x ];

  cmdsOf =
    services: n:
    let
      sc = services.${n}.serviceConfig or { };
    in
    toList (sc.ExecStartPre or null)
    ++ toList (sc.ExecStart or null)
    ++ toList (sc.ExecStartPost or null)
    ++ toList (sc.ExecStop or null);

  # Strip systemd's leading exec-modifier characters (`@ - + ! : ~ "`) one at a
  # time — several can stack (e.g. a templated, non-blocking, root-run unit) —
  # until none remain. Mirrors tests/unit-script-refs.nix's stripping, widened
  # with `~` and `"` per this task's own wording of the modifier set.
  stripLeading =
    s:
    let
      modChars = [ "@" "-" "+" "!" ":" "~" "\"" ];
      go = str:
        let
          m = lib.findFirst (c: lib.hasPrefix c str) null modChars;
        in
        if m == null then str else go (lib.removePrefix m str);
    in
    go s;

  # True for a single Exec* line whose PROGRAM token (after stripping
  # modifiers) is non-empty and does not start with /nix/store. Empty strings
  # are the standard NixOS idiom for masking a templated unit (getty@, etc.)
  # and are correctly excluded, matching the 2026-08-20 recon's confirmed
  # false-positive list.
  isNonStoreLine =
    raw:
    let
      s = stripLeading raw;
    in
    s != "" && !(lib.hasPrefix "/nix/store" s);

  # nixpkgs `pname` for a `path=` list entry. Entries are normally packages
  # (`with pkgs; [ bash … ]`); a bare string is treated as the command name
  # itself. VERIFIED EMPIRICALLY (2026-08-20, `nix eval
  # .#nixosConfigurations.sancta-choir.pkgs --apply '...pname...'`) that
  # `pkgs.bash`'s pname is `bash-interactive`, NOT `bash` — this function (and
  # the provides table it feeds) is keyed on the real pname, never the
  # `with pkgs;` attribute name, because those two are proven to differ.
  pkgNameOf =
    item:
    if builtins.isString item then item
    else if item ? pname then item.pname
    else if item ? name then (lib.strings.parseDrvName item.name).name
    else toString item;

  providedCommandsOf =
    pathList: lib.unique (lib.concatMap (item: data.provides.${pkgNameOf item} or [ ]) pathList);

  # The core assertion: does `path` (mapped through the provides table)
  # supply the contract's interpreter and every command it declares? Fails
  # closed (never silently passes) on a raw PATH= Environment override, since
  # this function has no model for what such an override would actually put
  # on $PATH.
  checkContract =
    { path, environment ? [ ], contract }:
    let
      hasRawPathOverride = lib.any (e: lib.hasPrefix "PATH=" (toString e)) environment;
      providedNames = providedCommandsOf path;
      needed = [ contract.interpreter ] ++ contract.commands;
      missing = lib.filter (c: !(lib.elem c providedNames)) needed;
    in
    if hasRawPathOverride then
      {
        ok = false;
        reason = "cannot verify — Environment carries a raw PATH= override; this checker only understands the declarative path= option (fail-closed, not a silent pass)";
      }
    else if missing != [ ] then
      { ok = false; reason = "path= does not provide: ${lib.concatStringsSep ", " missing}"; }
    else
      {
        ok = true;
        reason = "path= provides interpreter '${contract.interpreter}' + ${toString (lib.length contract.commands)} command(s)";
      };

  # Classify ONE unit on ONE host: excluded-vendor / UNDECLARED / ok / FAIL.
  # Returns null for units whose Exec* is entirely inside /nix/store — those
  # are unit-script-refs.nix's job, not this file's, and are silently in-scope
  # for THAT check rather than out-of-scope-and-unmentioned for this one.
  classifyOne =
    host: services: n:
    let
      execLines = map toString (cmdsOf services n);
      inScope = lib.any isNonStoreLine execLines;
    in
    if !inScope then null
    else if lib.elem n data.vendorExceptions then
      {
        unit = n;
        inherit host;
        status = "excluded-vendor";
        detail = "vendor unit — resolves via systemd's own compiled DEFAULT_PATH, not this unit's path=/Environment; see execstart-path-contracts.nix vendorExceptions.";
      }
    else
      let
        contract = (data.hosts.${host} or { }).${n} or null;
      in
      if contract == null then
        {
          unit = n;
          inherit host;
          status = "UNDECLARED";
          detail = "non-store Exec* with no committed contract in tests/execstart-path-contracts.nix — add one.";
        }
      else
        let
          svc = services.${n};
          res = checkContract {
            path = svc.path or [ ];
            environment = svc.serviceConfig.Environment or [ ];
            contract = contract;
          };
        in
        {
          unit = n;
          inherit host;
          status = if res.ok then "ok" else "FAIL";
          detail = res.reason;
        };

  # The other direction: a manifest entry whose unit no longer exists on that
  # host is a STALE declaration — worth failing on, because a rename that
  # drops the old name silently loses coverage for whatever the new unit is
  # called (it would land in UNDECLARED only if someone thinks to check;
  # STALE-MANIFEST makes that failure loud instead of just quietly wrong).
  classifyStale =
    host: services:
    let
      declared = lib.attrNames (data.hosts.${host} or { });
      present = lib.attrNames services;
    in
    map
      (n: {
        unit = n;
        inherit host;
        status = "STALE-MANIFEST";
        detail = "declared in tests/execstart-path-contracts.nix but no unit by this name exists on ${host} — a rename may have silently dropped coverage.";
      })
      (lib.filter (n: !(lib.elem n present)) declared);

  classifyServices =
    host: services:
    (lib.filter (r: r != null) (map (classifyOne host services) (lib.attrNames services)))
    ++ classifyStale host services;

  # ── REAL SCAN ──────────────────────────────────────────────────────────
  realResults = lib.concatMap
    (h: classifyServices h self.nixosConfigurations.${h}.config.systemd.services)
    allHosts;

  # ── NEGATIVE / REGRESSION SELF-TESTS — run on EVERY invocation ──────────
  # A check that cannot be shown to fail is worthless (same doctrine as
  # unit-script-refs.nix's probe.txt and sancta-doctrine-guard.nix's
  # expect_fail cases). Each case below states what it expects and is
  # compared against what checkContract/classifyServices actually returns.
  fullSancataPath = [
    pkgs.bash
    pkgs.nodejs
    pkgs.gh
    pkgs.jq
    pkgs.systemd
    pkgs.gnugrep
    pkgs.coreutils
  ];
  goodContract = data.hosts.sancta-choir.sancta-statusline-refresh;

  contractSelfTests = [
    {
      name = "positive control: real path= + real contract passes";
      result = checkContract {
        path = fullSancataPath;
        environment = [ ];
        contract = goodContract;
      };
      expectOk = true;
    }
    {
      # THE EXACT PRE-#564 SHAPE: bash was missing from `path=`. This is not a
      # synthetic worst case — it is what shipped and exited 127 on every
      # timer tick before PR #564. It must go red here, permanently, on every
      # invocation of this check, not just once during development.
      name = "REGRESSION pre-#564: bash missing from path= must be flagged";
      result = checkContract {
        path = [ pkgs.nodejs pkgs.gh pkgs.jq pkgs.systemd pkgs.gnugrep pkgs.coreutils ];
        environment = [ ];
        contract = goodContract;
      };
      expectOk = false;
    }
    {
      name = "detector fires on a missing non-interpreter command (gh removed)";
      result = checkContract {
        path = [ pkgs.bash pkgs.nodejs pkgs.jq pkgs.systemd pkgs.gnugrep pkgs.coreutils ];
        environment = [ ];
        contract = goodContract;
      };
      expectOk = false;
    }
    {
      name = "fail-closed on a raw PATH= Environment override";
      result = checkContract {
        path = fullSancataPath;
        environment = [ "PATH=/some/hand-rolled/path" ];
        contract = goodContract;
      };
      expectOk = false;
    }
  ];
  contractSelfTestFailures = lib.filter (t: t.result.ok != t.expectOk) contractSelfTests;

  # Classification self-tests: fully synthetic fixture services, exercised
  # through the SAME classifyServices function the real scan uses (not a
  # reimplementation — a reimplementation could drift from what actually runs).
  fixtureUndeclaredResults = classifyServices "sancta-choir" {
    "sancta-fixture-undeclared" = {
      serviceConfig.ExecStart = "/opt/not-in-store/run.sh";
      path = [ pkgs.bash ];
    };
  };
  fixtureUndeclared = lib.findFirst (r: r.unit == "sancta-fixture-undeclared") null fixtureUndeclaredResults;

  fixtureVendorResults = classifyServices "sancta-choir" {
    "systemd-tmpfiles-resetup" = {
      serviceConfig.ExecStart = "systemd-tmpfiles --create --remove --exclude-prefix=/dev";
    };
  };
  fixtureVendor = lib.findFirst (r: r.unit == "systemd-tmpfiles-resetup") null fixtureVendorResults;

  # Empty fixture (no units at all) still carries the real manifest's
  # sancta-choir entry, which the fixture host doesn't have -> STALE-MANIFEST.
  fixtureStaleResults = classifyServices "sancta-choir" { };
  fixtureStale = lib.findFirst (r: r.unit == "sancta-statusline-refresh") null fixtureStaleResults;

  # A fully in-store unit must classify as out-of-scope (null / filtered),
  # proving this check does not duplicate unit-script-refs.nix's job.
  fixtureStorePathResults = classifyServices "sancta-choir" {
    "sancta-fixture-store-unit" = {
      serviceConfig.ExecStart = "/nix/store/00000000000000000000000000000000-fixture/bin/run";
    };
  };
  fixtureStoreUnitFlagged = lib.any (r: r.unit == "sancta-fixture-store-unit") fixtureStorePathResults;

  classificationSelfTests = [
    { name = "classifier fires UNDECLARED on a fresh non-store unit"; ok = fixtureUndeclared != null && fixtureUndeclared.status == "UNDECLARED"; }
    { name = "classifier excludes the named vendor unit"; ok = fixtureVendor != null && fixtureVendor.status == "excluded-vendor"; }
    { name = "classifier fires STALE-MANIFEST when a declared unit vanishes"; ok = fixtureStale != null && fixtureStale.status == "STALE-MANIFEST"; }
    { name = "classifier does not flag a plain /nix/store unit (that's unit-script-refs.nix's job)"; ok = !fixtureStoreUnitFlagged; }
  ];
  classificationSelfTestFailures = lib.filter (t: !t.ok) classificationSelfTests;

  selfTestFailureCount =
    lib.length contractSelfTestFailures + lib.length classificationSelfTestFailures;

  realFailures = lib.filter (r: lib.elem r.status [ "FAIL" "UNDECLARED" "STALE-MANIFEST" ]) realResults;

  fmtResult = r: "  [${r.status}] ${r.host}/${r.unit}: ${r.detail}";

  report = lib.concatStringsSep "\n" (
    [
      "execstart-path-contract: eval-time declared-contract check (see file header for scope + limits)"
      "hosts evaluated (pure eval, no realisation needed): ${lib.concatStringsSep " " allHosts}"
      ""
      "-- self-tests (run every invocation) --"
    ]
    ++ (map (t: "  ok: ${t.name}") contractSelfTests)
    ++ (map (t: "  ok: ${t.name}") classificationSelfTests)
    ++ [ "" "-- real scan, all in-scope units across all hosts --" ]
    ++ (if realResults == [ ] then [ "  (no non-/nix/store Exec* units found on any host)" ] else map fmtResult realResults)
    ++ [ "" ]
  );
in
pkgs.runCommand "execstart-path-contract"
{
  inherit report;
  passAsFile = [ "report" ];
  selfTestFailureCount = toString selfTestFailureCount;
  realFailureCount = toString (lib.length realFailures);
}
  ''
    cat "$reportPath"
    if [ "$selfTestFailureCount" -ne 0 ]; then
      echo "SELF-TEST FAILED: $selfTestFailureCount self-test(s) did not match their expected result — the detector cannot be trusted, see above." >&2
      exit 1
    fi
    if [ "$realFailureCount" -ne 0 ]; then
      echo "FAILED: $realFailureCount real unit(s) failed their declared-path contract (or are UNDECLARED / STALE-MANIFEST) — see [FAIL]/[UNDECLARED]/[STALE-MANIFEST] lines above." >&2
      exit 1
    fi
    echo "execstart-path-contract: ok — self-tests passed, all in-scope units satisfy their declared contract."
    echo ok > $out
  ''
