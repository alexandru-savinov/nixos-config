Migrate OpenRouter from one shared agenix key to two scoped virtual keys (homelab/stable, homelab/experimental). File-edit slices only — `.age` encryption, OR dashboard work, and host deploys are manual gates outside this plan.

## Context

### Decisions baked in
- **Split:** `stable` = owui (sancta-choir) + openclaw+zdr-proxy (sancta-claw) + n8n (rpi5-full). `experimental` = hermes-agent (hermes-claw).
- **n8n is on `stable`.** If you decide n8n should be `experimental` instead, flip in two places: rpi5's `apiKeyFile` reference (Task 5) and the `publicKeys` lists in `secrets/secrets.nix` (Task 1).
- **gatus probe needs no OR key** — `GET /v1/models` is unauthenticated on OR. No gatus changes in this plan.
- **No `hermes-env.age` exists** — `hosts/hermes-claw/hermes-service.nix` composes its env at runtime from two separate agenix secrets. Migration is a single line change there.

### Consumer inventory

| Host | Consumer | File:line | Old secret | New secret |
|---|---|---|---|---|
| sancta-choir | open-webui | `hosts/sancta-choir/configuration.nix:70` | openrouter-api-key | openrouter-key-stable |
| sancta-claw | openclaw-zdr-proxy | `hosts/sancta-claw/configuration.nix:79` | openrouter-api-key | openrouter-key-stable |
| sancta-claw | openclaw auth-profiles inject | `hosts/sancta-claw/openclaw-service.nix:416` | openrouter-api-key | openrouter-key-stable |
| rpi5-full | n8n | `hosts/rpi5-full/configuration.nix:151` | openrouter-api-key | openrouter-key-stable |
| hermes-claw | hermes-agent env compose | `hosts/hermes-claw/hermes-service.nix:73` | openrouter-api-key | openrouter-key-experimental |

### Test fixtures that need updating
- `tests/module-eval.nix:572` hardcodes `/run/agenix/openrouter-api-key`
- `tests/module-eval.nix:600-607` asserts on that path
- Both must update to `openrouter-key-stable` in the same commit as the openclaw cutover (Task 3) so CI stays green.

### Repo conventions
- Work in a worktree, never on main: `git worktree add ../nixos-config-or-vkeys-c -b feat/or-vkeys-c-migration`
- Use `/nix-commit:commit` for every commit (runs `nix fmt` first; CI enforces format)
- Tasks 1-2 will leave `nix flake check` failing because `.age` files don't exist yet — that's expected, gated outside this plan
- Tasks 3-7 should pass `nix eval .#nixosConfigurations.<host>.config.system.build.toplevel` per touched host

### Manual gates (operator, outside ralphex)
- **Before Task 1**: in OR dashboard, create `homelab/stable` (cap $50/day or uncapped) and `homelab/experimental` (cap $5/day, $50 total). Note the `sk-or-v1-...` values.
- **After Task 2, before deploying**: `cd secrets && agenix -e openrouter-key-stable.age` (paste stable key value), then same for experimental. Commit and push the encrypted files.
- **After Task 6**: deploy each affected host in order — sancta-claw → hermes-claw → rpi5-full → sancta-choir. For x86_64 hosts: SSH in and `sudo nixos-rebuild switch --flake github:alexandru-savinov/nixos-config/<branch>#<host>`. After each, restart the relevant service (`systemctl restart openclaw-zdr-proxy`, etc.) — agenix doesn't always trigger restart on content-only changes. Verify in OR's dashboard that the new key label is receiving traffic.
- **Before Task 7**: 24-48h of normal operation. Then in OR's dashboard, rotate-then-revoke the legacy `openrouter-api-key`. Confirm zero new usage under the old key for 1 hour. Only then run Task 7.

### Out of scope
- ZDR allowlist refresh logic in `openclaw-zdr-proxy` stays unchanged — it still pulls from `/v1/endpoints/zdr` dynamically and is the primary ZDR enforcement.
- Aperture (`ai-1`) — separate setup, untouched by this migration.
- nullclaw on zero-kuzea — uses Anthropic key, not OpenRouter, unaffected.

## Tasks

### Task 1: Declare two new agenix secrets

- [ ] Read `secrets/secrets.nix` and verify the `let` block defines: `users`, `sancta-choir`, `rpi5`, `sancta-claw`, `hermes-claw`, `allPlusBoth`. If any are missing or renamed, stop and report.
- [ ] In `secrets/secrets.nix`, near the existing `"openrouter-api-key.age".publicKeys = allPlusBoth;` line (~line 73), add two new entries directly below it. Do NOT modify or remove the existing line:
  ```nix
  # Per-consumer OpenRouter virtual keys (Option C two-key split).
  # Coexists with openrouter-api-key.age during migration; legacy retires in cleanup task.
  "openrouter-key-stable.age".publicKeys       = users ++ [ sancta-choir sancta-claw rpi5 ];
  "openrouter-key-experimental.age".publicKeys = users ++ [ hermes-claw ];
  ```
- [ ] In `hosts/sancta-choir/configuration.nix`, find the `age.secrets` declaration block (around line 55 where `openrouter-api-key = secret "openrouter-api-key";` is). Add immediately below it (do NOT remove the legacy line): `openrouter-key-stable = secret "openrouter-key-stable";`
- [ ] In `hosts/rpi5-full/configuration.nix`, find the same pattern near line 94 and add: `openrouter-key-stable = secret "openrouter-key-stable";`
- [ ] In `hosts/sancta-claw/configuration.nix`, find the same pattern near line 73 and add: `openrouter-key-stable = secret "openrouter-key-stable";`
- [ ] In `hosts/hermes-claw/`, locate where `age.secrets` are declared for that host (could be `configuration.nix` or imported from `hermes-service.nix`). Add a declaration for `openrouter-key-experimental` using the host's existing helper/pattern. If no `secret = name: ...` helper exists on hermes-claw, use the full form: `age.secrets.openrouter-key-experimental.file = "${self}/secrets/openrouter-key-experimental.age";`
- [ ] Run `nix fmt` on all touched files.
- [ ] Commit with `/nix-commit:commit` — message: `feat(secrets): declare openrouter-key-stable and -experimental for vkey migration`
- [ ] **Do NOT run `nix flake check`** — it will fail because the `.age` files don't exist yet. That's expected; encryption is the next manual gate.

### Task 2: Update test fixtures for new secret path

- [ ] Read `tests/module-eval.nix` lines 560-630 to confirm the structure of the zdr-proxy wiring assertion.
- [ ] At line 572 (or wherever `apiKeyFile = "/run/agenix/openrouter-api-key";` appears in the zdr-proxy test block), change to `apiKeyFile = "/run/agenix/openrouter-key-stable";`.
- [ ] At the assertion block around lines 600-607, update the expected path string from `/run/agenix/openrouter-api-key` to `/run/agenix/openrouter-key-stable` and update the failure message accordingly.
- [ ] Read `tests/openclaw-zdr-proxy.nix` and `hosts/sancta-claw/smoke-test.nix` for any other hardcoded `openrouter-api-key` agenix path. If found, list them in the commit message but do NOT edit those tests unless they assert a path string (some references are about env-var names, which stay the same — do not touch those).
- [ ] Run `nix fmt` on touched files.
- [ ] Commit with `/nix-commit:commit` — message: `test(module-eval): update zdr-proxy apiKeyFile assertion for vkey migration`

### Task 3: Flip openclaw + zdr-proxy to stable (sancta-claw, risky-first)

- [ ] In `hosts/sancta-claw/configuration.nix:79`, change `apiKeyFile = config.age.secrets.openrouter-api-key.path;` to `apiKeyFile = config.age.secrets.openrouter-key-stable.path;`
- [ ] In `hosts/sancta-claw/openclaw-service.nix:416` (inside the `openclaw-inject-openrouter-auth` ExecStartPre script), change `KEY="$(cat ${config.age.secrets.openrouter-api-key.path})"` to `KEY="$(cat ${config.age.secrets.openrouter-key-stable.path})"`. Confirm these are the only two refs to the old secret path in the sancta-claw blast radius via grep before declaring complete.
- [ ] Run `nix fmt`.
- [ ] Run `nix eval .#nixosConfigurations.sancta-claw.config.system.build.toplevel >/dev/null` — must succeed (this validates evaluation but doesn't require `.age` files to exist).
- [ ] Commit with `/nix-commit:commit` — message: `feat(sancta-claw): point openclaw + zdr-proxy at openrouter-key-stable`

### Task 4: Flip hermes-agent to experimental (hermes-claw)

- [ ] In `hosts/hermes-claw/hermes-service.nix:73`, change the `OR_KEY=$(...)` line so it reads from `config.age.secrets.openrouter-key-experimental.path` instead of `config.age.secrets.openrouter-api-key.path`. The rest of `hermesAgentEnvBody` (BOT_TOKEN extraction, env file assembly, empty-key guards) must remain unchanged — only the OR_KEY source path differs.
- [ ] Confirm via grep that this is the only ref to `openrouter-api-key` inside `hosts/hermes-claw/` after the change.
- [ ] Run `nix fmt`.
- [ ] Run `nix eval .#nixosConfigurations.hermes-claw.config.system.build.toplevel >/dev/null` — must succeed.
- [ ] Commit with `/nix-commit:commit` — message: `feat(hermes-claw): point hermes-agent at openrouter-key-experimental`

### Task 5: Flip n8n and open-webui to stable

- [ ] In `hosts/rpi5-full/configuration.nix:151`, change `openrouterApiKeyFile = secret "openrouter-api-key";` to `openrouterApiKeyFile = secret "openrouter-key-stable";`
- [ ] In `hosts/sancta-choir/configuration.nix:70`, change `openai.apiKeyFile = config.age.secrets.openrouter-api-key.path;` to `openai.apiKeyFile = config.age.secrets.openrouter-key-stable.path;`
- [ ] Read `hosts/rpi5-full/configuration.nix:253` and the `external-openrouter` gatus endpoint definition in `modules/services/gatus.nix`. Confirm the probe does NOT pass an Authorization header (it should be a public `GET /v1/models`). If it DOES carry an auth header, do not change it — flag it in the commit message body and stop the task with a clear note that gatus key handling is out of scope for this plan and needs a separate decision.
- [ ] Run `nix fmt`.
- [ ] Run `nix eval .#nixosConfigurations.rpi5-full.config.system.build.toplevel >/dev/null` and same for sancta-choir — both must succeed.
- [ ] Commit with `/nix-commit:commit` — message: `feat(rpi5,sancta-choir): point n8n and open-webui at openrouter-key-stable`

### Task 6: Verify jq idempotency and OWUI filter upsert

This task is verification-first; only edit if a bug is found. Document findings in the commit message regardless.

- [ ] Read `hosts/sancta-claw/openclaw-service.nix` lines 410-450 (the `openclaw-inject-openrouter-auth` block). The jq filter modifies `auth-profiles.json`. Determine: does it REPLACE the `openrouter:zdr-proxy` profile (via `.profiles["openrouter:zdr-proxy"] = {...}`) or APPEND (via `+=` or array push)? If it replaces, no fix needed. If it appends, edit the jq filter to use assignment instead, so multiple restarts don't accumulate stale entries.
- [ ] Read `modules/services/open-webui.nix` lines 1467-1560 (the `openrouter_stats` filter install block). The OR key gets persisted into OWUI's SQLite as part of the filter's `valves`. Determine: does the install script always upsert the `openrouter_api_key` field on every service restart, or does it skip with `# already installed`? If it skips, modify it to always update `valves.openrouter_api_key` to the current key value on every restart, so a future agenix rotation propagates to OWUI's stored config. Do not change any other filter behavior.
- [ ] If either fix was needed, run `nix fmt` and document the change clearly in the commit message body, explaining what was wrong and why the fix is correct.
- [ ] If neither needed a fix, commit a one-line empty-ish commit IS NOT acceptable; instead, add a brief code comment near each verified block describing the idempotency guarantee found. Commit message: `chore(openclaw,owui): verify and document key-injection idempotency`
- [ ] Commit with `/nix-commit:commit`.

---

### MANUAL GATE — do not proceed to Task 7 until operator confirms

The operator must, outside ralphex, between Task 6 and Task 7:

1. Encrypt the two new `.age` files with real OR-generated virtual key values
2. Commit and push the encrypted files
3. Open PR, merge feature branch
4. Deploy in order: sancta-claw → hermes-claw → rpi5-full → sancta-choir
5. After each deploy, `systemctl restart` the relevant service (agenix doesn't auto-restart on content-only changes)
6. Verify in OR's dashboard that each consumer routes to the correct new key label
7. Run for 24-48h, confirm zero usage under legacy `openrouter-api-key`
8. In OR dashboard: rotate-then-revoke the legacy key, watch for 1h for 4xx auth errors anywhere
9. Only then re-launch ralphex to run Task 7

---

### Task 7: Retire legacy openrouter-api-key

- [ ] In `secrets/secrets.nix`, remove the line `"openrouter-api-key.age".publicKeys = allPlusBoth;`
- [ ] In `hosts/sancta-choir/configuration.nix`, remove `openrouter-api-key = secret "openrouter-api-key";` (was near line 55)
- [ ] In `hosts/rpi5-full/configuration.nix`, remove `openrouter-api-key = secret "openrouter-api-key";` (was near line 94)
- [ ] In `hosts/sancta-claw/configuration.nix`, remove `openrouter-api-key = secret "openrouter-api-key";` (was near line 73)
- [ ] Search the repo for any remaining references to `openrouter-api-key` (excluding the now-removed `.age` filename, test stubs that use the string as a literal identifier, and historical comments). If any production references remain, stop and report. If only test stubs remain (using the string as a fixture name, not an agenix path), leave them alone.
- [ ] `git rm secrets/openrouter-api-key.age`
- [ ] Verify `allPlusBoth` in `secrets/secrets.nix` still has at least one consumer (other secrets reference it). If not, leave the definition in place — removing helper definitions is out of scope.
- [ ] Update `SECRETS-ROTATION.md`: replace the OpenRouter section with the new two-key model. For each key, document: scope (which hosts decrypt), consumers (which services use it), rotation procedure (which hosts need redeploy + service restart).
- [ ] Run `nix fmt`.
- [ ] Run `nix flake check` — must pass now (all referenced `.age` files exist; legacy reference is gone).
- [ ] Commit with `/nix-commit:commit` — message: `feat(secrets): retire legacy openrouter-api-key after vkey migration`

## Constraints

- DO NOT touch any `.age` file. All encryption is manual and gated outside this plan.
- DO NOT run `nixos-rebuild` or any deploy command. Deploys are manual, per-host.
- DO NOT remove or modify the legacy `openrouter-api-key.age` declaration in Tasks 1-6 — it stays as fallback until Task 7.
- DO NOT modify the `let` block at the top of `secrets/secrets.nix` (the `users`, `systems`, key composites). Only add new entries to the secret attrset.
- DO NOT delete or rewrite the `openclaw-zdr-proxy` module. It owns dynamic ZDR allowlist enforcement and must keep working through this migration.
- DO NOT rename the `OPENROUTER_API_KEY` env var anywhere. n8n workflows, hermes container, and other consumers depend on that exact name. Only the agenix *source* path changes.
- DO NOT introduce new comments referencing this migration, task numbers, or PR numbers in production code. Code comments should explain timeless invariants only.
- DO NOT touch `tests/openclaw-zdr-proxy.nix` fixture data — it uses `etc."openrouter-test-key"` as a stub, unrelated to the production agenix path.
- DO NOT attempt to install the agenix CLI or run `agenix -e` anywhere — that's the operator's manual step.
- Each task ends with `/nix-commit:commit` (or `git commit` after running `nix fmt` manually if the slash command is unavailable in the agent context).
- Work in a worktree branch named `feat/or-vkeys-c-migration` or similar — never directly on `main`.
- If `nix flake check` fails during Tasks 1-6 with errors about missing `.age` files for `openrouter-key-stable` or `openrouter-key-experimental`, that's expected — note it and continue. The check will pass after the operator's manual encryption step.
