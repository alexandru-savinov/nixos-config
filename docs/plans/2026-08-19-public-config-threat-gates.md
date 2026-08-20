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
  (`config.systemd.services."<n>".text` — the exact bytes systemd reads, not an approximation
  reconstructed from Nix options), and it states in its own header comment exactly what it cannot
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
at all); it cannot see Tailscale control-plane state that diverges from the checked-in ACL file
except through the G2.5 runtime probe, which itself depends on API credentials that are their own
grant (cross-reference G1.3); and it cannot enumerate every authentication mechanism a future
service might invent — it asserts a *declared* mechanism is present and *backed*, not that the
mechanism itself is unbreakable.

## Gate 1 — declarative invariants (build time, `flake.checks`, run on demand/locally)

Cheap, cannot be forgotten, but **not added to `.github/workflows/*`** — the CI pipeline is already
heavy and this plan adds nothing to it. Each check derives from the evaluated config, follows the
`execstart-path-contract.nix` shape (a small committed contract cross-referenced against rendered
config), and states what it cannot see.

- **G1.1 — exposure CONTRACT (redesigned per finding 4).** For every host in
  `builtins.attrNames self.nixosConfigurations` (never a hardcoded list), collect declared listen
  addresses/ports and cross-reference against a committed
  `docs/exposure-contract.nix` with columns `host · unit · protocol · address · port · audience ·
  authentication · authority`. Assert every non-loopback, non-tailnet bind has a row, and every row
  has all eight columns filled — a blank `authentication` or `authority` column fails the same as a
  missing row. *Negative arm:* (a) a fixture host binding `0.0.0.0:9999` with no contract row must
  fail; (b) a fixture row with `authentication` left blank must fail. *What this cannot see:*
  whether the declared authentication/authority is real — that's G1.5. Whether the host is actually
  listening where declared — that's G2.1.
- **G1.2 — hardening floor for `sancta-*`, REDESIGNED to check values (finding 2).** The original
  shape asserted presence only and is retired. Redesign: for every `systemd.services.sancta-*`,
  assert on *values*: `RestrictAddressFamilies` excludes `AF_INET`/`AF_INET6` unless the unit has a
  row in the G1.1 contract; `SystemCallFilter` is a named allow-group (e.g. `@system-service`) that
  excludes dangerous groups (`@raw-io`, `@reboot`, `@swap`, `@module`, `@clock`, `@mount`,
  `@debug`), not merely non-empty; `ProtectSystem` equals `strict`, not `full`, unless a named
  exemption with a reason exists. *Negative arm:* a fixture unit that HAS `SystemCallFilter` set
  (so the old presence-only check would go green) but sets it to a list including `@raw-io` must
  still fail. A fixture with `ProtectSystem=full` and no exemption entry must fail. *What this
  cannot see:* whether the running generation actually carries these values — that's G2.2.
- **G1.3 — CI agent grants, corrected (finding on tool-scoping).** Parse `.github/workflows/*.yml`
  for agent `--allowed-tools`/`claude_args`. Assert no write-capable grant (`gh pr comment`,
  `gh pr edit`, `gh api -X POST`) appears unless the workflow is declared as a publishing workflow
  in an allowlist — **and** assert the agent's effective `permissions.defaultMode` is not `auto` (or
  otherwise unenforced) for any non-publishing workflow, since a tool allowlist without an enforced
  permission mode is an approval matcher, not a sandbox: an agent with no `Write` tool has already
  been shown to write files anyway via a `Bash` redirect once `defaultMode = "auto"` was set.
  *Negative arm:* re-adding a removed grant must turn it red; a fixture workflow with
  `defaultMode: auto` and no `Write` grant must *also* turn red (proving the check doesn't treat
  tool-scoping alone as sufficient). *What this cannot see:* runtime enforcement of the permission
  mode itself — that's a property of the harness, not of this repo's config.
- **G1.4 — group membership floor.** Assert no service user joins a host-wide reader group
  (`systemd-journal`, `docker`, `adm`, `wheel`) without an entry in a reviewed allowlist. *Negative
  arm:* adding `systemd-journal` to `sancta` must fail. (PR #559 v1, encoded.) *What this cannot
  see:* whether the running host's actual group membership matches — that's G2.3.
- **G1.5 — authentication & authority artifacts vs. the G1.1 contract (new, finding 1).** For every
  G1.1 contract row where `authentication = "SSH pubkey"`, assert the corresponding
  `authorized_keys`/agenix-managed key declaration matches the row's `authority` — e.g. a row
  claiming authority "forced-command: rsync only" must have a `command=` restriction on that key,
  not a bare key granting a full shell. For every row where `authentication = "Tailscale ACL"`,
  assert the committed ACL policy file grants access to that port only to the declared `audience`
  tag/group, and grants no wider authority than declared. *Negative arm:* a fixture SSH key entry
  without a `command=` restriction, on a contract row that claims "forced-command only" authority,
  must fail; a fixture ACL rule granting `group:all` where the contract declares a narrower tag
  must fail. *What this cannot see:* whether the live Tailscale control-plane ACL matches the
  committed file (control-plane state can drift from git independently) — that's G2.5. Whether the
  authenticated caller stays inside its granted authority once connected — out of scope for any
  static check; a G3 question if it's answerable at all.

## Gate 2 — activation probes (runtime, read-only, in the mechanical queue — not GitHub Actions)

Eval green proves evaluability, never activation (`tests/execstart-path-contract.nix` exists
because of exactly that lesson — a `${coreutils}/bin/hostname` that didn't exist evaluated fine for
months). These run read-only via `index/bin/wq-tick`, report, never mutate, and never enter CI.

- **G2.1 — actual listeners vs. G1.1.** `ss -tlnH` on the host, compared against the contract for
  the config the host actually booted. Any listener not in the contract is a finding; any
  contract-row-but-absent listener is a *different* finding (a dead service). *What this cannot
  see:* whether the listener enforces the contract's declared authentication — that's G2.5.
- **G2.2 — actual unit hardening vs. G1.2 (values, not presence).** `systemctl show <unit> -p
  <directive>` for every `sancta-*` unit, diffed against the redesigned value floor — not merely
  checked for presence. Catches drift between what the flake says and what the running generation
  carries.
- **G2.3 — actual group membership vs. G1.4.** `id <user>`, compared to the allowlist.
- **G2.4 — file-mode probe for agent-readable stores.** Any path a service writes for another user
  (e.g. journal exports) is checked for mode/owner, since the write path — not the declaration — is
  what an attacker meets.
- **G2.5 — auth reality vs. G1.5 (new, finding 1).** Read-only pull of the live Tailscale ACL (via
  the tailnet API, using a credential that is itself accounted for under G1.3) and the actual
  `authorized_keys` bytes on the host; diff against G1.5's committed contract. This is the one
  probe that can catch control-plane drift a git diff would never show. *What this cannot see:*
  behavior of an in-scope, authenticated caller — never in scope for a read-only probe.

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
  "report findings" mandate is a disclosure pipe).
- **G3.3 — fleet scope (open).** Host-level offensive tooling (e.g. the PentAGI deployment on
  another fleet host) belongs to this gate, but is out of scope for this repo's checks and is not
  assessable from the host this plan was written on. Tracked separately.

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

- **Every check ships with a negative arm.** No exceptions; a check that cannot fail is not a check
  (this repo has been bitten twice). For G1.2 and G1.5 specifically, the negative arm must keep the
  relevant directive/artifact *present* but set it to a *dangerous value* — presence-only fixtures
  proved insufficient once already.
- **Every check states what it cannot see.** Not just where useful — uniformly, in its own bullet,
  pointing at the gate that covers the blind spot if one exists.
- **Exemptions are named, not implicit.** An allowlist entry carries a reason string and an owner.
  Absence of an entry is a failure, not a pass.
- **Probes are read-only.** Gate 2 never mutates a host; it reports drift for a human.
- **No new GitHub Actions.** Gate 1 checks live in `flake.checks`, run on demand/locally via
  `nix flake check`; Gate 2 probes live in the mechanical queue (`index/bin/wq-tick`). Neither adds
  a workflow to `.github/workflows/*` — the pipeline is already heavy.
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
