#!/usr/bin/env bash
# sancta-soc-page.sh — rebuild the private SOC page, gate it, promote it.
#
# Run by sancta-soc-page.service (modules/services/sancta-soc-page.nix); safe to
# run by hand as the index owner with the same two variables set.
#
#   SANCTA_SOC_INDEX    the INDEX repo root (gallery/soc.mjs, gallery/publish.mjs)
#   SANCTA_SOC_OUT_DIR  where the gated pages land; the unit sets it to
#                       $SANCTA_SOC_INDEX/gallery. A hand run may point it at a
#                       scratch directory to prove generate + gate without
#                       touching what the gallery serves.
#
# THE INVARIANT: the gallery serves a file only when <file>.passed exists AND its
# sha256 equals the bytes on disk (gallery/link-rule.mjs). So a page and its
# token must arrive TOGETHER or not at all, and a refused page must never
# replace a served one. Hence:
#
#   1. soc.mjs writes into a private WORK directory OUTSIDE the out dir (under
#      $TMPDIR, which the unit's PrivateTmp makes a per-run /tmp). Nothing
#      ungated is ever written under the gallery tree: the soul mirror archives
#      index/ recursively as the same user and a stage inside the gallery would
#      let unreviewed bytes reach the archive.
#      It writes two pages there: soc.html and soc-decide.html, which soc.html
#      links to.
#   2. publish.mjs gates each page in the work dir; its token names only the
#      basename and the sha256, so a token is valid after the copy.
#   3. Any non-zero exit (generator fails closed on a broken repo read, gate
#      FAIL (1) or gate CLOSED (2)) exits with that code before step 4: the
#      previous pages and tokens are untouched, the work dir is removed, the
#      unit goes red.
#   4. Only when BOTH pages passed: copy pages and tokens into a gate-passed
#      stage directory INSIDE the out dir, verify each copy's sha256 equals the
#      gated sha256 in its token, then rename page, then token, for each.
#      Why the final stage is inside the out dir:
#        - rename(2) must stay on ONE MOUNT, not merely one filesystem. The
#          unit's ReadWritePaths bind-mounts gallery/ on its own; a stage in
#          index/ would sit on a different (read-only) mount point, and
#          rename(2) across mount points fails EXDEV (rename(2), ERRORS), as
#          would one from the private /tmp.
#        - It holds only bytes that already passed the gate. It is also never
#          servable: gallery/link-rule.mjs cleanPath() refuses any dot-led
#          path segment with 404 before the .passed rule is consulted (probed
#          live on choir 2026-11-10). The soul mirror additionally excludes
#          index/gallery/.soc-stage.* so an orphan is never archived.
#
# Between the two renames of one page, bytes and token disagree for a moment;
# the gallery then answers 404 for that page — dark, never unpassed bytes. A
# crash in that window leaves it dark until the next run. The post-check below
# re-hashes what was promoted, so a concurrent writer that interleaved with us
# makes this run fail instead of reporting a green it did not produce.
set -euo pipefail
umask 022

index="${SANCTA_SOC_INDEX:?SANCTA_SOC_INDEX is unset}"
out_dir="${SANCTA_SOC_OUT_DIR:?SANCTA_SOC_OUT_DIR is unset}"
pages=(soc.html soc-decide.html)

[ -d "$out_dir" ] || {
  echo "soc-page: out dir $out_dir does not exist" >&2
  exit 2
}

# One promoter at a time, timer and hand runs alike: the lock is taken HERE,
# not in the unit, so a by-hand run serialises with the timer too.
exec 9<"$out_dir"
flock -w 300 9 || {
  echo "soc-page: another run holds the lock on $out_dir" >&2
  exit 2
}

# A run killed with SIGKILL skips the EXIT trap and leaves its stage behind.
# Holding the lock, no other run can own one, so any stage present is orphaned.
# It is not servable (dot-led segment, see step 1 above), but it must not
# accumulate in the served tree either.
rm -rf -- "$out_dir"/.soc-stage.*

work="$(mktemp -d "${TMPDIR:-/tmp}/soc-work.XXXXXX")"
stage=""
trap 'rm -rf -- "$work" ${stage:+"$stage"}' EXIT

cd "$index"
node gallery/soc.mjs --out "$work/soc.html"

for p in "${pages[@]}"; do
  [ -s "$work/$p" ] || {
    echo "soc-page: generator produced no $p; nothing promoted" >&2
    exit 2
  }
done

for p in "${pages[@]}"; do
  rc=0
  node gallery/publish.mjs "$work/$p" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "soc-page: gate refused $p (exit $rc); previous published pages left untouched" >&2
    exit "$rc"
  fi
  [ -s "$work/$p.passed" ] || {
    echo "soc-page: gate exited 0 but wrote no $p.passed; nothing promoted" >&2
    exit 2
  }
done

# Both pages passed: only now do bytes enter the gallery tree.
stage="$(mktemp -d "$out_dir/.soc-stage.XXXXXX")"
for p in "${pages[@]}"; do
  gated="$(jq -r .sha256 "$work/$p.passed")"
  cp -- "$work/$p" "$stage/$p"
  cp -- "$work/$p.passed" "$stage/$p.passed"
  have="$(sha256sum "$stage/$p" | cut -d' ' -f1)"
  [ "$gated" = "$have" ] || {
    echo "soc-page: copied $p does not match the gated sha256; nothing promoted" >&2
    exit 1
  }
done

for p in "${pages[@]}"; do
  mv -f -- "$stage/$p" "$out_dir/$p"
  mv -f -- "$stage/$p.passed" "$out_dir/$p.passed"
done

for p in "${pages[@]}"; do
  want="$(jq -r .sha256 "$out_dir/$p.passed")"
  have="$(sha256sum "$out_dir/$p" | cut -d' ' -f1)"
  [ "$want" = "$have" ] || {
    echo "soc-page: promoted $p does not match its token; another writer interleaved" >&2
    exit 1
  }
done

echo "soc-page: promoted ${pages[*]} to $out_dir"
