Build vigil: the agent that watches, explains and recovers the Sancta fleet — contracts decide, the model explains after, recovery only where declared, on choir and rpi5.

## Context

Design (private, on the soul volume: `index/design/vigil-design.md`, v2 after two
revmux rounds; the owner has read and approved it). What this repo needs to know:

- **vigil** is a systemd timer (5 min) running `vigil-check` as a **dedicated
  system user `vigil`** (created by the module; `SupplementaryGroups =
  [ "systemd-journal" ]`), `ProtectSystem=strict`, `ProtectHome=true`,
  `StateDirectory=vigil` (mode 0755 so a sancta-owned explain unit can read it),
  an explicit `path` (the exit-127 scar), on **two hosts**: `sancta-choir` and
  `rpi5-full`. Same module, different contract lists. Verified 2026-09-20:
  `sancta` does not exist on rpi5-full (soul-mirror-pull runs as root), and
  `sancta-gallery`/`sancta-membrane` are SYSTEM units (`User=sancta`), not
  user units — so the design's "run as sancta, restart with `systemctl --user`"
  was wrong on both counts; this plan supersedes design decision 5.
- A **contract** is one TOML file, one target: `[contract]` (`nume`, `ce`,
  `verifica`, `tinta`, `astept`/`prag`, `la`, `picat_dupa`, optional `jurnal`,
  optional `secret`), optional `[recuperare]` (`act` absolute path, `max`),
  `[spune]` (`nivel`). Check types are a **closed set**: `tcp | http | unit | age
  | disk | mount | cmd | hass-state`. `cmd` is a closed allow-list of argv shapes
  declared in the module, never a free string.
- Verdicts are **three-valued**: `verde`, `picat`, `NECITIT` (could not observe —
  exit 127, missing file, unparsable output). NECITIT is never green and is
  reported as its own thing. **Absence is not a pass.**
- **Recovery of a system unit needs a right vigil does not have.** A scoped
  polkit rule (`security.polkit.extraConfig`: subject user `vigil`, action
  `org.freedesktop.systemd1.manage-units`, unit ∈ {sancta-gallery, sancta-membrane},
  verb `restart`) is right #4 and is introduced only in Task 6, as its own
  reviewable step. Until then every contract is report-only.
- An **incident** opens after `picat_dupa` consecutive `picat` ticks, closes after
  the same count of `verde` plus a 30-minute hold-down; recovery budget is `max`
  per incident AND 2 per contract per rolling 24 h, persisted; when exhausted:
  escalate once, stay red until `vigil ack <nume>`.
- **explain** (choir only) is a SEPARATE unit, `vigil-explain`, running as
  `sancta` (the account that holds the model CLI's auth; `vigil` cannot), on
  its own 5-minute timer, reading `/var/lib/vigil/incidents.json` and keeping
  its own "explained" marks — decoupled from vigil-check by files, so no
  privilege crosses between the two users. It runs once per incident open and once at escalation,
  with a *redacted, declared* journal slice: only units listed in the contract's
  `jurnal`, last N minutes, through a deny-list (`homeassistant.components.http.ban`,
  `homeassistant.auth`, `mobile_app`, lines with `person.`/`device_tracker.`, IP
  literals). rpi5 is report-only-without-explanation in v1.
- vigil keeps its own decision ledger at `/var/lib/vigil/decisions.jsonl`
  (same line format as `bin/decision`); the soul-volume ledger is 0700 sancta
  and unreachable from `vigil`.
- **say** = Telegram (the existing `backup-telegram-env` EnvironmentFile shape:
  `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`; the chat is the owner's DM) + the
  status-row state file. It emits contract `nume`, verdict, conclusion — **never
  journal text** — asserts the API returned `ok:true`, and records the last
  successful send for an `age` contract to watch.
- Peer-agent liveness: each vigil writes a **tick** file; a socket-activated
  responder on **:8747** serves it (no resident daemon); the peer checks it with
  `age`. ACL already grants choir→rpi5:8747 (measured 2026-09-20) and rpi5→choir
  `ip:*`.
- **Privacy wall, law not style:** this repo is PUBLIC. No contract in this repo
  may name a family member's device, account or dashboard. Family-facing
  contracts on rpi5 arrive as agenix secrets (one `.age` per contract, decrypted
  into the contracts directory), authored by the owner. Contracts may name only
  fixed-location devices; entities backed by `mobile_app`/`device_tracker` are
  excluded. Outbound messages use the contract's generic `nume`.
- Already in place: `secrets/ha-vigil-token.age` (#593) — token of a dedicated
  non-admin HA account `vigil`, recipients `users ++ [rpi5]`; the house's
  `guardedBlockingCommand` pattern in `modules/services/claude-code-managed-settings.nix`;
  `sancta-archive-deadman.nix` as the module template (store-backed script,
  timer, strict sandbox, `module-eval` wiring test); `tests/module-eval.nix`.
- Bottleneck (from the design's `GÂTUL ACUM`): the rpi5 half must be deployable
  with **one `nixos-rebuild switch` by the owner** — no manual steps on the Pi.
  Task order below follows that.

Files this plan touches: `pkgs/vigil/` (new: `vigil-check.mjs`, `vigil-say.mjs`,
`vigil-repair.mjs`, `vigil-explain.mjs`, `vigil-tick.mjs`, `lib/`), `pkgs/vigil.nix`
(derivation), `modules/services/vigil.nix` (new), `hosts/rpi5-full/configuration.nix`,
`hosts/sancta-choir/configuration.nix`, `hosts/*/vigil-contracts/*.toml` (public
contracts), `secrets/secrets.nix`, `tests/module-eval.nix`, `flake.nix` (package
export).

## Tasks

### Task 1: vigil-check — the deterministic core, with a negative arm that can go red
- [ ] Create `pkgs/vigil/vigil-check.mjs` (Node ESM, zero dependencies, `#!/usr/bin/env node`). It reads every `*.toml` in the directories given as argv, parses with a small TOML subset parser in `pkgs/vigil/lib/toml.mjs` (tables, strings, integers, booleans, inline tables, arrays of strings — nothing else; anything else is a parse error → the contract is NECITIT and named). Validate the schema: closed `verifica` set, required fields per type, `astept`/`prag` per type, `[recuperare].act` must be an absolute path, `max` integer ≥ 1.
- [ ] Implement the eight check types in `pkgs/vigil/lib/checks.mjs`: `tcp` (connect, timeout 5 s), `http` (status class + optional body regex + optional `astept.prospetime` — the body is an ISO timestamp that must be younger than the given duration —, timeout 10 s, no redirects), `unit` (`systemctl is-active <name>` via absolute path from `process.env.VIGIL_SYSTEMCTL`; system scope only — there is no `--user` in v1), `age` (`tinta` is either a file path — mtime — or `unit:<name>.service`, in which case the age is `ExecMainExitTimestamp` from `systemctl show` and `Result=success` is required; `tinta_glob` picks the newest match; **missing file / unknown unit / Result≠success → NECITIT**), `disk` (`statfs` use% vs `prag`), `mount` (`/proc/self/mountinfo` contains `tinta`), `cmd` (argv from a closed allow-list `VIGIL_CMD_ALLOW` of absolute paths; exit 127 → NECITIT; non-zero → picat; stdout compared to `astept.valoare` when given), `hass-state` (`GET $HASS_URL/api/states/<tinta>` with bearer from the file at `secret`; `state === "unavailable"` → picat; HTTP ≠ 200 or missing token file → NECITIT).
- [ ] Implement the incident state machine in `pkgs/vigil/lib/incident.mjs`, persisted as JSON in `$STATE_DIRECTORY/incidents.json`: open/close/hold-down/escalation exactly as in Context; the 24 h rolling recovery budget; `ack`. Pure functions over `(state, verdict, now)` so they are testable without I/O.
- [ ] Output: one JSON line per contract on stdout (`nume`, `verifica`, `verdict`, `motiv`, `incident: {stare, deschis_la, recuperari}`), summary on stderr, exit `0` = all verde · `1` = any picat · `2` = any NECITIT or **zero contracts read**. Zero contracts read is never exit 0.
- [ ] `--autoproba`: synthesise contracts **in memory** (never write files): a loud failure (`tcp` to a port nothing listens on) → picat; a silent one (`cmd` with `/nonexistent/bin` in the allow-list) → NECITIT; `age` on a missing file → NECITIT; a `verde` one (`mount` on `/`); the state machine walked through open → hold-down → close and through budget exhaustion → escalation. Assert the TEXT of each verdict line, not only the code. Exit 2 on any deviation.
- [ ] Tests: `node --test pkgs/vigil/` with unit tests for the TOML subset, every check type against local fixtures (a throwaway `net.createServer`, a temp file for `age`), and the state machine table. Add a **mutation script** `pkgs/vigil/mutate.sh` that flips (a) "missing file → NECITIT" to green, (b) the hold-down to 0, (c) NECITIT to exit 0 — each mutant must make `--autoproba` exit non-zero **from an assertion**, not from a crash (check stderr contains `EȘEC`, not a stack trace).
- [ ] Run `~/.claude/index/bin/absenta pkgs/vigil/*.mjs pkgs/vigil/lib/*.mjs` → must exit 0 (no catch-that-passes, no empty catch). Fix, don't sentinel.

### Task 2: vigil-say and the tick — the voice, and the proof it can speak
- [ ] Create `pkgs/vigil/vigil-say.mjs`: reads one JSON incident event on stdin (`nume`, `verdict`, `stare`, `concluzie?`, `gazda`), sends `sendMessage` to `$TELEGRAM_CHAT_ID` with `$TELEGRAM_BOT_TOKEN` (both from the EnvironmentFile the unit loads; never logged), text = `<emoji> [<gazda>] <nume>: <verdict> — <stare>` + optional one-line `concluzie`. **Refuse** (exit 2, no send) if the event carries a key named `jurnal` or any field longer than 500 chars — journal text must not reach this program. Assert the API response has `"ok":true`; on success write `$STATE_DIRECTORY/last-say-ok` (mtime is the fact); on failure exit 1 and write `last-say-fail` with the HTTP status only.
- [ ] Also write the status-row line: append/replace a `vigil` entry in `$STATE_DIRECTORY/row.json` (`{gazda, stare: "liniște" | "incident: <nume>", la}`); the existing status-row poller may read it later — this task only produces the file.
- [ ] Create `pkgs/vigil/vigil-tick.mjs`: (a) `write` mode — `vigil-check` calls it at the end of every tick to write `$STATE_DIRECTORY/tick` (ISO timestamp + last summary); (b) `serve` mode — reads stdin/stdout only (for systemd socket activation with `Accept=yes`), replies `HTTP/1.0 200` with the tick file content, `404` if absent, closes. No listening code in the program itself.
- [ ] `--autoproba` for say: run against a local `http.createServer` that plays Telegram (`{"ok":true}` / `{"ok":false}` / 429 / connection refused); assert `last-say-ok` is touched only on ok, that a `jurnal` key is refused, and that a 600-char field is refused. For tick: pipe a request through `serve` and assert the body equals the file.
- [ ] `absenta` clean on both files; mutation: make say ignore `"ok":false` → autoproba must go red from an assertion.

### Task 3: services.vigil — the NixOS module, contracts validated at eval time
- [ ] Create `pkgs/vigil.nix`: a derivation installing the `.mjs` files with `${pkgs.nodejs}/bin/node` shebang rewritten (or wrapper scripts), plus `bin/vigil` (dispatcher: `check|say|repair|explain|tick|ack|autoproba`). Export from `flake.nix` under `packages.<system>.vigil` for both `x86_64-linux` and `aarch64-linux`. `nix build .#packages.x86_64-linux.vigil` must succeed and `result/bin/vigil autoproba` must exit 0.
- [ ] Create `modules/services/vigil.nix` with options: `enable`, `user` (default `vigil`; the module declares `users.users.${user}` as an `isSystemUser` with its own group and `extraGroups = [ "systemd-journal" ]`), `contractsDirs` (list of paths — store paths for public contracts, plus the agenix decrypt directory), `telegramEnvFile` (path, agenix), `hassTokenFile` (path or null), `hassUrl` (string or null), `tickPort` (default 8747, `listenAddress` default the host's tailnet IP — never `0.0.0.0`), `explain.enable` (default false), `explain.command` (argv list, default null), `cmdAllow` (list of absolute paths), `interval` (default `5min`).
- [ ] **Validate every public contract at eval time** with `builtins.fromTOML` + assertions: closed `verifica` set, required fields per type, `[recuperare].act` absolute, no `tinta` containing a `100.` tailnet address for `http`/`tcp` when the contract is marked `local = true`. A bad contract fails `nix build`, not the first tick.
- [ ] Wire: `systemd.services.vigil` (oneshot; `User`; `ExecStart = ${vigil}/bin/vigil check <dirs>` then `vigil tick write`; `EnvironmentFile = cfg.telegramEnvFile`; `Environment = VIGIL_SYSTEMCTL=${pkgs.systemd}/bin/systemctl VIGIL_CMD_ALLOW=…`; `path = [ pkgs.coreutils pkgs.systemd pkgs.curl ]`; `StateDirectory = "vigil"`; `ProtectSystem = "strict"`; `ProtectHome = true`; `StateDirectoryMode = "0755"`; `PrivateTmp = false` (the strict claim is filesystem-only; say so in a comment); `OnFailure = [ "vigil-say-failure.service" ]` — a unit that sends one message "vigil itself failed on <host>"), `systemd.timers.vigil` (`OnUnitActiveSec = cfg.interval`, `Persistent = true`), `systemd.sockets.vigil-tick` (`ListenStream = <ip>:<port>`, `Accept = true`) + `systemd.services."vigil-tick@"` (`ExecStart = ${vigil}/bin/vigil tick serve`, `StandardInput = socket`, same user, same sandbox).
- [ ] Add to `tests/module-eval.nix`, in the house's style (assert the rendered shape, quantify over all contracts): the unit runs as the configured user; `ProtectSystem=strict`; `StateDirectory=vigil`; `path` non-empty; the socket listens on the tailnet IP and never `0.0.0.0`; the timer is persistent; and a **negative arm**: a fixture host with a contract whose `verifica = "shell"` (not in the set) must make eval throw with the contract's file name in the message.
- [ ] `nix fmt`; `nix build .#checks.x86_64-linux.module-eval` green; `absenta` over the module's embedded scripts if any.

### Task 4: rpi5-full — the half that matters, deployable with one switch
- [ ] Write the **public** rpi5 contracts under `hosts/rpi5-full/vigil-contracts/`: `tailscaled.toml` (unit), `ha-alive.toml` (http `http://127.0.0.1:8123/manifest.json`, `astept.body = "\"name\""`), `ha-served.toml` (http against the host's own serve URL `https://rpi5.tail4249a9.ts.net:8123/manifest.json`, status 200 — this exercises serve, not just HA), `soul-mirror-pull.toml` (age, prag 8d, `tinta = "unit:soul-mirror-pull.service"` — the vault dir is 0700 root, unreadable; the unit's last successful run is the observable fact), `choir-host.toml` (tcp `<choir tailnet ip>:8743`), `choir-tick.toml` (http `http://<choir tailnet ip>:8747/` status 200 — rpi5→choir is `ip:*`), `channel.toml` (age on `$STATE_DIRECTORY/last-say-ok`, prag 1d). Generic `nume` values; no device names anywhere in this directory.
- [ ] Register the **private** contract secrets in `secrets/secrets.nix` (recipients `users ++ [ rpi5 ]`): `vigil-rpi5-contract-1.age`, `-2.age`, `-3.age` with a comment stating they are family-facing `hass-state` contracts authored by the owner, one contract per file, decrypted into `/run/agenix.d/…` and passed to `contractsDirs`. **Do not create the `.age` files** (his hand; the chicken-and-egg rule) — and do not declare `age.secrets` for them in the host until he says they exist. Write the exact `agenix -e` commands and a **template** TOML (with placeholder entity `sensor.EXAMPLE`) in the PR description, not in the repo.
- [ ] Enable in `hosts/rpi5-full/configuration.nix`: `services.vigil = { enable = true; contractsDirs = [ ./vigil-contracts ]; telegramEnvFile = secret "backup-telegram-env"; hassTokenFile = secret "ha-vigil-token"; hassUrl = "http://127.0.0.1:8123"; tickPort = 8747; cmdAllow = []; }` and declare `age.secrets.ha-vigil-token = { file = …; owner = "vigil"; }`. Secrets owned by `vigil` (`owner = "vigil"`). The journal right comes from the module's `extraGroups`; nothing else to add on this host.
- [ ] `nix build .#checks.x86_64-linux.module-eval` and the aarch64 eval (`nix eval .#nixosConfigurations.rpi5-full.config.systemd.services.vigil.serviceConfig.ExecStart`) green; `nix fmt`; PR. **Closing check for this task (his hand, after switch):** `systemctl status vigil.timer` active; `journalctl -u vigil -n 20` shows one tick with 7 contracts, none NECITIT except the private three if their `.age` files are not yet there; `curl http://<rpi5 tailnet ip>:8747/` from choir returns the tick. Record the outcome in the PR.

### Task 5: sancta-choir — the second half, and the peer check both ways
- [ ] Write `hosts/sancta-choir/vigil-contracts/`: `tailscaled.toml` (unit), `galeria.toml` (http `http://127.0.0.1:8739/` 200 — **report-only in this task**; the `[recuperare]` section is added in Task 6 together with the polkit rule that makes it executable), `membrana.toml` (same shape on `:8743`), `soul-mirror.toml` (age, prag 8d, `tinta = "unit:sancta-soul-mirror.service"` — `/var/lib/sancta` is 0700 sancta, unreadable from `vigil`), `disk-root.toml` (disk `/`, prag 85), `build-volume.toml` (mount `/mnt/sancta-build-volume`), `open-webui.toml` (http `http://127.0.0.1:8080/health` 200), `n8n.toml` (http `http://127.0.0.1:5678/healthz` 200 + body `"status":"ok"`), `rpi5-host.toml` (tcp `<rpi5 tailnet ip>:8747`), `rpi5-tick.toml` (http `http://<rpi5 tailnet ip>:8747/` 200, `astept.prospetime = "15m"`), `channel.toml` (age, 1d).
- [ ] Telegram on choir: `backup-telegram-env.age` is keyed for rpi5 only. Add `sancta-choir` to its recipients in `secrets.nix` and write in the PR body the exact re-key command for the owner (`agenix -r`, from choir as the `users` key). Do not declare `age.secrets.backup-telegram-env` on choir until he confirms the re-key — otherwise the switch fails at activation.
- [ ] Enable `services.vigil` on choir (no `hassTokenFile`), `explain.enable = false` in this task. Telegram env `owner = "vigil"`. module-eval green, `nix fmt`, PR. Closing check (his hand, after switch and the re-key): `journalctl -u vigil -n 30` shows 11 contracts with verdicts; `curl http://<choir tailnet ip>:8747/` from rpi5 returns choir's tick; the two peer contracts are verde on both hosts.

### Task 6: vigil-repair and vigil-explain — the arms that act, gated by the law
- [ ] Create `pkgs/vigil/vigil-repair.mjs`: invoked by `vigil-check` on incident **open** only; runs `[recuperare].act` (argv split, absolute path verified; the act is `${systemd}/bin/systemctl restart <unit>` at SYSTEM scope). **This is where right #4 enters**: add to `modules/services/vigil.nix` an option `recoverableUnits` (list of unit names) that renders a `security.polkit.extraConfig` rule allowing exactly user `vigil`, action `org.freedesktop.systemd1.manage-units`, verb `restart`, unit ∈ that list — nothing else. A module-eval test must assert the rendered rule names only those units and only `restart`. Prove it on choir before wiring any contract: as `vigil`, `systemctl restart sancta-gallery` succeeds and `systemctl restart sancta-worker` is refused. If polkit refuses everything (e.g. polkit not enabled on the host), STOP and record it — **do not invent a sudo path**. Every act → `/var/lib/vigil/decisions.jsonl` in `bin/decision`'s line format. Respects per-incident `max` and the 24 h budget from Task 1.
- [ ] Create `pkgs/vigil/vigil-explain.mjs` (choir only; `explain.enable = true`) and its own unit `vigil-explain.service` + timer (`User = sancta`, `ProtectSystem=strict`, `ReadWritePaths` = the model CLI's config dir only, `ReadOnlyPaths=/var/lib/vigil`, its own `StateDirectory=vigil-explain`): it reads `/var/lib/vigil/incidents.json`, keeps `explained` marks in its own state, and for each new open/escalation builds input = the contract, the last N verdicts, and a journal slice built by `journalctl -u <each unit in jurnal> --since -15min -o cat` (absolute path, the user is in `systemd-journal`), passed through `lib/redact.mjs`: deny-list from Context + IP-literal stripping + a per-contract `jurnal_filtru` regex (HA contracts: only `roborock`-logger lines). The redacted slice is written to `$STATE_DIRECTORY/explain/<nume>-<ts>.txt` for audit. Then runs `explain.command` (argv, e.g. `claude -p --model sonnet` or `codex exec`) with a fixed prompt file from the package (`prompts/explain.md`: "state why, what is recoverable within the declared act, propose one contract; never quote the journal"), captures stdout, truncates to 500 chars, and hands `{concluzie}` to `vigil-say`. Runs only on incident open and escalation; gated by `~/.claude/index/bin/meter` (skip with a one-line note if over budget).
- [ ] `--autoproba` for both: repair against a throwaway system unit declared by the module for probes only (`vigil-probe.service`, `ExecStart=/bin/true`, in `recoverableUnits`) that a probe contract restarts — proving the polkit rule, the principal and the absolute-path act; explain against a fixture journal containing every deny-listed class and an IP — assert none of them survives redaction, assert a 501-char model output is truncated, assert the explain command is **not** invoked when the incident is not new. Mutation: disable one deny-list entry → autoproba red from an assertion.
- [ ] Enable `explain` on choir in `hosts/sancta-choir/configuration.nix` with the chosen `explain.command`; `absenta` clean; module-eval green; PR. Closing check (his hand): a deliberately failed probe contract on choir produces one Telegram message with a conclusion and one `explain/*.txt` file with zero deny-listed lines.

### Task 7: the private contracts on rpi5, and the first real incident
- [ ] Once the owner has created the three `.age` files (Task 4's commands), declare `age.secrets.vigil-rpi5-contract-{1,2,3}` on rpi5-full (`owner = "sancta"`), add their decrypt directory to `contractsDirs`, PR, CI. After his switch: `journalctl -u vigil` shows 10 contracts on rpi5, the three private ones with real verdicts, none NECITIT.
- [ ] Write the post-deploy verification as a checklist in `docs/plans/completed/2026-09-20-vigil-postdeploy.md` (commands only, no device names): timer active on both hosts; both tick endpoints answer from the peer; `last-say-ok` younger than 1 d on both; one deliberate probe incident end-to-end. **The plan is done only when the first real incident (a contract that fails on a real day) reaches Telegram** — until then vigil is a file that guards nothing; record the date of that first incident in the same file.

## Constraints

- This repo is PUBLIC. **No contract, comment, test or commit message names a family member's device, account, dashboard or entity id.** Family-facing contracts exist only as agenix ciphertext authored by the owner. If a task cannot be completed without naming one, stop and say so.
- No `sudo`, no root. The ONE privilege grant is the scoped polkit rule of Task 6 (`vigil` → `restart` on the listed units); it is introduced in its own task with its own eval test, never widened to `*`. No new listener except the socket-activated tick on `:8747` bound to the tailnet IP; no `0.0.0.0`; no LocalAPI socket; no change to the tailnet ACL (already done: choir→rpi5:8747).
- The check-type set is closed; `cmd` is an allow-list of absolute paths; every `[recuperare].act` is an absolute path; `NECITIT` is never exit 0; zero contracts read is exit 2.
- Every new executable has `--autoproba` that asserts **text**, not only exit codes, and a mutation that turns it red from an assertion (stderr `EȘEC`), never from a crash. Run `~/.claude/index/bin/absenta` over all new `.mjs` before opening a PR; it must exit 0.
- Do not touch: the soul volume, `soul-mirror*`, `/nix`, `managed-settings`, `sancta-worker`, `herdr`, `gatus.nix` (sq071 is separate).
- Follow the house: worktree + PR (never push to main), `nix fmt` in the background, `nix build .#checks.x86_64-linux.module-eval` before every PR, merge only on green CI **and zero medium+ review findings** (read the bot comments), deploys/switch/re-keys are the owner's hand and are written as exact commands in the PR body. Security findings return to the session, never onto the public PR.
- `hosts/rpi5-full` tracks `nixos-raspberrypi`'s nixpkgs pin, `sancta-choir` the root pin; anything that differs between them (option names, `nodejs` version) must be eval'd on both.
- Order is the bottleneck's: Task 4 (rpi5, one switch) before Task 5 (choir); Task 6 last. Do not reorder to make choir "nicer" first.
