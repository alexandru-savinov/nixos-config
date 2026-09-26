# Sancta conversation ownership: autonomous preparation

Status: autonomous implementation and test evidence prepared; latest automated review pending. No production activation or session interruption authorized.

## Verified evidence

- The Mac `sancta` executable already uses `agt-zmx --profile choir --session sancta`.
- The owner confirmed the second writer was started manually with `claude --resume`.
- The incident RCA identifies a legacy argv substring guard that cannot recognize all launch shapes. It also reports settings migration; its attribution is not independently proven by file timestamps alone.
- The latest read-only process inventory found one live Claude process associated with the main conversation. No process was stopped by this work.
- The secret-guard source exists and is executable; registration is absent from both user and managed settings. Actual live hook enforcement remains unverified.

## Prepared changes

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

## Requirement audit

| Requirement | Evidence and boundary |
| --- | --- |
| Read-only diagnosis | Owner confirmed manual raw resume; process metadata and cgroups were inspected without transcript content. Settings migration attribution remains a hypothesis. |
| Supported Mac/SSH attachment | Existing Mac alias selects the named backend; terminal attach and legacy `sancta-session` are attachment-only. Tests reject missing backends and assert no agent launch payload on reattachment. |
| Atomic ownership | Shared per-agent configuration lock covers explicit zmx/terminal recovery and new Claude identities. Concurrent contenders produce one owner; stale files are reused without inode replacement. |
| Crash and recovery | Disposable process tests cover normal exit, owner SIGKILL, inherited descriptor retention after parent death and release after the remaining child exits. Real Claude descriptor behavior remains a live acceptance gate. |
| Persistence and routing | Native PTY test retains the same shell PID across client loss and reconnect. Automated tests cover host/account/backend matching, alias routing, no duplicate pane creation and correct-pane restore identity. Human UI acceptance is not claimed. |
| Guard restoration | Managed registration preserves unrelated user settings. Existing source passed 21 fixtures; rendered wrapper passed 13 cases on both Mac and exact Linux dependencies. Runtime Claude loading remains deferred. |
| Preserved resource policy | Native module assertion and isolated VM passed. The VM reads back all five scope properties and verifies the loaded prefix drop-in. |
| Reviewable delivery | NixOS PR #618 and Darwin PR #29, native helper artifact, secret-scan/format checks, owner-script replacement template and separate activation/rollback procedure. Latest automated review remains pending. |

The first automated review correctly identified missing legacy memory ceilings.
Read-only `/proc` inspection also confirmed the surviving writer already lives
outside tailscaled's cgroup. The correction preserves the ceilings on the real
backend using `modules/services/sancta-session-scope.nix`. The first VM build
caught a nested `environment.etc` collision; packaging through `systemd.packages`
fixed it. The corrected VM run
[36249215579](https://github.com/alexandru-savinov/nixos-config/actions/runs/36249215579)
passed, and the review thread was resolved. Native module validation at `0af4414`
also passed, producing `/nix/store/ayps6m34gfn519xzxhqvqp8jckbpf3ki-module-eval-tests`.
The second review identified missing CI coverage for the rendered guard wrapper.
The dedicated workflow now builds `sancta-guard-wrapper` with a synthetic public
fixture; the private guard source remains outside the repository. Its first run
caught an invalid fixture shebang inside the Nix sandbox because the harmless
allow case failed. Patching the fixture interpreter fixed this, and both the
wrapper gate and scope VM passed at `08fae03` in run
[36249811113](https://github.com/alexandru-savinov/nixos-config/actions/runs/36249811113).
That review thread is resolved. The synthetic gate checks wrapper behavior;
the separate private-source fixture run supplies evidence about the existing guard.

The subsequent review identified that the stacked-branch workflow did not run
lock-safety tests, despite successful local and native builds. The workflow now
also builds the protocol suite, real-zmx reconnect integration, helper package
and module assertions, and watches their source paths. Their CI result is pending;
this delivery remains draft until that gate and review complete.

Prefix matching follows the upstream
[systemd unit documentation](https://github.com/systemd/systemd/blob/main/man/systemd.unit.xml).

## Residual findings and operating boundary

- These are cooperative locks, not containment against the owning account.
  Direct unwrapped Claude execution, in-session conversation switching, changed
  configuration roots, lock-file removal and old running launchers can bypass
  them. The normal supported path is attachment; explicit stopped recovery uses
  `sessions resume` or the zmx helper. No resume picker is supported for recovery.
- A child that closes inherited descriptors may lose inherited ownership after
  its parent dies. Metadata checks provide an additional refusal path, not an
  atomic replacement for the lock. The fake-agent crash test must not be cited
  as proof about the real Claude runtime.
- The owner soul-volume reconnect script remains untouched. Its attachment-only
  replacement is a reviewed migration template, not an automatic activation.
- The secret guard is a command-pattern tripwire. Constructed commands or a
  misleading hook marker can defeat it. Registration durability does not turn it
  into a secret scanner or prove that a currently running agent loaded it.
- Plain-terminal recovery has no agterm lifecycle bridge and stays in its terminal
  process tree. Use a `sancta-`-prefixed zmx backend with user scoping for persistent,
  resource-bounded Sancta recovery.

## Delivery

NixOS [PR #618](https://github.com/alexandru-savinov/nixos-config/pull/618) is stacked
on #612. Darwin [PR #29](https://github.com/alexandru-savinov/darwin-config/pull/29)
is stacked on #28; its CI and evaluated choir pin passed. The installed profiles
remain unchanged. The main-target Nix workflow does not run on the stacked NixOS
base, so native checks and the dedicated VM workflow supply the evidence here.

Native integration validation used `bf1f6b3`; exact guard-wrapper checks used
`2f79785`; neither helper sources nor guard registration changed in the later
scope-policy correction. The helper artifact is unchanged and matches Darwin's
pin. Both package CLI entry points were smoke-tested without launching agents.

Transition and rollback: [activation review](2026-09-26-sancta-activation.md).
Owner-script template: `scripts/sancta-reconnect-attach.sh`. Source-controlled
recovery instructions use the guarded path, not raw `claude --resume`.

## Deferred production gates

- Reverify single-writer state immediately before any approved activation. An earlier inventory is not continuing proof.
- Activate only after explicit owner approval; existing unwrapped processes cannot acquire a new cooperative lock retroactively.
- Validate guard loading in a fresh real agent after an approved transition. Fixture hook success does not prove the running agent loaded it.
- Human picker, notification-click and question-answer acceptance remain deferred.

No secret contents, transcript bodies or private conversation identifiers belong in this document or PRs.
