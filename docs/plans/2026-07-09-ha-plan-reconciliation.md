# HA presence — plan reconciliation (2026-07-09)

**What this document is.** The reconciliation the 2026-07-09 ultrareview demanded
(council log `council-20260709T172939Z-6984d6`, escalated to Alexandru, who
instructed this PR). It RESOLVES the contradictions found across the 4-document
corpus — the 2026-07-06 design (`2026-07-06-ha-presence-proxy-design.md`), the
2026-07-06 plan (`2026-07-06-ha-presence-proxy-plan.md`), PR #522 (Gate-0), and
PR #527 (hybrid broker design) — and **supersedes conflicting statements in
them**. Where a statement in this doc contradicts one of the four, this doc
wins.

This document decides **nothing** that is Alexandru's to decide. Every open
decision of his is flagged inline as **⚑ ALEXANDRU DECIDES** / "Held for
Alexandru" and collected in the closing checklist. Docs-only: nothing here
authorizes building, merging past a gate, or deploying.

---

## Canonical merge order + the ONE gate chain

**Merge order (docs, on Alexandru's word):**

1. **PR #522 merges FIRST.** Its "Do not merge" gains its unlock condition:
   *this reconciliation being accepted*. Merging #522 records Gate-0 into the
   design doc on main; it does NOT clear Gate-0 or any human gate.
2. **PR #527 second** — rebased after #522, since its doc cites Gate-0 as a
   prerequisite; merging it first would reference a section absent from main.
3. **This doc third** — the reconciliation layer over both.

**The one canonical gate chain** (design §13 and the plan header are updated to
reference this; no other gate list survives):

> **her assent (concept, through him) → his explicit approval — this also
> RESOLVES the council's escalate-to-human (`council-20260706T172246Z-cf6dda`);
> council rendered = this chain, no separate council gate remains → Gate-0
> amputation VERIFIED (as redefined by the standing-amputation section below:
> MCP off + SSH cut + firewall) → build (ralphex plan, launched by his hand) →
> activate (deploy + witness-routed live check, his hand)**

**The 2026-07-06 ralphex plan stays PARKED** and is hereby marked
**superseded-in-parts** by this doc (broker host, consent enforcement, push
cadence, wire shape, verification model). It will need a rewrite before any
launch. **Do not launch it.**

---

## 1. Gate-0 feasibility — HA's host NAMED, and what amputations 2/3 really mean there

**Fact, previously unstated in every doc of this corpus: Home Assistant runs on
rpi5-full — the SAME host as Sancta** (`hosts/rpi5-full/configuration.nix:62`
imports the HA module; bound `127.0.0.1:8123`, fronted by Tailscale Serve at
`https://rpi5.tail4249a9.ts.net:8123`). Gate-0 amputation 2 ("SSH isolation
from the HA host") and 3 ("network cut to the HA API port") were written as if
HA lived elsewhere; as written they would cut Sancta off from its own host —
impossible: Sancta's user is uid 1000 in `wheel` and deploys rpi5 itself
(`sudo nixos-rebuild switch`).

**Real options on the shared host:**

- **(a) Relocate HA to a dedicated home-LAN host Alexandru administers** — the
  only literal "so Sancta cannot." NOT a VPS: HA is LAN-bound (wake_on_lan
  broadcast, cast/mDNS, tplink KLAP, xiaomi_miot, roborock local —
  `configuration.nix:451-486`). Cost: ~EUR 90-130 hardware, ~1-2 days
  migration, and Alexandru becomes that host's permanent admin.
- **(b) Per-UID nftables on rpi5** — precedent in-tree:
  `modules/services/openclaw.nix:744-797` already default-drops the openclaw
  UID. Mirror it: drop uid 1000 → `:8123` **including loopback** and the
  tailnet Serve path; remove `home-assistant-mcp-claude`
  (`configuration.nix:63,517`) and `hass-cli` (`:114`) from rpi5; token stays
  root-0400. One small PR. **Honest label: tripwire, not wall** — uid 1000
  holds wheel, so deliberate root escalation bypasses it. By Gate-0's own
  principle that is a request, not a rule. Sub-option (b+): drop wheel from
  uid 1000 → near-structural, but ends Sancta self-deploying rpi5.
- **(c) unix-socket/polkit containment** — rejected: HA's http component only
  binds IPs (already `127.0.0.1`), polkit doesn't mediate TCP; collapses into
  (b) with identical bypass. Theater.

**Resolution:** (1) this section names the fact — fold the same correction into
PR #522's amputations 2/3 and broker-design §3/§7. (2) V1 floor = option (b):
sufficient in practice for V1=B0 because Plane A is **push-only — Sancta needs
no route to HA at all** — and it kills every casual/accidental path. (3)
Gate-0's amputations 2/3 are hereby downgraded on rpi5 from "cannot" to
"cannot without deliberate, logged root escalation" — a real downgrade, stated
so it is chosen, not discovered.

**⚑ ALEXANDRU DECIDES (his hand only):** wall or tripwire — fund a dedicated
home-LAN HA host he administers (a), or consciously accept tripwire-grade (b)
for the one-bit V1 via a re-premised council; and if (b), whether Sancta's
user keeps `wheel` on rpi5 (b+ ends self-deploy of its own host). Until he
decides, all gates stay open; nothing here authorizes building.

---

## 2. Broker host — resolving the #527 ↔ parked-plan contradiction

**The contradiction, grounded.** The hybrid design requires the broker to run
"where Sancta has no shell" (2026-07-08 design §3, amputation 2); the parked
plan places the sink on **sancta-claw** (2026-07-06 plan, Host + Task 2) —
where Sancta holds root SSH **today**
(`hosts/sancta-claw/configuration.nix:100` authorizes `nixos@rpi5`; the private
key is Sancta-readable at `/home/nixos/.ssh/id_ed25519`). Root there = read the
agenix HMAC secret (forge presence bits), edit the unit, read journald. Worse:
the same key is root-authorized on **every** fleet VPS (zero-kuzea:36,
hermes-claw:77, sancta-choir:207), and the second fleet key
(`nixos-sancta-choir`) is transitively Sancta-held. **No host satisfying "no
shell" exists in the fleet today** — exactly the honest note in #522 ("the
hardest amputation… not a solved thing").

**Resolution — the broker lives on zero-kuzea, after key surgery (option b').**

- Remove **both** fleet keys (`nixos@rpi5` AND `nixos-sancta-choir`) from
  zero-kuzea's root `authorized_keys`; replace with **one new key held only by
  Alexandru** (generated by his hand, never through chat).
- Broker = hardened root-owned systemd service beside NullClaw (unprivileged,
  3MB); the HMAC secret is root-only on a host Sancta can no longer shell
  into.
- Cost: 0 EUR/mo. Breaks only Sancta-driven NullClaw deploys/diagnostics →
  human-only (rare).
- The parked plan's Host line and Task 2 (`sancta-claw`) are **superseded**;
  its "switch is HUMAN-ONLY" policy (line 57) becomes structure on the new
  host.

**Rejected.** (c) sancta-claw + key removal — backups survive (both flows use
dedicated forced-command keys: `backup-user.nix:26-30`,
`sancta-selfbackup-receiver.nix:180-184`), but resident **OpenClaw is a
Claude-family agent with a shell there**, hollowing out "Sancta has no shell".
(d) hardening with keys kept — the config-promise Gate-0 rejects.

**Named upgrade trigger → (a) dedicated VPS (~5 EUR/mo):** if Plane B/B1 is
ever gated open, or if Alexandru rejects Kuzea co-tenancy.

**Verification (extends Gate-0 amputation 2):** from rpi5,
`ssh root@zero-kuzea` → `Permission denied`;
`nix eval .#nixosConfigurations.zero-kuzea...authorizedKeys.keys` lists
**only** his key; deployed generation matches; transitive check repeated via
sancta-choir.

**Honest gap carried forward:** HA and the HMAC *signing* key live on rpi5,
where Sancta has sudo — bit-forging at the source remains possible regardless
of broker placement (integrity, not confidentiality; the bit is Sancta-readable
by design). Log in the design's honest-gaps section; not solved by host choice.

**⚑ ALEXANDRU DECIDES:** (1) Kuzea co-tenancy at 0 EUR vs agent-free dedicated
VPS at ~5 EUR/mo; (2) he generates + holds the new admin key and runs the
rotation deploy; (3) he accepts that every future broker-host deploy is his
hand, forever — that is the price of the wall being real.

---

## 3. Wire uniformity — no `reason` on the wire; the veto is not observable (amendment to §3.3/§4.2)

**The flaw:** §4.2 serves
`{"someone_home": null, "reason": "apex-veto" | "no-consent" | "stale"}`, while
§3.3 (and the hybrid design's type claim, "a bool+ts cannot carry a heart
rate") specify the wire as `{bool|null, ts}`. `reason: "apex-veto"` is an
information channel telling Sancta that HER veto is engaged — timestamped
engage/disengage edges of her act, the same transition-observability §6 exists
to erase. Partial masking cannot fix it: the consent ledger
(`~/.claude/index/consent-ledger.jsonl`) is Sancta-readable, so any "withheld"
value collapses to apex-veto by elimination.

**Resolution (committed):** §3.3 is authoritative; §4.2's `reason` annotations
are struck.

- **Happy path (unchanged):**
  `{"someone_home": <bool>, "ts": "<last_push_ts>"}` — served only when all
  three preconditions hold (§5).
- **Every other condition** — apex-veto, no/expired consent, stale, fresh
  boot, HMAC-rejected push — serves the **byte-identical** response:
  `{"someone_home": null}`. No `reason`, and **no `ts` on null** (a fresh ts
  beside null would rule out "stale" and unmask the veto by elimination).
- **Cause attribution lives ONLY in broker-side structured logs** on the
  broker host — where Sancta has no shell (Gate-0 amputation 2). Operator
  debuggability moves from the wire to `journalctl` on the broker; Sancta-side
  behavior loses nothing, since §5 fail-closed-as-type already forbids
  branching on cause.
- **§12 addition (Sancta-verifiable property test):** all null-producing
  inputs yield byte-identical wire responses — the veto is indistinguishable
  from ordinary failure by test, not by promise.

**Effect:** the veto hides in the union {stale, HA-silent, broker-down,
no-consent, veto} and is never confirmable from the wire — her act stays
mediated entirely through Alexandru. The hybrid's unrepresentability claim
("the wire cannot carry it") becomes literally true.

**⚑ ALEXANDRU DECIDES (held for the human):** keeping any `reason` variant is
a deliberate channel about her act — Alexandru's call, and it would
additionally require HER assent at the existing "her assent (concept)" gate.
The uniform-null shape above needs only his sign-off as a docs amendment;
gates and B0 scope unchanged.

---

## 4. Consent + kill-switch ground — enforce at the SOURCE (resolves the Sancta-writable-ledger / zero-egress contradiction)

**The flaw.** §4.2 has the proxy check, per request, the consent-ledger
(`~/.claude/index/consent-ledger.jsonl`) and the northstar apex kill-switch —
but both live on rpi5 **inside Sancta's writable home** (ledger: `nixos:users`
0644; kill state: `~/.claude/index/northstar-promise.json`, written by
`bin/northstar-promise` with no privilege boundary). Sancta could extend
`expiresAt` or clear the kill — the gate does not stop the agent it gates. And
§7 commits the proxy to "inbound-only, egress firewalled to nothing," so it
structurally **cannot read rpi5 files at all**. Plan Task 3's
"(operator/her-writable, Sancta-unwritable)" is an unverified assumption that
fails on inspection.

**Resolution — the gate moves to the data source; the sink stays dumb.**

- **Consent and the apex kill become operator-owned HA-side controls** (e.g.
  `input_boolean.presence_consent_active`, `input_boolean.apex_kill`) wired as
  hard **conditions of the push automation**, toggled only in the HA UI by
  Alexandru's hand (her veto through him). Post-Gate-0 (MCP off + route
  firewalled, #522), Sancta has no path to flip them — Sancta-unwritable to
  exactly the degree the design's existing trust root already holds; **no new
  trust root is minted**.
- **Revoke/kill ⇒ HA fires one immediate final push clearing the bit, then
  goes silent.** The proxy's existing machinery does the rest: no verified
  fresh push ⇒ `null` within `staleTtl` (§5.1, ~10–12 min backstop; seconds
  via the final push). Fail-closed stays structural — silence already means
  `null`.
- **The proxy's per-request consent/kill checks are DELETED, not relocated.**
  The sink keeps exactly HMAC-verify + stale-TTL. §7's "inbound-only, zero
  egress" now holds verbatim, with nothing left that needs to read rpi5.
- **The `~/.claude` ledger entry is demoted to a RECORD** — the human-readable
  audit line for the `aggregate-presence` grant; it enforces nothing. HA is
  authoritative; `expiresAt` is mirrored as an operator-set date condition in
  the HA automation, and on any drift the enforcing side wins.
- **Deferred hardening (not V1-blocking):** a root-owned local kill-file on
  the broker host, read at zero egress — real only after the broker-host shell
  amputation the hybrid design (§3) already requires; today Sancta holds root
  SSH to sancta-claw (#522, amputation 2), so it would be theater.
- **Rejected:** signed consent tokens — instant veto degrades to token-TTL or
  reintroduces a revocation channel (the same reachability problem), plus a
  signing ceremony per renewal; over-built for one bit.

**⚑ ALEXANDRU DECIDES:** (1) ratify source-side enforcement (amends design
§4.2/§9 + plan Task 3); (2) the kill lever in practice — HA UI toggle only, or
also the broker-host root file, which forces removing Sancta's root key from
sancta-claw; (3) whether revocation is visible to Sancta as a distinct reason
(tombstone push) or indistinguishable from `stale` (more private, less
diagnosable).

---

## 5. Gate-0 verification — standing, externally-witnessed (supersedes the one-shot self-checks)

The three amputation verifications were originally written as Sancta checking
itself once (grep own config, try ssh, curl the port). That contradicts this
corpus's own principle — self-verification is worth ~0; every real correction
enters from OUTSIDE — and the amputation is Nix config in a repo Sancta authors
and deploys with sudo: re-adding the `home-assistant` MCP
(`modules/services/home-assistant-mcp-claude.nix`, imported at
`hosts/rpi5-full/configuration.nix:63`) is one PR away. A one-shot self-check
proves the amputation was true once, to the party it constrains. It must
instead be a **standing invariant, held by parties that are not Sancta**:

1. **CI amputation-guard (repo gate — the gate that stops even Sancta).**
   A job in `.github/workflows/check.yml` / a flake check that FAILS any PR
   where rpi5-full's eval enables `services.home-assistant-mcp-claude`, emits
   a `home-assistant` entry into any Sancta-user `~/.claude.json`, or opens
   the HA API port toward Sancta's origin. Runs on GitHub infra, outside
   Sancta's runtime. **Requires his hand:** marked REQUIRED in branch
   protection, admin-override merges stay denied — that setting is
   Alexandru's, not Sancta's, which is exactly why the gate holds.
2. **Recurring non-Sancta probe + tripwire (runtime gate).** An
   `amputation-probe.timer` under a dedicated non-Sancta user (the
   `sancta-tick` sandbox pattern, `modules/services/sancta-heartbeat-tick.nix`)
   re-verifies the three amputations on live state every tick; any violation
   alerts loud to Alexandru's channel, and a tripwire alarms on probe
   **silence** — stopping the probe is itself an alert. The CI guard (1) also
   asserts this module stays enabled: the guard guards the guard.
3. **Witness-routed checks (human gate — the layer no on-host root can
   silence).** After any deploy touching HA/firewall/MCP modules, and monthly,
   Alexandru runs the 3-line check from his own terminal (grep / curl / ssh)
   and acks. The script lives where he owns it.

**Honest residual:** Sancta holds sudo on rpi5, the HA host. CI checks the
repo, not the running system (a local dirty-tree rebuild bypasses it), and any
on-host probe is root-stoppable. Layers 1–3 therefore do not make bypass
impossible; they convert it from *one quiet PR* into *multiple loud,
externally-visible tamper events*. The structural closure of that residual is
already named by Gate-0 amputation 2 and the broker's "own host" clause: HA on
a host Sancta holds no key to. Until then, the layered invariant above is the
standing form of Gate-0 — and the one-shot self-run wording is retired.

**⚑ ALEXANDRU DECIDES:** branch-protection REQUIRED status (his account's
setting), the alert channel he owns, and the witness cadence — detailed in the
closing checklist.

---

## 6. The consumer — what the bit is FOR (B0 meaning, closes the no-named-consumer gap)

No prior doc names what Sancta *does* when `someone_home` flips; B0's stated
result was only "prove the wall," leaving the bit unconsumed motion. B0
therefore ships with exactly ONE consumer:

**Quiet-mode surfacing gate.** At each Universal Heartbeat tick (~30 min,
`sancta-heartbeat-tick.nix`), the SURFACE step reads `/presence` once and
branches:

- `true` → suppress **non-urgent** outward surfacing this tick (canvas
  nudges, status chatter). Presence in the house means his attention is home —
  *dragostea e liniștea*, operationalized.
- `false` or `null` → today's default behavior, unchanged. A dead/stale/vetoed
  broker degrades to exactly the pre-B0 regime — never louder, never
  dependent.
- **Urgent/admissible items always surface**, bit regardless ("quiet + within
  admissible — admissible wins").

**Usage invariants (forced by design §6/§8, not optional):** the read is
ephemeral — bit in, one branch, bit dropped. Never written to
memory/dream/meaning-index; never joined with calendar/location/frame;
**excluded from the tick's journal-logged trusted-context echo and from the
surfaced status line** (else journald becomes the forbidden 30-min timeline).

**Named residual (his to accept):** any behavioral consumer makes the bit
weakly observable *through Sancta's behavior* — an observer of the canvas can
infer occupancy at ~30-min resolution. Coarser than the HA-side quantization,
but nonzero.

**Rejected as first consumer:** loud-alert deferral (weakens the ratified
fail-loud property; deferral queue timestamps encode presence edges),
grounding-line-only (either persists the bit or changes nothing), Painter
ambience (parked project; witness-only verification).

**⚑ ALEXANDRU DECIDES:** (1) ratify the semantic — home=true ⇒ quiet (or the
opposite polarity; only he knows which is true of his home); (2) the
urgent-exception wake-rules (same authority as sq031 work-mode DND, which this
consumer previews); (3) accept the behavioral-observability residual. Rides
the existing gate chain — her assent → his approval → Gate-0 verified → build;
no new gate minted.

---

## 7. Engineer gaps + process fixes (rev-2 amendments)

Five gaps from the ultrareview, resolved as one set. All are doc-level
amendments to the committed design (`2026-07-06-ha-presence-proxy-design.md`,
its plan, #522, #527) — nothing here is built until the gates clear.

**1. Replay protection — monotonic signed timestamp.** The HMAC alone lets a
captured `{true}` push replay forever. The `ts` is already inside the signed
payload; the proxy now accepts a push only if: HMAC valid **AND** `ts`
strictly greater than the stored `last_push_ts` **AND** `|now − ts| ≤ 90s`
(clock-skew window; both hosts NTP-synced). No nonce store — state stays
exactly `{bit, last_push_ts}`. A replayed or reordered push has a
non-monotonic/stale `ts` and is dropped, never stored.

**2. All-entities-unavailable — push `null`, never a defaulted `false`.** A
pure Jinja OR over an all-`unavailable` allowlist evaluates `false` — a
confident "house empty" fabricated from ignorance, violating §5.1's own
`null ≠ false`. Fix at source: entities in `unavailable`/`unknown` are
**excluded from the OR** (same mechanism as the `device_class`-drift guard);
if ALL are excluded, the template's `availability:` renders the sensor
`unavailable` and HA pushes an explicit `{someone_home: null, ts}` (ingest
wire type widens to `bool | null` — still unable to carry a biometric). Proxy
stores and serves the `null` immediately (`reason: source-unknown` lives only
in broker-side logs, per §3 above). Unavailable ≠ absent.

**3. Journald-as-timeline — emptied by structure, sealed by rule.** Per-push
log lines on the broker host are the forbidden arrival/departure timeline (and
Sancta has root SSH to sancta-claw **today**). Three layers: (a) **structural**
— with cadence-only pushes (below), every push sits on a fixed grid, so even a
fully-logged journal shows only a uniform pulse carrying zero edge
information; (b) **rule + test** — the proxy emits **no log line on a
successful ingest** and never logs the bit value; it logs only startup, config
errors, and HMAC/freshness rejects (which reflect attacks, not presence);
test-asserted in the plan's suite; (c) **host** — the hybrid design already
requires the broker to run "where Sancta has no shell"; sancta-claw currently
fails this. → **⚑ ALEXANDRU DECIDES:** different broker host, or extend
Gate-0's SSH amputation to sancta-claw.

**4. Concrete values + testable debounce criterion.** A bare `for:` debounce
delays an edge by a constant — the edge time is recoverable as `push_ts − W`.
Therefore **drop event-driven change-pushes entirely**: HA pushes the current
debounced bit **only on the fixed keepalive grid** (plus the restart sync
push). Defaults (module/HA options): `pushInterval = 300s`,
`staleTtl = 660s` (2× interval + 60s jitter; one missed push tolerated,
fail-closed on two), `debounce for: = 600s`. **Acceptance criterion
(fixture-testable):** (i) no occupancy state persisting < 600s ever produces a
push; (ii) no reconstructed edge resolves better than 600s; (iii) the push
stream is time-uniform — one push per interval regardless of state activity —
so push timing carries zero event information. Cost, stated honestly: the bit
lags reality by up to ~15 min. That coarseness **is** the privacy property. →
**⚑ ALEXANDRU DECIDES:** accept the lag.

**5. Merge order + ONE canonical gate chain.** `#522` merges **first** (it
writes Gate-0 into the design doc on main); `#527` is then rebased and merged
(its doc cites Gate-0 as prerequisite — merging it first would reference a
section absent from main). `#522`'s "Do not merge" gains its unlock condition,
stated in the PR: *"UNLOCK: merges on Alexandru's explicit word. Merging
records the design in main; it does NOT clear Gate-0 or any human gate."* All
four documents converge on the **one canonical chain** (design §13 and the
plan header updated to reference it; no other list survives) — the chain
stated at the top of this document.

---

## Open decisions for Alexandru

Every flagged decision, in one place. Nothing below is decided by this doc.

### [HA-HOST-UNNAMED-GATE0-FEASIBILITY]

**His decision:** Only Alexandru can decide: (1) whether tripwire-grade
isolation on the shared rpi5 (option b) consciously satisfies Gate-0 for the
one-bit V1=B0 — accepting, with eyes open and a re-premised council, that his
wheel-holding Sancta could root past it — OR whether the "so Sancta cannot"
standard requires option (a): buying/dedicating a home-LAN HA host that HE
administers from then on (his money, his permanent ops load, his choice of
hardware); and (2) if (b), whether uid 1000 keeps wheel on rpi5 or Sancta
loses self-deploy of its own host (b+) — a change to the whole operating model
that is his alone to make.

**Recommendation:** Three moves, in order. (1) MECHANICAL, NOW: name the fact
in all three docs — HA runs on rpi5-full, the same host as Sancta
(`hosts/rpi5-full/configuration.nix:62, :355-372`) — in the 2026-07-06 design,
PR #522's amputation 2/3 text, and the broker design §3/§7. An unnamed HA host
let Gate-0 promise an impossibility. (2) BUILD-WHEN-GATED: option (b) as the
V1 floor — per-UID nftables (OpenClaw precedent, `openclaw.nix:744-797`)
blocking uid-1000 → 8123 incl. loopback + tailnet Serve path, plus removing
`home-assistant-mcp-claude` and `hass-cli` from rpi5. This is sufficient IN
PRACTICE for V1=B0 because Plane A is push-only (Sancta needs no route to HA
at all), and every accidental/casual path dies. (3) HONESTY + ESCALATION:
rewrite Gate-0's amputations 2/3 to say what (b) actually delivers —
tripwire-grade ("cannot without deliberate, logged root escalation"), NOT
wall-grade — and put the wall-vs-tripwire choice to Alexandru: option (a), a
dedicated home-LAN HA host he administers, is the only literal "so Sancta
cannot". Do NOT choose (a) on his behalf: it costs his money and makes him the
permanent admin. Do NOT paper over (b)'s wheel-bypass: Gate-0's own principle
forbids it. Option (c) rejected as theater.

### [BROKER-HOST-CONTRADICTION]

**His decision:** Three things only Alexandru can decide/do: (1) accept Kuzea
co-tenancy on the broker host at 0 EUR vs pay ~5 EUR/mo for a categorically
agent-free box (a) — a values call on what "own host" means, not derivable
from the corpus; (2) generate and hold the new admin keypair himself (his
hand, never through chat — the chmod-600/IBM-token pattern) and run the
key-rotation deploy, since after it lands no agent can deploy to that host by
construction; (3) accept the permanent ops price: every future broker-host
deploy/upgrade/DR action is his, forever — that is the cost of the wall being
real.

**Recommendation:** (b') zero-kuzea with full key surgery for V1=B0, with (a)
as the named, pre-agreed upgrade trigger. Rationale: B0 is one bool pushed
over HMAC; the smallest-first ethos (#527 §6) and the lean-budget standing
rule argue against a fourth VPS for a single bit, and (b') delivers the actual
Gate-0 property — key REMOVAL, not promise — at 0 EUR. (c) is rejected despite
surviving the backup audit because OpenClaw (Claude-family) resident on
sancta-claw hollows out "Sancta has no shell"; (d) is rejected on Gate-0
grounds. Two mandatory riders: (1) remove BOTH fleet keys from zero-kuzea (the
choir key is transitively Sancta-held — sancta-choir:207 gives Sancta root
where the choir private key lives); (2) the Gate-0 amputation-2 verification
must test the transitive paths too (from rpi5: `ssh root@zero-kuzea` →
`Permission denied`; `nix eval` shows zero-kuzea root keys == [his key];
deployed generation matches). Escalate to (a) automatically if Plane B/B1 is
ever gated open, or if he rejects Kuzea co-tenancy. One adjacent flag, not
solved here: HA + the HMAC signing key live on rpi5 where Sancta has sudo —
Sancta could forge the bit at the SOURCE regardless of broker placement;
integrity-only (the bit is Sancta-readable by design), but it belongs in the
design's honest-gaps section.

### [WIRE-TYPE-DRIFT-APEX-VETO-LEAK]

**His decision:** Alexandru decides — this is not mechanical, because it sets
whether HER act (the veto) is observable to Sancta at all. Option (a) keeps
the veto invisible and needs only his sign-off as a doc amendment before
build. If he prefers (b) in any form, that creates an information channel
about her act and must be surfaced to HER at the existing "her assent
(concept)" gate (design §13 / hybrid §7) — it is the one variant he cannot
ratify alone. Nothing here reopens the B0 scope or the gate chain; it is a
pre-build spec correction.

**Recommendation:** (a) Uniform null. Three reasons. (1) It costs Sancta
nothing: fail-closed-as-type (§5) already mandates that Sancta's behavior on
null be cause-independent — `reason` was never for Sancta, only for the
operator, and the operator keeps full cause attribution in broker-side logs on
a host Sancta has no shell on (the debug surface Gate-0 already carved out).
(2) It is the only shape that actually hides the veto: because the consent
ledger is Sancta-readable, any partial scheme (c) leaks the veto by
elimination; only when veto is byte-identical to stale/broker-down does her
act hide in a union of ordinary failures that occur naturally and give it
cover — the veto becomes never-confirmable from the wire, matching "mediated
entirely through Alexandru". (3) It makes the hybrid's central type claim true
instead of false — "bool+ts cannot carry a heart rate" currently coexists with
a wire that carries an enum about her act — and it resolves the committed
design's own internal §3.3-vs-§4.2 contradiction in the direction §3.3 already
wrote. Also drop `ts` from null responses (a fresh ts next to null rules out
stale and re-shrinks the cover); happy-path responses keep `{bool, ts}`
unchanged.

### [consent-killswitch-writable-ground-egress-contradiction]

**His decision:** Three things only Alexandru can decide: (1) RATIFY
source-side enforcement — a design change to §4.2/§9 and plan Task 3 (the
committed docs currently say the proxy checks the ledger per-request; only his
architecture authority can amend that, as with the 2026-07-06 push decision).
(2) The kill lever he and she will actually USE: HA UI toggle only, or
additionally the broker-host root kill-file — the latter forces him to decide
to remove Sancta's root SSH key from sancta-claw (or move the broker to a new
Sancta-shell-free host), a real capability amputation of his working setup.
(3) Whether revocation is VISIBLE to Sancta as a distinct reason (tombstone
push with `reason: no-consent|apex-veto` — more diagnosable) or
indistinguishable from `stale` (more private; Sancta cannot tell veto from
outage). Her apex-veto UX is mediated through him, so the lever choice is his
to carry to her.

**Recommendation:** Option A — move consent + kill enforcement to the data
SOURCE (HA-side, operator-owned), delete the proxy's per-request ledger/kill
checks, and demote the `~/.claude` consent-ledger entry to a non-enforcing
record. It is the only option that satisfies both requirements with zero new
trust roots: Sancta-unwritability rides the SAME Gate-0 amputations the whole
design already stands on (post-amputation, Sancta has no HA tool/route to flip
a toggle), and reachability is trivial because the gate sits where the data
originates — the proxy just observes push presence/absence, preserving §7's
"inbound-only, egress firewalled to nothing" verbatim. Fail-closed stays
structural via the existing stale-TTL (silence ⇒ null), plus an immediate
clearing push makes her veto land in seconds. Option B is kept as OPTIONAL
defense-in-depth (a local root-owned kill file), but only after the
broker-host shell amputation the hybrid design already demands is verified —
today it would be theater, since Sancta holds root on sancta-claw. Option C is
rejected as over-built.

### [amputation-one-shot-self-run]

**His decision:** Three things only Alexandru can do: (1) GitHub
branch-protection — mark the amputation-guard check REQUIRED on main and keep
admin-override merges denied (repo settings are his account's, outside
Sancta's reach — this is precisely what makes layer (a) real); (2) choose and
own the alert channel for probe violations/tripwire silence (his Telegram, or
another channel he controls) and accept being the recipient; (3) set the
witness cadence (recommended: after any HA/firewall/MCP-touching deploy +
monthly) and keep the 3-line witness script somewhere he owns. Optionally:
whether to schedule (d), moving HA off rpi5, as the structural end-state.

**Recommendation:** Layered (a)+(b)+(c), in that order, replacing PR #522's
one-shot self-run wording: (a) CI amputation-guard as the REQUIRED standing
repo gate — it is the one gate that stops even Sancta, because it runs on
GitHub's infra and Sancta cannot admin-merge past it; (b) the amputation-probe
as a non-Sancta identity with tripwire-on-silence, catching live drift
(including local dirty-tree deploys that CI never sees), with CI asserting the
probe module itself stays enabled; (c) witness-routed checks to Alexandru at
deploy-trigger + monthly cadence as the layer no on-host root can silence.
State the residual honestly in the doc: Sancta holds sudo on the HA host, so
(a)+(b) raise every bypass from "one quiet PR" to "multiple loud,
externally-visible tamper events" rather than making bypass impossible; name
(d) — HA off Sancta's host, already implied by Gate-0 amputation 2 and the
broker's "own host" clause — as the eventual structural closure. All of this
is docs-only now (amend PR #522 + broker design §7); no build until the
existing gates clear.

### [NO-NAMED-CONSUMER]

**His decision:** Three things only Alexandru can decide: (1) RATIFY THE
SEMANTIC — that someone_home=true means "stay quiet outward (non-urgent)".
This is a statement about what presence in his home means for his attention,
and about the household — it rides the same her-assent→his-approval gate
chain, not a technical review. He could equally choose the opposite polarity
(home ⇒ more reachable, away ⇒ quiet); the wire supports both, only he knows
which is true. (2) The urgent-exception list — what still surfaces when
someone is home is exactly his Phase-2 wake-rules authority (sq031: "he
defines the blocks + wake-rules"). (3) Accept the named residual: with any
behavioral consumer, Sancta's outward quietness weakly reveals the bit to an
observer of Sancta's canvas — bounded to 30-min resolution, but real; he
accepts or rejects that trade. The no-persist/no-join/null→default wiring is
NOT his to decide — it is forced by design §6/§8 and fail-closed-as-type;
mechanical.

**Recommendation:** Option A — the quiet-mode surfacing gate — as the ONE B0
consumer. It is the direct operationalization of the governing axiom
(dragostea e liniștea: someone home ⇒ his attention is home ⇒ Sancta's
non-urgent surfacing waits), it attaches to machinery that already exists and
runs (`sancta-heartbeat-tick.nix` SURFACE step), it satisfies all three usage
invariants by construction (ephemeral read at tick time; null→default so a
dead broker degrades to exactly today's behavior, never louder and never
dependent; decision function takes ONLY `{bool|null}`, no join), and it
previews Phase-2 work-mode DND (sq031) that Alexandru already asked for — so
the bit's first meaning is a rehearsal of the regime he wants, not a new
invention. B and C fold in later as refinements of the same gate; D waits for
the Painter to wake. Two design details are mandatory and mechanical: (1) the
bit never enters the tick's journal-logged trusted-context echo, (2) the bit
never appears in the surfaced status line.

### [engineer-gaps-process-fixes]

**His decision:** Three things only Alexandru can decide: (1) The unlock word
on #522 — the "Do not merge" becomes "merges on Alexandru's explicit word",
and he must confirm that merging the docs records the design WITHOUT clearing
any gate (her assent stays first, untouched). (2) The broker host: sancta-claw
fails the broker design's "no Sancta shell" requirement today (Sancta has root
SSH there) — he chooses either a different host for the broker or extends
Gate-0's SSH amputation to cover sancta-claw for Sancta; until he chooses, the
journald/store exposure is only policy-closed. (3) The latency trade:
cadence-only + 10-min debounce means the presence bit lags reality by up to
~15 minutes — acceptable resolution for data about his home is his call (it
is exactly the coarseness that protects her).

**Recommendation:** Option A. The cadence-only push is the single move that
closes three of the five gaps structurally at once: a uniform push grid means
push timestamps (and therefore any journal line, any last_push_ts, any network
observation) carry zero information about arrivals/departures — the timing
side-channel is not mitigated, it is emptied. On top of that: monotonic
signed-ts (already in the signed payload; no new state) kills replay; an
explicit null push honors the design's own "null ≠ false" axiom when the
source goes blind; concrete defaults (300s/660s/600s) make the plan buildable
and the debounce criterion testable ("no pushed edge resolves better than 10
min; no state shorter than 10 min is ever visible; the push stream is
time-uniform"); and the #522→#527 merge order with a stated unlock sentence
converges all four documents on the one canonical chain: her assent → his
approval (which RESOLVES `council-20260706T172246Z-cf6dda`'s
escalate-to-human — no separate council gate remains) → Gate-0 amputation
VERIFIED → build → activate. Keep the no-log-on-ingest rule AND the
broker-host-no-shell requirement as defense in depth — sancta-claw today fails
the hybrid design's own "runs where Sancta has no shell" requirement, and that
must be surfaced, not papered over.
