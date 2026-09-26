# Sancta ownership: activation and rollback review

This is an operator procedure, not permission to execute it. Autonomous work
only prepares code and disposable tests. Production is not declared repaired.

## Prerequisites

1. Review the final PR revision and its parent #612, native package/test results,
   rendered managed guard and the findings in the ownership review. Do not merge
   or deploy the current draft merely because its Python tests pass.
2. Build the host and client artifacts for that exact revision, record immutable
   paths, and compare the resulting system with the currently deployed system.
   Review the activation diff separately; a package test is not a system-switch
   impact assessment. Do not include unrelated updates in a narrow pilot.
3. Reinspect current writer identities, backend inventory, process ancestry,
   executable versions and guard registration using metadata only. Do not print
   argv, transcript IDs or settings bodies. Preserve owner checkout edits.
4. Obtain explicit approval for the concrete host/client activation and for any
   existing-session interruption. One approval does not imply the other.

## Approved transition, in order

1. Record existing host generation and Mac `agt-zmx`, `sancta`, and remote-profile
   targets. Back up the owner reconnect script and user settings privately with
   mode 0600 and hashes; do not put these backups in the repository or print them.
   Retain GC roots for the old immutable packages.
2. With the owner present, choose the authoritative conversation and exit any
   duplicate cleanly. Never use the old reconciliation script to kill candidates.
   Verify the result again. An inventory from an earlier day is insufficient.
3. Install the approved immutable helper and managed registration. This changes
   future launches; it cannot give an existing process a lock retroactively.
   The old backend and agent remain old code until an approved recovery.
4. Review the current soul-volume reconnect script against its saved hash, then
   apply `scripts/sancta-reconnect-attach.sh` as a separately approved owner-file
   migration, preserving its ownership and permissions. Its timer kill-only mode
   refuses to sweep, and its ordinary mode attaches. Verify any caller that
   parses its output before replacing it; no timer changes are implicit here.
5. Update the Mac remote profile's immutable `remote_bin` and the appropriate
   saved pane restoration commands to the built helper/client paths. Update the
   Darwin declarative pin as well. Existing profile pins from #28 refer to the old
   helper and do not automatically change when the host switches.
6. After an explicitly approved clean agent exit, recover the stopped conversation
   with the new helper into a new named backend using its explicit private UUID.
   Preserve the old backend record and transcript; do not edit a live record or
   blindly rerun its creation callback. Update the host and Mac Sancta alias
   together to the new backend name. Review these exact names privately before
   performing the transition.
7. Verify ownership while the recovered process is alive. A second supported
   recovery attempt must refuse before launching another agent. Call Mac `sancta`
   twice and attach from a separate SSH terminal; all must reach the same backend
   without another writer. Disconnect attachments and confirm the writer survives.
8. Verify that a fresh real Claude session loaded the managed guard and blocks
   an unscanned commit in an isolated repository before git executes. No real
   secret or publication is needed. Hook self-tests alone do not prove this.
9. Perform the deferred human picker, notification-click and native-question
   acceptance. Do not mark these passed from synthetic routing assertions.

## Rollback

- If an attachment fails, preserve all processes and records. Restore the saved
  client/profile pin and attach the still-live backend; do not launch a second
  writer as a fallback.
- If a newly recovered agent must be replaced, obtain interruption approval,
  exit it cleanly and verify it stopped before any alternate recovery. Do not
  unlink a lock file; a stale file is harmless, a live inode replacement is not.
- A full system rollback needs its own impact review and approval. Removing the
  new managed entry also removes secret-guard registration, so rollback does not
  preserve the new protection automatically. Keep that tradeoff explicit.
- Restore the old owner reconnect script only under explicit approval: restoring
  it reintroduces destructive reconciliation and the original bypass. A disabled
  legacy entry point is preferable to silently restoring that behavior.

## Scope limits

This is cooperative ownership for supported launchers, not a security boundary
against the account owner. Direct Claude binaries, in-session resume/continue,
changed configuration roots, deleting lock files, and old still-running launchers
can bypass it. A child that closes inherited descriptors can lose the inherited
lock after its parent dies; process-metadata checks provide another refusal path,
not an atomic replacement for ownership. Production rollout must retain these
limitations until tested or explicitly excluded from supported use.
