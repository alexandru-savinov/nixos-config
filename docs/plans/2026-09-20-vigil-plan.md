Build vigil v1: the agent that watches the Sancta fleet and speaks — contracts decide, three-valued verdicts, Telegram + status row, on choir and rpi5, deployable with one switch each. Explain and recover are plan 2.

Implementation update: reuse the existing Gatus dashboard for Vigil's public
status. The [reuse decision](2026-09-20-vigil-reuse.md) documents preserved
semantics and the custom components that remain necessary. Necessary Gatus
integration changes are permitted by the revised goal; the earlier blanket
`gatus.nix` exclusion below no longer applies to this integration.

## Context

v7 implementation contract (2026-09-20). Four completed revmux rounds on v1–v4 (31 + 16 + 16 + 17 findings; rounds 2
and 3 each found a fresh 16, half of them in the explain/recover half). The
rate was not falling, so v4 **splits the plan**: this file is vigil v1 —
watch + say + tick, both hosts, private contracts. Explain, recovery, polkit
and the two-user spool are `docs/plans/2026-09-20-vigil-2-explain-recover-plan.md`,
to be executed only after v1 has been live and has seen real incidents. All
four rounds' findings that apply to v1 are folded in; the disposition tables
are at the end. Design: private, on the soul volume (`index/design/vigil-design.md`
v2.1); the owner approved it. What this repo needs to know:

- **vigil** is a systemd timer running `vigil-check` as the system user
  **`vigil`** (hardcoded — no `user` option, so nothing can drift; declared by
  the module: `isSystemUser`, group `vigil`, no supplementary groups),
  `ProtectSystem=strict`, `ProtectHome=true`, `StateDirectory=vigil`, explicit
  `path`, on **two hosts**: `sancta-choir` and `rpi5-full`. Verified 2026-09-20:
  `sancta` does not exist on rpi5-full; `sancta-gallery`/`sancta-membrane` are
  SYSTEM units; `sancta` is not in `systemd-journal` and the house declined that
  grant (it has `sancta-journal-export.service`). **v1 recovers nothing** — every
  contract is report-only; `[recuperare]` is parsed and rejected with a message
  naming plan 2.
- A **contract** is one TOML file, one target. Closed schema (unknown keys are
  a validation error): `[contract]` — `nume` (unique across all directories),
  `ce`, `verifica`, `tinta`, type-specific `astept` (inline
  table) or `prag`, `picat_dupa`, optional `peer = true` (required for a parsed target host in the Tailscale CGNAT range); `[spune]` — `nivel = "incident" | "nota"`. Check types, closed:
  `tcp | http | unit | age | disk | mount | cmd | hass-state`. `cmd` = allow-list
  of **absolute executable paths** (`cmdAllow`). No `$VAR` expansion in `tinta`.
  `ce` is a generic operator-facing description string; `picat_dupa` is an
  integer ≥ 1. The validator defines and enforces the required `tinta`/`astept`/
  `prag` fields for each check type identically at eval and runtime.
  The runtime parser accepts a TOML **subset**: tables, single-line basic
  strings, integers, booleans, inline tables, arrays of strings — no floats,
  datetimes, literal or multi-line strings, dotted keys, arrays of tables.
  `#` comments are accepted. `nume` must match `^[a-z0-9][a-z0-9-]{0,63}$`;
  every derived path is resolved and checked to remain under its state subdirectory.
- Verdicts are **three-valued**: `verde`, `picat`, `NECITIT` (spawn error
  `ENOENT`/`EACCES` with `status === null`, exit 127, missing file, unknown
  unit, `Result≠success`, unparsable output, **or an unparsable contract
  file** — the file is *accounted for* and degrades to NECITIT; it never takes
  the host down). Exit codes of `vigil check`: `0` all verde · `1` any picat ·
  `2` any NECITIT or zero files · **`3` internal fault** (crash, duplicate
  `nume`, `--expect N` ≠ number of `*.toml` files **present**, or failure to
  enumerate a configured directory). An unreadable directory has unknown
  inventory; it cannot be represented as one synthetic contract or skipped.
  Exit 3 leaves the previous tick unchanged and invokes the self-failure path.
  An individually unreadable file in an enumerable directory remains NECITIT.
  Only 3 is a unit
  failure (`SuccessExitStatus = "1 2"`).
- An **incident** opens after `picat_dupa` consecutive `picat` ticks (it gets an
  `incident_id` = the ISO timestamp of the open transition, persisted in
  `incidents.json`), closes after the same count of `verde` plus a 30-minute
  hold-down; a contract NECITIT for `picat_dupa` consecutive ticks produces one
  `nota`. **Acknowledgement** is a drop-file `/var/lib/vigil/ack/<nume>`
  (directory `0775 vigil users`), consumed and deleted by the next tick; in v1
  it clears a NECITIT nota's suppression, nothing else. Consuming the ack deletes
  that contract's nota marker even when its verdict did not change.
- **Transitions → say.** `vigil-check` produces contract events: on `open`, `close`
  and the NECITIT `nota` it runs `$VIGIL_BIN say` (absolute path from the unit
  environment) with one JSON event `{gazda, nume, verdict, tranzitie, nivel, event_id, incident_id, occurred_at}` —
  never `tinta`, never log text. Failed sends remain in the authoritative queue and are projected under
  `/var/lib/vigil/outbox/`; active undelivered episodes do not expire.
- **say** = Telegram (`EnvironmentFile` = the existing `backup-telegram-env`
  shape; the chat is the owner's DM) + the status-row file, written **before**
  any network call. `nivel = "incident"` → every transition; `nivel = "nota"` →
  per-contract row + one message per *episode*: the marker `/var/lib/vigil/nota-sent/<nume>`
  holds the `verdict` it was sent for and is deleted by `vigil-check` when the
  contract's verdict changes or its ack is consumed. The special `vigil` marker
  is deleted only after a complete check run exits 0/1/2, so a later internal-fault
  episode alerts again without alerting every five minutes during one fault. When
  `VIGIL_SAY=0` (host without a keyed Telegram secret) say writes the row and
  exits 0 without touching the network. It asserts `"ok":true`; every
  successful send and a daily `sendChatAction` (`typing`, against
  `$TELEGRAM_CHAT_ID` — fails when the bot cannot reach *that chat*) touch
  `/var/lib/vigil/last-channel-ok`, which the `channel` contract checks with
  `age` (`prag = "2d"`). Every Telegram request has a 10-second deadline.
- **Tick.** `vigil-check`'s last action writes `/var/lib/vigil/tick.counts.json`
  atomically (`{run_id, la, verde, picat, necitit}`), where `run_id` is systemd's `$INVOCATION_ID` and `la` is the check-completion ISO time. Tests supply a unique invocation ID.
  `ExecStopPost = vigil tick
  write` reads it plus systemd's `$SERVICE_RESULT`/`$EXIT_STATUS` and replaces
  `/var/lib/vigil/tick` with `{run_id, la, verde, picat, necitit}`
  **only if** result is `success`, status ∈ {0,1,2}, the counts' `run_id`
  equals `$INVOCATION_ID`, and differs from the already published tick's `run_id`.
  Publish the entire counts object with one atomic rename, preserving its `la`;
  otherwise it leaves the tick stale — staleness is the peer's signal. A
  socket-activated responder on **:8747** serves it (`FreeBind`, after
  `tailscaled`, `Accept=yes`, `StandardError=journal`, `IPAddressAllow` on the
  **socket** unit — on the service it would be inert for accepted connections).
  Peers check it with `http` + `astept.prospetime` (reads `.la`, < 15 min), in
  **both** directions. ACL: choir→rpi5:8747 granted (measured 2026-09-20);
  rpi5→choir `ip:*`.
- **Privacy wall, law not style:** this repo is PUBLIC. No contract here names a
  family member's device, account or dashboard. Family-facing contracts on rpi5
  arrive as agenix secrets — one `.age` per contract, `path =
  "/run/vigil-contracts/contract-N.toml"`, `owner = "vigil"`, **`symlink =
  false`** — authored by the owner. Fixed-location devices only; `mobile_app` /
  `device_tracker`-backed entities are excluded. Outbound messages carry the
  generic `nume`; `motiv` is type-level and never includes `tinta`.
- Already in place: `secrets/ha-vigil-token.age` (#593); the module template
  `modules/services/sancta-archive-deadman.nix`; `tests/module-eval.nix`;
  CLAUDE.md's documented direct-bind exception for `sancta-gallery`.
  Bottleneck (design `GÂTUL ACUM`): the rpi5 half deployable with **one
  `nixos-rebuild switch` by the owner**. Task order follows that.

Files: `pkgs/vigil/` (`vigil-check.mjs`, `vigil-say.mjs`, `vigil-tick.mjs`,
`lib/{toml,checks,incident}.mjs`, `mutate.sh`), `pkgs/vigil.nix`,
`modules/services/vigil.nix`, `hosts/{rpi5-full,sancta-choir}/configuration.nix`,
`hosts/*/vigil-contracts/*.toml`, `secrets/secrets.nix`, `tests/module-eval.nix`,
`flake.nix`, `CLAUDE.md` (one paragraph).

## Tasks

### Shared schema and runtime rules

`[contract]` requires `nume`, `ce`, `verifica`, `tinta`, `picat_dupa`;
`[spune]` requires `nivel`. `nume` reserves `vigil` for the internal-failure
alarm; `ce` is 1–200 characters and is never sent or logged. `peer` defaults
false. Strings are single-line; `nume` and `verifica` use the closed values above.
`picat_dupa` is 1–12. `tinta` is a nonempty string except for `cmd`'s argv array.
`la` and `tinta_glob` are not contract keys. No implied defaults for expectations:

| verifica | target and required expectation | optional expectation |
|---|---|---|
| tcp | `tinta = "host:port"`; no `astept` or `prag` | none |
| http | absolute http(s) URL; `astept = { status = 200 }` (exact integer 100–599) | `body` regex string; `prospetime` duration |
| unit | exact `.service` unit name; no `astept` or `prag`; expects active | none |
| age | absolute file path or `unit:<name>.service`; `prag` duration | none |
| disk | absolute path; `prag` integer 1–100 (failure at use ≥ threshold) | none |
| mount | absolute mountpoint; no `astept` or `prag` | none |
| cmd | nonempty array of strings, absolute executable first; `astept = { valoare = "<expected>" }`, compared with trimmed stdout | none |
| hass-state | generic entity identifier, no URL; `astept = { valoare = "<expected state>" }` | none |

Durations are positive integers suffixed `s`, `m`, `h`, or `d`. Other expectation
keys and combinations are rejected. `hass-state` compares the returned `.state`
with `valoare`; unavailable/unknown state is picat; absent/malformed state is
NECITIT. Error messages are fixed type-level codes, never parser excerpts,
raw filenames, command output, URLs, entities, or exception messages. A malformed
file with no usable name gets `invalid-<sha256-of-full-path, first 16 hex>` as
its safe diagnostic identity. Every invalid file uses that identity even if it
contains a name, with `verifica = "invalid"` (output only, forbidden in input),
`picat_dupa = 2`, `nivel = "nota"`, and fixed `motiv = "contract-invalid"`;
the known `[recuperare]` case retains its fixed plan-2 code. It participates in
the same NECITIT threshold and acknowledgement rules. On repair, retire its
synthetic episode and pending nota. Do not construct paths from an invalid name.

All network and subprocess checks have a 10-second hard deadline (tcp 5 seconds),
bounded output (64 KiB), and no inherited interactive stdin. Check at most four
contracts concurrently. Telegram delivery is at-least-once: ambiguous timeouts
may duplicate a message. Persist transitions and pending events together in
one atomic `incidents.json` update before attempting delivery. Treat this file
as the authority; outbox files are an atomic projection for inspection. Mark
successful events delivered atomically. Keep an undelivered open or nota while
its episode is active, even across outages longer than 24 h. For ended episodes,
expire historical events after 24 h as a pair: never deliver a close without its
open. Log a fixed expiry code. Spend at most 60 seconds on delivery per tick,
including retries, to preserve time for the checks and publishing the tick.
All transitions go through one FIFO, never directly around older pending work.
Stop draining at the first failed head item. Each event additionally carries
`event_id` (UUID), `incident_id` (safe episode ID), and `occurred_at` (ISO);
include occurrence time in the message so delayed events are visibly dated.
Say validates these fields as part of its complete event schema. Internal-failure
events supply them too, with their own episode identity. The main loop runs
checks before draining the event queue; only the due bounded channel probe
precedes checks. Tests prove that open cannot arrive after its own close.
Never replay expired or retired nota episodes. Atomically clear a contract's
pending nota and suppression when consuming its ack or observing verdict change.
When delivery changes from disabled to enabled, enqueue the current open
incidents that have never been delivered, including ones opened during 5a.
The disabled mode writes rows but neither sends nor creates retry/outbox files.

The socket responder explicitly sets `STATE_DIRECTORY=/var/lib/vigil` as
read-only input, without `StateDirectory` making that directory writable in
its sandbox. The failure unit sets `StateDirectory=vigil` and inherits the
computed say environment including `VIGIL_SAY`; module-eval asserts both.

`last-channel-ok` records only a confirmed Telegram success. Do not seed it from
tmpfiles: do a bounded `--chataction` before checks when enabled and no successful
probe occurred in 24 h; only success updates `last-chataction`. A failed initial
probe honestly yields channel NECITIT. Closing checks inspect the latest complete
run after a successful probe rather than requiring all historical journal lines
to be green. Internal-failure sending uses the same bounded say implementation
and shared state directory, with all required environment variables supplied.

`incidents.json` corruption exits 3 without overwriting the file. Use temp-file,
fsync, rename, and parent-directory fsync for durable authoritative state. The
self-failure marker is separate so this alarm can still send on corrupt incident
state. All tests use a fresh temporary state directory; none call Telegram or
write deployed state. Tests cover kill/restart around each persistence boundary,
stale invocation counts, row-only→enabled replay, and Telegram deadline expiry.

Contract input/check failures are isolated; persistence faults are invocation
failures. In particular, a corrupt or unwritable transition row must not be
silently skipped: `say` requires its row before delivery, and the FIFO must retain
unconfirmed events. Transitions and alerts are committed before row projection;
a projection fault leaves completion counts unchanged and invokes self-failure.
After repair, queued alerts retry in order. This is distinct from an unreadable
contract input, which becomes NECITIT while the other checks continue.

An invalid file has a synthetic identity, so its presence prevents proving that
an absent old contract name was deleted. Keep unmatched incident state until all
file identities are readable again, and reset its consecutive/recovery evidence
to NECITIT while unmatched. A repaired contract resumes its original incident;
its continuous green hold starts again. Only a fully readable inventory may
retire names that are actually absent.

Filesystem probes have a 10-second observation deadline and return NECITIT when
it expires, releasing their checker slots. This does not cancel an outstanding
kernel filesystem request. If such a request prevents process exit, systemd's
existing invocation limit still fails the run and leaves the peer tick stale.

### Task 1: vigil-check — the deterministic core, with a negative arm that can go red
- [ ] `pkgs/vigil/vigil-check.mjs` (Node ESM, zero deps). All mutable state is rooted at `$STATE_DIRECTORY` (default `/var/lib/vigil`; systemd supplies that same path; tests supply a temporary directory), never hardcoded. Reads every `*.toml` in the argv directories, **stat-ing through symlinks** (`statSync(join(dir,name)).isFile()`, never `Dirent.isFile()`). Parses with the subset parser `lib/toml.mjs`; a file that fails parsing or any per-file schema/type/value rule is **accounted for as NECITIT** (with a safe diagnostic identity and fixed error code) and the run continues. Validates the closed schema, including the safe `nume` pattern and path confinement; a `[recuperare]` section → that contract is NECITIT with `motiv = "recuperare: plan 2"`. **Duplicate `nume` → exit 3** before any check. `--expect N` compares N with the number of `*.toml` files **present**; mismatch → exit 3. stderr reports `files present / parsed / necitit`.
- [ ] `lib/checks.mjs`, eight types: `tcp` (5 s); `http` (exact status, optional `astept.body` regex, optional `astept.prospetime` — body is JSON, `.la` ISO younger than the duration; 10 s; no redirects); `unit` (`$VIGIL_SYSTEMCTL show <name>` → `ActiveState`, system scope); `age` (absolute file → mtime, or `unit:<name>` → `ExecMainExitTimestamp` + `Result=success` via `systemctl show`); `disk` (`statfs` use% vs `prag`); `mount` (parse `/proc/self/mountinfo`, unescape, **mount-point field exact equality**); `cmd` (argv[0] ∈ `$VIGIL_CMD_ALLOW`, stdout vs `astept.valoare`); `hass-state` (`GET $HASS_URL/api/states/<tinta>`, bearer from the file at `$VIGIL_HASS_TOKEN_FILE`; `unavailable` → picat; ≠200 / no token → NECITIT). Spawn errors (`status === null`) and exit 127 → NECITIT, with a handler on the error event.
- [ ] `lib/incident.mjs`: pure functions over `(state, verdict, now)` — open (assign `incident_id`), close with hold-down, NECITIT-nota, ack drop-file. Persist `incidents.json` atomically by temp-file + rename; invalid existing JSON is an explicit internal fault (exit 3, preserving the bad file for diagnosis). On every verdict change or consumed ack, delete `nota-sent/<nume>` if present.
- [ ] Transitions and persistence follow Shared schema and runtime rules: durably enqueue before sending, retain active undelivered episodes and expire ended history per the shared rules, within the 60-second delivery budget, replay unsent open incidents on enabling delivery, and retire stale nota episodes. Perform the due channel probe before checks, recording its marker only on success. After completing state and count persistence, retire `nota-sent/vigil` for exits 0/1/2; `tick write` publishes only matching current-invocation counts.
- [ ] Output: one JSON line per contract (`nume`, `verifica`, `verdict`, `motiv` type-level, `incident`); summary on stderr; exit `0/1/2/3`.
- [ ] `--autoproba` uses a temporary `$STATE_DIRECTORY` and stub `$VIGIL_BIN` (contracts in memory, never written): loud (`tcp` closed port → picat); silent (`cmd` `/nonexistent/bin` → NECITIT via `ENOENT`; `age` missing file → NECITIT; `age unit:` with `Result=failed` → NECITIT; an unparsable or schema-invalid contract → NECITIT and the run continues; a `[recuperare]` → NECITIT "plan 2"); unsafe `nume` rejected; `mount` on `/` → verde, `/nonexistent-but-substring-of-root` → picat, **`/dev/sh` → picat**; `http prospetime` with a real tick body → verde, with `.la` 20 min old → picat; duplicate `nume` → exit 3; `--expect` mismatch on present files → exit 3; corrupt `incidents.json` → exit 3 without overwriting it; state machine: open → hold-down → close; NECITIT ×`picat_dupa` → one nota, verdict change or ack deletes the marker, next episode → nota again; self-failure fail → one nota, repeated fail → silent, successful run → marker cleared, later fail → nota. Assert **text** of each line; exit 2 on deviation.
- [ ] `NODE_OPTIONS= node --test pkgs/vigil/*.test.mjs`; `mutate.sh` mutants, each red from an assertion (`EȘEC` on stderr, no stack trace): (a) missing file → green; (b) hold-down 0; (c) NECITIT → exit 0; (d) `ENOENT` → picat; (e) mount via `mountpoint.includes(tinta)` (the `/dev/sh` fixture catches it); (f) nota marker never deleted (the re-fire arm catches it). `absenta` over all `.mjs` → 0.

### Task 2: vigil-say and vigil-tick — the voice, and the proof it can speak
- [ ] `vigil-say.mjs`: all state under `$STATE_DIRECTORY`; one event on stdin; validate the complete `{gazda,nume,verdict,tranzitie,nivel,event_id,incident_id,occurred_at}` shape and safe `nume`; **refuse** (exit 2) a `jurnal` or `tinta` key or any string > 500 chars. Writes `rows/<nume>.json` (`{gazda, nume, stare, la, event_id}`) **first**, using the event occurrence time and refusing to replace a newer row with an older event. If `$VIGIL_SAY == "0"` → exit 0, no network and no network-success markers. `nota` → if `nota-sent/<nume>` exists with the same `verdict` → exit 0; else send and write the marker with the verdict. `incident` → send. Send = `sendMessage` with a 10-second deadline, assert `"ok":true` → touch `last-say-ok` and `last-channel-ok`; else exit 1. `--chataction` → `sendChatAction` with the same deadline on `$TELEGRAM_CHAT_ID`, assert ok, touch `last-channel-ok`.
- [ ] `vigil-tick.mjs`: all state under `$STATE_DIRECTORY`; `write` — read `tick.counts.json`, the previous published `tick`, `$INVOCATION_ID`, and `$SERVICE_RESULT`/`$EXIT_STATUS`; publish with one atomic rename only on success/{0,1,2}/matching current invocation and a new `run_id`, preserving the counts' completion time. Invalid, stale or replayed counts never refresh the tick. `serve` — stdin/stdout only; accept bounded GET/HEAD requests on `/`, read at most 8 KiB of headers with a 2-second deadline, emit valid HTTP/1.1 with Content-Length and Connection: close; `200` + JSON if present, `404` if absent, invalid published data → 503. Never put diagnostics on stdout.
- [ ] `--autoproba` against a local fake Telegram: `ok:true`/`ok:false`/429/refused; marker/`last-*` semantics exactly as above; `VIGIL_SAY=0` writes the row and never connects; `nota` once, identical twice → once, after a verdict change → again; `jurnal`/`tinta`/501-char refused; tick `write` with `EXIT_STATUS=3` leaves the file, with `1` replaces it; `serve` 200/404.
- [ ] Mutants: say ignores `ok:false`; say lets `tinta` through; say sends in `VIGIL_SAY=0`; tick `serve` 200-empty on absent file; tick `write` ignores `EXIT_STATUS`. `absenta` clean.

### Task 3: services.vigil — the NixOS module, contracts validated before deployment
- [ ] `pkgs/vigil.nix` + `flake.nix` export for both systems; `nix build .#packages.x86_64-linux.vigil && result/bin/vigil autoproba` → 0.
- [ ] `modules/services/vigil.nix` options: `enable`; `contractsDirs` (list of Nix paths or absolute runtime strings, preserving the original type without coercion); `expectedContracts` (nonnegative int, mandatory when enabled, count of eval-visible Nix-path contracts); `expectedRuntimeContracts` (nonnegative int, default 0, count of string-path contracts); the module asserts `expectedContracts` equals the actual Nix-path `*.toml` count and passes their sum to `--expect`; `telegramEnvFile` (path or null → `VIGIL_SAY=0`; eval fails if null while any public contract has `nivel = "incident"` or is the `channel` contract); `hassTokenFile` / `hassUrl` (null → eval fails if any public `hass-state` contract); `tickPort` (8747); **`listenAddress` (`types.str`, mandatory)**; `cmdAllow`; `interval` (`5min`).
- [ ] Two-stage public-contract gate over original Nix-path entries only (runtime strings are skipped). At evaluation, a string/comment-aware scanner checks the TOML subset before `builtins.fromTOML`, then validates closed keys, field types, safe names, numeric limits, ordinary literal peer targets, uniqueness and service prerequisites. Quoted syntax-looking text and comments must remain data; reject literal/multiline strings, dotted/quoted keys, floats, datetimes, nondecimal numbers, numeric separators, arrays of tables and nested inline tables. Before activation, a mandatory `vigil-public-contracts` derivation invokes `vigil validate-public` using the exact runtime parser and schema, including full ECMAScript regex compilation and WHATWG URL normalization. The checker ExecStart must consume this validated derivation's copied public directories, making build validation unavoidable; expose it as `system.build.vigilContracts` and add a native x86_64 CI check for each host. This avoids duplicating Node's URL/regex engines in Nix and preserves valid regex/URL functionality. The shared corpus records evaluation expectations separately only for engine-semantic cases; every fixture must have identical final build-gate/runtime acceptance. Prove invalid regex and encoded-tailnet-without-peer fixtures fail real Nix builds, valid lookahead regexes remain supported, and no private runtime directory enters a derivation. Public build errors name the file; runtime errors keep fixed privacy-safe codes.
- [ ] Wire: `users.users.vigil`; `systemd.services.vigil` (`Type=oneshot`; `User=vigil`; `ExecStart = ${vigil}/bin/vigil check <dirs> [--expect public+runtime]`; `ExecStopPost = ${vigil}/bin/vigil tick write`; `TimeoutStartSec = "4min30s"` (below the 5-minute default interval; checks and delivery obey the stated budgets); `SuccessExitStatus = "1 2"`; `EnvironmentFile` when non-null; `Environment` = `VIGIL_BIN`, `VIGIL_SYSTEMCTL`, `VIGIL_CMD_ALLOW`, `VIGIL_SAY`, `HASS_URL`, `VIGIL_HASS_TOKEN_FILE`; `path = [ coreutils systemd ]`; `StateDirectory=vigil`; `ProtectSystem=strict`; `ProtectHome=true`; `OnFailure = [ "vigil-failed.service" ]`); `vigil-failed.service` (**`User=vigil`**, `TimeoutStartSec = "30s"`, same sandbox, `StateDirectory=vigil`, `EnvironmentFile` and say environment, sends the complete event `{gazda:<hostname>, nume:"vigil", verdict:"failed", tranzitie:"open", nivel:"nota", event_id:<UUID>, incident_id:<failure-episode-ID>, occurred_at:<ISO>}`); `systemd.tmpfiles.rules`: **`d /var/lib/vigil 0755 vigil vigil`** first (so `StateDirectory` never re-chowns), then `d /var/lib/vigil/outbox 0750 vigil vigil`, `d /var/lib/vigil/nota-sent 0750 vigil vigil`, `d /var/lib/vigil/ack 0775 vigil users`; `systemd.timers.vigil` (`wantedBy = [ "timers.target" ]`; `OnBootSec = "2min"`; `OnUnitActiveSec = cfg.interval`); `systemd.sockets.vigil-tick` (`wantedBy = [ "sockets.target" ]`; `after`/`wants` `tailscaled.service`; `ListenStream = "${cfg.listenAddress}:${toString cfg.tickPort}"`; `FreeBind = true`; `Accept = true`; **`IPAddressAllow = [ "100.64.0.0/10" "fd7a:115c:a1e0::/48" ]`, `IPAddressDeny = "any"` on the socket**) + `systemd.services."vigil-tick@"` (`ExecStart = ${vigil}/bin/vigil tick serve`; `StandardInput = "socket"`; **`StandardError = "journal"`**; `User=vigil`; `Environment.STATE_DIRECTORY = "/var/lib/vigil"`; strict read-only sandbox); a module assertion that `listenAddress` is inside `100.64.0.0/10`.
- [ ] `tests/module-eval.nix`: rendered-shape assertions for everything above (user + group; public/runtime count sum and a wrong-public-count failure; `SuccessExitStatus`; `ExecStopPost`; both timeouts; timer `OnBootSec` + `timers.target`; socket `sockets.target`, `FreeBind`, `IPAddressAllow` on the socket, address in range and ≠ `0.0.0.0`; `StandardError=journal` on the template; tmpfiles parent line and absence of a fabricated channel-success file; complete `vigil-failed` event as `vigil`); **negative arms** via fixture hosts: `verifica = "shell"`, unsafe `nume`, literal string, `prag = 85.0`, a datetime, a dotted key `astept.status = 200`, a `[recuperare]`, a `100.` `tinta` without `peer`, a duplicate `nume`, a `channel` contract with `telegramEnvFile = null`, a `hass-state` with `hassTokenFile = null` — each throws naming the file; fixtures with a `#` comment and syntax-looking text inside strings parse; and a fixture with `"/run/vigil-contracts"` in `contractsDirs` plus `expectedRuntimeContracts` **evaluates**.
- [ ] CLAUDE.md: extend the documented direct-bind exception paragraph to name `vigil-tick` alongside `sancta-gallery`, same reasoning (a dead responder must fail as `ECONNREFUSED`, which the peer's check reads as picat, not be swallowed by Serve's catch-all into a 200).
- [ ] `nix fmt`; `nix build .#checks.x86_64-linux.module-eval` green.

### Task 4: rpi5-full — the half that matters, deployable with one switch
- [ ] `hosts/rpi5-full/vigil-contracts/` (generic safe `nume`; no device names): `tailscaled.toml` (unit `tailscaled.service`); `ha-alive.toml` (http `http://127.0.0.1:8123/manifest.json`, `astept = { status = 200, body = "\"name\"" }`); `ha-served.toml` (http `https://rpi5.tail4249a9.ts.net:8123/manifest.json`, 200); `soul-mirror-pull.toml` (age `unit:soul-mirror-pull.service`, `prag = "8d"`); `choir-host.toml` (tcp `100.94.191.54:8747` — the port the module itself binds to the tailnet; **not** 8743, which is loopback + Serve; `peer = true`); `choir-tick.toml` (http `http://100.94.191.54:8747/`, `astept = { status = 200, prospetime = "15m" }`, `peer = true`); `channel.toml` (age `/var/lib/vigil/last-channel-ok`, `prag = "2d"`). Every file gives all fields required by its type, a generic `ce`, `picat_dupa = 2`, and `nivel = "incident"`. Seven files.
- [ ] Prepare `secrets/vigil-contracts.pending.nix` with `vigil-rpi5-contract-{1,2,3}.age` recipient rules matching `ha-vigil-token.age` (`users ++ [ rpi5 ]`). Do not import these rules into the active registry, create ciphertexts, or declare host secrets yet: the existing recipient guard rejects registered-but-missing files. The owner creates each ciphertext with `RULES=./vigil-contracts.pending.nix agenix -e vigil-rpi5-contract-N.age` from `secrets/`, then promotes all three rules and host declarations in the same commit as the ciphertexts. Include a generic template with an owner-replaced entity placeholder in the handoff.
- [ ] `hosts/rpi5-full/configuration.nix`: `services.vigil = { enable = true; contractsDirs = [ ./vigil-contracts ]; expectedContracts = 7; telegramEnvFile = secret "backup-telegram-env"; hassTokenFile = secret "ha-vigil-token"; hassUrl = "http://127.0.0.1:8123"; listenAddress = "100.106.93.87"; cmdAllow = []; }`; `age.secrets.ha-vigil-token = { …; owner = "vigil"; }`; for `backup-telegram-env` check its other consumers (`backup-pull`, `tailscale-dns-watchdog`) — if they need root ownership, set `group = "vigil"; mode = "0440";` and record which.
- [ ] module-eval green; `nix eval .#nixosConfigurations.rpi5-full.config.systemd.services.vigil.serviceConfig.ExecStart` succeeds; `nix fmt`; PR. **Closing check (his hand, after switch):** `vigil.timer` active (waiting), `vigil-tick.socket` listening; after a confirmed channel probe, the latest complete run (identified by its invocation ID, not a fixed journal tail) shows **7 contracts, zero NECITIT**, exit 0 or 1 (`choir-host`/`choir-tick` picat until Task 5 — picat, not NECITIT); `curl http://100.106.93.87:8747/` from choir returns the JSON tick with a fresh `.la`.

### Task 5: sancta-choir — the second half, in two PRs so the switch never fails
- [ ] **PR 5a.** `hosts/sancta-choir/vigil-contracts/` (all `nivel = "nota"` in this PR, because `telegramEnvFile = null`): `tailscaled.toml` (unit `tailscaled.service`); `galeria.toml` (http `http://100.94.191.54:8739/` 200, `peer = true`; this is the declared system gallery, not the independent screenshot server on loopback); `membrana.toml` (tcp `127.0.0.1:8743`; listener liveness without crossing its authenticated HTTP boundary); `soul-mirror.toml` (age `unit:sancta-soul-mirror.service`, 8d); `disk-root.toml` (disk `/`, 85); `build-volume.toml` (mount `/mnt/sancta-build-volume`); `rpi5-host.toml` (tcp `100.106.93.87:8747`, `peer`); `rpi5-tick.toml` (http `…:8747/`, `prospetime = "15m"`, `peer`). Every file gives all fields required by its type, a generic `ce`, and `picat_dupa = 2`. Enable with `telegramEnvFile = null`, `expectedContracts = 8`, `listenAddress = "100.94.191.54"`. Prepare the later activation patch adding `sancta-choir` to `backup-telegram-env.age`'s recipients, but leave the active rule unchanged in 5a. The owner applies that patch and runs the single-secret command `(cd secrets && EDITOR=: agenix -e backup-telegram-env.age)` before committing the rule and ciphertext together; never commit a recipient-count mismatch or use `agenix -r`. module-eval green; PR; his switch. Closing check: all 8 contracts verde; `curl http://100.94.191.54:8747/` from rpi5 fresh; `choir-host`/`choir-tick` on rpi5 turn verde; the packaged fake-Telegram autoproba proves a forced transition under `VIGIL_SAY=0` writes a row without a request, outbox entry or network-success marker. A healthy production run need not create per-contract transition rows under `rows/`; every completed run writes aggregate `row.json` and a fresh tick, whose eight verde verdicts are the production evidence.
- [ ] **PR 5b** (after all 5a incidents are closed; include the owner-confirmed single-secret re-key and recipient expansion in this same PR): `telegramEnvFile = secret "backup-telegram-env"` (owner/group as in Task 4), declare the secret on choir, add `channel.toml`, `expectedContracts = 9`, **flip all eight 5a contracts to `nivel = "incident"`**. Closing check (his hand, a quiet hour): `sudo systemctl stop sancta-gallery`; wait until the journal shows two consecutive picat ticks and exactly one Telegram `open`; start it; wait for two consecutive verde ticks plus the 30-minute hold-down and exactly one `close`. `last-channel-ok` exists; no row-only transition was silently carried into 5b.

### Task 6: the private contracts on rpi5, and the first real incident
- [ ] Once the owner has created the three `.age` files: declare `age.secrets.vigil-rpi5-contract-{1,2,3} = { file = …; owner = "vigil"; path = "/run/vigil-contracts/contract-N.toml"; symlink = false; }`, add `"/run/vigil-contracts"` to `contractsDirs`, keep `expectedContracts = 7`, and set `expectedRuntimeContracts = 3`. PR, CI, his switch. Closing check: `ls -l /run/vigil-contracts/` shows three regular `.toml` files owned by `vigil`; `journalctl -u vigil` shows **10 contracts, zero NECITIT**.
- [ ] `docs/plans/completed/2026-09-20-vigil-postdeploy.md`: commands only, no device names: timers active on both hosts; both tick endpoints answer the peer with fresh `.la`; `last-channel-ok` < 2 d on both; an isolated ack acceptance run as specified below; live ack remains pending until a natural NECITIT nota exists. **The plan is done only when the first real incident reaches Telegram**; record its date there. That date is the input to plan 2.

## Constraints

- PUBLIC repo. **No contract, comment, test, fixture or commit message names a family member's device, account, dashboard or entity id.** Family-facing contracts exist only as agenix ciphertext authored by the owner. If a task cannot be completed without naming one, stop and say so.
- No `sudo`, no root, no impersonation of `vigil`, **no privilege grant of any kind in v1** (polkit is plan 2). The only listener is the socket-activated tick on `:8747` bound to the configured tailnet address with `IPAddressAllow` on the socket; never `0.0.0.0`; the ACL is not changed.
- The user is `vigil`, hardcoded. The check-type set and the schema are closed; `cmd` is an allow-list of absolute executable paths; `[recuperare]` is rejected in v1; NECITIT is never exit 0; any per-contract parse/schema/type/value failure degrades to NECITIT, never to exit 3; exit 3 is reserved for duplicate `nume`, a present-file count mismatch, corrupt global state and crashes.
- **Any PR that adds or removes an eval-visible contract moves `expectedContracts`; any PR that adds or removes a runtime-only contract moves `expectedRuntimeContracts` in the same commit.** Module-eval proves the public count; runtime `--expect` proves their sum.
- Every new executable has `--autoproba` asserting **text** and at least one mutant in `mutate.sh` that turns it red from an assertion (`EȘEC`), never from a crash. `~/.claude/index/bin/absenta` over all new `.mjs` must exit 0 before a PR.
- Do not touch: the soul volume, `soul-mirror*`, `/nix`, `managed-settings`, `sancta-worker`, `herdr`, `gatus.nix`.
- House rules: worktree + PR; `nix fmt` in the background; `nix build .#checks.x86_64-linux.module-eval` before every PR; merge only on green CI **and zero medium+ review findings**; deploys, switches, re-keys, `.age` creation and ack drop-files are the owner's hand, written as exact commands in the PR body. Security findings return to the session, never onto the public PR.
- `hosts/rpi5-full` tracks `nixos-raspberrypi`'s nixpkgs pin, `sancta-choir` the root pin; eval both.
- Order is the bottleneck's: Task 4 before Task 5. Do not reorder.

## Disposition — round 1 (v1 → v2), 31 findings

All folded in; none refused. (Table unchanged from v2; kept for the record.)

| finding | where |
|---|---|
| owner sancta on rpi5 · exit 1/2 as failure · timer never fires · socket bind before tailscaled · listenAddress default · circular channel · agenix path/suffix/dir · explain↔say · explain journal access · `/bin/true` · polkit proof/enable/suffix · prospetime body · Task 5 secret ordering · fromTOML vs subset · dead `local`/`nivel` · no say producer · recovery never wired · redaction check on absence · two sources of truth · choir-tick freshness · ack path · tinta in logs · Node ENOENT · Task 4 NECITIT excuse · jurnal_filtru · cmd wording · mount substring · duplicate nume · missing mutants | Context / T1–T3 / T5 / Constraints; explain+recovery items now live in plan 2 |

## Disposition — round 2 (v2 → v3), 16 findings

All folded in; none refused: expectedContracts same-commit rule · hass token via env · `explicatie` transition (plan 2) · nota = row + one message · autoproba unit (plan 2) · tick counts file + `$SERVICE_RESULT` · tmpfiles owners · `sendChatAction` · `$VIGIL_BIN` · stale tick on failure · `/dev/sh` fixture · enumerated deny-list (plan 2) · 5b flips nota→incident · probe-fail unit (plan 2) · `symlink = false` · eval walk skips runtime dirs.

## Disposition — round 3 (v3 → v4), 16 findings

| finding | v4 |
|---|---|
| conclusions filename mismatch | plan 2 (explain removed from v1) |
| `lib.isStorePath` false for flake subdirs | `builtins.isPath` gate; fixture asserts negative arms throw |
| `IPAddressAllow` inert on the service for accepted sockets | moved to the **socket** unit; asserted there |
| `nota-sent` marker never cleared | deleted on verdict change or ack; self-failure marker retires after a successful run; re-fire arms + mutant (f) |
| row-only mode had no mechanism | `VIGIL_SAY=0`; row written first; asserted |
| post-`fromTOML` walk cannot see dotted keys | lexical pre-check of the source text + walk; dotted-key negative arm |
| `vigil-failed` ran as root | `User=vigil`, same sandbox |
| weekly polkit proof had no first run | plan 2 |
| tmpfiles parent created root → StateDirectory re-chown | explicit `d /var/lib/vigil 0755 vigil vigil` first |
| probe contracts red from the switch | plan 2 |
| unparsable contract → exit 3 → host unwatched | accounted as NECITIT; exit 3 only for present-file count / duplicates |
| explain never runs on real contracts (only the probe had `jurnal`) | plan 2, with this finding carried over |
| `choir-host` probed :8743 (loopback + Serve) | `:8747` |
| `user` option not propagated | option removed; `vigil` hardcoded |
| `incident_id` undefined | ISO timestamp of the open transition, in `incidents.json` |
| tick@ stderr on the TCP connection | `StandardError=journal`, asserted |

## Disposition — round 4 (v4 → v5), 17 findings

All folded in; none refused: episode lifecycle for contract and self-failure nota
markers · deterministic row-only deployment proof · complete contract values and
tick-count probe · Telegram and unit deadlines · complete self-failure event ·
5a must be all-green before delivery · persisted accepted run ID · runtime schema
errors become NECITIT · `$STATE_DIRECTORY` test isolation · atomic incident state ·
single-secret agenix re-key · confirmed-only channel freshness · split public/runtime
expected counts · dead `la` removed · literal-string gate plus accepted comments ·
unused `tinta_glob` removed · filename-safe, confined `nume`.

## Repository verification for v6

The declared choir gallery binds `100.94.191.54:8739`; loopback is an independent screenshot server. Choir Open-WebUI is disabled and n8n is not declared, so its inventory is eight contracts before channel and nine afterward. The single-secret re-key runs from `secrets/`, matching agenix's rules lookup. Tick identity and time publish in one file, and channel freshness comes only from an actual Telegram success.

## Final review disposition and acceptance

Round 6 completed with all sources present: five confirmed major findings and no critical findings. The implementation must prove: undelivered active opens survive a 30-hour outage; no systemd-journal grant; numeric rpi5 address 100.106.93.87 (observed from the local Tailscale peer list on 2026-09-20); aggregate status does not go green while another contract fails; and executable isolated ack acceptance. Round 5 also identified invalid-file fallback, auxiliary state environment, FIFO event ordering and retry starvation; their explicit rules above are required regression tests.

The main checker atomically writes `row.json` after each complete run, as
`{gazda, stare, la, verde, picat, necitit}`. Aggregate `stare` is NECITIT if
any result is unreadable, otherwise picat if any result or still-open incident
is failing, otherwise verde. Say writes only per-contract rows; replay cannot
overwrite the aggregate. Test overlapping incidents and replay of older rows.

The package provides `vigil autoproba --ack-only`: a temporary state directory,
a local fake Telegram server, and an age contract aimed at an intentionally
missing fixture file. Two checks must produce one nota; another check must not
repeat it. Create its ack, run two checks, assert the ack was consumed and one
new nota arrived, then create the missing fixture and confirm retirement.
Clean up the fixture in finally. This never alters production state or contacts
Telegram. The owner can run it after deployment as the actual service account:
`sudo systemd-run --unit=vigil-ack-acceptance --wait --collect --property=User=vigil --property=PrivateTmp=yes /run/current-system/sw/bin/vigil autoproba --ack-only`.
The module installs the CLI in systemPackages. This is isolated runtime
acceptance, not evidence that a live Telegram incident or production ack occurred.
Those remain explicitly pending in the operator handoff.
