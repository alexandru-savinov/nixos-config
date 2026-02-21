# Nemesis: Self-Evolving NixOS Agent

**Status:** Design / Pre-implementation
**Controller host:** `rpi5-full` (aarch64-linux, Raspberry Pi 5)
**Target host:** `sancta-choir` (x86_64-linux, Hetzner VPS)
**Brain:** Claude Code CLI via Claude Pro subscription (no API key billing)

---

## Overview

Nemesis is a closed-loop agent that runs on the Raspberry Pi 5 and manages
the `sancta-choir` Hetzner VPS. rpi5 is the **controller and watcher**: it
observes sancta-choir from the outside (via Tailscale SSH and Gatus health
checks), reasons about what to change, and deploys configuration updates
remotely. sancta-choir is the **target**: it never executes agent logic
itself — it only receives and activates changes triggered from rpi5.

This separation gives rpi5 an external vantage point that self-monitoring
cannot provide. If sancta-choir is truly broken, its own processes may be
unable to observe or recover the damage; rpi5 can see this from outside
and act.

**Why rpi5 as controller:** rpi5 has permanent Tailscale connectivity to
sancta-choir, already runs Gatus monitoring of sancta-choir's services,
holds the nixos-config git clone, and has Claude Code CLI installed.
Nemesis builds on this existing infrastructure — adding a dedicated
`nemesis` user, `claude -p` task runner, and SSH-based metric collection
— rather than installing a new agent on Hetzner.

**Core safety property:** NixOS generations are immutable, content-addressed
store paths. `nixos-rebuild test` on sancta-choir activates a generation
without making it the default boot entry — a reboot or explicit rollback
returns to the previous state. Nemesis exploits this as its primary safety
primitive: nothing on sancta-choir is permanent until rpi5's 10-minute
external verification window passes without incident.

**Why Claude Code as brain:** rpi5 already has the Claude Code CLI installed.
Nemesis invokes `claude -p` under a dedicated `nemesis` user with Pro/Max
subscription auth via `CLAUDE_CODE_OAUTH_TOKEN` (provisioned through
agenix) — no per-token billing, natural rate limiting, and full CC tool
execution. CC reads the repo, inspects the
target's current options, and writes an overlay — without a custom
tool-calling harness. The invocation pattern is modeled on the existing
OpenClaw task runner (`modules/services/openclaw.nix`).

---

## Prerequisites

The following must be completed before Nemesis implementation begins:

1. **Deploy OpenClaw on sancta-choir** (Tier 3, human PR) — Enable
   `services.openclaw` on sancta-choir via `modules/services/openclaw.nix`.
   This creates the `openclaw-task-runner.service` systemd unit that Nemesis
   will manage. Currently, sancta-choir only has the Claude Code CLI binary
   installed (no long-running service). The nix-openclaw Home Manager
   integration is disabled due to upstream bugs; use the existing NixOS
   module instead.

2. **Choose and deploy an embedding backend** (Phase 1 dependency) — Ollama
   is not currently deployed on rpi5. Open-WebUI uses OpenRouter, not local
   inference. Options: install Ollama with a small embedding model, use
   OpenRouter's embedding API, or defer RAG to Phase 5.

3. **Provision Nemesis SSH key** (Tier 3, human PR) — Add
   `nemesis-ssh-key.age` to `secrets/secrets.nix` and sancta-choir's
   `authorized_keys`. Required before Phase 2.

4. **Update Gatus sancta-choir endpoints** — Current Gatus config on rpi5
   monitors sancta-choir for Open-WebUI and n8n, which sancta-choir does
   not run. Update to monitor the actual services (OpenClaw, SSH, Tailscale).

---

## Topology

```
┌────────────────────────────────────┐     Tailscale VPN
│  rpi5  (aarch64, 4GB RAM)          │◄──────────────────────►┌──────────────────────────────┐
│  Controller + Watcher              │                         │  sancta-choir  (x86_64)      │
│                                    │                         │  Target                      │
│  ┌──────────────────────────────┐  │  SSH (port 22)         │                              │
│  │  nemesis-collector           │  │──────────────────────►  │  nixos-rebuild (native x86)  │
│  │  (SSHes to sancta-choir      │  │                         │  Overlay modules applied     │
│  │   every 2m for metrics)      │  │                         │  here                        │
│  └──────────────────────────────┘  │                         │                              │
│                                    │  Gatus health probes   │  ┌──────────────────────────┐│
│  ┌──────────────────────────────┐  │──────────────────────►  │  │  openclaw-task-runner    ││
│  │  Gatus (external monitor)    │  │                         │  │  (prerequisite: deploy   ││
│  │  already monitors sancta-    │  │                         │  │   OpenClaw on target)    ││
│  │  choir's HTTP endpoints      │  │                         │  └──────────────────────────┘│
│  └──────────────────────────────┘  │                         │                              │
│                                    │                         └──────────────────────────────┘
│                                    │
│  ┌──────────────────────────────┐  │
│  │  Nemesis brain               │  │
│  │  (CC planning, actuator,     │  │
│  │   tripwire, RAG memory)      │  │
│  └──────────────────────────────┘  │
└────────────────────────────────────┘
```

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                    NEMESIS  (runs entirely on rpi5)                  │
│                                                                      │
│  OBSERVE LAYER                                                       │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  nemesis-collector (2m timer)                               │    │
│  │    SSH → sancta-choir:                                      │    │
│  │      systemctl show --value -p MemoryCurrent <svc>          │    │
│  │      cat /proc/pressure/memory                              │    │
│  │      journalctl --since "2m ago" --output json              │    │
│  │    Local Gatus REST API (http://127.0.0.1:3001) for         │    │
│  │      sancta-choir service health (external vantage)         │    │
│  │    → SQLite /var/lib/nemesis/metrics.db                     │    │
│  │                                                             │    │
│  │  CUSUM watchdog (continuous)                                │    │
│  │    fires only on confirmed regime shift, not noise spikes   │    │
│  │                                                             │    │
│  │  anomaly watcher (continuous)                               │    │
│  │    Gatus failure · SSH-collected OOM event → trigger file   │    │
│  └──────────────────────────┬──────────────────────────────────┘    │
│                             │                                        │
│  PLAN LAYER                 │                                        │
│  ┌──────────────────────────▼──────────────────────────────────┐    │
│  │  Task File Generator                                        │    │
│  │    SystemSnapshot + Qdrant RAG + nix eval + constraints     │    │
│  │    → /var/lib/nemesis/tasks/<id>.md                         │    │
│  │                                                             │    │
│  │  Claude Code CLI (Pro subscription)                         │    │
│  │    claude -p <task> --allowedTools "Read,Glob,Grep,         │    │
│  │      Bash(nix eval *),Write" --max-turns 20                 │    │
│  │    CC reads repo, reasons, writes overlay to               │    │
│  │      hosts/sancta-choir/agent-overlays/                     │    │
│  │    CC cannot run nixos-rebuild, git, ssh, or curl           │    │
│  └──────────────────────────┬──────────────────────────────────┘    │
│                             │                                        │
│  VERIFY + ACTIVATE LAYER    │                                        │
│  ┌──────────────────────────▼──────────────────────────────────┐    │
│  │  Actuator (deterministic shell script — no LLM)             │    │
│  │                                                             │    │
│  │  LOCAL (on rpi5):                                           │    │
│  │    Gate 1: nix eval type-check option values          10ms  │    │
│  │    Gate 2: nix-instantiate --parse <overlay>           50ms  │    │
│  │    Gate 3: nix flake check                            ~10s  │    │
│  │    Gate 5: property test suite on COM snapshot         ~5s  │    │
│  │    Gate 6: change auditor verdict                      ~1s  │    │
│  │    (Gate 4 runs remotely — see below)                       │    │
│  │                                                             │    │
│  │  REMOTE (SSH to sancta-choir):                              │    │
│  │    Gate 4: nixos-rebuild build --flake .#sancta-choir ~5min │    │
│  │    nixos-rebuild test  (activate, not boot-default)         │    │
│  │    10min verification: 20 cycles × 30s                       │    │
│  │      Gatus probe (5s timeout) + SSH probe (10s timeout)     │    │
│  │      pass +1 · fail/timeout −3 · min 15/20 cycles           │    │
│  │    pass → nixos-rebuild switch + git push + PR              │    │
│  │    fail → rollback cascade (SSH→public IP→Hetzner reboot)  │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                                                                      │
│  SAFETY LAYER (separate unit, rpi5 — Nemesis cannot stop it)        │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  nemesis-tripwire  (PartOf nothing, Restart=always)         │    │
│  │    every 10s: SSH probe · tailscale status · Gatus          │    │
│  │    on violation during test window — rollback cascade:       │    │
│  │      1. SSH over Tailscale → nixos-rebuild switch --rollback│    │
│  │      2. SSH over public IP → same                           │    │
│  │      3. Hetzner API reboot (boot-default = last switch)     │    │
│  └─────────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Key Design Decisions

### rpi5 as external watcher — why this is stronger than self-monitoring

When a service on sancta-choir crashes badly enough to make the host
unresponsive, any monitoring process *on* sancta-choir is also broken.
rpi5's Gatus sees the failure from outside via Tailscale and can trigger
Nemesis independently. This is the same reason a production monitoring stack
lives on separate infrastructure from what it monitors.

Concretely: rpi5's Gatus already sends HTTP probes to sancta-choir's
exposed endpoints. Nemesis extends this by also collecting internal metrics
(PSI, cgroup data) via SSH, giving both external and internal perspectives.

### Remote build strategy — no cross-compilation

rpi5 is aarch64 and sancta-choir is x86_64. Cross-compilation is complex
and slow. Instead, the actuator SSHes into sancta-choir and runs
`nixos-rebuild` natively there:

```bash
# Build on sancta-choir (x86_64 native)
ssh root@sancta-choir \
  "cd /var/lib/nemesis/nixos-config && \
   git fetch && git checkout nemesis/<id> && \
   nixos-rebuild build --flake .#sancta-choir"

# Test-activate (not boot default)
ssh root@sancta-choir \
  "nixos-rebuild test --flake /var/lib/nemesis/nixos-config#sancta-choir"

# Permanent switch (after verification passes)
ssh root@sancta-choir \
  "nixos-rebuild switch --flake /var/lib/nemesis/nixos-config#sancta-choir"

# Rollback (if verification fails or tripwire fires)
ssh root@sancta-choir "nixos-rebuild switch --rollback"
```

sancta-choir maintains its own clone of the nixos-config repo at
`/var/lib/nemesis/nixos-config` for this purpose.

### Overlay modules (not text patches)

All agent-generated changes live in `hosts/sancta-choir/agent-overlays/`.
The agent writes a new `.nix` file; the actuator adds its import to
`hosts/sancta-choir/agent-overlays/default.nix`. The original modules are
**never modified**. Reverting a change means removing one file and one
import line — the known-good state is structurally preserved.

```
hosts/sancta-choir/
  configuration.nix              ← human-authored, never touched by Nemesis
  agent-overlays/
    default.nix                  ← actuator manages this (imports list)
    20260221-143000-claude-mem.nix   ← CC writes here only
```

Example overlay:
```nix
# hosts/sancta-choir/agent-overlays/20260221-143000-openclaw-mem.nix
# Nemesis overlay — goal: reduce OpenClaw task runner OOM restarts
# Hypothesis: openclaw-task-runner MemoryMax too low for CC workload
{ ... }:
{
  systemd.services.openclaw-task-runner.serviceConfig.MemoryMax = "2048M";   # was 1536M
  systemd.services.openclaw-task-runner.serviceConfig.MemoryHigh = "1792M";  # was 1280M
}
```

### CC as brain, actuator as hands

CC (on rpi5) is given:
- `Read`, `Glob`, `Grep` — full repo read access
- `Bash(nix eval *)` — inspect current option values
- `Write` restricted to `hosts/sancta-choir/agent-overlays/` and
  `/var/lib/nemesis/proposals/`

CC is **not** given: `Edit`, `Bash(nixos-rebuild *)`, `Bash(git *)`,
`Bash(ssh *)`, `Bash(curl *)`. All remote operations go through the
actuator shell script, which is deterministic and auditable.

### CUSUM trigger (not a fixed schedule)

The planner does not run on a fixed interval. The CUSUM (Cumulative Sum)
change-point detector runs continuously against the SQLite metrics DB,
watching metrics *collected from sancta-choir*. It emits a `REGIME_CHANGE`
event only when a metric has demonstrably shifted to a new mean — not on
momentary spikes.

```
S_t = max(0, S_{t-1} + (x_t − μ₀ − k))
Fire when S_t > h (threshold)
```

Parameters μ₀, k, and h are determined during Phase 0 calibration. k is
typically set to half the expected shift size (in standard deviations); h
is chosen to achieve the desired false-alarm rate (larger h = fewer false
triggers but slower detection). Calibrated values are stored in
`/var/lib/nemesis/cusum-params.json` before enabling Phase 3.

Scheduled fallback: if no regime change fires in 72 hours, run a routine
health-check cycle anyway.

### Exploration Policy

Every 5th planning cycle uses an alternative task template
(`task-template-explore.md`) that instructs CC to propose something outside
its recent pattern — e.g., tuning a metric it has never touched, or
revisiting a previously-rolled-back change with a different approach.

- Counter file: `/var/lib/nemesis/exploration-counter` (incremented by planner)
- Exploration proposals include `"exploration": true` in the proposal JSON
- Exploration cycles get a 15-minute verification window (vs 10 minutes)
  to allow for less predictable behavior to stabilize
- The alternative template omits the `<past_outcomes>` section to reduce
  anchoring bias

### Separate tripwire (rpi5-local, monitors sancta-choir)

`nemesis-tripwire.service` is a separate systemd unit with no `PartOf`,
`BoundBy`, or `WantedBy` links to the main Nemesis service. It cannot be
stopped by the Nemesis user. It polls:
- `ssh root@sancta-choir true` — TCP connectivity (10s timeout)
- `tailscale status --json | jq '.Peer["<sancta-choir-node-id>"].Online'`
- Gatus health endpoint for sancta-choir services (from rpi5)

On violation during an active test window, the tripwire executes a
**rollback cascade** — each channel is tried in order until one succeeds:

```bash
# Channel 1: SSH over Tailscale (normal path)
if ssh -o ConnectTimeout=10 root@sancta-choir.tail4249a9.ts.net \
     "nixos-rebuild switch --rollback"; then
  logger -t nemesis-tripwire "Rollback succeeded via Tailscale SSH"
  exit 0
fi

# Channel 2: SSH over public IPv4 (Tailscale may be down)
if ssh -o ConnectTimeout=10 root@<sancta-choir-public-ip> \
     "nixos-rebuild switch --rollback"; then
  logger -t nemesis-tripwire "Rollback succeeded via public IP SSH"
  exit 0
fi

# Channel 3: Hetzner API hard reboot (last resort — safe because
# nixos-rebuild test does NOT set the boot default; reboot recovers
# to the last nixos-rebuild switch generation)
if hcloud server reboot <sancta-choir-server-id>; then
  logger -t nemesis-tripwire -p daemon.crit \
    "Forced Hetzner reboot — SSH unreachable, recovering via boot default"
  exit 0
fi

# All channels failed — alert loudly
logger -t nemesis-tripwire -p daemon.emerg \
  "ALL ROLLBACK CHANNELS FAILED — sancta-choir stuck on test generation"
# Notify n8n webhook regardless of file I/O success
curl -sf -X POST "${N8N_WEBHOOK}" \
  -H 'Content-Type: application/json' \
  -d '{"event":"rollback_failed","severity":"critical"}' || true
```

**Why three channels:** The tripwire's SSH probe may detect that
Tailscale SSH is down — the same path it would use for rollback. A
public-IP fallback bypasses Tailscale. If sshd itself is broken (e.g.,
the tested generation changed sshd config), a Hetzner API reboot is the
ultimate recovery — `nixos-rebuild test` deliberately does not set the
boot default, so a reboot always returns to the last `switch` generation.

**Hetzner API prerequisite:** Requires `hcloud` CLI and an API token
(stored as `nemesis-hcloud-token.age`). This is a Phase 3 addition.

### Pro subscription auth (setup-token + agenix)

Nemesis authenticates `claude` CLI via the `CLAUDE_CODE_OAUTH_TOKEN`
environment variable, **not** interactive `claude auth login` (which
requires a browser redirect and produces short-lived tokens with unreliable
auto-refresh).

**Provisioning flow (one-time, on a machine with a browser):**

1. Run `claude setup-token` — this opens a browser OAuth flow and produces
   a long-lived (1-year) token: `sk-ant-oat01-...`
2. Encrypt the token: `cd secrets && agenix -e nemesis-oauth-token.age`
3. The `nemesis-planner.service` uses the standard agenix `ExecStartPre "+"`
   pattern to read the secret and export it as `CLAUDE_CODE_OAUTH_TOKEN`:

```bash
# ExecStartPre "+" (runs as root, reads agenix secret)
OAUTH_TOKEN=$(cat "${cfg.oauthTokenFile}")
echo "CLAUDE_CODE_OAUTH_TOKEN=$OAUTH_TOKEN" >> "$ENV_FILE"
```

**Token lifecycle:**
- Validity: 1 year from creation
- Renewal: re-run `claude setup-token`, re-encrypt with `agenix -e`
- Billing: charges against Pro/Max subscription quota, not per-token API rates
- Rate limits: 5-hour rolling window + 7-day weekly cap (Pro naturally
  limits planning cycles — this is a feature, not a bug)

**Why not `ANTHROPIC_API_KEY`?** API keys never expire and are simpler,
but bill per-token. The setup-token approach uses the existing Pro/Max
subscription at no marginal cost. If subscription rate caps become
problematic, switching to `ANTHROPIC_API_KEY` requires only changing
which agenix secret is read (the `anthropic-api-key.age` secret already
exists in this repo).

**Why not `claude auth login`?** Interactive OAuth produces short-lived
access tokens (hours) with a refresh token that has [known bugs](https://github.com/anthropics/claude-code/issues/12447)
— race conditions with concurrent sessions and unreliable automatic
refresh. A device-code flow (RFC 8628) has been [requested](https://github.com/anthropics/claude-code/issues/22992)
but is not implemented as of February 2026.

### Evaluation Constitution

The evaluation criteria for each planning cycle are defined as **stratum 0**
Nix options — the hardest layer to change, requiring a Tier 3 human PR:

```nix
options.services.nemesis.evaluation = {
  primaryMetric = mkOption {
    type    = types.str;
    default = "psi_mem_some_avg60";
    description = "The metric Nemesis optimizes for on the target.";
  };

  direction = mkOption {
    type    = types.enum [ "minimize" "maximize" ];
    default = "minimize";
  };

  minimumEffect = mkOption {
    type    = types.float;
    default = 0.05;
    description = "Minimum relative change to count as improvement (5%).";
  };

  safetyInvariants = mkOption {
    type    = types.listOf types.str;
    default = [ "ssh_reachable" "tailscale_online" "gatus_all_healthy" ];
    description = "Invariants checked at every verification step.";
  };
};
```

These options are injected into the task file as `<evaluation_criteria>` so
CC knows what "better" means. Changing the primary metric or direction
requires a human PR — Nemesis cannot redefine its own success function.

**24h Retrospective Check:** After each successful `nixos-rebuild switch`,
`nemesis-retrospective@<episode-id>.service` fires 24 hours later (via
`systemd-run --on-active=24h`). It compares the primary metric's 24h
post-switch average against the pre-switch baseline. If the metric
degraded beyond `minimumEffect`, a "delayed negative" vector is embedded
in Qdrant with `{"delayed_negative": true}`, overriding the original
`SUCCESS` outcome. This catches slow-onset regressions that pass the
10-minute verification window.

---

## Change Scope (sancta-choir services)

**Current state:** sancta-choir runs Tailscale, SSH, vscode-server, and
dev tools. Claude Code CLI is installed as a package (no systemd service).

**Prerequisite:** Deploy OpenClaw on sancta-choir (via `modules/services/
openclaw.nix`) to create the `openclaw-task-runner.service` systemd unit.
This is a Tier 3 human-reviewed change that must happen before Phase 2.

**Target state (post-prerequisite):** sancta-choir runs
`openclaw-task-runner.service` (the primary managed workload), Tailscale,
SSH, vscode-server, and supporting system services.

### Tier 1 — Autonomous (no human approval)

| Option | Bounds |
|--------|--------|
| `systemd.services.openclaw-task-runner.serviceConfig.MemoryMax` | ±20%, min 256M, max 3G |
| `systemd.services.openclaw-task-runner.serviceConfig.MemoryHigh` | ±20%, must be ≤ MemoryMax |
| `systemd.services.openclaw-task-runner.serviceConfig.CPUQuota` | ±25%, min 25%, max 400% |
| `systemd.services.openclaw-task-runner.serviceConfig.Nice` | ±3, range −20..19 |
| `nix.settings.max-jobs` / `nix.settings.cores` | ±1 |

**Note:** Options requiring a reboot are structurally incompatible with the
`nixos-rebuild test` verification window (reboot activates the boot-default
generation, not the tested one). Such options must be at least Tier 2.

### Tier 2 — Supervised (approval token before remote switch)

- `swapDevices[].size` — ±512MB (requires reboot; incompatible with autonomous test window)
- `services.openclaw.*` service-level options
- `boot.kernel.sysctl` memory/networking parameters
- Adding a new service module already present in `modules/services/`
- Package version pins for non-critical tools

### Tier 3 — Human PR only (Nemesis creates draft, does not apply)

- `modules/services/nemesis*.nix` — own config
- `networking.nftables.*`, `security.sudo.*`
- `flake.nix`, `flake.lock`
- `secrets/`, `age.secrets.*`
- `.github/workflows/`
- SSH authorized keys, user definitions, boot loader config

---

## New Files and Modules

```
modules/services/
  nemesis.nix                  ← Main NixOS module on rpi5 (options + units)
  nemesis-collector.nix        ← Observer: SSH-collects metrics from sancta-choir
  nemesis-actuator.nix         ← Actuator: six-gate pipeline + remote switch

modules/services/nemesis/
  change-auditor.py            ← Immutable auditor (Nix derivation)
  property-tests.py            ← COM property suite for sancta-choir config
  task-template.md             ← CC task file template
  system-prompt.txt            ← CC system prompt (Nix store, immutable)
  collect-remote.sh            ← SSH metric collection script
  self-profile-generator.py    ← Generates self-profile.json for task context
  invariant-checker.py         ← Verifies 6 identity invariants (immutable derivation)
  retrospective.py             ← 24h delayed outcome evaluator
  task-template-explore.md     ← Alternative CC template for exploration cycles
  memory-consolidator.py       ← Weekly episode consolidation + archival
  meta-review.py               ← Bi-weekly meta-analysis of Nemesis performance

hosts/sancta-choir/
  configuration.nix            ← + nemesis repo clone setup
  agent-overlays/
    default.nix                ← managed by actuator (imports list)
    .gitkeep

docs/
  nemesis-plan.md              ← This file
```

### `modules/services/nemesis.nix` — key options

```nix
options.services.nemesis = {
  enable = mkEnableOption "Nemesis self-evolving NixOS agent (controller on rpi5)";

  targetHost = mkOption {
    type    = types.str;
    default = "sancta-choir";
    description = "Tailscale hostname of the managed target.";
  };

  targetFlakeAttr = mkOption {
    type    = types.str;
    default = "sancta-choir";
    description = "Flake output attribute for the target host.";
  };

  targetRepoPath = mkOption {
    type    = types.str;
    default = "/var/lib/nemesis/nixos-config";
    description = "Path to nixos-config clone on the target host.";
  };

  sshKeyFile = mkOption {
    type    = types.path;
    description = "SSH private key (agenix) for nemesis user to reach target.";
  };

  planningIntervalHours = mkOption {
    type    = types.int;
    default = 72;
    description = "Fallback scheduled cycle if CUSUM never fires.";
  };

  verificationWindowSeconds = mkOption {
    type    = types.int;
    default = 600;
  };

  qdrantUrl = mkOption {
    type    = types.str;
    default = "http://127.0.0.1:6333";
    description = "Qdrant on rpi5 (local, used for RAG memory).";
  };

  gatusUrl = mkOption {
    type    = types.str;
    default = "http://127.0.0.1:3001";
    description = "Gatus on rpi5 (external monitor of sancta-choir).";
  };

  tier1.services = mkOption {
    type    = types.listOf types.str;
    default = [ "openclaw-task-runner" ];
    description = "systemd service names on target Nemesis may adjust autonomously.";
  };

  notifications.n8nWebhookUrl = mkOption {
    type    = types.nullOr types.str;
    default = null;
  };

  oauthTokenFile = mkOption {
    type    = types.path;
    description = "Path to file containing CLAUDE_CODE_OAUTH_TOKEN (agenix).";
  };

  limits.maxSwitchesPerDay  = mkOption { type = types.int; default = 3; };
  limits.maxConsecutiveFails = mkOption { type = types.int; default = 3; };
};
```

---

## Systemd Units (all on rpi5)

| Unit | Type | Purpose |
|------|------|---------|
| `nemesis-schema-init.service` | oneshot/boot | Apply SQLite schema |
| `nemesis-collector.service` | oneshot | SSH-collect metrics from sancta-choir |
| `nemesis-collector.timer` | timer/2m | Drive collector |
| `nemesis-cusum-watchdog.service` | simple | Continuous CUSUM; writes trigger file |
| `nemesis-anomaly-watcher.service` | simple | Gatus failures + SSH OOM scan; writes trigger |
| `nemesis-planner.service` | oneshot | Build task file, run `claude -p` |
| `nemesis-planner.path` | path | Watch `triggers/` for new trigger files |
| `nemesis-actuator@.service` | oneshot/template | Six-gate pipeline for one proposal |
| `nemesis-tripwire.service` | simple | External safety monitor; remote rollback |
| `nemesis-cleanup.timer` | timer/daily | Prune old proposals and episodes |
| `nemesis-retrospective@.service` | oneshot/template | 24h delayed metric comparison per episode |
| `nemesis-retrospective-check.timer` | timer/hourly | Persistent timer; fires pending retrospectives (Loop #4) |
| `nemesis-consolidation.timer` | timer/weekly | Trigger memory-consolidator.py |
| `nemesis-consolidation.service` | oneshot | Weekly episode consolidation + archival |
| `nemesis-meta-review.timer` | timer/bi-weekly | 1st and 15th of month meta-analysis |
| `nemesis-meta-review.service` | oneshot | Compute statistics + generate report |

### RAM Budget

All Nemesis scripts are oneshot services; they do not consume memory
concurrently with each other (except the always-running tripwire and
watchdog, which are small).

| Script | Peak RAM | Runtime | Frequency |
|--------|----------|---------|-----------|
| `collect-remote.sh` | ~5 MB | ~3s | Every 2m |
| `self-profile-generator.py` | ~15 MB | ~2s | Per planning cycle |
| `invariant-checker.py` | ~10 MB | ~1s | Per actuator run (×2) |
| `retrospective.py` | ~15 MB | ~5s | 24h after each switch |
| `memory-consolidator.py` | ~25 MB | ~30s | Weekly |
| `meta-review.py` | ~20 MB | ~10s | Bi-weekly |
| `change-auditor.py` | ~10 MB | ~1s | Per actuator run |
| `property-tests.py` | ~15 MB | ~5s | Per actuator run |

**Worst-case concurrent overhead:** ~40 MB (tripwire + watchdog + one
oneshot). The rpi5 has 4 GB RAM with zram; Nemesis is well within budget.

---

## Data Stores

### SQLite: `/var/lib/nemesis/metrics.db` (on rpi5)

```sql
CREATE TABLE observations (
  id           INTEGER PRIMARY KEY,
  collected_at DATETIME NOT NULL,
  target_host  TEXT NOT NULL DEFAULT 'sancta-choir',
  generation   INTEGER NOT NULL,
  data         JSON NOT NULL        -- full SystemSnapshot from target
);

CREATE TABLE service_metrics (
  id             INTEGER PRIMARY KEY,
  observation_id INTEGER REFERENCES observations(id),
  service        TEXT NOT NULL,
  memory_bytes   INTEGER,
  cpu_usage_ns   INTEGER,
  psi_mem_some   REAL,
  psi_mem_full   REAL,
  healthy        BOOLEAN,       -- from Gatus (external probe)
  latency_ms     INTEGER        -- from Gatus response time
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
  id               TEXT PRIMARY KEY,
  started_at       DATETIME,
  completed_at     DATETIME,
  goal             TEXT,
  overlay_file     TEXT,
  gate_results     JSON,
  activated        BOOLEAN DEFAULT FALSE,
  outcome          TEXT,  -- 'success', 'rollback', 'rejected'
  rollback_reason  TEXT,
  generation_from  INTEGER,
  generation_to    INTEGER,
  psi_before       REAL,
  psi_after        REAL
);
```

### Qdrant: collection `nemesis-outcomes` (on rpi5, existing instance)

```json
{
  "content": "Raised openclaw-task-runner MemoryMax 1536M→2048M on sancta-choir. OOM restarts dropped from 2/day to 0. PSI full avg60 fell from 1.2 to 0.1 within 20 minutes.",
  "metadata": {
    "target_host": "sancta-choir",
    "service": "openclaw-task-runner",
    "option": "systemd.services.openclaw-task-runner.serviceConfig.MemoryMax",
    "old_value": "1536M",
    "new_value": "2048M",
    "outcome": "success",
    "timestamp": "2026-02-21T18:00:00Z"
  }
}
```

Embedding model: TBD (see Prerequisites). Options: (a) install Ollama on
rpi5 with `nomic-embed-text` (~274MB RAM), (b) use OpenRouter embedding API
via existing Open-WebUI connection, (c) use a smaller model like
`all-minilm-l6-v2` (~80MB). Decision deferred to Phase 1.

---

## Remote Metric Collection

The collector SSHes into sancta-choir as `root` (dedicated SSH key in
root's `authorized_keys`). Root access is required because `nixos-rebuild`
and `systemctl show` need it. The key is restricted via `command=` in
`authorized_keys` to a wrapper script that whitelists only the commands
Nemesis needs (see "sancta-choir Host Configuration" section):

```bash
# modules/services/nemesis/collect-remote.sh
set -euo pipefail
TARGET="${1:-sancta-choir}"
SSH="ssh -i /run/nemesis/ssh-key -o ConnectTimeout=10 \
         -o StrictHostKeyChecking=accept-new \
         root@${TARGET}.tail4249a9.ts.net"
STDERR_LOG=$(mktemp)
COLLECT_FAILURES=0
trap 'rm -f "$STDERR_LOG"' EXIT

ssh_collect() {
  # Run SSH command, capture stderr, check exit code.
  # On failure: log error, record anomaly, increment failure counter.
  local label="$1"; shift
  if output=$($SSH "$@" 2>"$STDERR_LOG"); then
    echo "$output"
  else
    local rc=$?
    logger -t nemesis-collector -p daemon.err \
      "SSH collection failed [${label}]: rc=${rc} stderr=$(cat "$STDERR_LOG")"
    COLLECT_FAILURES=$((COLLECT_FAILURES + 1))
    return 1
  fi
}

# Per-service memory and CPU
for svc in openclaw-task-runner tailscaled; do
  mem=$(ssh_collect "${svc}/mem" \
    "systemctl show --value -p MemoryCurrent ${svc}.service") || mem=""
  cpu=$(ssh_collect "${svc}/cpu" \
    "systemctl show --value -p CPUUsageNSec  ${svc}.service") || cpu=""
  # Only record metric if collection succeeded (non-empty)
  if [ -n "$mem" ] && [ -n "$cpu" ]; then
    echo "service=${svc} mem=${mem} cpu=${cpu}"
  else
    echo "service=${svc} COLLECTION_FAILED"
    # Record anomaly in SQLite (anomaly_type='collection_failure')
  fi
done

# PSI (memory pressure from target's perspective)
ssh_collect "psi" "cat /proc/pressure/memory" || true

# Recent journal anomalies
ssh_collect "journal" \
  "journalctl --since '3m ago' --output json --no-pager -q" \
  | grep -E '"PRIORITY":"[012]"' | head -50 || true

# Current NixOS generation
ssh_collect "generation" \
  "readlink /nix/var/nix/profiles/system" \
  | grep -oP 'system-\K\d+' || true

# Report collection health to the /health endpoint
if [ "$COLLECT_FAILURES" -gt 0 ]; then
  logger -t nemesis-collector -p daemon.warning \
    "Collection cycle completed with ${COLLECT_FAILURES} failures"
fi
# Write failure count to state file for health endpoint
echo "$COLLECT_FAILURES" > /var/lib/nemesis/last-collect-failures
```

Gatus on rpi5 provides the **external** health perspective (HTTP probes
to sancta-choir's Tailscale-exposed endpoints) without any SSH dependency.
Both signals are stored in SQLite and combined in the SystemSnapshot.

---

## Task File Structure (what CC reads on rpi5)

```markdown
# Nemesis Planning Cycle — <timestamp>

## Your Role
You are the reasoning engine for Nemesis. You manage the NixOS configuration
of `sancta-choir` (x86_64 Hetzner VPS) from `rpi5`. Analyze the target's
current state, identify the highest-impact safe change, and write ONE overlay.

## Target host
sancta-choir — x86_64-linux, Hetzner VPS, 4GB RAM + 2GB swap
Running services: openclaw-task-runner, tailscaled, vscode-server

## Constraints (enforced by actuator — violations are rejected)
- Write to `hosts/sancta-choir/agent-overlays/<id>.nix` ONLY.
- Propose exactly one option change per overlay.
- Tier 1 options only:
    MemoryMax/MemoryHigh ±20% · CPUQuota ±25% · Nice ±3
    nix.settings.max-jobs ±1
- Services in scope: openclaw-task-runner
- If no safe change exists, write `agent-overlays/no-action-<id>.txt`.

## Required Outputs
1. Overlay .nix file (Write tool → hosts/sancta-choir/agent-overlays/<id>.nix)
2. Proposal JSON (Write tool → /var/lib/nemesis/proposals/<id>.json):
   {
     "hypothesis":          "...",
     "overlay_file":        "hosts/sancta-choir/agent-overlays/<id>.nix",
     "target_service":      "openclaw-task-runner",
     "target_option":       "...",
     "old_value":           "...",
     "new_value":           "...",
     "rationale":           "...",
     "verification_checks": [
       {"type": "health_check", "gatus_endpoint": "sancta-choir-openclaw", "timeout_seconds": 120},
       {"type": "ssh_probe",    "host": "sancta-choir",       "timeout_seconds": 10}
     ],
     "expected_outcome":    "..."
   }

## Target System State (collected via SSH + Gatus)
<snapshot>
[SystemSnapshot JSON]
</snapshot>

## Relevant Past Outcomes
<past_outcomes>
[Top-5 Qdrant results]
</past_outcomes>

## Current Configuration
<current_config>
[nix eval .#nixosConfigurations.sancta-choir.config.systemd.services.openclaw-task-runner]
</current_config>

## Self-Profile
<self_profile>
[Generated by self-profile-generator.py — recent option frequency, success
 rates, unexplored options, time since last exploration cycle]
</self_profile>

## Evaluation Criteria
<evaluation_criteria>
[From services.nemesis.evaluation Nix options — primary metric, direction,
 minimum effect size, safety invariants that must hold]
</evaluation_criteria>
```

---

## Actuator Pipeline

All steps run on rpi5. Remote steps are explicit SSH calls.

```
Step 1   Validate proposal JSON schema (rpi5, local)
Step 2   Verify overlay file path is in hosts/sancta-choir/agent-overlays/
Step 3   Gate 1: nix eval type-check proposed values             (rpi5, ~10ms)
Step 4   Gate 2: nix-instantiate --parse <overlay>               (rpi5, ~50ms)
Step 5   Gate 3: nix flake check                                 (rpi5, ~10s)
Step 6   Gate 5: property test suite against COM snapshot        (rpi5, ~5s)
Step 7   Gate 6: change-auditor verdict                          (rpi5, ~1s)
Step 8   Pre-flight:
           rpi5: disk ≥ 1GB free on local clone
           SSH:  df sancta-choir /nix ≥ 5GB free
           SSH:  nix-env --list-generations -p /nix/var/nix/profiles/system | wc -l ≥ 3
           Gatus: sancta-choir services currently healthy
Step 9   Update agent-overlays/default.nix to import new overlay (rpi5, local)
Step 9a  Evaluated-value verification (Feedback Loop #2):
           nix eval critical options (firewall, sshd, tailscale) against
           the overlay-applied configuration — catches semantic bypasses
           that the regex-based change auditor (Gate 6) cannot detect
Step 10  git commit (branch nemesis/<id>) + git push to origin   (rpi5)
Step 11  SSH: git fetch + checkout nemesis/<id> on sancta-choir
Step 12  Gate 4: SSH: nixos-rebuild build --flake .#sancta-choir (~5min on sancta-choir)
Step 13  SSH: nixos-rebuild test --flake .#sancta-choir
Step 14  Verification window: 10 minutes (20 probe cycles at 30s intervals)
           Grace period (Feedback Loop #3): first 30s (1 cycle) is unscored
             — nixos-rebuild test restarts sshd, causing transient SSH
             failures that would otherwise trigger immediate rollback.
             During grace: SSH failures are neutral, SSH successes score +1.
           each cycle runs two probes from rpi5:
             Gatus HTTP probe: sancta-choir health endpoint (5s timeout)
             SSH probe: ssh -o ConnectTimeout=10 root@sancta-choir true
           probe outcomes (three states, not two):
             pass    → +1 (both probes succeeded)
             fail    → −3 (either probe returned error)
             timeout → −3 (either probe exceeded its timeout — treated as fail)
           scoring: start at 0, abort if score < 0 OR tripwire fires
           minimum probe requirement: at least 15 of 20 cycles must complete
             (if <15 cycles run, e.g. due to slow timeouts, treat as fail)
           all probe results logged to episode record for post-mortem analysis
Step 15  score passes → SSH: nixos-rebuild switch
                      → gh pr create (from rpi5, labeled nemesis)
                      → embed SUCCESS in Qdrant (rpi5)
                      → write pending retrospective entry (Feedback Loop #4)
Step 16  score fails  → rollback cascade (Tailscale SSH → public IP → Hetzner reboot)
                      → embed ROLLBACK + lessons-learned in Qdrant (rpi5)
                      → git push origin --delete nemesis/<id> (Feedback Loop #7)
                      → notify n8n (rpi5)
         gate fails   → embed GATE_REJECTED in Qdrant (Feedback Loop #1)
                      → delete local branch (no remote push occurred)
```

### Property Test Suite (Gate 5, runs on rpi5 against sancta-choir COM)

```python
def test_no_port_conflicts(com):
    """No two services bind the same port on sancta-choir."""

def test_ssh_daemon_enabled(com):
    """services.openssh.enable must remain true (remote access)."""

def test_tailscale_enabled(com):
    """services.tailscale.enable must remain true."""

def test_openclaw_service_enabled(com):
    """services.openclaw.enable must remain true."""

def test_memory_limits_within_vps_budget(com):
    """Sum of MemoryMax < 3.5GB (4GB Hetzner VPS minus headroom)."""

def test_memhigh_lte_memmax(com):
    """MemoryHigh <= MemoryMax for every service."""

def test_nemesis_config_unchanged(com):
    """services.nemesis.* on rpi5 unchanged (not in target COM, but check diff)."""

def test_swap_not_removed(com):
    """swapDevices list is non-empty (prevents OOM during builds)."""
```

### Change Auditor (Gate 6, immutable derivation on rpi5)

```python
BLOCKED = [
    r"\.github/workflows/",
    r"authorized_keys",
    r"users\.users\.root",
    r"networking\.firewall\.enable\s*=\s*false",
    r"services\.openssh\.enable\s*=\s*false",
    r"services\.tailscale\.enable\s*=\s*false",
]

SUPERVISED = [
    r"modules/services/nemesis",
    r"secrets/secrets\.nix",
    r"age\.secrets\.",
    r"security\.sudo",
    r"networking\.nftables",
    r"boot\.(kernelPackages|initrd|kernelModules|loader)",
    r"fileSystems\.",
    r"swapDevices",
]
```

---

## Circuit Breaker

If 3 consecutive proposals result in rollback:
1. Write `/var/lib/nemesis/circuit-open`
2. Notify via n8n webhook (rpi5 → n8n → human)
3. Stop all trigger file writes
4. Human resets: `rm /var/lib/nemesis/circuit-open`

---

## Memory and Learning

### Retrieval-Augmented Planning

Past outcomes stored in Qdrant on rpi5 (`nemesis-outcomes` collection),
retrieved by semantic similarity at planning time. The embedding query is
the current `SystemSnapshot` formatted as prose — retrieving outcomes
matching the symptom pattern across all past sancta-choir episodes.

### Semantic Rollback Analysis

When rollback is detected, rpi5 calls `claude -p <analysis-prompt>` (one-shot,
no tools) to produce a `lessons-learned` paragraph, embedded alongside the
failure in Qdrant. Future planning cycles retrieve this diagnosis
automatically.

### Memory Consolidation

Weekly `nemesis-consolidation.timer` runs `memory-consolidator.py`:

1. **Group:** Query Qdrant `nemesis-outcomes` collection; group episodes by
   `(service, option)` pair.
2. **Summarize:** If a group has >5 episodes, call `claude -p` (one-shot, no
   tools) to produce a single consolidated pattern — e.g., "Raising MemoryMax
   above 2048M on openclaw-task-runner consistently reduces OOM events but
   shows diminishing returns above 2560M."
3. **Replace:** Delete individual episode vectors from Qdrant; insert the
   consolidated pattern as one new vector with metadata
   `{"consolidated": true, "episode_count": N}`.
4. **Archive:** Move episodes older than 90 days to a separate
   `nemesis-archive` Qdrant collection (queryable but not included in
   planning-time retrieval by default).
5. **Resolve contradictions:** If the same `(service, option, value)` appears
   with both `SUCCESS` and `ROLLBACK` outcomes, keep only the most recent
   result and annotate the consolidated vector with `"contradicted": true`.

### Meta-Review

Bi-weekly `nemesis-meta-review.timer` (fires on the 1st and 15th of each
month) runs `meta-review.py`:

1. **Compute statistics:**
   - Gate pass rate (per gate, over trailing 30 days)
   - Rollback rate (rollbacks / total activations)
   - Option frequency (which Tier 1 options are touched most)
   - Bound saturation (how close proposals get to Tier 1 bounds, e.g.,
     MemoryMax approaching the 3G ceiling)
2. **Output report:** `/var/lib/nemesis/meta-reviews/<date>.md`
3. **Bound expansion proposals:** If any Tier 1 bound is >60% saturated
   (e.g., most proposals push MemoryMax to >2.4G out of 3G max), generate
   a Tier 3 draft PR via `gh pr create --draft --label nemesis-meta`
   proposing a bound increase. The change auditor blocks auto-apply for
   `nemesis*.nix`, so this always requires human review.
4. **Context injection:** Meta-review output is included in future planning
   cycles as additional context (appended to the task file after
   `<past_outcomes>`).

---

## Feedback Loops

This section catalogs the closed-loop mechanisms that allow Nemesis to learn
from its own failures and prevent silent state drift. Each loop was identified
from design review feedback — without them, failures are invisible and the
agent repeats mistakes.

### Loop #1 — Gate Failure Embedding

**Gap:** When a gate rejects a proposal (Steps 3–7), the failure is logged
but not embedded in Qdrant. Future planning cycles have no semantic memory
of *why* similar proposals were rejected, leading to repeated gate failures.

**Mechanism:** On any gate failure, the actuator embeds a `GATE_REJECTED`
vector in the `nemesis-outcomes` Qdrant collection:

```json
{
  "content": "Proposal to raise MemoryMax to 3200M was rejected by Gate 5 (property test): sum of MemoryMax exceeded 3.5GB VPS budget.",
  "metadata": {
    "outcome": "gate_rejected",
    "gate": "property_tests",
    "target_option": "systemd.services.openclaw-task-runner.serviceConfig.MemoryMax",
    "proposed_value": "3200M",
    "rejection_reason": "test_memory_limits_within_vps_budget failed"
  }
}
```

Future planning cycles retrieve these failures by semantic similarity, giving
CC explicit knowledge of what the gates will reject.

**Phase:** 1 (when Qdrant embedding pipeline is available).

### Loop #2 — Evaluated-Value Verification

**Gap:** The change auditor (Gate 6) uses regex against raw Nix source text.
This cannot catch `lib.mkForce`, attribute-set nesting, or variable
indirection. A proposal could bypass the regex-based BLOCKED patterns while
still evaluating to a dangerous value.

**Mechanism:** After updating `agent-overlays/default.nix` (Step 9) and
before the remote build (Step 12), the actuator runs `nix eval` checks
against the *evaluated* configuration with the overlay applied:

```bash
# Verify critical options remain safe after overlay evaluation
nix eval .#nixosConfigurations.sancta-choir.config.networking.firewall.enable
# must == true
nix eval .#nixosConfigurations.sancta-choir.config.services.openssh.enable
# must == true
nix eval .#nixosConfigurations.sancta-choir.config.services.tailscale.enable
# must == true
```

This supplements (not replaces) the regex auditor — the regex catches
obviously bad source patterns early, while `nix eval` catches semantically
dangerous *evaluated* values regardless of how they're expressed.

**Phase:** 2 (when the actuator pipeline is implemented).

### Loop #3 — Verification Window Grace Period

**Gap:** `nixos-rebuild test` restarts sshd during activation, causing a
~5–10s window where SSH probes fail. With the `-3` fail weight, the first
probe after activation drops the score below 0 and triggers an immediate
rollback of an otherwise healthy change.

**Mechanism:** The verification window (Step 14) starts with a 30-second
grace period before scoring begins. During this grace period:
- Gatus HTTP probes are collected but not scored
- SSH probe failures are treated as neutral (score unchanged)
- Only SSH *successes* during grace are scored (+1), confirming the target
  is back online

After the grace period, normal scoring resumes (`+1 pass / -3 fail`).

**Phase:** 2 (actuator pipeline implementation).

### Loop #4 — Persistent Retrospective Timer

**Gap:** The 24h retrospective uses `systemd-run --on-active=24h`, which
creates a transient unit that does not survive rpi5 reboots. If rpi5
reboots within 24 hours of a successful switch, the delayed outcome
evaluation never fires, and slow-onset regressions go undetected.

**Mechanism:** Replace transient `systemd-run` with a persistent timer:

1. At switch time, the actuator writes a pending retrospective entry:
   ```bash
   echo "$episode_id $(date -u +%s)" >> /var/lib/nemesis/pending-retrospectives
   ```

2. `nemesis-retrospective-check.timer` fires hourly with `Persistent=true`
   (survives reboots). It reads `pending-retrospectives`, fires
   `nemesis-retrospective@<episode-id>.service` for any entry where
   `now - switch_timestamp >= 24h`, then removes the processed entry.

3. On rpi5 reboot, the persistent timer catches up on missed retrospectives
   at its next activation.

**Phase:** 4 (when retrospective is fully deployed).

### Loop #5 — Bound Saturation Alerting

**Gap:** Tier 1 bounds (e.g., MemoryMax max 3G) are fixed. If proposals
consistently push values toward the ceiling, the agent's ability to improve
shrinks without any signal. The agent keeps proposing near-ceiling values
that produce diminishing returns.

**Mechanism:** `meta-review.py` (bi-weekly) computes bound saturation for
each Tier 1 option:

```
saturation = (most_recent_value - bound_min) / (bound_max - bound_min)
```

If saturation exceeds 60%, the meta-review:
1. Logs a warning to the report
2. Generates a Tier 3 draft PR (`gh pr create --draft --label nemesis-meta`)
   proposing a bound increase with supporting data
3. Injects the saturation data into future planning cycles so CC can factor
   in how close it is to the ceiling

**Phase:** 4 (meta-review already designed; saturation tracking added here).

### Loop #6 — Collection Staleness Detection

**Gap:** If SSH collection fails repeatedly (sancta-choir unreachable,
command errors), the CUSUM watchdog and anomaly watcher operate on stale
data. Without an explicit staleness signal, the planner may propose
changes based on outdated metrics.

**Mechanism:**
- `collect-remote.sh` writes a timestamp to
  `/var/lib/nemesis/last-successful-collection`
- The planner checks this timestamp before generating a task file.
  If `now - last_collection > 10m` (5 missed cycles), the planner:
  1. Injects a `<stale_data_warning>` section into the task file
  2. CC is instructed to propose only no-action or conservative changes
  3. The staleness event is recorded as an anomaly in SQLite

**Phase:** 3 (when event-driven triggering is active).

### Loop #7 — Git Branch Hygiene After Rollback

**Gap:** Step 10 pushes a `nemesis/<id>` branch to GitHub before the remote
build (Step 12). If any subsequent step fails and the system rolls back,
the branch persists on GitHub. Over time, stale branches accumulate and
pollute the repository.

**Mechanism:**
- On rollback (Step 16): the actuator runs
  `git push origin --delete nemesis/<id>` after the rollback cascade
- On gate failure (Steps 3–7): the actuator deletes the local branch
  (no push was made yet)
- `nemesis-cleanup.timer` (daily): prunes any `nemesis/*` remote branches
  older than 7 days that have no associated open PR

**Phase:** 2 (when the actuator pipeline is implemented).

### Loop #8 — Planner Serialization Lock

**Gap:** The CUSUM watchdog and anomaly watcher can both write trigger files
simultaneously. If `nemesis-planner.path` fires twice within the same
activation window, two planners run concurrently — each generating a
separate overlay and racing to push to git.

**Mechanism:** The planner service uses `flock` to serialize execution:

```bash
# nemesis-planner ExecStart
exec flock --nonblock /var/lib/nemesis/planner.lock \
  /path/to/nemesis-planner.sh
```

If the lock is held, the second invocation exits immediately. The path
unit will re-trigger when the next trigger file appears.

Additionally, the actuator uses its own lock
(`/var/lib/nemesis/actuator.lock`) to prevent concurrent remote
`nixos-rebuild` operations.

**Phase:** 3 (when CUSUM + anomaly watcher are deployed).

### Loop #9 — OAuth Token Expiry Probe

**Gap:** The `CLAUDE_CODE_OAUTH_TOKEN` (1-year validity from
`claude setup-token`) can expire mid-cycle. Without explicit auth error
detection, an expired token causes CC invocation failures that increment
the consecutive-failure counter and eventually trip the circuit breaker —
masking the real problem (expired credential, not bad proposals).

**Mechanism:**
- `nemesis-planner.service` captures CC exit codes and stderr
- Auth errors (HTTP 401, "invalid token", "expired") are classified
  separately from planning failures
- Auth errors do **not** increment `limits.maxConsecutiveFails`
- On auth error: write `/var/lib/nemesis/auth-error`, notify n8n
  webhook with `{"event": "auth_expired", "severity": "high"}`
- The planner refuses to run while `auth-error` exists (similar to
  circuit breaker, but distinct — requires re-provisioning the token)

**Phase:** 1 (required when CC invocation begins).

### Loop #10 — Nix Store GC on Target

**Gap:** Nemesis creates new NixOS generations on sancta-choir with each
successful switch. Without periodic garbage collection, `/nix/store` fills
up. The pre-flight check (`df /nix ≥ 5GB`) catches imminent disk
exhaustion but doesn't prevent it.

**Mechanism:**
- `nemesis-cleanup.timer` (daily, already planned) adds a remote GC step:
  ```bash
  ssh root@sancta-choir \
    "nix-collect-garbage --delete-older-than 14d"
  ```
- The cleanup retains the 3 most recent generations regardless of age
  (ensures rollback is always possible)
- Disk usage is reported in the meta-review for trend tracking

**Phase:** 2 (when the actuator has remote SSH access).

### Loop Summary

| # | Name | Signal | Response | Phase |
|---|------|--------|----------|-------|
| 1 | Gate failure embedding | Gate rejects proposal | Embed in Qdrant for future planning | 1 |
| 2 | Evaluated-value check | Overlay applied | `nix eval` critical options | 2 |
| 3 | Grace period | `nixos-rebuild test` | 30s scoring pause | 2 |
| 4 | Persistent retrospective | Successful switch | Hourly timer checks pending list | 4 |
| 5 | Bound saturation | Proposals near ceiling | Draft PR + planner context | 4 |
| 6 | Collection staleness | SSH failures | Stale-data warning in task file | 3 |
| 7 | Git hygiene | Rollback/gate failure | Delete stale branches | 2 |
| 8 | Planner serialization | Concurrent triggers | `flock` on planner + actuator | 3 |
| 9 | OAuth probe | Auth error from CC | Separate error class, notify | 1 |
| 10 | Nix store GC | Daily timer | Remote `nix-collect-garbage` | 2 |

---

## Integration with Existing Infrastructure

| Component (on rpi5) | Role in Nemesis |
|---------------------|-----------------|
| **OpenClaw module** | `modules/services/openclaw.nix` provides the design pattern for user isolation, sudo wrapper, and nftables rules. Not currently deployed on rpi5 — Nemesis builds its own invocation layer modeled on this. |
| **Gatus** | Primary external health signal for sancta-choir. Nemesis polls `http://127.0.0.1:3001/api/v1/endpoints/statuses` for sancta-choir endpoint results. |
| **Qdrant** | RAG memory bank (`nemesis-outcomes` collection). Existing instance on rpi5 at `http://127.0.0.1:6333`. |
| **n8n** | Receives circuit-breaker alerts and Tier-2 approval requests from Nemesis. |
| **Embedding** | TBD — see Prerequisites. Ollama is not currently deployed on rpi5. |

### New Secrets

```nix
# secrets/secrets.nix — add:
"nemesis-ssh-key.age".publicKeys = allKeys;        # SSH key for rpi5 nemesis→sancta-choir
"nemesis-github-token.age".publicKeys = allKeys;   # GitHub PAT for PR creation
"nemesis-oauth-token.age".publicKeys = allKeys;    # CC setup-token (1-year, Pro/Max)
"nemesis-hcloud-token.age".publicKeys = allKeys;   # Hetzner API token (tripwire rollback)
```

```nix
# hosts/rpi5-full/configuration.nix — age.secrets:
age.secrets.nemesis-oauth-token.file = "${self}/secrets/nemesis-oauth-token.age";
```

### rpi5 Host Configuration

```nix
# hosts/rpi5-full/configuration.nix — add:
imports = [ ../../modules/services/nemesis.nix ];

services.nemesis = {
  enable            = true;
  targetHost        = "sancta-choir";
  targetFlakeAttr   = "sancta-choir";
  targetRepoPath    = "/var/lib/nemesis/nixos-config";
  sshKeyFile        = config.age.secrets.nemesis-ssh-key.path;
  oauthTokenFile    = config.age.secrets.nemesis-oauth-token.path;
  qdrantUrl         = "http://127.0.0.1:6333";
  gatusUrl          = "http://127.0.0.1:3001";
  tier1.services    = [ "openclaw-task-runner" ];
  notifications.n8nWebhookUrl = "http://127.0.0.1:5678/webhook/nemesis";
  limits.maxSwitchesPerDay   = 3;
};
```

### sancta-choir Host Configuration (additions)

```nix
# hosts/sancta-choir/configuration.nix — add:
imports = [
  # ... existing imports ...
  ./agent-overlays   # imports hosts/sancta-choir/agent-overlays/default.nix
];

# Nemesis repo clone: kept up to date by the actuator (git pull before each build)
systemd.tmpfiles.rules = [
  "d /var/lib/nemesis 0750 root root -"
  "d /var/lib/nemesis/nixos-config 0750 root root -"
];

# Add nemesis SSH key to root's authorized_keys — command-restricted
users.users.root.openssh.authorizedKeys.keys = [
  # existing keys...
  ''command="${pkgs.nemesis-ssh-wrapper}/bin/nemesis-ssh-wrapper",restrict ssh-ed25519 AAAA... nemesis@rpi5''
];
```

The `nemesis-ssh-wrapper` is a Nix derivation (immutable) that whitelists
only the commands Nemesis needs:

```bash
#!/usr/bin/env bash
# nemesis-ssh-wrapper — restrict SSH commands from the Nemesis key
# Built as a Nix derivation; the agent cannot modify it.
set -euo pipefail

case "$SSH_ORIGINAL_COMMAND" in
  "systemctl show --value -p "*)         exec $SSH_ORIGINAL_COMMAND ;;
  "cat /proc/pressure/memory")           exec $SSH_ORIGINAL_COMMAND ;;
  "journalctl --since "*" --output json"*) exec $SSH_ORIGINAL_COMMAND ;;
  "readlink /nix/var/nix/profiles/system") exec $SSH_ORIGINAL_COMMAND ;;
  "df "*"/nix"*)                         exec $SSH_ORIGINAL_COMMAND ;;
  "nix-env --list-generations"*)         exec $SSH_ORIGINAL_COMMAND ;;
  "nixos-rebuild build --flake "*)       exec $SSH_ORIGINAL_COMMAND ;;
  "nixos-rebuild test --flake "*)        exec $SSH_ORIGINAL_COMMAND ;;
  "nixos-rebuild switch --flake "*)      exec $SSH_ORIGINAL_COMMAND ;;
  "nixos-rebuild switch --rollback")     exec $SSH_ORIGINAL_COMMAND ;;
  "systemd-run --unit=nemesis-rebuild "*)exec $SSH_ORIGINAL_COMMAND ;;
  "true")                                exit 0 ;;  # SSH probe
  "cd /var/lib/nemesis/nixos-config && git fetch"*) exec $SSH_ORIGINAL_COMMAND ;;
  *)
    logger -t nemesis-ssh-wrapper -p auth.warning \
      "Blocked command from nemesis key: $SSH_ORIGINAL_COMMAND"
    echo "ERROR: command not in Nemesis allowlist" >&2
    exit 1
    ;;
esac
```

### Gatus Endpoints (rpi5, Nemesis self-observability)

```nix
services.gatus-tailscale.endpoints = {
  nemesis-collector = {
    name  = "Nemesis Collector";
    group = "nemesis";
    url   = "http://127.0.0.1:9095/health";
    interval = "5m";
    conditions = [
      "[STATUS] == 200"
      "[BODY].last_collection_age_seconds < 300"
      "[BODY].circuit_breaker_open == false"
    ];
  };
};
```

---

## Security Posture

### The Nemesis User (on rpi5)

```nix
users.users.nemesis = {
  isSystemUser = true;
  uid          = 992;    # static, for nftables
  group        = "nemesis";
  home         = "/var/lib/nemesis";
};
```

### Sudo Wrapper (nemesis-sudo, analogous to openclaw-sudo)

- `build <target>` → `nixos-rebuild build --flake <repo>#<target>` (rpi5 dry-run only)
- `check` → `nix flake check`
- `fmt` → `nix fmt`
- SSH operations: handled directly by the `nemesis` user's SSH key, not via sudo
- No `switch` or `test` in the local sudo wrapper — those run on sancta-choir via SSH

### Network Restrictions (nftables, rpi5 UID-based)

The `nemesis` user on rpi5 may reach:
- `api.anthropic.com` (CC Pro subscription)
- `api.github.com` + `github.com` (PR creation)
- Tailscale interface (`tailscale0`) — covers sancta-choir SSH, local services
- DNS, loopback

All other outbound: dropped and logged.

### CC `allowedTools` Whitelist

```
Read · Glob · Grep · Bash(nix eval *) · Write
```

CC cannot: `Edit`, run `nixos-rebuild`, `git`, `ssh`, `curl`, or `systemctl`.

### What Nemesis Cannot Change About Itself

`modules/services/nemesis.nix` and `hosts/rpi5-full/configuration.nix`
(the controller's own config) are matched by the change auditor's
`SUPERVISED` patterns. Any proposal touching them produces a draft PR only.

---

## Identity Invariant

Six properties must hold **before and after** every Nemesis modification.
The actuator runs `invariant-checker.py` at pre-flight (Step 8) and
post-verification (after Step 14). Failure at either point aborts or
rolls back the episode.

| # | Check | Method | Failure Action |
|---|-------|--------|----------------|
| 1 | `ssh_reachable` | `ssh root@sancta-choir true` (5s timeout) | Abort / rollback |
| 2 | `tailscale_online` | `tailscale status --json` → peer online | Abort / rollback |
| 3 | `gatus_all_healthy` | Gatus API: all sancta-choir endpoints healthy | Abort / rollback |
| 4 | `rollback_functional` | `nix-env --list-generations` ≥ 3 on target | Abort (pre-flight only) |
| 5 | `tripwire_running` | `systemctl is-active nemesis-tripwire` on rpi5 | Abort (pre-flight only) |
| 6 | `auditor_integrity` | SHA256 of `change-auditor.py` matches Nix store | Abort |

`invariant-checker.py` is built as an **immutable Nix derivation** —
its content is fixed at deploy time and cannot be modified by the Nemesis
user at runtime. The tripwire also uses a subset of these checks
(1, 2, 3) for its continuous monitoring loop.

---

## Implementation Phases

| Phase | Weeks | Summary |
|-------|-------|---------|
| 0 | 1–2 | Remote observer only (SSH metrics + Gatus) |
| 1 | 3–4 | CC planning (proposals reviewed by human) |
| 2 | 5–6 | Actuator + manual approval (remote nixos-rebuild) |
| 3 | 7–8 | CUSUM + tripwire (event-driven, safety monitor) |
| 4 | 9–10 | Tier 1 autonomy (exploration budget, retrospective) |
| 5 | 11–12 | Learning validation (RAG A/B, consolidation, meta-review) |
| 6 | 13–14 | Tier 2 expansion (service + kernel options) |
| 7 | 15+ | Meta-proposals (Tier 1 bound changes via draft PR) |

### Phase 0 — Remote Observer Only (Weeks 1–2)

**Goal:** Collect sancta-choir metrics from rpi5. No changes to either host.

1. Create `modules/services/nemesis.nix` (observer-only mode)
2. Implement `collect-remote.sh` (SSH metric collection)
3. Define SQLite schema; apply on rpi5
4. Implement collector service + 2m timer
5. Expose health HTTP endpoint on `127.0.0.1:9095`
6. Add Gatus endpoint for nemesis-collector on rpi5
7. Deploy and run for 7 days

**Deliverable:** 7 days of sancta-choir metrics on rpi5. Confirmed SSH
collection and Gatus integration. Baseline for CUSUM calibration.

**Validation:**
```bash
sqlite3 /var/lib/nemesis/metrics.db \
  "SELECT service, AVG(memory_bytes/1048576.0) AS avg_mb, AVG(psi_mem_some)
   FROM service_metrics WHERE collected_at > datetime('now','-7 days')
   GROUP BY service;"
```

---

### Phase 1 — Planning (Weeks 3–4)

**Goal:** CC produces proposals for sancta-choir; human reviews, no auto-apply.

1. Create `task-template.md` and `system-prompt.txt`
2. Implement task file generator (inject snapshot + Qdrant RAG + `nix eval`)
3. Implement `nemesis-planner.service` calling `claude -p`
4. CC `allowedTools`: `Read,Glob,Grep,Bash(nix eval *),Write`
5. 72h fallback timer (no CUSUM yet)
6. Proposals written to `/var/lib/nemesis/proposals/`; human reviews manually
7. Self-profile generator produces `self-profile.json`, injected into task
   file as `<self_profile>` section (option frequency, success rates,
   unexplored options)
8. Gate failure embedding (Feedback Loop #1): rejected proposals embedded
   in Qdrant as `GATE_REJECTED` vectors for future planning context
9. OAuth token expiry detection (Feedback Loop #9): planner distinguishes
   auth errors from planning failures, does not increment failure counter

**Deliverable:** 5 proposals reviewed. Overlay files syntactically valid,
targeting sancta-choir options correctly.

---

### Phase 2 — Actuator + Manual Approval (Weeks 5–6)

**Goal:** Full pipeline including remote nixos-rebuild. Human approves each switch.

1. Implement `change-auditor.py` and `property-tests.py` as Nix derivations
2. Implement `nemesis-actuator` shell script (all 16 steps including SSH)
3. Set up sancta-choir nixos-config clone at `/var/lib/nemesis/nixos-config`
4. Provision Nemesis SSH key (add to sancta-choir's `authorized_keys`)
5. Approval token mechanism: actuator pauses at Step 13 (before `nixos-rebuild test`)
6. **Deliberately test rollback:** force a Gate 5 failure, verify sancta-choir
   returns to previous generation
7. Implement Qdrant outcome embedding
8. Invariant checker runs at pre-flight (after Step 8) and post-verification
   (after Step 14) — all 6 checks must pass
9. Evaluation constitution Nix options defined (`services.nemesis.evaluation.*`)
10. Evaluated-value verification (Feedback Loop #2): `nix eval` checks on
    critical options after overlay application (Step 9a)
11. Verification grace period (Feedback Loop #3): 30s unscored window after
    `nixos-rebuild test` to absorb sshd restart transients
12. Git branch cleanup on rollback (Feedback Loop #7): delete stale
    `nemesis/<id>` remote branches on failure
13. Nix store GC on target (Feedback Loop #10): daily remote
    `nix-collect-garbage --delete-older-than 14d` added to cleanup timer

**Deliverable:** End-to-end pipeline confirmed. Remote rollback verified.

**Validation:**
```bash
# On rpi5, after a forced rollback:
ssh root@sancta-choir \
  "nix-env --list-generations -p /nix/var/nix/profiles/system | tail -3"
```

---

### Phase 3 — CUSUM + Tripwire (Weeks 7–8)

**Goal:** Event-driven triggering; independent safety monitor targeting sancta-choir.

1. Implement `nemesis-cusum-watchdog.service` (watches SSH-collected PSI/memory)
2. Implement `nemesis-anomaly-watcher.service` (Gatus failures + SSH OOM scan)
3. Implement `nemesis-planner.path` on `triggers/` directory
4. Implement `nemesis-tripwire.service`:
   - SSH probe + Tailscale check + Gatus for sancta-choir
   - On violation: rollback cascade (Tailscale SSH → public IP SSH → Hetzner API reboot)
5. Confirm tripwire fires independently even when Nemesis main service is stopped
6. Tripwire uses `invariant-checker.py` with subset checks (1, 2, 3) for its
   continuous monitoring loop
7. Collection staleness detection (Feedback Loop #6): planner injects
   `<stale_data_warning>` when metrics are >10m old
8. Planner serialization lock (Feedback Loop #8): `flock` prevents concurrent
   planner/actuator instances from CUSUM + anomaly watcher races

---

### Phase 4 — Tier 1 Autonomy (Weeks 9–10)

**Goal:** openclaw-task-runner resource limits adjusted fully autonomously.

1. Remove human approval gate for `autonomous` auditor verdict
2. Enable `limits.maxSwitchesPerDay = 3`
3. Implement circuit breaker (consecutive failure counter)
4. Tune CUSUM thresholds from Phase 0 baseline
5. Deploy and monitor for one week
6. Exploration budget enabled (every 5th cycle uses `task-template-explore.md`)
7. Persistent retrospective timer (Feedback Loop #4): replace transient
   `systemd-run --on-active=24h` with `nemesis-retrospective-check.timer`
   (hourly, `Persistent=true`) that processes pending retrospective entries
8. Bound saturation alerting (Feedback Loop #5): `meta-review.py` tracks
   how close proposals get to Tier 1 ceilings; >60% saturation triggers
   a draft PR proposing bound expansion

**Acceptance criteria:**
- ≥ 3 autonomous remote switches with PSI improvement confirmed
- No unexpected rollback
- Tripwire never fired spuriously
- Circuit breaker not tripped

---

### Phase 5 — Learning Validation (Weeks 11–12)

**Goal:** Confirm Qdrant RAG improves proposal quality for remote targets.

1. A/B test: 5 cycles with RAG disabled vs 5 with RAG enabled
2. Compare gate failure rate and verification pass rate
3. Implement semantic rollback analysis (lessons-learned embedding)
4. Add property test predicates from any Phase 2–4 rollback incidents
5. `retrospective.py` fully deployed — 24h delayed evaluation per episode
6. Memory consolidator (`nemesis-consolidation.timer`) — weekly episode grouping
7. Meta-review (`nemesis-meta-review.timer`) — bi-weekly statistics + reports

---

### Phase 6 — Tier 2 Expansion (Week 13+)

**Goal:** Expand to service-specific and kernel options on sancta-choir.

1. n8n approval workflow for Tier 2 proposals
2. Add `services.openclaw.*` and `boot.kernel.sysctl` options
3. `expected_outcome` verification (predicted metric delta confirmed in window)

---

### Phase 7 — Meta-Proposals (Week 15+)

**Goal:** Close the reflexive loop — Nemesis proposes changes to its own
operational bounds, always through a human gate.

1. Extend `meta-review.py` to generate concrete Nix overlay fragments
   proposing Tier 1 bound changes (e.g., raising `MemoryMax` ceiling from
   3G to 3.5G) when bound saturation exceeds 60%
2. Proposals are always created as draft PRs:
   `gh pr create --draft --label nemesis-meta`
3. The change auditor's `SUPERVISED` patterns match `nemesis*.nix`, blocking
   any auto-apply — meta-proposals always require human review
4. Meta-review statistics are embedded in the draft PR description for
   context (saturation %, affected options, historical trend)

**Acceptance criteria:**
- Meta-review generates ≥ 1 bound-expansion draft PR
- Draft PR is well-formed (valid Nix, correct option paths)
- Change auditor correctly blocks auto-application
- Human can merge or close with full context from the PR body

**Note:** The reflexive loop is intentionally shallow — Nemesis can propose
changes to Tier 1 bounds only, never to the change auditor, invariant
checker, evaluation constitution, or its own module structure. These
remain stratum 0 (human-only).

---

## Open Questions for Implementation

1. **SSH key provisioning:** The `nemesis-ssh-key` secret must be added to
   `secrets/secrets.nix` and `sancta-choir/configuration.nix`
   (`authorized_keys`). This bootstrapping step is Tier 3 (requires a
   human-reviewed PR). Must be done before Phase 2.

2. **~~Pro subscription OAuth flow headless~~ (Resolved):** Use
   `claude setup-token` on a browser-equipped machine to produce a 1-year
   `CLAUDE_CODE_OAUTH_TOKEN`. Encrypt as `nemesis-oauth-token.age` and
   provision via the standard agenix `ExecStartPre "+"` pattern. No
   `CLAUDE_CONFIG_DIR` sharing needed — the token is an env var, not a
   file tree. Renewal: annual re-run of `claude setup-token` + `agenix -e`.
   See "Pro subscription auth" in Key Design Decisions for full details.

3. **Embedding model on rpi5:** Ollama is not currently deployed on rpi5.
   Options: (a) add a `services.ollama` module to rpi5-full and pull
   `nomic-embed-text` (~274MB RAM on 4GB device), (b) use OpenRouter's
   embedding API via the existing Open-WebUI connection (small per-token
   cost), (c) use a smaller model like `all-minilm-l6-v2` (~80MB).
   Decision needed before Phase 1 (RAG pipeline).

4. **agent-overlays directory import:** `imports = [ ./agent-overlays ]`
   requires a `default.nix` in that directory. The actuator manages
   `default.nix`, adding a new import line for each overlay. This is the
   simplest pattern and keeps `configuration.nix` unchanged.

5. **CUSUM μ₀ calibration:** A one-time calibration script computes μ₀ ±2σ
   from Phase 0 data. Run after 7 days of collection before activating CUSUM.

6. **`nixos-rebuild test` on sancta-choir via SSH:** `nixos-rebuild test`
   may restart `sshd.service` during activation if the sshd configuration
   changed, which kills the parent SSH connection. For Tier 1 changes
   (resource limits on non-sshd services), sshd typically survives. Use
   `systemd-run` as defensive practice to detach the
   rebuild from the SSH session:
   ```bash
   ssh root@sancta-choir \
     "systemd-run --unit=nemesis-rebuild --no-block \
      nixos-rebuild test --flake /var/lib/nemesis/nixos-config#sancta-choir"
   ```
   **Important:** Do NOT use `--scope` — scope units inherit the SSH
   session's cgroup and are killed when SSH disconnects, defeating the
   purpose. Without `--scope`, `systemd-run` creates a transient service
   unit that survives the session. Apply this pattern consistently to
   all remote `nixos-rebuild` commands: `test`, `switch`, and
   `switch --rollback` (including in the tripwire rollback cascade).
   The actuator polls for completion via a separate SSH probe:
   `ssh root@sancta-choir "systemctl is-active nemesis-rebuild.service"`

---

## Success Criteria

- [ ] Phase 0: 7 days continuous sancta-choir metrics, no collection gaps > 5min
- [ ] Phase 1: CC produces valid sancta-choir overlay files in ≥ 4/5 cycles
- [ ] Phase 2: Remote rollback verified; sancta-choir returns to previous generation
- [ ] Phase 3: CUSUM fires on a deliberate SSH-injected PSI spike within 3 minutes
- [ ] Phase 4: ≥ 3 autonomous remote switches with confirmed metric improvement
- [ ] Phase 5: RAG retrieval demonstrably improves gate-pass rate (A/B documented)
- [ ] Phase 6: One Tier 2 change applied via n8n approval on sancta-choir
- [ ] Phase 7: Meta-review generates ≥1 bound-expansion draft PR; human reviews

### Feedback Loop Validation

- [ ] Loop #1: Gate failures produce Qdrant vectors retrievable by future planning cycles
- [ ] Loop #2: `nix eval` verification catches at least one regex-bypassing value in testing
- [ ] Loop #3: Grace period prevents false rollbacks during sshd restart transient
- [ ] Loop #4: Retrospective fires correctly after rpi5 reboot (persistent timer)
- [ ] Loop #7: No stale `nemesis/*` branches older than 7 days on GitHub
- [ ] Loop #8: Concurrent CUSUM + anomaly triggers produce exactly one planner run
- [ ] Loop #9: Expired OAuth token triggers alert, not circuit breaker
- [ ] Loop #10: `/nix/store` on sancta-choir does not grow unboundedly (14d GC verified)

---

## References

- Research proposals: synthesized from 4 independent agent analyses (2026-02-21)
- Key primitives: `nixos-rebuild test` (`nixos-rebuild(8)` man page), CUSUM (Page 1954)
- Prior art: `modules/services/openclaw.nix`, `modules/services/gatus.nix`,
  `modules/services/qdrant.nix`
- sancta-choir current config: `hosts/sancta-choir/configuration.nix`
