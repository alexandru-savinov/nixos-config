# NixOS integration test for the OpenClaw ZDR enforcement proxy.
#
# Boots a single VM that runs:
#   - the proxy (modules/services/openclaw-zdr-proxy.nix)
#   - a stub OpenRouter (tests/stubs/openrouter_stub.py) on :9999
#
# Verifies end-to-end:
#   1. Proxy starts and serves /healthz after lazily refreshing the
#      ZDR allow-list from the stub.
#   2. A POST through the proxy reaches the upstream with provider.zdr=true
#      injected on the wire (introspected via the stub's /__last_payload).
#   3. A model not present in the ZDR allow-list is rejected with HTTP 4xx
#      before the request ever leaves the proxy.
#
# Wired into flake.nix as `checks.x86_64-linux.openclaw-zdr-proxy`. Returns
# the test args; flake.nix wraps with `pkgs.testers.nixosTest`.

{ pkgs }:

let
  pythonStubEnv = pkgs.python3.withPackages (ps: with ps; [ flask ]);
in
{
  name = "openclaw-zdr-proxy-test";

  nodes.machine =
    { config, pkgs, ... }:
    {
      imports = [ ../modules/services/openclaw-zdr-proxy.nix ];

      # The proxy unit runs as user `openclaw`. In production this user is
      # created by openclaw-service.nix on sancta-claw; in this isolated test
      # we provision it minimally.
      users.users.openclaw = {
        isSystemUser = true;
        group = "openclaw";
        home = "/var/lib/openclaw";
        createHome = true;
      };
      users.groups.openclaw = { };

      # Mock OpenRouter API key. The proxy's ExecStartPre reads this raw value
      # (no `KEY=` prefix) and translates it into an EnvironmentFile.
      environment.etc."openrouter-test-key".text = "sk-test";

      # Stub OpenRouter on :9999. Listens on 127.0.0.1 by default
      # (see tests/stubs/openrouter_stub.py `__main__`).
      systemd.services.openrouter-stub = {
        description = "Stub OpenRouter API for nixosTest";
        wantedBy = [ "multi-user.target" ];
        before = [ "openclaw-zdr-proxy.service" ];
        environment.PORT = "9999";
        serviceConfig = {
          ExecStart = "${pythonStubEnv}/bin/python ${./stubs/openrouter_stub.py}";
          Restart = "on-failure";
        };
      };

      services.openclaw-zdr-proxy = {
        enable = true;
        apiKeyFile = "/etc/openrouter-test-key";
        # Stub registers /v1/endpoints/zdr, /v1/chat/completions, etc.
        upstreamUrl = "http://127.0.0.1:9999/v1";
        allowListCacheTtl = 60;
      };
    };

  testScript = ''
    start_all()

    # 1. Stub up first — the proxy will fetch the ZDR allow-list from it.
    machine.wait_for_unit("openrouter-stub.service")
    machine.wait_for_open_port(9999)

    # 2. Proxy up.
    machine.wait_for_unit("openclaw-zdr-proxy.service")
    machine.wait_for_open_port(5780)

    # 3. /healthz triggers a lazy refresh against the stub. After this call
    #    at least one gunicorn worker has a populated allow-list cache.
    machine.succeed("curl -sf --max-time 10 http://127.0.0.1:5780/healthz")

    # 4. POST a ZDR-allowed model. Use a file so JSON quoting can't trip up
    #    the test shell. The proxy must inject provider.zdr=true and forward.
    machine.succeed(
        "printf '%s' "
        "'{\"model\":\"qwen/qwen3-coder:free\","
        "\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}' "
        "> /tmp/zdr-req.json"
    )
    out = machine.succeed(
        "curl -sf --max-time 15 -X POST "
        "-H 'authorization: Bearer sk-test' "
        "-H 'content-type: application/json' "
        "--data @/tmp/zdr-req.json "
        "http://127.0.0.1:5780/v1/chat/completions"
    )
    assert "choices" in out, f"chat completion missing choices: {out!r}"

    # 5. Verify the upstream stub recorded provider.zdr=true on the wire.
    last = machine.succeed("curl -sf http://127.0.0.1:9999/__last_payload").strip()
    assert '"zdr": true' in last, f"ZDR flag missing from upstream payload: {last}"

    # 6. Non-ZDR model must be rejected by the proxy. curl -f exits non-zero
    #    on 4xx, so machine.fail captures the rejection.
    machine.succeed(
        "printf '%s' "
        "'{\"model\":\"openrouter/gpt-4o-32k\","
        "\"messages\":[{\"role\":\"user\",\"content\":\"x\"}]}' "
        "> /tmp/non-zdr-req.json"
    )
    machine.fail(
        "curl -sf --max-time 15 -X POST "
        "-H 'authorization: Bearer sk-test' "
        "-H 'content-type: application/json' "
        "--data @/tmp/non-zdr-req.json "
        "http://127.0.0.1:5780/v1/chat/completions"
    )

    print("openclaw-zdr-proxy nixosTest passed: ZDR injection and rejection verified")
  '';
}
