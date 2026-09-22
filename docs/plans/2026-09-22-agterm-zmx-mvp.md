# Remote zmx MVP

One named session on choir survives an SSH disconnect and reattaches to the same
process. Agterm owns the Mac panes; zmx owns the remote PTY. The default is a fresh
shell under `sancta`, reached through the existing `root@sancta-choir-1` SSH target.
The existing `sancta-session`, `sancta-reconnect`, tmux sessions, worker, credentials,
and global agent settings are not invoked or modified by the MVP.

## Goal and phases

Run Claude Code and Codex in persistent remote zmx sessions, with agterm providing
the panes and reliable status routing. Adopt it gradually without losing existing
conversations or interrupting production services.

1. **Prove persistence.** An isolated choir shell keeps the same PID through a
   real SSH disconnect and reattach. Automated PTY tests establish the process
   mechanism; live SSH acceptance establishes the complete connection path.
2. **Prove agent integration.** A fresh Claude session survives reconnect and its
   actual lifecycle events reach only its owning pane. Verify Codex persistence
   separately, with no claim of automatic Codex status. Phases 1-2 are this MVP.
3. **Make it convenient.** Add a session picker, pane launch and tested restoration
   after restarting agterm. Do not change the app's global restore mode implicitly.
4. **Migrate deliberately.** Move selected workflows after acceptance, preserving
   conversations and a usable tmux fallback. Migration is separately approved.
5. **Complete both-agent support.** Add verified Codex status reporting and a
   documented recovery path after host reboot or daemon loss. Process survival
   and restarting a saved conversation remain distinct outcomes.

## Components

- `scripts/agterm-zmx/client.py`: run in an existing agterm pane. Opens a restricted
  local Unix status relay and SSH reverse forwarding, retries SSH exit 255 after
  five seconds. Ctrl-C during the wait cancels retries. No SSH agent forwarding.
  `--open --name NAME` creates a new agterm session; `--pick` lists live sessions
  from the remote inventory. Each attached client pins its own reconnect command
  using its stable pane token for agterm's Re-run commands restore mode.
- `scripts/agterm-zmx/host.py`: packaged as `agt-zmx-host`, with Python, bash and
  zmx supplied by Nix. Session records and sockets live in the account's private
  `~/.local/state/agt-zmx/`. Names are prefixed `agt-mvp-`.
- The host package is added only to choir's system packages. No boot service,
  firewall rule, or daemon is started by installation. The existing unstable
  nixpkgs pin supplies zmx 0.8.0; no flake update is needed.
- Claude receives additional hooks through its launch-specific `--settings`;
  hook payloads and transcripts never cross the relay. The relay accepts only
  four lifecycle states and fixes the target session and stable pane ID locally.

This is an original minimal implementation informed by agterm's
[remote-Claude recipe](https://github.com/umputun/agterm/tree/master/cookbook/remote-claude-session)
and [zmx's SSH workflow](https://github.com/neurosnap/zmx#ssh-workflow).
It does not vendor or install that cookbook's scripts.

## Acceptance before deployment

```sh
AGT_ZMX_TEST_BINARY=/Applications/agterm.app/Contents/MacOS/zmx \
  python3 -m unittest discover -s tests -p test_agterm_zmx.py -v
nix build .#checks.x86_64-linux.agterm-zmx
nix build .#packages.x86_64-linux.agterm-zmx-host
```

Tests cover an actual disposable zmx PTY retaining its shell PID after client
termination, refusal to reuse a name for another directory, remote shell quoting,
status destination changes, and the relay's target/command boundary over actual
sockets. Test daemons use their own temporary socket directory; cleanup targets
only the named test daemon. Mac's bundled zmx is 0.7.0; the Nix check uses the
actual packaged Linux zmx 0.8.0. Passing Mac tests alone does not establish Linux
or SSH integration acceptance.

## Launcher and picker

From the Mac checkout, after the remote package is approved and available:

```sh
python3 scripts/agterm-zmx/client.py --open --name shell-trial-1 --remote-bin /nix/store/REPLACE-WITH-BUILT-PACKAGE/bin/agt-zmx-host
python3 scripts/agterm-zmx/client.py --pick --remote-bin /nix/store/REPLACE-WITH-BUILT-PACKAGE/bin/agt-zmx-host
```

Both create a session under the `Remote zmx` workspace in the invoking window.
Cancellation creates nothing; dead remote sessions are excluded. The picker
does not create a new remote conversation. Use `--open` with an explicit new name
for that. An already attached session can be picked again; the one-recipient
limitation below still applies. This is not concurrent-viewer acceptance.

The restore pin contains the Python interpreter, client path, remote host/user,
session name, directory, agent and host executable. Keep those local files and
the remote package available. It targets the pane running the client, including
a right split, and leaves the app's global restore mode unchanged. In Fresh
shells mode it will not run; this workflow requires Re-run commands. A real app
restart test is still pending and requires approval because other local sessions
can be interrupted by restarting agterm.

## Choir pilot (owner approval required)

Build the host package from this reviewed worktree on a Linux builder. A pilot
can use the resulting `/nix/store/.../bin/agt-zmx-host` directly on choir with
`--remote-bin`; there is no need to switch the entire NixOS configuration merely
to try it. Keep a GC root for that package while pilot sessions use it.

In a **new Mac agterm shell pane**, from the checkout:

```sh
python3 scripts/agterm-zmx/client.py --name shell-trial-1 \
  --remote-bin /nix/store/REPLACE-WITH-BUILT-PACKAGE/bin/agt-zmx-host
```

The placeholder must be replaced with the actual built path. After approved
normal package deployment, omit `--remote-bin`. The defaults are
`--host root@sancta-choir-1 --user sancta --cwd /var/lib/sancta --agent shell`.
An empty `--user ''` uses the SSH account directly on other hosts.

1. In the **remote shell**, run `echo $$` and record the PID.
2. Close that new Mac pane. Do not type `exit`, which ends the remote shell.
3. Open another new pane and repeat the exact client command. `echo $$` must
   return the same PID. Also verify a real SSH/network disconnect reconnects.
4. Start a separate `--name claude-trial-1 --agent claude` session. Leave the main
   Sancta conversation alone. Confirm login, terminal drawing/resizing, and that
   real Claude prompt/tool/approval/Stop events reach only this pane.
5. Reattach this trial and repeat a turn to prove the updated relay destination
   works. A diagnostic `agt-zmx-host status` invocation exercises transport only;
   it is not acceptance of Claude lifecycle hooks.
6. `--agent codex` starts a fresh persistent Codex session. The expanded rollout
   generates an additional content-addressed profile containing lifecycle hooks;
   existing config and authentication files are preserved. Review these hooks in
   Codex `/hooks` before expecting them to run. Live Codex hook acceptance remains
   pending. `PermissionRequest` is not mapped to blocked because it can precede
   automatic review; accurate human-dialog detection is still outstanding.

Existing authentication is used. If unavailable, stop and arrange interactive
login separately; this tool never reads, copies, or creates credentials. No prompt
is automatically sent to either agent, and permission checks remain enabled.

## Limits and recovery

- One current status recipient per named remote session: the latest attach wins.
  Concurrent viewers are not an accepted MVP workflow.
- Status is a last observed lifecycle event, not progress or liveness. A Claude
  Stop means a turn ended, not that all background work finished. Disconnected
  events are dropped; the next event uses the new relay. There is no status replay.
- zmx persistence covers client loss, not host reboot or daemon death. If a record
  remains but its daemon is gone, attachment refuses instead of silently starting
  a fresh conversation. Pick a new name; existing transcripts remain available to
  the agent's own resume UI. Automatic conversation resume is deferred.
- The socket namespace is separate from ordinary zmx and tmux. Do not change
  zmx versions under a running pilot; protocol compatibility across upgrades is
  not promised. The MVP has no bulk cleanup or kill command.
- The SSH server must allow loopback reverse forwarding. A port collision or SSH
  forwarding failure produces a visible retry; Ctrl-C stops it. Root SSH can use
  `runuser`; other SSH accounts should leave `--user` empty.
- While connected, remote processes able to reach the forwarded loopback port
  can set this one pane's status. They cannot type into panes or access the raw
  agterm control API through the relay.
- Picker and pane-specific restore policy are implemented, with automated
  cancellation/targeting tests. Live picker and app restart acceptance are still
  pending. There is no installed key binding, remote git credential forwarding,
  or Sancta session migration yet.
- End a shell trial with `exit`. Agent exit leaves an interactive remote shell;
  exit that shell when finished. Closing the Mac pane only detaches.

## Rollout status

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
| Phase 3: picker, pane launch, app restoration | Pane launch and restore pin accepted live; native picker opened an attachment to the Claude pilot | Approved app restart acceptance |
| Phase 4: selected tmux workflows migrated | Owner selected the main Sancta Claude conversation; no existing workflow changed | Disposable same-conversation resume and tmux fallback accepted; finish restart gate and obtain interruption approval |
| Phase 5: Codex status and cold recovery | Codex active/completed hooks accepted before and after real SSH reconnect; owner files preserved in tests | Human-dialog status, document and test cold recovery |

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
