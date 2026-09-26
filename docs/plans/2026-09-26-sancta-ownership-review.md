# Sancta conversation ownership: autonomous preparation

Status: in progress; no production activation or session interruption authorized.

## Verified evidence

- The Mac `sancta` executable already uses `agt-zmx --profile choir --session sancta`.
- The owner confirmed the second writer was started manually with `claude --resume`.
- The incident RCA identifies a legacy argv substring guard that cannot recognize all launch shapes. It also reports settings migration; its attribution is not independently proven by file timestamps alone.
- The latest read-only process inventory found one live Claude process associated with the main conversation. No process was stopped by this work.
- The secret-guard source exists and is executable; registration is absent from both user and managed settings. Actual live hook enforcement remains unverified.

## Changes staged so far

- Existing zmx backend attachments use `false` as the create-if-missing payload. Loss after inventory must not start a replacement agent.
- Explicit conversation locks are shared by agent configuration directory instead of backend state directory. Lock paths reject symlinks and multiply linked files and require private ownership and modes.
- Agent exit ends its backend shell rather than leaving an unguarded login shell. Explicit shell sessions are unchanged.
- `sessions resume AGENT UUID --cwd DIRECTORY` provides explicit stopped-conversation recovery through the shared lock. It does not accept argument pass-through, ambiguous names, a resume picker or config overrides.
- The legacy root `sancta-session` entry point now attaches the existing backend; its prior stop/reconcile/relaunch implementation has been removed. The owner soul-volume script remains unchanged and is a residual bypass pending separately approved migration.
- Secret-guard registration is staged in the existing managed-settings module, preserving user settings and the other managed hook entries. It uses the existing bounded fail-closed Bash wrapper.
- Fresh Claude records now allocate an explicit UUID, acquire its conversation lock before launch, and pass it through `--session-id`. Reattachment preserves the record; launching it again after a transcript exists fails instead of reusing it as a fresh conversation. Legacy fresh-agent records without a locked identity refuse recovery through `launch`.
- Local regression suite: 60 tests, 59 passed and one optional real-zmx test skipped. Includes a real disposable fake-agent process proving lock contention, lifetime, release and exit status. A surviving fake agent retains the inherited lock after its parent launcher is killed. This does not establish native PTY or human UI acceptance or real Claude descriptor retention.
- A new simultaneous-process test reproduced an intermittent file-opening failure in the initial create-or-open implementation. Exclusive creation followed by opening the winner's existing inode passed 20 consecutive targeted runs. The test asserts one owner, one refusal, recovery after SIGKILL of the disposable owner, and unchanged lock inode during recovery.
- Rendered choir managed settings contain exactly one Bash secret-guard entry with a bounded fail-closed wrapper. The outer hook timeout exceeds the inner timeout plus escalation window.
- `tests/check_sancta_guard_wrapper.py` passed all 13 cases locally and then on Linux against the exact rendered timeout executable. It checks error status mapping, missing/non-executable/hung guards, other-user exclusion, real guard deny/allow inputs, and independent user-settings replacement. This is hook-protocol evidence, not evidence that Claude loads the managed layer.
- Native Linux real-zmx integration and module-evaluation builds passed. Outputs: `/nix/store/ks83pjjyjcgzh7j31sjbpvkc3yia1i3b-agterm-zmx-integration-tests` and `/nix/store/5f9lgxk4qsazhhbzr8rp4lrkyrzvkn21-module-eval-tests`. The real PTY test verifies the same shell PID survives attachment loss and reconnect; it also rejects a mismatched directory. The earlier Mac-only module evaluation could not realize a Linux import-from-derivation; native validation supersedes that limitation.
- The helper built natively at `/nix/store/s1ha72iq6fkphqxalxk7pm92lr0gxhz8-agterm-zmx-host-0.1.0`; both packaged CLI help commands passed. This is a build artifact, not an installed production profile.
- Existing guard source copied read-only to a private local fixture: SHA-256 `4844e499f22f319304ebcaa664b8add3ac7ee2d51dd920d425330f8ecf639b96`. All 21 self-tests passed, including stdin-level allow and block. No real secret or production repository was used. The program is a command-pattern tripwire, not a secret scanner or containment boundary; constructed commands and a misleading hook marker can bypass it.

## Remaining implementation and adversarial review

Automated review found that replacing the legacy scope launcher also removed
its resource limits. The staged correction moves those same limits to a choir
user-unit drop-in for `agt-mvp-sancta-*.scope`, with an assertion that the Sancta
alias uses the matching prefix. Read-only `/proc` inspection confirmed the
surviving backend is already under `user@993.service`, outside tailscaled's
cgroup; the old review's claim that the agent moved back into tailscaled was not
supported by that observation. The missing memory ceilings were a valid finding.
Both stale scope comments were corrected. Native module validation must be rerun
for this correction. Prefix drop-in lookup follows the upstream
[systemd unit documentation](https://github.com/systemd/systemd/blob/main/man/systemd.unit.xml).

1. Review every supported launch/recovery command against the shared ownership mechanism. Direct execution of an unwrapped Claude binary, in-session conversation switching, and the old soul-volume launcher remain cooperative-lock bypasses. A launcher cannot prevent the same user from executing another binary or removing their own lock file. Do not claim universal enforcement. Codex fresh sessions retain native identity/writer-lock behavior; the added shared lock covers explicit Codex recovery.
2. Validate the legacy entry point replacement and prepare the soul-volume script migration for separately approved activation.
3. Verify rendered managed registration and wrapper enforcement in fixtures, including missing, crashed and timed-out guards and simulated user-settings rewrites.
4. Test lock inheritance, simultaneous launch, parent/agent crashes, stale files, separate backend namespaces and repeated attachment using disposable processes and transcripts.
5. Run relevant module/package checks, review the complete diff, create PRs and prepare exact activation and rollback steps.

Draft PR #618 is stacked on #612. Companion Darwin PR #29 is stacked on #28 and
pins choir to the built immutable helper; the existing installed profile remains
unchanged. The main-target Nix workflow does not run on the stacked NixOS base.
Native Linux test/module validation completed in an isolated temporary checkout
at revision `bf1f6b3`, one build worker/core, without activation. Follow-up
artifact and exact-wrapper checks used `2f79785` with unchanged helper sources.
The transition review
is in `2026-09-26-sancta-activation.md`; the owner reconnect replacement template is
`scripts/sancta-reconnect-attach.sh` and is deliberately not installed automatically.

## Deferred production gates

- Reverify single-writer state immediately before any approved activation. An earlier inventory is not continuing proof.
- Activate only after explicit owner approval; existing unwrapped processes cannot acquire a new cooperative lock retroactively.
- Validate guard loading in a fresh real agent after an approved transition. Fixture hook success does not prove the running agent loaded it.
- Human picker, notification-click and question-answer acceptance remain deferred.

No secret contents, transcript bodies or private conversation identifiers belong in this document or PRs.
