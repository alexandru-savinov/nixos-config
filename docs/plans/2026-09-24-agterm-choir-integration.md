# Choir native interface rollout

Scope: Sancta, Claude, Codex and shell sessions on choir. Preserve the accepted
zmx persistence/recovery paths and tmux fallback. No rpi5 rollout.

## Implemented, pending deployment and native acceptance

- `--menu` offers live backends and fresh Claude, Codex and shell sessions;
  `--session sancta` resolves the configured alias from host inventory.
- The local configuration is `~/.config/agterm/remote-choir.json` (override with
  `AGT_REMOTE_CONFIG`). Friendly workspace/title changes do not change backend
  identity. Existing attachments are focused using host/user/backend identity.
- New splits refuse an existing split, including a hidden one. Custom picker
  directory/name entries use the documented `query` result field.
- SSH connection notices remain separate from agent lifecycle state.
- `agt-ui --hud open 'Counting files'`, `--hud update 'Count complete'`, and
  `--hud close` address only the owning Mac attachment. Panels expire after
  60 seconds; update renews that interval. Refresh longer-running tasks before
  expiry. An expired panel must be opened again.
- `agt-ask 'Choose a mode' --button inspect=Inspect --button cancel=Cancel`
  returns JSON. Only an answered question exits zero. Escape, timeout and
  disconnect are not permission grants. Neither tool executes the selection.
- UI text is explicitly supplied by the remote command; transcripts and hook
  stdin are not forwarded. Remote requests cannot provide Mac control commands,
  session IDs, pane IDs or executable actions.

Native pane HUDs and questions require agterm 0.31.0 or later. The remote helper
must be on the agent's PATH or called by its full installed path. Existing
backends retain their original environment; do not restart Sancta implicitly.

## Platform limits

The transport uses a per-attachment 256-bit token for every status/UI request.
The token travels through encrypted SSH stdin, never argv or environment, and
is stored in a 0600 route file under the backend user's 0700 state directory.
The Mac checks it before dispatch and invalidates it on disconnect. Other host
users can reach the TCP listener but cannot submit authenticated requests.
The relay caps concurrent handlers at 16 and the accept backlog at 16. Excess
connections are closed before a worker thread is created; handler completion or
thread-start failure releases its slot. Saturation can still delay delivery,
but does not create an unbounded number of Mac worker threads.
Activation approval must explicitly include creation of these short-lived
tokens; existing credentials are not changed or re-keyed.

A private Unix-forward prototype passed kernel permission tests but failed the
actual Tailscale SSH forwarding test. Choir's ordinary alias uses Tailscale SSH,
so OpenSSH daemon forwarding settings do not establish transport support. The
unsupported Unix-forward implementation has been replaced, not deployed.

Old running agents retain hooks pointing at the previous helper, which
does not authenticate its status requests. They must be cleanly resumed with the new helper
before enabling this transport for their attachment. The main Sancta resume
requires explicit owner approval; preserve its conversation identity and tmux
fallback. Do not claim a client-only upgrade preserves its old status hooks.

Claude's `PermissionRequest` event is confirmed in the official hook reference:
https://code.claude.com/docs/en/hooks#permissionrequest . The event represents a
permission decision, not proof that a human dialog remains visible; another hook
can decide it. Live acceptance subsequently observed a real Claude Bash permission dialog
and blocked status in its own pane; the request was cancelled without approval.
Codex was tested separately with its own genuine command-approval dialog.

Agterm has one HUD slot per session. Two split panes cannot display independent
HUDs simultaneously. The bridge uses a per-session advisory lease and refuses
an occupied slot; update/close compare the owned panel fingerprint first.
External manual UI changes are not atomic with that comparison because agterm
has no compare-and-update HUD API. Avoid concurrent external HUD writers in the
same session. Native questions use agterm's separate question lifecycle.

## Evidence and remaining gates

2026-09-24: 38 local tests passed, including a real zmx PTY process surviving
disconnect/reattach. Question routing uses real local relay sockets with mocked
native UI responses; HUD ownership, foreign-slot refusal, expiry/cleanup logic
and question cancellation tests do not constitute live native UI acceptance.
The 0.31.0 DMG checksum, app signature and Gatekeeper notarization were verified
without installing or launching it.

## Approved activation and native acceptance

The owner approved activation, per-attachment token creation, a clean Sancta
resume, and the app upgrade/restart. The first automated clean Sancta exit failed
and did not force-kill anything. After the owner exited it, its old backend was
also gone. Its unchanged saved conversation was recovered in
`sancta-main-20260924`; metadata proved exactly one writer using the new hooks.
The old record and tmux fallback were preserved.

The installed Mac package, profile, wrapper and shortcuts use immutable Nix
paths. Both packages have GC roots. Homebrew installed agterm 0.31.0. An early
reopen initially ran the old binary; the final owner-completed reopen was
verified as 0.31.0. Both remote panes restored and the same Sancta writer survived.

Live acceptance on 0.31.0 established:

- Installed `sancta` focuses the recovered pane without duplicating it.
- A remote file-check task read and hashed four helper-package files; its HUD
  opened in the disposable pane, updated with the result and closed.
- The owner's native Received button returned `answered/received` to choir.
- Native cancellation returned exit 2 and no answer ID.
- Disconnecting only the disposable SSH tunnel removed its pending question
  and HUD; automatic reconnect accepted another authenticated UI request.
- Fresh Claude and Codex each produced `active` then `completed` in their own
  pane on a harmless response-only task. Codex's seven hooks were verified
  against the immutable helper before approval through its hook-review UI.
- In more restrictive disposable permission modes, both agents showed actual
  permission dialogs and `blocked` in the owning pane. Both requests were
  cancelled without granting access. Main Sancta's permission policy was untouched.
- The installed split workflow created a new right backend with its own
  immutable restore pin while preserving the left shell backend. A terminal
  notification from the right split registered as unread in that session.

Remaining: owner confirmation of visible notification/click routing and native
picker selection, final cleanup/status checks, and current PR check acceptance.
Forty local/package integration tests passed before activation; those automated
tests supplement rather than replace the native evidence above. The complete
six-phase goal remains open until the remaining acceptance requirements pass.

## Claude cancellation regression found during acceptance

Claude 2.1.270 did not emit a clearing lifecycle hook when Esc cancelled its
permission dialog, leaving the deployed client falsely blocked. The candidate
client now probes only a blocked Claude attachment's visible screen for the
observed empty idle composer. It does not save or forward that screen text.
Unknown layouts, nonempty composers, ongoing activity and newer lifecycle events
prevent clearing. Completed timing lines are distinguished from busy spinners.

The candidate passed a real repeat of the request/cancel sequence on a disposable
backend: blocked cleared to idle without approving the command. The 43-test
suite passed with the optional real-PTY case skipped in this invocation; real
SSH/UI acceptance was run separately. The native layout probe is conservative
and currently covers the observed English Claude UI. This correction remains
staged until its immutable client package is built and activated; the running
main Sancta attachment still uses the previous client.

The follow-up review identified unbounded pre-authentication connection threads.
A local socket regression reproduced the missing bound before the fix. The
corrected relay rejects excess concurrent peers and accepts new work after
occupied slots are released. The combined 44-test suite passed with the optional
real-PTY case skipped. Both client corrections remain staged for main Sancta.

## Resume inventory guard

Review found that globbing a missing Claude sessions directory silently skipped
the live-writer check. The staged helper now enumerates that directory explicitly
and refuses resume if it is missing, is not a directory, or cannot be read.
The regression failed before the fix and passed afterward; the complete 44-test
suite passed with one optional PTY test skipped. Transcript contents remain unread.
This helper change is staged only. It does not change the built Mac client or
authorize replacing the deployed helper or restarting Sancta.
