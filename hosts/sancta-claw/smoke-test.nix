# Declarative smoke test for sancta-claw health verification
#
# Quick post-rebuild or post-restore sanity check.
# Verifies core services, secrets, and workspace files.
#
# Usage:
#   /etc/sancta-claw/smoke-test.sh

{ pkgs, ... }:

let
  smokeTestBody = ''
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
    echo

    # Core services
    check "systemd: openclaw running" systemctl is-active --quiet openclaw
    check "systemd: tailscaled running" systemctl is-active --quiet tailscaled
    check "systemd: sshd running" systemctl is-active --quiet sshd

    # Tailscale connectivity
    check "tailscale: node online" bash -c 'tailscale status --json | grep -q "BackendState.*Running"'

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

    # OpenClaw ZDR proxy + free+ZDR ladder verification
    check "openclaw: zdr proxy active" systemctl is-active --quiet openclaw-zdr-proxy
    check "openclaw: primary model is free+zdr" \
      bash -c 'jq -e ".agents.defaults.model.primary | test(\"^(qwen|z-ai|meta-llama|nousresearch|inclusionai|tencent|cognitivecomputations)/\")" /var/lib/openclaw/.openclaw/openclaw.json'
    check "openclaw: zdr proxy healthz" \
      curl -sf --max-time 5 http://127.0.0.1:5780/healthz
    # The proxy ignores the client `Authorization` header and uses its own
    # configured OPENROUTER_API_KEY (from agenix via EnvironmentFile), so a
    # placeholder bearer is sufficient here. This avoids leaking the real key
    # via argv (`ps auxww` / /proc/<pid>/cmdline) — bash's `$VAR` expansion
    # would inline a real secret into curl's command line before `execve`.
    # `bash -c` is used so the curl|jq pipeline runs as one shell command.
    # shellcheck disable=SC2016
    check "openclaw: end-to-end completion" \
      bash -c 'curl -sf --max-time 30 -X POST http://127.0.0.1:5780/v1/chat/completions -H "authorization: Bearer placeholder" -H "content-type: application/json" -d "{\"model\":\"qwen/qwen3-coder:free\",\"messages\":[{\"role\":\"user\",\"content\":\"reply with the single word OK\"}]}" | jq -e ".choices[0].message.content | test(\"OK\"; \"i\")"'

    echo
    echo "Results: $PASS passed, $FAIL failed"

    if [ "$FAIL" -gt 0 ]; then
      exit 1
    fi
  '';
  smokeTestScript = pkgs.writeShellApplication {
    name = "sancta-claw-smoke-test";
    runtimeInputs = with pkgs; [
      coreutils
      systemd
      tailscale
      curl
      jq
    ];
    text = smokeTestBody;
  };
in
{
  # Expose the rendered smoke-test body so the module-eval test can grep
  # for required check titles without IFD. Mirrors the
  # system.build.openclawBrowserConfigBody pattern in openclaw-service.nix.
  system.build.smokeTestBody = smokeTestBody;

  environment.etc."sancta-claw/smoke-test.sh" = {
    source = "${smokeTestScript}/bin/sancta-claw-smoke-test";
    mode = "0755";
  };
}
