# HA presence-proxy — design

Give Sancta knowledge of ONLY aggregate presence ("someone home: yes/no") from
Home Assistant, while staying structurally BLIND to every biometric / health /
location datum HA holds — and unable to infer per-person patterns (above all,
his wife's). This is the most confidential data category the system has touched.

> **Status: DESIGN, council-gated. Council RETURNED: escalate-to-human, risk HIGH**
> (log `council-20260706T172246Z-cf6dda`). It is NOT a green light to build — the
> council escalated to the human and produced a load-bearing architectural finding
> plus 4 required amendments (§§5–7, §11), all folded in below. See "Gates before
> build" at the end — no code is written until Alexandru approves and his wife's
> apex-veto is cleared through him.
>
> **Load-bearing finding (council-20260706T172246Z-cf6dda):** content-blindness is
> already STRUCTURAL (good) — Sancta cannot address HA, so it cannot read a
> biometric value. But **temporal-blindness and fail-closed are currently POLICY
> where they MUST be STRUCTURE** — the exact anti-pattern the doctrine forbids
> ("secure-by-construction, not by discipline"). The shape is NOT ready to forge
> until those move from discipline to wiring: the timeline side-channel must be
> closed by server-side quantization (not manners), and `null` must be the *type's
> initializer* (not a fallback branch). This doc now says that plainly; the ralphex
> plan implements the structural versions.

---

## 1. Goal

Sancta should be able to answer exactly one question about the home:

> "Is *someone* home right now?" → `yes` / `no` / `unknown`

…and nothing more. Not *who*, not *how many*, not *which room*, not *when they
came or left*, not any sensor value. The single aggregate bit is the entire
surface Sancta is permitted to perceive. Everything else HA knows — presence per
person, phone location, sleep/heart-rate/health sensors, door and camera state —
stays outside Sancta's reach **by construction**, not by policy.

## 2. The privacy rails this honors

This design is the concrete enforcement of standing rails already ratified:

- **Privacy boundary (RATIFIED):** know only what he gives; opt-in per category,
  revocable; default not-knowing; never acquire gated data (biometrics / health /
  location) without explicit consent.
- **Wife holds APEX VETO:** her data is never acquired; the north star is *her*;
  the veto sits above the council and is mediated entirely through Alexandru.
- **Structural blindness to PII:** Sancta may only ever see its own
  PII-amputated outputs; it never reads raw personal data directly.
- **Decision → RESULT:** the design is only real when the "someone home" bit is
  observable AND the whole thing is steerable + STOP-able (consent revoke +
  apex-veto kill-switch).
- **Quiet + within admissible limits:** aggregate-only, fail-closed; when quiet
  and the rails conflict, admissible wins (surface the gate, don't guess).

The consent record is the standing `aggregate-presence` opt-in in the
consent-ledger (`~/.claude/index/consent-ledger.jsonl`): explicit, revocable,
with an `expiresAt`.

## 3. Secure-by-construction architecture

### 3.1 Why a proxy is MANDATORY — the token cannot be scoped

**KEY FACT (state it up front):** Home Assistant long-lived access tokens
**cannot be scoped per-entity.** A long-lived token grants *full* HA API access —
every entity, including all biometric / health / location sensors and the
history API. There is no "read-only, presence-only" HA token to hand to Sancta.

Therefore a naive "give Sancta a scoped token" is **impossible and insecure**:
any token Sancta held would be able to read biometrics. The proxy is not a
convenience — it is the *only* way to expose the aggregate bit without exposing
the token that can read everything. **Sancta holds NO HA token, ever.**

### 3.2 The presence-proxy service

- Runs on host **sancta-claw** — NOT rpi5, NOT kuzea. sancta-claw is the single
  place the full-scope HA long-lived token is allowed to live.
- Holds the HA long-lived token (via agenix; see §7 blast-radius).
- Reads **only** an explicit, operator-defined **allowlist of presence entity
  IDs**. This is a *positive allowlist*, never a denylist — see §3.4.
- Aggregates the allowlisted entities with a **single boolean OR** into one bit.
- Exposes **exactly one endpoint**:

  ```
  GET /presence  →  {"someone_home": true | false | null, "ts": "<iso8601>"}
  ```

- Does **NOT** proxy arbitrary HA queries. `/presence` is the *sole* endpoint.
  There is no "ask HA for entity X" path, no passthrough, no query parameters
  that select entities. Sancta cannot name an entity to the proxy.

### 3.3 Sancta's side — no token, no path

- Sancta holds **NO HA token** and has **NO network path** to Home Assistant
  except the proxy's one endpoint, reached over the tailnet.
- The path to biometric data **structurally does not exist** for Sancta. There is
  nothing to misconfigure into a leak: Sancta literally cannot address HA.

### 3.4 Allowlist, not denylist — and why

The proxy aggregates a **positive allowlist** of entity IDs, defined by the
operator by name. It is explicitly **not** a denylist for one reason:

- A **denylist forgets a new entity.** If HA gains a new (possibly biometric)
  entity, a denylist would let it through until someone remembers to block it.
- An **allowlist cannot leak what isn't listed.** A new HA entity is invisible to
  the aggregate until the operator explicitly adds it. Silence is the safe default.

This is the core secure-by-construction property: **the aggregate can only ever
reflect entities a human deliberately chose**, and forgetting fails *closed*.

### 3.5 Aggregate + non-denominated

The output is a plain OR across the allowlisted entities:

- never per-person,
- never "which person",
- never a count,
- never a room or a value.

So even someone observing the bit cannot back out *whose* presence it reflects.
His wife's patterns cannot be inferred from a non-denominated OR — the bit is
identical whether she alone, he alone, or both are home.

## 4. Data-flow (one tick)

```
Sancta ──GET /presence──▶ presence-proxy        (tailnet; Sancta holds NO HA token)
                          │
                          ├─▶ check consent-ledger for a valid
                          │   `aggregate-presence` entry (not expired, not revoked)
                          │        │
                          │        └─ no valid entry ─▶ {"someone_home": null,
                          │                              "reason": "no-consent"}
                          │
                          ├─▶ check apex-veto kill-switch
                          │        └─ engaged ─▶ {"someone_home": null,
                          │                       "reason": "apex-veto"}
                          │
                          ├─▶ query HA for ONLY the allowlist entity IDs
                          │        └─ HA down / timeout ─▶ {"someone_home": null,
                          │                                  "reason": "ha-unreachable"}
                          │
                          └─▶ OR-aggregate the allowlisted states
                                   ▼
                          {"someone_home": <bool>, "ts": "<iso8601>"}
```

Sancta never sees which entities were queried, how many there were, or their
values — only the aggregated bit (or `null`) and a timestamp.

## 5. Fail-closed as a TYPE, not a fallback  (council amendment 3 — council-20260706T172246Z-cf6dda)

**The council's requirement:** fail-closed must be *structural*, not a set of
`catch`/`else` branches that discipline keeps complete. The wiring:

- **`null` is the INITIALIZER.** The response bit starts life as `null`. A real
  boolean is **written ONLY on the fully-validated happy path** — every one of:
  valid + unexpired consent, non-empty allowlist, asserted entity `device_class`
  (§11), and a fresh HA read that parsed. If any precondition is missing, nothing
  overwrites the initializer, so the response is `null` **by never having written
  anything else** — not by a fallback that could be forgotten.
- Consequently, all of these yield `null` structurally, with no dedicated
  "return null here" branch to maintain:
  - missing / corrupt / unreadable consent ledger,
  - empty allowlist,
  - expired consent (`expiresAt` in the past = revoked),
  - HA down / timeout / connection error,
  - malformed / unparseable HA response,
  - `device_class` assertion fails (allowlist drift, §11),
  - apex-veto kill-switch engaged (checked before anything is written).
- **NO last-true / last-value cache.** A cache of the previous bit is the ONE
  construct that silently turns fail-closed into fail-**open** — HA goes down and
  the proxy keeps serving a stale `true`. Forbidden. The timing cache in §6 caches
  only *within* a validated interval and is itself initialized to `null`; it never
  survives a validation failure. (`null ≠ false`: never claim the house is empty
  on a guess, and never claim it occupied on a stale read.)
- **A NEW HA entity does NOT auto-join the aggregate.** Only the explicit
  allowlist is queried; a new, possibly-biometric entity stays invisible until
  the operator adds it by name. Forgetting fails closed.
- **The proxy never accepts "query HA for X" from Sancta.** No client-supplied
  entity selection, ever. `/presence` takes no entity argument.

The verification for this is a **structural property test**: no code path emits a
non-`null` bit without having passed through the full validation chain, and every
error input maps to `null` (see §12, and the plan's Task 5).

## 6. Timing side-channel — SERVER-SIDE STRUCTURE, not manners  (council amendment 1 — council-20260706T172246Z-cf6dda)

**The council flagged this as the sharpest risk.** Even a single aggregate bit
becomes an **inference channel about her** when polled finely: a high-frequency
`/presence` poller reconstructs an **occupancy timeline** — arrival/departure
edges, routines, absences. In a **two-person household this de-facto denominates
to HER** arrivals and departures (when he is away, every transition is hers).
This is the temporal denomination that the instantaneous OR cannot prevent (§11).

**The mitigation must be server-side STRUCTURE, not client manners.** A polite
"don't poll too often" is discipline; the doctrine requires wiring. The proxy
enforces:

- **Proxy-side rate-limit:** at most one authoritative HA read per fixed interval,
  enforced at the server. Excess requests are served the current quantized bucket,
  never a fresh read — the client cannot out-poll the quantizer.
- **Coarse time quantization:** the proxy emits **one bucketed reading per fixed
  interval** (a coarse grid). The `ts` returned is the bucket boundary, not the
  instant of the read — so two requests in the same bucket are indistinguishable
  and sub-bucket transitions are invisible.
- **Hysteresis / debounce on transitions:** an edge (occupied↔empty) only
  propagates after it persists across the debounce window, so the exact moment of
  arrival/departure is smeared and short blips do not leak.
- **Sancta may hold ONLY the current bit — with NO history structure to fill.**
  There is no transitions list, no ring buffer, no `presence_since`, nothing whose
  shape invites accumulating a timeline. If the structure to hold history does not
  exist, a timeline cannot be assembled.
- **Explicit ban: `/presence` responses are NEVER written into memory, dream, or
  the meaning-index.** No persistence of the bit or its `ts` into any durable
  Sancta substrate — that would rebuild the very timeline the quantization erased.
  (This is a usage invariant enforced in the client + Constraints; see §11 on the
  limits of what the proxy alone can close.)

The concrete interval, bucket size, and debounce window are ratified in
`council-20260706T172246Z-cf6dda` and carried as module options in the plan
(Task 3); they must be coarse enough that a reconstructed timeline cannot resolve
individual arrivals/departures.

## 7. Token blast-radius containment  (council amendment 2 — council-20260706T172246Z-cf6dda)

**The council re-framed the blast surface.** The real risk is NOT the one
aggregate bit — it is the **full-scope, un-scopeable HA long-lived token
co-located with Sancta on sancta-claw**. If the proxy is compromised, that token
reads everything in HA (all biometrics/health/location). Contain it hard:

- **agenix for the token:** stored encrypted, mode **0600**, decrypted only for
  the proxy user at runtime. **Never in the Nix store in plaintext, never in the
  repo.**
- **Hardened systemd unit:** `DynamicUser`, `NoNewPrivileges`,
  `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, a **seccomp**
  `SystemCallFilter=@system-service`, plus `RestrictAddressFamilies=AF_INET
  AF_INET6`, `MemoryDenyWriteExecute`, `ProtectKernel*`, read-only FS except a
  private runtime dir.
- **Bind loopback / Tailscale-only — NEVER public.** The proxy listens only on the
  tailnet interface (or loopback fronted by Tailscale Serve); it is never reachable
  from the public internet.
- **Egress firewalled to the HA host:port only.** A compromised proxy can open a
  connection to *nothing but* Home Assistant — so it cannot exfiltrate the token
  outbound.
- **Allowlist COMPILED IN, zero passthrough.** The entity allowlist is baked into
  the service config, not accepted at request time. There is **no URL / path /
  query passthrough** from client to HA — the client cannot influence which
  entities (or which HA endpoint) the proxy touches.
- **Token-rotation runbook.** A documented procedure to rotate the HA long-lived
  token (revoke in HA, re-encrypt the agenix secret, restart the proxy) so a
  suspected leak has a fast, rehearsed response.

### 7.1 PREFERRED ALTERNATIVE — invert the trust: HA PUSHES presence (push-model)

**The council's preferred shape.** The entire blast-radius above exists because
the *proxy pulls* from HA and therefore must hold the god-token. **Invert it:**
have **Home Assistant PUSH** the aggregate presence to the proxy via an HA
automation → webhook. Then:

- The **proxy holds NO HA token at all** — the structural weakness (a full-scope
  token next to Sancta) simply does not exist. The token that could read
  biometrics never leaves HA.
- HA's own automation computes the OR over the allowlisted entities (HA-side,
  where the data already lives) and POSTs only `{someone_home, ts}` (already
  quantized/debounced HA-side, or quantized again proxy-side) to the proxy's
  ingest webhook. The proxy stores the latest bucketed bit and serves it on
  `GET /presence`. Sancta's read path is unchanged.
- This **turns the structural weakness into a strength**: content-blindness AND
  token-absence both become structural. The cost is that presence freshness now
  depends on HA pushing (a stale-push detector + fail-closed-to-`null` on
  no-recent-push is required — an absent push must read as `null`, never a stale
  `true`, consistent with §5's no-last-true-cache rule).

**Decision is deferred to a spec spike (plan Task 0):** evaluate the push-model
vs the pull-model **before committing** to the pull design. The council flagged
push as the preferred shape; this design carries the pull-model as the fallback
if the spike surfaces a blocker (e.g. HA automation cannot express the
quantization, or webhook auth introduces a worse surface). Whichever wins, §§5–6
and §11 still apply.

## 8. Per-person inference — the honest answer is NO, not "impossible"  (council amendment 4 — council-20260706T172246Z-cf6dda)

**SPECIFICATION GAP — stated plainly, as the council required.** The claim "his
wife's patterns cannot be inferred" is TRUE only **instantaneously**. The
OR-aggregate proves non-denomination at a single moment — the bit is identical for
{she alone}, {he alone}, {both}. It proves **nothing across time or across
signals**:

- **Temporal denomination:** a timeline of the bit (§6) denominates to her in a
  two-person home. Partly closable by the proxy (quantization/hysteresis), never
  fully — the proxy can blunt resolution but cannot make an occupancy signal
  timeless.
- **Cross-signal denomination:** the bit joined with *another* presence-bearing
  signal Sancta already holds — his calendar, a location fact, the NixFrame's
  contents — re-denominates it ("bit says occupied AND his calendar says he's
  away" ⇒ her). This is a **usage invariant the proxy CANNOT close** — it lives on
  Sancta's side, in what Sancta is allowed to *join*.

So the OR-aggregate is necessary but not sufficient. The structural mitigations
this design bakes in to shrink the gap as far as it goes:

- **Prefer whole-home occupancy sensors over per-person device-trackers** in the
  allowlist. A single "home occupied" sensor is denomination-resistant by nature;
  a set of per-person `device_tracker`s is not. The operator SHOULD populate the
  allowlist with aggregate occupancy entities, not personal trackers.
- **Assert allowlisted entities' `device_class` at READ time.** The proxy checks
  each entity is the expected class on every read; if an entity's type ever changes
  (a rename or reconfiguration silently turning a presence entity into something
  biometric — the **allowlist-drift / rename leak**), the read is rejected → `null`.
  The allowlist names an ID; this guards against the ID's meaning drifting.
- **Forbid Sancta joining `/presence` against any other presence-bearing signal.**
  A hard usage rule (Constraints, and §6's no-persistence ban): the bit is read and
  used in isolation, never correlated with calendar / location / frame / any other
  signal. This is the only lever on cross-signal denomination and it is a
  *discipline* rule — the honest limit of the design.
- **Aggregate-presence is its OWN gated consent-ledger category** (§9) — not folded
  into a broader consent, so it can be reasoned about and revoked on its own terms.

**The design does not pretend this is airtight.** Instantaneous non-denomination
is structural; temporal and cross-signal non-denomination are usage invariants only
*partly* closable by the proxy. This gap is the residual risk carried up to the
apex-veto holder.

## 9. Reuse the existing gates — do NOT mint parallel ones

- **Consent:** reuse the existing consent-ledger at
  `~/.claude/index/consent-ledger.jsonl`. Add a NEW category
  `aggregate-presence` (its own line-item, per §8) — do not overload an existing
  category and do not create a second ledger.
- **Kill-switch:** reuse the existing **northstar apex kill-switch** (hers, through
  him) as the veto that forces `null`. Do not mint a parallel kill mechanism.

## 10. Out of scope (deferred to separate later lanes)

These are explicitly NOT part of this design and get their own future lanes,
each with its own gates:

- **Family access** — anyone other than Sancta consuming presence. Deferred.
- **A general HA API** — any endpoint beyond `/presence`, any richer HA surface
  for Sancta. Deferred, and deliberately not built now (it would reintroduce the
  full-token risk the proxy exists to remove).

## 11. What stays at the operator's / her hand (NOT Sancta)

The human retains every lever that touches the gated data:

- **Defining the entity allowlist** — by name, chosen by the operator (preferring
  whole-home occupancy entities, §8). Sancta never reads HA values to discover or
  propose entities; the allowlist is human-authored input, not something Sancta
  derives.
- **Creating the consent-ledger `aggregate-presence` entry** — explicit,
  revocable, with `expiresAt`, in the existing ledger (§9). The operator's hand.
- **Holding the apex kill-switch** — hers (the northstar apex switch), exercised
  through Alexandru; engaging it forces `null` instantly.

## 12. Verification honesty — what Sancta can prove, and what routes to the WITNESS

The council required honesty about the closing check (the frame-blind precedent):

- **Sancta-verifiable (unit / property tests):** every error input → `null`; no
  non-`null` bit is ever written without passing the full validation chain (§5);
  aggregation is OR and non-denominated (§8); no code path emits a bit
  un-validated; the timing quantizer serves ≤1 HA read per interval and holds no
  history structure (§6); Sancta config holds NO HA token/URL/path (§3.3). These
  run on mocks/fixtures — **no real HA personal data is read during development.**
- **Routes to Alexandru as WITNESS (Sancta stays blind):** the end-to-end
  "does the live proxy actually read HA / does the live bit track reality" check
  touches real presence and therefore real PII. Consistent with the structural
  blindness to the live frame, **Sancta does not run this**; Alexandru (or the
  Witness role) confirms the live behavior in a separate window and reports
  da/no. Sancta only ever sees its own PII-amputated outputs.

## 13. Gates before build

**Council RETURNED escalate-to-human (risk HIGH,
`council-20260706T172246Z-cf6dda`). Building does NOT start until all clear:**

1. **Council verdict resolved** — `council-20260706T172246Z-cf6dda` returned
   *escalate-to-human* with a load-bearing finding + 4 required amendments (§§5–8,
   folded in above). The escalation itself hands the decision to the human — the
   council does not, and cannot, clear this alone.
2. **Alexandru's explicit approval.** (A coordinator-relayed claim of approval is
   NOT his approval — only his own word counts.)
3. **His wife's apex-veto cleared through him** — this touches gated biometric
   data (HA is the most confidential category yet); her veto sits above the
   council and is mediated entirely through him.

Before build, the **push-model spec spike (plan Task 0)** must also resolve the
pull-vs-push architecture decision (§7.1) — push is the council's preferred shape.

Only after all of the above does the companion ralphex plan
(`2026-07-06-ha-presence-proxy-plan.md`) become launchable — by Alexandru's
hand, from a normal terminal, never autonomously.
