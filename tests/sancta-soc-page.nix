# The promotion rule of sancta-soc-page, driven in both directions.
#
# WHAT IT DRIVES: the REAL wrapper the unit executes — the store path taken
# from sancta-choir's rendered ExecStart, passed as a whole string so its
# store-path context realises it into this sandbox.
#
# WHAT IT DOES NOT PROVE, said plainly: gallery/soc.mjs and gallery/publish.mjs
# live on the LUKS soul volume, which no build sandbox can read. The arms use
# STUBS with the same contract (generator writes soc.html + soc-decide.html
# beside --out, or exits non-zero; gate exits 0 and writes <file>.passed with
# the sha256, or exits 1 FAIL / 2 CLOSED and writes nothing). What is proven is
# the wrapper's rule: a refused or missing page never replaces a served one,
# and only a fully passed pair is promoted. The real generator + real gate run
# was done by hand on choir; that evidence is in the PR body.

{ pkgs
, self
,
}:

let
  svc = self.nixosConfigurations.sancta-choir.config.systemd.services.sancta-soc-page;
in
pkgs.runCommand "sancta-soc-page-arms"
{
  execStart = toString svc.serviceConfig.ExecStart;
  nativeBuildInputs = with pkgs; [
    bash
    nodejs
    jq
    coreutils
    util-linux
    gawk
  ];
} ''
  set -u
  WRAPPER=$(printf '%s' "$execStart" | awk '{print $2}')
  if [ ! -r "$WRAPPER" ]; then
    echo "SELF-TEST FAILED: could not realise the unit's wrapper ($WRAPPER)" >&2
    exit 1
  fi
  echo "driving the real wrapper: $WRAPPER"

  idx=$PWD/idx; o=$PWD/o
  mkdir -p "$idx/gallery" "$o"

  # Stub generator: MODE picks the branch.
  cat > "$idx/gallery/soc.mjs" <<'EOF'
  import { writeFileSync } from 'node:fs';
  import { dirname, join } from 'node:path';
  const out = process.argv[process.argv.indexOf('--out') + 1];
  const mode = process.env.MODE;
  if (mode === 'genfail') process.exit(1);
  writeFileSync(out, mode === 'leak-main' ? 'LEAK new soc\n' : 'new soc\n');
  if (mode !== 'no-decide') writeFileSync(join(dirname(out), 'soc-decide.html'),
    mode === 'leak-decide' ? 'LEAK new decide\n' : mode === 'closed-decide' ? 'CLOSED\n' : 'new decide\n');
  EOF

  # Stub gate, same exit contract as gallery/publish.mjs.
  cat > "$idx/gallery/publish.mjs" <<'EOF'
  import { readFileSync, writeFileSync } from 'node:fs';
  import { basename } from 'node:path';
  import { createHash } from 'node:crypto';
  const f = process.argv[2];
  const b = readFileSync(f);
  if (b.includes('CLOSED')) process.exit(2);
  if (b.includes('LEAK')) process.exit(1);
  writeFileSync(f + '.passed', JSON.stringify({ img: basename(f), sha256: createHash('sha256').update(b).digest('hex') }) + '\n');
  EOF

  seed() {
    rm -rf "$o"; mkdir -p "$o"
    for p in soc.html soc-decide.html; do
      echo "old $p" > "$o/$p"; echo '{"sha256":"old"}' > "$o/$p.passed"
    done
  }
  snap() { (cd "$o" && ls -A | sort && cat ./*) | sha256sum; }

  fail=0
  # arm <name> <MODE> <want exit> <want: same|promoted>
  arm() {
    seed; local before; before=$(snap)
    local rc=0
    MODE="$2" SANCTA_SOC_INDEX="$idx" SANCTA_SOC_OUT_DIR="$o" bash "$WRAPPER" > log 2>&1 || rc=$?
    local after; after=$(snap)
    local ok=1
    [ "$rc" -eq "$3" ] || ok=0
    if [ "$4" = same ]; then
      [ "$before" = "$after" ] || ok=0
    else
      for p in soc.html soc-decide.html; do
        grep -q '^new' "$o/$p" || ok=0
        [ "$(jq -r .sha256 "$o/$p.passed")" = "$(sha256sum "$o/$p" | cut -d' ' -f1)" ] || ok=0
      done
    fi
    # The stage directory must never outlive a run, pass or fail.
    if ls -A "$o" | grep -q '^\.soc-stage'; then ok=0; fi
    if [ "$ok" = 1 ]; then echo "ok   $1 (exit $rc)"; else
      echo "FAIL $1: exit $rc (want $3), want $4" >&2; sed 's/^/    | /' log >&2; ls -A "$o" >&2; fail=1; fi
  }

  arm "both pages pass -> both promoted with matching tokens" pass 0 promoted
  arm "gate FAIL on soc.html -> nothing replaced" leak-main 1 same
  arm "gate FAIL on soc-decide only -> soc.html NOT promoted either" leak-decide 1 same
  arm "gate CLOSED -> nothing replaced, exit 2 kept" closed-decide 2 same
  arm "generator fails closed -> nothing replaced" genfail 1 same
  arm "generator omits soc-decide -> nothing replaced" no-decide 2 same

  [ "$fail" = 0 ] || exit 1
  echo "sancta-soc-page: all arms passed" > $out
''
