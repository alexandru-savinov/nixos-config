# The NEGATIVE ARM for sancta-absent-guard — prove the clock's unit actually
# goes RED, and actually goes GREEN, instead of asserting that it would.
#
# WHY THIS FILE EXISTS
#   A guard that has never been shown firing on a real absence is an unproven
#   guard. module-eval proves the unit is WIRED (mount gate present, marker
#   directory writable, cadence single-sourced); nothing in eval or dry-build
#   proves that a stale producer produces a non-zero exit — and this house has
#   twice shipped a check that could not fail (tests/unit-script-refs.nix and
#   tests/sancta-doctrine-guard.nix both carry that scar, and both answered it
#   the same way: drive the real artifact and assert BOTH directions).
#
# WHAT IT DRIVES: the REAL ExecStart of sancta-choir's sancta-absent-guard.
# Not a copy, not a re-derivation of the script text — the store path the unit
# would actually execute, realised into this derivation's sandbox by passing
# the whole Exec* string as an env var (which carries its store-path CONTEXT;
# splitString/match would strip it and the builder would read an absent file —
# the exact "check that proves nothing" this file is written against).
#
# WHAT IT DOES NOT PROVE, said plainly:
#   * Nothing here runs the real bin/absent-guard. That script lives on a LUKS
#     volume no Nix build sandbox can read (same structural limit that forces
#     tests/execstart-path-contracts.nix to be a hand-committed manifest). The
#     arms below use STUB guards that exit 0/1/2/7 on demand, so what is proven
#     is the translation — guard exit code → unit red or green — which is the
#     entire contract this module adds. The guard's own age arithmetic is
#     proven by driving the real script against fixture tables by hand; that
#     evidence is in the PR body, not in CI, because CI cannot reach it.
#   * Nothing here boots a VM, so activation is still unproven. This host has
#     no /dev/kvm (verified 2026-09-26: `ls /dev/kvm` → No such file), so
#     pkgs.testers.nixosTest cannot run here at all. Eval + these arms +
#     module-eval are what is honestly available; the first real beat on
#     sancta-choir is the first activation proof.

{ pkgs
, self
,
}:

let
  svc = self.nixosConfigurations.sancta-choir.config.systemd.services.sancta-absent-guard;
in
pkgs.runCommand "sancta-absent-guard-arms"
{
  # Carries the store-path context of the check script, so Nix realises it into
  # the sandbox. Keep the FULL string — never split it in Nix.
  execStart = toString svc.serviceConfig.ExecStart;
  bash = "${pkgs.bash}/bin/bash";
} ''
    set -u

    CHECK=$(printf '%s' "$execStart" | ${pkgs.gawk}/bin/awk '{print $1}')
    if [ ! -x "$CHECK" ]; then
      echo "SELF-TEST FAILED: could not realise the unit's ExecStart script ($CHECK) — the arms below would prove nothing." >&2
      exit 1
    fi
    echo "driving the real ExecStart: $CHECK"

    mkdir -p fixtures
    cd fixtures

    # ── fixture tables ──────────────────────────────────────────────────────
    # A table WITH the guard's self-watch row (the real shape), and one without.
    cat > producers-ok.json <<'JSON'
    { "producers": [
        { "name": "absent-guard", "path": "absent-last.json", "max_age": "6h",
          "means": "THIS GUARD ITSELF has not completed a run." },
        { "name": "dreams", "path": "dreams", "max_age": "36h",
          "means": "The night consolidation loop is not running." }
    ] }
  JSON

    cat > producers-no-self-row.json <<'JSON'
    { "producers": [
        { "name": "dreams", "path": "dreams", "max_age": "36h",
          "means": "The night consolidation loop is not running." }
    ] }
  JSON

    # ── stub guards ─────────────────────────────────────────────────────────
    # bin/absent-guard's documented contract: 0 ok / 1 stale / 2 missing-or-
    # internal-failure. Each stub prints a report the way the real one does, so
    # the arms also prove the report reaches the journal in BOTH directions.
    mkstub() { # $1=name $2=exit code $3=report line
      {
        echo "#!$bash"
        echo "cat <<'REPORT_EOF'"
        echo "$3"
        echo "REPORT_EOF"
        echo "exit $2"
      } > "$1"
      chmod +x "$1"
    }
    mkstub guard-ok      0 'ok       dreams         newest=2026-09-26T00:00Z  age=1h  max=36h'
    mkstub guard-stale   1 'STALE    dreams         newest=2026-08-08T00:51Z  age=48d max=36h'
    mkstub guard-missing 2 'MISSING  northstar      newest=never              max=90d'
    mkstub guard-weird   7 'who knows'

    fail=0
    ran=0

    # run <name> <expected exit> <expected substring> <guard> <table> <interval>
    run() {
      local name="$1" want="$2" needle="$3" guard="$4" table="$5" interval="$6"
      local out rc
      ran=$((ran + 1))
      # genericBuild's setup.sh has already run `set -e` by the time this
      # buildCommand executes, and this file's own `set -u` only ADDS -u — it
      # does not turn -e off. A bare `out=$(cmd)` where cmd exits nonzero is NOT
      # exempt from errexit (only `if`/`while`/`&&`/`||`/`!` contexts are), so
      # the very first RED arm killed the whole derivation before `rc=$?` ever
      # ran, before this fix — a random-looking builder failure instead of the
      # comparison below. Putting the assignment in an `if` condition is the
      # exemption tests/sancta-doctrine-guard.nix's expect_pass/expect_fail
      # already rely on for the same reason.
      if out=$(SANCTA_ABSENT_PRODUCERS="$table" SANCTA_ABSENT_INTERVAL_SEC="$interval" \
               "$CHECK" "$guard" 2>&1); then
        rc=0
      else
        rc=$?
      fi
      if [ "$rc" -ne "$want" ]; then
        echo "✗ $name: expected exit $want, got $rc" >&2
        printf '%s\n' "$out" | sed 's/^/    | /' >&2
        fail=1
        return
      fi
      case "$out" in
        *"$needle"*) echo "✓ $name (exit $rc)" ;;
        *) echo "✗ $name: exit $rc was right but the message never said '$needle'" >&2
           printf '%s\n' "$out" | sed 's/^/    | /' >&2
           fail=1 ;;
      esac
    }

    echo "── GREEN arm ───────────────────────────────────────────────"
    run "all producers fresh → unit GREEN" \
        0 "absent-guard OK" "$PWD/guard-ok" "$PWD/producers-ok.json" 7200

    echo "── RED arms ────────────────────────────────────────────────"
    # The one the whole module is for: a producer has gone quiet.
    run "a STALE producer → unit RED" \
        1 "at least one producer is STALE" "$PWD/guard-stale" "$PWD/producers-ok.json" 7200
    run "a STALE producer → the guard's report reaches the journal" \
        1 "STALE    dreams" "$PWD/guard-stale" "$PWD/producers-ok.json" 7200

    # MISSING outranks stale in the guard; both must be red here.
    run "a MISSING producer → unit RED" \
        1 "is MISSING, or the guard itself failed" "$PWD/guard-missing" "$PWD/producers-ok.json" 7200

    # "could not ask" is never "healthy".
    run "the guard itself gone → unit RED" \
        1 "nothing is holding a clock against any producer" \
        "$PWD/no-such-guard" "$PWD/producers-ok.json" 7200
    run "an undocumented exit status → unit RED" \
        1 "not one of its documented statuses" "$PWD/guard-weird" "$PWD/producers-ok.json" 7200

    # THE CADENCE RELATION — the two-repo relation made an assertion. A 7h beat
    # against the guard's 6h self max_age must fail BEFORE it can be reported as
    # a producer problem, because the clock would be causing it.
    run "timer slower than the guard's own max_age → unit RED" \
        1 "TIMER TOO SLOW" "$PWD/guard-ok" "$PWD/producers-ok.json" 25200
    run "timer exactly at the guard's max_age → still GREEN (boundary)" \
        0 "absent-guard OK" "$PWD/guard-ok" "$PWD/producers-ok.json" 21600

    # The self-watch row deleted from the table: a completed run would stop
    # proving anything ran, and that must be loud rather than convenient.
    run "no absent-guard row in the table → unit RED" \
        1 "SELF-watch is gone" "$PWD/guard-ok" "$PWD/producers-no-self-row.json" 7200
    run "unreadable table → unit RED" \
        1 "SELF-watch is gone" "$PWD/guard-ok" "$PWD/nope.json" 7200

    echo "────────────────────────────────────────────────────────────"
    if [ "$ran" -lt 10 ]; then
      echo "SELF-TEST FAILED: only $ran arms ran — the harness is not exercising what it claims." >&2
      exit 1
    fi
    if [ "$fail" -ne 0 ]; then
      echo "FAILED: sancta-absent-guard's unit script did not behave as its module claims." >&2
      exit 1
    fi
    echo "sancta-absent-guard: $ran arms, red and green both demonstrated"
    echo ok > $out
''
