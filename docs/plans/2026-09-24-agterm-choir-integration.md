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

Still required: declarative Mac package/config/shortcuts, live picker choices,
native HUD open/update/close for a real remote task, selected question reply and
cancellation/disconnect acceptance, restored panes using installed package paths,
and PR checks. Production deployment, app restart and Sancta interruption each
require owner approval. Do not claim the full six-phase goal complete before
those acceptance checks pass.
