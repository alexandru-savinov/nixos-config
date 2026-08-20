# Testing a public NixOS config — four gates, in a different order than v1

**Date:** 2026-08-19 (rewritten 2026-08-20) · **Status:** plan, no code · **Scope:** what to
test, in what order, and how each check proves it can fail.

## What changed since the first draft, and why

An independent model (different priors, own budget) reviewed the first draft and returned four
findings, all accepted:

1. **A whole gate was missing.** The plan checked WHERE a service listens, never WHO may pass and
   with what powers. A tailnet-only port can be perfectly bound and still hand out far too much to
   any tailnet member. Added below as its own section, with checks G1.5/G2.5.
2. **G1.2 (hardening floor) was theatre.** It asserted the *presence* of hardening directives,
   never their *values*. `RestrictAddressFamilies` can include the network; `SystemCallFilter` can
   be wide open; `ProtectSystem=full` permits more than `strict`. Redesigned below to check values,
   with a fixture that keeps the directive present but dangerous.
3. **The original priority order was wrong.** It put G2.1 (diff real listeners against the
   allowlist) *before* G1.1 (the allowlist itself) — you cannot compare reality against a contract
   that does not exist yet. Reordered below; see "Order of work."
4. **The exposure allowlist needed to be a contract, not a port list.** "Cannot" is decided by
   authentication and authority, not at `bind()`. G1.1 is redesigned around an
   `audience · authentication · authority` shape.

## What changed again, after revmux reviewed this rewrite

The rewrite above was run through `revmux --profile focused` (a Claude bugs pass + a Codex
adversarial pass, then synthesis and verification against this repo — `nix eval`, `git grep`,
`origin/main`). It returned 15 findings, all about this document's own factual claims and
internal consistency, not about prose or tone, and all 15 were confirmed and accepted; nothing
was rejected. Fixed below, in the sections they touch: a wrong Nix attribute path for rendered
unit text (`systemd.services` doesn't exist; `systemd.units."<n>.service"` does — the exact
confusion `execstart-path-contract.nix`'s own header warns against); a swapped file attribution
(the `${coreutils}/bin/hostname` lesson belongs to `unit-script-refs.nix`, not
`execstart-path-contract.nix`, which exists for a different bug); an overclaim that Gate-1
checks add nothing to CI (`check.yml` already runs `nix flake check --all-systems` on every
push — flagged as an open budget question, not silently assumed away); a G1.2 rule that would
fail existing, correctly-hardened outbound-only units by gating `AF_INET` need on an *inbound*
contract row those units can never earn; a G1.1 exemption for tailnet listeners that left the
new auth gate with nothing to check for exactly the class it exists to cover; a TCP-only
listener probe that would miss UDP; a vocabulary mismatch where G1.5 branched on a value G1.1
never defines, and conflated an authority mechanism with an authentication one; a G1.3
assertion on a config key (`permissions.defaultMode`) that exists nowhere in this repo; a G2.5
credential cross-reference pointed at the wrong existing check; a hardening-floor redesign that
silently dropped six directives instead of adding value-checks alongside them; a `wq-tick` path
written as repo-relative when it lives in a separate repo; missing "what this cannot see"
bullets on five checks, in violation of this plan's own new rule; no negative arm specified for
any Gate-2 probe; and no stated mechanism for distributing one probe across three hosts.

This rewrite also folds in three things confirmed true on 2026-08-20, the day of the rewrite:

- **The fleet shrank.** `sancta-claw`, `hermes-claw`, `zero-kuzea` are retired (PRs #565, #567,
  both merged into `main`); live `nixosConfigurations` are `sancta-choir`, `rpi5`, `rpi5-full`.
  Every check below iterates hosts by evaluating `builtins.attrNames self.nixosConfigurations` (or
  `nix flake show --json`) — **never a hardcoded host list.** The fleet has already changed size
  once since this plan's first draft; a hardcoded list would have silently stopped covering the
  hosts that were added or kept probing the ones that are gone.
- **A working template for a Gate-1 check landed.** `tests/execstart-path-contract.nix` (PR #568,
  on `main`) is an eval-time check that cross-references a small, committed, human-written contract
  (`tests/execstart-path-contracts.nix`) against each unit's *rendered* systemd text
  (`config.systemd.units."<n>.service".text`, or `.../user/units/...` for user units — the exact
  bytes systemd reads, not an approximation reconstructed from Nix options), and it states in its own header comment exactly what it cannot
  see (a script living outside the Nix store, on a LUKS volume no CI runner has mounted) and hands
  that half to a separate runtime probe. Every Gate-1 check below should have this shape: a
  committed contract, cross-referenced against rendered config, with an explicit "what this cannot
  see" note pointing at the matching Gate-2 probe. Not a new shape invented per check.
- **A capability gate we believed in is not one.** Scoped `Bash(cmd:*)` entries in an agent
  definition are an *approval matcher*, not a sandbox — with `permissions.defaultMode = "auto"` set
  fleet-wide, an agent with no `Write` tool still wrote a file via a `Bash` shell redirect. G1.3
  below is corrected: a tool-grant allowlist alone proves nothing if the surrounding permission
  mode makes the allowlist advisory rather than enforced.

## The premise

This config is **public**. The threat model is therefore not "they must not see" but
**"they see everything and still cannot"**. An attacker reads every port, unit, path and grant
before touching anything. Secrecy contributes nothing; only enforced properties do.

## What is already covered (do not rebuild)

| Layer | Mechanism | What it proves |
|---|---|---|
| Dependencies / secrets | Trivy, CodeQL, GitGuardian, Security Scan (CI) | known CVEs, committed secrets, code patterns |
| Decryptability | `checks.secrets-recipient-guard` | who *can* decrypt each secret |
| Network exposure (one unit) | `checks.sancta-gallery-bind-probe` | the gallery binds tailnet, not `0.0.0.0` |
| Store-ref existence | `checks.unit-script-refs` (PR #558) | `${pkg}/bin/X` strings that do not exist |
| Non-store ExecStart paths | `checks.execstart-path-contract` (PR #568) | committed contract vs. rendered unit text for scripts outside the store; the template Gate 1 below follows |
| Substrate authenticity | `checks.sancta-doctrine-guard` | the authored substrate is present + recoverable |

Every one of these carries a negative arm — a fixture that must turn it red. That property is the
point; a check that has never failed has not been shown to be able to.

## The gaps

1. **Declared ≠ actual.** Nothing compares what the config *says* is exposed with what the host is
   *actually* doing. `sancta-gallery-bind-probe` does this for exactly one service.
2. **Hardening is per-unit convention, not an invariant — and even encoded, presence isn't
   enough.** PR #559's review found a new root oneshot shipped without the hardening its sibling
   unit carries. A check that only asserts a directive is *set* can go green while the value it's
   set to is dangerous.
3. **Nothing checks who may pass a listener, or with what power, once bound correctly.** A
   tailnet-only bind is not a security property by itself — it's a property of *addressing*.
   Authentication (who) and authority (what they can then do) are separate questions this plan did
   not ask at all until the rewrite.
4. **Capability grants to CI agents are unbounded by policy, and tool-scoping is not the boundary
   it looks like.** 2026-08-19: a reviewing agent held a raw public-comment grant it did not need
   for its task. Separately confirmed 2026-08-20: an agent's tool allowlist is an approval matcher,
   not a sandbox, when the permission mode is `auto`. No check would have flagged either.
5. **Prompt injection has no test at all.** The repo runs LLM agents over attacker-influenced text
   (PR diffs, issue bodies). No scanner models this; it is the newest surface and the least
   covered.

## The missing gate: authentication & authority (who may pass, with what power)

A well-bound tailnet-only port is a claim about *addressing*, not about *access*. Anyone on the
tailnet — which, for a shared or growing tailnet, is not "just Alexandru" — can reach it. What
stops them from doing damage once they connect is authentication (does the service verify who they
are at all, and how) and authority (what can an authenticated caller then do). Neither question is
asked by the exposure allowlist as originally written, and neither is a property Gate 1's original
hardening floor or Gate 2's original probes touch — hardening restricts what a *compromised unit*
can do to the *host*; it says nothing about what a *legitimate but unintended caller* can do to the
*service*.

This plan treats authentication/authority as a first-class gate, expressed as two checks that live
inside the existing Gate 1 / Gate 2 machinery rather than inventing a fourth top-level structure:

- **G1.1 is redesigned** (finding 4) so the exposure allowlist becomes a contract with columns
  `host · unit · protocol · address · port · audience · authentication · authority` — `audience`
  is who is reachable (e.g. "tailnet", "localhost-only"), `authentication` is the mechanism (e.g.
  "SSH pubkey", "Tailscale node identity", "none"), `authority` is what an authenticated caller can
  then do (e.g. "shell as user X", "forced-command: rsync only", "read-only HTTP GET").
- **G1.5 / G2.5** (new, finding 1) check that the `authentication`/`authority` columns are *backed
  by real enforcement artifacts* — SSH `authorized_keys` restrictions and Tailscale ACL grants —
  not just asserted in prose in the contract. Concrete checks are under Gate 1 and Gate 2 below.

**What this gate cannot see, stated once:** it cannot see whether an authenticated, in-scope caller
misuses authority it was legitimately granted (that is a G3 adversarial question, if it's answerable
at all); an ACL check alone cannot see application-level authority at all, only reachability (see
G1.5's scope limit below); it cannot see Tailscale control-plane state that diverges from the
checked-in ACL file except through the G2.5 runtime probe, which itself depends on API credentials
that are their own grant — covered by `secrets-recipient-guard`, not by G1.3 (G1.3 is scoped to CI
workflow tool grants, not host-side API credentials); and it cannot enumerate every authentication
mechanism a future service might invent — it asserts a *declared* mechanism is present and
*backed*, not that the mechanism itself is unbreakable.

## Gate 1 — declarative invariants (build time, `flake.checks`, run on demand/locally)

Cheap, cannot be forgotten — but **open budget question, not silently free:**
`.github/workflows/check.yml` already runs `nix flake check --all-systems` on every push and PR,
so anything added to `flake.checks` runs there automatically, with no separate workflow file and
no opt-out. `flake.nix` already documents the hazard this creates — a VM test was moved *out* of
`flake.checks` after it killed a runner. Each check below iterates every host, so before it is
built, someone must either confirm the runner cost is acceptable or move the expensive ones to
`packages.<system>.*` (invoked on demand, off the default CI path) the way that VM test was
moved. This plan does not resolve that choice; it names it. Each check derives from the evaluated
config, follows the `execstart-path-contract.nix` shape (a small committed contract
cross-referenced against rendered config), and states what it cannot see.

- **G1.1 — exposure CONTRACT (redesigned per finding 4).** For every host in
  `builtins.attrNames self.nixosConfigurations` (never a hardcoded list), collect declared listen
  addresses/ports and cross-reference against a committed
  `docs/exposure-contract.nix` with columns `host · unit · protocol · address · port · audience ·
  authentication · authority`. Assert **every** listener has a row — including loopback and
  tailnet-only ones, not just non-loopback/non-tailnet binds as the first version of this
  redesign said; `audience` is exactly the column that classifies reachability
  ("localhost-only", "tailnet", "public"), so exempting the quiet cases from needing a row left
  the new authentication gate (G1.5) with nothing to check for precisely the listener class it
  exists to cover. Every row must have all eight columns filled — a blank `authentication` or
  `authority` column fails the same as a missing row. *Negative arm:* (a) a fixture host binding
  `0.0.0.0:9999` with no contract row must fail; (b) a fixture tailnet-only bind with no contract
  row must also fail; (c) a fixture row with `authentication` left blank must fail. *What this
  cannot see:* whether the declared authentication/authority is real — that's G1.5. Whether the
  host is actually listening where declared — that's G2.1.
- **G1.2 — hardening floor for `sancta-*`, REDESIGNED to check values (finding 2).** The presence
  check is not replaced but *extended*: still assert presence of `NoNewPrivileges`,
  `ProtectHome`, `PrivateTmp`, `ProtectKernel*`, `RestrictNamespaces`, `LockPersonality` (dropping
  these was a mistake in the first redesign — a unit could satisfy a floor that checked only the
  three value-sensitive directives below while disabling everything else), and add *value*
  assertions for three: `SystemCallFilter` is a named allow-group (e.g. `@system-service`) that
  excludes dangerous groups (`@raw-io`, `@reboot`, `@swap`, `@module`, `@clock`, `@mount`,
  `@debug`), not merely non-empty; `ProtectSystem` equals `strict`, not `full`, unless a named
  exemption with a reason exists; `RestrictAddressFamilies` excludes `AF_INET`/`AF_INET6` unless
  the unit declares an egress need — its **own** exemption-list entry with a reason (e.g.
  `sancta-self-backup`: "ssh push", `sancta-heartbeat-tick`: "outbound API calls"), *not* a G1.1
  contract row: outbound-only units never bind anything and can never earn a row, so gating the
  AF_INET rule on G1.1 would fail every correctly-hardened outbound unit that exists on `main`
  today. *Negative arm:* a fixture unit that HAS `SystemCallFilter` set (so a presence-only check
  would go green) but sets it to a list including `@raw-io` must still fail. A fixture with
  `ProtectSystem=full` and no exemption entry must fail. A fixture unit with `AF_INET` set and
  neither a G1.1 row nor an egress-exemption entry must fail. *What this cannot see:* whether the
  running generation actually carries these values — that's G2.2.
- **G1.3 — CI agent grants, corrected (finding on tool-scoping).** Parse `.github/workflows/*.yml`
  for agent `--allowed-tools`/`claude_args`. Assert no write-capable grant (`gh pr comment`,
  `gh pr edit`, `gh api -X POST`) appears unless the workflow is declared as a publishing workflow
  in an allowlist. **Separately**, since a tool allowlist without an enforced permission mode is an
  approval matcher, not a sandbox — an agent with no `Write` tool has already been shown to write
  files anyway via a `Bash` redirect once `permissions.defaultMode = "auto"` was set — flag that
  this check *cannot* close that gap from inside this repo: `defaultMode` is not a key in any
  `.github/workflows/*.yml` file here (confirmed: `git grep -n defaultMode` on `main` returns
  nothing); it lives in the separate claude-shared flake's `settings.json`, which this repo only
  imports. G1.3 as implemented here can only assert the tool-grant half; closing the
  permission-mode half requires a check in claude-shared, or a recorded blind spot, not an
  assertion this repo cannot observe. *Negative arm:* re-adding a removed write-capable grant must
  turn it red. *What this cannot see:* the effective permission mode at runtime — that lives in
  claude-shared, outside this repo's checks entirely; recorded here as an open dependency, not
  papered over with an assertion that would pass vacuously.
- **G1.4 — group membership floor.** Assert no service user joins a host-wide reader group
  (`systemd-journal`, `docker`, `adm`, `wheel`) without an entry in a reviewed allowlist. *Negative
  arm:* adding `systemd-journal` to `sancta` must fail. (PR #559 v1, encoded.) *What this cannot
  see:* whether the running host's actual group membership matches — that's G2.3.
- **G1.5 — authentication & authority artifacts vs. the G1.1 contract (new, finding 1).** For every
  G1.1 contract row where `authentication = "SSH pubkey"`, assert the corresponding
  `authorized_keys`/agenix-managed key declaration matches the row's `authority` — e.g. a row
  claiming authority "forced-command: rsync only" must have a `command=` restriction on that key,
  not a bare key granting a full shell. For every row where `authentication = "Tailscale node
  identity"` (the same value G1.1 defines — a prior draft of this check branched on "Tailscale
  ACL", a spelling G1.1 never uses and which names the *authority* mechanism, not the
  authentication one; a contract row written to G1.1's own vocabulary fell through unverified),
  assert the committed ACL policy file grants access to that port only to the declared `audience`
  tag/group. **Scope limit, stated plainly:** the ACL check only validates *audience/reachability*
  — which identities may reach the port at all — never *authority*. An ACL cannot enforce
  "read-only HTTP GET" or any other application-level authority; a service whose ACL correctly
  admits only the declared audience, but whose application logic permits writes beyond the
  declared authority, passes this check while violating its own contract row. Verifying authority
  beyond reachability needs a service-specific artifact or probe this plan does not yet specify.
  Any contract row whose `authentication` value matches neither branch must fail the check, not
  pass silently. *Negative arm:* a fixture SSH key entry without a `command=` restriction, on a
  contract row that claims "forced-command only" authority, must fail; a fixture ACL rule granting
  `group:all` where the contract declares a narrower tag must fail; a fixture contract row with an
  `authentication` value outside the two known branches must fail rather than being skipped.
  *What this cannot see:* whether the live Tailscale control-plane ACL matches the committed file
  (control-plane state can drift from git independently) — that's G2.5, whose own credential is
  covered under `secrets-recipient-guard`, not G1.3. Whether the authenticated caller stays inside
  its granted *authority* once connected, beyond what an ACL can express — out of scope for any
  static check; a G3 question if it's answerable at all.

## Gate 2 — activation probes (runtime, read-only, in the mechanical queue — not GitHub Actions)

Eval green proves evaluability, never activation (`tests/unit-script-refs.nix` exists because of
exactly that lesson — a `${coreutils}/bin/hostname` that didn't exist evaluated fine for months,
PR #558; `execstart-path-contract.nix`, PR #568, is the *other* lesson, a missing shebang
interpreter — the two checks are deliberately distinct, see "What is already covered" above).
These run read-only via the INDEX repo's `bin/wq-tick` (a separate repo on the LUKS soul volume,
not a path inside this one — see `flake.nix`'s own citation convention), report, never mutate, and
never enter CI. **Distribution, stated plainly:** these probes observe the machine they run on;
routing them all through one `wq-tick` queue does not by itself put them on `rpi5`/`rpi5-full` —
each probe needs either a per-host `wq-tick` instance or a remote-execution step (e.g. over
Tailscale SSH) plus a way to aggregate per-host results, neither of which this plan specifies yet.
Until that's designed, treat coverage as `sancta-choir`-only and say so in the probe's own output,
rather than silently reporting one host's state as the fleet's.

**Negative arm, Gate 2 (previously unspecified for every probe below):** a runtime probe's
negative arm is a non-mutating test fixture or isolated harness — e.g. a throwaway systemd unit
with a known-bad `ss`-visible bind, or a saved `systemctl show` snapshot with a directive value
deliberately wrong — run through the probe's comparison logic to prove it reports `drift`, not
`ok`. Every G2.x check below needs its own version of this before it ships; none is designed yet.

- **G2.1 — actual listeners vs. G1.1.** `ss -tlnH` (TCP) **and** `ss -ulnH` (UDP) on the host,
  each compared against the contract's `protocol` column for the config the host actually booted —
  a TCP-only probe would never flag an undeclared UDP listener despite the contract having a
  protocol column for exactly that. Any listener not in the contract is a finding; any
  contract-row-but-absent listener is a *different* finding (a dead service). *What this cannot
  see:* whether the listener enforces the contract's declared authentication — that's G2.5.
- **G2.2 — actual unit hardening vs. G1.2 (values, not presence).** `systemctl show <unit> -p
  <directive>` for every `sancta-*` unit, diffed against the redesigned value floor — not merely
  checked for presence. Catches drift between what the flake says and what the running generation
  carries. *What this cannot see:* a directive can be correct on the unit and still be
  circumvented by something outside systemd's model entirely (e.g. a setuid helper); this probe
  only sees what `systemctl show` reports.
- **G2.3 — actual group membership vs. G1.4.** `id <user>`, compared to the allowlist. *What this
  cannot see:* group membership granted transiently at runtime rather than declared in the unit
  file (e.g. `sudo -g`) — this probe reads static membership only.
- **G2.4 — file-mode probe for agent-readable stores.** Any path a service writes for another user
  (e.g. journal exports) is checked for mode/owner, since the write path — not the declaration — is
  what an attacker meets. *What this cannot see:* ACLs or extended attributes layered on top of
  the POSIX mode bits this probe reads; a mode-clean file can still carry a permissive ACL.
- **G2.5 — auth reality vs. G1.5 (new, finding 1).** Read-only pull of the live Tailscale ACL (via
  the tailnet API, using a credential covered by `secrets-recipient-guard`, not G1.3) and the
  actual `authorized_keys` bytes on the host; diff against G1.5's committed contract. This is the
  one probe that can catch control-plane drift a git diff would never show. *What this cannot
  see:* behavior of an in-scope, authenticated caller — never in scope for a read-only probe; nor
  application-level authority, for the same reason G1.5's ACL check cannot see it.

Cadence: hourly-to-daily in the existing mechanical queue; a failure surfaces as a loud row, never
a silent log line. Each probe reports `ok` / `drift` / `unknown` — never "assumed ok".

## Gate 3 — adversarial (periodic, human-gated)

- **G3.1 — injection fixtures.** For every workflow whose prompt ingests attacker-influenced text,
  a fixture containing hostile instructions (e.g. an `@`-mention meant to re-summon a privileged
  agent, or "ignore previous instructions" phrasing in a diff comment) must produce a **defused**
  output. *Negative arm:* the same fixture with the defusal disabled must fail the test. This is
  the first test of this class in the repo. *What this cannot see:* injection vectors not yet
  imagined; this is a fixture set, not exhaustive coverage.
- **G3.2 — independent red-team pass.** Given the public config, a separate model (different
  priors, own budget) answers: "what would you attack first, and what does the config already
  prevent?" Findings return **privately to the maintainer** — never posted to the public PR by the
  agent that found them (2026-08-19 lesson: a delegated agent with a public-write grant plus a
  "report findings" mandate is a disclosure pipe). *What this cannot see:* anything the reviewing
  model doesn't think to try; it is one more perspective, not exhaustive coverage, and its
  findings are only as good as what it was shown.
- **G3.3 — fleet scope (open).** Host-level offensive tooling (e.g. the PentAGI deployment on
  another fleet host) belongs to this gate, but is out of scope for this repo's checks and is not
  assessable from the host this plan was written on. Tracked separately. *What this cannot see:*
  everything — this item is a pointer to future scope, not a check; it proves nothing on its own.

## Order of work (revised — the original order was backwards)

The first draft ordered G2.1 (diff real listeners against the allowlist) before G1.1 (the allowlist
itself), which cannot work: there is nothing to diff reality against until the contract exists. An
independent review caught this (finding 3) and proposed: (1) G1.3, (2) G1.1+G2.1 as one pair,
(3) G1.4+G2.3, (4) G1.2 redesigned+G2.2, (5) G3.1 — for the plan's original three-gate structure.
Adding the authentication/authority gate (finding 1) required deciding where it lands in that
sequence; it's placed immediately after the contract pair, because G1.5 depends on the
`audience`/`authentication`/`authority` columns that don't exist until G1.1 is redesigned, and
before the group-floor/hardening work because the reviewer named the missing auth gate more
consequential than either.

1. **G1.3 — CI agent grants (corrected).** Cheapest, external blast radius, a defect already
   produced today (2026-08-19's public-comment grant). Makes today's least-privilege fix permanent,
   and closes the tool-scoping-is-not-a-sandbox gap found 2026-08-20.
2. **G1.1 + G2.1 as one pair.** The contract, then the probe that checks it against reality — a
   probe with nothing to diff against is not a check.
3. **G1.5 + G2.5 — authentication & authority.** The gate finding 1 said was missing entirely. Slots
   here because it depends on the contract columns G1.1 just added, and because "well-bound but
   wide open to any tailnet member" is exactly the class of gap that made the review necessary.
4. **G1.4 + G2.3 — group membership floor.** Cheap and deterministic; encodes the #559 v1 decision.
5. **G1.2 REDESIGNED (semantic, values) + G2.2.** Closes the theatre finding — a check that could
   go green while a unit kept a dangerous capability.
6. **G3.1 — injection fixtures.** After the deterministic paths are settled.
7. **G3.2 — red-team.** Last; run before it, and it produces fears instead of findings.

## Rules that bind every gate

- **Every check ships with a negative arm.** No exceptions — this applies to Gate 2 exactly as much
  as Gate 1; a runtime probe with no fixture proving it can report `drift` is unverified, the same
  as an eval-time check that has never been shown to go red (this repo has been bitten twice on
  the eval-time side already). For G1.2 and G1.5 specifically, the negative arm must keep the
  relevant directive/artifact *present* but set it to a *dangerous value* — presence-only fixtures
  proved insufficient once already.
- **Every check states what it cannot see.** Not just where useful — uniformly, in its own bullet,
  pointing at the gate that covers the blind spot if one exists.
- **Exemptions are named, not implicit.** An allowlist entry carries a reason string and an owner.
  Absence of an entry is a failure, not a pass.
- **Probes are read-only.** Gate 2 never mutates a host; it reports drift for a human.
- **No new GitHub Actions workflow — but `flake.checks` is not automatically off-CI.** Gate 2
  probes live in the mechanical queue (the INDEX repo's `bin/wq-tick`), genuinely never touching
  CI. Gate 1 checks are meant to run on demand/locally, but `flake.checks` entries run inside the
  *existing* `check.yml` job's `nix flake check --all-systems` unless deliberately placed
  elsewhere (e.g. `packages.<system>.*`, as an existing VM test was moved to avoid killing a
  runner) — see the runner-cost note under Gate 1.
- **Host lists are derived, never hardcoded.** Every check iterates
  `builtins.attrNames self.nixosConfigurations` at eval time. The fleet has already shrunk once
  (six hosts to three) since this plan's first draft.
- **Security findings route privately.** Public disclosure of an unpatched mechanism is a
  maintainer decision, never an agent's default.
- **Fail closed.** A probe that cannot determine state reports `unknown` and fails the gate, rather
  than assuming health.

## Non-goals

No new network listeners; no offensive tooling in this repo; no secret-scanning rewrite
(Trivy/GitGuardian already cover it); no attempt to make the config private — the premise is that
it stays public and the properties hold anyway; no attempt to enumerate every possible
authentication bypass (G1.5/G2.5 check that declared mechanisms are backed by real artifacts, not
that the mechanisms themselves are unbreakable — that residual question is G3's, if it's answerable
at all).
