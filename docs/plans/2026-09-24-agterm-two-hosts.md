# Two-host agterm rollout

Goal: persistent Claude, Codex and shell sessions on choir and rpi5, including
Sancta on choir, with navigation, native status/notifications, HUDs and questions.
The six phases and production approval boundary remain unchanged.

## Prepared

- Host selection precedes SSH discovery; an unavailable choir does not block rpi5.
- Explicit restore commands preserve host/account/backend identity and scope.
- Mac Sancta shortcut explicitly selects choir.
- ARM helper packaging and rpi5 user lingering are declarative.
- Host-side `sessions list` and `sessions attach NAME` preserve existing routes,
  refuse ended records and cannot restart an agent. Choir's Sancta alias is
  account-scoped in `/etc/agt-zmx-aliases.json`.
- Native helper builds and integration tests pass on both architectures. Mac
  package build and Home Manager profile evaluation passed before helper repinning.

## Remaining acceptance and activation

Review CI for the final revisions. PR #612 targets main because NixOS workflows
filter on that base; it includes the prerequisite #609 changes until they merge.
Darwin #28 depends on #27. Do not infer a merge or deployment from a green build.

Before activation, inspect current live sessions and installed pins again. Obtain
approval for rpi5 lingering and helper installation, the additional choir helper
and alias configuration, and the two-host Mac profile/client installation. Existing
conditional approval covers only the separately reviewed choir client correction.
Preserve old immutable packages, pins, process identities and conversation state.

Use disposable sessions to verify each host's Claude/Codex/shell lifecycle,
reconnects, directory, native HUD ownership, question answer/cancel/disconnect and
split restoration. Carry forward accepted choir evidence where implementation is
unchanged. User-observed picker focus and notification click delivery remain open;
programmatic delivery alone is not human acceptance. Claude interruption that
restores a draft can still leave active status; do not clear it based on a guess.

No production activation or existing-session interruption is performed by these
PRs' build and test steps. Never launch a second Sancta writer or delete a record
as recovery. Plain-terminal attachment does not provide native agterm UI.
