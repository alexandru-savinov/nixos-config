# Gatus coverage and Vigil boundaries

Status: proposed, 2026-09-22. This plan authorizes no production switches,
service interruptions, new secrets, paid requests, or monitoring-semantics changes.
Implement in small worktree-backed PRs; obtain approval before production activation.

## Goal

Make the dashboard answer three distinct questions: is the service reachable,
does its public interface work, and does a representative user journey complete?
Use native Gatus features where they answer those questions. Retain Vigil's
host-local evidence and established incident behavior. Success is useful coverage,
not enabling every available Gatus feature.

## Verified starting point

Repository baseline: PR #602, `aa57a0b330d457a879268bdaf7112c885da85934`.
Read-only live Gatus inventory confirms **24 endpoints**: six direct checks,
16 public Vigil detail rows, and two Vigil summaries. Deployment evidence is
tracked separately in PR #603; this plan does not replace that evidence.

| Direct Gatus check | Current assertion | What it does not establish |
| --- | --- | --- |
| n8n | Local `/healthz` returns 200 | A workflow produces the expected result |
| Anki Workflow | UI webhook returns 200 | Image-to-deck processing succeeds |
| NixFrame Upload | UI webhook returns 200 | Upload or frame delivery succeeds |
| Home Assistant | Authenticated local `/api/` returns 200 | Desired private entity conditions or the user-facing HTTPS path |
| Tailscale | Pi tailnet hostname answers ICMP | Remote service or HTTPS availability |
| OpenRouter API | Model-list GET returns 200 within 3 seconds | Inference succeeds, account credit, or model quality |

The Nix wrapper already supports HTTP method/body/headers, DNS/SSH settings,
suites with shared context and always-run steps, SQLite history, and runtime
credential injection. Suites are currently disabled alongside Open-WebUI.
Open-WebUI and Qdrant endpoint definitions are commented out; do not enable
monitoring for services merely because old definitions exist.

The wrapper exposes global alert-provider configuration but currently does not
serialize per-endpoint alerts. It also does not expose endpoint UI settings,
client timeouts, or suite timeout. Verify each missing field against the installed
Gatus 5.31.0 before proposing a minimal wrapper extension. The module's certificate
and domain comments say days; upstream conditions use duration values. Correct
that wording if those conditions are introduced, with a pinned-version fixture.

Gatus response time on a Vigil row measures fetching a snapshot, not the original
probe. Likewise, its poll timestamp is not Vigil's `checked_at`. Preserve this
meaning explicitly in the dashboard documentation.

## Ownership map

| Existing Vigil evidence | Planned owner / treatment |
| --- | --- |
| `build-volume`, `disk-root`, `tailscaled` | Keep host-local checks in Vigil |
| `soul-mirror`, `soul-mirror-pull` | Keep producer completion/freshness semantics in Vigil; no backup-service changes |
| `channel` | Keep actual Telegram delivery evidence in Vigil |
| `choir-tick`, `rpi5-tick` | Keep peer timestamp validation in Vigil |
| `choir-host`, `rpi5-host`, `membrana` | Audit overlap with native network probes; retain existing checks until an explicit ownership decision |
| `ha-alive`, `ha-served`, `galeria` | Candidates for complementary native functional HTTP checks; no automatic removal or alert migration |
| Private Home Assistant conditions | Deferred until securely supplied by the owner; never exposed as Gatus detail rows |
| Three-valued verdicts, acknowledgement, durable notification queue, recovery hold-down | Remain in Vigil |

A native HTTP probe from the Pi and a local probe on choir observe different
failure paths. Do not label them duplicates solely because they name the same
service. Gatus itself runs on the Pi: local green checks do not prove external
reachability, and the Pi cannot report its own complete outage through Gatus.
Retain peer monitoring and explicitly inventory coverage of Gatus service failure.

## Phase 1: evidence and coverage audit

Deliver a coverage table before adding checks. For every service record its user
entrypoint, observer host, current assertion, interval, timeout, response-time
meaning, notification owner, and a concrete failure it would miss. Include both
hosts' HTTPS/Tailscale paths and distinguish application failure from DNS,
network, authentication, and dependency failures.

Inspect public source/routes and use bounded, read-only requests. Record status,
content type, and allowlisted schema facts; do not save response bodies, tokens,
private content, or Home Assistant entity names. Verify actual gallery routes:
the earlier “API -> item -> image” example is a candidate, not a confirmed API.
Its server is outside this repository, so inspect the deployed route contract
without copying private gallery content into this plan.

Check the installed binary's support for the specific features chosen. Current
upstream documentation is not proof that the pinned release implements a field.
Do not add a package upgrade unless a selected capability requires one; review
and validate any upgrade separately.

Acceptance: each proposed check has a user-visible failure it detects, a verified
route and assertion, a privacy classification, and one notification owner. Publish
omissions as unknowns rather than inventing health endpoints or sample content.

## Phase 2: strengthen native checks first

Make one small PR for verified assertions and user-facing transport coverage:

- Keep existing endpoint names/groups stable to preserve history. Describe the
  limited coverage of UI-only Anki and NixFrame checks clearly.
- Add stable body/schema conditions where a 200 response could still be an error
  page, login page, or broken API. Use only public, non-sensitive values that may
  safely appear in failed-condition detail.
- Check selected real HTTPS entrypoints, including TLS validity/expiry where
  supported. Choose renewal headroom from the actual certificate lifecycle;
  do not use arbitrary deadlines or domain-expiry checks for provider-owned names.
- Measure direct service latency over at least 24 hours, including normal jobs,
  before proposing new latency thresholds. Preserve the existing OpenRouter
  threshold unless evidence justifies a separately reviewed change.
- Add DNS or remote-path probes only for a documented blind spot. Prefer a probe
  from the other host when local observation cannot detect the failure.

Keep new coverage dashboard-only initially. No duplicate Telegram alerts, new
private conditions, state-changing requests, or model-inference charges.
Extend the Nix wrapper only for fields actually used by the selected checks.

Acceptance: fixtures distinguish valid responses from misleading 200s; evaluated
config preserves old endpoint identities; no sensitive resolved values reach
Gatus history; direct latency is visibly distinct from Vigil snapshot latency.

## Phase 3: one read-only functional suite

Pilot gallery as the first candidate because checking content delivery can reveal
failures that a listening HTTP server cannot. First verify a stable public route
and safe representative asset. Where supported by the real API, read metadata,
extract a public identifier, then retrieve the referenced resource and assert
its status/content contract. If there is no suitable API, choose a stable public
page-to-asset path or document the blocker; do not fabricate fixtures in production.

Start with a proposed five-minute interval and bounded per-request/whole-suite
timeouts, calibrated to measured behavior. No uploads, deletes, workflow triggers,
private object identifiers, generated content, or paid calls. Empty legitimate
content must have an agreed meaning before adding a non-empty assertion.

Use shared context only when the next step genuinely depends on the previous
response. Keep unrelated checks independent. Test step-failure/skip behavior and
any required always-run behavior with the pinned binary. Suites are documented
as alpha; validate their UI, history, reload, and restart behavior in isolation.

Acceptance: a fixture with a healthy entrypoint but broken referenced resource
fails at the correct step. Healthy fixtures pass. The deployed read-only pilot
runs for 48 hours without unexpected traffic, sensitive history, or duplicate
notifications. No live service interruption is needed for this acceptance.

## Phase 4: review ownership and simplify only with evidence

Review baseline coverage after the pilot. Keep useful native Gatus checks and
Vigil's operational checks. For each apparent overlap, compare observer location,
failure cases, cadence, unknown-state treatment, alert thresholds, recovery,
acknowledgement, and outages of the monitoring process itself.

Do not migrate a Vigil contract merely because Gatus can send the same request.
Removing one also changes contract counts, peer evidence, and incident behavior.
Any removal or notification reassignment needs an explicit proposal and owner
approval. Retain existing incident state/history and never reset it to make a
migration appear healthy. If semantic parity is not needed or not achievable,
keep both observations with clear descriptions and one incident owner.

After 48 hours of pilot evidence, choose whether a second suite is worthwhile.
Anki generation, NixFrame upload, and LLM inference need separate decisions about
side effects, test data, cleanup, credentials, and costs. They are not part of
this read-only pilot. Keep private HA conditions deferred.

## Delivery and verification

1. Coverage inventory and chosen candidates: docs PR; no deployment.
2. Native assertion/transport improvements: code PR and only necessary module fields.
3. Gallery read-only suite: separate code PR after verified route and privacy review.
4. Evidence and ownership decision: docs PR; migrations only if separately approved.

For code PRs run relevant module evaluation, formatting, and isolated tests with
the installed Gatus version. Test meaningful failures: misleading 200, missing
field, timeout, broken suite step, stale snapshot, and credential-value exclusion
where applicable. Avoid rerunning unrelated suites without a reason; required CI
must pass before activation.

Before each deployment, build the exact revision in a clean worktree, review unit
changes, preserve owner edits, and request the production switch approval. After
activation verify actual Gatus config/API results, representative dashboard
presentation, service state, fresh Vigil ticks, unchanged incidents, and absence
of additional notifications. Observe at least 24 hours for native changes and
48 hours for the suite. Record evidence rather than marking acceptance from
configuration alone. Roll back a faulty change to the previous generation while
preserving monitoring history and incident state; service interruption requires
approval unless already included in the deployment approval.

## References

- Current config: `hosts/rpi5-full/configuration.nix` and `modules/services/gatus.nix`.
- Existing division of responsibility: [Vigil and Gatus](2026-09-20-vigil-reuse.md).
- [Upstream suites documentation](https://gatus.io/docs/suites).
- [Upstream configuration reference](https://github.com/TwiN/gatus#configuration).

Upstream describes sequential shared-context suites and per-step rather than
suite-level alerts. Treat its feature list as a candidate catalog; installed
5.31.0 behavior must pass the checks above before use.
