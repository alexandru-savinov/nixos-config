# Runs tests/test_soc_vigil_alarms.py against the exact script the units run.
# Both arms of each SOC alarm rule are driven from hand-built raw audit
# records, cscli JSON and fail2ban status text; see the test file's header.
{ pkgs }:

pkgs.runCommand "soc-vigil-alarms-tests"
{
  nativeBuildInputs = [ pkgs.python3 ];
}
  ''
    set -euo pipefail
    export SOC_VIGIL_ALARMS=${../modules/services/soc-vigil-alarms.py}
    python3 -W error::ResourceWarning ${./test_soc_vigil_alarms.py} 2>&1 | tee "$TMPDIR/log"
    status=''${PIPESTATUS[0]}
    if [ "$status" -ne 0 ]; then exit "$status"; fi
    grep -q '^OK$' "$TMPDIR/log"
    cp "$TMPDIR/log" "$out"
  ''
