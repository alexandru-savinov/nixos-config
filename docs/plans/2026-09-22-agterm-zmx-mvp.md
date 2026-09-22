# Remote zmx rollout

The five-phase rollout is accepted for choir. The main Sancta Claude conversation
now runs in zmx with its original conversation history. The original tmux shell
remains available for fallback. Shell and agent reconnects, the native picker,
agterm restart restoration, real lifecycle status, and explicit conversation
recovery have been exercised. No NixOS switch was performed.

## Daily use on this Mac

Run these commands in a Mac agterm shell:

```sh
~/.local/bin/agt-zmx --pick
~/.local/bin/agt-zmx --open --name my-shell --agent shell
~/.local/bin/agt-zmx --open --name my-claude --agent claude --cwd /home/nixos
~/.local/bin/agt-zmx --open --name my-codex --agent codex --cwd /home/nixos
```

Use a unique name for each new backend. The picker attaches an existing live
backend without creating another conversation. Closing the Mac pane detaches;
exiting the remote agent leaves a shell, and exiting that shell ends the backend.

The installed launcher uses a versioned client outside the worktree, the tested
remote Nix store package, and independent user scopes. Its default target is
`root@sancta-choir-1`, running as `sancta`. Main Sancta and recovered Codex restore
commands now reference the versioned client. Keep the remote package GC roots.
Agterm's existing **Re-run commands** restore mode remains unchanged.

## Architecture and boundaries

Agterm owns Mac panes; zmx owns remote PTYs. The client retries SSH loss and pins
an explicit pane restore command. Private remote session records retain launch
identity. The latest attachment receives status through a restricted loopback
relay accepting only four lifecycle states, never transcript or hook payloads.

Claude uses launch-specific settings. Codex uses an additional content-addressed
profile, preserving owner configuration and credentials. Review its hooks through
the normal Codex trust UI. Real lifecycle events and the observed English command
approval dialog were accepted; other dialog formats/locales are not claimed.
The dialog observer reads only its owning pane locally and does not log or relay
terminal text. Automatic permission review is not mistaken for human blocking.

Status is the last observed lifecycle event, not liveness. Lost events are not
replayed. One current status recipient per backend is supported. SSH persistence
does not preserve processes through host reboot or daemon death: use an explicit
saved conversation UUID with a new backend name, following the
[recovery instructions](../agterm-zmx-recovery.md). Both agents' recovery is
accepted; the destructive recovery test used a disposable Codex daemon, not a
host reboot. Never delete native writer locks or old records to bypass a refusal.

Packages are exposed for x86_64-linux, the choir pilot platform. Installation adds
no boot service or firewall rule. Do not change zmx versions under running
backends. No global hooks, SSH agent forwarding, or automatic migration occurs.

## Validation

All 23 tests passed on macOS with bundled zmx 0.7.0 and on choir with packaged
zmx 0.8.0. The full suite includes a real disposable PTY; ordinary flake checks
run the 22 protocol tests separately. Live acceptance is recorded below.

```sh
AGT_ZMX_TEST_BINARY=/Applications/agterm.app/Contents/MacOS/zmx \
  python3 -m unittest discover -s tests -p test_agterm_zmx.py -v
nix build .#checks.x86_64-linux.agterm-zmx
nix build .#packages.x86_64-linux.agterm-zmx-tests
nix build .#packages.x86_64-linux.agterm-zmx-host
```

The following evidence is chronological. Statements about pending gates describe
that checkpoint; the audit table and final acceptance entries give current status.

## Historical implementation and acceptance evidence

Draft PR: https://github.com/alexandru-savinov/nixos-config/pull/609

At implementation commit `0218b06dac94518b366c002cf507659e2bf912af`:

- All eight tests passed on macOS with bundled zmx 0.7.0.
- The package built on choir with `--max-jobs 1 --cores 1`, and all eight Nix
  acceptance tests passed there with Linux zmx 0.8.0, inside the build sandbox.
- Formatting and package evaluation passed. No flake lock changed.
- Built pilot executable:
  `/nix/store/96nsymrqyx6bfvfyhv3hqq0xmkafwmh9-agterm-zmx-host-0.1.0/bin/agt-zmx-host`.
  The build used `--no-link`; establish a GC root before a live pilot.

No production switch, existing session interruption, global hook installation,
or agent launch occurred. Live choir SSH and real-agent acceptance remain pending
owner approval and must be recorded separately from these build-sandbox tests.

## Full-goal audit (after the user expanded beyond the MVP)

| Requirement | Evidence | Remaining gate |
|---|---|---|
| Phase 1: real SSH reconnect retains PID | Passed on choir; evidence below | Complete for the isolated shell |
| Phase 2: real Claude events and Codex persistence | Both exact agent PIDs survive SSH reconnect; Claude real hooks and tool result accepted | Complete for the fresh pilots; migration is separate |
| Phase 3: picker, pane launch, app restoration | Pane launch and restore pin accepted live; native picker opened an attachment to the Claude pilot | Complete for the tested restored pilot panes |
| Phase 4: selected tmux workflows migrated | Main Sancta resumed with the same conversation identity; SSH reconnect and new turn accepted; original tmux shell retained | Complete for the owner-selected main Sancta conversation; evidence below |
| Phase 5: Codex status and cold recovery | Codex active/completed hooks accepted before and after real SSH reconnect; owner files preserved in tests | Complete: native writer guard, daemon-loss resume, retained context and new turn accepted |

Codex's bundled agterm integration treats `PermissionRequest` as an approval
candidate: automatic review can resolve it without showing a human dialog.
Blindly mapping that event to blocked would fail the accurate-status goal.
Codex hooks must also be reviewed/trusted through its supported hook flow; the
rollout must not bypass hook trust or sandbox/approval controls to make tests pass.

## Approved live pilot evidence, 2026-09-22

The owner explicitly approved isolated shell/Claude/Codex pilots without a system
switch or interruption of existing sessions. The pilot runs under `sancta`, using
existing credentials; no credential contents were printed or copied.

An initial live-only failure identified `runuser` retaining `/root` as cwd. zmx
tried to initialize its unprivileged daemon there before the Python launch
callback changed directory. Commit `fcce3adacfad3b99e922fc518ef4a43252cde523`
changes cwd/PWD before starting zmx and adds a regression test. All 13 tests at
that commit passed on both Mac zmx 0.7.0 and Linux zmx 0.8.0.

Accepted package:
`/nix/store/a7bn521q6yd39bmxqv3gd2p9wg2sh78g-agterm-zmx-host-0.1.0`.
GC roots are `/root/agterm-zmx-pilot-fcce3ad` and its second build output. Earlier
pilot build roots are retained; no unrelated results were removed.

| Pilot | Agterm session | Process evidence | Reconnect evidence |
|---|---|---|---|
| shell-pilot2-20260922 | C34418C2-9B68-41D5-A715-864B17F297D5 | Shell PID 3369559 before and after | SSH reverse-forward port changed 54456 → 39770 |
| claude-pilot-20260922 | 27F36884-3C11-4CA9-9F10-C801274F8010 | Claude PID 3370919 survived; started 20:03:47 host time | Port changed 42703 → 35643 |
| codex-pilot-20260922 | 2AC219F0-F345-4AA4-86E0-5B94C799267E | Codex PID 3371278 survived; started 20:04:19 host time | Port changed 21724 → 40854 |

Only the pilot SSH clients were disconnected, using SSH's escape sequence. No
tailscaled, sshd, worker, or existing tmux session was restarted. Each client
reconnected automatically. Both agents returned their prescribed no-tools
acceptance response. Claude showed real `active → completed` transitions in its
own pane. After reconnect, another turn executed exactly `sleep 2` once and
returned its prescribed response; transcript inspection emitted only the count
of that exact tool invocation and matching successful result (one each).

The long second Claude test prompt initially remained a draft when text and
Return were injected together. A separately delivered Return submitted it and
the hook-driven status reached completed. Automated future probes should verify
the draft and submit Return separately; process survival alone is not proof that
a new turn was accepted.

The failed first shell pilot pane is
`264B7B5F-F31D-4161-B895-507ACBF52661`; its daemon is gone. Its record and the
`shell-debug-20260922` record are retained as failed-pilot evidence. The picker
excludes both because they are not live. No claim of agterm app-restart acceptance
or tmux migration follows from these tests.

### Codex lifecycle pilot

Commit `f2bf89b2cbb7dbc29d998d76c28a19ec10dbccc8` passed all 14 tests on Mac
and choir, including actual zmx PTY persistence and preservation of existing
Codex configuration/auth files when creating a separate profile. Built package:
`/nix/store/7jgsnzxw2hzsarj90mw9n4sa13ybps72-agterm-zmx-host-0.1.0`;
rooted at `/root/agterm-zmx-pilot-f2bf89b`.

Fresh pilot `codex-status-pilot-20260922` runs in agterm session
`34CA40F3-B0FE-40CE-8475-2F36A23AF6AF`. The normal Codex hook-trust screen
appeared; `/hooks` subsequently confirmed seven installed and seven active hooks.
No hook-trust bypass flag or sandbox relaxation was used. An attempted numeric
review-menu selection appeared as a conversation prompt instead; do not count
that injection as proof of navigating the review submenu. The active inventory
and actual lifecycle events are the acceptance evidence.

A deliberate `sleep 2` turn showed `active → completed` in the owning pane and
returned exactly `ZMX_CODEX_STATUS_ACCEPTED`. An SSH escape disconnect changed
the route port from 53043 to 45137; Codex PID 3376847 (started 20:23:48 host time)
survived. A new no-tools turn after reconnect again showed `active → completed`
and returned exactly `ZMX_CODEX_STATUS_RECONNECTED`.
Human approval-dialog `blocked` status is not implemented or accepted yet.

### Selected migration preflight

The owner selected the main Sancta Claude conversation. Read-only inspection
found `sancta-session.scope` inactive and only one Sancta-owned tmux pane with
Claude foreground: `4:0.0`, cwd `/home/nixos`, shell PID 3270087, Claude PID
3270160. Its cgroup is an existing user-manager tmux-spawn scope, not
`sancta-session.scope`; no explicit resume UUID was present in its argv.
The owner explicitly confirmed that this is the intended conversation.

Do not invoke `sancta-session` or `sancta-reconnect` merely to discover identity:
their documented reconciliation can stop an existing conversation. Before
migration, identify the current conversation UUID without printing its contents,
record the existing scope protections, and prepare an explicit same-conversation
resume plus tmux fallback. Explicit Claude `--resume UUID` support is now prepared and requires an existing
transcript plus a stopped source process. Live resume/fallback acceptance remains
pending; helper support alone is insufficient for the handoff. No existing pane or process has been stopped.

### Native picker acceptance and review follow-up

The native picker returned a selection of `claude-pilot-20260922` and opened
agterm session `269D3EC7-A557-43B8-844E-4EE87A07E5CB`. Its restore command pins
that same remote session, agent, cwd, and the tested package. The original Claude
PID 3370919 remained alive. The latest attachment becomes the status recipient;
two attached panes do not both receive hook status under the current contract.

The selected main Sancta process has one matching Claude session metadata record
with an explicit conversation UUID. Exact handoff details are kept in a local
mode-0600 review file; conversation contents were not read or published. The
existing source process has not been interrupted.

Automated review found a duplicate unstable nixpkgs import in the package wiring.
The package now uses the existing architecture-specific binding. Both Linux
package derivation evaluations pass, and the x86_64 derivation remains identical
to the package tested above. No rebuild or redeployment is needed for that fix.

### Explicit resume preparation

`--resume UUID --agent claude` is preserved through the picker, SSH transport,
and restore command. The host requires a matching transcript filename and checks
Claude process metadata without reading transcript contents. A matching live PID
causes refusal; the helper never stops the source. A per-conversation lock is
inherited by the agent's parent shell and released when the agent exits, preventing
concurrent cooperating helper launches. Independent manual Claude launches do not
honor that lock, so the operator must still avoid concurrent writers.

All 17 Mac tests passed, including refusal for a live conversation, absent
transcript, lock inheritance and release through a real child shell, and identity
transport. The production metadata schema was checked against the selected process.

Read-only cgroup inspection confirmed both existing fresh agent pilots remain in
`tailscaled.service`. SSH reconnect acceptance does not prove independence from a
Tailscale service restart. Migration must place the new backend in a user-manager
scope, preserving the selected tmux workflow's transport-independent lifetime;
this remains a required pre-migration implementation and acceptance gate.

### Scoped resume and tmux fallback accepted, 2026-09-22

Commit `042a5621944e450548cf7dd7b8c2a1cf173c6a59` passed all 18 tests on Mac
and Linux. Choir package:
`/nix/store/q70v0xszgb65rq5hz9hqf96l9kgyx771-agterm-zmx-host-0.1.0`, rooted at
`/root/agterm-zmx-pilot-042a562`.

`--user-scope` creates the backend inside the existing systemd user manager.
Reattachments use that backend directly, without creating another scope. The
flag is preserved in inventory, picker selection, SSH arguments, and restore
commands. Existing unscoped pilots retain their original contract; migration
and new production launches must explicitly include `--user-scope`.

The disposable Claude pilot exited, then resumed by exact conversation UUID in
new agterm pane `7418166E-E444-4143-9C56-9FAF0913085E`, session name
`claude-resume-pilot-20260922`. Its new PID 3384809 was confirmed in
`/user.slice/user-993.slice/user@993.service/app.slice/agt-mvp-claude-resume-pilot-20260922.scope`.
It recalled the prior acceptance marker without that marker appearing in the
new prompt and reported `active → completed`. A concurrent resume attempt was
refused before creating a second agent. SSH disconnect changed relay port
32243 → 44169 while preserving both PID and independent cgroup.

For the reverse handoff, injected `/exit` was interpreted as conversation input
and injected EOF did not exit the agent. No successful clean CLI exit is claimed
for that step. After confirming exact pilot identity and idle state, SIGTERM was
sent only to PID 3384809; its exit was verified before any replacement started.
The transcript remained in place. Isolated tmux session
`agt-fallback-pilot-20260922` then resumed that exact conversation as PID 3386566,
showed the prior history, and answered a new turn with
`ZMX_TMUX_FALLBACK_ACCEPTED`. Session metadata confirmed the same UUID, and its
cgroup is an independent tmux-spawn user scope. The fallback remains running.

This proves disposable conversation preservation in both directions and recovery
after an agent process ends. It does not prove a whole host reboot, agterm app
restart, human approval-dialog status, or migration of the main conversation.
The main Sancta PID 3270160 remained alive throughout. Production interruption
still requires explicit owner approval; no such interruption was performed.

### Validation entry points

Following review, general `checks.x86_64-linux.agterm-zmx` runs the protocol
suite only. Full PTY persistence acceptance remains required for this rollout:
`nix build .#packages.x86_64-linux.agterm-zmx-tests` on choir (or the matching
architecture on another Linux host). The package runs the entire suite, including
the real PTY reconnect test. This keeps terminal timing out of unrelated general
flake checks without removing the integration test or treating it as optional
rollout evidence. Mac validation still sets `AGT_ZMX_TEST_BINARY` explicitly.

### Recovery refusal and restart attempt

The missing-daemon diagnostic now directs the operator to preserve the old record
and explicitly resume a saved conversation under a new backend name. A regression
verifies that no exec occurs and neither record nor route is overwritten. All 19
Mac tests passed. See [the recovery guide](../agterm-zmx-recovery.md) for supported
paths and the remaining integrated Codex recovery gap.

The owner approved a clean agterm restart, including effects on five other local
sessions. Immediately before the attempt, agterm PID was 3252, active/configured
restore mode was rerun, and three open pilot panes had pinned restore commands.
Remote baseline: shell 3369559, Codex status pilot 3376847, disposable tmux Claude
3386566, and main Sancta Claude 3270160. The Codex route port was 45137.

A detached supervisor sent an AppleScript clean-quit request at 17:58:08 UTC. It
timed out, then verified agterm still running and stopped without force-killing
or reopening it. A PID-addressed normal macOS quit request is being investigated;
no app-restart acceptance follows from a request alone. The permission/confirmation
UI question is pending. The restart approval remains valid; do not request the
same approval again solely because this attempt failed.

### Owner-completed app restart and command-approval status

After the two normal programmatic quit requests left agterm running, the owner
reported restarting it. Verification found app PID 5544 instead of 3252, rerun
mode still active, and all four current pilot panes realized with their same
restore commands. Remote PIDs 3369559 (shell), 3376847 (Codex), 3386566 (disposable
tmux fallback), and 3270160 (main Sancta) remained unchanged. The Codex route port
changed 45137 → 54139. A new turn returned `ZMX_APP_RESTART_ACCEPTED` and changed
its owning pane from active to completed. This is live app-restart acceptance;
it does not rely on the earlier timed-out quit requests.

The separate `codex-human-pilot-20260922` uses two private launch-only wrapper
files to set `approvals_reviewer="user"` and on-request approval. The owner's base
configuration still uses auto review and was not edited. Its agterm pane is
`6FDB1218-0F15-43E9-98EC-BF0552639F3A`; the ordinary hook-review UI confirmed all
seven generated hooks active. A real `sleep 3` approval test showed
`active → blocked → active → completed` and returned `ZMX_BLOCKED_STATUS_ACCEPTED`.

The local observer recognizes the observed English Codex command-approval dialog
from its header, choices, and final footer. It reads only the owning pane's final
24 lines in memory; it does not log or send their text. A generation guard drops
screen observations superseded by lifecycle events. Clearing a dialog restores
the latest actual lifecycle state. Automatic-review events alone do not mark the
pane blocked. Other dialog types/locales are not claimed as supported. All 22 Mac
tests passed, including ordinary-prose rejection, stale-screen/Stop ordering, and
retry after failed status delivery.

Main-source preflight still matches the selected conversation UUID and PID
3270160; only booleans for an empty prompt and absence of the interrupt hint were
emitted from its screen inspection. The tested independent user scope matches
the original tmux scope: unlimited MemoryHigh/MemoryMax/MemorySwapMax,
OOMPolicy=stop, KillMode=control-group. Main interruption remains unapproved.

### Main Sancta migration accepted

The owner explicitly approved interrupting Sancta after restart and approval-status
acceptance. Final checks found the selected conversation unchanged, its prompt
empty, no interrupt hint, its transcript present, and the new backend name unused.
Its source argv had only `--resume` and no positional/custom-prompt arguments.

SIGTERM was sent only to source Claude PID 3270160 after rechecking identity and
idle indicators. Exit was observed before starting any replacement; no force kill
was used. The exact conversation UUID was resumed in `/home/nixos` as `sancta`,
using the previously tested package and `--user-scope`.

New backend: `sancta-main-20260922`; agterm pane:
`DEE045C4-9DE3-4AEE-83FE-C5C48C6E4182`. Claude PID 3394805 (started 21:21:27 host
time) has the same conversation UUID and is in
`/user.slice/user-993.slice/user@993.service/app.slice/agt-mvp-sancta-main-20260922.scope`.
Original tmux pane `4:0.0` remains at bash PID 3270087 for fallback.

An SSH disconnect changed the route port 30420 → 53296 without changing Claude
PID 3394805. A new no-tools acceptance turn returned `SANCTA_ZMX_RECONNECTED`
and the owning pane showed `active → completed`. No transcript contents were
printed; identity and readiness checks emitted allowlisted metadata/booleans.
The exact conversation UUID and fallback command remain in the private local
handoff review. No NixOS switch, credential creation, or unrelated service
interruption occurred.

## Codex daemon-loss recovery and stable launcher acceptance

At implementation commit `7fb4b7ed4c289c04b92400f5a2fe40304dddba14`, the helper
supports explicit Codex resume and probes the existing native thread writer lock
read-only. A live source was refused. Only the disposable
`codex-status-pilot-20260922` daemon was then stopped, after identity checks;
its old record and route remained unchanged. Reusing that name was refused.

`codex-recovered-20260922` resumed the original thread in its original directory,
in an independent user scope. New PID 3398320 held the original thread's native
writer lock. After normal hook review, a new turn recalled the earlier acceptance
marker without that marker being supplied in the prompt. The owning pane showed
`active → completed`. Main Sancta PID 3394805 remained running throughout.
This establishes saved-context recovery, not survival of a process after reboot.

The Mac entrypoint `~/.local/bin/agt-zmx` uses the immutable client at
`~/.local/share/agterm-zmx/7fb4b7ed4c289c04b92400f5a2fe40304dddba14/client.py`
and tested remote package
`/nix/store/bq2ka5s4j65aqhlmqbw0f102bayvgnp1-agterm-zmx-host-0.1.0`.
The client bytes match the committed source. Main Sancta and recovered Codex
restore pins were updated without interrupting their running clients. Existing
package roots and the original tmux shell were retained.

## Claude permission-hook review evidence

The [official Claude hook reference](https://code.claude.com/docs/en/hooks#permissionrequest)
defines `PermissionRequest` as the tool-permission request signal. The configured
event name is valid; it is not inferred from Codex's similarly named event.
Another permission hook can decide the request, so this is a lifecycle signal,
not proof that a human dialog remains visible. This rollout verifies Claude's
real prompt/tool/Stop events; it does not claim a separately exercised Claude
permission-dialog transition. Codex's actual human command-dialog transition was
exercised separately as recorded above.
