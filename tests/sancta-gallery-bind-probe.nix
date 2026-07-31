# Behaviour coverage for modules/services/sancta-gallery-bind-probe.js.
#
# The eval test in tests/module-eval.nix proves the unit is ORDERED after
# tailscaled and that the probe is wired in. It cannot prove the probe
# discriminates correctly — and the discriminator is the whole point: a probe
# that exits 0 on EADDRNOTAVAIL never waits, and a probe that exits 1 on
# EADDRINUSE turns "the port is taken" into a 60s timeout with a misleading
# message. So the discriminator is exercised here, for real, against real
# sockets in the build sandbox.
#
# Run: nix build .#checks.<system>.sancta-gallery-bind-probe
{ pkgs }:

let
  probe = ../modules/services/sancta-gallery-bind-probe.js;
in
pkgs.runCommand "sancta-gallery-bind-probe-tests"
{
  nativeBuildInputs = [ pkgs.nodejs ];
} ''
    fails=0

    # Run the probe and assert its exit status. 1 means "address not here yet,
    # keep waiting"; 0 means "stop waiting, let ExecStart speak".
    expect() {
      local want="$1" bind="$2" what="$3" got=0
      GALLERY_BIND="$bind" node ${probe} || got=$?
      if [ "$got" = "$want" ]; then
        echo "  ok:   $what (exit $got)"
      else
        echo "  FAIL: $what — expected exit $want, got $got"
        fails=$((fails + 1))
      fi
    }

    echo "sancta-gallery bind probe:"

    # 1 — the address IS local: stop waiting.
    expect 0 127.0.0.1 "loopback is bindable -> proceed"

    # 2 — the boot race itself. 100.64.0.1 is inside Tailscale's CGNAT range and
    #     is NOT assigned in the build sandbox, so bind() gives EADDRNOTAVAIL.
    #     This is the case that must return 1; if it ever returns 0 the wait loop
    #     is decorative and the unit is back to racing tailscaled.
    expect 1 100.64.0.1 "unassigned tailnet address -> wait"

    # 3 — the discriminator, from the other side. Hold 127.0.0.1:8739 so the probe
    #     gets EADDRINUSE, not EADDRNOTAVAIL. The address IS local, so the answer
    #     must be "proceed" (exit 0) and NOT "wait" — otherwise a port conflict is
    #     reported as an absent tailnet address.
    node -e 'const s=require("net").createServer(); s.listen(8739,"127.0.0.1",()=>{setTimeout(()=>process.exit(0),20000)})' &
    holder=$!
    for _ in $(seq 1 50); do
      node -e 'const s=require("net").createServer();s.once("error",e=>process.exit(e.code==="EADDRINUSE"?0:1));s.listen(8739,"127.0.0.1",()=>s.close(()=>process.exit(1)))' && break
      sleep 0.1
    done
    expect 0 127.0.0.1 "port held (EADDRINUSE) -> proceed, not wait"
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true

    # 4 — a BROKEN probe must not look like "still waiting". Node exits 1 on an
    #     uncaught exception, which is the same code as EADDRNOTAVAIL, so without
    #     the explicit handler a probe bug would silently burn the whole timeout
    #     and then blame an absent tailnet address. Simulate by making `require`
    #     throw before the probe reaches its own handler-installed code path.
    cat > broken-probe.js <<'EOF'
    process.on("uncaughtException", () => process.exit(2));
    throw new Error("simulated probe bug");
  EOF
    got=0
    node broken-probe.js || got=$?
    if [ "$got" = 2 ]; then
      echo "  ok:   internal probe failure -> exit 2, not 1 (distinguishable from wait)"
    else
      echo "  FAIL: internal probe failure — expected exit 2, got $got"
      fails=$((fails + 1))
    fi

    # 4b — and the real probe must carry that handler, not just this fixture.
    if grep -q 'uncaughtException' ${probe} && grep -q 'FAIL_INTERNAL = 2' ${probe}; then
      echo "  ok:   the shipped probe installs the internal-failure handler"
    else
      echo "  FAIL: the shipped probe lost its uncaughtException -> exit 2 handler"
      fails=$((fails + 1))
    fi

    # 5 — no bind configured at all is a configuration error, not a wait state.
    got=0
    node ${probe} || got=$?
    if [ "$got" = 0 ]; then
      echo "  ok:   GALLERY_BIND unset -> proceed (exit 0)"
    else
      echo "  FAIL: GALLERY_BIND unset — expected exit 0, got $got"
      fails=$((fails + 1))
    fi

    if [ "$fails" -ne 0 ]; then
      echo "sancta-gallery-bind-probe: $fails case(s) FAILED" >&2
      exit 1
    fi
    echo "sancta-gallery-bind-probe: all 6 cases hold"
    echo ok > $out
''
