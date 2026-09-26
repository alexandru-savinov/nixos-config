# Sancta ownership rollout: approval package

Prepared on 2026-09-27 (Europe/Chisinau). **None of the activation commands below
has been executed.** This package prepares a coordinated migration, not an
unattended deployment. Do not activate the new aliases before their backend exists.

## Source and artifact identity

| Item | Exact identity |
| --- | --- |
| Ownership PR | NixOS #618, owner head `da57de91a188002cebfc9538d931e8e43385c1db` |
| Current parent | NixOS #612, `e7a70818b03d66be4c545e5422507680e0ae6a80` |
| Guard | #619 is merged; the live managed registration is already present |
| Alias proposal | NixOS #620 and Darwin #30; both remain undeployed |
| Mac ownership pin | Darwin #29, `f968aaa828126ade3efacdb3891385fef3dab0a0`, on #28 |
| Host build source | Isolated combined candidate `8856b74ac63f78e5d973c1bd71dd4c5fcddc3b4c` |
| Mac build source | Isolated owner-preserving candidate `dfbd4eb` |
| Host candidate | `/nix/store/fz034bfy8gz7nbgbxv8b5y24zhawyyyp-nixos-system-sancta-choir-25.11.20260318.fea3b36` |
| Mac candidate | `/nix/store/yfrb6w4h43jvvy27nszifca5ywzw8yk6-darwin-system-26.05.06648f4` |
| Host helper | `/nix/store/s1ha72iq6fkphqxalxk7pm92lr0gxhz8-agterm-zmx-host-0.1.0` |
| Mac client | `/nix/store/9akwihdjl4qxnw03gwrg31fi27xpyvcl-agterm-remote-608f4a4b` |
| Host baseline | `/nix/store/fmdz1y946jzmci6lplh89yb7k0ak6nb0-nixos-system-sancta-choir-25.11.20260318.fea3b36` |
| Mac baseline | `/nix/store/ch6788zax71zmncc64c51vvfz926ihy2-darwin-system-26.05.06648f4` |

The NixOS version suffix identifies the nixpkgs revision here, **not** the
configuration checkout. Use the complete store paths and recorded candidate
commits. The host candidate applies #618's net patch to the current #612 parent,
retaining #619. No PR was merged by this preparation.

The plain Mac PR-chain system built successfully but removed installed FortiClient
work. It is **not** the selected artifact. The selected candidate applies the
agterm changes to owner commit `ad1bd592f2a7fd9901bc9cfd3d38830822d20260`, preserving
FortiClient and the owner's Claude/Codex wrapper changes. Do not replace it with a
fresh main-only build without repeating the comparison.

Task-only checkouts and evidence:

- Mac: `/Users/alexandru/.local/share/vigil-owner/sancta-rollout-20260927` and
  `/Users/alexandru/.local/share/vigil-owner/darwin-owner-rollout-20260927`.
- Choir: `/tmp/sancta-rollout-20260927.IFKzfV/repo`.
- Private local evidence: `/tmp/sancta-rollout-20260927` (directory mode 0700).
- The private `private/restore-before.txt` and `private/restore-proposed.txt`
  contain sensitive session metadata. Never print, commit or attach them to PRs.
  The proposed command changes only the helper path and backend name.

Store artifacts are held by task build links. Recheck their presence before the
approved window; `/tmp` is not permanent retention. Preserve old and new artifacts
with explicit GC roots before activation. No garbage collection is part of this plan.

## Observed state and exact effects

At inspection, one live Sancta Claude process occupied the
`agt-mvp-sancta-main-20260924.scope` cgroup. Its private process metadata matched
the old backend record. This is a snapshot, not a continuing singleton guarantee.
The old records are never edited or deleted by this plan.

The live managed settings contain exactly one secret-guard registration. Their
bytes match the host candidate. The existing guard source hash is
`4844e499f22f319304ebcaa664b8add3ac7ee2d51dd920d425330f8ecf639b96`.
Do not repeat guard activation or change user settings. Wrapper fixtures passed
all 13 cases against the current registration and source, without executing a
commit. This does not prove live Claude hook loading.

The live scope has unlimited memory settings, OOMPolicy `stop`, and stop timeout
90 seconds. The candidate adds the prefix drop-in with MemoryHigh 4 GiB,
MemoryMax 5 GiB, MemorySwapMax 2 GiB, OOMPolicy `continue`, timeout 45 seconds.
The resource-policy VM test also exercises revealing the policy and reloading an
already running fixture scope, checking the same process survives. Its latest CI
result is a rollout prerequisite, not permission to reload the production manager.

Host unit comparison found no added/removed system services. The only changed
system/user service overrides are D-Bus restart-trigger paths; both use
`X-ReloadIfChanged=true`. A full switch may reload D-Bus and user managers. It also
changes the root Sancta launcher, system package path, alias file and user scope
policy. It does not retroactively give an existing Claude process a writer lock.

The selected Mac system preserves all unrelated installed packages and owner
wrappers. Home-file comparison adds managed `.local/bin/agt-zmx` and
`.config/agterm/remote-hosts.json`, and changes `.local/bin/sancta`. Their live
counterparts already exist as manually installed files. No `.before-nix` backup
collision was present at inspection; recheck before activation.

A **full Darwin activation is not just a file copy**: its existing script runs
Homebrew bundle, writes defaults, kills cfprefsd and Dock, and may reload launchd
jobs. The Brewfile itself is unchanged. Approval must cover these effects; no
agterm restart is required or included.

The owner soul-volume reconnect script still contains raw `claude --resume`,
`pgrep` and killing logic. Its hash at inspection was
`a4ececb96d5721e67c25d8d126bc53b3b1f6ca133fdd824cedfdb52f5b09d544`.
Replacing it with `scripts/sancta-reconnect-attach.sh` is a separate owner-file
approval. Verify its callers, including kill-only/timer callers, before replacement.

## Approval boundaries and preflight

Obtain explicit approval for: PR merge decisions; clean agent/backend exit and
Mac attachment interruption; host activation and manager reloads; full Darwin
activation; owner-file replacement; and live/human acceptance. None is implied
by this document or by successful builds. Coordinate one short migration window.

Read-only preflight immediately before that window:

```sh
# Mac: SSH destination comes from the installed choir profile, not ~/.ssh/config.
ssh -o BatchMode=yes -o ConnectTimeout=10 root@sancta-choir-1 \
  'readlink -f /run/current-system; readlink /nix/var/nix/profiles/system'
readlink /run/current-system

# Choir, through SSH: inventory only, no agent launch.
ssh root@sancta-choir-1 \
  'sudo -iu sancta /nix/store/s1ha72iq6fkphqxalxk7pm92lr0gxhz8-agterm-zmx-host-0.1.0/bin/sessions list'
```

Reinspect writer process metadata, matching conversation identity privately,
current cgroup, helper availability, live guard registration and the three Mac
home files. Check both PR chains and CI. Stop if baseline identities, owner-file
hashes or writer state changed. Do not repair drift by overwriting owner work.

Before interruption, back up the old backend record/route, `/etc/agt-zmx-aliases.json`,
the owner reconnect script, the three Mac files, and the current pane restoration
command into private mode-0700 directories. Preserve symlinks and ownership.
Do not put these backups in the repository. No transcript copy is needed.

## Approved migration order

1. With the owner present, cleanly exit the authoritative Claude process. If the
   old helper leaves a shell, exit that shell too. Verify both the writer and old
   backend are gone. Never use the legacy reconcile/kill script. Preserve records.
   Close or stop only the old Mac attachment after checking it has no new split
   or unrelated foreground work. Keep its private restoration backup.
2. Recover into the new backend with the built helper **before activating aliases**.
   The following is a future approved command, not an autonomous test. It reads
   only the saved UUID and process metadata, suppresses shell tracing, and refuses
   while the recorded conversation still has a live writer:

```sh
# Run on Mac inside agterm, after the approved clean exit. Never echo this variable.
set +x
SANCTA_RECOVERY_ID="$(ssh -o BatchMode=yes root@sancta-choir-1 \
  'runuser -u sancta -- env HOME=/var/lib/sancta /nix/store/44rn0p64x92bnnh7cwn6x6ybvflybmvz-python3-3.13.12/bin/python3 -' <<'PY'
import json, pathlib, sys
sys.path.insert(0, '/nix/store/s1ha72iq6fkphqxalxk7pm92lr0gxhz8-agterm-zmx-host-0.1.0/libexec/agterm-zmx')
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
  --remote-bin /nix/store/s1ha72iq6fkphqxalxk7pm92lr0gxhz8-agterm-zmx-host-0.1.0/bin/agt-zmx-host
unset SANCTA_RECOVERY_ID
```

3. Verify the new backend, one writer, shared ownership lock and correct private
   conversation identity. Do not proceed just because old text is visible. The
   new scope initially uses the old installed policy; do not start substantive
   work before the approved switch and resource verification below.
4. Activate the exact host artifact, after confirming the new backend exists and
   the observed baseline has not changed. These commands change production:

```sh
# On choir as root, only after approval and new-backend verification.
test "$(readlink -f /run/current-system)" = /nix/store/fmdz1y946jzmci6lplh89yb7k0ak6nb0-nixos-system-sancta-choir-25.11.20260318.fea3b36 || exit 1
nix-env --profile /nix/var/nix/profiles/system --set \
  /nix/store/fz034bfy8gz7nbgbxv8b5y24zhawyyyp-nixos-system-sancta-choir-25.11.20260318.fea3b36
/nix/store/fz034bfy8gz7nbgbxv8b5y24zhawyyyp-nixos-system-sancta-choir-25.11.20260318.fea3b36/bin/switch-to-configuration switch
systemctl --user --machine=sancta@.host show agt-mvp-sancta-main-owned-20260927.scope \
  -p ActiveState -p MemoryHigh -p MemoryMax -p MemorySwapMax -p OOMPolicy -p TimeoutStopUSec
```

Require `active`, `4294967296`, `5368709120`, `2147483648`, `continue`, `45s`.
If the existing scope does not acquire these values, stop acceptance and preserve
it; do not silently restart the agent or declare the resource gate passed.

5. Activate the selected owner-preserving Mac artifact, under its separate approval:

```sh
# On Mac; full activation has the effects listed above.
test "$(readlink /run/current-system)" = /nix/store/ch6788zax71zmncc64c51vvfz926ihy2-darwin-system-26.05.06648f4 || exit 1
sudo nix-env --profile /nix/var/nix/profiles/system --set \
  /nix/store/yfrb6w4h43jvvy27nszifca5ywzw8yk6-darwin-system-26.05.06648f4
sudo /nix/store/yfrb6w4h43jvvy27nszifca5ywzw8yk6-darwin-system-26.05.06648f4/activate
```

6. If separately approved, install the reviewed attachment-only owner-script
   template after verifying its saved hash and caller compatibility. Preserve
   ownership and mode. Never run the old script as a migration step.
7. Verify `sancta` focuses the new pane, a second call creates no duplicate, and
   `ssh -t root@sancta-choir-1 'sudo -iu sancta sessions attach sancta'` attaches
   the same backend. The new client pins its own restoration command; read it
   back privately and verify its backend/helper identity. Do not restore the old
   pane's command onto the new pane. No application restart is included.

## Rollback without a second writer

Before the old writer exits, rollback is attachment-only: preserve it and restore
its recorded client/route. After the new writer starts, **keep the new backend**
and repair attachment first. Do not launch the old conversation again.

An independent terminal can attach explicitly even if an alias/profile is wrong:

```sh
ssh -t root@sancta-choir-1 \
  'sudo -iu sancta /nix/store/s1ha72iq6fkphqxalxk7pm92lr0gxhz8-agterm-zmx-host-0.1.0/bin/sessions attach sancta-main-owned-20260927'
```

Full profile rollback needs separate approval and the same activation-impact
review. Verify old artifacts and private backups still exist, then use the same
profile/set-and-activate commands above with these exact old targets:

```sh
# Choir, root. Do not execute as an automatic response to an attachment failure.
nix-env --profile /nix/var/nix/profiles/system --set /nix/store/fmdz1y946jzmci6lplh89yb7k0ak6nb0-nixos-system-sancta-choir-25.11.20260318.fea3b36
/nix/store/fmdz1y946jzmci6lplh89yb7k0ak6nb0-nixos-system-sancta-choir-25.11.20260318.fea3b36/bin/switch-to-configuration switch
# Mac, separately approved.
sudo nix-env --profile /nix/var/nix/profiles/system --set /nix/store/ch6788zax71zmncc64c51vvfz926ihy2-darwin-system-26.05.06648f4
sudo /nix/store/ch6788zax71zmncc64c51vvfz926ihy2-darwin-system-26.05.06648f4/activate
```

A full rollback removes the new scope policy and may remove newly managed aliases
and home files; it does not necessarily restore their former manually installed
versions. Restore only the reviewed individual backups if appropriate. Old aliases
point at the ended backend after migration, so use explicit attachment to the new
backend until routing is repaired. Retain the absolute helper artifact. Do not
restore the old destructive owner launcher without a separate decision. If it was
replaced, its `/run/current-system/sw/bin/sessions` dependency also needs review
when rolling back to a generation without that package. Never unlink writer locks.

## Acceptance and remaining limits

- Repeated Mac/SSH attachment and disconnect/reconnect keep the same writer PID.
- A competing **supported** recovery refuses before starting another agent.
- Both aliases and the saved restoration command identify the new backend.
- Scope properties match all five expected values, with the writer surviving reload.
- Managed guard registration remains present and unchanged; a fresh real Claude
  session must separately demonstrate hook loading using a harmless disposable
  repository. Fixture success is not live acceptance.
- Human picker, notification-click and interactive-question tests remain pending
  until the owner can observe them. No synthetic assertion counts as that result.

Locks are cooperative. Direct binaries, in-session switching, changed config roots,
owner-deleted lock files and old running launchers can bypass them. Fake-child
inherited-FD tests do not prove real Claude descriptor retention after launcher
SIGKILL. The secret guard is a command-pattern tripwire, not a containment boundary.

Both original and new PRs remain unmerged by this work. The artifact package is
ready only when its relevant CI/review gates pass; production resolution requires
the separately approved transition and acceptance above.
