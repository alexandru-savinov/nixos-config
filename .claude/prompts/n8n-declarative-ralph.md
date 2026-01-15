# Ralph Prompt: n8n Declarative Workflows & Credentials (Issue #94)

## Objective

Implement declarative workflow import and credential management for the `n8n-tailscale` NixOS module. Verify correctness using NixOS VM tests (the proper NixOS testing pattern).

## Context

- **Issue:** #94
- **Module:** `modules/services/n8n.nix`
- **Pattern to follow:** `tests/open-webui-tavily.nix` (NixOS VM test)

## Critical Technical Constraints

### DynamicUser + File Permissions

The n8n service uses `DynamicUser=true`. Key implications:

1. **EnvironmentFile** (`/run/n8n/env`): Read by systemd as root BEFORE dropping privileges. Current chmod 600 works because systemd reads it, not n8n.

2. **Credentials file**: n8n process (as DynamicUser) must READ this file at runtime.

   **Solution:** Copy to `/run/n8n/credentials.json` with chmod 644. The directory `/run/n8n` is mode 0700 owned by DynamicUser, so only DynamicUser (and root) can traverse to the file. World-readable file inside restricted directory = secure.

```bash
# In ExecStartPre (runs as root with + prefix):
cp "${cfg.credentialsFile}" /run/n8n/credentials.json
chmod 644 /run/n8n/credentials.json  # Safe: dir is 0700
echo "CREDENTIALS_OVERWRITE_DATA_FILE=/run/n8n/credentials.json" >> "$ENV_FILE"
```

### Workflow Import Timing

`n8n import:workflow` operates on the SQLite database directly. Two options:

1. **Separate oneshot service** (preferred): Runs after n8n.service, ensures DB exists
2. **ExecStartPost**: Runs after ExecStart begins but n8n might not be ready

Use **separate service** pattern (like `tailscale-serve-n8n`) for reliability.

## Implementation Specification

### 1. New Options (`modules/services/n8n.nix`)

```nix
# Add to options.services.n8n-tailscale:

credentialsFile = mkOption {
  type = types.nullOr types.path;
  default = null;
  example = lib.literalExpression "config.age.secrets.n8n-credentials.path";
  description = ''
    Path to JSON file containing n8n credential overwrites.
    The file is copied to /run/n8n/credentials.json at startup.

    Format: { "credentialType": { "field": "value", ... }, ... }

    Common credential types:
      - httpHeaderAuth: { "name": "Header-Name", "value": "header-value" }
      - httpBasicAuth: { "user": "...", "password": "..." }
      - oAuth2Api: { "clientId": "...", "clientSecret": "..." }
      - slackApi: { "accessToken": "xoxb-..." }
      - telegramApi: { "accessToken": "123:ABC..." }

    SECURITY: Use agenix, NOT a file in the Nix store!
      credentialsFile = config.age.secrets.n8n-credentials.path;
  '';
};

workflows = mkOption {
  type = types.listOf types.path;
  default = [];
  example = lib.literalExpression "[ ./workflows/backup.json ]";
  description = ''
    List of workflow JSON files to import on service startup.

    IMPORTANT: Each workflow JSON MUST have a stable "id" field!
    Without an ID, n8n generates a random one, causing duplicates on re-import.

    Workflows are imported as-is, including their "active" state.
    Set "active": true in JSON for scheduled/webhook workflows to run.

    Export from n8n UI: Menu → Download workflow.
  '';
};

workflowsDir = mkOption {
  type = types.nullOr types.path;
  default = null;
  example = lib.literalExpression "../../n8n-workflows";
  description = ''
    Directory containing workflow JSON files (*.json) to import.
    All JSON files in this directory are imported on startup.

    Same requirements as 'workflows': each file must have stable "id" field.
  '';
};

extraEnvironment = mkOption {
  type = types.attrsOf types.str;
  default = {};
  example = lib.literalExpression ''{ N8N_TEMPLATES_ENABLED = "false"; }'';
  description = ''
    Additional environment variables for n8n.
    Useful for enabling features not covered by this module.

    Example: Enable public API for external integrations:
      extraEnvironment.N8N_PUBLIC_API_DISABLED = "false";
  '';
};
```

**IMPORTANT:** All options use `lib.` prefix functions. Ensure these are in scope:
```nix
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption mkEnableOption types mkIf optionalString
                optionalAttrs concatMapStringsSep literalExpression
                hasPrefix mapAttrsToList concatStringsSep;
  cfg = config.services.n8n-tailscale;
in
```

### 2. Security Assertion (prevent Nix store credentials)

```nix
# Add to config = mkIf cfg.enable { ... }:
assertions = [
  {
    assertion = cfg.credentialsFile == null ||
                !(lib.hasPrefix "/nix/store" (toString cfg.credentialsFile));
    message = ''
      services.n8n-tailscale.credentialsFile points to the Nix store!
      Files in /nix/store are WORLD-READABLE. Your credentials would be exposed.

      Use agenix instead:
        age.secrets.n8n-credentials.file = ./secrets/n8n-credentials.age;
        services.n8n-tailscale.credentialsFile = config.age.secrets.n8n-credentials.path;
    '';
  }
];
```

### 3. Credentials Injection (in ExecStartPre)

Add to the existing `n8n-setup-env` script:

```nix
# After encryption key handling, before chmod:
${optionalString (cfg.credentialsFile != null) ''
  if [[ ! -f "${cfg.credentialsFile}" ]]; then
    echo "ERROR: Credentials file not found: ${cfg.credentialsFile}" >&2
    exit 1
  fi
  # Validate JSON syntax before copying (fail fast)
  if ! ${pkgs.jq}/bin/jq empty "${cfg.credentialsFile}" 2>/dev/null; then
    echo "ERROR: Credentials file is not valid JSON: ${cfg.credentialsFile}" >&2
    exit 1
  fi
  # Copy to runtime dir - chmod 644 is safe because dir is 0700
  cp "${cfg.credentialsFile}" /run/n8n/credentials.json
  chmod 644 /run/n8n/credentials.json
  echo "CREDENTIALS_OVERWRITE_DATA_FILE=/run/n8n/credentials.json" >> "$ENV_FILE"
  echo "Credentials file configured: /run/n8n/credentials.json"
''}
```

### 4. Extra Environment Variables (in ExecStartPre)

Add to the existing `n8n-setup-env` script, after credentials handling:

```nix
# Write extra environment variables to env file
${concatStringsSep "\n" (mapAttrsToList (name: value: ''
  echo "${name}=${value}" >> "$ENV_FILE"
'') cfg.extraEnvironment)}
```

### 5. Workflow Import (ExecStartPost - CRITICAL: must use same user context)

**Why ExecStartPost, not a separate service:**
- n8n uses DynamicUser - database is at `/var/lib/n8n/`
- A separate service running as root would use `/root/.n8n/` (WRONG database!)
- ExecStartPost runs as the SAME DynamicUser, accessing the CORRECT database

**CRITICAL: Do NOT use `mkIf` directly on serviceConfig attributes!**

```nix
# WRONG - mkIf doesn't work on serviceConfig attributes!
# serviceConfig.ExecStartPost = mkIf condition [...];

# CORRECT - use optionalAttrs to conditionally add the attribute:
systemd.services.n8n = {
  serviceConfig = {
    # ... existing ExecStartPre, RuntimeDirectory, etc ...
  } // lib.optionalAttrs (cfg.workflows != [] || cfg.workflowsDir != null) {
    ExecStartPost = [
      (pkgs.writeShellScript "n8n-import-workflows" ''
        set -euo pipefail

        # Wait for n8n to be FULLY ready (not just port open)
        # Using healthz endpoint is more reliable than just port check
        echo "Waiting for n8n to be ready..."
        timeout=120
        while ! ${pkgs.curl}/bin/curl -sf http://127.0.0.1:${toString cfg.port}/healthz >/dev/null 2>&1; do
          # Fallback: also accept 200 from root path
          if ${pkgs.curl}/bin/curl -sf http://127.0.0.1:${toString cfg.port}/ >/dev/null 2>&1; then
            break
          fi
          timeout=$((timeout - 1))
          if [ $timeout -le 0 ]; then
            echo "WARNING: n8n not ready after 120 seconds, skipping workflow import"
            exit 0  # Don't fail the service
          fi
          sleep 1
        done

        # Brief delay for database initialization
        sleep 2

        echo "Importing declarative workflows..."

        # Import individual workflow files
        ${concatMapStringsSep "\n" (wf: ''
          echo "Importing: ${wf}"
          if ! ${pkgs.n8n}/bin/n8n import:workflow --input="${wf}" 2>&1; then
            echo "WARNING: Failed to import ${wf} - check JSON syntax and 'id' field"
          fi
        '') cfg.workflows}

        # Import all workflows from directory
        ${optionalString (cfg.workflowsDir != null) ''
          for wf in ${cfg.workflowsDir}/*.json; do
            if [ -f "$wf" ]; then
              echo "Importing: $wf"
              if ! ${pkgs.n8n}/bin/n8n import:workflow --input="$wf" 2>&1; then
                echo "WARNING: Failed to import $wf - check JSON syntax and 'id' field"
              fi
            fi
          done
        ''}

        echo "Workflow import complete"
      '')
    ];
  };
};
```

**Important notes:**
- ExecStartPost inherits service credentials (same DynamicUser) → correct database access
- ExecStartPost also inherits the EnvironmentFile → has access to N8N_ENCRYPTION_KEY, CREDENTIALS_OVERWRITE_DATA_FILE, etc.
- Uses `curl` healthz check (more reliable than port check with `nc`)
- Uses `lib.optionalAttrs` to conditionally add ExecStartPost (NOT `mkIf`!)

**Workflow active state behavior:**
- Workflows with `"active": true` will **immediately start** after import
- This includes scheduled triggers, webhook listeners, polling triggers
- For webhooks: n8n uses `N8N_WEBHOOK_URL` if set, otherwise constructs from host/port
- Recommendation: Import with `"active": false` initially, activate via UI after verifying

### 6. NixOS VM Test (`tests/n8n-declarative.nix`)

```nix
{ pkgs ? import <nixpkgs> { } }:

pkgs.testers.nixosTest {
  name = "n8n-declarative-test";

  nodes.machine = { config, pkgs, ... }: {
    imports = [ ../modules/services/n8n.nix ];

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
      id = "test-declarative-import";  # REQUIRED for idempotency
      name = "Test Declarative Import";
      nodes = [
        {
          id = "start";
          name = "Start";
          type = "n8n-nodes-base.manualTrigger";
          typeVersion = 1;
          position = [ 250 300 ];
          parameters = {};
        }
      ];
      connections = {};
      active = false;
      settings = {};
    };

    services.n8n-tailscale = {
      enable = true;
      encryptionKeyFile = "/etc/n8n-encryption-key";
      credentialsFile = "/etc/n8n-credentials.json";
      workflows = [ "/etc/n8n-test-workflow.json" ];
      tailscaleServe.enable = false;  # No tailscale in test VM
    };

    networking.firewall.allowedTCPPorts = [ 5678 ];
  };

  testScript = ''
    start_all()

    # Wait for n8n service to be active
    machine.wait_for_unit("n8n.service")
    machine.wait_for_open_port(5678)

    # Give ExecStartPost time to run (workflow import)
    machine.sleep(10)

    # Get n8n process PID
    pid = machine.succeed("systemctl show --property MainPID --value n8n.service").strip()

    # 1. Verify credentials file env var is set
    print("Checking credentials env var...")
    machine.succeed(f"grep -z 'CREDENTIALS_OVERWRITE_DATA_FILE=/run/n8n/credentials.json' /proc/{pid}/environ")

    # 2. Verify credentials file exists and is readable
    print("Checking credentials file...")
    machine.succeed("test -f /run/n8n/credentials.json")
    machine.succeed("cat /run/n8n/credentials.json | grep -q 'X-Test-Auth'")

    # 3. Verify workflow import ran (check journal for import messages)
    print("Checking workflow import log...")
    machine.succeed("journalctl -u n8n.service | grep -q 'Importing declarative workflows' || journalctl -u n8n.service | grep -q 'import:workflow'")

    # 4. Verify n8n responds (basic health check)
    print("Checking n8n health...")
    machine.succeed("curl -sf http://127.0.0.1:5678/ | head -c 100")

    # 5. CRITICAL: Verify workflow was ACTUALLY imported via n8n API
    # This catches issues where import runs but fails silently
    print("Verifying workflow exists in n8n...")
    result = machine.succeed("curl -sf http://127.0.0.1:5678/api/v1/workflows 2>/dev/null || echo '{}'")
    assert "test-declarative-import" in result or "Test Declarative Import" in result, \
        f"Workflow not found in n8n! API returned: {result[:200]}"

    print("All n8n declarative tests passed!")
  '';
}
```

### 7. Test Artifacts (Workflow JSON MUST have stable ID)

**CRITICAL: Workflow JSON MUST include a stable `id` field!**

Without an `id`, n8n generates a random one. On re-import, a NEW workflow is created (duplicate).
With a stable `id`, n8n updates the existing workflow (idempotent).

**`n8n-workflows/example-webhook-handler.json`** (example workflow for users):
```json
{
  "id": "example-webhook-handler",
  "name": "Example Webhook Handler",
  "nodes": [
    {
      "id": "webhook-1",
      "name": "Webhook Trigger",
      "type": "n8n-nodes-base.webhook",
      "typeVersion": 1,
      "position": [250, 300],
      "webhookId": "example-webhook",
      "parameters": {
        "path": "example",
        "httpMethod": "POST"
      }
    },
    {
      "id": "respond-1",
      "name": "Respond",
      "type": "n8n-nodes-base.respondToWebhook",
      "typeVersion": 1,
      "position": [450, 300],
      "parameters": {
        "respondWith": "json",
        "responseBody": "={{ JSON.stringify({ received: true, timestamp: Date.now() }) }}"
      }
    }
  ],
  "connections": {
    "Webhook Trigger": {
      "main": [[{ "node": "Respond", "type": "main", "index": 0 }]]
    }
  },
  "active": false,
  "settings": {}
}
```

## Verification Commands

Run after EACH iteration (fast checks first):

```bash
# 1. FAST syntax check (use eval, not full flake check)
echo "=== Quick eval check ==="
nix eval .#nixosConfigurations.sancta-choir.config.system.build.toplevel --apply 'x: "Config evaluates OK"' 2>&1 | tail -3

# 2. Options exist (MUST return type info, not error)
echo "=== Checking new options ==="
nix eval .#nixosConfigurations.sancta-choir.options.services.n8n-tailscale.credentialsFile.type 2>&1 | head -1
nix eval .#nixosConfigurations.sancta-choir.options.services.n8n-tailscale.workflows.type 2>&1 | head -1
nix eval .#nixosConfigurations.sancta-choir.options.services.n8n-tailscale.workflowsDir.type 2>&1 | head -1
nix eval .#nixosConfigurations.sancta-choir.options.services.n8n-tailscale.extraEnvironment.type 2>&1 | head -1

# 3. Validate JSON files exist and have required fields
echo "=== Validating JSON files ==="
python3 -c "
import json, sys
f = 'n8n-workflows/example-webhook-handler.json'
try:
    data = json.load(open(f))
    assert 'id' in data, 'Missing id field (required for idempotency)'
    assert 'name' in data, 'Missing name field'
    assert 'nodes' in data, 'Missing nodes field'
    print(f'OK: {f} (id={data[\"id\"]})')
except Exception as e:
    print(f'FAIL: {f} - {e}')
    sys.exit(1)
"

# 4. VM test file exists and is valid Nix
echo "=== Checking VM test ==="
test -f tests/n8n-declarative.nix && nix-instantiate --parse tests/n8n-declarative.nix > /dev/null 2>&1 && echo "OK: VM test parses" || echo "FAIL: VM test missing or invalid"

# 5. Check ExecStartPost is configured (when workflows specified)
echo "=== Checking ExecStartPost ==="
nix eval .#nixosConfigurations.sancta-choir.config.systemd.services.n8n.serviceConfig.ExecStartPost --json 2>&1 | head -1

# 6. FULL check (run less frequently - slow)
# echo "=== Full flake check ==="
# nix flake check 2>&1 | tail -10
```

## Completion Criteria (ALL must be true)

1. **Config evaluates** without error:
   ```bash
   nix eval .#nixosConfigurations.sancta-choir.config.system.build.toplevel
   ```

2. **All four options exist** with correct types:
   - `credentialsFile` → `types.nullOr types.path`
   - `workflows` → `types.listOf types.path`
   - `workflowsDir` → `types.nullOr types.path`
   - `extraEnvironment` → `types.attrsOf types.str`

3. **Security assertion exists** preventing Nix store credentials

4. **ExecStartPre** contains credentials logic:
   - Validates JSON with `jq` before copying
   - Copies credentialsFile to `/run/n8n/credentials.json`
   - Sets `chmod 644`
   - Writes `CREDENTIALS_OVERWRITE_DATA_FILE` to env file
   - Writes `extraEnvironment` vars to env file

5. **ExecStartPost** contains workflow import logic (NOT a separate service):
   - Wait loop for n8n to be ready (healthz check with curl)
   - Uses `${pkgs.n8n}/bin/n8n import:workflow`
   - Iterates over `cfg.workflows` and `cfg.workflowsDir`

6. **`n8n-workflows/` directory** exists with at least one workflow JSON that:
   - Has stable `id` field
   - Has `name`, `nodes`, `connections` fields
   - Is valid JSON

7. **`tests/n8n-declarative.nix`** exists and:
   - Parses as valid Nix
   - Follows `pkgs.testers.nixosTest` pattern
   - Verifies credential env var and file
   - Waits for n8n service
   - **Verifies workflow exists via n8n API** (not just import ran)

8. **`nix flake check`** passes (run at end)

## Completion Signal

When ALL criteria above are verified, output:

```
<promise>N8N_DECLARATIVE_COMPLETE</promise>
```

## Implementation Order (follow strictly)

1. **First:** Add options to `modules/services/n8n.nix` (credentialsFile, workflows, workflowsDir, extraEnvironment)
2. **Second:** Add security assertion
3. **Third:** Modify ExecStartPre for credentials injection (with JSON validation)
4. **Fourth:** Modify ExecStartPre for extraEnvironment handling
5. **Fifth:** Add ExecStartPost for workflow import
6. **Sixth:** Create `n8n-workflows/` directory with example workflow
7. **Seventh:** Create `tests/n8n-declarative.nix`
8. **Last:** Run `nix flake check` for final validation

**Verify after EACH step** using the verification commands above.

## Anti-Patterns to Avoid

- ❌ **Don't use separate systemd service for workflow import** - wrong database! Use ExecStartPost
- ❌ Don't use pytest/Docker for testing - use NixOS VM test pattern
- ❌ Don't rely on external services (httpbin.org) - mock everything locally
- ❌ Don't assume credentials file is readable by DynamicUser - copy it first
- ❌ Don't test n8n functionality - test that MODULE generates correct config
- ❌ Don't create workflows without stable `id` field - causes duplicates on re-import
- ❌ Don't allow credentialsFile in /nix/store - world-readable!

## Files to Create/Modify

| File | Action | Purpose |
|------|--------|---------|
| `modules/services/n8n.nix` | Modify | Add options, assertion, credentials, workflow import |
| `n8n-workflows/example-webhook-handler.json` | Create | Example workflow with stable ID |
| `tests/n8n-declarative.nix` | Create | NixOS VM test |

## Reference: Existing Patterns

- `tests/open-webui-tavily.nix` - NixOS VM test pattern
- `modules/services/n8n.nix` lines 135-183 - ExecStartPre pattern (credentials injection goes here)
- `modules/services/n8n.nix` lines 108-116 - Existing assertions/warnings pattern

## Key Nix Functions Needed

```nix
lib.optionalString      # Conditional string in scripts
lib.optionalAttrs       # Conditionally add attributes (USE THIS for ExecStartPost!)
lib.mkIf                # Conditional config (but NOT for serviceConfig attrs!)
lib.hasPrefix           # String prefix check (for assertion)
lib.concatMapStringsSep # Iterate workflows with separator
lib.concatStringsSep    # Join strings with separator
lib.mapAttrsToList      # Convert attrset to list (for extraEnvironment)
lib.literalExpression   # For option examples
types.nullOr            # Optional type
types.nullOr types.path # For credentialsFile, workflowsDir
types.listOf types.path # For workflows list
types.attrsOf types.str # For extraEnvironment
pkgs.jq                 # JSON validation for credentials file
pkgs.curl               # Health check for n8n readiness
```

**WARNING about mkIf:**
```nix
# WRONG - causes issues with serviceConfig attributes:
serviceConfig.ExecStartPost = lib.mkIf condition [ ... ];

# CORRECT - use optionalAttrs to conditionally add:
serviceConfig = { ... } // lib.optionalAttrs condition {
  ExecStartPost = [ ... ];
};
```

---

**Start by reading `modules/services/n8n.nix` lines 1-120 to understand option patterns, then implement incrementally. Verify after EACH modification.**
