{ pkgs ? import <nixpkgs> { }
, # Repo root — the n8n module reads ''${self}/scripts/generate-apkg.py.
  # The flake passes its real `self`; the default works for standalone runs.
  self ? ../.
,
}:

pkgs.testers.nixosTest {
  name = "n8n-declarative-test";

  nodes.machine = { config, pkgs, ... }: {
    imports = [ ../modules/services/n8n.nix ];

    # The n8n module takes `self` as a module argument (this nixpkgs'
    # makeTest has no node.specialArgs, so inject via _module.args).
    _module.args.self = self;

    # NOTE: n8n is unfree (Sustainable Use License). The pkgs instance passed
    # in must be created with config.allowUnfree = true (flake.nix nixpkgsFor
    # does this) — setting nixpkgs.config here would conflict with the
    # externally created instance the test framework injects.

    # Mock secrets (plaintext for testing)
    environment.etc."n8n-encryption-key".text = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    environment.etc."n8n-credentials.json".text = builtins.toJSON {
      httpHeaderAuth = {
        name = "X-Test-Auth";
        value = "test-credential-value-12345";
      };
    };

    # Test workflow (minimal valid workflow - MUST have stable id!)
    environment.etc."n8n-test-workflow.json".text = builtins.toJSON {
      id = "test-declarative-import"; # REQUIRED for idempotency
      name = "Test Declarative Import";
      nodes = [
        {
          id = "start";
          name = "Start";
          type = "n8n-nodes-base.manualTrigger";
          typeVersion = 1;
          position = [ 250 300 ];
          parameters = { };
        }
      ];
      connections = { };
      active = false;
      settings = { };
    };

    services.n8n-tailscale = {
      enable = true;
      encryptionKeyFile = "/etc/n8n-encryption-key";
      credentialsFile = "/etc/n8n-credentials.json";
      workflows = [ "/etc/n8n-test-workflow.json" ];
      tailscaleServe.enable = false; # No tailscale in test VM
      # Enable public API for testing workflow verification
      extraEnvironment.N8N_PUBLIC_API_DISABLED = "false";
    };

    # sqlite3 for verifying workflow import
    environment.systemPackages = [ pkgs.sqlite ];

    networking.firewall.allowedTCPPorts = [ 5678 ];
  };

  testScript = ''
    start_all()

    # Wait for n8n service to be active
    machine.wait_for_unit("n8n.service")
    machine.wait_for_open_port(5678)

    # Workflow import runs in the dedicated n8n-workflow-sync.service (not
    # n8n.service ExecStartPost as in earlier module versions). Wait for its
    # completion message instead of sleeping a fixed interval.
    print("Waiting for workflow import to complete...")
    machine.wait_until_succeeds(
        "journalctl -u n8n-workflow-sync.service | grep -q 'Workflow import complete'",
        timeout=300,
    )

    # The sync unit restarts n8n after import (webhook registration) —
    # re-await the service before poking at its process.
    machine.wait_for_unit("n8n.service")
    machine.wait_for_open_port(5678)

    # Get n8n process PID
    pid = machine.succeed("systemctl show --property MainPID --value n8n.service").strip()

    # 1. Verify credentials file env var is set
    print("Checking credentials env var...")
    machine.succeed(f"grep -z 'CREDENTIALS_OVERWRITE_DATA_FILE=/run/n8n/credentials.json' /proc/{pid}/environ")

    # 2. Verify credentials file exists and is readable
    print("Checking credentials file...")
    machine.succeed("test -f /run/n8n/credentials.json")
    machine.succeed("cat /run/n8n/credentials.json | grep -q 'X-Test-Auth'")

    # 3. Show import logs for debugging
    import_logs = machine.succeed("journalctl -u n8n-workflow-sync.service --no-pager | grep -E '(Import|import|workflow)' || echo 'No import logs found'")
    print(f"Import logs: {import_logs}")

    # 4. Verify n8n responds (basic health check). Use /healthz — the same
    # endpoint the module gates on; GET / can return a non-200 while the
    # app is still warming up after the post-import restart.
    print("Checking n8n health...")
    machine.wait_until_succeeds("curl -sf http://127.0.0.1:5678/healthz", timeout=120)

    # 5. CRITICAL: Verify workflow was ACTUALLY imported
    # The API requires authentication, so check via database or CLI export
    print("Verifying workflow exists in n8n database...")
    # Use sqlite3 to query the workflow table directly
    result = machine.succeed("sqlite3 /var/lib/n8n/.n8n/database.sqlite \"SELECT name FROM workflow_entity WHERE id='test-declarative-import' OR name='Test Declarative Import';\"")
    print(f"Database query result: {result}")
    assert "Test Declarative Import" in result, \
        f"Workflow not found in database! Query returned: {result}"

    print("All n8n declarative tests passed!")
  '';
}
