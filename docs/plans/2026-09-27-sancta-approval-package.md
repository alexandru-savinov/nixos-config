# Sancta ownership: remaining migration and approval package

Prepared 2026-09-27. This supersedes the earlier artifact and rollback commands
in this file. It authorizes no production action. The autonomous readiness work
has not activated profiles, interrupted the conversation, restarted agterm,
replaced the owner launcher, or created/re-keyed secrets.

## Verified starting point

Read-only inspection at approximately 17:10 UTC found:

- Choir generation 47, built from main `6248f534d4a29061fd01b178bb7fd3c35134d210`;
  its exact running store identity is the host baseline below.
- One live Claude writer matched the current backend's private conversation
  metadata. Neither the writer nor its launcher ancestors held that conversation's
  `agt-writer-locks` descriptor; the lock file did not exist. Installing a new
  helper did not retrofit ownership into the old backend.
- `sancta-main-20260924` is alive; `sancta-main-owned-20260927` does not exist.
  Host/Mac aliases and the Mac pane restoration command still select the old
  backend. The profile and restoration command already pin the current helper.
- Sancta lingering is enabled. The live scope has MemoryHigh 4 GiB, MemoryMax
  5 GiB, MemorySwapMax 2 GiB, OOMPolicy `continue`, and TimeoutStopSec 45 s.
- Managed settings contain exactly one secret-guard registration. The existing
  owner reconnect script already matches the attach-only template. Neither needs
  replacement or repeated activation.
- Owner checkouts contain existing edits. These remain untouched. The selected
  Mac artifact preserves the owner's installed packages and wrappers, including
  FortiClient, and the deployed no-update/no-upgrade Homebrew behavior.

These observations are snapshots. Recheck them before any approved transition.
The remaining production change is a clean recovery through the locking helper,
followed by coordinated alias activation and acceptance. Do not repeat completed
helper, guard, resource-policy, or owner-script rollout steps.

## Exact artifacts

| Item | Immutable identity |
| --- | --- |
| Host baseline | `/nix/store/dbh80v4j9cdq1likhdnhgv08hbdhg4h5-nixos-system-sancta-choir-25.11.20260318.fea3b36` |
| Host candidate | `/nix/store/9ihnxc6bcs3pkpcxmb5hf9sss3swj8wh-nixos-system-sancta-choir-25.11.20260318.fea3b36` |
| Host candidate source | `5a3c36307b94dfa7a489ec47d39cd001c042ddcc` |
| Mac baseline | `/nix/store/3cwf50qj4dn0kyy08lhnp391zagl2j33-darwin-system-26.05.06648f4` |
| Mac candidate | `/nix/store/imhdl5kfk18zrs9r713fidzr76v609jr-darwin-system-26.05.06648f4` |
| Mac candidate source | `b2f58594db4f7fe41f1476126fbf8b09d23ee76e` |
| Current/new helper | `/nix/store/fqf7pygmfl9rrjhn2s1b1wng54n0j0pa-agterm-zmx-host-0.1.0` |
| Current/new Mac client | `/nix/store/9akwihdjl4qxnw03gwrg31fi27xpyvcl-agterm-remote-608f4a4b` |

Host source is current main plus the reviewed scope fixture/docs and the explicit
alias patch. Mac source snapshots owner base `ad1bd592f2a7fd9901bc9cfd3d38830822d20260`
plus the five existing agterm file changes, changes only the Sancta backend alias,
and explicitly preserves the deployed Homebrew activation flags. A plain current
main build is not a substitute for this owner-preserving artifact.

Build-only worktrees under `/Users/alexandru/.local/share/vigil-owner/`:
`sancta-migration-artifacts`, `sancta-mac-current`. Source bundles are
`/tmp/sancta-readiness-20260927/{host,mac}.bundle` on the Mac. The remote source
and host build link are under `/tmp/sancta-readiness-20260927.auCeYq/`; the Mac
candidate link is `/tmp/sancta-readiness-20260927/mac-candidate`.
These links retain candidates while present; `/tmp` is not permanent retention.
Before the approved window, retain both baselines, candidates and helper with
explicit GC roots and confirm their availability. No GC is part of this plan.

Normal repository aliases remain unchanged. The proposed mapping lives in
`2026-09-27-sancta-owned-alias.patch` in each repository and is applied only to
the isolated artifact sources. Merge/review of this preparation does not select
the proposed backend. Apply/commit the patch to normal configuration only after
approved recovery verifies that backend alive; otherwise a later rebuild could
revert routing. Keep the host and Mac source changes coordinated.

## Activation effects and validated limits

Host comparison found one changed configuration file:
`/etc/agt-zmx-aliases.json`. System/user unit trees, system packages, helper and
managed guard settings have identical targets. Generated activation differences
normalize to system/etc/source store identities; all referenced ciphertext bytes
are identical. A full switch still runs normal NixOS activation, including agenix
re-materialization and boot/profile bookkeeping. No service-unit change requires
an agent restart; this is not permission to skip inspecting switch output.

Mac home-file comparison has no additions or removals and changes only
`.config/agterm/remote-hosts.json`; its JSON differs only in the Sancta backend.
Other packages, launchers and the Home Manager activation actions are preserved.
A full Darwin activation still runs the existing Homebrew bundle (auto-update
and upgrade disabled), defaults, Dock/cfprefsd actions, and launchd/Home Manager
activation. It is not merely copying the alias file. No agterm restart is planned.
The profiles affected are `/nix/var/nix/profiles/system` on each machine and the
Mac Home Manager generation. No owner script/settings replacement is needed.

Local regression: 61 tests, 60 passed, one optional native-zmx test skipped.
The expanded scope/ownership CI at `cb728e008073a4f4e236f7428e1c564ae88aa17e`
passed [run 36335596174](https://github.com/alexandru-savinov/nixos-config/actions/runs/36335596174).
It builds the protocol suite, native-zmx integration, helper, module assertions
and the VM scope fixture. The fixture checks fresh scope policy, all five
properties after reload, actual cgroup memory limits, and membership/survival of
the same PID. Its prior failure was `systemd-run` expanding `$$` into literal `$`;
`--expand-environment=no` fixes the measured cause without removing assertions.

The 13 disposable secret-guard wrapper cases passed against current managed
settings and the actual guard source: success/block/error mappings, absent,
non-executable and hung guards, unrelated user exclusion, user-settings rewrite,
harmless input and blocked unscanned-commit input. No commit command ran. These
prove wrapper behavior, not that a real Claude session loads the hook.

## Approval and preflight

Separate approval must cover the clean agent/backend exit and Mac attachment
interruption, host activation, full Mac activation effects, and live/human
acceptance. Successful builds or PR merges authorize none of these actions.

Before requesting the transition, record a fresh read-only snapshot of:

1. Both running system paths and system profile targets, compared with the exact
   baselines above. Stop on drift; rebuild/review rather than overwriting it.
2. Exactly one writer matched privately to the old backend record, its ancestor
   chain, cwd `/home/nixos`, user `sancta`, helper and scope properties.
3. Old backend alive, proposed backend absent with no existing record; both aliases
   and saved Mac restoration command agree. Inventory alone does not prove ownership.
4. Managed guard registration/source and attach-only owner launcher unchanged;
   current owner edits remain preserved. Confirm no unrelated pane/split work
   would be lost when ending only the old attachment.
5. Exact final PR CI/review results and artifact availability. Before interruption,
   make private mode-0700 backups of the old backend record, both alias profiles,
   affected Mac symlinks and pane restoration metadata; never print their contents.
   Preserve ownership/symlinks. No transcript backup or key operation is needed.

For host identity (read-only):

```sh
ssh -o BatchMode=yes -o ConnectTimeout=10 root@sancta-choir-1 \
  'readlink -f /run/current-system; readlink -f /nix/var/nix/profiles/system'
readlink /run/current-system
readlink /nix/var/nix/profiles/system
```

## Future approved transition

First, with the owner present, cleanly exit the authoritative Claude and then
its old backend shell, if one remains. Verify the matched writer and old backend
are gone; preserve records. End only the reviewed Mac attachment. Do not use
process sweeps, raw `claude --resume`, transcript edits or lock deletion.

After that explicit interruption approval and stopped-state verification, run on
the Mac inside agterm. Do not enable shell tracing or print the private variable:

```sh
set +x
SANCTA_RECOVERY_ID="$(ssh -o BatchMode=yes root@sancta-choir-1 \
  'runuser -u sancta -- env HOME=/var/lib/sancta /nix/store/44rn0p64x92bnnh7cwn6x6ybvflybmvz-python3-3.13.12/bin/python3 -' <<'PY'
import json, pathlib, sys
sys.path.insert(0, '/nix/store/fqf7pygmfl9rrjhn2s1b1wng54n0j0pa-agterm-zmx-host-0.1.0/libexec/agterm-zmx')
import host
record = json.loads(pathlib.Path('/var/lib/sancta/.local/state/agt-zmx/agt-mvp-sancta-main-20260924.json').read_text())
assert record['agent'] == 'claude' and record['cwd'] == '/home/nixos'
identifier = record['resume']
host.validate_resume('claude', identifier)
print(identifier)
PY
)" && test -n "$SANCTA_RECOVERY_ID" && \
/nix/store/9akwihdjl4qxnw03gwrg31fi27xpyvcl-agterm-remote-608f4a4b/bin/agt-zmx \
  --profile choir --open --name sancta-main-owned-20260927 --title sancta \
  --agent claude --cwd /home/nixos --resume "$SANCTA_RECOVERY_ID" --user-scope \
  --remote-bin /nix/store/fqf7pygmfl9rrjhn2s1b1wng54n0j0pa-agterm-zmx-host-0.1.0/bin/agt-zmx-host
unset SANCTA_RECOVERY_ID
```

Verify one new writer, private identity match, an actually held shared writer
lock, the new backend, and all five scope values before changing aliases. The
policy is already installed and must apply when the new scope is created. Do
not infer ownership from the mere existence of a lock file or visible old text.
If creation fails, preserve the stopped record and diagnose; never launch the
old unguarded writer as an automatic fallback.

After separate host activation approval, on choir as root:

```sh
set -eu
HOST_BASE=/nix/store/dbh80v4j9cdq1likhdnhgv08hbdhg4h5-nixos-system-sancta-choir-25.11.20260318.fea3b36
HOST_NEW=/nix/store/9ihnxc6bcs3pkpcxmb5hf9sss3swj8wh-nixos-system-sancta-choir-25.11.20260318.fea3b36
test "$(readlink -f /run/current-system)" = "$HOST_BASE"
test "$(readlink -f /nix/var/nix/profiles/system)" = "$HOST_BASE"
# Refuse alias activation if the proposed backend is absent. The preceding
# private writer/lock verification remains mandatory; inventory is not that proof.
sudo -u sancta env HOME=/var/lib/sancta XDG_RUNTIME_DIR=/run/user/993 \
  /nix/store/fqf7pygmfl9rrjhn2s1b1wng54n0j0pa-agterm-zmx-host-0.1.0/bin/agt-zmx-host list | \
  /nix/store/44rn0p64x92bnnh7cwn6x6ybvflybmvz-python3-3.13.12/bin/python3 -c \
  'import json,sys; assert any(r["name"] == "sancta-main-owned-20260927" and r["alive"] for r in json.load(sys.stdin))'
nix-env --profile /nix/var/nix/profiles/system --set "$HOST_NEW"
"$HOST_NEW/bin/switch-to-configuration" switch
sudo -u sancta env XDG_RUNTIME_DIR=/run/user/993 systemctl --user show \
  agt-mvp-sancta-main-owned-20260927.scope \
  -p ActiveState -p MemoryHigh -p MemoryMax -p MemorySwapMax -p OOMPolicy -p TimeoutStopUSec
```

Require `active`, `4294967296`, `5368709120`, `2147483648`, `continue`, `45s`.
Verify the same writer survived. If activation fails, stop and inspect both the
profile pointer and active system; a partially completed switch is not atomic.

After separate full Mac activation approval:

```sh
set -eu
MAC_BASE=/nix/store/3cwf50qj4dn0kyy08lhnp391zagl2j33-darwin-system-26.05.06648f4
MAC_NEW=/nix/store/imhdl5kfk18zrs9r713fidzr76v609jr-darwin-system-26.05.06648f4
test "$(readlink /run/current-system)" = "$MAC_BASE"
test "$(realpath /nix/var/nix/profiles/system)" = "$MAC_BASE"
sudo nix-env --profile /nix/var/nix/profiles/system --set "$MAC_NEW"
sudo "$MAC_NEW/activate"
```

Verify both aliases select the new backend. The new client records its own
restore command; read it back privately and verify backend/helper identity.
Do not copy the old pane's restore command onto the new pane. Apply and commit
the reviewed alias patches in isolated repository checkouts so future rebuilds
retain the approved routing; preserve unrelated owner edits.

## Rollback and recovery boundaries

Before clean exit, rollback means keeping the existing writer and attachments.
After new recovery, prefer repairing attachment to the surviving new backend:

```sh
ssh -t root@sancta-choir-1 \
  'sudo -iu sancta /nix/store/fqf7pygmfl9rrjhn2s1b1wng54n0j0pa-agterm-zmx-host-0.1.0/bin/sessions attach sancta-main-owned-20260927'
```

A full profile rollback requires separate approval. These commands deliberately
refuse any state other than the exact successfully activated candidate. If
activation partially failed or either identity differs, stop for an updated
impact review; do not remove the guards or run an older historical rollback.

```sh
# Choir as root, separately approved.
set -eu
HOST_BASE=/nix/store/dbh80v4j9cdq1likhdnhgv08hbdhg4h5-nixos-system-sancta-choir-25.11.20260318.fea3b36
HOST_NEW=/nix/store/9ihnxc6bcs3pkpcxmb5hf9sss3swj8wh-nixos-system-sancta-choir-25.11.20260318.fea3b36
test "$(readlink -f /run/current-system)" = "$HOST_NEW"
test "$(readlink -f /nix/var/nix/profiles/system)" = "$HOST_NEW"
test -x "$HOST_BASE/bin/switch-to-configuration"
nix-env --profile /nix/var/nix/profiles/system --set "$HOST_BASE"
"$HOST_BASE/bin/switch-to-configuration" switch
```

```sh
# Mac, separately approved.
set -eu
MAC_BASE=/nix/store/3cwf50qj4dn0kyy08lhnp391zagl2j33-darwin-system-26.05.06648f4
MAC_NEW=/nix/store/imhdl5kfk18zrs9r713fidzr76v609jr-darwin-system-26.05.06648f4
test "$(readlink /run/current-system)" = "$MAC_NEW"
test "$(realpath /nix/var/nix/profiles/system)" = "$MAC_NEW"
test -x "$MAC_BASE/activate"
sudo nix-env --profile /nix/var/nix/profiles/system --set "$MAC_BASE"
sudo "$MAC_BASE/activate"
```

These current baselines retain the helper, guard, limits and attach-only launchers,
but restore aliases pointing to the ended old backend. Keep explicitly attaching
the surviving new backend until routing is repaired. Never replace its live lock
inode, restart an old writer, or restore the destructive legacy launcher. Any
subsequent conversation recovery needs another clean-exit approval.

## Acceptance checklist for the later approved window

- [ ] One privately matched writer, one running new backend and a held shared lock.
- [ ] Supported competing recovery refuses before launching another agent.
- [ ] Repeated Mac `sancta` and separate SSH attachments reach the same writer;
      disconnect/reconnect preserves its PID and creates no duplicate pane.
- [ ] Host/Mac aliases, declarative patches and new pane restoration agree.
- [ ] All five scope values and actual cgroup limits match; writer survived activation.
- [ ] Managed guard registration remains unchanged; a fresh disposable real Claude
      session demonstrates hook loading without a secret or actual commit.
- [ ] Owner observes picker focus, notification click and interactive questions.
      Synthetic routing tests do not count as human acceptance.

Locks are cooperative: direct binaries, in-session conversation switching, changed
configuration roots, deleted lock files and old launchers can bypass them. Fake
agent crash tests do not prove real Claude retains an inherited descriptor after
its launcher dies. Do not kill the production launcher to test that. The guard
is a command-pattern tripwire, not account containment. Production and human
acceptance remain pending even after every preparation check is green.
