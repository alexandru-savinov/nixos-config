Build the HA presence-proxy (PUSH model): Home Assistant aggregates the operator's allowlisted presence entities into ONE non-denominated bit and pushes it to a dumb-sink NixOS service on sancta-claw that holds ZERO HA credential; Sancta reads only `GET /presence → someone_home: yes/no/unknown`, staying structurally blind to all biometric/health/location data and unable to infer per-person (esp. his wife's) patterns.

> # ⛔ DO NOT LAUNCH until:
> 1. **Council verdict resolved** (log `council-20260706T172246Z-cf6dda` —
>    RETURNED *escalate-to-human*, risk HIGH; the escalation hands the decision to
>    the human, so this gate is cleared by Alexandru, not by the council).
> 2. **Alexandru's explicit approval.**
> 3. **His wife's apex-veto cleared through him.**
> 4. **Gate 0 — Amputation VERIFIED (structural PRECONDITION).** Sancta must be
>    structurally UNABLE to reach HA by any path other than the proxy BEFORE this
>    plan is built or activated: (a) the `home-assistant` MCP server removed from
>    Sancta's config (no `mcp__home-assistant__*` tool), (b) no SSH/shell to the
>    HA host/container, (c) no direct network route to the HA API port. Without
>    Gate 0 the proxy is **theater** — a data-path mediator cannot constrain an
>    agent that still holds an independent HA capability. See the design's
>    **"Gate 0 — Amputation"** section for the verifiable amputations + ordering.
>
> **Corrected order of operations (design "Gate 0"):**
> **her assent → his approval → Gate 0 amputation (verified) → build → activation.**
>
> **Premise caveat:** the re-gate council (`council-20260706T180259Z-6a0fa5`) was
> rendered **WITHOUT the amputation premise** — it reasoned about the proxy as the
> only path to HA, so its verdict is **incomplete without Gate 0**; a re-premised
> council may be warranted before proceeding.
>
> **This touches gated biometric data** — Home Assistant is the most confidential
> data category the system has reached. This plan is a document to be launched by
> Alexandru's hand AFTER the gates clear, from a normal terminal (NOT inside
> Claude Code). Do not launch autonomously.
>
> **COMMITTED ARCHITECTURE (Alexandru's 2026-07-06 decision — architecture
> authority, NOT a launch authorization; the 3 gates stay open):** the **PUSH
> model with HA-side aggregation + a normal stale-TTL** is the primary, committed
> shape. HA aggregates + quantizes the bit at source and PUSHES it (HMAC-signed) to
> a proxy on sancta-claw that **holds no HA token at all**; the proxy stores
> `{bit, last_push_ts}` and serves `null` if no verified push arrived within the
> stale-TTL. The **PULL model (proxy holds the full-scope HA token) is REJECTED**
> (design §7). The council's 4 amendments (timing → HA-side structure, token →
> eliminated by push, fail-closed-as-type + stale-TTL, per-person inference
> spec-gap) are folded into the design and IMPLEMENTED by the tasks below.

## Context

- **Design doc:** [`docs/plans/2026-07-06-ha-presence-proxy-design.md`](./2026-07-06-ha-presence-proxy-design.md).
  Read it first — it is the authoritative spec. This plan executes that design;
  where the two disagree, the design wins.
- **Repo:** the flake at repo root. **Branch from `main`** (protected — open a PR,
  never push to `main`). Prefer `--worktree` so the run is isolated.
- **Host:** the proxy runs on **sancta-claw** (x86_64-linux) — NOT rpi5, NOT
  kuzea. It is a **dumb sink holding ZERO HA credential** (only an HMAC shared
  secret to verify pushes).
- **Why PUSH, not pull:** HA long-lived tokens **cannot be scoped per-entity** —
  any token grants full HA API access (all biometrics/health/location). A *pull*
  proxy would have to hold that god-token next to Sancta on sancta-claw = the whole
  HA API is the blast radius. The **push model eliminates the token**: HA
  aggregates at source and pushes the bit out; the proxy only receives. Sancta
  holds NO HA token, ever — and neither does the proxy.
- **HA side (data holder):** a template `binary_sensor.someone_home` = OR across
  the operator's allowlisted presence entities (non-denominated). An HA automation
  pushes ONLY that bit (a) on debounced/quantized change and (b) as a periodic
  keepalive, and re-fires an immediate sync push on HA restart. Allowlist +
  aggregation + quantization all live in HA (operator's hand).
- **Consent:** an `aggregate-presence` entry in the consent-ledger
  (`~/.claude/index/consent-ledger.jsonl`) — explicit, revocable, with `expiresAt`.
- **Apex-veto:** hers, through Alexandru — a runtime kill-switch that forces
  `null` instantly, no rebuild.
- **Stale-TTL (NORMAL):** keepalive `~5 min`, stale threshold `~10–12 min` (≈ 2×
  keepalive). No verified push within the stale-TTL ⇒ serve `null` (reason
  `stale`). Tolerates one missed keepalive, fails closed on two. Both are module
  options with these defaults.
- **Verification is per-task.** Build-gated tasks verify by `nix eval` /
  `nixos-rebuild dry-build` + unit/integration tests. The actual deploy to
  sancta-claw (`nixos-rebuild switch --target-host`) is **HUMAN-ONLY** and is NOT
  part of any autonomous task.
- **Council RETURNED** `council-20260706T172246Z-cf6dda` (escalate-to-human, risk
  HIGH). Load-bearing finding: content-blindness is structural (good), but
  **temporal-blindness and fail-closed were POLICY where they MUST be STRUCTURE**.
  The committed push model makes them structural — HA-side quantization/hysteresis
  (Task 1 HA-side), `null`-as-initializer + stale-TTL (Tasks 2–3). The concrete
  timing numbers are the §5.1/§6 defaults; carry them as module / HA options.

### Verify-first mandate (every task)

Before working a task, run its **verify-first** check and confirm the baseline.
Do the minimal change. Then run the **closing check** and paste the output / exit
code as evidence in the commit. Never report done on "it evals" alone — for the
privacy properties the closing check is a *test that proves behavior* (aggregation
is OR, no-consent→null, non-allowlisted entity never appears), not parsing. Do not
weaken a check to make it pass; fix the root cause. If a check refutes a privacy
guard, STOP and escalate — do not proceed.

## Tasks

### Task 1: HA side — template `binary_sensor.someone_home` + quantized/debounced push automation + keepalive + restart re-sync

> The minimization lives at the source, in HA. This task produces HA config
> (YAML/packages) the operator installs on the HA host — NOT sancta-claw code. It
> is authored/reviewed here; the operator applies it to HA (his hand). Test with
> HA's own config-check / a fixture, NEVER against real personal entities.

- [ ] verify-first: confirm the HA host + how its config is managed (packages dir / `configuration.yaml`); confirm the operator's allowlist of presence entity IDs is provided by NAME (Sancta does not read HA to discover them); confirm HA can emit an outbound webhook (`rest_command` / notify) to the proxy over the tailnet.
- [ ] Author the template `binary_sensor.someone_home` = **pure OR** across the operator's allowlisted presence entities. Non-denominated: never which/how-many. Guard each allowlisted entity's expected `device_class` HA-side (design §8 — allowlist-drift/rename leak): an entity whose class drifted is EXCLUDED from the OR, never silently contributing a biometric value.
- [ ] Author the push automation: (a) fire on **debounced/quantized change** of `binary_sensor.someone_home` — HA-side hysteresis (`for:` delay) so brief transitions and exact edge-times don't leak; (b) a **periodic keepalive** (~5 min) re-pushing the current bit; (c) on **HA start/restart** fire an immediate **sync push**. Each push POSTs ONLY `{someone_home: bool, ts}`, **HMAC-signed** with the shared secret.
- [ ] Document the operator-hand steps: define the allowlist entities, install the package, set the shared secret + proxy URL. Prefer whole-home occupancy entities over per-person device-trackers.
- [ ] tests (in this task): HA config-check passes on the authored package (fixture entities, NO real PII); a fixture proving the template is a pure OR and non-denominated (identical bit for {a}, {b}, {a,b}); an assertion the automation has the debounce `for:` and the keepalive+restart triggers; the pushed payload schema is exactly `{someone_home, ts}` (no entity list, no count).
- [ ] closing check: HA config-check green on the fixture; paste it + the pure-OR/non-denominated fixture result + the payload-schema assertion.

### Task 2: proxy dumb-sink NixOS module on sancta-claw — HMAC-verified tailnet webhook receiver, {bit,ts} store, /presence, ZERO HA token

- [ ] verify-first: confirm no `services.presence-proxy` / `modules/services/presence-proxy.nix` exists yet (`git ls-files | grep -i presence` returns nothing); confirm sancta-claw imports the standard module set; confirm agenix is wired for sancta-claw secrets.
- [ ] Create `modules/services/presence-proxy.nix` exposing `services.presence-proxy` with options: `enable`, `listenAddress` (tailnet), `port`, `hmacSecretFile` (agenix path), `keepaliveInterval` (default ~5 min), `staleTtl` (default ~10–12 min). **NO `haBaseUrl`, NO `haTokenFile`** — the proxy never talks to HA.
- [ ] Implement the proxy (small service). Two inbound surfaces, tailnet-only: (1) an **ingest webhook** HA POSTs to — verify the **HMAC** against `hmacSecretFile`; on valid, store `{someone_home_bit, last_push_ts}`; on invalid, **reject/drop** (never store). (2) `GET /presence` → `{someone_home: bool|null, ts}`. The served bit is `null`-INITIALIZED (design §5): a boolean is served ONLY when (verified fresh push within `staleTtl`) AND (consent active — Task 3) AND (kill-switch clear — Task 3). No other route, no query params, no way to name an entity.
- [ ] Store ONLY `{bit, last_push_ts}` — **no history structure** (no transitions list, no ring buffer, no `presence_since`), so no timeline can be assembled (design §6).
- [ ] Sandbox the systemd unit (design §7): `DynamicUser`, `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, seccomp `SystemCallFilter=@system-service`, `RestrictAddressFamilies=AF_INET AF_INET6`, `MemoryDenyWriteExecute`, `ProtectKernel*`, read-only FS except a private runtime dir. Bind **Tailscale-only, NEVER public** (both ingest + read). **Inbound-only — egress can be firewalled to nothing** (the proxy never calls out). The proxy user reads ONLY the HMAC secret — no HA token exists to protect.
- [ ] Wire the HMAC shared secret as an agenix secret, mode **0600**, readable only by the proxy user; never in the Nix store plaintext, never in the repo. Add an HMAC-secret-rotation runbook note (regen → re-encrypt both HA + proxy sides → restart).
- [ ] tests (in this task): `nix eval` the module under `tests/module-eval.nix` (enabled + disabled) — imports/evaluates standalone. Assert `serviceConfig` has the hardening set (`NoNewPrivileges`, `ProtectSystem=strict`, `DynamicUser`, `SystemCallFilter`, non-public bind). Assert the module exposes NO `haToken`/`haBaseUrl` option and no second read route. Runtime: a valid HMAC push is stored + served; an **invalid HMAC push is rejected** (not stored); a stale store (no push within `staleTtl`) serves `null` reason `stale`.
- [ ] closing check: `nixos-rebuild dry-build --flake .#sancta-claw` succeeds with the module enabled; `nix eval .#nixosConfigurations.sancta-claw.config.systemd.services.presence-proxy.serviceConfig --json` shows the hardening set and NO HA-token env; module-eval green; the HMAC-reject + stale→null tests pass. Paste evidence.

### Task 3: consent-ledger gate (REUSE existing) + apex kill-switch (REUSE northstar) + fail-closed-as-TYPE + stale-TTL

> Do NOT mint parallel gates (design §9). REUSE the existing consent-ledger at
> `~/.claude/index/consent-ledger.jsonl` with the category `aggregate-presence`;
> REUSE the existing northstar apex kill-switch. No second ledger, no parallel kill.

- [ ] verify-first: confirm the consent-ledger path and JSONL shape and how categories are keyed; confirm the northstar apex kill-switch mechanism the proxy can check per-request (operator/her-writable, Sancta-unwritable).
- [ ] In the proxy read path: on every `GET /presence`, require — in this order — (1) apex kill-switch NOT engaged, (2) an `aggregate-presence` consent entry active (not revoked) AND `expiresAt` in the future, (3) a verified push within `staleTtl`. Any failing ⇒ the bit stays `null`-initialized ⇒ `{someone_home: null, reason: <apex-veto|no-consent|stale>}`.
- [ ] Fail-closed as TYPE (design §5, amendment 3): do NOT add per-error `return null` branches; prove every failing precondition simply never overwrites the `null` initializer. Treat `expiresAt` in the past, and a missing/corrupt/unreadable ledger, as revoked → `null`. **NO last-true-beyond-TTL / no last-value cache** — the stored bit is served ONLY while fresh; past `staleTtl` it reads `null`, never a stale `true` (the one construct that turns fail-closed into fail-OPEN).
- [ ] Wire the northstar apex kill-switch: a per-request runtime check that, when engaged, forces `null` + `reason:apex-veto` **instantly, no rebuild**, short-circuiting FIRST (before consent/freshness). Her-writable through him only.
- [ ] tests (in this task): no consent entry → `null`+`no-consent`; missing/corrupt ledger → `null`; expired `expiresAt` → `null`; stale store (no push within TTL) → `null`+`stale`, and true-then-silent ⇒ `null` (no fail-open); apex-veto engaged → `null`+`apex-veto` even when consent valid AND a fresh true push is stored (veto wins).
- [ ] closing check: run the Task-3 integration tests, all green; paste output including the apex-veto-wins and the true-then-silent⇒null (no fail-open) assertions. Assert the veto forces `null` at runtime (toggle in the harness, no rebuild).

### Task 4: Sancta client path — tailnet, NO HA token

- [ ] verify-first: confirm how Sancta's tick / client currently reaches services (tailnet HTTP); confirm Sancta holds NO HA token anywhere today (`grep -ri 'long.lived\|home.assistant.*token' <sancta config paths>` returns nothing for Sancta hosts); confirm neither Sancta nor the proxy has any HA base URL / HA client.
- [ ] Add the Sancta-side client: a small helper that does `GET /presence` against the proxy over the tailnet and returns `someone_home` (bool | null). It carries NO HA token, knows NO HA URL, and has NO way to name an HA entity.
- [ ] Ensure Sancta's only presence signal is this bit — no direct HA path is added anywhere for Sancta.
- [ ] Enforce the no-timeline usage invariants (design §6, §8): the client does NOT persist `/presence` responses into memory / dream / the meaning-index (no durable write of the bit or its `ts`), and does NOT join the bit against any other presence-bearing signal (calendar / location / frame). The bit is read and used in isolation, in-the-moment only.
- [ ] tests (in this task): the client reads the bit from the proxy; a test asserting the Sancta client/config contains NO HA token and NO HA base URL (grep-based, fails if either appears); a test that the client cannot request a specific entity (no such parameter exists); a test asserting no code path writes a `/presence` response into a durable substrate (memory/dream/index) — grep/structural.
- [ ] closing check: run the client tests + the no-HA-token + no-persistence assertions, all green; paste output.

### Task 5: test suite — aggregation is OR + non-denominated; the structural blindness invariants

- [ ] verify-first: confirm the test harness location and how the other module tests are wired into `flake.nix` `checks`.
- [ ] Unit (HA-side, from Task 1): the pushed aggregation is a plain **OR** across allowlisted entities AND is **non-denominated** — the pushed bit is identical for {she alone}, {he alone}, {both}; the push payload is exactly `{someone_home, ts}` with NO count, NO which-person, NO per-person / entity field.
- [ ] Structural property (amendment 3): assert **no code path serves a non-`null` bit without passing the full validation chain** (verified-fresh-push + consent + kill-switch-clear). The "fail-closed is a type" proof, not a list of branch tests.
- [ ] Property: **the proxy holds NO HA token, NO HA base URL, NO HA client** anywhere (grep + `serviceConfig` eval) — token-absence is structural, not just Sancta-side.
- [ ] Integration (the privacy invariants, each its own case):
  - no-consent / missing-corrupt-ledger → `null` (from Task 3, re-asserted at suite level);
  - stale store (no verified push within `staleTtl`) → `null`+`stale`, and true-then-silent ⇒ `null` (no fail-open cache);
  - an **HMAC-invalid push is rejected** and never appears in `/presence` (from Task 2);
  - **`device_class` drift** — an allowlisted entity's class changes HA-side → excluded from the OR → the pushed bit does not silently carry a biometric value (allowlist-drift / rename leak, design §8, HA-side fixture from Task 1);
  - apex-veto → `null` (from Task 3);
  - **Sancta has no HA token and no HA path** — assert structurally (grep + config eval) that Sancta cannot reach HA except via `/presence`, and does not persist/join the bit (from Task 4).
- [ ] Wire the tests into `flake.nix` `checks` (x86_64-linux) so CI runs them.
- [ ] closing check (Sancta-verifiable half, design §12): `nix flake check` (or the targeted check) runs the full suite green; paste the attrNames of the new checks and the passing output. STOP and escalate if ANY privacy-invariant test fails.
- [ ] WITNESS-routed check (design §12, frame-blind precedent): the live "does HA actually push, does the live bit track reality" e2e touches real PII — **Sancta does NOT run it**. Flag in the PR/commit that Alexandru (or the Witness) confirms live behavior da/no in a separate window; Sancta stays blind and records only the da/no verdict.

## Constraints  (HARD "do NOT" rules — privacy scope-guards)

These are inviolable. Any task that would require breaking one must STOP and
escalate to the human, not work around it.

- **Gate 0 — Amputation is a structural PRECONDITION (design "Gate 0").** The
  proxy is theater unless Sancta is structurally UNABLE to reach HA by any other
  path. Three amputations must be VERIFIED before this plan is built/activated:
  (1) remove the `home-assistant` MCP server from Sancta's config — no
  `mcp__home-assistant__*` tool (grep → zero `home-assistant`); (2) no SSH/shell
  to the HA host/container (Sancta → HA host = permission denied); (3) no direct
  network route to the HA API port (Sancta → `HA:port` = connection refused). This
  is the AGENT-CAPABILITY wall; the proxy is only the data-path mediator. Ordering:
  her assent → his approval → **Gate 0 (verified)** → build → activation.
- **NEITHER Sancta NOR the proxy may hold an HA token.** No long-lived token, no
  scoped token (scoped tokens don't exist for HA), no token file, no HA base URL,
  no HA API client anywhere. The proxy is a dumb sink; it only *receives* pushes.
- **PUSH model only — the PULL model is REJECTED.** Do NOT build a proxy that
  queries HA / holds the HA token. HA aggregates at source and pushes out; the
  proxy never calls HA (design §7, §7.1).
- **NO per-person or denominated presence.** Never expose which person, never a
  count, never a room, never a sensor value. Only the non-denominated aggregate
  OR bit. His wife's patterns must be uninferable from the output.
- **NO endpoint other than `GET /presence` (read) + the single HMAC ingest
  webhook (HA→proxy).** No HA passthrough, no query params, no client-supplied
  entity selection, no history endpoint, no other read route.
- **NO auto-adding HA entities.** Only the operator's explicit HA-side allowlist
  feeds the template sensor. A new/possibly-biometric HA entity stays invisible
  until a human adds it by name. Forgetting must fail CLOSED.
- **Do NOT read HA biometric/health/location values during development.** Test with
  mocks/fixtures, never real personal entities (HA config-check the package on a
  fixture). Sancta (and this build) reads its own PII-amputated outputs only. The
  live e2e is WITNESS-routed to Alexandru (design §12); Sancta stays blind.
- **Fail-closed as a TYPE, not a fallback:** `null` is the initializer; a boolean
  is served ONLY on the fully-validated happy path (verified-fresh-push + consent +
  kill-switch-clear). `null ≠ false`.
- **NO last-true-beyond-TTL / no last-value cache** — the one construct that
  silently turns fail-closed into fail-OPEN. Past `staleTtl` the proxy serves
  `null`, never a stale `true`.
- **Stale-TTL is NORMAL:** keepalive ~5 min, stale threshold ~10–12 min (≈2×
  keepalive) as module-option defaults — tolerate one missed keepalive, fail
  closed on two. HA must re-fire an immediate sync push on restart.
- **Timing mitigation is HA-SIDE STRUCTURE, not manners:** HA quantizes/debounces
  the bit at source (hysteresis `for:` on the change trigger) before it is pushed;
  polling cannot out-resolve the push. The proxy stores ONLY `{bit, last_push_ts}`
  with NO history structure.
- **NO persistence or cross-signal join of the bit:** never write a `/presence`
  response into memory / dream / the meaning-index; never correlate the bit with
  calendar / location / frame / any other presence-bearing signal. (Closes the
  temporal + cross-signal denomination gap, design §8.)
- **Guard `device_class` HA-SIDE (in the template):** an allowlisted entity whose
  class drifted is excluded from the OR, never silently contributing a biometric
  value; prefer whole-home occupancy entities over per-person device-trackers.
- **REUSE existing gates — do NOT mint parallel ones:** the existing consent-ledger
  (`~/.claude/index/consent-ledger.jsonl`, category `aggregate-presence`) and the
  existing northstar apex kill-switch. No second ledger, no parallel kill.
- **The proxy's only secret is the HMAC shared secret**, via agenix mode 0600,
  readable only by the sandboxed proxy user. Never in the repo, never in the Nix
  store plaintext. There is NO HA token to protect anywhere.
- **Verify every push's HMAC; reject the unverifiable** (drop, never store) — a
  forged bit must not enter the store.
- **NO deploy from this plan.** ralphex makes the eval/dry-build-proven edits and
  runs tests only. The `nixos-rebuild switch` to sancta-claw, and applying the HA
  package to the HA host, are HUMAN-ONLY.
- **Never push to `main`.** Branch + PR only; `main` is protected.
- **Use the §5.1/§6 timing defaults as module options**; the operator may tune
  them, but ship the committed "normal" balance as the default.
