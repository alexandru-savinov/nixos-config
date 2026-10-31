Build Vigil horizon phase 1 (SOC visibility): three new closed contract types — crowdsec, osquery, anomaly — backed by loopback-only CrowdSec, osquery and Netdata sensors, proven by unit tests and a NixOS VM test, deployable to sancta-choir and rpi5-full with one switch each.

## Context

Approved design: `docs/plans/2026-10-31-vigil-horizon-design.md` (read it first;
the "Phase 1 — SOC visibility" section is the contract for this plan). Vigil v1
is specified in `docs/plans/2026-09-20-vigil-plan.md` and its invariants hold
unchanged: closed TOML schema, three-valued verdicts (`verde` / `picat` /
`NECITIT`), exit codes 0/1/2/3, incidents, outbox, Telegram, `/status`.

Files that matter:

- `modules/services/vigil-schema.nix` — eval-time contract validator. The type
  list is at the `builtins.elem kind [ … ]` line; per-type `astept`/`tinta`
  rules follow it.
- `pkgs/vigil/lib/schema.mjs` — runtime validator (`TYPES` array). It MUST
  accept and reject exactly what `vigil-schema.nix` does.
- `pkgs/vigil/schema-fixtures.json` — shared fixtures read by both
  `pkgs/vigil/schema.test.mjs` and `tests/module-eval.nix`; this is how eval
  and runtime are kept identical. Add cases here, not in only one side.
- `pkgs/vigil/lib/checks.mjs` — the verdict dispatcher (`switch (c.verifica)`).
  Follow the `hass-state` case as the pattern for an HTTP sensor
  (timeout budget, `unreadable(...)` reasons, no throw escapes).
- `pkgs/vigil/checks.test.mjs`, `pkgs/vigil/checker.test.mjs` — unit tests;
  `pkgs/vigil.nix` runs the suite at build time (`node vigil.mjs autoproba`).
- `modules/services/vigil.nix` — the unit, its environment (`VIGIL_*`
  variables) and sandbox (`User=vigil`, `ProtectSystem=strict`,
  `RestrictAddressFamilies`). Note the socket's `IPAddressAllow` is tailnet
  only; the checker service must be able to reach 127.0.0.1.
- `tests/module-eval.nix`, `tests/vigil-module.nix` — eval assertions; follow
  their style for new asserts.
- `flake.nix` `checks` — where VM and eval tests are registered.
- Contracts: `hosts/sancta-choir/vigil-contracts/`,
  `hosts/rpi5-full/vigil-contracts/`; counts in each host's
  `services.vigil.expectedContracts`.

Sensor versions in nixpkgs 25.11 (verified 2026-10-31): crowdsec 1.7.2,
osquery 5.21.0, netdata 2.8.4 — all have NixOS modules.

## Tasks

### Task 1: Schema for the three new types
- [x] Add `crowdsec`, `osquery`, `anomaly` to the type list in both `modules/services/vigil-schema.nix` and `pkgs/vigil/lib/schema.mjs`
- [x] `crowdsec`: `tinta` is an `http://127.0.0.1:<port>` or `http://[::1]:<port>` URL (any other host is a validation error); `astept = { scenariu = "<string>", fereastra_min = <int ≥ 1> }`; `prag` integer ≥ 1 required
- [x] `osquery`: `tinta` matches `^[a-z][a-z0-9_]{0,63}$` (a query name, never SQL); `astept = { permis = [ <strings> ] }` (may be empty); no `prag`
- [x] `anomaly`: `tinta` matches a Netdata chart id `^[a-z0-9_]+\.[a-z0-9_]+$`; `prag` integer 1–100 required; no `astept`
- [x] Add valid + invalid cases for each type to `pkgs/vigil/schema-fixtures.json` (valid, unknown key, missing required field, non-loopback crowdsec `tinta`, SQL-looking osquery `tinta`, `prag = 0` and `101` for anomaly)
- [x] Run the vigil package tests (`nix build .#vigil` builds and runs autoproba) and `nix build .#checks.x86_64-linux.module-eval` if a builder is available; both must pass (no linux builder on this darwin host, so neither nix build could run: node autoproba suite run directly, 175/177 with the 2 failures also present on clean HEAD (darwin env); tests/vigil-module.nix incl. schema-parity evaluated to true)

### Task 2: crowdsec checker
- [x] In `pkgs/vigil/lib/checks.mjs` add `case 'crowdsec'`: read the machine credential file from `VIGIL_CROWDSEC_CREDENTIALS` (YAML with `login`/`password`/`url`; parse only those three keys), POST `/v1/watchers/login` for a JWT, GET `/v1/alerts?scenario=<scenariu>&since=<N>m`, count alerts
- [x] Verdicts: count ≥ `prag` → `picat` (`crowdsec-alerts`); below → `verde`; missing env/credential, non-200, unparsable JSON, timeout → `NECITIT` with distinct reasons (`crowdsec-config`, `crowdsec-auth`, `crowdsec-response`, `crowdsec-timeout`)
- [x] Use the same 10 s total budget pattern as `hass-state`; never log the password or token
- [x] Tests in `pkgs/vigil/checks.test.mjs` against a fake local HTTP server: 0 alerts → verde, prag alerts → picat, 401 → NECITIT, garbage body → NECITIT, server down → NECITIT

### Task 3: osquery checker
- [ ] Add `case 'osquery'`: read the osquery filesystem-logger results file at `VIGIL_OSQUERY_RESULTS` (JSON lines, osquery `snapshot` format), take the newest snapshot whose `name` equals `pack_vigil_<tinta>`
- [ ] Row key per query is fixed in code: `listening_ports` → `port/protocol/name`, `local_users` → `username`, `suid_bins` → `path`, `etc_fim` → `target_path` (events format); unknown query name → `NECITIT` (`osquery-query`)
- [ ] Verdicts: any key not in `permis` → `picat` (`osquery-unexpected`, include at most the first 3 unexpected keys in the reason detail); none → `verde`; file missing, newest snapshot older than 2 × `VIGIL_OSQUERY_INTERVAL` seconds, or unparsable → `NECITIT`
- [ ] Read the file tail only (bounded, e.g. last 4 MiB) so a large log cannot stall the tick
- [ ] Tests with fixture result files: allowed only → verde, one extra port → picat, stale snapshot → NECITIT, missing file → NECITIT, truncated JSON line → NECITIT

### Task 4: anomaly checker
- [ ] Confirm the Netdata 2.8.4 query for a chart's anomaly rate from the packaged docs or `netdata` source in the nix store (the v1/v2 data API with the anomaly-bit option); record the exact URL form in a comment with where it was verified
- [ ] Add `case 'anomaly'`: query `http://127.0.0.1:19999` (from `VIGIL_NETDATA_URL`) for the chart's anomaly rate over the last tick interval; take the maximum across dimensions
- [ ] Verdicts: rate ≥ `prag` → `picat` (`anomaly-rate`); below → `verde`; Netdata down, unknown chart (404), no anomaly data yet (ML untrained) → `NECITIT`
- [ ] Tests against a fake server with recorded response bodies for each case

### Task 5: Sensor module
- [ ] Create `modules/services/vigil-sensors.nix` with `services.vigil.sensors.{crowdsec,osquery,netdata}.enable` (`lib.mkEnableOption`), imported by `modules/services/vigil.nix`
- [ ] CrowdSec: enable `services.crowdsec` with the sshd/journald acquisition, LAPI on 127.0.0.1 only, console enrolment off, its own notifications off, no bouncer; a root oneshot `vigil-crowdsec-register` (After crowdsec) that runs `cscli machines add vigil --auto -f /var/lib/vigil/crowdsec.yaml --force` only if the file is absent, then `chown vigil:vigil` + `chmod 0400`; export `VIGIL_CROWDSEC_CREDENTIALS`
- [ ] osquery: enable `services.osquery` with a `vigil` pack containing exactly the four queries from Task 3 (snapshot mode, interval 300 s), filesystem logger results file readable by group `vigil`; export `VIGIL_OSQUERY_RESULTS` and `VIGIL_OSQUERY_INTERVAL`
- [ ] Netdata: enable `services.netdata` bound to 127.0.0.1:19999, ML enabled, cloud/claim disabled, retention capped (dbengine tier 0 only, ≤ 256 MiB disk); export `VIGIL_NETDATA_URL`
- [ ] `MemoryMax` per sensor unit: netdata 400M, crowdsec 256M, osquery 128M
- [ ] Ensure the vigil checker service can reach loopback (adjust its `IPAddressAllow` only if one is set on the service; do not widen the tailnet socket)
- [ ] Add asserts to `tests/module-eval.nix`: type list contains the three types; each sensor's listen address is loopback; `MemoryMax` set on all three units; no crowdsec bouncer unit exists

### Task 6: Contracts with config-derived allowlists
- [ ] In `vigil-sensors.nix`, generate the osquery contracts (`porturi-noi`, `utilizatori-noi`, `suid-nou`, `etc-schimbat`) with `pkgs.writeTextDir` and append that directory to `services.vigil.contractsDirs`; derive `permis` from evaluated config: `users.users` names for `local_users`, `networking.firewall` + the declared service ports for `listening_ports`, the `security.wrappers` paths for `suid_bins`; `etc_fim` `permis = [ ]`
- [ ] Generate `ssh-bruteforce` (crowdsec, `crowdsecurity/ssh-bf`, window 15, prag 1) and `cpu-anomalie` / `mem-anomalie` (anomaly on `system.cpu` / `system.ram`, prag 20, `picat_dupa = 3`) the same way, only when the matching sensor is enabled
- [ ] Make `expectedContracts` on each host add the generated count automatically (derive it from the generated set; do not hand-edit a number per host)
- [ ] Enable all three sensors in `hosts/sancta-choir/configuration.nix` and `hosts/rpi5-full/configuration.nix`
- [ ] `nix eval` both hosts' `config.system.build.toplevel.drvPath` (or `nix flake check --no-build`) and run module-eval; the listening-port allowlist printed for choir must include 22, 8739, 8747, 19999 (loopback) and the crowdsec LAPI port

### Task 7: VM behaviour test
- [ ] Create `tests/vigil-soc.nix` (`pkgs.testers.runNixOSTest`), register it in `flake.nix` checks next to `vigil-module`
- [ ] One node with sshd + vigil + all three sensors; wait for each sensor and for Netdata ML to report anomaly data (poll with a timeout, do not sleep blindly)
- [ ] Assert: at rest every generated contract reads `verde` (`vigil check --json` or the state file)
- [ ] Assert: 10 failed ssh password logins from the test driver → `ssh-bruteforce` `picat` and an incident opens in `incidents.json`
- [ ] Assert: `nc -l 4444 &` → after the next osquery interval (set to 30 s in the test) `porturi-noi` `picat`
- [ ] Assert: a CPU burn (`stress-ng` or a busy loop) → `cpu-anomalie` `picat` within its tick budget; if ML training time makes this unreliable in CI, assert the checker's NECITIT→verdict path with a pinned trained model is out of reach and document it, but keep the other assertions
- [ ] Assert: stopping each sensor in turn makes its contracts `NECITIT`, never `verde`
- [ ] Build it: `nix build .#checks.x86_64-linux.vigil-soc` (needs an x86_64-linux builder; if none is available locally, push the branch and use the CI run as the evidence)

### Task 8: Docs and handoff
- [ ] Update the status line of `docs/plans/2026-10-31-vigil-horizon-design.md` to "phase 1 implemented, not deployed"
- [ ] Add the three sensors to the Services table in `CLAUDE.md` as loopback-only, with a one-line note that Vigil is their only alerting path
- [ ] Write the attended deploy + live acceptance steps (planted ssh-failure burst reaches Telegram; `systemctl show -p MemoryCurrent` under caps after 24 h) as a short section at the end of the design doc; do not execute them

## Constraints

- Do NOT deploy anything, run `nixos-rebuild switch`/`boot`, or ssh to any host. Deploys are attended owner steps (choir is a non-atomic GRUB host).
- Do NOT change v1 verdict semantics, exit codes, incident open/close rules, outbox or Telegram delivery. New types plug into the existing dispatcher only.
- Do NOT add any enforcement: no CrowdSec bouncer, no osquery distributed/write features, no `[recuperare]` handling. Phase 4 owns actions.
- Do NOT add Suricata, Wazuh, docker, compose or any model/LLM call. Phase 2 owns models.
- Sensors bind loopback only, with their own notification paths off. Vigil stays the only speaker.
- Do NOT create or edit `.age` secrets. The CrowdSec credential is generated on-host by the register oneshot.
- Never print or log credentials, JWTs or tokens, including in tests.
- `vigil-schema.nix` and `schema.mjs` must stay identical in behaviour; every schema change gets a shared fixture in `schema-fixtures.json`.
- Every unreadable condition degrades to `NECITIT`. A sensor fault must never read `verde` and must never crash the tick (exit 3 stays reserved for internal faults).
- The `vigil-kb` security KB repo is private and lives on choir; do not create it or any runbook content in this public repo.
- Follow repo conventions: `lib.mkIf`/`lib.mkEnableOption`, run `nix fmt` before each commit, commit with `nix shell nixpkgs#trivy -c git commit` on darwin (pre-commit needs trivy), one commit per task, branch `feat/vigil-soc-p1` off `origin/main`.
