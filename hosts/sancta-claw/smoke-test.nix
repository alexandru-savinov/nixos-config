# Declarative smoke test for sancta-claw health verification
#
# Quick post-rebuild or post-restore sanity check.
# Verifies core services, secrets, and workspace files.
#
# Usage:
#   /etc/sancta-claw/smoke-test.sh

{ pkgs, ... }:

let
  smokeTestScript = pkgs.writeShellApplication {
    name = "sancta-claw-smoke-test";
    runtimeInputs = with pkgs; [ coreutils systemd tailscale ];
    text = ''
      set -euo pipefail

      PASS=0
      FAIL=0

      check() {
        local name="$1"
        shift
        if "$@" &>/dev/null; then
          echo "  PASS  $name"
          PASS=$((PASS + 1))
        else
          echo "  FAIL  $name"
          FAIL=$((FAIL + 1))
        fi
      }

      echo "=== sancta-claw smoke test ==="
      echo ""

      # Core services
      check "systemd: openclaw running" systemctl is-active --quiet openclaw
      check "systemd: tailscaled running" systemctl is-active --quiet tailscaled
      check "systemd: sshd running" systemctl is-active --quiet sshd

      # Tailscale connectivity
      check "tailscale: node online" "tailscale status --json | grep -q '\"BackendState\":\"Running\"'"

      # Agenix secrets decrypted
      check "agenix: secrets present (>=5)" test "$(find /run/agenix/ -type f 2>/dev/null | wc -l)" -ge 5

      # OpenClaw workspace files
      check "workspace: SOUL.md exists" test -f /var/lib/openclaw/.openclaw/workspace/SOUL.md
      check "workspace: MEMORY.md exists" test -f /var/lib/openclaw/.openclaw/workspace/MEMORY.md
      check "workspace: openclaw.json exists" test -f /var/lib/openclaw/.openclaw/openclaw.json

      # OpenClaw binary
      check "openclaw: binary installed" test -x /var/lib/openclaw/.npm-global/bin/openclaw

      # Git config
      check "git: .gitconfig exists" test -f /var/lib/openclaw/.gitconfig

      echo ""
      echo "Results: $PASS passed, $FAIL failed"

      if [ "$FAIL" -gt 0 ]; then
        exit 1
      fi
    '';
  };
in
{
  environment.etc."sancta-claw/smoke-test.sh" = {
    source = "${smokeTestScript}/bin/sancta-claw-smoke-test";
    mode = "0755";
  };
}
