# Testing a public NixOS config — three gates, not one audit

**Date:** 2026-08-19 · **Status:** plan, no code · **Scope:** what to test, in what order, and
how each check proves it can fail.

## The premise

This config is **public**. The threat model is therefore not "they must not see" but
**"they see everything and still cannot"**. An attacker reads every port, unit, path and
grant before touching anything. Secrecy contributes nothing; only enforced properties do.

## What is already covered (do not rebuild)

| Layer | Mechanism | What it proves |
|---|---|---|
| Dependencies / secrets | Trivy, CodeQL, GitGuardian, Security Scan (CI) | known CVEs, committed secrets, code patterns |
| Decryptability | `checks.secrets-recipient-guard` | who *can* decrypt each secret |
| Network exposure (one unit) | `checks.sancta-gallery-bind-probe` | the gallery binds tailnet, not `0.0.0.0` |
| Store-ref existence | `checks.unit-script-refs` (PR #558) | `${pkg}/bin/X` strings that do not exist |
| Substrate authenticity | `checks.sancta-doctrine-guard` | the authored substrate is present + recoverable |

Every one of these carries a negative arm — a fixture that must turn it red. That property
is the point; a check that has never failed has not been shown to be able to.

## The gaps

1. **Declared ≠ actual.** Nothing compares what the config *says* is exposed with what the
   host is *actually* doing. `sancta-gallery-bind-probe` does this for exactly one service.
2. **Hardening is per-unit convention, not an invariant.** PR #559's review found a new
   root oneshot shipped without the hardening its sibling unit carries. Convention caught
   it that time because a human asked; nothing asserts it.
3. **Capability grants to CI agents are unbounded by policy.** 2026-08-19: a reviewing
   agent held a raw public-comment grant it did not need for its task (fixed under path B,
   least-privilege). No check would have flagged the grant itself.
4. **Prompt injection has no test at all.** The repo runs LLM agents over attacker-influenced
   text (PR diffs, issue bodies). No scanner models this; it is the newest surface and the
   least covered.

## Gate 1 — declarative invariants (build time, `flake.checks`)

Cheap, run on every PR, cannot be forgotten. Each derives from the evaluated config.

- **G1.1 — exposure allowlist.** For every `nixosConfiguration`, collect the units'
  declared listen addresses (`listenAddress`/`bind`/`ExecStart` port args where the module
  exposes them) plus `networking.firewall.allowed*Ports`. Assert: nothing binds a non-loopback,
  non-tailnet address unless its unit name appears in an explicit `docs/exposure-allowlist.nix`
  with a reason string. *Negative arm:* a fixture host binding `0.0.0.0:9999` must fail.
- **G1.2 — hardening floor for `sancta-*`.** Assert every `systemd.services.sancta-*` sets
  the minimum set already used by `sancta-doctrine-guard`: `NoNewPrivileges`,
  `ProtectSystem=strict|full`, `ProtectHome`, `PrivateTmp`, `RestrictAddressFamilies`,
  `SystemCallFilter`, `ProtectKernel*`, `RestrictNamespaces`, `LockPersonality`. Exemptions
  live in a named attrset with a reason. *Negative arm:* a fixture unit missing
  `SystemCallFilter` must fail. (Directly generalises the PR #559 finding.)
- **G1.3 — CI agent grants.** Parse `.github/workflows/*.yml` for agent `--allowed-tools` /
  `claude_args`. Assert no write-capable grant (`gh pr comment`, `gh pr edit`, `gh api -X POST`)
  appears unless the workflow is declared as a publishing workflow in an allowlist.
  *Negative arm:* re-adding a removed grant must turn it red. (This is the 2026-08-19 bug,
  made structural rather than remembered.)
- **G1.4 — group membership floor.** Assert no service user joins a host-wide reader group
  (`systemd-journal`, `docker`, `adm`, `wheel`) without an entry in a reviewed allowlist.
  *Negative arm:* adding `systemd-journal` to `sancta` must fail. (PR #559 v1, encoded.)

## Gate 2 — activation probes (runtime, read-only, on the host)

Eval green proves evaluability, never activation (`tests/unit-script-refs.nix` exists because
of that lesson; a `${coreutils}/bin/hostname` that does not exist evaluated fine for months).
These run read-only in the maintenance queue and report, never mutate.

- **G2.1 — actual listeners vs G1.1.** `ss -tlnH` on the host, compared against the allowlist
  derived from the same config the host booted. Any listener not in the allowlist is a
  finding; any allowlisted-but-absent listener is a *different* finding (a dead service).
- **G2.2 — actual unit hardening vs G1.2.** `systemctl show <unit> -p <directive>` for every
  `sancta-*` unit, diffed against the declared floor. Catches drift between what the flake
  says and what the running generation carries.
- **G2.3 — actual group membership vs G1.4.** `id <user>`, compared to the allowlist.
- **G2.4 — file-mode probe for agent-readable stores.** Any path a service writes for another
  user (e.g. journal exports) is checked for mode/owner, since the write path — not the
  declaration — is what an attacker meets.

Cadence: hourly-to-daily in the existing mechanical queue; a failure surfaces as a loud row,
never as a silent log line. Each probe reports `ok` / `drift` / `unknown` — never "assumed ok".

## Gate 3 — adversarial (periodic, human-gated)

- **G3.1 — injection fixtures.** For every workflow whose prompt ingests attacker-influenced
  text, a fixture containing hostile instructions (e.g. an `@`-mention meant to re-summon a
  privileged agent, or "ignore previous instructions" phrasing in a diff comment) must produce
  a **defused** output. *Negative arm:* the same fixture with the defusal disabled must fail
  the test. This is the first test of this class in the repo.
- **G3.2 — independent red-team pass.** Given the public config, a separate model (different
  priors, own budget) answers: "what would you attack first, and what does the config already
  prevent?" Findings return **privately to the maintainer** — never posted to the public PR
  by the agent that found them (2026-08-19 lesson: a delegated agent with a public-write grant
  plus a "report findings" mandate is a disclosure pipe).
- **G3.3 — fleet scope (open).** Host-level offensive tooling (e.g. the PentAGI deployment on
  another fleet host) belongs to this gate, but is out of scope for this repo's checks and is
  not assessable from the host this plan was written on. Tracked separately.

## Order of work (value / effort)

1. **G2.1 listeners probe** — cheapest real-world truth, catches the class no eval can.
2. **G1.2 hardening floor** — generalises a finding that already landed twice.
3. **G1.3 grant allowlist** — makes today's least-privilege fix permanent.
4. **G1.4 + G2.3 group floor** — encodes the #559 v1 decision.
5. **G1.1 + G2.1 pairing** — the allowlist becomes meaningful once the probe exists.
6. **G3.1 injection fixtures** — after the deterministic paths are settled.
7. **G3.2 red-team** — last; run before it, and it produces fears instead of findings.

## Rules that bind every gate

- **Every check ships with a negative arm.** No exceptions; a check that cannot fail is not a
  check (this repo has been bitten twice).
- **Exemptions are named, not implicit.** An allowlist entry carries a reason string and an
  owner. Absence of an entry is a failure, not a pass.
- **Probes are read-only.** Gate 2 never mutates a host; it reports drift for a human.
- **Security findings route privately.** Public disclosure of an unpatched mechanism is a
  maintainer decision, never an agent's default.
- **Fail closed.** A probe that cannot determine state reports `unknown` and fails the gate,
  rather than assuming health.

## Non-goals

No new network listeners; no offensive tooling in this repo; no secret-scanning rewrite
(Trivy/GitGuardian already cover it); no attempt to make the config private — the premise is
that it stays public and the properties hold anyway.
