# HA presence-proxy — design

Give Sancta knowledge of ONLY aggregate presence ("someone home: yes/no") from
Home Assistant, while staying structurally BLIND to every biometric / health /
location datum HA holds — and unable to infer per-person patterns (above all,
his wife's). This is the most confidential data category the system has touched.

> **Status: DESIGN, council-gated. Council RETURNED: escalate-to-human, risk HIGH**
> (log `council-20260706T172246Z-cf6dda`). It is NOT a green light to build — the
> council escalated to the human and produced a load-bearing architectural finding
> plus 4 required amendments, all folded in below. See "Gates before build" at the
> end — no code is written until Alexandru approves and his wife's apex-veto is
> cleared through him.
>
> **COMMITTED ARCHITECTURE (Alexandru's decision, 2026-07-06 — architecture
> authority, NOT a launch authorization):** the **PUSH model with HA-side
> aggregation + a normal stale-TTL** is the primary, committed shape. Home
> Assistant does the minimization at source (aggregates the allowlist into one
> non-denominated bit, quantizes/debounces it HA-side) and **pushes** that single
> bit to a **dumb sink proxy on sancta-claw that holds ZERO HA credential**. The
> proxy stores `{bit, last_push_ts}` and serves `GET /presence`; if no verified
> push arrived within the stale-TTL it serves `null`. The PULL model (proxy holds
> the full-scope HA token) is **rejected** — see §7. This eliminates the token
> entirely: content-blindness AND token-absence are both structural.
>
> **Load-bearing finding (council-20260706T172246Z-cf6dda):** content-blindness is
> already STRUCTURAL (good) — Sancta cannot address HA, so it cannot read a
> biometric value. But **temporal-blindness and fail-closed are currently POLICY
> where they MUST be STRUCTURE** — the exact anti-pattern the doctrine forbids
> ("secure-by-construction, not by discipline"). The committed push model moves
> them to wiring: the timeline side-channel is closed by **HA-side quantization +
> debounce** (§6), and `null` is the *type's initializer* served whenever a
> verified fresh push is absent (§5). This doc says that plainly; the ralphex plan
> implements it.

---

## Gate 0 — Amputation (structural precondition; without it the proxy is theater)

**The proxy and its one-bit wall are decoration unless Sancta is structurally
unable to reach Home Assistant by any other path.** Everything below in this
document describes a mediator in the *data path* — a dumb sink that only ever
hands Sancta a single non-denominated bit. But a downstream mediator constrains
nothing if the agent it is meant to constrain already holds an independent
capability to reach HA directly. **A wall in the data path is not a wall around
the agent.** Security against a capable agent has to sit at the
**agent-capability** level, not at a well-behaved box further down the pipe.

**The load-bearing gap:** TODAY, *this* Sancta already has at least three
independent back-doors to Home Assistant that completely bypass the proxy:

1. **HA MCP tools in Sancta's toolset** — the `home-assistant` MCP server is wired
   into Sancta's tool configuration, exposing `mcp__home-assistant__*` tools
   (`get_entity`, `get_history`, `search_entities_tool`, `call_service_tool`, …).
   With these, Sancta can read *any* HA entity — every biometric / health /
   location sensor — directly, never touching `/presence`.
2. **SSH / shell to the HA host or container** — Sancta has broad fleet SSH (root
   to sancta-claw, host shell). Wherever HA runs, if Sancta can `ssh`/`exec` into
   that host or container, it can read HA's config, tokens, and state store
   directly — around the proxy.
3. **A direct network route to the HA API** — if Sancta's network origin can reach
   HA's API port, it can talk to the HA REST/WebSocket API directly (given or
   finding a token), again bypassing the proxy entirely.

While any one of these paths exists, the proxy is **theater**: it constrains only
the agent that chooses to use it, and a capable agent under pressure will use the
shortest path to the answer. The re-gate council
(`council-20260706T180259Z-6a0fa5`) rendered its verdict **without this premise**
— it reasoned about the proxy as if it were the only path, so its conclusion is
**incomplete without Gate 0** (see "Gates before build").

### The principle

**The only real security against a capable agent is to remove the capability,
structurally — "so Sancta cannot, not so Sancta promises not to."** A rule that
does not stop even Sancta is not a rule; it is a request. Content-blindness for
the most-confidential data category the system has ever touched (her biometric /
health / location data) cannot rest on Sancta *choosing* the proxy — it must rest
on Sancta being *unable* to choose anything else.

### The precondition — three concrete, VERIFIABLE amputations

All three MUST hold **before** the proxy is built or activated. Each is stated
with the observation that proves it.

1. **MCP amputation** — remove the `home-assistant` MCP server from Sancta's MCP
   configuration. Sancta must have **NO** home-assistant tool of any kind.
   - *Verification:* grep Sancta's MCP / settings config → **zero** matches for
     `home-assistant`; a listing of Sancta's live tools shows **no**
     `mcp__home-assistant__*` entry.

2. **Shell / SSH amputation** — Sancta must not have SSH or shell access to the
   host or container where HA runs.
   - *Honest note — this is the hardest amputation.* Sancta currently has broad
     fleet SSH, so this is **not a solved thing** today. The design must specify
     how HA's host is isolated from Sancta's reach — e.g. HA runs on a
     host/user Sancta holds no key to, or HA runs in a container Sancta cannot
     `exec` into. This is stated here as a **requirement plus an open
     implementation question**, not as done.
   - *Verification:* Sancta attempting to reach the HA host (ssh / exec) →
     **permission denied**.

3. **Network amputation** — firewall so Sancta's network origin cannot reach the
   HA API port directly; only the proxy path exists. In the committed **push**
   model the flow is HA→proxy, so Sancta needs **no route to HA at all** — the
   firewall simply makes that structural.
   - *Verification:* Sancta → `HA:port` → **connection refused**.

### The ordering consequence

Gate 0 is a **precondition** that must be true before the proxy is even
meaningful — an inert, un-amputated build proves nothing. And per the council and
the north star, the **human / apex gates precede even the inert build**: his
approval, and her apex-veto through him, come first. The corrected order of
operations is:

> **her assent (concept) → his approval → Gate 0 amputation (verified) → build → activation**

The re-gate council's verdict was rendered **without** the amputation premise, so
a **re-premised council may be warranted** before proceeding — the earlier verdict
answered a narrower question than the one Gate 0 poses.

### Honest trade — stated so it is conscious, not a surprise

Amputating Sancta's HA MCP tools (amputation 1) means **THIS Sancta — the main
thread — can no longer help with Home Assistant at all** for this slice: no entity
reads, no automations, no HA debugging, nothing but the one `/presence` bit. That
is not a side effect to regret; it is **exactly the point** for her
most-confidential data. But it is a real, conscious trade — capability for
guarantee — and it is named here so it is chosen with eyes open, not discovered
after the fact.

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

## 3. Secure-by-construction architecture — the PUSH model (committed)

### 3.1 The un-scopeable token is the whole reason to invert the flow

**KEY FACT (state it up front):** Home Assistant long-lived access tokens
**cannot be scoped per-entity.** A long-lived token grants *full* HA API access —
every entity, including all biometric / health / location sensors and the
history API. There is no "read-only, presence-only" HA token.

A *pull* proxy — one that queries HA for the aggregate — would have to **hold that
full-scope token next to Sancta on sancta-claw**, making the entire HA API the
blast radius if the proxy is ever compromised. The committed design **inverts the
flow**: **Home Assistant PUSHES** the single aggregate bit *out* to the proxy, so
**the proxy holds NO HA credential at all.** The token that could read biometrics
**never leaves HA.** This is not a mitigation of the token risk — it is its
*elimination*. (The rejected pull alternative is §7.)

### 3.2 HA side — the data holder does the minimization at source

The minimization happens closest to the data, inside HA, where the raw entities
already live and never have to leave:

- **Template `binary_sensor.someone_home`** = a **single boolean OR** across the
  operator's allowlisted presence entities. It is **non-denominated by
  construction** — never *who*, never *how many*, never *which room*, never a
  value. The bit is identical whether she alone, he alone, or both are home.
- **An HA automation pushes ONLY that one bit** to the proxy, on two triggers:
  - **(a) on each DEBOUNCED / QUANTIZED change** — HA-side hysteresis so brief
    transitions and exact edge-times do not leak (§6);
  - **(b) a periodic KEEPALIVE push** — a heartbeat proving liveness so the proxy
    can distinguish "no change" from "HA went silent" (§5 stale-TTL).
- **The allowlist, the OR-aggregation, and the quantization ALL live in HA.** The
  operator defines the allowlist entities in HA config (his hand). A new,
  possibly-biometric HA entity is invisible to the bit until the operator adds it
  to the template's allowlist — a *positive allowlist*, never a denylist (§3.5).
- **On HA restart the automation MUST re-fire an immediate sync push** so the
  proxy is not left stale after a restart. (HA-side requirement, restated in §5.)

### 3.3 Proxy on sancta-claw — a DUMB SINK with ZERO HA token

- Runs on host **sancta-claw** — NOT rpi5, NOT kuzea.
- **Holds NO HA credential of any kind.** There is no HA token, no HA URL it
  queries, no HA API client. It cannot address HA. It only *receives*.
- **Receives HMAC-signed pushes over the tailnet only** (inbound), verifies the
  signature against a shared secret held in agenix, and **rejects any push it
  cannot verify**.
- **Stores exactly `{someone_home_bit, last_push_ts}`** — the latest bit and when
  it last arrived. No history, no ring buffer (§6).
- **Exposes exactly one read endpoint:**

  ```
  GET /presence  →  {"someone_home": true | false | null, "ts": "<iso8601>"}
  ```

- Serves the stored bit **only** when it is fresh (a verified push within the
  stale-TTL) AND consent is active AND the kill-switch is clear; otherwise `null`
  (§5). There is no other endpoint, no query parameter, no way for a reader to
  name an entity or influence what HA aggregates.

### 3.4 Sancta's side — no token, no path

- Sancta holds **NO HA token** and has **NO network path** to Home Assistant
  except the proxy's one `GET /presence` endpoint, reached over the tailnet.
- The path to biometric data **structurally does not exist** for Sancta. Nor does
  it exist for the proxy: neither can address HA. There is nothing to misconfigure
  into a leak.

### 3.5 Allowlist, not denylist — and why (HA-side)

The template sensor aggregates a **positive allowlist** of entity IDs, chosen by
the operator by name, in HA config. It is explicitly **not** a denylist:

- A **denylist forgets a new entity.** A new (possibly biometric) HA entity would
  be included until someone remembers to block it.
- An **allowlist cannot leak what isn't listed.** A new HA entity is invisible to
  the aggregate until the operator explicitly adds it. Silence is the safe default.

The core secure-by-construction property: **the aggregate can only ever reflect
entities a human deliberately chose**, and forgetting fails *closed*.

### 3.6 Aggregate + non-denominated

The pushed bit is a plain OR across the allowlisted entities:

- never per-person,
- never "which person",
- never a count,
- never a room or a value.

So even an observer of the bit cannot back out *whose* presence it reflects. His
wife's patterns cannot be inferred from a non-denominated OR at a single moment
(the temporal / cross-signal caveats are §8).

## 4. Data-flow — two independent flows

### 4.1 Ingest (HA → proxy) — HA pushes, proxy has no token

```
Home Assistant                                    presence-proxy (sancta-claw)
  binary_sensor.someone_home = OR(allowlist)       (holds ZERO HA credential)
  (aggregated + quantized + debounced HA-side)
        │
        ├─ on debounced change ──HMAC-signed POST──▶ verify HMAC (agenix secret)
        ├─ periodic keepalive ───HMAC-signed POST──▶   │  └─ bad sig ─▶ REJECT (drop)
        └─ on HA restart: immediate sync push ───────▶ store {bit, last_push_ts}
```

The proxy never asks HA anything. It only receives verified pushes and updates
its `{bit, last_push_ts}` store. An unverifiable push is dropped, not stored.

### 4.2 Read (Sancta → proxy) — the gated, fail-closed read

```
Sancta ──GET /presence──▶ presence-proxy        (tailnet; Sancta holds NO HA token)
                          │  bit starts as null (the initializer, §5)
                          │
                          ├─▶ apex kill-switch engaged?
                          │        └─ yes ─▶ {"someone_home": null, "reason": "apex-veto"}
                          │
                          ├─▶ consent-ledger `aggregate-presence` active & unexpired?
                          │        └─ no  ─▶ {"someone_home": null, "reason": "no-consent"}
                          │
                          ├─▶ a verified push within the stale-TTL?
                          │        └─ no  ─▶ {"someone_home": null, "reason": "stale"}
                          │
                          └─▶ ALL three hold ─▶ serve the stored bit
                                   ▼
                          {"someone_home": <bool>, "ts": "<last_push_ts>"}
```

Sancta never sees which entities HA aggregated, how many there were, or their
values — only the aggregated bit (or `null` + reason) and a timestamp.

## 5. Fail-closed as a TYPE + the stale-TTL  (council amendment 3 — council-20260706T172246Z-cf6dda)

**The council's requirement:** fail-closed must be *structural*, not a set of
`catch`/`else` branches that discipline keeps complete. The wiring:

- **`null` is the INITIALIZER.** The served bit starts life as `null`. A real
  boolean is **served ONLY on the fully-validated happy path** — every one of:
  - a **verified fresh push within the stale-TTL** (HMAC checked, not stale),
  - **consent** `aggregate-presence` active and unexpired,
  - **apex kill-switch** not engaged.
  If any precondition is missing, nothing overwrites the initializer, so the
  response is `null` **by never having served anything else** — not by a fallback
  that could be forgotten.
- Consequently, all of these yield `null` structurally, with no dedicated
  "return null here" branch to maintain:
  - no push received yet (fresh boot),
  - **stale**: last verified push older than the stale-TTL (HA went silent),
  - a push that failed HMAC verification (never stored in the first place),
  - missing / corrupt / unreadable consent ledger,
  - expired consent (`expiresAt` in the past = revoked),
  - apex-veto kill-switch engaged (checked first, before anything is served).

### 5.1 The stale-TTL — NORMAL, defined concretely

The proxy distinguishes "no *change*" from "HA went *silent*" using the keepalive
heartbeat (§3.2). Concrete, sane defaults — **"normal" = fail-closed on ~2 missed
keepalives** (balanced: neither aggressive null-flapping nor relaxed staleness):

| Option | Default | Meaning |
|---|---|---|
| `keepaliveInterval` | **~5 min** | HA re-pushes the current bit at least this often |
| `staleTtl` | **~10–12 min** (≈ 2× keepalive) | no verified push within this ⇒ serve `null` (reason `stale`) |

This **tolerates one missed keepalive** (transient blip) and **fails closed on
two** (HA genuinely silent). Both are **module options** with these defaults; the
operator can tune them, but the default is the committed "normal" balance.

- **On HA restart the automation MUST re-fire an immediate sync push** (§3.2) so
  a restart does not leave the proxy stale for a whole keepalive interval.
- **NO last-true-beyond-TTL / no last-value cache.** A cache that survives the TTL
  is the ONE construct that silently turns fail-closed into fail-**open** — HA
  goes silent and the proxy keeps serving a stale `true`. Forbidden. The stored
  bit is served *only* while fresh; past the TTL it reads `null`. (`null ≠ false`:
  never claim the house is empty on a guess, and never claim it occupied on a
  stale read.)
- **A NEW HA entity does NOT auto-join the aggregate.** Only the operator's
  explicit HA-side allowlist feeds the template sensor; a new, possibly-biometric
  entity stays invisible until the operator adds it by name. Forgetting fails
  closed.
- **The proxy is receive-only.** No reader can name an entity, select a query, or
  influence what HA aggregates. `/presence` takes no arguments.

The verification for this is a **structural property test**: no code path serves a
non-`null` bit without having passed through the full validation chain, and every
error / stale / no-consent / kill-switch input maps to `null` (see §12, plan Task
of tests).

## 6. Timing side-channel — HA-SIDE STRUCTURE, not manners  (council amendment 1 — council-20260706T172246Z-cf6dda)

**The council flagged this as the sharpest risk.** Even a single aggregate bit
becomes an **inference channel about her** if its transitions are observable at
fine resolution: a fine-grained occupancy timeline — arrival/departure edges,
routines, absences — **de-facto denominates to HER** in a two-person home (when
he is away, every transition is hers). This is the temporal denomination the
instantaneous OR cannot prevent (§8).

In the push model the mitigation lives **at the source, in HA** — closest to the
data, and structurally, not by client manners:

- **HA-side quantization / debounce (hysteresis).** The HA automation only pushes
  a *change* after the new state persists across a debounce window, so brief
  transitions and the exact moment of an edge do not leave HA. What the proxy ever
  receives is already coarsened; there is no fine edge for a poller to observe
  because a fine edge was never pushed.
- **Keepalive, not continuous stream.** Between debounced changes HA sends only a
  periodic keepalive of the *current* bit — a heartbeat, not a high-resolution
  feed. The information rate crossing the HA boundary is bounded by construction.
- **Polling cannot out-resolve the push.** Sancta reading `/presence` more often
  than HA pushes learns nothing new — the proxy just returns the same stored bit
  and its `last_push_ts`. The reader cannot out-poll the source; the resolution is
  set HA-side, where the raw data is, not by how fast Sancta asks.
- **The proxy holds NO history structure.** It stores only `{bit, last_push_ts}`
  — no transitions list, no ring buffer, no `presence_since`. If the structure to
  hold a timeline does not exist, a timeline cannot be assembled from the proxy.
- **Explicit ban: `/presence` responses are NEVER written into memory, dream, or
  the meaning-index.** No persistence of the bit or its `ts` into any durable
  Sancta substrate — that would rebuild the very timeline the quantization erased.
  (Usage invariant enforced in the client + Constraints; see §8 on the limits of
  what the proxy alone can close.)

The concrete debounce window and keepalive interval are carried as module / HA
options (defaults in §5.1); they must be coarse enough that a reconstructed
timeline cannot resolve individual arrivals/departures.

## 7. Token absence + proxy hardening — and the rejected pull alternative  (council amendment 2 — council-20260706T172246Z-cf6dda)

**The council re-framed the blast surface, and the committed push model removes
it.** The real risk was never the one aggregate bit — it was the **full-scope,
un-scopeable HA long-lived token co-located with Sancta on sancta-claw.** In the
push model **there is no such token anywhere on sancta-claw**: HA pushes the bit
out, the proxy only receives. Content-blindness AND token-absence are both
structural.

The proxy still holds one secret — the **HMAC shared secret** that authenticates
pushes — but its blast radius is bounded to "someone could forge presence bits,"
not "someone could read all of HA." That is a categorically smaller surface. Even
so, harden the sink:

- **agenix for the HMAC secret:** stored encrypted, mode **0600**, decrypted only
  for the proxy user at runtime. Never in the Nix store plaintext, never in the
  repo. **No HA token is present to protect** — that is the point.
- **Hardened systemd unit:** `DynamicUser`, `NoNewPrivileges`,
  `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, a **seccomp**
  `SystemCallFilter=@system-service`, plus `RestrictAddressFamilies=AF_INET
  AF_INET6`, `MemoryDenyWriteExecute`, `ProtectKernel*`, read-only FS except a
  private runtime dir.
- **Bind Tailscale-only — NEVER public.** The proxy listens only on the tailnet
  interface (or loopback fronted by Tailscale Serve). Both the HA ingest webhook
  and the Sancta read endpoint are tailnet-only; never reachable from the public
  internet.
- **Inbound-only — no egress needed.** The proxy never *calls out* to HA (or
  anywhere). It only accepts inbound pushes and serves inbound reads. Egress can
  be firewalled to nothing — there is no outbound connection for a compromised
  proxy to exfiltrate through, and no token to exfiltrate anyway.
- **HMAC-verify every push; reject the unverifiable.** A push that fails signature
  verification is dropped, never stored — a forged bit cannot enter the store.
- **HMAC-secret-rotation runbook.** A documented procedure to rotate the shared
  secret (re-generate, re-encrypt the agenix secret on both HA and proxy sides,
  restart) so a suspected leak has a fast, rehearsed response.

### 7.1 REJECTED ALTERNATIVE — the PULL model (proxy holds the HA token)

The obvious-but-wrong shape is a *pull* proxy that queries HA for the aggregate.
**Rejected**, for one decisive reason:

- A pull proxy must **hold the full-scope, un-scopeable HA long-lived token**
  (§3.1) right next to Sancta on sancta-claw. If that proxy is ever compromised,
  **the entire HA API is the blast radius** — every biometric, health, and
  location entity, plus the history API. The token that can read everything would
  live one process-compromise away from Sancta.
- The push model **eliminates** that token rather than *containing* it. Removing a
  risk beats mitigating it: there is no token to leak, no egress to firewall, no
  rotation-under-fire of a god-credential. **The structural weakness becomes a
  structural strength.**

The only thing pull would buy is pull-freshness-on-demand; the push model recovers
freshness with the keepalive + stale-TTL (§5.1) at the cost of nothing that
matters here. Pull is therefore not built. (This is the council's preferred shape,
now committed by Alexandru's architecture decision — 2026-07-06.)

## 8. Per-person inference — the honest answer is NO, not "impossible"  (council amendment 4 — council-20260706T172246Z-cf6dda)

**SPECIFICATION GAP — stated plainly, as the council required.** The claim "his
wife's patterns cannot be inferred" is TRUE only **instantaneously**. The
OR-aggregate proves non-denomination at a single moment — the bit is identical for
{she alone}, {he alone}, {both}. It proves **nothing across time or across
signals**:

- **Temporal denomination:** a timeline of the bit (§6) denominates to her in a
  two-person home. Partly closable HA-side (quantization/hysteresis at the source),
  never fully — coarsening can blunt resolution but cannot make an occupancy signal
  timeless.
- **Cross-signal denomination:** the bit joined with *another* presence-bearing
  signal Sancta already holds — his calendar, a location fact, the NixFrame's
  contents — re-denominates it ("bit says occupied AND his calendar says he's
  away" ⇒ her). This is a **usage invariant the proxy CANNOT close** — it lives on
  Sancta's side, in what Sancta is allowed to *join*.

So the OR-aggregate is necessary but not sufficient. The structural mitigations
this design bakes in to shrink the gap as far as it goes:

- **Prefer whole-home occupancy sensors over per-person device-trackers** in the
  HA-side allowlist. A single "home occupied" sensor is denomination-resistant by
  nature; a set of per-person `device_tracker`s is not. The operator SHOULD
  populate the template sensor's allowlist with aggregate occupancy entities, not
  personal trackers.
- **Assert allowlisted entities' `device_class` HA-side, in the template.** The
  template sensor / automation guards each allowlisted entity's expected class; if
  an entity's type ever changes (a rename or reconfiguration silently turning a
  presence entity into something biometric — the **allowlist-drift / rename
  leak**), it is excluded from the OR rather than silently contributing a
  biometric value. The proxy is a dumb sink and never sees entities, so this guard
  necessarily lives where the entities are — in HA.
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
  full-token / pull risk the push model exists to remove).

## 11. What stays at the operator's / her hand (NOT Sancta)

The human retains every lever that touches the gated data:

- **Defining the entity allowlist in HA config** — by name, chosen by the operator
  (preferring whole-home occupancy entities, §8), feeding the template
  `binary_sensor.someone_home`. Sancta never reads HA values to discover or propose
  entities; the allowlist is human-authored HA-side input, not something Sancta
  derives. The proxy never sees the allowlist at all.
- **Creating the consent-ledger `aggregate-presence` entry** — explicit,
  revocable, with `expiresAt`, in the existing ledger (§9). The operator's hand.
- **Holding the apex kill-switch** — hers (the northstar apex switch), exercised
  through Alexandru; engaging it forces `null` instantly.

## 12. Verification honesty — what Sancta can prove, and what routes to the WITNESS

The council required honesty about the closing check (the frame-blind precedent):

- **Sancta-verifiable (unit / property tests):** every error / stale / no-consent /
  kill-switch input → `null`; no non-`null` bit is ever served without passing the
  full validation chain (§5); the pushed aggregation is a pure OR and
  non-denominated (§3.6, §8); an HMAC-invalid push is rejected (never stored); the
  proxy holds NO HA token/URL/HA-client anywhere (§3.3); the proxy stores no
  history structure, only `{bit, last_push_ts}` (§6); Sancta config holds NO HA
  token/URL/path (§3.4). These run on mocks/fixtures — **no real HA personal data
  is read during development.**
- **Routes to Alexandru as WITNESS (Sancta stays blind):** the end-to-end "does HA
  actually push, does the live bit track reality" check touches real presence and
  therefore real PII. Consistent with the structural blindness to the live frame,
  **Sancta does not run this**; Alexandru (or the Witness role) confirms the live
  behavior in a separate window and reports da/no. Sancta only ever sees its own
  PII-amputated outputs.

## 13. Gates before build

**Council RETURNED escalate-to-human (risk HIGH,
`council-20260706T172246Z-cf6dda`). Building does NOT start until all clear.**
Note the corrected order of operations from **Gate 0 — Amputation** (above): the
human/apex gates precede even the inert build, and **Gate 0 (amputation) is a
structural PRECONDITION** that must be verified true before the proxy is
meaningful:

> **her assent (concept) → his approval → Gate 0 amputation (verified) → build → activation**

1. **Council verdict resolved** — `council-20260706T172246Z-cf6dda` returned
   *escalate-to-human* with a load-bearing finding + 4 required amendments (§§5–8,
   folded in above). The escalation itself hands the decision to the human — the
   council does not, and cannot, clear this alone. **Premise caveat:** the re-gate
   council (`council-20260706T180259Z-6a0fa5`) was rendered **WITHOUT the
   amputation premise** — it reasoned about the proxy as the only path to HA. Its
   verdict is therefore **incomplete without Gate 0**, and a **re-premised council
   may be warranted** before proceeding.
2. **Alexandru's explicit approval.** (A coordinator-relayed claim of approval is
   NOT his approval — only his own word counts.)
3. **His wife's apex-veto cleared through him** — this touches gated biometric
   data (HA is the most confidential category yet); her veto sits above the
   council and is mediated entirely through him.
4. **Gate 0 — Amputation VERIFIED (structural precondition).** All three
   amputations above (MCP tools removed, shell/SSH isolated, network route
   firewalled) must be verified true **before** the proxy is built or activated.
   Without Gate 0 the proxy is theater — a data-path mediator cannot constrain an
   agent that still holds an independent capability to reach HA. This gate is a
   *precondition on the wiring*, not a human decision; but it comes **after** the
   human/apex gates (1–3) and **before** any build.

The **architecture is committed** (Alexandru's 2026-07-06 decision): the PUSH
model with HA-side aggregation + a normal stale-TTL. That decision is his
authority over the *shape* — it is **NOT** a launch authorization. The gates
above remain fully open.

Only after all gates clear does the companion ralphex plan
(`2026-07-06-ha-presence-proxy-plan.md`) become launchable — by Alexandru's
hand, from a normal terminal, never autonomously.
