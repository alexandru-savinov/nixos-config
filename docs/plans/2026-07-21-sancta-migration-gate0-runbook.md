# Sancta migration Gate 0 — pinned-commit E2E runbook

**Status:** PREPARED / NOT AUTHORIZED FOR LIVE EXECUTION
**Date:** 2026-07-21
**Last verified:** 2026-07-22
**Scope:** migration prerequisite for issue #537; no ingestion-membrane implementation

## Verdict and stop conditions

Gate 0 is currently **FAIL / incomplete**. Gate 0-A is the migration proof in Phases 1–5; Gate 0-B is the human-gated aggregate-presence proof in Phase 6. Gate 0-A may run and produce its own PASS/FAIL record while Gate 0-B remains unresolved, but issue #537 implementation stays blocked until both pass and the final composite regression is green.

- PR #538 remains open at `0d2eedaee91aa4e60cfe7ae7c16f83b620ab3e04`.
- The required exact-source, Home Manager, worker-order, pure-regression, relay-crash, and booted-VM work exists only in the dirty local tree; `tests/sancta-soul-volume.nix` and this runbook are untracked.
- The VM package derivation evaluates through a `path:` flake, but ordinary Git-flake evaluation cannot see the untracked VM file, and neither the VM nor crash suite has a recorded successful build/run or exact-SHA CI result.
- No merged `main` commit contains the complete candidate.
- No attended deploy/reboot, real resumed-Claude round trip, or aggregate-presence E2E has been recorded for that candidate.
- The aggregate-presence path is docs-only and human-gated; no broker, client, firewall/ACL proof, or test exists.

Stop the active phase immediately if any command fails, any expected value differs, the worktree is dirty at the selected commit, the live host cannot identify the prior generation, console recovery is unavailable, or a secret would enter a log/chat/argv. Unresolved Home Assistant decisions block Phase 6 and overall Gate 0—not the separately recorded migration-only Phases 1–5. Do not treat a skipped unit, empty output, zero-capability test, generic HA operation, or a successful fake-Claude test as a pass.

Deployment, reboot, symlink moves, the billed `/send`, household-presence actions, key/ACL changes, and rollback are Alexandru-authorized steps. Agents may prepare and review evidence only.

## Fixed identifiers and evidence directory

The executor records, without guessing:

- `MIGRATION_SHA`: the exact 40-character commit on `origin/main` containing PR #538's complete source, mount, ordering, and regression fixes;
- `MIGRATION_TOPLEVEL`: the exact built `sancta-choir` toplevel store path for `MIGRATION_SHA`;
- `FINAL_GATE_SHA`: the later exact `origin/main` commit containing both Gate 0-A and the authorized Gate 0-B implementation, used for the final composite regression;
- `PRIOR_SYSTEM`: `/run/current-system` before staging;
- `PRIOR_GENERATION`: the bootable generation number before staging;
- `BOOT_ID_BEFORE` and `BOOT_ID_AFTER`;
- `SESSION_ID`: `666bcb25-8bc5-467a-b603-4eecce495341`, unless a reviewed config change deliberately replaces it; and
- a fresh local evidence directory containing only redacted outputs, hashes, counts, paths, and pass/fail markers.

Create the evidence directory outside every repository with `umask 077`. Never copy age plaintext, API/OAuth tokens, the membrane Basic password, live household presence, raw replies, or transcript content into evidence. The deliberately harmless allowlisted challenge may be recorded, but all reply and transcript evidence is limited to hashes, byte/record counts, and boolean schema checks.

## Phase 1 — candidate and CI proof (read-only)

1. Fetch refs and verify that `MIGRATION_SHA` is exactly reachable from `origin/main`, not merely a PR head or dirty local tree.
2. Record local `git status --porcelain=v1`, refs, and any dirty-diff SHA only as non-candidate context. Every migration evaluation/build/deploy must reference immutable `MIGRATION_SHA` or a separately verified clean detached checkout; never evaluate `.#` from the working tree. The deploy candidate itself must be clean.
3. Verify the candidate contains all Home Manager/mount invariants:
   - `After=sancta-soul-mount.service`;
   - `Requires=sancta-soul-mount.service`; and
   - `ConditionPathIsMountPoint=/var/lib/sancta/.claude`;
   - armed open/mount units fail rather than condition-skip when the image/mapper is missing;
   - the mount script verifies the exact mapper source before changing ownership;
   - a non-remaining `sancta-soul-verify` oneshot rechecks the target, mapper, image, and mounted source for each dependent start transaction;
   - the worker both follows and requires successful `home-manager-sancta` activation; and
   - `sancta-membrane` also hard-requires the verified mount.
4. Verify the pure regression evaluates to `true`:

   ```bash
   nix eval --json \
     "github:alexandru-savinov/nixos-config/${MIGRATION_SHA}#checks.x86_64-linux.module-eval.tests.sancta-choir-home-manager-soul-mount-guard"
   ```

5. Require a booted NixOS VM test, using the production source/mount units and evaluated host wiring, that proves the expected mapper/image boots through Home Manager and the worker. A symlink/noncanonical target, wrong pre-mounted filesystem, wrong existing mapper, or missing image must prevent Home Manager, worker, membrane, and Serve. After a successful start, replace the mount or mapper only inside the disposable VM and prove stop/restart refuses to unmount/close the replacement and reports failure. Inject failure immediately after mapper creation and after mount creation: any leftover must remain unavailable to dependents, be reported explicitly, and be recoverable only after exact ownership/source verification—never guessed cleanup. A failed Home Manager must prevent the worker; the intentional status-only gateway may remain up only if authenticated `/send` returns unavailable with no inbox/quota mutation and no ready marker. A host mount namespace without its own systemd manager is not equivalent.
6. Require causal production-relay tests for three ambiguous crash windows: after the in-progress marker but before provider spawn, after provider exit but before reply commit, and after reply rename but before cursor save. A build-time test interposer or unreachable test-only hook must deterministically stop at each point and prove the tested relay otherwise hashes to the production source. The first two cases remain operator-blocked with no automatic second spawn; the committed-checkpoint case advances to EOF on restart with exactly one total fake-provider spawn. Pre-seeding a reply is not a causal substitute.

   ```bash
   nix build \
     "github:alexandru-savinov/nixos-config/${MIGRATION_SHA}#sancta-soul-volume-test" -L
   nix build \
     "github:alexandru-savinov/nixos-config/${MIGRATION_SHA}#checks.x86_64-linux.sancta-membrane" -L
   ```

7. Record the successful required CI workflow URL, run ID, workflow SHA, job names, and logs for the exact candidate. The x86_64 job must build `sancta-choir` and run both VM/crash suites; success for `0d2eeda` does not validate a later local fix.
8. Confirm no #537 ingestion-membrane files or behavior are mixed into the migration candidate.

**Gate:** do not proceed unless the complete candidate is on `main`, the candidate tree is clean, all required checks are green, and the exact CI evidence is recorded.

## Phase 2 — attended host preflight (read-only)

Run from an operator-controlled terminal with provider console recovery already open.

1. Record current boot/system state:
   - `readlink -f /run/current-system`;
   - `nixos-rebuild list-generations`;
   - `cat /proc/sys/kernel/random/boot_id`;
   - `uname -a`; and
   - `systemctl --failed`.
2. Record, without content, the current soul boundary:
   - `findmnt -n -o SOURCE,FSTYPE,OPTIONS --target /var/lib/sancta/.claude`;
   - `cryptsetup status sancta-soul`;
   - owner/mode for `/var/lib/sancta`, the mountpoint, and the image; and
   - status plus unit text for `sancta-soul-open`, `sancta-soul-mount`, `home-manager-sancta`, `sancta-worker`, `sancta-membrane`, and `sancta-membrane-serve`.
3. Require the mounted source to be the active `/dev/mapper/sancta-soul` backed by `/var/lib/sancta-soul/soul.img`. `ConditionPathIsMountPoint` alone proves only that *some* filesystem is mounted.
4. Record hashes/counts—not contents—for:
   - the inbox, replies, cursor, failure marker, and rate-limit files;
   - every Claude session transcript and specifically `SESSION_ID`;
   - `/var/lib/sancta/.claude/settings.json`; and
   - managed skill/agent/command/`CLAUDE.md` symlink targets; and
   - a metadata/type/mode/owner/hash manifest of every regular file and symlink in the complete writable `/var/lib/sancta` boundary, without recording contents.
5. Validate every pre-existing inbox/reply JSONL line, final-newline status, closed record schema, checkpoint uniqueness and offset/hash consistency, cursor schema, failure schema, and rate-limit schema before relying on their counts. Confirm the exact session-marker file exists, exactly one resumable transcript matches `SESSION_ID`, the cursor is an integer at inbox EOF, no unresolved failure marker exists, no proceed-classified item is pending, and at least one rolling-day proceed slot remains.
6. Confirm the credential file exists with the reviewed owner and mode without reading or hashing its plaintext. Record disk, RAM, and swap headroom against reviewed minimums.
7. Inventory the pre-existing hand-repaired symlinks against the Home Manager manifest and prepare an explicit collision list. Keep the documented `sancta-soul-hm-files` GC root and the older unmanaged `n8n-*` links until a separate migration retires them.

**Gate:** any wrong mapper, non-EOF cursor, unresolved failure, unexpected session count, missing GC root, or unreviewed collision stops the run.

## Phase 3 — build and stage the exact commit (human-authorized)

On `sancta-choir`, build from the immutable GitHub revision with throttling:

```bash
nixos-rebuild build \
  --flake "github:alexandru-savinov/nixos-config/${MIGRATION_SHA}#sancta-choir" \
  --max-jobs 1 --cores 1
```

Record `readlink -f result` as `MIGRATION_TOPLEVEL`. Inspect the rendered `sancta-soul-open`, `sancta-soul-mount`, `home-manager-sancta`, worker, membrane, and Serve units in `MIGRATION_TOPLEVEL` and recheck their source, condition, and dependency invariants. Compare a CI store path only if CI published an authenticated `outPath`/`drvPath` artifact for this exact commit; job success alone supplies no path to compare.

Before the final snapshot or any symlink move, freeze without interrupting paid work:

1. Stop only `sancta-membrane-serve.service`, require HTTPS port 8743 absent, and record—but do not alter—the reviewed baseline of unrelated Serve routes.
2. Wait at least 30 seconds, exceeding the gateway's 15-second request plus 10-second membrane bounds, then require two stable inbox/rate snapshots. If those code bounds differ in `MIGRATION_SHA`, recompute and review the wait instead of copying 30 seconds.
3. Let the worker drain naturally until the cursor is at EOF and no in-progress/failure marker remains. Never stop it merely because a timeout elapsed.
4. Only then stop `sancta-membrane` and `sancta-worker` and repeat the complete Phase 2 manifest as the authoritative pre-reboot snapshot.

While ingress remains frozen, Alexandru may move only the exact colliding managed symlinks from the reviewed Phase 2 list into a timestamped backup directory on the encrypted soul. Do not use a broad glob, touch the unmanaged `n8n-*` links, or remove the retained GC root.

After explicit confirmation, stage for the next boot without activating in the current session:

```bash
sudo nixos-rebuild boot \
  --flake "github:alexandru-savinov/nixos-config/${MIGRATION_SHA}#sancta-choir" \
  --max-jobs 1 --cores 1
```

Record the new generation and the legacy prior generation, but do not label that prior generation safe merely because it is selectable; prove the rescue/emergency path required by Rollback is available. Do not use an unthrottled build, first-time LUKS formatting, or an unattended `switch`.

If staging is cancelled or fails before reboot, restore/recreate only the exact moved links from the collision manifest, re-verify the expected mapper/image/mount, then restart the old worker, membrane, and Serve in that safe order. Require cursor/ready/quota state and the unrelated Serve-route baseline to match the frozen snapshot. Do not leave the host silently frozen or links displaced.

## Phase 4 — reboot and boot-order proof (human-authorized)

Reboot only with console access and the prior generation recorded. After SSH returns:

1. Require a new boot ID and `readlink -f /run/current-system == MIGRATION_TOPLEVEL`.
2. Require no unexpected failed units.
3. Prove the healthy-boot order `sancta-soul-open` → `sancta-soul-mount` → exact-source verifier → successful `home-manager-sancta` → worker readiness → membrane/Serve acceptance. For the open/mount/verifier/Home Manager/Serve oneshots require `Result=success`, `ConditionResult=yes`, and the applicable monotonic start/finish inequalities. For the long-running worker and membrane require `ActiveState=active`, `SubState=running`, nonzero `MainPID`, expected `NRestarts`, start timestamps, the worker ready marker/status, and proof that no request was accepted before readiness. `After=` orders start jobs, not application readiness. Retain critical-chain, `systemctl show`, and this-boot journal evidence as supporting data rather than treating their presence as an assertion.
4. Re-run `findmnt` and `cryptsetup status`; prove the exact mapper/image relationship. The wrong-source negative belongs in the booted NixOS VM from Phase 1—never replace or unmount the live soul and never substitute a host mount namespace for the systemd E2E.
5. Prove the hidden bare underlay stayed empty using a reviewed private-namespace procedure that non-recursively bind-mounts the root filesystem, remounts that bind read-only, proves the inspected path's source is the root filesystem rather than `sancta-soul`, and then asserts the hidden directory is empty. Never use `--rbind` and never unmount the live soul.
6. Require Home Manager success and verify the host-owned `/var/lib/sancta/.claude-shared` clone plus managed skill/agent/command/`CLAUDE.md` links resolve. Confirm `model = "opus[1m]"` and `verbose = true` without printing unrelated settings.
7. Confirm `SESSION_ID`, the transcript hashes/counts, inbox/replies/cursor state, and the retained `n8n-*` compatibility links match preflight expectations.
8. Confirm the worker remains `--safe-mode`, `--strict-mcp-config`, empty MCP, `Read,Grep,Glob`, and a `2.00` per-turn budget cap.
9. Confirm Tailscale Serve exposes exactly the reviewed membrane route on HTTPS port 8743, the previously recorded unrelated-route baseline is unchanged, and the gateway reports the worker ready. Do not send a message yet.

**Gate:** stop and roll back on a wrong toplevel, wrong mount source, underlay write, failed Home Manager activation, broken links, missing session, cursor drift, unexpected transcript mutation, widened tool/MCP surface, or unready gateway.

## Phase 5 — one authenticated real resumed turn (human-authorized and billed)

This phase deliberately spends at most the configured `2.00` USD cap and consumes one of the three rolling daily proceed slots.

1. From the operator terminal, generate a unique harmless challenge consisting of `hello` followed immediately by a random 64-character `!`/`?` suffix. This remains inside `comm-membrane`'s exact trivial allowlist; a nonce-echo instruction would escalate and can never exercise the worker. Record the challenge and its SHA-256, but place no response text in evidence and do not require the model to echo it.
2. Capture pre-send hashes, byte sizes, JSONL counts, cursor offset, failure-marker state, the valid rolling-window quota set, all session transcript hashes, the last committed checkpoint set, and the complete `/var/lib/sancta` metadata/hash manifest.
3. Discover the exact Serve URL from the live `tailscale serve status`; do not guess a hostname. Send exactly one HTTPS `POST /send` with:
   - the authenticated Tailscale user path;
   - interactive `curl --user alexandru` password prompting so the secret never appears in argv/history;
   - `X-Sancta-Request: send`;
   - `Content-Type: application/json`; and
   - the allowlisted challenge as the sole message.
4. Require HTTP success and membrane decision `proceed`. Do not retry on timeout or ambiguity; inspect state first to avoid double spend.
5. Poll with a reviewed on-host metadata probe that emits only hashes, counts, offsets, and booleans until exactly one new worker reply is committed or the reviewed timeout expires. Do not fetch `/thread` or `/thread-merged` as evidence, because neither provides the required checkpoint proof without exposing content. Never use `curl -v`, tracing, shell xtrace, or a redirect that could retain Basic credentials, and never issue a second send.
6. Require all of the following:
   - inbox grew by exactly one newline-terminated, valid-JSON proceed record;
   - replies grew by exactly one `source:sancta-worker` record;
   - that record contains non-empty text, one unique `inbox_checkpoint`, and the correct old/new byte offsets;
   - `inbox_hash` is SHA-256 of the exact new serialized inbox JSONL line excluding its newline, and `inbox_checkpoint` equals `<old_offset>:<entry.ts>:<line_hash>`;
   - cursor equals inbox EOF;
   - failure marker is absent;
   - an on-host redacting parser proves the challenge hash occurs exactly once as the new user record in `SESSION_ID` and is causally followed by exactly one assistant/result record from that resumed invocation;
   - only the expected transcript changes, its logical record delta matches one resumed invocation, and every other legitimately mutable Claude metadata path is explicitly allowlisted;
   - authoritative redacted provider-result evidence proves one invocation and `0 < total_cost_usd <= 2.00` (or an equally authoritative usage field if billing mode reports no per-call cost);
   - the rate-limit file remains mode `0600`, contains no plaintext login, and its prior valid rolling-window set gains exactly one timestamp inside the request interval for the hashed identity;
   - no unexpected regular file or symlink outside the encrypted `.claude` allowlist is new or changed anywhere under writable `/var/lib/sancta`; and
   - no credential, unrelated content, or raw transcript entered evidence/journal.
7. Restart only `sancta-worker`, wait beyond one polling interval, and prove inbox/reply/cursor/transcript/quota hashes and the full writable-boundary manifest remain unchanged. Label this narrowly as clean-restart/no-new-work durability; the causal crash-window guarantees come from the exact-candidate CI suite in Phase 1.

Any ambiguous HTTP result, Claude failure, reply-commit failure, cursor retention, duplicate reply/checkpoint, second transcript mutation, or budget uncertainty is a FAIL requiring operator review—not an automatic retry. The supported guarantee is no automatic replay after ambiguity; never claim exactly-once model execution without provider idempotency and stronger crash-durable transactions.

Record Gate 0-A as PASS, FAIL-ROLLED-BACK, or NOT-RUN. A Gate 0-A PASS is reusable migration evidence, not an overall Gate 0 PASS while Phase 6 remains unresolved.

## Phase 6 — home-side and aggregate-presence prerequisite

This phase is **blocked by design/consent, not executable yet**. Before implementation, Alexandru must resolve the gates recorded in `2026-07-09-ha-plan-reconciliation.md`, including household assent, wall versus tripwire, broker host/key surgery, source-side consent/apex controls, uniform-null privacy, latency, and standing CI/probe/witness controls. That authoritative plan must also name the consumer host, exact ephemeral action and default/null behavior, downstream protocol and persistence policy, fixed normalization deadline/tolerance, broker identity/state ownership, and the per-UID network enforcement that lets the consumer—but neither `sancta-worker` nor ad-hoc `sancta` processes—reach the broker. Host-level tailnet ACLs alone cannot distinguish Unix UIDs.

The only acceptable V1 capability is Plane A aggregate presence:

- HA on `rpi5-full` computes a human-authored, non-denominated allowlist OR;
- unknown/unavailable/device-class drift is excluded and all unavailable becomes null;
- 600-second debounce, a fixed 300-second push cadence, 660-second stale TTL, and at most the single explicitly specified restart-sync exception from the authoritative plan;
- an exact versioned HMAC algorithm/domain separator/canonical-byte/timestamp protocol; every authenticated timestamp is within 90 seconds and strictly greater than a broker-owned, worker-inaccessible persisted anti-replay high-water mark;
- TTL uses monotonic receipt time so wall-clock rollback cannot extend freshness;
- broker holds no HA token, URL, client, history, or egress;
- the only consumer/read surface is parameterless `GET /presence`; a separate authenticated HA-only ingest exists and is unreachable from choir;
- fresh response is `{someone_home: bool, ts}`;
- an accepted signed null advances the durable high-water mark, immediately clears any prior good value, and serves exactly `{"someone_home":null}` without `ts`;
- fresh boot/restart serves null until a newer authenticated post-boot push, without discarding the persisted replay high-water mark;
- a rejected push never erases or refreshes a still-fresh prior good value; and
- every no-value body is byte-identical `{"someone_home":null}`, with status, headers, timing, DNS, connection, and transport failures normalized locally rather than revealing the reason.

Required proof has three parts:

1. A VM/fixture test proves aggregation, scheduled cadence plus the sole restart-sync exception, debounce/staleness, HMAC/replay/reorder denial, latest-value-only storage, uniform full-observable null within the fixed deadline, and no value logging. It causally tests bad-on-empty → null, bad-after-good → unchanged prior good only until its original TTL, good → accepted null, boot → accepted null, null replay/reorder rejection, and wall-clock rollback.
2. Broker state uses no-follow/no-replace temporary writes or an equivalent transaction, file and directory `fsync`, and acknowledgement only after the high-water/value transaction is durable. Kill after every persistence stage and reboot: a persistence failure neither exposes nor acknowledges the new value; the old timestamp remains rejected, served state is null after restart, and only a newer signed push restores a value.
3. A separate fixed-purpose consumer UID—not `sancta-worker`—has no writable persistent filesystem, no value-bearing stdout/stderr/journal, and no unapproved persistent downstream action state. The authoritative plan treats the exact approved ephemeral action as an explicit declassification and proves it cannot preserve the raw bit/timestamp or join it with other signals. From the consumer's actual mount/network/cgroup namespaces the fixed read and action succeed, while query/body/entity/path/method variations, broker ingest, history, Plane B, direct HA REST/WebSocket/`:8123`, alternate sockets/proxies, and unrelated routes fail. Cross-UID bypass attempts from the worker and ad-hoc `sancta` fail at the named local enforcement layer.
4. Alexandru separately witnesses live HA → broker tracking and revoke/veto → null, recording pass/fail only. Agents never inspect household presence.
5. Select `FINAL_GATE_SHA` only after the authorized HA implementation is on `main` with green CI. Build and boot its exact toplevel, repeat the Phase 1 VM/crash suites and Phase 4 live migration assertions, then repeat Phase 5 only with separate human authorization for the billed call. Overall Gate 0 cannot reuse stale live evidence from `MIGRATION_SHA` as proof that the final combined commit did not regress migration.

Static configuration is insufficient. From the untrusted worker and consumer namespaces, the negative proof must separately record network/ACL denial and target authorized-key absence for ordinary SSH and Tailscale SSH paths to both the RPi and broker identities; a generic SSH `Permission denied` is not proof of pre-auth network denial. Operator management access may remain outside those namespaces. The RPi `nixos` account currently has broad LLAT-backed HA config; a transitive shell would defeat the boundary. Home-side HA execution may remain on RPi, but broad RPi tooling must never become reachable from the VPS worker.

Until this phase is implemented, authorized, and green, Gate 0 remains FAIL and issue #537 stays planning-only.

## Evidence manifest and review

The redacted manifest records:

- deployed repo commit/tree SHA, clean-source proof, and `flake.lock` revisions; any local dirty-diff hash is labeled non-candidate context and never substituted for those identifiers;
- CI workflow SHA/run URL/jobs and exact test derivations;
- `MIGRATION_SHA`, `MIGRATION_TOPLEVEL`, `FINAL_GATE_SHA` when selected, `PRIOR_SYSTEM`, generation numbers, boot IDs, and timestamps;
- unit-file hashes, MainPIDs, UID/GID/groups, namespace IDs, mountinfo, mapper/image relationship, and critical-chain timestamps;
- before/after hashes, sizes, counts, offsets, checkpoint IDs, and the harmless unique challenge;
- the HA fixture/live pass/fail matrix without household values; and
- every deviation, failure, rollback, and persistent test artifact.

A second reviewer must reproduce the count/hash assertions and sign the PASS/FAIL conclusion before issue #537 implementation can begin.

## Rollback

Rollback is code/generation rollback, never deletion or rewriting of soul data:

1. Treat `PRIOR_GENERATION` as legacy and unsafe by default: it lacks the new wrong-source, condition-skip, and Home-Manager/worker protections. A mapper/image/mount failure must enter rescue/emergency recovery or a prebuilt fail-closed recovery specialization that disables Home Manager, worker, membrane, and Serve; never normal-boot the old generation into that fault.
2. A normal prior-generation rollback is allowed only after rescue-console verification of the exact healthy mapper/image/mount and with the Sancta session marker disarmed. On a reachable non-storage failure, stop Serve ingress, drain safely as in Phase 3, stage with `sudo nixos-rebuild boot --rollback`, and prove the target resolves to `PRIOR_SYSTEM` before a supervised reboot.
3. Restore or recreate only the exact managed symlinks moved in Phase 3 as required by the prior generation, using the recorded collision manifest; do not touch the unmanaged `n8n-*` links.
4. Re-run mapper, session, cursor, transcript, complete writable-boundary, link, and service checks before rearming the session marker or ingress.
5. Preserve failure markers, inbox/reply records, journals, hashes, and moved-link backup for diagnosis. Do not clear a failure marker or retry a turn until checkpoint/transcript/billing are reconciled.
6. Do not remove the soul image, close/format/recreate LUKS, delete migration history, or discard the retained GC root as “rollback.”

Record the final state as PASS, FAIL-ROLLED-BACK, or NOT-RUN. There is no partial PASS.
