# HA broker hybrid — design

Give Alexandru the communication channel he wants with Home Assistant —
**filtered** — by standing up a separate **BROKER entity** that owns ALL HA
reach, while Sancta stays structurally blind to HA. The Gate-0 amputation
(PR #522) stops being a config promise and becomes a **service boundary**: HA
credentials live only with the broker; Sancta holds zero HA creds and zero
route.

> **Status: DESIGN, docs-only.** Decided with Alexandru 2026-07-08 — his
> choices: the **hybrid (c)** shape, then the **B0 scope** (Plane A only, no
> control channel in V1). This doc **EXTENDS** the committed 2026-07-06
> push-model design (`2026-07-06-ha-presence-proxy-design.md`) and the Gate-0
> amputation (#522) — it does not replace or contradict either. **This doc does
> NOT authorize building.** The gates in §7 remain fully open; the existing
> ralphex plan (`2026-07-06-ha-presence-proxy-plan.md`) stays parked.

---

## 1. Intent

Alexandru wants a communication channel with Home Assistant, but FILTERED. The
chosen shape: a separate **broker** — its own repo, its own host/service
identity, its own secret store — mediating **all** HA access. HA credentials
live ONLY with the broker. Sancta never talks to HA; Sancta talks (in the
narrowest possible way) to the broker's fixed outputs.

The Gate-0 amputation from #522 ("so Sancta cannot, not so Sancta promises not
to") is the prerequisite this design builds on: once Sancta's HA MCP tools are
removed, SSH to the HA host is cut, and the network route is firewalled, the
broker is the **one door** — and the amputation is realized as a *service
boundary*, not a per-host config promise that discipline keeps true.

## 2. The hybrid — two planes that never touch

The channel splits into two planes with categorically different trust models.
They share the broker identity but **never mix**:

### Plane A — FIXED PROJECTIONS (sensitive, structurally bounded)

- The broker computes **fixed, minimized projections at source** — concretely,
  the HA-side template `binary_sensor.someone_home` OR-aggregate from the
  2026-07-06 design — and **PUSHES** `{bool, ts}` over the HMAC-signed tailnet
  webhook. The push model, stale-TTL → `null`, fail-closed-as-type,
  consent-ledger gate, and apex kill-switch are all **kept verbatim** from the
  committed design; Plane A *is* that design, now owned by the broker identity.
- Sancta can only READ the projection: `{true | false | null}`. The narrow
  wire type makes biometrics **UNREPRESENTABLE** — a bool+ts cannot carry a
  heart rate, a location, or a name, no matter what goes wrong upstream.
- **No queries from Sancta — push-only, no pull.** A pull surface, even a
  "filtered" one, would re-create the proxy-for-access theater already
  rejected (#521 / design §7 + Gate-0 finding in #522): a mediator in the data
  path that a query surface slowly widens back into access.

### Plane B — CONTROL CHANNEL (non-sensitive, policy-bounded — NOT IN V1)

- An **enumerated allowlist of write-only ACTIONS** — e.g. `light.turn_on`,
  `scene.turn_on` on named entities. Responses are **ack/fail only**; NO state
  reads pass through it, ever.
- Prompt-injection blast radius = a light turns on. Never a leak: Plane B verbs
  **NEVER return Plane A state** (not even "the light is already on" — just
  ack/fail).
- **DECISION (Alexandru, 2026-07-08): V1 = B0 — Plane A only, NO control
  channel at all.** B1 (lights + scenes) is a SEPARATE future step behind its
  own gate. B1/B2 below are roadmap, not scope.

## 3. The broker as a separate entity — why it strengthens the prior design

The 2026-07-06 design already has the dumb-sink proxy. The new element is the
**broker as a SEPARATE identity**:

- **Own repo** — the broker's code, config, and review history are not
  Sancta's; Sancta cannot quietly grow the broker's surface from inside its own
  substrate.
- **Own host / service account** — the broker runs where Sancta has no shell
  (per Gate-0 amputation 2).
- **Own secret store** — every HA credential (the un-scopeable long-lived
  token included, if the broker ever needs one HA-side) lives ONLY with the
  broker. Sancta's side: **zero HA creds, zero route** — MCP-off + SSH-cut +
  firewall, exactly the three Gate-0 amputations, verified as in #522.
- **Complete mediation** — one door HA→broker, one choke-point broker→Sancta.
  There is exactly one place to audit, one place to kill, one place where the
  filter lives.

Gate-0 said the proxy is theater while side-doors exist. The broker-as-entity
is the positive restatement: after amputation, the broker is not *a* wall in
the data path — it is the **only** path, held by an identity that is not
Sancta.

## 4. The structural argument (why two planes, and the honest gap)

From the /architect pass — the load-bearing distinction:

- A **fixed projection is provably bounded.** It has no will; it computes the
  same OR-aggregate every time; it cannot be "talked into" leaking. Its output
  type (`bool | null`) cannot represent what it must not carry.
- An **agent-that-filters is only policy-bounded.** An LLM/agent broker asked
  to "answer questions about the home, but filter out the sensitive parts" can
  be prompt-injected, pressured, or confused into oversharing. Its bound is a
  promise, and promises are not walls (the Gate-0 principle again).

Hence the plane split: **sensitive data ONLY ever crosses over fixed
projections** (Plane A); any conversational/agentic channel is reserved for
**non-sensitive control** (Plane B), where the worst case is an unwanted
`light.turn_on`, not a leak.

**Specification gap — stated honestly:** the broker becomes the **new trust
kernel**. The service boundary proves Sancta cannot bypass the broker; it does
NOT prove the broker's own filter is correct (that the projection really is a
pure OR, that Plane B really returns only ack/fail). That correctness needs its
own review + tests in the broker's repo, and the live end-to-end check remains
**witness-routed** (design §12): Alexandru confirms; Sancta stays blind.

## 5. Tool choices (scout-pass recommendations, not mandates)

- **Push (Plane A):** HA-native template `binary_sensor` + webhook /
  RESTful-notify push — minimal custom code, the minimization stays at the
  source, as the committed design requires.
- **Transport:** Tailscale + HMAC — the existing fleet patterns; no new mesh,
  no new PKI.
- **IF a richer bus is ever needed (B1+):** MQTT with per-topic ACLs
  (Mosquitto) gives *structural* topic-level filtering — the broker publishes
  only allowlisted topics, the ACL (not a promise) bounds what Sancta's
  credentials can subscribe to. Noted for B1+ evaluation, **NOT V1**.

## 6. Delivery path — smallest first (umputun: no perfect, smallest first)

B0 proves the wall with ONE bit end-to-end. Each later step is a separate PR
behind its own gate:

| Step | Scope | Gate |
|---|---|---|
| **B0** (V1) | Plane A only: the presence bit, push-only, `{bool\|null}` | §7 gates — all of them |
| **B1** (future) | Plane B minimal: lights + scenes allowlist, ack/fail only | its own PR + its own gate |
| **B2** (maybe) | Plane B wider: climate / media verbs | its own PR + its own gate |

Plane B verbs never return Plane A state — the rule holds at every step.

## 7. Gates before build (unchanged — restated)

The gate chain from the 2026-07-06 design + #522 is unchanged:

> **her assent (concept) → his approval → GATE-0 AMPUTATION VERIFIED
> (home-assistant MCP off + SSH isolation from the HA host + firewall) →
> build → activate**

- The live e2e touches real PII → **witness-routed to Alexandru**; Sancta
  stays blind (design §12, the frame-blind precedent).
- **This design doc does NOT authorize building.** The existing ralphex plan
  (`2026-07-06-ha-presence-proxy-plan.md`, DO-NOT-LAUNCH header) stays parked.
  A future **B0 plan** would be written only after the gates clear — and would
  execute Plane A under the broker identity described here.

## 8. Relationship to the existing docs

- **EXTENDS `2026-07-06-ha-presence-proxy-design.md`:** the push model —
  HA-side aggregation, HMAC tailnet webhook, stale-TTL `null`,
  fail-closed-as-type, consent-ledger `aggregate-presence` gate, apex
  kill-switch, witness-routed e2e — is kept **verbatim as Plane A**. Where this
  doc and that one describe the same mechanism, that one is authoritative.
- **KEEPS #522's Gate-0 as a hard prerequisite**, now *realized* as a service
  boundary: the amputations are what make "the broker is the only door" true,
  and the broker identity is what makes the amputation durable.
- **Not a replacement — an elaboration:** the new content is (a) the broker as
  a separate identity owning all HA reach, and (b) the hybrid two-plane roadmap
  with the B0 decision. Everything else stands as written.
