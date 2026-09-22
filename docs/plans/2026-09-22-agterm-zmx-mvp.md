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
6. `--agent codex` starts a fresh persistent Codex session, but **automatic Codex
   lifecycle status is not implemented** in this MVP.

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
| Phase 1: real SSH reconnect retains PID | Same-PID PTY tests pass on Mac and Linux | Approved real choir SSH pilot |
| Phase 2: real Claude events and Codex persistence | Claude launch-scoped hooks implemented; relay tested | Agent login, real events, correct-pane and reconnect acceptance |
| Phase 3: picker, pane launch, app restoration | Implemented; 12 Mac tests pass including cancellation and stable-pane restore targeting | Linux rebuild and live UI/restart acceptance |
| Phase 4: selected tmux workflows migrated | No existing workflow changed | Select conversations, checkpoint, approve interruption, migrate, test fallback |
| Phase 5: Codex status and cold recovery | Installed Codex 0.154.0 and official hook docs inspected | Implement and verify status; document and test recovery |

Codex's bundled agterm integration treats `PermissionRequest` as an approval
candidate: automatic review can resolve it without showing a human dialog.
Blindly mapping that event to blocked would fail the accurate-status goal.
Codex hooks must also be reviewed/trusted through its supported hook flow; the
rollout must not bypass hook trust or sandbox/approval controls to make tests pass.
