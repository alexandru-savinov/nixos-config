# Nemesis: Self-Evolving NixOS Agent

**Status:** Design / Pre-implementation
**Target host:** `rpi5-full`
**Brain:** Claude Code CLI via Claude Pro subscription (no API key billing)

---

## Overview

Nemesis is a closed-loop agent that observes the rpi5 system's runtime state,
proposes NixOS configuration improvements, and applies them safely using
NixOS's native rollback machinery. It is not an experiment — it is an
engineering system built entirely from primitives already running in this repo.

**Core safety property:** NixOS generations are immutable, content-addressed
store paths. `nixos-rebuild test` activates a generation without making it the
default boot entry. A reboot or explicit rollback always restores the previous
state. Nemesis exploits this as its primary safety primitive: nothing is
permanent until a 10-minute verification window passes without incident.

**Why Claude Code as brain:** `claude -p` already runs via OpenClaw. Using the
Pro subscription (via `claude auth login`) instead of an API key means no
per-token billing, natural rate limiting, and full CC tool execution — CC
can `Read`, `Glob`, `Grep`, and `nix eval` the repo before writing its
proposed overlay, without a custom tool-calling harness.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                          NEMESIS                                    │
│                                                                     │
│  TRIGGER LAYER                                                      │
│  ┌────────────────────────────────────────────────────────────┐     │
│  │  nemesis-collector (2m timer)                              │     │
│  │    PSI · cgroups · Gatus REST · journald → SQLite          │     │
│  │                                                            │     │
│  │  CUSUM watchdog (continuous)                               │     │
│  │    fires only on confirmed regime shift, not noise spikes  │     │
│  │                                                            │     │
│  │  anomaly watcher (continuous)                              │     │
│  │    fires immediately on OOM event or Gatus failure         │     │
│  └───────────────────────────┬────────────────────────────────┘     │
│                              │                                      │
│  PLANNING LAYER              │                                      │
│  ┌───────────────────────────▼────────────────────────────────┐     │
│  │  Task File Generator                                       │     │
│  │    SystemSnapshot + Qdrant RAG (top-5 past outcomes)       │     │
│  │    + current option values (nix eval) + constraints        │     │
│  │    → /var/lib/nemesis/tasks/<id>.md                        │     │
│  │                                                            │     │
│  │  Claude Code CLI (Pro subscription)                        │     │
│  │    claude -p <task> --allowedTools "Read,Glob,Grep,        │     │
│  │      Bash(nix eval *),Write" --max-turns 20                │     │
│  │    CC reads repo, reasons, writes overlay + proposal JSON  │     │
│  │    cannot run nixos-rebuild, git, curl, or ssh             │     │
│  └───────────────────────────┬────────────────────────────────┘     │
│                              │                                      │
│  VERIFICATION + ACTIVATION LAYER                                    │
│  ┌───────────────────────────▼────────────────────────────────┐     │
│  │  Actuator (deterministic shell script — no LLM)            │     │
│  │                                                            │     │
│  │  Gate 1: nix eval type-check proposed option values  10ms  │     │
│  │  Gate 2: nix --parse <overlay file>                  50ms  │     │
│  │  Gate 3: nix flake check                             ~10s  │     │
│  │  Gate 4: nixos-rebuild build (no activation)        ~5min  │     │
│  │  Gate 5: property test suite on COM snapshot          ~5s  │     │
│  │  Gate 6: change auditor verdict (auto/super/blocked)  ~1s  │     │
│  │                                                            │     │
│  │  nixos-rebuild test → 10min weighted verification window   │     │
│  │    (+1 per passing check, −3 per failure)                  │     │
│  │  pass → nixos-rebuild switch + push overlay as PR          │     │
│  │  fail → tripwire rolls back; lessons embedded in Qdrant    │     │
│  └─────────────────────────────────────────────────────────────┘    │
│                                                                     │
│  SAFETY LAYER (separate systemd unit — Nemesis cannot touch it)    │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  nemesis-tripwire (continuous, PartOf nothing)              │    │
│  │    polls every 10s: SSH · Tailscale · PSI full stall       │    │
│  │    on violation → nixos-rebuild switch --rollback           │    │
│  └─────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Key Design Decisions

### Overlay modules (not text patches)

All agent-generated changes live in `hosts/rpi5-full/agent-overlays/`. The
agent writes a new `.nix` file; the actuator adds its import to
`hosts/rpi5-full/configuration.nix`. Reverting a change means removing one
file and one import line — the original modules are **never modified**.

This is architecturally stronger than any git rollback: the known-good state
is structurally preserved, not reconstructed.

```
hosts/rpi5-full/
  configuration.nix         ← human-authored, never touched by Nemesis
  agent-overlays/
    .gitkeep
    20260221-143000-n8n-memory.nix     ← Nemesis writes here only
    20260221-180000-open-webui-cpu.nix
```

Example overlay:
```nix
# hosts/rpi5-full/agent-overlays/20260221-143000-n8n-memory.nix
# Nemesis overlay — goal: reduce n8n OOM kills
# Hypothesis: MemoryMax too low for actual n8n worker heap usage
{ ... }:
{
  systemd.services.n8n.serviceConfig.MemoryMax = "2048M";   # was 1536M
  systemd.services.n8n.serviceConfig.MemoryHigh = "1536M";  # was 1G
}
```

### CC as brain, actuator as hands

CC is given:
- `Read`, `Glob`, `Grep` — full repo read access
- `Bash(nix eval *)` — inspect current option values
- `Write` restricted to `hosts/rpi5-full/agent-overlays/` and
  `/var/lib/nemesis/proposals/`

CC is **not** given: `Edit`, `Bash(nixos-rebuild *)`, `Bash(git *)`,
`Bash(curl *)`, `Bash(ssh *)`. All deployment operations are performed by the
actuator shell script, which is auditable and deterministic.

### CUSUM trigger (not a fixed schedule)

The planner does not run on a fixed interval. The CUSUM (Cumulative Sum)
change-point detector runs continuously against the SQLite metrics DB. It
emits a `REGIME_CHANGE` event only when a metric has demonstrably shifted
to a new mean — not on momentary spikes.

```
S_t = max(0, S_{t-1} + (x_t − μ₀ − k))
Fire when S_t > h (threshold)
```

This prevents thrashing: CC is invoked when the system actually needs
attention, not on a timer. Scheduled fallback: if no regime change fires in
72 hours, run a routine health-check cycle anyway.

### Separate tripwire

`nemesis-tripwire.service` is a separate systemd unit with no `PartOf`,
`BoundBy`, or `WantedBy` links to the main Nemesis service. It cannot be
stopped by the Nemesis user, has a 32M memory limit, and always restarts.
It polls SSH reachability, Tailscale status, and PSI full stall every 10
seconds. On violation during a test window, it calls `nixos-rebuild switch
--rollback` directly.

### Pro subscription auth

Nemesis invokes `claude` CLI authenticated via `claude auth login` (OAuth with
the Claude.ai account), not an `ANTHROPIC_API_KEY`. This uses Pro allocation,
not API billing. The existing `openclaw` nftables rules are extended to allow
the Nemesis user to reach the same endpoints (`api.anthropic.com`,
`api.github.com`). Rate limits from Pro naturally cap the number of planning
cycles per day.

---

## Change Scope

### Tier 1 — Autonomous (no human approval, full pipeline)

| Option | Bounds |
|--------|--------|
| `systemd.services.<svc>.serviceConfig.MemoryMax` | ±20% of current, min 128M, max 3G |
| `systemd.services.<svc>.serviceConfig.MemoryHigh` | ±20%, must be ≤ MemoryMax |
| `systemd.services.<svc>.serviceConfig.CPUQuota` | ±25%, min 10%, max 400% |
| `systemd.services.<svc>.serviceConfig.Nice` | ±3, range −20..19 |
| `services.earlyoom.freeMemThreshold` | ±5 percentage points |
| `nix.settings.max-jobs` / `nix.settings.cores` | ±1 |

Services in scope: `n8n`, `open-webui`, `qdrant`, `gatus`, `earlyoom`.

### Tier 2 — Supervised (approval token required before `nixos-rebuild switch`)

- Service-specific options beyond resource limits
  (e.g., `services.n8n-tailscale.concurrencyLimit`)
- `boot.kernel.sysctl` memory/networking parameters
- Adding a new service that has a complete module already written
  (e.g., enabling an existing module in `modules/services/`)

### Tier 3 — Human PR only (Nemesis creates draft PR, does not apply)

- Any change to `modules/services/nemesis*.nix` (own config)
- `networking.nftables.*` or `security.sudo.*`
- `flake.nix` or `flake.lock`
- `secrets/` or any `age.secrets.*` reference
- `.github/workflows/`
- SSH authorized keys, user definitions

The Tier 3 boundary is enforced by the **change auditor** — an immutable
Python script packaged as a Nix derivation. The Nemesis user cannot modify
it; it lives in `/nix/store`.

---

## New Files and Modules

```
modules/services/
  nemesis.nix                  ← Main NixOS module (options + systemd units)
  nemesis-collector.nix        ← Observer: collects metrics to SQLite
  nemesis-actuator.nix         ← Actuator: five-gate pipeline + switch/rollback

modules/services/nemesis/
  change-auditor.py            ← Immutable auditor (packaged as derivation)
  property-tests.py            ← Property suite run against COM snapshot
  task-template.md             ← Task file template injected with snapshot
  system-prompt.txt            ← CC system prompt (in Nix store, immutable)

hosts/rpi5-full/
  configuration.nix            ← Add nemesis module import + enable option
  agent-overlays/
    .gitkeep

docs/
  nemesis-plan.md              ← This file
```

### `modules/services/nemesis.nix` — key options

```nix
options.services.nemesis = {
  enable = mkEnableOption "Nemesis self-evolving NixOS agent";

  flakeTarget = mkOption {
    type    = types.str;
    default = "rpi5-full";
  };

  planningIntervalHours = mkOption {
    type    = types.int;
    default = 72;
    description = "Fallback scheduled cycle if CUSUM never fires.";
  };

  verificationWindowSeconds = mkOption {
    type    = types.int;
    default = 600;
    description = "How long to run after nixos-rebuild test before committing.";
  };

  qdrantUrl = mkOption {
    type    = types.str;
    default = "http://127.0.0.1:6333";
  };

  tier1.services = mkOption {
    type    = types.listOf types.str;
    default = [ "n8n" "open-webui" "qdrant" "gatus" ];
    description = "Services Nemesis may adjust autonomously.";
  };

  tier1.maxMemoryChangePct = mkOption {
    type    = types.int;
    default = 20;
  };

  tier1.maxCpuChangePct = mkOption {
    type    = types.int;
    default = 25;
  };

  notifications.n8nWebhookUrl = mkOption {
    type    = types.nullOr types.str;
    default = null;
    description = "n8n webhook for circuit breaker alerts and tier-2 approval requests.";
  };

  limits.maxSwitchesPerDay = mkOption {
    type    = types.int;
    default = 3;
  };

  limits.maxConsecutiveFailures = mkOption {
    type    = types.int;
    default = 3;
    description = "Trip circuit breaker after this many consecutive rollbacks.";
  };
};
```

---

## Systemd Units

| Unit | Type | Purpose |
|------|------|---------|
| `nemesis-schema-init.service` | oneshot/boot | Apply SQLite schema to `/var/lib/nemesis/metrics.db` |
| `nemesis-collector.service` | oneshot | Collect metrics snapshot → SQLite |
| `nemesis-collector.timer` | timer/2m | Drive collector |
| `nemesis-cusum-watchdog.service` | simple | Continuous CUSUM on metrics DB; writes trigger file |
| `nemesis-anomaly-watcher.service` | simple | Tail journald + poll PSI; writes trigger file on OOM/failure |
| `nemesis-planner.service` | oneshot | Build task file, run `claude -p`, produce overlay + proposal |
| `nemesis-planner.path` | path | Watch `/var/lib/nemesis/triggers/` for new trigger files |
| `nemesis-actuator@.service` | oneshot/template | Run five-gate pipeline for one proposal (instance = proposal-id) |
| `nemesis-tripwire.service` | simple | Independently poll safety signals; rollback on violation |
| `nemesis-tripwire-cleanup.timer` | timer/daily | Prune old proposals and episodes |

The actuator is a **templated service** (`nemesis-actuator@<proposal-id>`).
The planner writes a trigger file; the path watcher fires the actuator
instance. Only one actuator runs at a time (the planner checks for active
instances before writing a trigger).

---

## Data Stores

### SQLite: `/var/lib/nemesis/metrics.db`

```sql
CREATE TABLE observations (
  id           INTEGER PRIMARY KEY,
  collected_at DATETIME NOT NULL,
  generation   INTEGER NOT NULL,
  data         JSON NOT NULL        -- full SystemSnapshot
);

CREATE TABLE service_metrics (
  id             INTEGER PRIMARY KEY,
  observation_id INTEGER REFERENCES observations(id),
  service        TEXT NOT NULL,
  memory_bytes   INTEGER,
  cpu_usage_ns   INTEGER,
  psi_mem_some   REAL,
  healthy        BOOLEAN,
  latency_ms     INTEGER
);

CREATE TABLE anomalies (
  id             INTEGER PRIMARY KEY,
  detected_at    DATETIME NOT NULL,
  observation_id INTEGER REFERENCES observations(id),
  service        TEXT,
  anomaly_type   TEXT,  -- 'oom', 'error_log', 'health_fail', 'psi_spike'
  message        TEXT,
  resolved       BOOLEAN DEFAULT FALSE
);

CREATE TABLE episodes (
  id               TEXT PRIMARY KEY,   -- proposal-id
  started_at       DATETIME,
  completed_at     DATETIME,
  goal             TEXT,
  overlay_file     TEXT,
  gate_results     JSON,
  activated        BOOLEAN DEFAULT FALSE,
  outcome          TEXT,   -- 'success', 'rollback', 'rejected'
  rollback_reason  TEXT,
  generation_from  INTEGER,
  generation_to    INTEGER,
  psi_before       REAL,
  psi_after        REAL
);
```

### Qdrant: collection `nemesis-outcomes`

Each document:
```json
{
  "content": "Raised n8n MemoryMax 1536M→2048M. OOM kills dropped from 2/day to 0. PSI avg60 went from 1.95 to 0.43 within 30 minutes of activation.",
  "metadata": {
    "service": "n8n",
    "option": "systemd.services.n8n.serviceConfig.MemoryMax",
    "old_value": "1536M",
    "new_value": "2048M",
    "outcome": "success",
    "generation_from": 250,
    "generation_to": 251,
    "timestamp": "2026-02-21T18:00:00Z"
  }
}
```

Retrieval at planning time: embed the current `SystemSnapshot` summary,
query top-5 by cosine similarity. Results are injected into the task file.

Embedding model: `nomic-embed-text` via the local Ollama/Open-WebUI endpoint
already running at `http://127.0.0.1:8080`. No external embedding API needed.

---

## Task File Structure (what CC reads)

```markdown
# Nemesis Planning Cycle — <timestamp>

## Your Role
You are the reasoning engine for a self-evolving NixOS agent running on a
Raspberry Pi 5 (aarch64-linux, 4GB RAM). Analyze the system state, identify
the highest-impact safe change, and write ONE overlay module.

## Constraints (strictly enforced by the actuator — violations are rejected)
- Write to `hosts/rpi5-full/agent-overlays/<id>.nix` ONLY.
  Touch no other files.
- Propose exactly one option change per overlay.
- Tier 1 options only:
    MemoryMax/MemoryHigh ±20% · CPUQuota ±25% · Nice ±3
    earlyoom.freeMemThreshold ±5pp · nix.settings.max-jobs ±1
- Services in scope: n8n, open-webui, qdrant, gatus
- If no safe change exists, write `agent-overlays/no-action-<id>.txt`
  with a one-sentence reason.

## Required Outputs
1. The overlay .nix file (use Write tool)
2. `/var/lib/nemesis/proposals/<id>.json` (use Write tool):
   {
     "hypothesis": "...",
     "overlay_file": "...",
     "target_service": "...",
     "target_option": "...",
     "old_value": "...",
     "new_value": "...",
     "rationale": "...",
     "verification_checks": [
       {"type": "health_check", "service": "...", "timeout_seconds": 120},
       {"type": "metric_threshold", "metric": "psi_some_avg60",
        "operator": "<", "value": 0.10}
     ],
     "expected_outcome": "..."
   }

## System State
<snapshot>
[SystemSnapshot JSON — last 1h averages]
</snapshot>

## Relevant Past Outcomes
<past_outcomes>
[Top-5 Qdrant results for current symptom pattern]
</past_outcomes>

## Current Configuration (relevant options)
<current_config>
[nix eval output for in-scope services]
</current_config>
```

---

## The Actuator Pipeline

The actuator (`nemesis-apply`) is a ~200-line shell script. No LLM. Every
step is logged. All gates must pass in order; any failure aborts and rolls back.

```
Step 1  Validate proposal JSON schema
Step 2  Check overlay file exists and is in agent-overlays/
Step 3  Gate 1: nix eval type-check — verify proposed values are valid types
Step 4  Gate 2: nix --parse <overlay> — syntactic validity
Step 5  Gate 3: nix flake check — evaluation correctness
Step 6  Gate 4: nixos-rebuild build — derivation can be built
Step 7  Gate 5: property test suite against COM snapshot
Step 8  Gate 6: change-auditor verdict — autonomous / supervised / blocked
Step 9  Pre-flight: disk ≥ 5GB free · ≥ 3 generations exist · services healthy
Step 10 git commit overlay (local branch nemesis/<proposal-id>)
Step 11 nixos-rebuild test (activates, does NOT set boot default)
Step 12 Verification window: 10 minutes
          every 30s: run verification_checks from proposal JSON
          scoring: +1 pass, −3 fail
          abort if score drops below floor OR tripwire fires
Step 13 score passes → nixos-rebuild switch (permanent)
                     → git push → gh pr create (labeled nemesis)
                     → embed SUCCESS in Qdrant
Step 14 score fails  → nixos-rebuild switch --rollback
                     → embed ROLLBACK + lessons-learned in Qdrant
                     → notify via n8n webhook
```

### Property Test Suite (Gate 5)

A Python script run against the COM snapshot (output of `nix eval --json`).
Predicates that must hold on every proposed configuration:

```python
def test_no_port_conflicts(com):
    """No two services bind the same port."""

def test_all_services_bind_localhost(com):
    """No service binds 0.0.0.0 (security invariant)."""

def test_memory_limits_sum_within_budget(com):
    """Sum of MemoryMax across all services < 3.5GB (4GB RPi5 minus headroom)."""

def test_memhigh_lte_memmax(com):
    """MemoryHigh <= MemoryMax for every service (avoid systemd inconsistency)."""

def test_cpuquota_not_zero(com):
    """No service has CPUQuota = 0% (would starve the service)."""

def test_required_services_enabled(com):
    """tailscaled, sshd, and nemesis itself are always enabled."""

def test_nemesis_config_unchanged(com):
    """services.nemesis.* options are identical to the baseline snapshot."""
```

The suite grows over time. When a rollback occurs and a human identifies the
root cause, a new predicate can be added that would have caught it — this is
cheap to add and makes the property suite a living document of institutional
knowledge.

### Change Auditor (Gate 6)

Packaged as a Nix derivation; the Nemesis user cannot modify it.

```python
#!/usr/bin/env python3
# modules/services/nemesis/change-auditor.py
#
# Input:  git diff between main and the proposed branch (via stdin or args)
# Output: JSON { "verdict": "autonomous|supervised|blocked", "findings": [...] }
# Exit:   0=autonomous, 1=supervised, 2=blocked

BLOCKED = [
    r"\.github/workflows/",
    r"authorized_keys",
    r"users\.users\.root",
    r"networking\.firewall\.enable\s*=\s*false",
]

SUPERVISED = [
    r"modules/services/nemesis",   # own config
    r"secrets/secrets\.nix",
    r"age\.secrets\.",
    r"security\.sudo",
    r"networking\.nftables",
    r"allowedTools",
    r"allowedBuildTargets",
    r"boot\.(kernelPackages|initrd|kernelModules)",
    r"fileSystems\.",
]
```

---

## Circuit Breaker

If 3 consecutive proposals result in rollback:
1. Nemesis enters `paused` state (writes `/var/lib/nemesis/circuit-open`)
2. Notifies via n8n webhook
3. Stops writing trigger files (no new planning cycles)
4. Human resets by: `rm /var/lib/nemesis/circuit-open`

If 5 consecutive planning cycles produce `no-action`:
1. Nemesis drops to 1 cycle / 72h fallback schedule
2. Logs the no-action reason for each cycle
3. Resumes normal CUSUM-triggered cadence once a regime change fires

---

## Memory and Learning

### Retrieval-Augmented Planning

Past outcomes are stored in Qdrant (`nemesis-outcomes` collection) and
retrieved by semantic similarity at planning time. The embedding query is the
current `SystemSnapshot` formatted as prose — surfacing outcomes that match
the symptom pattern, not just the service name.

### Semantic Rollback Analysis

When the actuator detects a rollback (new generation < expected), it:
1. Reads the verification failure details from the episode record
2. Calls `claude -p <analysis-prompt>` (one-shot, no tools needed) to produce
   a structured `lessons-learned` paragraph
3. Embeds the paragraph alongside the failure record in Qdrant

This ensures the next planning cycle that matches this symptom pattern will
retrieve the failure and its diagnosis — not just the bare fact of failure.

### Episode Journal

`/var/lib/nemesis/metrics.db` `episodes` table stores every proposal attempt
with before/after PSI and a complete gate result log. This provides an audit
trail and enables retrospective analysis of the agent's decision quality.

---

## Integration with Existing Infrastructure

| Component | How Nemesis uses it |
|-----------|---------------------|
| **OpenClaw** | Nemesis reuses the same `claude -p` invocation pattern and `CLAUDE_CONFIG_DIR` isolation. Runs as a separate `nemesis` user to avoid contention with user tasks. |
| **Gatus** | Primary service health signal. Nemesis reads Gatus's SQLite DB at `/var/lib/gatus/data.db` and polls the REST API at `http://127.0.0.1:3001/api/v1/endpoints/statuses`. |
| **Qdrant** | Memory bank. New collection `nemesis-outcomes`. Existing instance at `http://127.0.0.1:6333`. |
| **n8n** | Receives outcome/circuit-breaker notifications. Tier-2 approval requests are n8n webhook calls that return an approval token. |
| **earlyoom** | Nemesis reads earlyoom journal entries as OOM signals. `earlyoom.freeMemThreshold` is in Tier 1 scope. |
| **PSI** | Already enabled (`psi=1` boot param). Nemesis's CUSUM watchdog polls `/proc/pressure/memory` directly. |
| **Open-WebUI / Ollama** | Embedding endpoint for Qdrant document insertion. `nomic-embed-text` via `http://127.0.0.1:8080/api/embeddings`. |

### New Secrets

```nix
# secrets/secrets.nix — add:
"nemesis-github-token.age".publicKeys = allKeys;
# anthropic-api-key already exists (reused via claude auth login,
# OR: Nemesis runs under an account already logged in via OAuth — no secret needed)
```

### Host Configuration

```nix
# hosts/rpi5-full/configuration.nix — add:
imports = [
  # ... existing imports ...
  ../../modules/services/nemesis.nix
  # Auto-generated overlays (empty initially):
  ./agent-overlays  # imports all *.nix in the directory
];

services.nemesis = {
  enable = true;
  flakeTarget = "rpi5-full";
  tier1.services = [ "n8n" "open-webui" "qdrant" "gatus" ];
  qdrantUrl = "http://127.0.0.1:6333";
  notifications.n8nWebhookUrl = "http://127.0.0.1:5678/webhook/nemesis";
  limits.maxSwitchesPerDay = 3;
};
```

### Gatus Monitoring (Nemesis Self-Observability)

```nix
services.gatus-tailscale.endpoints = {
  nemesis-collector = {
    name = "Nemesis Collector";
    group = "nemesis";
    url = "http://127.0.0.1:9095/health";
    interval = "5m";
    conditions = [
      "[STATUS] == 200"
      "[BODY].last_collection_age_seconds < 300"
    ];
  };
};
```

The collector exposes a minimal HTTP health endpoint (10-line Python `http.server`)
reporting: `last_collection_age_seconds`, `anomalies_unresolved`,
`circuit_breaker_open`, `tier1_budget_remaining`.

---

## Implementation Phases

### Phase 0 — Observer Only (Weeks 1–2)

**Goal:** Build observation baseline. No autonomous changes.

1. Create `modules/services/nemesis-collector.nix`
2. Define SQLite schema (observations, service_metrics, anomalies)
3. Implement collector script:
   - Poll `systemctl show` for per-service memory/CPU
   - Read `/proc/pressure/memory` for PSI
   - Poll Gatus REST API for health
   - Scan `journalctl` for OOM and ERROR events
4. Minimal health HTTP endpoint on `127.0.0.1:9095`
5. Add Gatus endpoint for nemesis-collector
6. Deploy and run for 7 days

**Deliverable:** 7 days of observation data. Confirmed PSI/cgroup/Gatus
integration. Baseline statistics for CUSUM μ₀ calibration.

**Validation:**
```bash
sqlite3 /var/lib/nemesis/metrics.db \
  "SELECT service, AVG(memory_bytes/1048576) AS avg_mb, \
          AVG(psi_mem_some) AS avg_psi \
   FROM service_metrics \
   WHERE collected_at > datetime('now', '-7 days') \
   GROUP BY service;"
```

---

### Phase 1 — Planning (Weeks 3–4)

**Goal:** CC produces proposals; human manually reviews and applies or rejects.

1. Create `modules/services/nemesis/task-template.md`
2. Create `modules/services/nemesis/system-prompt.txt`
3. Implement task file generator (shell script):
   - Query SQLite for current SystemSnapshot
   - Retrieve top-5 past outcomes from Qdrant (initially empty)
   - `nix eval` current option values for in-scope services
   - Render task file with all context
4. Implement `nemesis-planner.service` (calls `claude -p`)
5. Wire CC `allowedTools`: `Read,Glob,Grep,Bash(nix eval *),Write`
6. Write overlay path restriction: validate in actuator before writing
7. Implement `nemesis-planner.timer` (72h fallback only, no CUSUM yet)
8. Proposals written to `/var/lib/nemesis/proposals/<id>.json`
9. Human reviews each proposal JSON and applies manually if desired

**Deliverable:** 5 proposals reviewed. Quality assessment. Prompt refinement.

**Validation:** Run `claude -p <task-file>` manually, inspect output, verify
CC reads the correct files and writes a syntactically valid overlay.

---

### Phase 2 — Actuator + Manual Approval (Weeks 5–6)

**Goal:** Full pipeline runs end-to-end. Human approves each `nixos-rebuild switch`.

1. Implement `modules/services/nemesis/change-auditor.py` (packaged as derivation)
2. Implement `modules/services/nemesis/property-tests.py`
3. Implement `nemesis-actuator` shell script (all 14 steps)
4. Implement approval token mechanism:
   - Actuator pauses after Gate 6 if verdict is `supervised`
   - Writes approval request to `/var/lib/nemesis/pending-approval/<id>.json`
   - n8n webhook notifies human
   - Human writes token: `echo "approve" > /run/nemesis/approvals/<gen-hash>`
   - Actuator polls for token before `nixos-rebuild switch`
5. **Deliberately test rollback:** Propose a change known to fail Gate 5 or
   the verification window. Verify rollback restores the previous generation.
6. Implement Qdrant embedding pipeline for outcomes

**Deliverable:** 3 proposals applied and verified (or rolled back) through
the full actuator pipeline. Rollback path confirmed to work.

**Validation:**
```bash
# After a forced-fail test:
nix-env --list-generations -p /nix/var/nix/profiles/system | tail -3
# Should show rollback to the pre-test generation
```

---

### Phase 3 — CUSUM + Tripwire (Weeks 7–8)

**Goal:** Event-driven triggering; independent safety monitor.

1. Implement `nemesis-cusum-watchdog.service`:
   - Reads `service_metrics` from SQLite
   - Runs CUSUM on PSI `some_avg60` and per-service `memory_bytes`
   - Writes `/var/lib/nemesis/triggers/<id>-regime-change.trigger` on detection
2. Implement `nemesis-anomaly-watcher.service`:
   - Tail `journalctl --follow --output json` for OOM and ERROR entries
   - Poll Gatus REST API every 60s for health failures
   - Write `/var/lib/nemesis/triggers/<id>-anomaly.trigger` immediately
3. Implement `nemesis-planner.path` watcher on `triggers/` directory
4. Implement `nemesis-tripwire.service`:
   - Poll every 10s: `ssh localhost true`, `tailscale status`, PSI full stall
   - On violation during active test window: `nixos-rebuild switch --rollback`
   - Log rollback reason to `/var/log/nemesis/tripwire.log`
5. Drop the 72h fallback timer to 48h now that event-driven triggering works

**Deliverable:** Agent triggers autonomously on a PSI spike or OOM event.
Tripwire tested by intentionally causing a service failure during a test window.

---

### Phase 4 — Tier 1 Autonomy (Weeks 9–10)

**Goal:** Tier 1 resource changes applied fully autonomously.

1. Remove human approval requirement for Tier 1 changes (auditor verdict = `autonomous`)
2. Enable `limits.maxSwitchesPerDay = 3`
3. Implement circuit breaker (consecutive failure counter in SQLite)
4. Tune CUSUM thresholds based on 8 weeks of baseline data
5. Tune property test memory budget predicate with actual observed totals
6. Deploy and monitor for one week

**Deliverable:** First week of fully autonomous Tier 1 operation.
Outcome journal shows ≥ 80% success rate (no rollback).

**Acceptance criteria:**
- Three autonomous switches in first week, all with PSI improvement confirmed
- No rollback triggered unexpectedly
- Tripwire has not fired spuriously
- Circuit breaker not tripped

---

### Phase 5 — Learning Quality Validation (Weeks 11–12)

**Goal:** Confirm RAG context improves proposal quality.

1. Run 5 planning cycles with Qdrant retrieval **disabled** (A/B test)
2. Run 5 planning cycles with retrieval **enabled**
3. Compare: proposal relevance, gate failure rate, verification pass rate
4. Implement semantic rollback analysis:
   - When rollback detected, call `claude -p <analysis-prompt>` for lessons-learned
   - Embed in Qdrant alongside failure record
5. Review property test suite: add predicates from any rollback incidents

**Deliverable:** Documented evidence that RAG context improves gate-pass rate.

---

### Phase 6 — Tier 2 Expansion (Week 13+)

**Goal:** Expand change vocabulary to service-specific options.

1. Implement n8n approval workflow:
   - Nemesis sends proposal JSON to n8n webhook
   - n8n renders a review UI (or notification with approve/reject buttons)
   - Approval response writes token file
2. Add Tier 2 options to change vocabulary:
   - `services.n8n-tailscale.concurrencyLimit`
   - `boot.kernel.sysctl` memory management parameters
3. Implement `expected_outcome` verification:
   - Proposal states "CPU usage of open-webui will drop by ≥ 15%"
   - Actuator verifies this within the 10-minute window
   - Mismatch → log but do not roll back (expectation error ≠ system failure)

---

## Security Posture

### The Nemesis User

```nix
users.users.nemesis = {
  isSystemUser = true;
  uid = 992;   # static, referenced in nftables
  group = "nemesis";
  home = "/var/lib/nemesis";
  description = "Nemesis self-evolving agent";
};
```

### Sudo Restrictions

Nemesis gets a wrapper (`nemesis-sudo`) analogous to `openclaw-sudo`:
- `test <target>` — `nixos-rebuild test` only
- `switch <target>` — `nixos-rebuild switch` only (requires approval token for Tier 2)
- `switch --rollback` — always allowed
- `build <target>` — `nixos-rebuild build` only
- All other commands: rejected with logged error

### Network Restrictions

Nemesis user gets the same nftables UID-based restriction as OpenClaw:
- `api.anthropic.com` (CC login refresh + any API fallback)
- `api.github.com` + `github.com` (PR creation)
- Loopback + Tailscale interface (Gatus, Qdrant, n8n, Ollama/Open-WebUI)
- All other outbound: dropped and logged

### CC `allowedTools` Whitelist

```
Read
Glob
Grep
Bash(nix eval *)
Write
```

`Edit`, `Bash(nixos-rebuild *)`, `Bash(git *)`, `Bash(curl *)`,
`Bash(ssh *)`, `Bash(systemctl *)` are NOT in the whitelist.
CC cannot deploy, commit, or reach the network.

### What Nemesis Cannot Change About Itself

`modules/services/nemesis.nix` is Tier 3. The change auditor matches
`modules/services/nemesis` in the `SUPERVISED` → actually `BLOCKED` list if
it touches the auditor itself. Any proposal touching Nemesis's own config
produces a draft PR only; a human must merge it.

---

## Open Questions for Implementation

1. **Pro subscription OAuth flow in headless systemd context:** `claude auth
   login` requires an interactive browser step. Confirm whether the existing
   OpenClaw OAuth session can be shared (same `CLAUDE_CONFIG_DIR`) or whether
   Nemesis needs its own `~/.claude` directory with a pre-authorized session.
   _Likely answer:_ Share `CLAUDE_CONFIG_DIR=/var/lib/openclaw/.claude` if
   running as the same user, or do a one-time `claude auth login` for the
   `nemesis` user during provisioning.

2. **`nomic-embed-text` availability:** Open-WebUI's Ollama backend must have
   this model pulled (`ollama pull nomic-embed-text`). Add to the
   Open-WebUI module's startup or document as a manual step.

3. **`agent-overlays/` import:** NixOS does not natively support `imports =
   [ ./agent-overlays ]` (directory import). Options: (a) use `lib.filesystem.
   listFilesRecursive` to collect all `.nix` files and import them; (b)
   generate a `default.nix` in the directory that imports all siblings;
   (c) have the actuator update `agent-overlays/default.nix` on each new
   overlay. Option (c) is simplest and safest.

4. **CUSUM μ₀ calibration:** Initial values for μ₀ (baseline mean) and k
   (allowable slack) must come from Phase 0 observation data. Implement a
   one-time calibration script that computes μ₀ ± 2σ from the first week
   of PSI/memory data.

5. **`nixos-rebuild test` and Tailscale Serve:** Does `nixos-rebuild test`
   restart Tailscale Serve configuration? If so, the verification window may
   briefly show Gatus failures for unrelated reasons. Instrument the
   verification window to distinguish "services restarting" (expected, within
   first 60s) from "services failing" (unexpected, after 60s).

---

## Success Criteria

The implementation is complete when:

- [ ] Phase 0: 7 days of continuous metrics collected, no data gaps > 5 minutes
- [ ] Phase 1: CC produces valid overlay files in ≥ 4 out of 5 planning cycles
- [ ] Phase 2: Rollback path validated; actuator recovers to known-good generation
- [ ] Phase 3: CUSUM fires on a deliberate PSI spike within 3 minutes
- [ ] Phase 4: 3 autonomous Tier 1 switches with confirmed metric improvement
- [ ] Phase 5: RAG retrieval demonstrably changes (improves) proposal selection
- [ ] Phase 6: One Tier 2 change applied via n8n approval workflow

---

## References

- Research proposals: synthesized from 4 independent agent analyses
  (see conversation history, 2026-02-21)
- Key primitives: `nixos-rebuild test` (NixOS manual §5.3), Qdrant REST API,
  CUSUM algorithm (Page 1954), UCB1 (Auer et al. 2002)
- Prior art in this repo: `modules/services/openclaw.nix` (task runner
  pattern), `modules/services/gatus.nix` (health monitoring),
  `modules/services/qdrant.nix` (vector DB)
