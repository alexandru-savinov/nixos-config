# Vigil horizon — from fleet monitor to personal NOC + SOC

Status: phase 1 implemented, not deployed. Design approved by the owner
2026-10-31. Phase 1 is specified here in full; phases 2–4 are fixed only at
their interfaces and get their own spec, plan and run cycle.

## Scope and audience

**Personal only.** Vigil watches the owner's own fleet — `sancta-choir`,
`rpi5-full`, the Mac's links into them — and never client systems. "NOC" means
the health of those hosts and services; "SOC/XDR" means security signals from
those hosts and the tailnet.

Vigil v1 (`2026-09-20-vigil-plan.md`) is live and is the base: closed TOML
contracts, three-valued verdicts (`verde` / `picat` / `NECITIT`), incidents,
outbox, Telegram, `/status` into Gatus. Nothing in this design weakens any v1
invariant.

## Decisions

| Question | Decision |
|---|---|
| Audience | Personal only |
| Phase order | 1 SOC visibility → 2 explain + model choice → 3 console/skins → 4 control |
| Architecture | Approach **B**: Nix-ready sensors detect; Vigil remains the only judge and the only speaker |
| Packaging | The NixOS module is the "one file". No Docker, no compose. Tools are a declared set, never a shell |
| Guardrails | Model proposes; `/council` gates; deterministic code executes only declared recovery steps |
| Reuse | Gatus (live), Tailscale, existing Anthropic key + Codex subscription, Home Assistant, n8n (optional glue) |
| P1 sensors | CrowdSec, osquery, Netdata anomaly ML. Suricata deferred |

Rejected: Wazuh (no NixOS module or package in nixpkgs 25.11; community agent
package unmerged); a separate `vigil-soc` service (duplicates incidents,
delivery and dashboard); docker-compose export (YAGNI for a personal fleet).

## Nix-ready inventory (nixpkgs 25.11, evaluated on sancta-choir 2026-10-31)

Module + package: `crowdsec` 1.7.2 (+ `crowdsec-firewall-bouncer`), `osquery`
5.21.0, `netdata` 2.8.4, `suricata` 7.0.10, `fail2ban`, `gatus` 5.31.0,
`opensearch`, `victorialogs`, `loki`, `vector`, `alloy`, `prometheus`,
`grafana`, `ntopng`, `librenms`, `uptime-kuma`, `ollama`, `llama-cpp`,
`open-webui`, `n8n`. Package only: `aide`, `zeek`, `tetragon`. Absent: `wazuh`,
`falco`. Nothing Nix-ready exists for the console; it is built in phase 3.

## Architecture

```
 CrowdSec LAPI (127.0.0.1)   osquery (scheduled queries → results log)   Netdata (127.0.0.1:19999)
        │ alerts                    │ ports · users · suid · FIM              │ anomaly rate per chart
        └──────────────┬────────────┴──────────────┬──────────────────────────┘
                 vigil-check   (new closed types: crowdsec | osquery | anomaly)
                       │ verde / picat / NECITIT → incidents.json → outbox → Telegram
                       │                          → /status → Gatus (NOC view)
                       └→ redacted evidence slice per incident ─► P2 explain ─► P4 propose → /council
```

Rules that hold for every sensor:

- Bound to loopback only. Its own notification and alerting paths are off;
  Vigil is the only thing that speaks.
- No enforcement capability in phase 1: no CrowdSec bouncer, no osquery
  `distributed` write paths.
- Own systemd unit with an explicit `MemoryMax`, so earlyoom never has to
  choose a sensor over the Sancta session. Budget on choir: Netdata ≤ 400 MB
  (retention capped, cloud claim off, ML on), CrowdSec ≤ 256 MB, osquery
  ≤ 128 MB.
- A sensor that is down, unreachable or returns unparsable output makes its
  contract `NECITIT`. It is never read as `verde`.

## Phase 1 — SOC visibility

### New contract types

Each type is added to the closed type list and validated identically at
evaluation and at runtime, exactly as the v1 types are. Unknown keys remain a
validation error.

**`crowdsec`** — `tinta` is the LAPI URL (loopback only; non-loopback is a
validation error). `astept = { scenariu = "<scenario name>", fereastra_min = N }`,
`prag = M`. Verdict: `picat` when the count of alerts for that scenario within
the last N minutes is ≥ M; `verde` when below; `NECITIT` on connection refused,
auth failure or unparsable JSON. Vigil authenticates as a read-only LAPI
machine whose credential is an agenix secret owned by `vigil`.

**`osquery`** — `tinta` is the name of a scheduled query declared in the
module's osquery pack (not free SQL in the contract).
`astept = { permis = ["<row key>", …] }`. Verdict: `picat` when the latest
result for that query contains any row whose key is not in `permis`; `verde`
otherwise; `NECITIT` when the results log is missing, older than two query
intervals, or unparsable. Phase 1 ships three queries: `listening_ports`
(key `port/proto/process`), `local_users` (key `username`), `suid_bins`
(key `path`), plus file-integrity events on `/etc` (key `target_path`, the
allowlist is normally empty so any change is `picat`).

**`anomaly`** — `tinta` is a Netdata chart id. `prag` is an integer anomaly
rate in percent; `picat_dupa` (existing field) gives the consecutive-tick
requirement. Verdict: `picat` when the chart's anomaly rate over the last tick
interval is ≥ `prag`; `verde` below; `NECITIT` when Netdata is unreachable,
the chart is unknown, or ML is not yet trained (Netdata reports no anomaly
data).

### Contracts shipped in phase 1 (per host)

`ssh-bruteforce` (crowdsec, `crowdsecurity/ssh-bf`), `porturi-noi`
(osquery listening_ports), `utilizatori-noi` (osquery local_users),
`suid-nou` (osquery suid_bins), `etc-schimbat` (osquery FIM), `cpu-anomalie`
and `mem-anomalie` (anomaly on `system.cpu` and `system.ram`). The
`expectedContracts` count on each host rises by exactly the number added.
Allowlists are derived from the evaluated NixOS config where possible
(declared users, firewall/serve ports) rather than typed by hand.

### Security knowledge base

A new private git repository `vigil-kb` on choir under the `vigil` user's
state, never in this public repo. Contents: per-host baselines, one runbook
per contract (contracts reference it by `nume`), closed-incident notes, and in
phase 4 the append-only action log. Phase 1 creates the repo with a runbook
for each new contract; Vigil only links to runbooks in Telegram messages.

### Phase 1 testing

| Layer | Check |
|---|---|
| Schema | `pkgs/vigil/schema.test.mjs` fixtures per new type: valid, unknown key, missing field, non-loopback `tinta` (crowdsec) |
| Checker | `pkgs/vigil/checks.test.mjs`: each type maps fake sensor output to the three verdicts, including down/unparsable → `NECITIT` |
| Module | `tests/module-eval.nix` asserts the type list, loopback binds, `MemoryMax` present on all three sensor units |
| VM behaviour | New `tests/vigil-soc.nix`: boot CrowdSec + osquery + Netdata + Vigil; at rest all contracts `verde`; 10 failed ssh logins → `ssh-bruteforce` `picat` and an incident opens; `nc -l 4444` → `porturi-noi` `picat`; a CPU burn → `cpu-anomalie` `picat`; stop each sensor → its contract `NECITIT` |
| Live (attended) | After deploy on choir: one planted ssh-failure burst reaches Telegram; `systemctl show -p MemoryCurrent` for each sensor stays below its cap after 24 h |

## Phase 2 — explain with a choice of model (interface only)

Fills the existing `2026-09-20-vigil-2-explain-recover-plan.md` stub for the
explain half. Fixed now:

- **Evidence slice**: `evidence/<nume>-<incident_id>.json`, written by
  vigil-check after the closed redaction pattern list from the stub has run.
  Nothing unredacted leaves the host, whatever the model.
- **Model adapter**: one interface, `explain(evidence, runbook) → conclusion`
  with a JSON schema. Adapters in order: Anthropic API (existing key), Codex
  (existing subscription), local `ollama`/`llama-cpp` (CPU-only on choir; the
  Mac or a GPU VPS later). All adapters receive the same redacted input.
- The model only reads and concludes. It has no tools.

## Phase 3 — console and skins (interface only)

A static page that reads `/status` and `/checks/<public-name>` only; it has no
write path. Skins are swappable theme packages over one data model: an LCARS
style and a Sony/Panasonic cassette-futurism style first. 2D engine first; a
3D engine only after the 2D console is accepted. Gatus stays the plain NOC
view.

## Phase 4 — control (interface only)

- **Proposal schema**: `{nume, incident_id, recovery_id, why}`. `recovery_id`
  must name a step declared in that contract's `[recuperare]` section.
  Free-form commands are impossible by schema.
- **Gate**: every proposal goes to `/council`. `proceed` → the action unit
  (its own sandboxed user) runs the declared step. `escalate` → Telegram
  approve/deny to the owner. `block` → logged, nothing runs.
- **Hard floors no verdict overrides**: rate limit per host per hour; never
  act on `vigil*`, `sancta-soul*`, `tailscaled` or the Sancta session scope;
  never act during a `nixos-rebuild`; a `STOP` file refuses everything;
  every action appended to the `vigil-kb` action log.
- The CrowdSec bouncer, if ever enabled, is a phase-4 declared recovery step,
  not a phase-1 component.

## Out of scope

Client or DAAC systems; Wazuh; Suricata (until phase 1 has run for a month);
docker-compose; any change to Vigil v1 verdict, incident or delivery
semantics; any action capability before phase 4.

## Open items

- `soc.html` was named as an existing tool to reuse; it was not found on the
  Mac on 2026-10-31. Its location and role are to be supplied by the owner.
- Whether the Tailscale plan exposes configuration audit logs and network flow
  logs; if yes, a `tailnet-audit` contract type joins phase 1b.

## Phase 1 deploy and live acceptance (attended)

Owner steps; nothing below has been run. Merge `feat/vigil-soc-p1` with green
CI first. Do choir, then rpi5-full, and finish step 3 on choir before starting
rpi5-full.

Differences from the sections above: the CrowdSec credential is not an agenix
secret. `vigil-crowdsec-register` generates `/var/lib/vigil/crowdsec.yaml` on
the host, and the LAPI listens on 8088 because 8080 is Open-WebUI. The private
`vigil-kb` repository and its runbooks do not exist yet and remain an owner
step.

**1. Deploy.** Choir is a non-atomic GRUB host, so build first with one job:

```sh
git switch main && git pull --ff-only
nixos-rebuild build --flake .#sancta-choir --max-jobs 1 --cores 1 &&
  sudo nixos-rebuild switch --flake .#sancta-choir --max-jobs 1 --cores 1
```

On rpi5: `sudo nixos-rebuild switch --flake .#rpi5-full`. CrowdSec needs network
on first start to fetch its hub.

**2. Read the first verdicts.** Expect 17 contracts on choir and 18 on
rpi5-full (16 evaluated plus 2 runtime):

```sh
systemctl is-active crowdsec osqueryd netdata vigil.timer
sudo stat -c '%U %a' /var/lib/vigil/crowdsec.yaml   # vigil 400
sudo systemctl start vigil.service
journalctl -u vigil.service -o cat -n 60 | grep '^{"nume"' | jq -c '{nume,verdict,motiv}'
sudo jq '{verde,picat,necitit}' /var/lib/vigil/tick.counts.json
```

Expected noise on a first deploy:

- `cpu-anomalie` and `mem-anomalie` read NECITIT (`anomaly-untrained`) for at
  least 15 minutes.
- The osquery contracts read NECITIT until the first 300 s snapshot lands.
- `porturi-noi` reads `picat` for any socket config does not declare, for
  example tailscaled's random peerapi port. Real listeners were never observed
  on these hosts. Add each legitimate one to
  `services.vigil.sensors.osquery.allowedListeners` in a PR.
- `etc-schimbat` has an empty allowlist, so a switch that rewrites `/etc` may
  page. How often this happens on a real host is unmeasured.

Do not edit state to clear an incident; wait for the green threshold and
30-minute hold-down.

**3. Planted ssh-failure burst reaches Telegram.** Run it on the host, from a
documentation address on `lo`. The other routes do not work: over the tailnet,
`tailscale up --ssh` can answer port 22 before sshd sees the connection, and
`crowdsecurity/whitelists` drops loopback and RFC 1918 sources, which include
LAN clients. This also means `ssh-bruteforce` sees only sshd, never Tailscale
SSH. Password auth is off on both hosts, so the burst relies on sshd's
`Invalid user` line rather than the failed-password path the VM test used; this
step is the first proof of that path.

```sh
sudo ip addr add 203.0.113.7/32 dev lo
for i in 1 2 3 4 5 6 7 8 9 10; do
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -b 203.0.113.7 intruder@203.0.113.7 true
done
sudo ip addr del 203.0.113.7/32 dev lo
sudo cscli alerts list
sudo systemctl start vigil.service
sudo jq '.contracts["ssh-bruteforce"].open' /var/lib/vigil/incidents.json
```

Pass: a CrowdSec alert for `crowdsecurity/ssh-bf`, a non-null incident and a
Telegram message. The alert stays in the 15-minute window, then the incident
closes on its own. There is no bouncer, so the address is never blocked.

**4. After 24 hours, on each host.**

```sh
for unit in netdata crowdsec osqueryd; do
  systemctl show -p Id -p MemoryCurrent -p MemoryPeak -p MemoryMax "$unit.service"
done
sudo systemctl start vigil.service
journalctl -u vigil.service -o cat -n 60 | grep '^{"nume"' |
  jq -c 'select(.nume | test("anomalie")) | {nume,verdict,motiv}'
```

Pass: `MemoryCurrent` is below `MemoryMax` for all three units (netdata
419430400, crowdsec 268435456, osqueryd 134217728), and neither anomaly contract
reads `anomaly-untrained`. The steady-state untrained share on a real host is
unmeasured. If either contract still reads `anomaly-untrained`, the checker's
half-trained gate does not fit that host; treat that as a bug, not as noise.
