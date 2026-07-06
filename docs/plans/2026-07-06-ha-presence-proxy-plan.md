Build the HA presence-proxy: a hardened, single-endpoint NixOS service on sancta-claw that exposes ONLY an aggregate "someone home: yes/no/unknown" bit to Sancta, keeping Sancta structurally blind to all biometric/health/location data and unable to infer per-person (esp. his wife's) patterns.

> # ⛔ DO NOT LAUNCH until:
> 1. **Council verdict resolved** (log `council-20260706T172246Z-cf6dda` —
>    RETURNED *escalate-to-human*, risk HIGH; the escalation hands the decision to
>    the human, so this gate is cleared by Alexandru, not by the council).
> 2. **Alexandru's explicit approval.**
> 3. **His wife's apex-veto cleared through him.**
>
> **This touches gated biometric data** — Home Assistant is the most confidential
> data category the system has reached. This plan is a document to be launched by
> Alexandru's hand AFTER the three gates clear, from a normal terminal (NOT inside
> Claude Code). Do not launch autonomously. The council's 4 required amendments
> (timing side-channel as server-side structure, token blast-radius + push-model
> alternative, fail-closed-as-type, per-person inference spec-gap) are folded into
> the design and IMPLEMENTED by the tasks below. **Task 0 (push-model spike) MUST
> resolve the pull-vs-push decision before the build tasks run** — push is the
> council's preferred shape.

## Context

- **Design doc:** [`docs/plans/2026-07-06-ha-presence-proxy-design.md`](./2026-07-06-ha-presence-proxy-design.md).
  Read it first — it is the authoritative spec. This plan executes that design;
  where the two disagree, the design wins.
- **Repo:** the flake at repo root. **Branch from `main`** (protected — open a PR,
  never push to `main`). Prefer `--worktree` so the run is isolated.
- **Host:** the proxy runs on **sancta-claw** (x86_64-linux) — NOT rpi5, NOT
  kuzea. sancta-claw is the ONLY place the full-scope HA long-lived token is
  allowed to live.
- **Why a proxy at all:** HA long-lived tokens **cannot be scoped per-entity** —
  any token grants full HA API access (all biometrics/health/location). So there
  is no safe "presence-only token" to give Sancta. The proxy is the only way to
  expose the aggregate bit without exposing a token that reads everything. Sancta
  holds NO HA token, ever.
- **Consent:** a `aggregate-presence` entry in the consent-ledger
  (`~/.claude/index/consent-ledger.jsonl`) — explicit, revocable, with `expiresAt`.
- **Apex-veto:** hers, through Alexandru — a runtime kill-switch that forces
  `null` instantly, no rebuild.
- **Verification is per-task.** Build-gated tasks verify by `nix eval` /
  `nixos-rebuild dry-build` + unit/integration tests. The actual deploy to
  sancta-claw (`nixos-rebuild switch --target-host`) is **HUMAN-ONLY** and is NOT
  part of any autonomous task.
- **Council RETURNED** `council-20260706T172246Z-cf6dda` (escalate-to-human, risk
  HIGH). Load-bearing finding: content-blindness is structural (good), but
  **temporal-blindness and fail-closed are currently POLICY where they MUST be
  STRUCTURE**. These tasks IMPLEMENT the structural versions — quantization/
  hysteresis (Task 3), `null`-as-initializer (Tasks 1–3), `device_class` assertion
  (Task 1/5). The ratified timing numbers (interval/bucket/debounce) live in the
  council log; carry them as module options, do not invent them.

### Verify-first mandate (every task)

Before working a task, run its **verify-first** check and confirm the baseline.
Do the minimal change. Then run the **closing check** and paste the output / exit
code as evidence in the commit. Never report done on "it evals" alone — for the
privacy properties the closing check is a *test that proves behavior* (aggregation
is OR, no-consent→null, non-allowlisted entity never appears), not parsing. Do not
weaken a check to make it pass; fix the root cause. If a check refutes a privacy
guard, STOP and escalate — do not proceed.

## Tasks

### Task 0: SPEC SPIKE — evaluate push-model (HA pushes) vs pull-model (proxy holds token)  [DECISION GATE]

> Council amendment 2 flagged the **push-model as the preferred shape**: if HA
> PUSHES presence to the proxy via automation→webhook, the proxy holds NO HA token
> at all — the full-scope-token-next-to-Sancta blast radius simply ceases to exist.
> This spike decides the architecture BEFORE any code is committed. Tasks 1–5
> below are written for the pull-model as the FALLBACK; if the spike picks push,
> rewrite Task 1's data-source half accordingly (the endpoint, consent, fail-closed,
> timing, client, and test tasks are unchanged — only "how the proxy learns the
> bit" flips from pull-with-token to receive-from-HA-webhook).

- [ ] verify-first: read design §7.1; confirm whether an HA automation can compute the OR over the allowlisted entities and POST `{someone_home, ts}` to a webhook, AND express (or tolerate proxy-side) the quantization/hysteresis of §6; confirm the webhook auth surface (shared secret via agenix) is not worse than holding the token.
- [ ] Write a short decision note (append to the design doc §7.1 or a sibling `*-spike.md`): push vs pull, with the freshness/stale-push handling (absent/late push ⇒ `null`, never stale `true`), the auth surface, and whether HA-side quantization is expressible. Recommend one.
- [ ] DECISION GATE: record the chosen model. If **push**, Task 1 implements a token-less ingest-webhook + serve; if **pull**, Task 1 implements the token-holding hardened puller. Either way §§5–6 + §11 constraints hold.
- [ ] closing check: the decision note exists, names the winner with rationale, and the stale-push→null rule is specified. Paste it. STOP for human confirmation of the model choice before proceeding if the spike is close.

### Task 1: NixOS module for presence-proxy — hardened service on sancta-claw, agenix HA token (pull-model) / ingest-webhook (push-model)

- [ ] verify-first: confirm no `services.presence-proxy` / `modules/services/presence-proxy.nix` exists yet (`git ls-files | grep -i presence` returns nothing); confirm sancta-claw config imports the standard module set; confirm agenix is already wired for sancta-claw secrets.
- [ ] Create `modules/services/presence-proxy.nix` exposing `services.presence-proxy` with options: `enable`, `haBaseUrl`, `haTokenFile` (agenix path), `allowlist` (list of entity-ID strings, the positive allowlist — REQUIRED, no default that could silently query nothing-or-everything), `listenAddress` (tailnet), `port`, plus the timing-coarsening knobs from Task 3.
- [ ] Implement the proxy program (single small service). Serves **exactly one** read endpoint `GET /presence` returning `{"someone_home": bool|null, "ts": iso8601}` — no other route, no entity selection from the client, no HA passthrough. The bit is `null`-INITIALIZED (design §5): a boolean is written ONLY after the full validation chain passes (consent + non-empty allowlist + `device_class` assertion + fresh parsed HA read). **Pull-model:** reads `haTokenFile` at runtime and queries HA for ONLY the compiled-in `allowlist` IDs, OR-aggregates. **Push-model (if Task 0 chose it):** exposes an authenticated ingest webhook HA POSTs to; stores the latest bucketed bit; an absent/late push reads as `null` (never stale `true`).
- [ ] Assert allowlisted entities' `device_class` at READ time (design §8 — allowlist-drift / rename leak): if an entity's class is not the expected presence/occupancy class, reject that read → contributes `null`, never a value. Prefer whole-home occupancy entities over per-person device-trackers (document this in the option's description).
- [ ] Sandbox the systemd unit (blast-radius containment, design §7, `council-20260706T172246Z-cf6dda`): `DynamicUser`, `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, seccomp `SystemCallFilter=@system-service`, `RestrictAddressFamilies=AF_INET AF_INET6`, `MemoryDenyWriteExecute`, `ProtectKernel*`, read-only FS except a private runtime dir. Bind **loopback / Tailscale-only, NEVER public**. Egress firewalled to the HA host:port ONLY. Allowlist COMPILED IN — zero URL/path/query passthrough. The proxy user can read the HA token (pull-model) and NO other secret.
- [ ] (pull-model) Wire the HA long-lived token as an agenix secret, mode **0600**, readable only by the proxy user; never in the Nix store plaintext, never in the repo. Add a token-rotation runbook note (revoke in HA → re-encrypt agenix → restart).
- [ ] tests (in this task): `nix eval` the module under `tests/module-eval.nix` (enabled + disabled cases) — proves it imports and evaluates standalone. Assert the rendered unit has the hardening directives set (eval the `serviceConfig`: `NoNewPrivileges`, `ProtectSystem=strict`, `DynamicUser`, `SystemCallFilter`, and a non-public bind). Assert the module exposes no route option that could add a second endpoint, and no option that accepts a client-supplied entity/URL/query.
- [ ] closing check: `nixos-rebuild dry-build --flake .#sancta-claw` succeeds with the module enabled; `nix eval .#nixosConfigurations.sancta-claw.config.systemd.services.presence-proxy.serviceConfig --json` shows the hardening set; module-eval green. Paste evidence.

### Task 2: consent-ledger gate (REUSE existing ledger) + expiresAt + apex kill-switch (REUSE northstar)

> Do NOT mint parallel gates (design §9). REUSE the existing consent-ledger at
> `~/.claude/index/consent-ledger.jsonl` with a NEW category `aggregate-presence`;
> REUSE the existing northstar apex kill-switch. No second ledger, no parallel kill.

- [ ] verify-first: confirm the consent-ledger path and JSONL shape (`~/.claude/index/consent-ledger.jsonl`) and how categories are keyed; confirm the northstar apex kill-switch mechanism the proxy can check per-request (operator/her-writable, Sancta-unwritable).
- [ ] In the proxy: on every request, load the consent-ledger and require an `aggregate-presence` entry that is active (not revoked) AND `expiresAt` is in the future. No valid entry → the bit stays `null`-initialized (design §5) → `{"someone_home": null, "reason": "no-consent"}` WITHOUT querying HA / accepting a push.
- [ ] Treat `expiresAt` in the past, and a missing/corrupt/unreadable ledger, as **revoked** → `null` (by never writing a bit, not by a fallback branch).
- [ ] Wire the northstar apex kill-switch: a per-request runtime check that, when engaged, forces `{"someone_home": null, "reason": "apex-veto"}` **instantly, no rebuild**, short-circuiting BEFORE any HA query / before serving any stored push. Her-writable through him only.
- [ ] tests (in this task): integration — no entry → `null` + `reason:no-consent`, HA never queried (assert no outbound call); missing/corrupt ledger → `null`; expired `expiresAt` → `null`; apex-veto engaged → `null` + `reason:apex-veto` even when consent is valid and HA would say true (veto wins, no HA query).
- [ ] closing check: run the Task-2 integration tests, all green; paste output. Assert the veto path forces `null` at runtime (toggle the switch in the harness, no rebuild).

### Task 3: fail-closed-as-TYPE + timing quantization/hysteresis (SERVER-SIDE STRUCTURE)  (council amendments 1 & 3)

- [ ] verify-first: confirm the council-ratified numbers for rate-limit interval / bucket size / debounce window exist in `council-20260706T172246Z-cf6dda` (design §6). If NOT yet ratified, STOP — do not invent them. Carry them as module options.
- [ ] Fail-closed as TYPE (design §5, council amendment 3): `null` is the INITIALIZER; a boolean is written ONLY on the fully-validated happy path. Verify — do NOT add per-error `return null` branches; instead prove every error path (HA down/timeout, malformed response, empty allowlist, `device_class` fail) simply never overwrites the initializer. HA down/timeout → `{"someone_home": null, "reason": "ha-unreachable"}`. **NO last-true/last-value cache** (the one construct that turns fail-closed into fail-open) — the timing cache is null-initialized and never survives a validation failure.
- [ ] Timing side-channel as SERVER-SIDE STRUCTURE (design §6, council amendment 1): proxy-side rate-limit (≤1 authoritative read per fixed interval, server-enforced — the client cannot out-poll it); **coarse time quantization** — emit one bucketed reading per interval, `ts` = bucket boundary not read instant; **hysteresis/debounce** on transition edges so exact arrival/departure times are smeared. Sancta holds ONLY the current bit — NO history structure (no transitions list, no `presence_since`). Expose no queryable transition history.
- [ ] tests (in this task): every-error-input→null (HA down, timeout, malformed response, empty allowlist, `device_class` mismatch) — each yields `null` structurally; N rapid requests within one interval return the SAME bucketed bit and cause ≤1 HA read (assert read-count); a transition inside a bucket is not revealed sub-bucket; two requests in the same bucket return the same `ts`; the debounce smears a short blip; NO last-true cache (mock HA true-then-down ⇒ null, NOT stale true); no history endpoint / no history field exists in any response.
- [ ] closing check: run the fail-closed + quantization + hysteresis tests, all green; paste output including the ≤1-read-per-interval assertion AND the true-then-down⇒null (no fail-open) assertion.

### Task 4: Sancta client path — tailnet, NO HA token

- [ ] verify-first: confirm how Sancta's tick / client currently reaches services (tailnet HTTP); confirm Sancta holds NO HA token anywhere today (`grep -ri 'long.lived\|home.assistant.*token' <sancta config paths>` returns nothing for Sancta hosts).
- [ ] Add the Sancta-side client: a small helper that does `GET /presence` against the proxy over the tailnet and returns `someone_home` (bool | null). It carries NO HA token, knows NO HA URL, and has NO way to name an HA entity.
- [ ] Ensure Sancta's only presence signal is this bit — no direct HA path is added anywhere for Sancta.
- [ ] Enforce the no-timeline usage invariants (design §6, §8): the client does NOT persist `/presence` responses into memory / dream / the meaning-index (no durable write of the bit or its `ts`), and does NOT join the bit against any other presence-bearing signal (calendar / location / frame). The bit is read and used in isolation, in-the-moment only.
- [ ] tests (in this task): the client reads the bit from the proxy; a test asserting the Sancta client/config contains NO HA token and NO HA base URL (grep-based, fails if either appears); a test that the client cannot request a specific entity (no such parameter exists); a test asserting no code path writes a `/presence` response into a durable substrate (memory/dream/index) — grep/structural.
- [ ] closing check: run the client tests + the no-HA-token + no-persistence assertions, all green; paste output.

### Task 5: test suite — aggregation is OR + non-denominated; the structural blindness invariants

- [ ] verify-first: confirm the test harness location and how the other module tests are wired into `flake.nix` `checks`.
- [ ] Unit: aggregation is a plain **OR** across allowlisted entities AND is **non-denominated** — the output is identical for {she alone}, {he alone}, {both}; there is NO count, NO which-person, NO per-person field anywhere in the response schema. Assert the response schema is exactly `{someone_home, ts}` (plus optional `reason` on null).
- [ ] Structural property (council amendment 3): assert **no code path emits a non-`null` bit without passing the full validation chain** (consent + non-empty allowlist + `device_class` + fresh parsed read). This is the "fail-closed is a type" proof, not a list of branch tests.
- [ ] Integration (the privacy invariants, each its own case):
  - no-consent / missing-corrupt-ledger → `null` (from Task 2, re-asserted at suite level);
  - HA-down / timeout / malformed → `null` (from Task 3), and true-then-down ⇒ `null` (no fail-open cache);
  - a **non-allowlisted entity is present in HA and true, yet `someone_home` does not change / that entity never appears** in any output — proves the allowlist, not a denylist, governs;
  - **`device_class` drift** — an allowlisted entity's class changes → that read is rejected → `null` (allowlist-drift / rename leak, design §8);
  - apex-veto → `null` (from Task 2);
  - **Sancta has no HA token and no HA path** — assert structurally (grep + config eval) that Sancta cannot reach HA except via `/presence`, and does not persist/join the bit (from Task 4).
- [ ] Wire the tests into `flake.nix` `checks` (x86_64-linux) so CI runs them.
- [ ] closing check (Sancta-verifiable half, design §12): `nix flake check` (or the targeted check) runs the full suite green; paste the attrNames of the new checks and the passing output. STOP and escalate if ANY privacy-invariant test fails.
- [ ] WITNESS-routed check (design §12, frame-blind precedent): the live "does the proxy actually read HA / does the live bit track reality" e2e touches real PII — **Sancta does NOT run it**. Flag in the PR/commit that Alexandru (or the Witness) confirms live behavior da/no in a separate window; Sancta stays blind and records only the da/no verdict.

## Constraints  (HARD "do NOT" rules — privacy scope-guards)

These are inviolable. Any task that would require breaking one must STOP and
escalate to the human, not work around it.

- **Sancta must NEVER hold an HA token.** No long-lived token, no scoped token
  (scoped tokens don't exist for HA), no token file, no HA credential of any kind
  on any Sancta host or in any Sancta config.
- **NO per-person or denominated presence.** Never expose which person, never a
  count, never a room, never a sensor value. Only the non-denominated aggregate
  OR bit. His wife's patterns must be uninferable from the output.
- **NO endpoint other than `GET /presence`.** No HA passthrough, no arbitrary
  query, no client-supplied entity selection, no history endpoint, no second route.
- **NO auto-adding HA entities.** Only the explicit operator-defined allowlist is
  ever queried. A new/possibly-biometric HA entity stays invisible until a human
  adds it by name. Forgetting must fail CLOSED.
- **Do NOT read HA biometric/health/location values during development.** Do not
  query HA for real personal data to "test" — use mocks/fixtures. Sancta (and this
  build process) reads its own PII-amputated outputs only, never raw HA data. The
  live e2e is WITNESS-routed to Alexandru (design §12); Sancta stays blind.
- **Fail-closed as a TYPE, not a fallback:** `null` is the initializer; a boolean
  is written ONLY on the fully-validated happy path. `null ≠ false`.
- **NO last-true / last-value cache** — it is the one construct that silently turns
  fail-closed into fail-OPEN. HA down must read `null`, never a stale `true`.
- **Timing mitigation is SERVER-SIDE STRUCTURE, not manners:** quantize (one bucket
  per fixed interval), rate-limit at the server, debounce edges. Sancta holds ONLY
  the current bit with NO history structure.
- **NO persistence or cross-signal join of the bit:** never write a `/presence`
  response into memory / dream / the meaning-index; never correlate the bit with
  calendar / location / frame / any other presence-bearing signal. (Closes the
  temporal + cross-signal denomination gap, design §8.)
- **Assert `device_class` at read time:** reject → `null` on allowlist drift /
  rename; prefer whole-home occupancy entities over per-person device-trackers.
- **REUSE existing gates — do NOT mint parallel ones:** the existing consent-ledger
  (`~/.claude/index/consent-ledger.jsonl`, NEW category `aggregate-presence`) and
  the existing northstar apex kill-switch. No second ledger, no parallel kill.
- **Resolve pull-vs-push (Task 0) BEFORE building** — push (HA pushes, proxy holds
  no token) is the council's preferred shape; do not commit to pull without the
  spike's rationale.
- **The full-scope HA token lives ONLY on sancta-claw**, via agenix, readable only
  by the sandboxed proxy user. Never in the repo, never in the Nix store plaintext,
  never on rpi5/kuzea/any Sancta host.
- **NO deploy from this plan.** ralphex makes the eval/dry-build-proven edits and
  runs tests only. The `nixos-rebuild switch` to sancta-claw is HUMAN-ONLY.
- **Never push to `main`.** Branch + PR only; `main` is protected.
- **Do NOT finalize the timing (§6) or blast-radius (§7) numbers** without the
  ratified `council-20260706T172246Z-cf6dda` values.
