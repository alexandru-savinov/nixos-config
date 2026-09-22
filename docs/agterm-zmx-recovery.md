# Recovering remote agterm/zmx sessions

SSH loss, application restart, and host restart require different recovery actions.
Do not delete session records to make an error disappear: doing so can start a new
conversation under an old name.

## SSH connection lost

The Mac launcher retries SSH automatically. Reattachment updates the status route
for that pane. A second attachment to the same session becomes the status
recipient; status is not broadcast to all attached panes.

Use the native picker to attach an existing live backend. Preserve its recorded
agent, directory, resume UUID (if present), and `--user-scope` setting. Do not start
a replacement agent merely because one SSH observation timed out.

## agterm restarted

The launcher's explicit restore command is used in agterm's **Re-run commands**
mode. It starts a new SSH attachment to the existing backend. It does not resume a
new agent process when the backend still exists. Fresh-shell mode does not run
that command, and changing the global restore mode requires separate review.

If automatic restoration fails, run the saved launcher command in a new agterm
pane, or use the native picker. Verify the remote process identity and a real
agent turn before declaring recovery complete. Merely seeing restored text is
not proof that input or status works.

## Host reboot or missing zmx daemon

A host reboot destroys process memory. A lost daemon is not a surviving session.
The helper refuses to reuse a recorded name whose daemon is gone and leaves both
the record and status route intact. Preserve the old record, transcript, checkout,
and credentials. Use a **new backend name** for recovery.

1. Confirm the backend is actually gone, rather than unreachable. The helper's
   inventory reports liveness; also inspect the relevant process and user scope.
   Do not restart SSH/Tailscale or remove sockets as a discovery step.
2. For an agent conversation, identify the exact saved conversation. A backend
   name is not an agent conversation UUID. Resumed helper records contain the UUID;
   fresh conversations may require the agent's own resume picker. Do not select
   “most recent” when several conversations exist.
3. Confirm the previous agent process has ended before starting another writer.
4. Resume in the original working directory as the original account. A successful
   recovery has a new process PID, the same conversation identity, retained prior
   context, and a successfully completed new turn.

For Claude, the launcher supports explicit `--resume UUID --agent claude` with a
new `--name` and `--user-scope`. It requires an existing transcript and refuses a
matching live process from Claude's session metadata. Its lock serializes helper
launches; independent manual Claude launches must also respect the single-writer
rule. The helper never stops a source process or invokes `sancta-reconnect`.

For Codex, the installed CLI supports `codex resume UUID` in the original working
directory. `codex resume --all` opens its cross-directory picker if the UUID is
unknown. This is currently a **manual recovery fallback**, not a supported
`client.py --resume` mode: that option currently accepts Claude only. A plain
Codex resume inside a shell does not automatically install a new pane's status
profile. Do not claim automatic status for this fallback. Integrated Codex cold
recovery remains an acceptance gap.

A shell's unsaved process state cannot be recovered after reboot. Start a new
shell under a new backend name and inspect the existing files before rerunning
any command with side effects.

## Returning the selected Claude conversation to tmux

Keep the original tmux pane and shell available throughout migration. If rollback
is needed, exit the zmx agent and verify its PID has ended, then run
`claude --resume UUID` from the original directory in that retained tmux shell.
Use the same UUID, not a fresh conversation or `--continue`.

Injected `/exit` and EOF did not reliably exit one reattached pilot. Check the
actual process after any exit request. The disposable fallback test used a
verified targeted SIGTERM, checked that the old PID had exited, and then resumed
successfully in a separate tmux session. Applying an interruption to the main
conversation still requires explicit owner approval.

## Evidence and outstanding acceptance

The rollout record is [the pilot plan](plans/2026-09-22-agterm-zmx-mvp.md).
SSH reconnect, independent user-scope placement, explicit Claude resume, retained
context, duplicate-launch refusal, and a disposable tmux fallback are verified.
No host reboot was performed. App restart, integrated Codex cold recovery,
human-approval status, and main-conversation migration remain separate gates.
