# Kuzea: Self-Evolving NixOS Agent

**Status:** Design / Pre-implementation
**Controller host:** `rpi5-full` (aarch64-linux, Raspberry Pi 5)
**Target host:** `sancta-choir` (x86_64-linux, Hetzner VPS — 4GB RAM, 2 vCPU, 2GB swap)
**Brain:** Claude Code CLI via Claude Pro subscription (no API key billing)

---

## Overview

Kuzea is a closed-loop agent that runs on the Raspberry Pi 5 and manages
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
Kuzea builds on this existing infrastructure — adding a dedicated
`kuzea` user, `claude -p` task runner, and SSH-based metric collection
— rather than installing a new agent on Hetzner.

**Core safety property:** NixOS generations are immutable, content-addressed
store paths. `nixos-rebuild test` on sancta-choir activates a generation
without making it the default boot entry — a reboot or explicit rollback
returns to the previous state. Kuzea exploits this as its primary safety
primitive: nothing on sancta-choir is permanent until rpi5's 10-minute
external verification window passes without incident.

**Why Claude Code as brain:** rpi5 already has the Claude Code CLI installed.
Kuzea invokes `claude -p` under a dedicated `kuzea` user with Pro/Max
subscription auth via `CLAUDE_CODE_OAUTH_TOKEN` (provisioned through
agenix) — no per-token billing, natural rate limiting, and full CC tool
execution. CC reads the repo, inspects the
target's current options, and writes an overlay — without a custom
tool-calling harness. The invocation pattern is modeled on the existing
OpenClaw task runner (`modules/services/openclaw.nix`).

---

## Prerequisites

The following must be completed before Kuzea implementation begins:

1. **Deploy OpenClaw on sancta-choir** (Tier 3, human PR) — Enable
   `services.openclaw` on sancta-choir via `modules/services/openclaw.nix`.
   This creates the `openclaw-task-runner.service` systemd unit that Kuzea
   will manage. Currently, sancta-choir only has the Claude Code CLI binary
   installed (no long-running service). The nix-openclaw Home Manager
   integration is disabled due to upstream bugs; use the existing NixOS
   module instead.

2. **Choose and deploy an embedding backend** (Phase 1 dependency) — Ollama
   is not currently deployed on rpi5. Open-WebUI uses OpenRouter, not local
   inference. Options: install Ollama with a small embedding model, use
   OpenRouter's embedding API, or defer RAG to Phase 5.

3. **Provision Kuzea SSH key** (Tier 3, human PR) — Add
   `kuzea-ssh-key.age` to `secrets/secrets.nix` and sancta-choir's
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
│  │  kuzea-collector           │  │──────────────────────►  │  nixos-rebuild (native x86)  │
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
│  │  Kuzea brain               │  │
│  │  (CC planning, actuator,     │  │
│  │   tripwire, RAG memory)      │  │
│  └──────────────────────────────┘  │
└────────────────────────────────────┘
```

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                    KUZEA  (runs entirely on rpi5)                  │
│                                                                      │
│  OBSERVE LAYER                                                       │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  kuzea-collector (2m timer)                               │    │
│  │    SSH → sancta-choir:                                      │    │
│  │      systemctl show --value -p MemoryCurrent <svc>          │    │
│  │      cat /proc/pressure/memory                              │    │
│  │      journalctl --since "3m ago" --output json              │    │
│  │    Local Gatus REST API (http://127.0.0.1:3001) for         │    │
│  │      sancta-choir service health (external vantage)         │    │
│  │    → SQLite /var/lib/kuzea/metrics.db                     │    │
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
│  │    → /var/lib/kuzea/tasks/<id>.md                         │    │
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
│  │    Gate 3: nix flake check (eval only, not build)     ~10s  │    │
│  │    Gate 4: property test suite on evaluated config     ~5s  │    │
│  │    Gate 5: change auditor verdict                      ~1s  │    │
│  │                                                             │    │
│  │  REMOTE (SSH to sancta-choir):                              │    │
│  │    Gate 6: nixos-rebuild build --flake .#sancta-choir ~5min │    │
│  │    nixos-rebuild test  (activate, not boot-default)         │    │
│  │    10min verification: 20 cycles × 30s                       │    │
│  │      Gatus probe (5s timeout) + SSH probe (10s timeout)     │    │
│  │      pass +1 · fail/timeout −3 · min 15/20 recorded cycles  │    │
│  │    pass → nixos-rebuild switch + git push + PR              │    │
│  │    fail → rollback cascade (SSH→public IP→Hetzner reset)  │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                                                                      │
│  SAFETY LAYER (separate unit, rpi5 — Kuzea cannot stop it)        │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  kuzea-tripwire  (PartOf nothing, Restart=always)         │    │
│  │    every 10s: SSH probe · tailscale status · Gatus          │    │
│  │    on violation during test window — rollback cascade:       │    │
│  │      1. SSH over Tailscale → nixos-rebuild switch --rollback│    │
│  │      2. SSH over public IP → same                           │    │
│  │      3. Hetzner API hard reset (boot-default = last switch)     │    │
│  └─────────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Key Design Decisions

### rpi5 as external watcher — why this is stronger than self-monitoring

When a service on sancta-choir crashes badly enough to make the host
unresponsive, any monitoring process *on* sancta-choir is also broken.
rpi5's Gatus sees the failure from outside via Tailscale and can trigger
Kuzea independently. This is the same reason a production monitoring stack
lives on separate infrastructure from what it monitors.

Concretely: rpi5's Gatus already sends HTTP probes to sancta-choir's
exposed endpoints. Kuzea extends this by also collecting internal metrics
(PSI, cgroup data) via SSH, giving both external and internal perspectives.

### Remote build strategy — no cross-compilation

rpi5 is aarch64 and sancta-choir is x86_64. Cross-compilation is complex
and slow. Instead, the actuator SSHes into sancta-choir and runs
`nixos-rebuild` natively there. **Note:** Gate 3 (`nix flake check`) runs
locally on rpi5 — this catches Nix evaluation errors but will **not**
catch build failures that manifest only on x86_64. Gate 6 (the remote
`nixos-rebuild build`) is the real build barrier:

```bash
# Fetch and checkout on sancta-choir (git -C avoids compound shell commands
# through the SSH wrapper — exec cannot re-parse && operators)
ssh root@sancta-choir "git -C /var/lib/kuzea/nixos-config fetch origin"
ssh root@sancta-choir "git -C /var/lib/kuzea/nixos-config checkout kuzea/<id>"

# Build on sancta-choir (x86_64 native, exact flake path)
ssh root@sancta-choir \
  "nixos-rebuild build --flake /var/lib/kuzea/nixos-config#sancta-choir"

# Test-activate via systemd-run (survives SSH disconnect if sshd restarts)
ssh root@sancta-choir \
  "systemd-run --unit=kuzea-rebuild --no-block \
   nixos-rebuild test --flake /var/lib/kuzea/nixos-config#sancta-choir"
# Poll completion separately:
ssh root@sancta-choir "systemctl is-active kuzea-rebuild.service"

# Permanent switch (after verification passes)
ssh root@sancta-choir \
  "nixos-rebuild switch --flake /var/lib/kuzea/nixos-config#sancta-choir"

# Rollback (if verification fails or tripwire fires)
ssh root@sancta-choir "nixos-rebuild switch --rollback"
```

sancta-choir maintains its own clone of the nixos-config repo at
`/var/lib/kuzea/nixos-config` for this purpose.

### Overlay modules (not text patches)

All agent-generated changes live in `hosts/sancta-choir/agent-overlays/`.
The agent writes a new `.nix` file; `default.nix` auto-imports all sibling
`.nix` files via `builtins.readDir` — no manual index management needed.
The original modules are **never modified**. Reverting a change means
removing one file — the known-good state is structurally preserved.

```
hosts/sancta-choir/
  configuration.nix              ← human-authored, never touched by Kuzea
  agent-overlays/
    default.nix                  ← auto-imports all *.nix siblings
    20260221-143000-claude-mem.nix   ← CC writes here only
```

Bootstrap `default.nix` (committed to git, never modified by the actuator):
```nix
# hosts/sancta-choir/agent-overlays/default.nix
# Auto-import all Kuzea overlay files in this directory.
# The actuator adds/removes overlay .nix files; this file is never edited.
{ lib, ... }: {
  imports =
    let
      entries = builtins.readDir ./.;
      nixFiles = lib.filterAttrs
        (name: type: type == "regular" && lib.hasSuffix ".nix" name && name != "default.nix")
        entries;
    in
    map (name: ./. + "/${name}") (builtins.attrNames nixFiles);
}
```

Example overlay:
```nix
# hosts/sancta-choir/agent-overlays/20260221-143000-openclaw-mem.nix
# Kuzea overlay — goal: reduce OpenClaw task runner OOM restarts
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
  `/var/lib/kuzea/proposals/`

CC is **not** given: `Edit`, `Bash(nixos-rebuild *)`, `Bash(git *)`,
`Bash(ssh *)`, `Bash(curl *)`. All remote operations go through the
actuator shell script, which is deterministic and auditable.

**Security boundary for Write:** The `--allowedTools Write` flag has no
path qualifier — CC's `Write` tool can write to any path the `kuzea` OS
user can access. The actual write restriction is enforced at the OS level:
the `kuzea` user must not have write access to `hosts/rpi5-full/`,
`modules/`, or other sensitive repo paths. If CC writes outside
`agent-overlays/`, the actuator's Step 2 rejects the proposal, and the
actuator cleans up unexpected files in the working tree after each episode.

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
`/var/lib/kuzea/cusum-params.json` before enabling Phase 3.

**Time-of-day bucketing:** Memory pressure on an LLM task runner VPS
likely follows a daily pattern (higher during business hours). CUSUM
assumes a stationary process; a seasonal mean will produce persistently
high S_t during peak hours, triggering false `REGIME_CHANGE` events.
Phase 0 calibration should compute separate μ₀ values for 4-hour time
buckets (or verify the 7-day baseline captures enough daily cycles to
produce a robust single μ₀).

Scheduled fallback: if no regime change fires in 72 hours, run a routine
health-check cycle (re-run the planner to produce a proposal). The 72h
fallback is distinct from the CUSUM trigger — it ensures the planner
runs at least once every 3 days even if metrics are stable.

### Exploration Policy

Every 5th planning cycle uses an alternative task template
(`task-template-explore.md`) that instructs CC to propose something outside
its recent pattern — e.g., tuning a metric it has never touched, or
revisiting a previously-rolled-back change with a different approach.

- Counter file: `/var/lib/kuzea/exploration-counter` (incremented by planner)
- Exploration proposals include `"exploration": true` in the proposal JSON
- Exploration cycles get a 15-minute verification window (vs 10 minutes)
  to allow for less predictable behavior to stabilize
- The alternative template omits `SUCCESS` outcomes from `<past_outcomes>`
  to reduce anchoring bias, but **retains `ROLLBACK` outcomes** — failure
  memory is the most important signal to avoid re-proposing failed approaches

### Separate tripwire (rpi5-local, monitors sancta-choir)

`kuzea-tripwire.service` is a separate systemd unit with no `PartOf`,
`BoundBy`, or `WantedBy` links to the main Kuzea service. It cannot be
stopped by the Kuzea user. It polls:
- `ssh root@sancta-choir true` — TCP connectivity (10s timeout)
- `tailscale status --json | jq '.Peer["<sancta-choir-node-id>"].Online'`
- Gatus health endpoint for sancta-choir services (from rpi5)

On violation during an active test window (detected by the presence of
`/var/lib/kuzea/test-window-active`), the tripwire executes a
**rollback cascade** — each channel is tried in order until one succeeds.

**test-window-active format:** The file contains `<episode-id> <expiry-epoch>`.
The tripwire reads the expiry timestamp and ignores the file if expired
(prevents stale windows from triggering rollbacks after a crash).
`kuzea-cleanup.timer` also garbage-collects stale `test-window-active`
files older than `verificationWindowSeconds + 300s` as a safety net:

```bash
# Channel 1: SSH over Tailscale (normal path)
if ssh -o ConnectTimeout=10 root@sancta-choir.tail4249a9.ts.net \
     "nixos-rebuild switch --rollback"; then
  logger -t kuzea-tripwire "Rollback succeeded via Tailscale SSH"
  exit 0
fi

# Channel 2: SSH over public IPv4 (Tailscale may be down)
if ssh -o ConnectTimeout=10 root@<sancta-choir-public-ip> \
     "nixos-rebuild switch --rollback"; then
  logger -t kuzea-tripwire "Rollback succeeded via public IP SSH"
  exit 0
fi

# Channel 3: Hetzner API hard reset (last resort — safe because
# nixos-rebuild test does NOT set the boot default; reboot recovers
# to the last nixos-rebuild switch generation)
# Uses 'reset' (hard power cycle) not 'reboot' (ACPI soft signal),
# because if the kernel is stuck (OOM, panic), soft reboot won't work.
if hcloud server reset <sancta-choir-server-id>; then
  logger -t kuzea-tripwire -p daemon.crit \
    "Forced Hetzner hard reset — SSH unreachable, recovering via boot default"
  exit 0
fi

# All channels failed — alert loudly
logger -t kuzea-tripwire -p daemon.emerg \
  "ALL ROLLBACK CHANNELS FAILED — sancta-choir stuck on test generation"
# Notify n8n webhook regardless of file I/O success
curl -sf -X POST "${N8N_WEBHOOK}" \
  -H 'Content-Type: application/json' \
  -d '{"event":"rollback_failed","severity":"critical"}' || true
```

**Why three channels:** The tripwire's SSH probe may detect that
Tailscale SSH is down — the same path it would use for rollback. A
public-IP fallback bypasses Tailscale. If sshd itself is broken (e.g.,
the tested generation changed sshd config), a Hetzner API hard reset is the
ultimate recovery — `nixos-rebuild test` deliberately does not set the
boot default, so a reboot always returns to the last `switch` generation.

**Hetzner API prerequisite:** Requires `hcloud` CLI and an API token
(stored as `kuzea-hcloud-token.age`). This is a Phase 3 addition.

### Pro subscription auth (setup-token + agenix)

Kuzea authenticates `claude` CLI via the `CLAUDE_CODE_OAUTH_TOKEN`
environment variable, **not** interactive `claude auth login` (which
requires a browser redirect and produces short-lived tokens with unreliable
auto-refresh).

**Provisioning flow (one-time, on a machine with a browser):**

1. Run `claude setup-token` — this opens a browser OAuth flow and produces
   a long-lived (1-year) token: `sk-ant-oat01-...`
2. Encrypt the token: `cd secrets && agenix -e kuzea-oauth-token.age`
3. The `kuzea-planner.service` uses the standard agenix `ExecStartPre "+"`
   pattern to read the secret and export it as `CLAUDE_CODE_OAUTH_TOKEN`:

```bash
# ExecStartPre "+" (runs as root, reads agenix secret)
# ENV_FILE lives on tmpfs (/run/kuzea/) — not recoverable after service stop
ENV_FILE="/run/kuzea/planner.env"
mkdir -p /run/kuzea
OAUTH_TOKEN=$(cat "${cfg.oauthTokenFile}")
install -m 0600 -o kuzea -g kuzea /dev/null "$ENV_FILE"
cat > "$ENV_FILE" <<ENVEOF
CLAUDE_CODE_OAUTH_TOKEN=$OAUTH_TOKEN
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
ENVEOF
# DISABLE_NONESSENTIAL_TRAFFIC prevents update checks, telemetry, and
# other outbound traffic beyond api.anthropic.com in the headless context.
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

**Token expiry handling:** `kuzea-planner.service` captures CC's exit
code and distinguishes auth errors (exit code 1 with "authentication"
or "token" in stderr) from planning failures. Auth errors do **not**
increment the consecutive-failure counter (to avoid tripping the circuit
breaker on an expired token). On auth error, the service:
1. Logs `daemon.crit`
2. Writes `/var/lib/kuzea/auth-expired` flag file (exposed by the
   health endpoint as `"auth_expired": true` — gives Gatus a second
   notification channel independent of n8n availability)
3. Notifies the n8n webhook with `{"event":"auth_expired","severity":"high"}`

Renewal requires a human to re-run `claude setup-token` +
`agenix -e kuzea-oauth-token.age`, then `rm /var/lib/kuzea/auth-expired`.

**Verify `claude setup-token` exists:** Before Phase 1, confirm the
`claude setup-token` subcommand is available in the installed CC version.
If it does not exist, the fallback is to use `ANTHROPIC_API_KEY` via
the existing `anthropic-api-key.age` secret (per-token billing instead
of subscription).

### Evaluation Constitution

The evaluation criteria for each planning cycle are defined as **stratum 0**
Nix options — the hardest layer to change, requiring a Tier 3 human PR:

```nix
options.services.kuzea.evaluation = {
  primaryMetric = mkOption {
    type    = types.str;
    default = "psi_mem_some_avg60";
    description = "The metric Kuzea optimizes for on the target.";
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
requires a human PR — Kuzea cannot redefine its own success function.

**24h Retrospective Check:** After each successful `nixos-rebuild switch`,
the actuator writes a timestamp file:
`echo "<episode-id> <switch-epoch>" >> /var/lib/kuzea/pending-retrospectives`.
A persistent `kuzea-retrospective-poll.timer` checks this file every hour
and fires `kuzea-retrospective@<episode-id>.service` for entries whose
switch timestamp is ≥24h ago. This approach survives rpi5 reboots (unlike
transient `systemd-run --on-active=24h`, which is lost on reboot).

The retrospective compares the primary metric's 24h post-switch average
against the pre-switch baseline. If the metric degraded beyond
`minimumEffect`, a "delayed negative" vector is embedded in Qdrant with
`{"delayed_negative": true}`, overriding the original `SUCCESS` outcome.
This catches slow-onset regressions that pass the 10-minute verification
window. Processed entries are removed from `pending-retrospectives`.

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
generation, not the tested one). Such options (e.g., `swapDevices[].size`)
must be at least Tier 2 and require a separate verification flow.

### Tier 2 — Supervised (approval token before remote switch)

- `swapDevices[].size` — ±512MB (requires reboot; incompatible with autonomous test window)
- `services.openclaw.*` service-level options
- `boot.kernel.sysctl` memory/networking parameters
- Adding a new service module already present in `modules/services/`
- Package version pins for non-critical tools

### Tier 3 — Human PR only (Kuzea creates draft, does not apply)

- `modules/services/kuzea*.nix` — own config
- `networking.nftables.*`, `security.sudo.*`
- `flake.nix`, `flake.lock`
- `secrets/`, `age.secrets.*`
- `.github/workflows/`
- SSH authorized keys, user definitions, boot loader config

---

## New Files and Modules

```
modules/services/
  kuzea.nix                  ← Main NixOS module on rpi5 (options + units)
  kuzea-collector.nix        ← Observer: SSH-collects metrics from sancta-choir
  kuzea-actuator.nix         ← Actuator: 6-gate pipeline + remote switch

modules/services/kuzea/
  change-auditor.py            ← Immutable auditor (Nix derivation)
  property-tests.py            ← Evaluated config property suite for sancta-choir
  task-template.md             ← CC task file template
  system-prompt.txt            ← CC system prompt (Nix store, immutable)
  collect-remote.sh            ← SSH metric collection script
  self-profile-generator.py    ← Generates self-profile.json for task context
  invariant-checker.py         ← Verifies 6 identity invariants (immutable derivation)
  retrospective.py             ← 24h delayed outcome evaluator
  task-template-explore.md     ← Alternative CC template for exploration cycles
  memory-consolidator.py       ← Weekly episode consolidation + archival
  meta-review.py               ← Bi-weekly meta-analysis of Kuzea performance

hosts/sancta-choir/
  configuration.nix            ← + kuzea repo clone setup
  agent-overlays/
    default.nix                ← auto-imports all *.nix siblings via builtins.readDir

docs/
  kuzea-plan.md              ← This file
```

### `modules/services/kuzea.nix` — key options

```nix
options.services.kuzea = {
  enable = mkEnableOption "Kuzea self-evolving NixOS agent (controller on rpi5)";

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
    default = "/var/lib/kuzea/nixos-config";
    description = "Path to nixos-config clone on the target host.";
  };

  sshKeyFile = mkOption {
    type    = types.path;
    description = "SSH private key (agenix) for kuzea user to reach target.";
  };

  planningIntervalHours = mkOption {
    type    = types.int;
    default = 72;
    description = "Fallback scheduled cycle if CUSUM never fires.";
  };

  verificationWindowSeconds = mkOption {
    type    = types.int;
    default = 600;
    description = "Duration of the post-activation verification window in seconds. 20 probe cycles at 30s intervals.";
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
    description = "systemd service names on target Kuzea may adjust autonomously.";
  };

  notifications.n8nWebhookUrl = mkOption {
    type    = types.nullOr types.str;
    default = null;
  };

  oauthTokenFile = mkOption {
    type    = types.path;
    description = "Path to file containing CLAUDE_CODE_OAUTH_TOKEN (agenix).";
  };

  limits.maxSwitchesPerDay  = mkOption {
    type = types.int; default = 3;
    description = "Maximum nixos-rebuild switch operations per UTC day. Checked against a rolling SQLite count in the episodes table. Excess triggers are deferred, not dropped.";
  };
  limits.maxConsecutiveFails = mkOption {
    type = types.int; default = 3;
    description = "Consecutive rollbacks before the circuit breaker trips. Tracked by a counter in /var/lib/kuzea/consecutive-failures (reset to 0 on any success).";
  };
};
```

---

## Systemd Units (all on rpi5)

| Unit | Type | Purpose |
|------|------|---------|
| `kuzea-schema-init.service` | oneshot/boot | Apply SQLite schema |
| `kuzea-collector.service` | oneshot | SSH-collect metrics from sancta-choir |
| `kuzea-collector.timer` | timer/2m | Drive collector |
| `kuzea-cusum-watchdog.service` | simple | Continuous CUSUM; writes trigger file on regime shift |
| `kuzea-anomaly-watcher.service` | simple | Gatus failures + SSH OOM scan; writes trigger file |
| `kuzea-planner.service` | oneshot | Build task file, run `claude -p` (flock serialized) |
| `kuzea-planner.path` | path | Watch `/var/lib/kuzea/triggers/` for new trigger files |
| `kuzea-actuator@.service` | oneshot/template | Six-gate pipeline for one proposal |
| `kuzea-tripwire.service` | simple | External safety monitor; remote rollback |
| `kuzea-health.service` | simple | Serve /var/lib/kuzea/health.json on 127.0.0.1:9095 |
| `kuzea-cleanup.timer` | timer/daily | Prune old proposals, episodes, and stale remote branches |
| `kuzea-retrospective-poll.timer` | timer/1h | Check pending-retrospectives for due entries |
| `kuzea-retrospective@.service` | oneshot/template | 24h delayed metric comparison per episode |
| `kuzea-consolidation.timer` | timer/weekly | Trigger memory-consolidator.py |
| `kuzea-consolidation.service` | oneshot | Weekly episode consolidation + archival |
| `kuzea-meta-review.timer` | timer/bi-weekly | 1st and 15th of month meta-analysis |
| `kuzea-meta-review.service` | oneshot | Compute statistics + generate report |

### RAM Budget

All Kuzea scripts are oneshot services; they do not consume memory
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
oneshot). The rpi5 has 4 GB RAM with zram; Kuzea is well within budget.

---

## Data Stores

### SQLite: `/var/lib/kuzea/metrics.db` (on rpi5)

```sql
-- Enable WAL mode for concurrent reads + one writer without SQLITE_BUSY.
-- The collector (2m timer), CUSUM watchdog (continuous), and anomaly watcher
-- (continuous) all access this database concurrently.
PRAGMA journal_mode=WAL;

CREATE INDEX IF NOT EXISTS idx_observations_collected_at
  ON observations(collected_at);

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

### Qdrant: collection `kuzea-outcomes` (on rpi5, existing instance)

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

**Phase 1 RAG dependency:** The task file generator injects
`<past_outcomes>` from Qdrant RAG. Without an embedding backend, the RAG
section returns empty results. Phase 1 uses an empty `<past_outcomes>`
placeholder (no embeddings yet — the first episodes generate the initial
data). Full RAG retrieval is validated in Phase 5. If the embedding
backend is not resolved by Phase 5, defer RAG validation and proceed
with empty `<past_outcomes>` throughout.

---

## Remote Metric Collection

The collector SSHes into sancta-choir as `root` (dedicated SSH key in
root's `authorized_keys`). Root access is required because `nixos-rebuild`
and `systemctl show` need it. The key is restricted via `command=` in
`authorized_keys` to a wrapper script that whitelists only the commands
Kuzea needs (see "sancta-choir Host Configuration" section):

```bash
# modules/services/kuzea/collect-remote.sh
set -euo pipefail
TARGET="${1:-sancta-choir}"
SSH="ssh -i /run/kuzea/ssh-key -o ConnectTimeout=10 \
         -o StrictHostKeyChecking=yes \
         -o UserKnownHostsFile=/var/lib/kuzea/known_hosts \
         -o ControlMaster=auto -o ControlPath=/run/kuzea/ssh-%r@%h \
         -o ControlPersist=60 \
         root@${TARGET}.tail4249a9.ts.net"
# known_hosts is pre-populated during Phase 0 setup (one-time ssh-keyscan)
# and stored as an immutable Nix store path. ControlMaster reuses one TCP
# connection across the 4-6 SSH calls per collection cycle (~720 cycles/day).
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
    logger -t kuzea-collector -p daemon.err \
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
  logger -t kuzea-collector -p daemon.warning \
    "Collection cycle completed with ${COLLECT_FAILURES} failures"
fi
# Write failure count to state file for health endpoint
echo "$COLLECT_FAILURES" > /var/lib/kuzea/last-collect-failures
```

Gatus on rpi5 provides the **external** health perspective (HTTP probes
to sancta-choir's Tailscale-exposed endpoints) without any SSH dependency.
Both signals are stored in SQLite and combined in the SystemSnapshot.

---

## Task File Structure (what CC reads on rpi5)

```markdown
# Kuzea Planning Cycle — <timestamp>

## Your Role
You are the reasoning engine for Kuzea. You manage the NixOS configuration
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
2. Proposal JSON (Write tool → /var/lib/kuzea/proposals/<id>.json):
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
[From services.kuzea.evaluation Nix options — primary metric, direction,
 minimum effect size, safety invariants that must hold]
</evaluation_criteria>
```

---

## Actuator Pipeline

All steps run on rpi5. Remote steps are explicit SSH calls.
The **entire pipeline** (planning + actuator, Steps 1–16) runs under
`flock /var/lib/kuzea/actuator.lock` — the planner acquires the lock
before generating the task file and holds it through actuator completion.
This prevents a second trigger from starting a new planning cycle while
the first actuator is mid-flight on sancta-choir.

```
Step 1   Validate proposal JSON schema (rpi5, local)
Step 2   Verify overlay file path is in hosts/sancta-choir/agent-overlays/
         Clean up any unexpected files in working tree from prior episodes
Step 3   Gate 1: nix eval type-check proposed values             (rpi5, ~10ms)
Step 4   Gate 2: nix-instantiate --parse <overlay>               (rpi5, ~50ms)
Step 5   Gate 3: nix flake check (catches eval errors, not build (rpi5, ~10s)
           failures — see Gate 6 for the real build barrier)
Step 6   Gate 4: property test suite against evaluated config    (rpi5, ~5s)
           ("evaluated config" = output of nix eval on the proposed
            NixOS configuration, abbreviated "EC" in this document)
Step 7   Gate 5: change-auditor verdict (regex pre-filter)       (rpi5, ~1s)
         + nix eval checks on critical evaluated option values
           (firewall.enable, openssh.enable, tailscale.enable)
Step 8   Pre-flight:
           rpi5: disk ≥ 1GB free on local clone
           SSH:  df sancta-choir /nix ≥ 5GB free
           SSH:  nix-env --list-generations -p /nix/var/nix/profiles/system | wc -l ≥ 3
           Gatus: sancta-choir services currently healthy
           maxSwitchesPerDay not yet exhausted (check SQLite counter)
Step 9   git add overlay file + git commit (branch kuzea/<id>)   (rpi5)
           (default.nix auto-imports via builtins.readDir, no edit needed)
Step 10  git push to origin                                      (rpi5)
Step 11  SSH: git -C <repo> fetch origin                         (sancta-choir)
         SSH: git -C <repo> checkout kuzea/<id>                  (sancta-choir)
           Retry with 3× 5s backoff if branch not yet propagated
Step 12  Gate 6: SSH: nixos-rebuild build --flake .#sancta-choir (~5min)
           Wall-clock timeout: 20 minutes. If exceeded → abort episode
Step 13  SSH: systemctl reset-failed kuzea-rebuild.service       (sancta-choir)
           (clears stale unit from prior episode if rpi5 rebooted mid-run)
         SSH: systemd-run --unit=kuzea-rebuild --no-block        (sancta-choir)
           nixos-rebuild test --flake .#sancta-choir
         Write active-test-window flag: /var/lib/kuzea/test-window-active
           (includes episode-id and expiry timestamp for crash recovery)
         Poll completion: ssh "systemctl is-active kuzea-rebuild.service"
           with 3× 5s retry on SSH failure (sshd may be restarting)
           30s grace period before scoring begins (sshd restart window)
Step 14  Verification window: 10 minutes (20 probe cycles at 30s intervals)
           each cycle runs two probes from rpi5:
             Gatus HTTP probe: sancta-choir health endpoint (5s timeout)
             SSH probe: ssh -o ConnectTimeout=10 root@sancta-choir true
           probe outcomes (three states, not two):
             pass    → +1 (both probes succeeded)
             fail    → −3 (either probe returned error)
             timeout → −3 (either probe exceeded its timeout — treated as fail)
           scoring: start at 0, abort if score < 0 OR tripwire fires
           minimum probe requirement: at least 15 of 20 cycles must record
             a result (pass or fail). If <15 cycles record results (e.g. due
             to slow timeouts consuming all slots), treat as fail regardless
             of score. A "recorded" cycle is one where the probe returned
             either pass or fail — not one that passed.
           all probe results logged to episode record for post-mortem analysis
Step 15  score passes → SSH: nixos-rebuild switch
                      → remove test-window-active flag
                      → gh pr create (from rpi5, labeled kuzea)
                      → embed SUCCESS in Qdrant (rpi5)
                      → write to pending-retrospectives for 24h delayed check
                      → git push origin --delete kuzea/<id> (cleanup remote branch)
Step 16  score fails  → rollback cascade (Tailscale SSH → public IP → Hetzner reset)
                      → remove test-window-active flag
                      → embed ROLLBACK + lessons-learned in Qdrant (rpi5)
                      → git push origin --delete kuzea/<id> (cleanup remote branch)
                      → git rm overlay file + commit (revert the working tree)
                      → notify n8n (rpi5)
```

**`maxSwitchesPerDay` overflow:** When the daily budget is exhausted,
trigger events are **deferred** (trigger file remains in `triggers/` but
the planner checks the budget before proceeding). The next planning cycle
after UTC midnight processes the backlog. To prevent a trigger thundering
herd after a sustained incident, only the 3 most recent trigger files
are kept — older deferred triggers are discarded by the planner before
processing. If CUSUM fires during a genuine regime shift while the budget
is exhausted, the most recent trigger persists and is acted on the next day.

### Property Test Suite (Gate 4, runs on rpi5 against sancta-choir evaluated config)

```python
# EC = evaluated config (output of nix eval on the NixOS configuration)

def test_no_port_conflicts(ec):
    """No two services bind the same port on sancta-choir."""

def test_ssh_daemon_enabled(ec):
    """services.openssh.enable must remain true (remote access)."""

def test_tailscale_enabled(ec):
    """services.tailscale.enable must remain true."""

def test_openclaw_service_enabled(ec):
    """services.openclaw.enable must remain true."""

def test_memory_limits_within_vps_budget(ec):
    """Sum of MemoryMax < 3.5GB (4GB Hetzner VPS minus 512MB headroom
       for kernel, sshd, and Tailscale overhead)."""

def test_memhigh_lte_memmax(ec):
    """MemoryHigh <= MemoryMax for every service."""

def test_kuzea_config_unchanged(ec):
    """services.kuzea.* on rpi5 unchanged (not in target EC, but check diff)."""

def test_tripwire_unit_unchanged(ec):
    """kuzea-tripwire.service definition unchanged in the diff."""

def test_swap_not_removed(ec):
    """swapDevices list is non-empty (prevents OOM during builds)."""
```

### Change Auditor (Gate 5, immutable derivation on rpi5)

```python
BLOCKED = [
    r"\.github/workflows/",
    r"authorized_keys",
    r"users\.users\.root",
    r"networking\.firewall\.enable\s*=\s*false",
    r"services\.openssh\.enable\s*=\s*false",
    r"services\.tailscale\.enable\s*=\s*false",
    r"networking\.nftables",                        # controls attack surface
    r"systemd\.services\.kuzea-tripwire",           # safety monitor must not be modified
]

# Supplement regex with nix eval checks for critical evaluated values:
# The text-based auditor cannot catch Nix indirection (e.g., variable
# assignment, lib.mkForce, attribute set nesting). After Gate 3 passes,
# the actuator also runs:
#   nix eval .#nixosConfigurations.sancta-choir.config.networking.firewall.enable
#   nix eval .#nixosConfigurations.sancta-choir.config.services.openssh.enable
#   nix eval .#nixosConfigurations.sancta-choir.config.services.tailscale.enable
# These must all return their expected values. This is the actual safety
# net for Tier 1 autonomy — the regex scan is a fast pre-filter.

SUPERVISED = [
    r"modules/services/kuzea",
    r"secrets/secrets\.nix",
    r"age\.secrets\.",
    r"security\.sudo",
    r"boot\.(kernelPackages|initrd|kernelModules|loader)",
    r"fileSystems\.",
    r"swapDevices",
]
```

---

## Circuit Breaker

If 3 consecutive proposals result in rollback:
1. Write `/var/lib/kuzea/circuit-open` (kuzea user creates it)
2. Notify via n8n webhook (rpi5 → n8n → human):
   `{"event":"circuit_breaker_tripped","severity":"critical","consecutive_failures":3}`
3. Stop all trigger file writes; planner checks for this file before proceeding
4. **Recovery procedure:**
   a. Human investigates rollback reasons in `episodes` table
   b. Human decides whether CUSUM recalibration is needed (parameters may be stale)
   c. `sudo rm /var/lib/kuzea/circuit-open` (kuzea user cannot delete it — file
      ownership is `root:root`, only writable by kuzea via `O_CREAT` on the directory)
   d. If recalibration needed, re-run Phase 0 calibration script before re-enabling

---

## Cleanup and Maintenance

### `kuzea-cleanup.timer` (daily)

Runs on rpi5:
1. **Proposals:** Delete proposal files older than 30 days from
   `/var/lib/kuzea/proposals/`
2. **Trigger files:** Remove processed trigger files from
   `/var/lib/kuzea/triggers/`
3. **Remote branches:** Delete merged/failed `kuzea/*` branches from
   GitHub: `git push origin --delete kuzea/<id>` for branches whose
   episode is completed (success or rollback)
4. **SQLite metrics:** Prune `observations` and `service_metrics` rows
   older than 90 days. Add an index on `collected_at` for CUSUM query
   performance (already in schema).
5. **Nix store GC on sancta-choir:** SSH to sancta-choir and run:
   ```bash
   nix-env --delete-generations +3 -p /nix/var/nix/profiles/system
   nix-collect-garbage
   ```
   This retains the 3 most recent NixOS generations and garbage-collects
   the rest. (`nix-collect-garbage --delete-older-than 14d` does **not**
   have a "keep N generations" flag — use `nix-env --delete-generations +3`
   first to retain the last 3.)
6. **Meta-review reports:** Retain last 10 meta-review reports; archive
   older ones.

---

## Memory and Learning

### Retrieval-Augmented Planning

Past outcomes stored in Qdrant on rpi5 (`kuzea-outcomes` collection),
retrieved by semantic similarity at planning time. The embedding query is
the current `SystemSnapshot` formatted as prose — retrieving outcomes
matching the symptom pattern across all past sancta-choir episodes.

### Semantic Rollback Analysis

When rollback is detected, rpi5 calls `claude -p <analysis-prompt>` (one-shot,
no tools) to produce a `lessons-learned` paragraph, embedded alongside the
failure in Qdrant. Future planning cycles retrieve this diagnosis
automatically.

### Memory Consolidation

Weekly `kuzea-consolidation.timer` runs `memory-consolidator.py`:

1. **Group:** Query Qdrant `kuzea-outcomes` collection; group episodes by
   `(service, option)` pair.
2. **Archive first:** Copy all individual episode vectors to the
   `kuzea-archive` Qdrant collection before any deletion. This makes
   consolidation reversible — if a summary is inaccurate, the original
   data can be recovered from the archive.
3. **Summarize:** If a group has >5 episodes, call `claude -p` (one-shot, no
   tools) to produce a single consolidated pattern — e.g., "Raising MemoryMax
   above 2048M on openclaw-task-runner consistently reduces OOM events but
   shows diminishing returns above 2560M."
4. **Replace:** Delete individual episode vectors from `kuzea-outcomes`;
   insert the consolidated pattern as one new vector with metadata
   `{"consolidated": true, "episode_count": N}`.
5. **Age-based cleanup:** Prune vectors older than 90 days from
   `kuzea-archive` (the archive is for recovery, not permanent storage).
6. **Resolve contradictions:** If the same `(service, option, value)` appears
   with both `SUCCESS` and `ROLLBACK` outcomes, keep the most recent result
   and annotate the consolidated vector with
   `"contradicted": true, "contradiction_count": N`. Retaining the count
   preserves the signal that an option's success may be load-dependent —
   future planning cycles can use this to avoid fragile changes.

### Meta-Review

Bi-weekly `kuzea-meta-review.timer` (fires on the 1st and 15th of each
month) runs `meta-review.py`:

1. **Compute statistics:**
   - Gate pass rate (per gate, over trailing 30 days)
   - Rollback rate (rollbacks / total activations)
   - Option frequency (which Tier 1 options are touched most)
   - Bound saturation (how close proposals get to Tier 1 bounds, e.g.,
     MemoryMax approaching the 3G ceiling)
2. **Output report:** `/var/lib/kuzea/meta-reviews/<date>.md`
3. **Bound expansion proposals:** If any Tier 1 bound is >60% saturated
   (e.g., most proposals push MemoryMax to >2.4G out of 3G max), generate
   a Tier 3 draft PR via `gh pr create --draft --label kuzea-meta`
   proposing a bound increase. The change auditor blocks auto-apply for
   `kuzea*.nix`, so this always requires human review.
4. **Context injection:** Meta-review output is included in future planning
   cycles as additional context (appended to the task file after
   `<past_outcomes>`).

---

## Integration with Existing Infrastructure

| Component (on rpi5) | Role in Kuzea |
|---------------------|-----------------|
| **OpenClaw module** | `modules/services/openclaw.nix` provides the design pattern for user isolation, sudo wrapper, and nftables rules. Not currently deployed on rpi5 — Kuzea builds its own invocation layer modeled on this. |
| **Gatus** | Primary external health signal for sancta-choir. Kuzea polls `http://127.0.0.1:3001/api/v1/endpoints/statuses` for sancta-choir endpoint results. |
| **Qdrant** | RAG memory bank (`kuzea-outcomes` collection). Existing instance on rpi5 at `http://127.0.0.1:6333`. |
| **n8n** | Receives circuit-breaker alerts and Tier-2 approval requests from Kuzea. |
| **Embedding** | TBD — see Prerequisites. Ollama is not currently deployed on rpi5. |

### New Secrets

```nix
# secrets/secrets.nix — add:
"kuzea-ssh-key.age".publicKeys = allKeys;        # SSH key for rpi5 kuzea→sancta-choir
"kuzea-github-token.age".publicKeys = allKeys;   # GitHub PAT (scopes: contents:write, pull-requests:write)
"kuzea-oauth-token.age".publicKeys = allKeys;    # CC setup-token (1-year, Pro/Max)
"kuzea-hcloud-token.age".publicKeys = allKeys;   # Hetzner API token (tripwire last-resort hard reset)
```

**Note on `kuzea-hcloud-token`:** This secret is a Phase 3 prerequisite
(used by the tripwire's Channel 3 rollback via `hcloud server reset`).
It can be deferred until Phase 3 implementation begins.

```nix
# hosts/rpi5-full/configuration.nix — age.secrets:
age.secrets.kuzea-oauth-token.file = "${self}/secrets/kuzea-oauth-token.age";
```

### rpi5 Host Configuration

```nix
# hosts/rpi5-full/configuration.nix — add:
imports = [ ../../modules/services/kuzea.nix ];

services.kuzea = {
  enable            = true;
  targetHost        = "sancta-choir";
  targetFlakeAttr   = "sancta-choir";
  targetRepoPath    = "/var/lib/kuzea/nixos-config";
  sshKeyFile        = config.age.secrets.kuzea-ssh-key.path;
  oauthTokenFile    = config.age.secrets.kuzea-oauth-token.path;
  qdrantUrl         = "http://127.0.0.1:6333";
  gatusUrl          = "http://127.0.0.1:3001";
  tier1.services    = [ "openclaw-task-runner" ];
  notifications.n8nWebhookUrl = "http://127.0.0.1:5678/webhook/kuzea";
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

# Kuzea repo clone: kept up to date by the actuator (git pull before each build)
systemd.tmpfiles.rules = [
  "d /var/lib/kuzea 0750 root root -"
  "d /var/lib/kuzea/nixos-config 0750 root root -"
];

# Add kuzea SSH key to root's authorized_keys — command-restricted
users.users.root.openssh.authorizedKeys.keys = [
  # existing keys...
  # restrict = no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty
  # from= limits to the rpi5 Tailscale IP only
  # Phase 2 provisioning: replace 100.x.y.z with rpi5's actual Tailscale IP
  # obtained from: tailscale status --json | jq -r '.Self.TailscaleIPs[0]'
  ''command="${pkgs.kuzea-ssh-wrapper}/bin/kuzea-ssh-wrapper",restrict,from="100.x.y.z" ssh-ed25519 AAAA... kuzea@rpi5''
];
```

The `kuzea-ssh-wrapper` is a Nix derivation (immutable) that whitelists
only the commands Kuzea needs:

```bash
#!/usr/bin/env bash
# kuzea-ssh-wrapper — restrict SSH commands from the Kuzea key
# Built as a Nix derivation; the agent cannot modify it.
#
# SECURITY: Never `exec $SSH_ORIGINAL_COMMAND` — unquoted expansion triggers
# word splitting and glob expansion, while shell metacharacters (&&, ||, ;)
# are NOT re-parsed by exec, causing compound commands to fail silently.
# Instead, parse and reconstruct each allowed command explicitly.
set -euo pipefail
set -f  # disable globbing

REPO="/var/lib/kuzea/nixos-config"
FLAKE="${REPO}#sancta-choir"
CMD="$SSH_ORIGINAL_COMMAND"

case "$CMD" in
  # --- Metric collection (read-only) ---
  "systemctl show --value -p MemoryCurrent "*.service)
    svc="${CMD##* }"; svc="${svc%.service}"
    case "$svc" in
      openclaw-task-runner|tailscaled) ;;
      *) echo "ERROR: service not in allowlist: $svc" >&2; exit 1 ;;
    esac
    exec systemctl show --value -p MemoryCurrent "${svc}.service" ;;
  "systemctl show --value -p CPUUsageNSec "*.service)
    svc="${CMD##* }"; svc="${svc%.service}"
    case "$svc" in
      openclaw-task-runner|tailscaled) ;;
      *) echo "ERROR: service not in allowlist: $svc" >&2; exit 1 ;;
    esac
    exec systemctl show --value -p CPUUsageNSec "${svc}.service" ;;
  "cat /proc/pressure/memory")
    exec cat /proc/pressure/memory ;;
  "readlink /nix/var/nix/profiles/system")
    exec readlink /nix/var/nix/profiles/system ;;

  # --- Journal (read-only, exact match for collection interval) ---
  "journalctl --since '3m ago' --output json --no-pager -q")
    exec journalctl --since '3m ago' --output json --no-pager -q ;;

  # --- Pre-flight checks (read-only) ---
  "df /nix")
    exec df /nix ;;
  "nix-env --list-generations -p /nix/var/nix/profiles/system")
    exec nix-env --list-generations -p /nix/var/nix/profiles/system ;;

  # --- Nix store GC (daily cleanup timer) ---
  "nix-env --delete-generations +3 -p /nix/var/nix/profiles/system")
    exec nix-env --delete-generations +3 -p /nix/var/nix/profiles/system ;;
  "nix-collect-garbage")
    exec nix-collect-garbage ;;

  # --- Git operations (exact repo path, no wildcards) ---
  "git -C ${REPO} fetch origin")
    exec git -C "$REPO" fetch origin ;;
  "git -C ${REPO} checkout kuzea/"*)
    branch="${CMD##*checkout }"
    if [[ ! "$branch" =~ ^kuzea/[a-zA-Z0-9_-]+$ ]]; then
      echo "ERROR: invalid branch name: $branch" >&2; exit 1
    fi
    exec git -C "$REPO" checkout "$branch" ;;

  # --- Build/deploy (exact flake path only — no wildcards) ---
  "nixos-rebuild build --flake ${FLAKE}")
    exec nixos-rebuild build --flake "$FLAKE" ;;
  "nixos-rebuild test --flake ${FLAKE}")
    exec nixos-rebuild test --flake "$FLAKE" ;;
  "nixos-rebuild switch --flake ${FLAKE}")
    exec nixos-rebuild switch --flake "$FLAKE" ;;
  "nixos-rebuild switch --rollback")
    exec nixos-rebuild switch --rollback ;;

  # --- Detached rebuild (survives SSH disconnect) ---
  "systemd-run --unit=kuzea-rebuild --no-block nixos-rebuild test --flake ${FLAKE}")
    exec systemd-run --unit=kuzea-rebuild --no-block \
      nixos-rebuild test --flake "$FLAKE" ;;
  "systemctl is-active kuzea-rebuild.service")
    exec systemctl is-active kuzea-rebuild.service ;;
  "systemctl reset-failed kuzea-rebuild.service")
    exec systemctl reset-failed kuzea-rebuild.service ;;

  # --- SSH probe ---
  "true")
    exit 0 ;;

  *)
    logger -t kuzea-ssh-wrapper -p auth.warning \
      "Blocked command from kuzea key: $SSH_ORIGINAL_COMMAND"
    echo "ERROR: command not in Kuzea allowlist" >&2
    exit 1
    ;;
esac
```

### Health Endpoint (rpi5)

The collector writes a JSON status file after each cycle:
`/var/lib/kuzea/health.json` containing `last_collection_epoch`,
`collect_failures`, and `circuit_breaker_open`. A separate
`kuzea-health.service` (simple, always-running) serves this file via
Python's `http.server` on `127.0.0.1:9095`. This is the simplest
implementation — a 5-line wrapper script that uses `http.server` with a
custom handler to serve the JSON file as `/health`.

### Gatus Endpoints (rpi5, Kuzea self-observability)

```nix
services.gatus-tailscale.endpoints = {
  kuzea-collector = {
    name  = "Kuzea Collector";
    group = "kuzea";
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

### The Kuzea User (on rpi5)

```nix
users.users.kuzea = {
  isSystemUser = true;
  uid          = 992;    # static, for nftables
  group        = "kuzea";
  home         = "/var/lib/kuzea";
};

# Ensure proper permissions on home and sensitive directories
systemd.tmpfiles.rules = [
  "d /var/lib/kuzea 0750 kuzea kuzea -"
  "d /var/lib/kuzea/.claude 0700 kuzea kuzea -"     # OAuth token storage
  "d /var/lib/kuzea/proposals 0750 kuzea kuzea -"
  "d /var/lib/kuzea/triggers 0750 kuzea kuzea -"
  "d /var/lib/kuzea/jobs 0750 kuzea kuzea -"
];
```

### Sudo Wrapper (kuzea-sudo, analogous to openclaw-sudo)

- `build <target>` → `nixos-rebuild build --flake <repo>#<target>` (rpi5 dry-run only)
- `check` → `nix flake check`
- `fmt` → `nix fmt`
- SSH operations: handled directly by the `kuzea` user's SSH key, not via sudo
- No `switch` or `test` in the local sudo wrapper — those run on sancta-choir via SSH

### Network Restrictions (nftables, rpi5 UID-based)

The `kuzea` user on rpi5 may reach:
- `api.anthropic.com` (CC Pro subscription)
- `api.github.com` + `github.com` (PR creation)
- Tailscale interface (`tailscale0`) — covers sancta-choir SSH, local services
- DNS, loopback

All other outbound: dropped and logged.

**Implementation:** nftables itself cannot perform DNS lookups in rules.
Use the same pattern as `openclaw.nix`: a `kuzea-nft-update.timer`
(every 6h) resolves `api.anthropic.com` and `api.github.com` to IP
addresses and populates named nft sets. The UID-based egress filter
references these sets. See `modules/services/openclaw.nix` for the
full pattern including IPv6 and dynamic DNS resolution.

**Tripwire user:** `kuzea-tripwire.service` runs as **root** (not the
`kuzea` user) because it needs to call `hcloud server reset` (which
requires reaching `api.hetzner.cloud`, not in the kuzea user's nftables
allowlist). Running the tripwire as root also prevents the kuzea user
from interfering with the tripwire's network access.

### CC `allowedTools` Whitelist

```
Read · Glob · Grep · Bash(nix eval *) · Write
```

CC cannot: `Edit`, run `nixos-rebuild`, `git`, `ssh`, `curl`, or `systemctl`.

### What Kuzea Cannot Change About Itself

`modules/services/kuzea.nix` and `hosts/rpi5-full/configuration.nix`
(the controller's own config) are matched by the change auditor's
`SUPERVISED` patterns. Any proposal touching them produces a draft PR only.

---

## Identity Invariant

Six properties must hold **before and after** every Kuzea modification.
The actuator runs `invariant-checker.py` at pre-flight (Step 8) and
post-verification (after Step 14). Failure at either point aborts or
rolls back the episode.

| # | Check | Method | Failure Action |
|---|-------|--------|----------------|
| 1 | `ssh_reachable` | `ssh root@sancta-choir true` (5s timeout) | Abort / rollback |
| 2 | `tailscale_online` | `tailscale status --json` → peer online | Abort / rollback |
| 3 | `gatus_all_healthy` | Gatus API: all sancta-choir endpoints healthy | Abort / rollback |
| 4 | `rollback_functional` | `nix-env --list-generations` ≥ 3 on target | Abort (pre-flight only) |
| 5 | `tripwire_running` | `systemctl is-active kuzea-tripwire` on rpi5 | Abort (pre-flight only) |
| 6 | `auditor_integrity` | SHA256 of `change-auditor.py` matches Nix store | Abort |

`invariant-checker.py` is built as an **immutable Nix derivation** —
its content is fixed at deploy time and cannot be modified by the Kuzea
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

1. Create `modules/services/kuzea.nix` (observer-only mode)
2. **Prerequisite check:** Verify `psi=1` in sancta-choir's kernel command
   line (`ssh root@sancta-choir "grep -q psi=1 /proc/cmdline"`). If not
   present, add `boot.kernelParams = [ "psi=1" ];` and reboot before
   collection begins. Without PSI, `cat /proc/pressure/memory` returns
   nothing and the CUSUM baseline will be empty.
3. Implement `collect-remote.sh` (SSH metric collection)
4. **Bootstrap `known_hosts`:** Run `ssh-keyscan sancta-choir.tail4249a9.ts.net`
   once and commit the output as an immutable Nix store path. Used by
   `collect-remote.sh` with `StrictHostKeyChecking=yes`.
5. Define SQLite schema (with `PRAGMA journal_mode=WAL`); apply on rpi5
6. Implement collector service + 2m timer
7. Implement `kuzea-health.service` — Python `http.server` wrapper serving
   `/var/lib/kuzea/health.json` on `127.0.0.1:9095`
8. Add Gatus endpoint for kuzea-collector on rpi5
9. Deploy and run for 7 days

**Deliverable:** 7 days of sancta-choir metrics on rpi5. Confirmed SSH
collection and Gatus integration. Baseline for CUSUM calibration.

**Phase gate:**

*Go/no-go:*
```bash
# Must return rows for every monitored service with non-null averages
sqlite3 /var/lib/kuzea/metrics.db \
  "SELECT service, AVG(memory_bytes/1048576.0) AS avg_mb, AVG(psi_mem_some)
   FROM service_metrics WHERE collected_at > datetime('now','-7 days')
   GROUP BY service;"

# Collection gap check — no gap longer than 5 minutes in the last 7 days
sqlite3 /var/lib/kuzea/metrics.db \
  "SELECT MAX(gap_seconds) FROM (
     SELECT (julianday(collected_at) - julianday(LAG(collected_at) OVER (ORDER BY collected_at))) * 86400 AS gap_seconds
     FROM observations WHERE collected_at > datetime('now','-7 days')
   ) WHERE gap_seconds > 300;"
# Must return empty (no gaps > 5min)

# Gatus endpoint healthy
curl -sf http://127.0.0.1:3001/api/v1/endpoints/statuses | jq '.[] | select(.group=="kuzea")'
```

*Red flags — stop and investigate if:*
- SSH collection fails >5 consecutive times (check `last-collect-failures` state file)
- `service_metrics` table has rows but all `memory_bytes` values are NULL (SSH succeeds but commands return empty)
- Gatus kuzea-collector endpoint is unhealthy within the first 48 hours (misconfigured health endpoint)
- SQLite DB grows >100MB in 7 days (schema or insertion bug)

*Time budget:* **2 weeks.** If SSH connectivity issues consume >3 days of debugging, reassess whether the sancta-choir network path is reliable enough for this architecture.

---

### Phase 1 — Planning (Weeks 3–4)

**Goal:** CC produces proposals for sancta-choir; human reviews, no auto-apply.

1. Create `task-template.md` and `system-prompt.txt`
2. Implement task file generator (inject snapshot + Qdrant RAG + `nix eval`)
3. Implement `kuzea-planner.service` calling `claude -p`
4. CC `allowedTools`: `Read,Glob,Grep,Bash(nix eval *),Write`
5. 72h fallback timer (no CUSUM yet)
6. Proposals written to `/var/lib/kuzea/proposals/`; human reviews manually
7. Self-profile generator produces `self-profile.json`, injected into task
   file as `<self_profile>` section (option frequency, success rates,
   unexplored options)

**Phase gate:**

*Go/no-go:*
```bash
# At least 5 proposal files exist and are valid JSON
ls /var/lib/kuzea/proposals/*.json | wc -l   # must be ≥ 5

# At least 4 of 5 overlay files parse as valid Nix
for f in hosts/sancta-choir/agent-overlays/2*.nix; do
  nix-instantiate --parse "$f" > /dev/null 2>&1 && echo "OK: $f" || echo "FAIL: $f"
done
# ≥ 4 must show OK

# CC exit code 0 in ≥ 4 of 5 planning runs
grep -c "exit_code.*0" /var/lib/kuzea/planner-runs.log   # must be ≥ 4
```

*Red flags — stop and investigate if:*
- CC consistently produces `no-action-*.txt` files (≥3 in a row) — task template may be too restrictive or snapshot data insufficient
- Qdrant embedding failures in planner logs (embedding model not working or Qdrant unreachable)
- Planner service OOM-killed (check `journalctl -u kuzea-planner`) — CC + embedding may exceed rpi5's 4GB
- Proposals target options outside the Tier 1 allowlist — system prompt or `allowedTools` misconfigured

*Time budget:* **2 weeks.** If CC produces 0 valid proposals after 5 attempts, stop and review the task template and system prompt before continuing.

---

### Phase 2 — Actuator + Manual Approval (Weeks 5–6)

**Goal:** Full pipeline including remote nixos-rebuild. Human approves each switch.

1. Implement `change-auditor.py` and `property-tests.py` as Nix derivations
2. Implement `kuzea-actuator` shell script (all 16 steps including SSH)
3. Set up sancta-choir nixos-config clone at `/var/lib/kuzea/nixos-config`
4. Provision Kuzea SSH key (add to sancta-choir's `authorized_keys`)
   Deploy `kuzea-ssh-wrapper` on sancta-choir (immutable Nix derivation)
   including the `systemd-run` and `systemctl is-active` commands
5. Approval token mechanism: actuator pauses at Step 13 (before `nixos-rebuild test`)
6. **Deliberately test rollback:** force a gate failure (e.g., inject a
   failing property test), verify sancta-choir returns to previous generation
7. Implement Qdrant outcome embedding
8. Invariant checker runs at pre-flight (after Step 8) and post-verification
   (after Step 14) — all 6 checks must pass
9. Evaluation constitution Nix options defined (`services.kuzea.evaluation.*`)

**Deliverable:** End-to-end pipeline confirmed. Remote rollback verified.

**Phase gate:**

*Go/no-go:*
```bash
# Remote rollback verified — generation number decreased after rollback
ssh root@sancta-choir \
  "nix-env --list-generations -p /nix/var/nix/profiles/system | tail -3"
# Must show test generation followed by rollback to previous

# End-to-end pipeline: at least 1 episode completed with outcome != 'rejected'
sqlite3 /var/lib/kuzea/metrics.db \
  "SELECT COUNT(*) FROM episodes WHERE outcome IS NOT NULL AND outcome != 'rejected';"
# Must be ≥ 1

# All 6 invariant checks pass on current state
python3 /nix/store/.../invariant-checker.py --all   # exit code 0
# (invocation via absolute store path; the module wraps this in a script)

# Rollback Channel 2 (public IP SSH) verified
ssh -o ConnectTimeout=10 root@<sancta-choir-public-ip> \
  "nixos-rebuild switch --rollback"
# Must succeed (Channel 3 / Hetzner API deferred to Phase 3 when hcloud token is provisioned)
```

*Red flags — stop and investigate if:*
- Remote `nixos-rebuild build` fails consistently on sancta-choir (store path mismatch, disk full, or flake eval error)
- Rollback Channel 2 (public IP SSH) unreachable — firewall or sshd config issue on sancta-choir's public interface
- Qdrant outcome embedding silently fails (episodes complete but `kuzea-outcomes` collection stays empty)
- SSH key `command=` restriction blocks a command the actuator needs (check `kuzea-ssh-wrapper` logs on sancta-choir)

*Time budget:* **2 weeks.** The remote build + rollback verification is the critical path. If sancta-choir builds take >15 minutes consistently, investigate before Phase 3 adds more automated cycles.

---

### Phase 3 — CUSUM + Tripwire (Weeks 7–8)

**Goal:** Event-driven triggering; independent safety monitor targeting sancta-choir.

1. Implement `kuzea-cusum-watchdog.service` (watches SSH-collected PSI/memory)
2. Implement `kuzea-anomaly-watcher.service` (Gatus failures + SSH OOM scan)
3. Implement `kuzea-planner.path` on `/var/lib/kuzea/triggers/` directory
   Planner service uses `flock /var/lib/kuzea/actuator.lock` to serialize
   concurrent trigger-driven runs (prevents two planners racing on git state)
4. Implement `kuzea-tripwire.service`:
   - SSH probe + Tailscale check + Gatus for sancta-choir
   - On violation: rollback cascade (Tailscale SSH → public IP SSH → Hetzner API hard reset)
5. Confirm tripwire fires independently even when Kuzea main service is stopped
6. Tripwire uses `invariant-checker.py` with subset checks (1, 2, 3) for its
   continuous monitoring loop

**Phase gate:**

*Go/no-go:*
```bash
# CUSUM fires on a synthetic PSI spike injected via SSH
# (inject a known-bad value into metrics.db, verify trigger file appears)
sqlite3 /var/lib/kuzea/metrics.db \
  "INSERT INTO service_metrics (observation_id, service, psi_mem_some) VALUES (999, 'test', 50.0);"
# Within 3 minutes: ls /var/lib/kuzea/triggers/  → must contain a new trigger file
# Clean up: DELETE the test row and trigger file after verification

# Tripwire independently detects simulated outage
# (block sancta-choir SSH temporarily, verify tripwire logs a violation)
journalctl -u kuzea-tripwire --since "5m ago" | grep -c "violation"   # must be ≥ 1

# Path unit triggers planner on file write
touch /var/lib/kuzea/triggers/test-trigger
systemctl is-active kuzea-planner.service   # must be activating or active within 10s
rm /var/lib/kuzea/triggers/test-trigger
```

*Red flags — stop and investigate if:*
- CUSUM never fires despite normal metric variance — calibration parameters (μ₀, k, h) are wrong; recalibrate from Phase 0 data
- Tripwire produces false positives (fires when sancta-choir is healthy) — probe timeout too aggressive or Gatus endpoint misconfigured
- SQLite `BUSY` errors in watchdog or anomaly watcher logs (concurrent write contention from multiple services)
- `kuzea-planner.path` activates but planner fails immediately (missing env vars, OAuth token expired)

*Time budget:* **2 weeks.** CUSUM calibration is the critical unknown. If the calibration script produces unreasonable parameters (h < 1 or h > 100), revisit the baseline data quality from Phase 0.

---

### Phase 4 — Tier 1 Autonomy (Weeks 9–10)

**Goal:** openclaw-task-runner resource limits adjusted fully autonomously.

1. Remove human approval gate for `autonomous` auditor verdict
2. Enable `limits.maxSwitchesPerDay = 3`
3. Implement circuit breaker (consecutive failure counter)
4. Tune CUSUM thresholds from Phase 0 baseline
5. Deploy and monitor for one week
6. Exploration budget enabled (every 5th cycle uses `task-template-explore.md`)
7. Retrospective entries written to `pending-retrospectives` per episode
   (persistent file, survives reboots — see "24h Retrospective Check")

**Phase gate:**

*Go/no-go:*
```bash
# ≥ 3 autonomous switches with confirmed PSI improvement
sqlite3 /var/lib/kuzea/metrics.db \
  "SELECT COUNT(*) FROM episodes
   WHERE outcome = 'success' AND psi_after < psi_before;"
# Must be ≥ 3

# No unexpected rollbacks (rollback_reason must be NULL or 'deliberate_test')
sqlite3 /var/lib/kuzea/metrics.db \
  "SELECT COUNT(*) FROM episodes
   WHERE outcome = 'rollback' AND rollback_reason NOT LIKE '%deliberate%';"
# Must be 0

# Circuit breaker file does not exist
test ! -f /var/lib/kuzea/circuit-open && echo "OK" || echo "FAIL"

# Tripwire has not fired outside of test windows
journalctl -u kuzea-tripwire --since "7 days ago" | grep -c "rollback"
# Must be 0 (unless a deliberate test triggered it)

# Retrospective timer fires correctly
systemctl list-timers 'kuzea-retrospective@*' --no-pager
# Must show at least one scheduled or completed retrospective
```

*Red flags — stop and investigate if:*
- Every autonomous switch results in rollback (Tier 1 bounds may be too narrow, or the target service is fundamentally unstable)
- PSI improvement is within noise (< `minimumEffect` of 5%) on all switches — Kuzea is making changes that don't matter
- Exploration cycle (every 5th) consistently produces `no-action` — exploration template needs tuning
- Circuit breaker trips within the first 48 hours of autonomy — Phase 3 CUSUM calibration may be triggering on noise

*Time budget:* **2 weeks.** If zero successful autonomous switches after 1 week, drop back to Phase 2 (manual approval) and investigate why proposals fail gates or verification.

---

### Phase 5 — Learning Validation (Weeks 11–12)

**Goal:** Confirm Qdrant RAG improves proposal quality for remote targets.

1. A/B comparison: alternate RAG-enabled and RAG-disabled cycles. Target
   10+ cycles per arm for meaningful comparison. With n=5 per arm, treat
   results as a qualitative case study rather than statistically significant.
2. Compare gate failure rate and verification pass rate
3. Implement semantic rollback analysis (lessons-learned embedding)
4. Add property test predicates from any Phase 2–4 rollback incidents
5. `retrospective.py` fully deployed — 24h delayed evaluation per episode
6. Memory consolidator (`kuzea-consolidation.timer`) — weekly episode grouping
7. Meta-review (`kuzea-meta-review.timer`) — bi-weekly statistics + reports

**Phase gate:**

*Go/no-go:*
```bash
# A/B comparison documented with measurable difference
ls /var/lib/kuzea/meta-reviews/ab-comparison-*.md   # must exist
# Gate failure rate with RAG < gate failure rate without RAG (documented in file)

# Memory consolidation ran without data loss
python3 -c "
import requests
r = requests.get('http://127.0.0.1:6333/collections/kuzea-outcomes')
count = r.json()['result']['points_count']
archive = requests.get('http://127.0.0.1:6333/collections/kuzea-archive')
archive_count = archive.json()['result']['points_count']
print(f'Active: {count}, Archived: {archive_count}')
assert count > 0, 'Active collection is empty after consolidation'
"

# Meta-review report generated
ls /var/lib/kuzea/meta-reviews/*.md | head -1   # must exist
```

*Red flags — stop and investigate if:*
- A/B sample size too small to draw conclusions (fewer than 5 cycles per arm) — extend the test or defer conclusions
- Consolidation deleted vectors without archiving (Qdrant `kuzea-archive` collection empty after consolidation ran)
- Retrospective checks consistently show delayed negatives (>30% of "successful" switches degrade within 24h) — the 10-minute verification window is too short
- Meta-review statistics show 0% exploration success rate — exploration template is ineffective

*Time budget:* **2 weeks.** The A/B test requires 10 planning cycles minimum (5+5). If Kuzea averages fewer than 1 cycle/day, extend the phase rather than reducing sample size.

---

### Phase 6 — Tier 2 Expansion (Week 13+)

**Goal:** Expand to service-specific and kernel options on sancta-choir.

1. n8n approval workflow for Tier 2 proposals
2. Add `services.openclaw.*` and `boot.kernel.sysctl` options
3. `expected_outcome` verification (predicted metric delta confirmed in window)

**Phase gate:**

*Go/no-go:*
```bash
# At least one Tier 2 change applied and verified on sancta-choir
sqlite3 /var/lib/kuzea/metrics.db \
  "SELECT COUNT(*) FROM episodes
   WHERE goal LIKE '%Tier 2%' AND outcome = 'success';"
# Must be ≥ 1

# n8n approval workflow completed at least one approval cycle
# (check n8n execution history for the kuzea approval workflow)
curl -sf http://127.0.0.1:5678/api/v1/executions?workflowId=<approval-wf-id>&status=success | jq '.data | length'
# Must be ≥ 1
# TBD: <approval-wf-id> populated after n8n workflow creation in Phase 6
```

*Red flags — stop and investigate if:*
- n8n approval workflow is broken or unreachable (approvals silently fail, proposals never proceed)
- Tier 2 changes require reboots that break the verification window (`nixos-rebuild test` + reboot = lose test generation)
- `boot.kernel.sysctl` changes cause immediate instability before the verification window starts (kernel panics, network loss)
- Tier 2 scope creep — proposals touch options not yet in the Tier 2 allowlist

*Time budget:* **2 weeks.** Tier 2 expansion is inherently riskier. If the first Tier 2 change results in rollback, pause and tighten the property test suite before the second attempt.

---

### Phase 7 — Meta-Proposals (Week 15+)

**Goal:** Close the reflexive loop — Kuzea proposes changes to its own
operational bounds, always through a human gate.

1. Extend `meta-review.py` to generate concrete Nix overlay fragments
   proposing Tier 1 bound changes (e.g., raising `MemoryMax` ceiling from
   3G to 3.5G) when bound saturation exceeds 60%
2. Proposals are always created as draft PRs:
   `gh pr create --draft --label kuzea-meta`
3. The change auditor's `SUPERVISED` patterns match `kuzea*.nix`, blocking
   any auto-apply — meta-proposals always require human review
4. Meta-review statistics are embedded in the draft PR description for
   context (saturation %, affected options, historical trend)

**Phase gate:**

*Go/no-go:*
```bash
# Meta-review generated ≥ 1 bound-expansion draft PR
gh pr list --label kuzea-meta --state all --json number,title | jq 'length'
# Must be ≥ 1

# Draft PR is well-formed: valid Nix overlay in the PR diff
gh pr diff <pr-number> -- '*.nix' | head -20
# Must contain a syntactically valid option change

# Change auditor correctly blocked auto-application
sqlite3 /var/lib/kuzea/metrics.db \
  "SELECT COUNT(*) FROM episodes
   WHERE json_extract(gate_results, '$.auditor_verdict') = 'supervised';"
# Must be ≥ 1 (proves the auditor caught the meta-proposal)

# Human reviewed and either merged or closed with rationale
gh pr view <pr-number> --json state,reviews | jq '.state'
# Must be "MERGED" or "CLOSED" (not indefinitely open)
```

*Red flags — stop and investigate if:*
- Meta-review never triggers a bound-expansion proposal (saturation threshold of 60% is never reached — Kuzea may be under-utilizing its Tier 1 bounds, which is fine but means Phase 7 has nothing to do)
- Draft PR contains invalid Nix (meta-review.py's overlay generation has a bug)
- Multiple bound-expansion PRs pile up unreviewed (human bottleneck — consider reducing meta-review frequency or auto-closing stale drafts)
- Proposed bound changes are unreasonable (e.g., MemoryMax ceiling exceeds VPS RAM) — add bounds validation to meta-review.py

*Time budget:* **Open-ended (ongoing).** Phase 7 is not a one-time deliverable — it's the steady-state operational mode. However, the **first** meta-proposal should appear within 4 weeks of enabling Phase 7. If not, verify that the saturation calculation is correct.

**Note:** The reflexive loop is intentionally shallow — Kuzea can propose
changes to Tier 1 bounds only, never to the change auditor, invariant
checker, evaluation constitution, or its own module structure. These
remain stratum 0 (human-only).

---

## Open Questions for Implementation

1. **SSH key provisioning:** The `kuzea-ssh-key` secret must be added to
   `secrets/secrets.nix` and `sancta-choir/configuration.nix`
   (`authorized_keys`). This bootstrapping step is Tier 3 (requires a
   human-reviewed PR). Must be done before Phase 2.

2. **~~Pro subscription OAuth flow headless~~ (Resolved):** Use
   `claude setup-token` on a browser-equipped machine to produce a 1-year
   `CLAUDE_CODE_OAUTH_TOKEN`. Encrypt as `kuzea-oauth-token.age` and
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
   requires a `default.nix` in that directory. The `default.nix` uses
   `builtins.readDir` to auto-import all sibling `.nix` files — the
   actuator only adds/removes overlay files, never edits `default.nix`.
   This eliminates race conditions between overlay writes and index
   updates. See the "Overlay modules" section for the bootstrap file.

5. **CUSUM μ₀ calibration:** A one-time calibration script computes μ₀ ±2σ
   from Phase 0 data. Run after 7 days of collection before activating CUSUM.

6. **`nixos-rebuild test` on sancta-choir via SSH:** `nixos-rebuild test`
   may restart `sshd.service` during activation if the sshd configuration
   changed, which kills the parent SSH connection. For Tier 1 changes
   (resource limits on non-sshd services), sshd typically survives. Use
   `systemd-run` (without `--scope` — scope units are bound to the
   invoking session and killed when SSH disconnects) as defensive practice:
   ```bash
   ssh root@sancta-choir \
     "systemd-run --unit=kuzea-rebuild --no-block \
      nixos-rebuild test --flake /var/lib/kuzea/nixos-config#sancta-choir"
   ```
   This creates a transient **service** unit that survives SSH
   disconnection. The actuator polls for completion via a separate SSH
   probe with 3× 5s retry on SSH failure (sshd may be briefly restarting):
   `ssh root@sancta-choir "systemctl is-active kuzea-rebuild.service"`
   The `kuzea-ssh-wrapper` on sancta-choir must include both
   `systemd-run --unit=kuzea-rebuild --no-block ...` and
   `systemctl is-active kuzea-rebuild.service` as allowed commands.
   This is a **Phase 2 prerequisite** — deploy the wrapper on
   sancta-choir before enabling remote operations.

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

---

## Plan Retrospective Triggers

Stop and reassess the **entire plan** (not just the current phase) if any of
these conditions occur:

| Trigger | Action |
|---------|--------|
| Any phase exceeds **2× its time budget** | Pause. Write a retrospective: why did it take longer? Is the plan's scope realistic for this hardware and team size? Adjust remaining phase budgets before continuing. |
| **2 consecutive phases** fail their go/no-go gate on first attempt | The plan's assumptions may be wrong. Re-evaluate prerequisites and phase ordering before proceeding. |
| A prerequisite (embedding model, SSH key, OAuth token) remains **unresolved past its phase deadline** | The blocked phase cannot start. Escalate the prerequisite or restructure the plan to defer the dependent phase. |
| **Circuit breaker trips** during any phase | Indicates a fundamental design issue (not just a bad proposal). Review the safety architecture before re-enabling. |
| **Human intervention required >3×** in a phase designed for autonomy | The autonomy boundary is drawn wrong. Tighten the scope or add more gates before expanding again. |
| **sancta-choir becomes unreachable** for >1 hour during any phase | The target host may have a hardware or network issue unrelated to Kuzea. Investigate independently before attributing to Kuzea changes. |

**Format:** When a retrospective is triggered, create a file
`/var/lib/kuzea/retrospectives/<date>-phase<N>.md` with:
1. Which trigger fired and the concrete evidence
2. Root cause analysis (5 whys or equivalent)
3. Decision: continue with adjustments, revert to previous phase, or pause the project

---

## References

- Research proposals: synthesized from 4 independent agent analyses (2026-02-21)
- Key primitives: `nixos-rebuild test` (`nixos-rebuild(8)` man page), CUSUM (Page 1954)
- Prior art: `modules/services/openclaw.nix`, `modules/services/gatus.nix`,
  `modules/services/qdrant.nix`
- sancta-choir current config: `hosts/sancta-choir/configuration.nix`
