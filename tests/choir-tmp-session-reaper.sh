#!/usr/bin/env bash
# Harness for modules/services/choir-tmp-session-reaper.sh against a fake /tmp,
# fake /proc and fake homes. Usage: choir-tmp-session-reaper.sh <reaper.sh>
set -euo pipefail
REAPER=$1
[ "$(id -u)" != 0 ] || { echo "run as non-root (uid 0 is refused by the reaper)"; exit 1; }
uid=$(id -u)
W=$(cd "$(mktemp -d)" && pwd -P); trap 'chmod -R u+rw "$W" 2>/dev/null; find "$W" -delete 2>/dev/null' EXIT
fails=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fails=$((fails + 1)); }
old='10 days ago'

mk() { # name: tree with an old file, owned by us
  mkdir -p "$W/tmp/claude-$uid/proj/$1"; echo x > "$W/tmp/claude-$uid/proj/$1/f"
  touch -d "$old" "$W/tmp/claude-$uid/proj/$1/f" "$W/tmp/claude-$uid/proj/$1"
}
for s in live resumable stale fresh; do mk $s; done
mkdir -p "$W/home/$uid/.claude/projects/proj"
# fake process: proc <pid> <cmdline-with-@-as-NUL> <environ> <cwd>
proc() {
  mkdir -p "$W/proc/$1/fd"; printf '%s' "$2" | tr '@' '\0' > "$W/proc/$1/cmdline"
  printf '%s' "$3" > "$W/proc/$1/environ"; ln -sfn "$4" "$W/proc/$1/cwd"
}
proc 1 "init" "PATH=/bin" /                              # bystander: matches nothing
# live: a process cwd under the tree
proc 4242 "claude@--model@x" "PATH=/bin" "$W/tmp/claude-$uid/proj/live"
# session id in a cmdline keeps a tree alive: bare, --resume <id>, -r <id>
for v in cmdlive resumelive rlive; do mk $v; done
proc 5 "claude@--session-id@cmdlive" "A=b" /
proc 6 "claude@--resume@resumelive" "A=b" /
proc 7 "claude@-r@rlive" "A=b" /
# open fd under the tree
mk fdlive; ln -s "$W/tmp/claude-$uid/proj/fdlive/f" "$W/proc/1/fd/3"
# environ mentions the dir (e.g. TMPDIR / scratchpad path of a resumed zmx session)
mk envlive; proc 8 "zmx@attach" "SCRATCH=$W/tmp/claude-$uid/proj/envlive/scratchpad" /
# environ unreadable => assume live
# excluded by prefix even though stale and not live
mk 666bcb25-aaaa-bbbb
# resumable: fresh transcript; stale: old transcript; fresh: new file in tree
touch "$W/home/$uid/.claude/projects/proj/resumable.jsonl"
touch -d "$old" "$W/home/$uid/.claude/projects/proj/stale.jsonl"
touch "$W/tmp/claude-$uid/proj/fresh/new"
# symlinks pointing out of the tree, and a symlinked session dir
mkdir -p "$W/outside"; echo precious > "$W/outside/keep"
ln -s "$W/outside" "$W/tmp/claude-$uid/proj/stale/escape"
touch -h -d "$old" "$W/tmp/claude-$uid/proj/stale/escape"; touch -d "$old" "$W/tmp/claude-$uid/proj/stale"
ln -s "$W/outside" "$W/tmp/claude-$uid/proj/linksess"

run() { # extra env... ; prints reaper output
  env EXCLUDE_SESSIONS="666bcb25" TMP_ROOT="$W/tmp" PROC_ROOT="$W/proc" HOMES_ROOT="$W/home" IDLE_DAYS=7 "$@" bash "$REAPER" 2>&1
}
T="$W/tmp/claude-$uid/proj"

out=$(run DRY_RUN=1)
echo "$out" | sed 's/^/    /'
grep -q "DRY-RUN would remove $T/stale " <<<"$out" && ok "stale+idle is logged for removal" || bad "stale not logged"
[ -d "$T/stale" ] && ok "dry-run deletes nothing" || bad "dry-run deleted stale"
grep -q "keep $T/live: live" <<<"$out" && ok "live (cwd) kept" || bad "live not kept"
for v in cmdlive resumelive rlive fdlive envlive; do
  grep -q "keep $T/$v: live" <<<"$out" && ok "$v kept as live" || bad "$v not kept"
done
grep -q "keep $T/666bcb25-aaaa-bbbb: excluded" <<<"$out" && ok "excluded session kept" || bad "excluded not kept"
grep -q "would remove $T/666bcb25" <<<"$out" && bad "excluded session was a candidate" || ok "excluded session never a candidate"
grep -q "keep $T/resumable: transcript fresh" <<<"$out" && ok "resumable kept" || bad "resumable not kept"
grep -q "keep $T/fresh: tree modified" <<<"$out" && ok "recently modified tree kept" || bad "fresh not kept"
grep -q "would remove $T/linksess" <<<"$out" && bad "symlinked session dir considered" || ok "symlinked session dir ignored"

out=$(run DRY_RUN=0 RUN_AS=env)
[ ! -e "$T/stale" ] && ok "real run removes stale tree" || bad "stale survived real run"
[ -f "$W/outside/keep" ] && ok "symlink out of tree not followed" || bad "outside file deleted"
[ -L "$T/linksess" ] && ok "symlinked session dir intact" || bad "linksess removed"
for s in live resumable fresh cmdlive resumelive rlive fdlive envlive 666bcb25-aaaa-bbbb; do [ -d "$T/$s" ] || bad "$s removed in real run"; done

# unreadable environ of a same-uid process => nothing of that uid is reaped
mk blindcand
mkdir -p "$W/proc2/1/fd" "$W/proc2/9/fd"; for n in 1 9; do : > "$W/proc2/$n/cmdline"; : > "$W/proc2/$n/environ"; ln -sfn / "$W/proc2/$n/cwd"; done
chmod 000 "$W/proc2/9/environ"
out=$(run DRY_RUN=1 PROC_ROOT="$W/proc2")
grep -q "keep $T/blindcand: live" <<<"$out" && ! grep -q "would remove" <<<"$out" && ok "unreadable environ => assume live" || bad "unreadable environ did not protect"
chmod 600 "$W/proc2/9/environ"

# unreadable transcript root => keep, never guess
mk blind; out=$(run DRY_RUN=1 HOMES_ROOT="$W/nohome")
grep -q "keep $T/blind: cannot see" <<<"$out" && ok "no transcript root => kept" || bad "blind not kept"

# size alert (threshold 0 GiB via tiny file is not >0; use ALERT_GIB with du faked)
mkdir -p "$W/fakebin"; printf '#!/bin/sh\necho "20971520\t$3"\n' > "$W/fakebin/du"; chmod +x "$W/fakebin/du"
out=$(PATH="$W/fakebin:$PATH" run DRY_RUN=1 ALERT_GIB=10)
grep -q "^<4>choir-tmp-session-reaper: WARN .* 20 GiB" <<<"$out" && ok "size alert emitted at WARN priority" || bad "no size alert"

# large stale tree (thousands of entries): the run must not abort (the old
# `sort | head -1` under pipefail died with EPIPE/SIGPIPE here)
mk big; mkdir -p "$T/big/d"; for i in $(seq 1 6000); do : > "$T/big/d/f$i"; done
find "$T/big" -exec touch -h -d "$old" {} +
touch -d "$old" "$W/home/$uid/.claude/projects/proj/big.jsonl"
rcb=0; out=$(run DRY_RUN=1) || rcb=$?
grep -q "DRY-RUN would remove $T/big " <<<"$out" && ok "large stale tree is processed (no pipefail abort)" || bad "large tree not processed (rc=$rcb)"

# kernel-thread-like process (empty cmdline, no cwd) does not make everything live
mkdir -p "$W/proc3/2/fd"; : > "$W/proc3/2/cmdline"; : > "$W/proc3/2/environ"   # no cwd link
mkdir -p "$W/proc3/1/fd"; printf init > "$W/proc3/1/cmdline"; printf 'PATH=/bin' > "$W/proc3/1/environ"; ln -sfn / "$W/proc3/1/cwd"
out=$(run DRY_RUN=1 PROC_ROOT="$W/proc3")
grep -q "DRY-RUN would remove $T/big " <<<"$out" && ok "kernel thread (no cwd, empty cmdline) is ignored" || bad "kernel thread made sessions live"

# unknown uid directory: must not abort the run, and must not be reaped
mkdir -p "$W/tmp/claude-99999/proj/ghost"; touch -d "$old" "$W/tmp/claude-99999/proj/ghost"
rcu=0; out=$(env -u HOMES_ROOT EXCLUDE_SESSIONS="666bcb25" TMP_ROOT="$W/tmp" PROC_ROOT="$W/proc" IDLE_DAYS=7 DRY_RUN=1 bash "$REAPER" 2>&1) || rcu=$?
grep -q "would remove $W/tmp/claude-99999" <<<"$out" && bad "unknown uid tree was a candidate" || ok "unknown uid tree kept"
[ "$rcu" = 0 ] && ok "unknown uid does not abort the run" || bad "run aborted on unknown uid (rc=$rcu)"

# a failing delete warns, continues with the next session, and fails the unit at the end
mk zfail; touch -d "$old" "$W/home/$uid/.claude/projects/proj/zfail.jsonl"; touch -d "$old" "$T/zfail"
printf '#!/bin/sh\ncase "$2" in *zfail*) exit 1;; esac\nexec "$@"\n' > "$W/fakebin/failrun"; chmod +x "$W/fakebin/failrun"
rcf=0; out=$(run DRY_RUN=0 RUN_AS="$W/fakebin/failrun") || rcf=$?
grep -q "WARN could not fully remove $T/zfail" <<<"$out" && ok "failed delete is reported" || bad "failed delete not reported"
[ ! -e "$T/big" ] && ok "later session still processed after a failed delete" || bad "run stopped at the failed delete"
[ "$rcf" != 0 ] && ok "unit exits non-zero after a failed delete" || bad "failed delete left exit 0"

[ "$fails" = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
