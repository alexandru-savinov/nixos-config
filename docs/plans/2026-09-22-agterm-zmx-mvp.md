# Remote zmx MVP

One named session on choir survives an SSH disconnect and reattaches to the same
process. Agterm owns the Mac panes; zmx owns the remote PTY. The default is a fresh
shell under `sancta`, reached through the existing `root@sancta-choir-1` SSH target.
The existing `sancta-session`, `sancta-reconnect`, tmux sessions, worker, credentials,
and global agent settings are not invoked or modified by the MVP.

## Components

- `scripts/agterm-zmx/client.py`: run in an existing agterm pane. Opens a restricted
  local Unix status relay and SSH reverse forwarding, retries SSH exit 255 after
  five seconds. Ctrl-C during the wait cancels retries. No SSH agent forwarding.
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
- There is no picker, key binding, automatic Mac app restart restoration, remote
  git credential forwarding, or Sancta session migration in this first version.
- End a shell trial with `exit`. Agent exit leaves an interactive remote shell;
  exit that shell when finished. Closing the Mac pane only detaches.

## Rollout status

Implementation and isolated acceptance are tracked in the PR. No production
switch, existing session interruption, or global hook installation is implied by
these tests. Live choir SSH and real-agent acceptance must be recorded separately.
