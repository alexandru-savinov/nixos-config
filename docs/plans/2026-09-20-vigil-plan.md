Build vigil: the agent that watches, explains and recovers the Sancta fleet — contracts decide, the model explains after, recovery only where declared, on choir and rpi5.

## Context

v3 of this plan (2026-09-20): two revmux rounds (r1: three Opus lenses + Codex
`gpt-5.6-sol` adversarial, 31 findings; r2 focused on what v2 introduced, 16
findings, one critical). All 47 folded in; the disposition tables are at the end. Design: private, on the soul volume
(`index/design/vigil-design.md`, v2.1); the owner has read and approved it.
What this repo needs to know:

- **vigil** is a systemd timer running `vigil-check` as a **dedicated system
  user `vigil`** (declared by the module: `isSystemUser`, own group,
  `extraGroups = [ "systemd-journal" ]`), `ProtectSystem=strict`,
  `ProtectHome=true`, `StateDirectory=vigil` (`StateDirectoryMode=0755`), an
  explicit `path`, on **two hosts**: `sancta-choir` and `rpi5-full`. Same module,
  different contract lists. Verified 2026-09-20: `sancta` does not exist on
  rpi5-full; `sancta-gallery`/`sancta-membrane` are SYSTEM units; polkit is
  **not enabled** on choir today; `sancta` is not in `systemd-journal` and the
  house deliberately declined that grant (`sancta-journal-export.service`
  exists instead).
- A **contract** is one TOML file, one target. Schema (closed; unknown keys are
  a validation error): `[contract]` — `nume` (unique across all directories),
  `ce`, `verifica`, `tinta`, `astept` (inline table) or `prag`, `la`,
  `picat_dupa`, optional `peer = true` (the only way a `100.` tailnet address is
  allowed in `tinta`), optional `jurnal` (array of unit names), optional
  `jurnal_filtru` (string, a regex); optional `[recuperare]` — `act` (exactly
  `<abs systemctl> restart <unit>`), `max`; `[spune]` — `nivel = "incident" |
  "nota"` (`nota` = status row + **one** Telegram message, repeats suppressed
  until the state changes; `incident` = every transition). Check types are a closed
  set: `tcp | http | unit | age | disk | mount | cmd | hass-state`. `cmd` is an
  allow-list of **absolute executable paths** (`cmdAllow`); no argv-shape
  matching in v1. `$VAR` expansion in `tinta` is **not** supported: paths are
  absolute.
- Verdicts are **three-valued**: `verde`, `picat`, `NECITIT` (could not observe:
  spawn error `ENOENT`/`EACCES` with `status === null`, exit 127, missing
  file, unknown unit, `Result≠success`, unparsable output). NECITIT is never
  green. Exit codes of `vigil check`: `0` all verde · `1` any picat · `2` any
  NECITIT or zero contracts · **`3` internal fault** (crash, invalid config,
  duplicate `nume`, expected-count mismatch). Only 3 is a unit failure
  (`SuccessExitStatus = "1 2"`).
- An **incident** opens after `picat_dupa` consecutive `picat` ticks, closes
  after the same count of `verde` plus a 30-minute hold-down; recovery budget
  is `max` per incident AND 2 per contract per rolling 24 h, persisted; when
  exhausted: escalate once, stay red until acknowledged. A contract that is
  NECITIT for `picat_dupa` consecutive ticks produces one `nota` (row +
  Telegram once), then silence until it changes. **Acknowledgement** is a
  drop-file: the owner creates `/var/lib/vigil/ack/<nume>` (directory `0775
  vigil:<ownerGroup>`); the next tick consumes and deletes it.
- **Transitions → say.** `vigil-check` is the only producer: on `open`,
  `escalation`, `close`, `explicatie` (a conclusion arrived for a still-open
  incident — a follow-up message on the next tick) and the NECITIT `nota`, it
  invokes `$VIGIL_BIN say` (absolute path from the unit's environment — the
  dispatcher is not on PATH) with one JSON event. If the send fails, the event is spooled to
  `/var/lib/vigil/outbox/` and retried on the next tick for up to 24 h. No other
  component sends.
- **explain** (choir only) is a SEPARATE unit `vigil-explain` running as
  `sancta` (the account holding the model CLI's auth), on its own timer,
  decoupled from vigil by files in both directions: it reads
  `/var/lib/vigil/incidents.json` and the **already-redacted** journal slice
  `/var/lib/vigil/journal/<nume>-<ts>.txt` (written by `vigil-check`, which is
  the account in the journal group — explain never runs `journalctl`), and it
  writes `{nume, incident_id, concluzie}` to
  `/var/lib/vigil/conclusions/<nume>-<incident_id>.json`; the next `vigil check`
  tick picks it up, sends it as an `explicatie` transition, and deletes it. A
  conclusion whose `incident_id` no longer matches the open incident is deleted
  unsent. `vigil-explain`'s timer runs every **2 minutes** so "within two
  vigil ticks" is achievable. No credential
  crosses between the users. rpi5 is report-only-without-explanation in v1.
- **say** = Telegram (`EnvironmentFile` = the existing `backup-telegram-env`
  shape: `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`; the chat is the owner's DM) +
  the status-row file. It emits contract `nume`, verdict, transition, optional
  conclusion — **never journal text, never `tinta`**. It asserts the API said
  `"ok":true`. Once per 24 h (no incident needed) `vigil check` calls Telegram
  `sendChatAction` (`typing`) against `$TELEGRAM_CHAT_ID` — an operation that
  fails when the bot cannot reach *that chat*, unlike `getMe` — and touches
  `/var/lib/vigil/last-channel-ok` on success (every successful real send
  touches it too); the
  `channel` contract is an `age` on that absolute path (`prag = "2d"`).
- **Tick.** `vigil-check`'s last action is to atomically write
  `/var/lib/vigil/tick.counts.json` (counts only). `ExecStopPost = vigil tick
  write` then reads that file plus systemd's `$SERVICE_RESULT` / `$EXIT_STATUS`
  and replaces `/var/lib/vigil/tick` with `{"la":"<ISO>","verde":n,"picat":n,"necitit":n}`
  — **only if** `SERVICE_RESULT == "success"` and `EXIT_STATUS` ∈ {0,1,2} and the
  counts file is from this run. On exit 3, a 203/EXEC, or a missing counts file
  it leaves the old tick untouched: staleness is the peer's signal that vigil
  itself is broken. A
  socket-activated responder on **:8747** (`FreeBind`, ordered after
  `tailscaled`) serves it. The peer checks it with `http` +
  `astept.prospetime` (reads `.la`; must be younger than 15 min) — in **both**
  directions. ACL: choir→rpi5:8747 granted (measured 2026-09-20); rpi5→choir is
  `ip:*`.
- **Recovery** (Task 6 only): `[recuperare].act` is exactly `<abs systemctl>
  restart <unit>` at system scope. The module derives the polkit rule **from
  the contracts**: it parses every public contract's act at eval time, extracts
  the unit operand, normalises the `.service` suffix, sets
  `security.polkit.enable = true`, and renders one rule (user `vigil`, action
  `org.freedesktop.systemd1.manage-units`, verb `restart`, unit ∈ that derived
  set). Nothing else is granted; this is right #4 of the design.
- **Privacy wall, law not style:** this repo is PUBLIC. No contract in this repo
  may name a family member's device, account or dashboard. Family-facing
  contracts on rpi5 arrive as agenix secrets (one `.age` per contract, decrypted
  to an explicit `path` under `/run/vigil-contracts/*.toml`, `owner = "vigil"`,
  **`symlink = false`** — agenix's default is a symlink, and a `Dirent.isFile()`
  scan skips symlinks silently),
  authored by the owner. Contracts may name only fixed-location devices;
  entities backed by `mobile_app`/`device_tracker` are excluded. Outbound
  messages and the journal carry the generic `nume` only; the reason string
  (`motiv`) is type-level and never includes `tinta`.
- Already in place: `secrets/ha-vigil-token.age` (#593; recipients `users ++
  [rpi5]`); the module template `modules/services/sancta-archive-deadman.nix`;
  `tests/module-eval.nix`. Bottleneck (design `GÂTUL ACUM`): the rpi5 half must
  be deployable with **one `nixos-rebuild switch` by the owner**. Task order
  follows that.

Files: `pkgs/vigil/` (new: `vigil-check.mjs`, `vigil-say.mjs`, `vigil-tick.mjs`,
`vigil-repair.mjs`, `vigil-explain.mjs`, `lib/{toml,checks,incident,redact}.mjs`,
`prompts/explain.md`, `mutate.sh`), `pkgs/vigil.nix`, `modules/services/vigil.nix`
(new), `hosts/{rpi5-full,sancta-choir}/configuration.nix`,
`hosts/*/vigil-contracts/*.toml`, `secrets/secrets.nix`, `tests/module-eval.nix`,
`flake.nix`.

## Tasks

### Task 1: vigil-check — the deterministic core, with a negative arm that can go red
- [ ] Create `pkgs/vigil/vigil-check.mjs` (Node ESM, zero dependencies). It reads every `*.toml` in the directories given as argv (**stat through symlinks**: `statSync(join(dir,name)).isFile()`, never `Dirent.isFile()`), parses with a TOML **subset** parser in `pkgs/vigil/lib/toml.mjs` (tables, basic single-line strings, integers, booleans, inline tables, arrays of strings — anything else, including floats, datetimes, multi-line strings, dotted keys and arrays of tables, is a parse error → that contract is NECITIT and named). Validate the closed schema from Context, including `peer`, `jurnal`, `jurnal_filtru`, `[spune].nivel`; reject unknown keys; **reject duplicate `nume` across all directories with exit 3** before running any check; report `files seen / parsed` on stderr; if `--expect N` is given and the parsed count differs, exit 3.
- [ ] Implement the eight check types in `pkgs/vigil/lib/checks.mjs`: `tcp` (connect, 5 s); `http` (status class + optional `astept.body` regex + optional `astept.prospetime`: parse the body as JSON and require `.la` to be an ISO timestamp younger than the duration; 10 s; no redirects); `unit` (`$VIGIL_SYSTEMCTL is-active <name>`, system scope only); `age` (`tinta` = absolute file path → mtime, or `unit:<name>` → `ExecMainExitTimestamp` from `$VIGIL_SYSTEMCTL show` with `Result=success` required; `tinta_glob` picks the newest match); `disk` (`statfs` use% vs `prag`); `mount` (parse `/proc/self/mountinfo`, unescape fields, compare the **mount-point field for exact equality**); `cmd` (argv[0] must be in `$VIGIL_CMD_ALLOW`; stdout compared to `astept.valoare` if given); `hass-state` (`GET $HASS_URL/api/states/<tinta>` with bearer read from the file named by `$VIGIL_HASS_TOKEN_FILE` — the unit's environment, not the contract; `state === "unavailable"` → picat; HTTP ≠ 200 / missing token file → NECITIT). **Spawn errors (`ENOENT`/`EACCES`, `status === null`) and exit 127 → NECITIT** — the error event has a handler; nothing rejects unhandled.
- [ ] Implement the incident state machine in `pkgs/vigil/lib/incident.mjs`, persisted in `/var/lib/vigil/incidents.json` (path from `$STATE_DIRECTORY`, which the *unit* sets — not the contract): open/close/hold-down/escalation/24 h budget/NECITIT-nota/ack-drop-file exactly as in Context. Pure functions over `(state, verdict, now)`.
- [ ] Transitions: for each `open` / `escalation` / `close` / `explicatie` / NECITIT-nota, build one JSON event `{gazda, nume, verdict, tranzitie, nivel, concluzie?}` (never `tinta`, never journal text) and spawn `$VIGIL_BIN say` (absolute) with it on stdin; on non-zero exit, write the event to `/var/lib/vigil/outbox/<ts>-<nume>.json`; at the start of every tick, retry outbox events younger than 24 h and delete those that succeed or age out. Also: if `/var/lib/vigil/conclusions/<nume>-<incident_id>.json` exists and the incident is still open, send an `explicatie` event carrying `concluzie` and delete the file; if the id does not match the open incident, delete unsent. Once per 24 h (marker `/var/lib/vigil/last-chataction`), run `$VIGIL_BIN say --chataction`; success touches `/var/lib/vigil/last-channel-ok`. Last action of every run: write `/var/lib/vigil/tick.counts.json` atomically (`{run_id, verde, picat, necitit}`).
- [ ] Output: one JSON line per contract on stdout (`nume`, `verifica`, `verdict`, `motiv` — type-level only, e.g. `"http 503"`, `"file missing"`, never `tinta` —, `incident`), summary on stderr, exit per Context (`0/1/2/3`).
- [ ] `--autoproba`: contracts synthesised **in memory** (never written): loud (`tcp` to a closed port → picat); silent (`cmd` with `/nonexistent/bin` in the allow-list → NECITIT via `ENOENT`; `age` on a missing file → NECITIT; `age` on `unit:` with `Result=failed` → NECITIT); `mount` on `/` → verde, `mount` on `/nonexistent-but-substring-of-root` → picat, and `mount` on `/dev/sh` → **picat** (`/dev/shm` is mounted on every NixOS host: this is the fixture that catches `mountpoint.includes(tinta)` and raw-text scans — the direction v1 actually had); `http` `prospetime` fed a real two-field tick body → verde, and a body with `la` 20 min old → picat; duplicate `nume` → exit 3; `--expect` mismatch → exit 3; the state machine walked open → hold-down → close, budget exhaustion → escalation, ack-file → cleared, NECITIT × `picat_dupa` → one nota. Assert the **text** of each verdict line. Exit 2 on any deviation.
- [ ] Tests: `node --test pkgs/vigil/` (TOML subset incl. rejections; every check type against local fixtures; state-machine table). `pkgs/vigil/mutate.sh` with mutants that must each turn `--autoproba` red **from an assertion** (stderr contains `EȘEC`, no stack trace): (a) missing file → green, (b) hold-down = 0, (c) NECITIT → exit 0, (d) `ENOENT` → picat, (e) mount matched by `mountpoint.includes(tinta)` (the `/dev/sh` fixture must catch it).
- [ ] `~/.claude/index/bin/absenta pkgs/vigil/*.mjs pkgs/vigil/lib/*.mjs` → exit 0. Fix, don't sentinel.

### Task 2: vigil-say and vigil-tick — the voice, and the proof it can speak
- [ ] `pkgs/vigil/vigil-say.mjs`: reads one JSON event on stdin; **refuses** (exit 2, no send) if the event has a key `jurnal` or `tinta`, or any string field longer than 500 chars. `nivel = "nota"` → status row + one `sendMessage`, and a marker `/var/lib/vigil/nota-sent/<nume>-<stare>` suppresses repeats until the state changes. Otherwise `sendMessage` to `$TELEGRAM_CHAT_ID` with `$TELEGRAM_BOT_TOKEN` (from the unit's `EnvironmentFile`; never logged): `<emoji by nivel/tranzitie> [<gazda>] <nume>: <verdict> — <tranzitie>` + optional one-line `concluzie`. Assert `"ok":true`; success → touch `/var/lib/vigil/last-say-ok` and `last-channel-ok`; failure → exit 1 (the caller spools). `--chataction` mode: `sendChatAction` with `chat_id = $TELEGRAM_CHAT_ID`, `action = typing`, assert `"ok":true`, touch `last-channel-ok`, exit 0/1.
- [ ] Status row: replace the `vigil` entry in `/var/lib/vigil/row.json` (`{gazda, stare: "liniște" | "incident: <nume>", la}`) on every event including `nota`. (Wiring the existing poller to read it is not in this plan.)
- [ ] `pkgs/vigil/vigil-tick.mjs`: `write` mode — read `/var/lib/vigil/tick.counts.json` and `$SERVICE_RESULT`/`$EXIT_STATUS` (as set by systemd for `ExecStopPost`), and replace `/var/lib/vigil/tick` with the JSON body from Context **only when** result is `success`, status ∈ {0,1,2} and the counts file's `run_id` is newer than the last written tick; otherwise leave the tick untouched and log why; `serve` mode — stdin/stdout only (systemd socket activation, `Accept=yes`): reply `HTTP/1.0 200` + body if the file exists, `404` if absent, close. No listening code in the program.
- [ ] `--autoproba` for say: against a local `http.createServer` playing Telegram (`ok:true` / `ok:false` / 429 / refused); assert `last-say-ok` is touched only on ok, `jurnal`/`tinta` keys refused, a 501-char field refused, `nota` hits the fake server exactly once and a second identical `nota` does not, `--chataction` touches `last-channel-ok` and a fake `ok:false` does not. For tick `write`: with `SERVICE_RESULT=exit-code EXIT_STATUS=3` the tick file is untouched; with `success`/`1` it is replaced. For tick: pipe a request through `serve` and assert body equals file; absent file → 404.
- [ ] Mutants in `mutate.sh`: say ignores `"ok":false` (→ red); say lets a `tinta` key through (→ red); **tick `serve` returns 200 with empty body when the file is absent** (the 404 arm must catch it). `absenta` clean on both files.

### Task 3: services.vigil — the NixOS module, contracts validated at eval time against the SAME grammar
- [ ] `pkgs/vigil.nix`: derivation installing the `.mjs` files with `${pkgs.nodejs}/bin/node` and a `bin/vigil` dispatcher (`check|say|tick|repair|explain|autoproba`); export as `packages.<system>.vigil` for `x86_64-linux` and `aarch64-linux`; `nix build .#packages.x86_64-linux.vigil && result/bin/vigil autoproba` exit 0.
- [ ] `modules/services/vigil.nix` options: `enable`; `user` (default `vigil`) and `ownerGroup` (default `users`; used for the ack directory); `contractsDirs` (list of paths); `expectedContracts` (int or null → `--expect`); `telegramEnvFile` (**path or null**; when null, say is disabled and any `channel` contract or `nivel = "incident"` in a public contract makes eval fail — so a host can run report-to-row-only before its secret is keyed); `hassTokenFile` null while any public `hass-state` contract exists → eval fails likewise; `hassTokenFile`, `hassUrl` (path/string or null); `tickPort` (default 8747); **`listenAddress` (`types.str`, mandatory, no default)**; `cmdAllow` (list of absolute paths); `interval` (default `5min`); `explain.enable`, `explain.command` (argv list), `explain.user` (default `sancta`).
- [ ] Eval-time validation of every contract in the `contractsDirs` entries that are **Nix paths / store paths** (`lib.isStorePath`; runtime-populated directories such as `/run/vigil-contracts` are skipped at eval and covered by `expectedContracts` at runtime) with `builtins.fromTOML`, then a **walk that rejects anything outside the runtime subset** (leaf must be string/int/bool/list-of-string; no dotted keys; no arrays of tables) — the eval gate accepts exactly what the runtime accepts. Assert: closed `verifica` set; required fields per type; unknown keys rejected; `[recuperare].act` matches `^/[^ ]+/systemctl restart [A-Za-z0-9@._-]+$`; any `tinta` containing `100.` requires `peer = true`; `nume` unique across `contractsDirs` that are store paths. Failure messages name the file.
- [ ] Wire: `users.users.${cfg.user}` (system user, `group = cfg.user`, `extraGroups = [ "systemd-journal" ]`); `systemd.services.vigil` (`Type=oneshot`; `User`; `ExecStart = ${vigil}/bin/vigil check <dirs> [--expect N]`; `ExecStopPost = ${vigil}/bin/vigil tick write`; `SuccessExitStatus = "1 2"`; `EnvironmentFile = cfg.telegramEnvFile` when non-null; `Environment` = `VIGIL_BIN=${vigil}/bin/vigil`, `VIGIL_SYSTEMCTL=${pkgs.systemd}/bin/systemctl`, `VIGIL_CMD_ALLOW=…`, `HASS_URL`, `VIGIL_HASS_TOKEN_FILE=${cfg.hassTokenFile}` (when non-null); `path = [ pkgs.coreutils pkgs.systemd ]`; `StateDirectory = "vigil"`; `StateDirectoryMode = "0755"`; `ProtectSystem = "strict"`; `ProtectHome = true`; `OnFailure = [ "vigil-failed.service" ]` — a unit, same `EnvironmentFile`, that sends one `nota`-level message "vigil itself failed on <host>" — `nota` reaches Telegram once per state — only when say is enabled); `systemd.services.vigil-autoproba` + weekly timer (`User = cfg.user`, same sandbox, `ExecStart = ${vigil}/bin/vigil autoproba --polkit`, declared only when the polkit rule is rendered) so the proof of right #4 actually runs as `vigil` and lands in the journal; `users.groups.vigil-spool` with `cfg.user` and `cfg.explain.user` as members; `systemd.tmpfiles.rules` spelled out: `d /var/lib/vigil/outbox 0750 vigil vigil`, `d /var/lib/vigil/nota-sent 0750 vigil vigil`, `d /var/lib/vigil/journal 0750 vigil vigil-spool`, `d /var/lib/vigil/conclusions 2770 vigil vigil-spool` (setgid: explain's files are group-owned so vigil can unlink them), `d /var/lib/vigil/ack 0775 vigil ${cfg.ownerGroup}`; `systemd.timers.vigil` (`wantedBy = [ "timers.target" ]`; `OnBootSec = "2min"`; `OnUnitActiveSec = cfg.interval`; no `Persistent`); `systemd.sockets.vigil-tick` (`wantedBy = [ "sockets.target" ]`; `after`/`wants` `tailscaled.service`; `ListenStream = "${cfg.listenAddress}:${toString cfg.tickPort}"`; `FreeBind = true`; `Accept = true`) + `systemd.services."vigil-tick@"` (`ExecStart = ${vigil}/bin/vigil tick serve`; `StandardInput = "socket"`; same user and sandbox, read-only; **`IPAddressAllow` = Tailscale's CGNAT `100.64.0.0/10` + ULA `fd7a:115c:a1e0::/48`, `IPAddressDeny = any`** — the same narrowing CLAUDE.md records for `sancta-gallery`; and a module assertion rejects any `listenAddress` outside those ranges).
- [ ] `tests/module-eval.nix`, house style (assert rendered shape; quantify): user exists with the journal group; `ProtectSystem=strict`; `StateDirectory=vigil` + mode; `SuccessExitStatus` contains `1 2`; tick write is in `ExecStopPost`, not a second `ExecStart`; timer has `OnBootSec` and is wanted by `timers.target`; socket wanted by `sockets.target`, `FreeBind`, listens on the configured address which is inside `100.64.0.0/10` and ≠ `0.0.0.0`; **negative arms** via fixture hosts: `verifica = "shell"` → eval throws naming the file; `prag = 85.0` (float) → throws; a datetime → throws; a `100.` `tinta` without `peer` → throws; a duplicate `nume` → throws; a `channel` contract with `telegramEnvFile = null` → throws; a `hass-state` contract with `hassTokenFile = null` → throws; a fixture host with `"/run/vigil-contracts"` in `contractsDirs` → **evaluates** (the runtime dir is skipped at eval); the rendered tmpfiles lines carry the owners above and `explain.user` is in `vigil-spool` whenever `explain.enable`.
- [ ] `vigil-tick` binds a tailnet address directly instead of loopback + Tailscale Serve — the same exception CLAUDE.md already documents for `sancta-gallery`, for the same reason: a dead responder must fail as `ECONNREFUSED` (which the peer's `http` check reads as picat), not be swallowed by Serve's catch-all `/` routing into a 200. Extend CLAUDE.md's documented-exception paragraph to name `vigil-tick` alongside `sancta-gallery`, with this rationale, in this task's PR.
- [ ] `nix fmt`; `nix build .#checks.x86_64-linux.module-eval` green.

### Task 4: rpi5-full — the half that matters, deployable with one switch
- [ ] Public contracts under `hosts/rpi5-full/vigil-contracts/` (generic `nume`; no device names): `tailscaled.toml` (unit `tailscaled.service`); `ha-alive.toml` (http `http://127.0.0.1:8123/manifest.json`, `astept = { status = 200, body = "\"name\"" }`); `ha-served.toml` (http `https://rpi5.tail4249a9.ts.net:8123/manifest.json`, status 200 — exercises tailscale serve end to end); `soul-mirror-pull.toml` (age `unit:soul-mirror-pull.service`, `prag = "8d"`); `choir-host.toml` (tcp `<choir tailnet ip>:8743`, `peer = true`); `choir-tick.toml` (http `http://<choir tailnet ip>:8747/`, `astept = { status = 200, prospetime = "15m" }`, `peer = true`); `channel.toml` (age `/var/lib/vigil/last-channel-ok`, `prag = "2d"`). Seven files, seven `nume`.
- [ ] `secrets/secrets.nix`: register `vigil-rpi5-contract-{1,2,3}.age` (recipients `users ++ [ rpi5 ]`) with a comment: family-facing `hass-state` contracts, one per file, authored by the owner, decrypted to `/run/vigil-contracts/contract-N.toml`. **Do not create the `.age` files and do not declare `age.secrets` for them yet** (his hand; chicken-and-egg). Put in the PR body: the three `agenix -e` commands and a template contract with `tinta = "sensor.EXAMPLE"`, `nivel = "incident"`, generic `nume`.
- [ ] `hosts/rpi5-full/configuration.nix`: `services.vigil = { enable = true; contractsDirs = [ ./vigil-contracts ]; expectedContracts = 7; telegramEnvFile = secret "backup-telegram-env"; hassTokenFile = secret "ha-vigil-token"; hassUrl = "http://127.0.0.1:8123"; listenAddress = "<rpi5 tailnet ip>"; tickPort = 8747; cmdAllow = []; }`; `age.secrets.ha-vigil-token = { file = …; owner = "vigil"; }`; and set `owner = "vigil"` on `backup-telegram-env` **only if** no other consumer needs it root-owned — check `backup-pull` and `tailscale-dns-watchdog` first; if they do, add `group = "vigil"; mode = "0440";` instead and record which.
- [ ] `nix build .#checks.x86_64-linux.module-eval` green; `nix eval .#nixosConfigurations.rpi5-full.config.systemd.services.vigil.serviceConfig.ExecStart` succeeds; `nix fmt`; PR. **Closing check (his hand, after switch):** `systemctl status vigil.timer` active (waiting) and `vigil-tick.socket` listening; within 10 min `journalctl -u vigil -n 40` shows a tick with **7 contracts, zero NECITIT, exit 0 or 1** (a `picat` on `choir-tick` is expected until Task 5 lands; it must be `picat`, not NECITIT); `curl http://<rpi5 tailnet ip>:8747/` from choir returns the JSON tick with `.la` fresh. Record in the PR.

### Task 5: sancta-choir — the second half, in two PRs so the switch never fails
- [ ] **PR 5a.** Public contracts under `hosts/sancta-choir/vigil-contracts/`: `tailscaled.toml`; `galeria.toml` (http `http://127.0.0.1:8739/` 200 — report-only here); `membrana.toml` (http `http://127.0.0.1:8743/` 200); `soul-mirror.toml` (age `unit:sancta-soul-mirror.service`, 8d); `disk-root.toml` (disk `/`, 85); `build-volume.toml` (mount `/mnt/sancta-build-volume`); `open-webui.toml` (http `http://127.0.0.1:8080/health` 200); `n8n.toml` (http `http://127.0.0.1:5678/healthz`, `astept = { status = 200, body = "\"status\":\"ok\"" }`); `rpi5-host.toml` (tcp `<rpi5 tailnet ip>:8747`, `peer = true`); `rpi5-tick.toml` (http `http://<rpi5 tailnet ip>:8747/`, `prospetime = "15m"`, `peer = true`). **No `channel.toml` in 5a.** Enable `services.vigil` on choir with `telegramEnvFile = null` (row-only), `expectedContracts = 10`, `listenAddress = "<choir tailnet ip>"`. Add `sancta-choir` to `backup-telegram-env.age`'s recipients in `secrets.nix` and write the exact re-key command in the PR body (`agenix -r`, from choir as the `users` key). module-eval green; PR; his switch. Closing check: 10 contracts, zero NECITIT; `curl http://<choir tailnet ip>:8747/` from rpi5 returns a fresh tick; `choir-tick` on rpi5 turns `verde`.
- [ ] **PR 5b** (only after the owner confirms the re-key): set `telegramEnvFile = secret "backup-telegram-env"` (owner/group as decided in Task 4), declare `age.secrets.backup-telegram-env` on choir, add `channel.toml`, `expectedContracts = 11`, and **flip all ten 5a contracts from `nivel = "nota"` to `nivel = "incident"`** (5a had to write them as `nota` to pass the `telegramEnvFile = null` gate; none is meant to stay a note). Closing check (his hand, a quiet hour): 11 contracts; `last-channel-ok` exists within a day; `sudo systemctl stop sancta-gallery` for 12 minutes then start it — one of the **pre-existing** contracts must produce exactly one Telegram message on open and one on close.

### Task 6: vigil-repair and vigil-explain — the arms that act, gated by the law
- [ ] `pkgs/vigil/vigil-repair.mjs`, invoked by `vigil-check` on incident **open** only: runs `[recuperare].act` (argv split; absolute path; the exact `restart <unit>` shape), respecting per-incident `max` and the 24 h budget; every act appended to `/var/lib/vigil/decisions.jsonl` in `bin/decision`'s line format. Module: when any public contract carries `[recuperare]`, derive the unit set from the acts (suffix-normalised), set `security.polkit.enable = true`, render the rule into `security.polkit.extraConfig` (user `vigil`, `manage-units`, verb `restart`, unit ∈ set). `tests/module-eval.nix`: assert `config.environment.etc."polkit-1/rules.d/10-nixos.rules".text` (exists only when polkit is on) contains each **suffixed** unit name and `"restart"` and no `*`; negative arm: a contract whose act names a unit not in any contract cannot exist by construction — assert instead that an act with a verb other than `restart` throws at eval.
- [ ] The proof of right #4 runs **as `vigil`, in `vigil-autoproba.service`** (Task 3) — no hand-run as `vigil` (a system user cannot be impersonated without root). The polkit arms are **conditional**: when the calling uid is not `vigil`'s (the build gate, CI, a developer), `autoproba` prints `SĂRIT: polkit (nu rulez ca vigil)` and exits 0 — so Task 3's `result/bin/vigil autoproba` gate stays meaningful after Task 6. When it does run as `vigil`, the arms assert on `systemctl`'s **stderr text**: denial = `Access denied` / `Interactive authentication required`; a job that ran and failed = `Job for ... failed` — the two are not the same and the arm names which it saw. The module declares three probe units, none with an environment switch: `vigil-probe.service` (`Type=oneshot`, `RemainAfterExit=true`, `ExecStart = "${pkgs.coreutils}/bin/true"`; **in** the derived set via a probe contract — the polkit positive arm), `vigil-probe-denied.service` (same, **not** in any contract — the negative arm), and `vigil-probe-fail.service` (`ExecStart` = a `pkgs.writeShellScript` that `cat`s the checked-in corpus `pkgs/vigil/redact-corpus.txt` to stdout and exits 1; its own contract carries `jurnal = [ "vigil-probe-fail.service" ]` and a `[recuperare]` on itself — the redaction and end-to-end probe). Positive arm: restart of `vigil-probe` succeeds; negative arm: restart of `vigil-probe-denied` is refused by polkit. If both are refused → the autoproba reports `polkit` as the cause (rule not installed) and exits 2 — the owner's-hand alternative (`sudo systemctl restart vigil-probe.service` as a sanity check of the unit itself) is written in the PR body.
- [ ] `vigil-check` gains the journal step (it is the journal-group account): at incident **open** for a contract with `jurnal`, run `journalctl -u <unit> --since -15min -o cat` per unit (absolute path; **check the exit status; non-zero → the slice is `NECITIT: journal` and says so**), pass through `lib/redact.mjs` (the **enumerated** deny-list from Constraints + the contract's `jurnal_filtru` if set), write `/var/lib/vigil/journal/<nume>-<ts>.txt` (mode 0644).
- [ ] `pkgs/vigil/vigil-explain.mjs` + `vigil-explain.service`/timer (`User = cfg.explain.user`, its own `StateDirectory=vigil-explain`, `ReadOnlyPaths=/var/lib/vigil`, `ReadWritePaths` = the model CLI's config dir + `/var/lib/vigil/conclusions`, `ProtectSystem=strict`): reads `incidents.json`, keeps `explained` marks, for each new open/escalation reads the redacted slice (refuses to run the model if the slice is missing or `NECITIT`), runs `explain.command` with `prompts/explain.md`, truncates output to 500 chars, writes `/var/lib/vigil/conclusions/<nume>.json`. It never sends. Gated by `~/.claude/index/bin/meter` (skip with a note if over budget).
- [ ] `--autoproba`: repair — positive and negative polkit arms above, plus budget exhaustion → escalation; redact — the checked-in corpus `pkgs/vigil/redact-corpus.txt` (one benign line + one line per deny-list pattern, maintained separately from the pattern list) → the benign line survives and nothing else does, asserting per pattern which line was removed; a 501-char model output → truncated; an already-explained incident → the command is **not** invoked. Mutants: repair ignores per-incident `max` (→ red); the `device_tracker` deny-list entry disabled (→ red, and the corpus line that survives is named); explain runs on a missing slice (→ red).
- [ ] **Wire it:** add `[recuperare]` (`act = "/run/current-system/sw/bin/systemctl restart sancta-gallery.service"`, `max = 1`) to `galeria.toml` and the same for `membrana.toml`; add `vigil-probe.toml` (polkit positive arm, `[recuperare]` on `vigil-probe.service`) and `vigil-probe-fail.toml` (`jurnal = [ "vigil-probe-fail.service" ]`, `[recuperare]` on itself, `max = 1`); **set `expectedContracts = 13` in the same commit** (11 + 2; the count is a hard exit-3 tripwire). Enable `explain` on choir with the chosen `explain.command`. `absenta` clean; module-eval green (asserting 13); PR. **Closing check (his hand):** `sudo systemctl start vigil-probe-fail.service`; within two vigil ticks: an `open` message, then an `explicatie` follow-up carrying a conclusion; `/var/lib/vigil/journal/vigil-probe-fail-*.txt` is **non-empty, contains the corpus's benign line, and contains none of the planted ones**; `decisions.jsonl` shows the probe restart; `vigil-probe-denied` was refused in the autoproba; an ack drop-file clears an escalated probe incident on the next tick.

### Task 7: the private contracts on rpi5, and the first real incident
- [ ] Once the owner has created the three `.age` files: declare `age.secrets.vigil-rpi5-contract-{1,2,3} = { file = …; owner = "vigil"; path = "/run/vigil-contracts/contract-N.toml"; symlink = false; }`, add `"/run/vigil-contracts"` to `contractsDirs`, `expectedContracts = 10`. PR, CI, his switch. Closing check: `ls -l /run/vigil-contracts/` shows three regular `.toml` files owned by `vigil`; `journalctl -u vigil` shows **10 contracts, zero NECITIT** (the three private ones with real verdicts); the count assertion is what proves the files were parsed, not merely present.
- [ ] Write `docs/plans/completed/2026-09-20-vigil-postdeploy.md`: commands only (no device names): timers active on both hosts; both tick endpoints answer from the peer with fresh `.la`; `last-channel-ok` younger than 2 d on both; one deliberate probe incident end-to-end including ack. **The plan is done only when the first real incident (a contract that fails on a real day) reaches Telegram**; record its date there.

## Constraints

- This repo is PUBLIC. **No contract, comment, test, fixture or commit message names a family member's device, account, dashboard or entity id.** Family-facing contracts exist only as agenix ciphertext authored by the owner. If a task cannot be completed without naming one, stop and say so.
- No `sudo`, no root, no impersonation of `vigil`. The ONE privilege grant is the polkit rule of Task 6 — derived from the contracts, `restart` only, never `*` — with its own eval test against the installed rule file. No new listener except the socket-activated tick on `:8747` bound to the configured tailnet address; never `0.0.0.0`; no LocalAPI socket; the tailnet ACL is not changed (choir→rpi5:8747 is already granted).
- The check-type set and the contract schema are closed; `cmd` is an allow-list of absolute executable paths; `[recuperare].act` is exactly `<abs systemctl> restart <unit>`; NECITIT is never exit 0; zero contracts and count mismatch are exit 3.
- Every new executable has `--autoproba` that asserts **text**, and at least one mutant in `mutate.sh` that turns it red from an assertion (stderr `EȘEC`), never from a crash. Run `~/.claude/index/bin/absenta` over all new `.mjs` before opening a PR; it must exit 0.
- **Any PR that adds or removes a contract file moves `expectedContracts` on that host in the same commit** — `--expect` is a hard exit-3 tripwire, not a warning. The module-eval test asserts the value.
- **The redaction deny-list is this closed list**, implemented literally in `lib/redact.mjs` and exercised line-by-line by `pkgs/vigil/redact-corpus.txt`: `homeassistant\.components\.http\.ban`, `homeassistant\.auth`, `mobile_app`, `person\.[a-z0-9_]+`, `device_tracker\.[a-z0-9_]+`, `/home/[a-z][a-z0-9_-]*`, IPv4 literals, IPv6 literals, MAC literals, `[a-z0-9-]+\.ts\.net`, `@[A-Za-z0-9_]{3,}`. Adding a pattern requires adding its corpus line in the same commit.
- Do not touch: the soul volume, `soul-mirror*`, `/nix`, `managed-settings`, `sancta-worker`, `herdr`, `gatus.nix`.
- House rules: worktree + PR (never push to main); `nix fmt` in the background; `nix build .#checks.x86_64-linux.module-eval` before every PR; merge only on green CI **and zero medium+ review findings**; deploys, switches, re-keys, `.age` creation and ack drop-files are the owner's hand and are written as exact commands in the PR body. Security findings return to the session, never onto the public PR.
- `hosts/rpi5-full` tracks `nixos-raspberrypi`'s nixpkgs pin, `sancta-choir` the root pin; anything that differs must be eval'd on both.
- Order is the bottleneck's: Task 4 before Task 5; Task 6 last. Do not reorder.

## Disposition of the review (v1 → v2)

31 findings, all changed the plan; none refused.

| finding | where fixed |
|---|---|
| Task 7 `owner = "sancta"` on a host without sancta | T7: `owner = "vigil"` |
| exit 1/2 treated as unit failure; tick skipped; OnFailure every 5 min | Context exit contract: `3` = fault; `SuccessExitStatus = "1 2"`; tick via `ExecStopPost` |
| timer never fires (no wantedBy, no first trigger, inert Persistent) | T3: `OnBootSec` + `OnUnitActiveSec`, `timers.target`, `sockets.target`; Persistent dropped |
| socket bind fails before tailscaled | T3: `FreeBind`, after/wants tailscaled; asserted |
| `listenAddress` cannot default to the tailnet IP | T3 mandatory; T4/T5 set it; eval asserts 100.64/10 |
| `channel.toml` NECITIT forever / circular | Context: daily `getMe` → `last-channel-ok`, absolute path, `prag 2d`; no `$VAR` expansion |
| agenix private contracts: no `.toml`, rotating path, shared dir | explicit `path = /run/vigil-contracts/contract-N.toml`, owner vigil; `--expect` count |
| explain cannot call say; state-dir mismatch | explain writes conclusions to a spool; `vigil check` sends |
| explain reads the journal as sancta (no access); empty passes | `vigil-check` (journal group) writes the redacted slice; explain never runs journalctl; exit status checked |
| `/bin/true` does not exist on NixOS | `${pkgs.coreutils}/bin/true`, oneshot RemainAfterExit |
| polkit proof requires impersonating vigil | proof inside `vigil.service` autoproba; two probe units, positive + negative arms |
| polkit never enabled; test green either way | module enables polkit; test reads the installed rules file |
| bare unit names vs `.service` lookup | suffix normalisation; test asserts suffixed names |
| `prospetime` body format mismatch | tick body is JSON `{la, counts}`; `prospetime` reads `.la`; stated in T1 and T2; autoproba case |
| Task 5 forbids then requires the Telegram secret | T5 split into 5a (row-only, `telegramEnvFile = null`) and 5b (after re-key) |
| eval gate (`fromTOML`) looser than the runtime subset | T3 walk rejects floats/datetimes/dotted keys/arrays of tables; negative arms |
| dead `local` field; dead `[spune].nivel` | `peer = true` replaces it (inverted guard); `nivel` wired into say (`nota` = row only) |
| no producer of transition events for say | T1: check invokes say per transition; outbox retry 24 h |
| Task 6 never wires the two recovery contracts | T6 last step wires galeria + membrana + probe |
| redaction closing check passes on absence | probe contract with `jurnal`; probe plants deny-listed lines; check requires non-empty + benign present + planted absent |
| `recoverableUnits` vs acts: two sources of truth | derived from the contracts at eval; option removed |
| `choir-tick` without freshness | `prospetime` on both peer contracts; Context wording fixed |
| `ack` has no path | drop-file in `/var/lib/vigil/ack` (0775 vigil:ownerGroup); owner-hand; exercised in T6 check |
| private `tinta` could reach journal / tick body | `motiv` type-level only; tick body counts only; say refuses `tinta` |
| exit 127 vs Node `ENOENT` | spawn error with `status === null` → NECITIT, stated |
| Task 4 check excuses NECITIT | 7 contracts, zero NECITIT, full stop |
| `jurnal_filtru` undefined | in schema, validated; HA parenthetical dropped |
| Context "argv shapes" vs absolute paths | Context corrected to absolute executable paths |
| `mount` substring match | mount-point field, exact, unescaped; autoproba + mutant |
| duplicate `nume` accepted | exit 3 at runtime; eval assertion over store dirs |
| tick and repair without mutants | mutants added for tick (empty-200), repair (ignore `max`), explain (missing slice) |

## Disposition of round 2 (v2 → v3)

16 findings, all changed the plan; none refused.

| finding | where fixed |
|---|---|
| **critical**: probe contracts added without moving `expectedContracts` → exit 3 every tick | T6 sets 13 in the same commit; 5b tests a pre-existing contract instead of a temp one; Constraints rule |
| `hass-state` read a `secret` key the closed schema lacks; token path never exported | token via `$VIGIL_HASS_TOKEN_FILE` from the unit; eval gate for null token |
| a conclusion had no transition to ride on; explain interval unspecified; stale conclusions | `explicatie` transition; conclusions keyed by incident id; explain timer 2 min |
| `nota` never reached Telegram, so vigil-failed and the NECITIT notice were dropped | `nota` = row + one message, repeats suppressed; autoproba asserts once/not-twice |
| autoproba never wired into a unit; polkit arms would fail the build gate after T6 | `vigil-autoproba.service` + weekly timer as `vigil`; arms skip with `SĂRIT` when uid ≠ vigil; stderr text named |
| `tick write` had no source for the counts | `tick.counts.json` written by check; tick write merges + `$SERVICE_RESULT` |
| tmpfiles owners unspecified; conclusions needs two writers | every line spelled out; `vigil-spool` setgid group |
| `getMe` proves the token, not the chat | `sendChatAction` against the chat id |
| dispatcher not on PATH | `$VIGIL_BIN` absolute |
| `ExecStopPost` refreshed the tick even on exit 3 / 203 | tick write refuses on non-success / status 3; staleness is the signal |
| mount fixtures caught one containment direction | `/dev/sh` fixture; mutant (e) direction named |
| deny-list never enumerated; closing check circular | enumerated in Constraints; separate checked-in corpus; mutant names the entry |
| 5a forced `nota`; 5b never flipped back | 5b flips all ten; closing check on a pre-existing contract |
| no trigger for the probe; env switch broke the positive arm | `vigil-probe-fail.service` as its own unit; trigger = `systemctl start` |
| agenix `path` is a symlink; `Dirent.isFile()` skips it | `symlink = false`; scan stats through symlinks; `ls -l` in the check |
| eval walk over a runtime dir fails the switch | walk only store paths; fixture host asserts a runtime dir evaluates |
