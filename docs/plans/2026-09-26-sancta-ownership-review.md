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
- `tests/check_sancta_guard_wrapper.py` passed 13 local fixture cases against the rendered command with only its Linux timeout binary replaced by the Mac equivalent. It checks error status mapping, missing/non-executable/hung guards, other-user exclusion, real guard deny/allow inputs, and independent user-settings replacement. This is hook-protocol evidence, not evidence that Claude loads the managed layer. Native execution of the exact Linux command remains to be checked.
- Broad `checks.x86_64-linux.module-eval` evaluation reached a Linux-only import-from-derivation and failed on the Mac because no Linux builder was available (`sancta-archive-deadman`). This is not a passed module check; run it on a Linux builder or CI. The evaluation process is terminal, not still running.
- Existing guard source copied read-only to a private local fixture: SHA-256 `4844e499f22f319304ebcaa664b8add3ac7ee2d51dd920d425330f8ecf639b96`. All 21 self-tests passed, including stdin-level allow and block. No real secret or production repository was used. The program is a command-pattern tripwire, not a secret scanner or containment boundary; constructed commands and a misleading hook marker can bypass it.

## Remaining implementation and adversarial review

1. Review every supported launch/recovery command against the shared ownership mechanism. Direct execution of an unwrapped Claude binary, in-session conversation switching, and the old soul-volume launcher remain cooperative-lock bypasses. A launcher cannot prevent the same user from executing another binary or removing their own lock file. Do not claim universal enforcement. Codex fresh sessions retain native identity/writer-lock behavior; the added shared lock covers explicit Codex recovery.
2. Validate the legacy entry point replacement and prepare the soul-volume script migration for separately approved activation.
3. Verify rendered managed registration and wrapper enforcement in fixtures, including missing, crashed and timed-out guards and simulated user-settings rewrites.
4. Test lock inheritance, simultaneous launch, parent/agent crashes, stale files, separate backend namespaces and repeated attachment using disposable processes and transcripts.
5. Run relevant module/package checks, review the complete diff, create PRs and prepare exact activation and rollback steps.

Draft PR #618 is stacked on #612. The main-target Nix workflow does not run on
this stacked base. Native Linux test/module validation was started in an isolated
temporary checkout at revision `bf1f6b3`, one build worker/core, without activation.
Collect its terminal result before calling the check passed. The transition review
is in `2026-09-26-sancta-activation.md`; the owner reconnect replacement template is
`scripts/sancta-reconnect-attach.sh` and is deliberately not installed automatically.

## Deferred production gates

- Reverify single-writer state immediately before any approved activation. An earlier inventory is not continuing proof.
- Activate only after explicit owner approval; existing unwrapped processes cannot acquire a new cooperative lock retroactively.
- Validate guard loading in a fresh real agent after an approved transition. Fixture hook success does not prove the running agent loaded it.
- Human picker, notification-click and question-answer acceptance remain deferred.

No secret contents, transcript bodies or private conversation identifiers belong in this document or PRs.
