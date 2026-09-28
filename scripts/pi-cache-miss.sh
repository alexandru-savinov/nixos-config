#!/usr/bin/env bash
#
# pi-cache-miss.sh — would this flake.lock make the Raspberry Pi build its
# kernel or firmware from source?
#
# Why this exists (NixCon 2026 "corporate trenches" note, #182):
#   `nixos-raspberrypi` deliberately does NOT follow our nixpkgs, so that its
#   kernel/firmware derivations hash-match what the vendor binary cache
#   (nixos-raspberrypi.cachix.org) already holds. That only holds while the
#   vendor cache still HAS those paths. A lock bump to an uncached rev, or an
#   eviction on the vendor side, turns `nixos-rebuild` on the 4 GB Pi into a
#   multi-hour kernel build. This script catches that in the flake-update PR,
#   not on the device.
#
# What it does (evaluation only, nothing is built or downloaded):
#   1. `nix build --dry-run` on each host's system.build.toplevel and parses
#      the "will be built" list from stderr.
#   2. Reads the host's OWN nix.settings.substituters / trusted-public-keys
#      (single source of truth: hosts/rpi5*/configuration.nix) and passes them
#      as --option extra-substituters. A trusted user (CI runner) gets an exact
#      answer from Nix itself.
#   3. Selects the kernel / firmware / dtb candidates from that list and
#      probes only their outputs directly on those substituters over HTTP
#      (<hash>.narinfo). This keeps the answer right when the local nix-daemon
#      ignores the extra substituters (untrusted user), and says so. Only a
#      404 from every vendor substituter counts as a miss; any other answer
#      (timeout, 5xx) marks the check incomplete, never a miss.
#   4. Flags the candidates that are confirmed misses.
#   5. Name-drift guard: the toplevel's derivation closure (nix-store -qR on
#      the nixos-system-*.drv; independent of what the local store holds)
#      must contain a kernel and a raspberrypi-firmware derivation matching
#      the sentinels, else the result is "incomplete", never ✓.
#
# Usage:
#   scripts/pi-cache-miss.sh [--flake REF] [--markdown FILE] [--github-output FILE]
#                            [HOST...]            (default HOST: rpi5 rpi5-full)
# Env:
#   PI_CACHE_NIX_WRAP  optional command prefix for every nix call
#                      (e.g. "flock /tmp/nix-eval.lock").
# Exit:
#   0 = check ran (flagged or not — this is a FLAG, not a gate)
#   2 = usage error / check could not run (eval failed, parse failed)
set -euo pipefail

FLAKE="."
MD_OUT=""
GH_OUT=""
HOSTS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --flake) FLAKE="$2"; shift 2 ;;
    --markdown) MD_OUT="$2"; shift 2 ;;
    --github-output) GH_OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) HOSTS+=("$1"); shift ;;
  esac
done
[ ${#HOSTS[@]} -eq 0 ] && HOSTS=(rpi5 rpi5-full)

# shellcheck disable=SC2206
WRAP=(${PI_CACHE_NIX_WRAP:-})
nixw() { "${WRAP[@]}" nix "$@"; }

WORK="$(mktemp -d)"
# If anything aborts the script unexpectedly (set -e), still tell the workflow
# the check is incomplete: failed=true keeps any existing pi-cache-miss label.
outputs_written=false
# shellcheck disable=SC2329  # invoked via trap
on_exit() {
  rc=$?
  if ! $outputs_written && [ -n "$GH_OUT" ]; then
    echo "::warning::pi-cache-miss: aborted unexpectedly (exit $rc)" >&2
    { echo "miss=false"; echo "failed=true"; } >>"$GH_OUT"
  fi
  rm -rf "$WORK"
}
trap on_exit EXIT

# Heavy Pi derivations, matched on the real names nixos-raspberrypi produces
# (observed 2026-09-28): linux_rpi-bcm2712-<ver>, linux-config-<ver>,
# raspberrypi-firmware-<ver>, raspberrypi-wireless-firmware-<ver>,
# firmware-nonfree, bluez-firmware, linux-firmware-<ver>, *dtbs*, device-tree-overlays.
FLAG_RE='^(linux[_-]rpi[^ ]*|linux-config-[0-9][^ ]*|raspberrypi(-wireless)?-firmware[^ ]*|linux-firmware[^ ]*|firmware-nonfree[^ ]*|bluez-firmware[^ ]*|[^ ]*dtbs[^ ]*|device-tree-overlays[^ ]*)$'
# Cheap local assembly steps (aggregateModules "<kernel>-modules", modules-shrunk,
# initrd, compressed copies, scripts) that are always built on the host and are never
# in any cache — matching the patterns above but not worth a flag.
SKIP_RE='(-modules|-modules-shrunk|-zstd|\.sh|\.conf)$|^initrd-'

# Name-drift sentinels. Every Pi system closure contains a kernel and the boot
# firmware. If the toplevel's derivation closure has no derivation matching
# these, upstream renamed them and FLAG_RE can no longer see a miss: the
# result is "incomplete", never a clean ✓.
KERNEL_SENTINEL_RE='^linux[_-]rpi[^ ]*-[0-9][^ ]*$'
FIRMWARE_SENTINEL_RE='^raspberrypi-firmware-[0-9][^ ]*$'

drv_name() { basename "$1" .drv | cut -d- -f2-; }
nixstorew() { "${WRAP[@]}" nix-store "$@"; }

any_flagged=false
check_failed=false
md_body=""
summary_lines=""

for host in "${HOSTS[@]}"; do
  attr="${FLAKE}#nixosConfigurations.${host}.config.system.build.toplevel"
  settings_json="$WORK/$host.settings.json"
  if ! nixw eval --json "${FLAKE}#nixosConfigurations.${host}.config.nix.settings" \
      --apply 's: { subs = s.substituters or []; keys = s.trusted-public-keys or []; }' \
      >"$settings_json" 2>"$WORK/$host.settings.err"; then
    echo "::warning::pi-cache-miss: could not read nix.settings for $host" >&2
    cat "$WORK/$host.settings.err" >&2
    check_failed=true
    md_body+=$'\n'"#### \`$host\` — ⚠ check could not run (nix.settings eval failed)"$'\n'
    continue
  fi
  # Non-default substituters of the host (i.e. the vendor cache), de-duplicated.
  mapfile -t extra_subs < <(jq -r '.subs[]' "$settings_json" | sed 's:/*$::' \
    | grep -v '^https://cache\.nixos\.org$' | sort -u)
  mapfile -t keys < <(jq -r '.keys[]' "$settings_json" | sort -u)

  echo "== $host: dry-run (vendor substituters: ${extra_subs[*]:-none}) ==" >&2
  dry_err="$WORK/$host.dry.err"
  if ! nixw build --dry-run "$attr" \
      --option extra-substituters "${extra_subs[*]:-}" \
      --option extra-trusted-public-keys "${keys[*]:-}" \
      >/dev/null 2>"$dry_err"; then
    echo "::warning::pi-cache-miss: dry-run failed for $host" >&2
    tail -n 30 "$dry_err" >&2
    check_failed=true
    md_body+=$'\n'"#### \`$host\` — ⚠ check could not run (dry-run failed)"$'\n'
    continue
  fi

  # Parse the "will be built" block. Nix prints either
  #   "this derivation will be built:" or "these N derivations will be built:"
  # followed by indented store paths, then possibly a "will be fetched" block.
  awk '
    /derivations? will be built:$/ { inb=1; next }
    /will be fetched/              { inb=0; next }
    inb && /^[[:space:]]+\/nix\/store\/.*\.drv$/ { sub(/^[[:space:]]+/, ""); print; next }
    inb && !/^[[:space:]]/         { inb=0 }
  ' "$dry_err" >"$WORK/$host.built.raw"
  nix_count=$(wc -l <"$WORK/$host.built.raw")
  declared=$(grep -Eo '(these [0-9]+ derivations|this derivation) will be built' "$dry_err" \
    | sed -E 's/these ([0-9]+).*/\1/; s/this derivation.*/1/' || true)
  declared=${declared:-0}
  if [ "$declared" != "$nix_count" ]; then
    echo "::warning::pi-cache-miss: parsed $nix_count paths but nix declared $declared for $host" >&2
    check_failed=true
    md_body+=$'\n'"#### \`$host\` — ⚠ check could not run (parsed $nix_count of $declared will-be-built paths)"$'\n'
    continue
  fi

  count=$nix_count
  incomplete=""

  # Name-drift guard. Checked on the toplevel's DERIVATION closure, not on the
  # will-be-built / will-be-fetched lists: a kernel already valid in the local
  # store appears in neither list, but its .drv is always in the closure, so
  # this does not depend on what the local store holds.
  #  - nothing to build        -> nothing can be built from source: a true ✓
  #  - otherwise the toplevel nixos-system-*.drv is in the built list; its
  #    closure must contain a kernel and a firmware derivation matching the
  #    sentinels, else the result is incomplete.
  if [ "$nix_count" -gt 0 ]; then
    top=$(grep -E '^/nix/store/[a-z0-9]{32}-nixos-system-[^/]*\.drv$' "$WORK/$host.built.raw" | head -n 1 || true)
    if [ -z "$top" ]; then
      incomplete="no nixos-system-*.drv in the will-be-built list, so the kernel/firmware name check could not run"
    elif ! nixstorew --query --requisites "$top" >"$WORK/$host.closure" 2>"$WORK/$host.closure.err"; then
      tail -n 20 "$WORK/$host.closure.err" >&2
      incomplete="could not read the derivation closure of $(basename "$top")"
    else
      closure_names=$(grep '\.drv$' "$WORK/$host.closure" | while read -r p; do drv_name "$p"; done)
      if ! grep -Eq "$KERNEL_SENTINEL_RE" <<<"$closure_names"; then
        incomplete="no kernel derivation matching \`$KERNEL_SENTINEL_RE\` in the system closure (renamed upstream? update FLAG_RE)"
      elif ! grep -Eq "$FIRMWARE_SENTINEL_RE" <<<"$closure_names"; then
        incomplete="no firmware derivation matching \`$FIRMWARE_SENTINEL_RE\` in the system closure (renamed upstream? update FLAG_RE)"
      fi
    fi
  fi

  # Kernel/firmware candidates: only these are probed (a handful of paths,
  # not the whole will-be-built closure).
  : >"$WORK/$host.cand"
  while read -r drv; do
    [ -n "$drv" ] || continue
    n=$(drv_name "$drv")
    if [[ "$n" =~ $FLAG_RE ]] && ! [[ "$n" =~ $SKIP_RE ]]; then echo "$drv" >>"$WORK/$host.cand"; fi
  done <"$WORK/$host.built.raw"
  ncand=$(wc -l <"$WORK/$host.cand")

  # Direct probe of the candidates on the vendor substituter(s). This keeps
  # the answer right when the nix-daemon ignored the extra substituter
  # (untrusted user). A candidate is:
  #   substitutable - every output answered 200 on some vendor substituter
  #   flagged       - an output answered 404 on all of them (confirmed miss)
  #   unknown       - any other answer (timeout, 5xx, ...) -> check incomplete,
  #                   never reported as a miss.
  : >"$WORK/$host.flagged"
  probed_hits=0
  probe_unknown=0
  if [ "$ncand" -gt 0 ] && [ ${#extra_subs[@]} -eq 0 ]; then
    # No vendor substituter configured: Nix's own verdict stands.
    cp "$WORK/$host.cand" "$WORK/$host.flagged"
  elif [ "$ncand" -gt 0 ]; then
    # shellcheck disable=SC2046
    if ! nixw derivation show $(cat "$WORK/$host.cand") >"$WORK/$host.show.json" 2>"$WORK/$host.show.err" \
      || ! jq -r 'to_entries[] | .key as $d | [.value.outputs[] | .path // empty] | "\(if ($d|startswith("/nix/store/")) then $d else "/nix/store/"+$d end) \(join(" "))"' \
        "$WORK/$host.show.json" >"$WORK/$host.outs"; then
      echo "::warning::pi-cache-miss: could not read candidate outputs for $host" >&2
      tail -n 20 "$WORK/$host.show.err" >&2
      check_failed=true
      md_body+=$'\n'"#### \`$host\` — ⚠ check could not run (derivation show failed)"$'\n'
      continue
    fi
    awk '{for (i=2;i<=NF;i++) print $i}' "$WORK/$host.outs" | sort -u >"$WORK/$host.outpaths"
    # "<code> <sub> <path>" per probe; curl retries transient errors itself.
    : >"$WORK/$host.codes"
    for sub in "${extra_subs[@]}"; do
      # shellcheck disable=SC2016
      xargs -r -P 8 -I{} sh -c '
        h=$(basename "$1" | cut -d- -f1)
        code=$(curl -s -o /dev/null -w "%{http_code}" --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 30 "$2/$h.narinfo") || code=000
        echo "$code $2 $1"' _ {} "$sub" <"$WORK/$host.outpaths" >>"$WORK/$host.codes"
    done
    while read -r drv outs; do
      state=hit
      [ -n "$outs" ] || state=unknown
      for o in $outs; do
        # hit: some sub answered 200 · miss: every sub answered 404 · else unknown
        verdict=$(awk -v p="$o" '
          $3 == p { n++; if ($1 == "200") hit=1; else if ($1 == "404") nf++ }
          END { if (hit) print "hit"; else if (n > 0 && nf == n) print "miss"; else print "unknown" }
        ' "$WORK/$host.codes")
        case "$verdict" in
          hit) ;;
          miss) [ "$state" = unknown ] || state=miss ;;
          *) state=unknown ;;
        esac
      done
      case "$state" in
        hit) probed_hits=$((probed_hits + 1)) ;;
        miss) echo "$drv" >>"$WORK/$host.flagged" ;;
        *) probe_unknown=$((probe_unknown + 1)); echo "  probe inconclusive: $drv" >&2 ;;
      esac
    done <"$WORK/$host.outs"
    # A candidate that derivation show did not return is unknown, not a hit.
    missing_show=$(comm -23 <(sort -u "$WORK/$host.cand") <(awk '{print $1}' "$WORK/$host.outs" | sort -u) | wc -l)
    probe_unknown=$((probe_unknown + missing_show))
  fi
  nflag=$(wc -l <"$WORK/$host.flagged")

  if [ "$probe_unknown" -gt 0 ]; then
    echo "::warning::pi-cache-miss: $probe_unknown candidate(s) for $host got no definitive answer from the vendor cache" >&2
    incomplete="${incomplete:+$incomplete; }vendor cache did not answer definitively for $probe_unknown candidate(s)"
  fi
  if [ -n "$incomplete" ]; then
    echo "::warning::pi-cache-miss: $host check incomplete: $incomplete" >&2
    check_failed=true
  fi

  note=""
  if [ "$probed_hits" -gt 0 ]; then
    note=" (upper bound: $probed_hits kernel/firmware derivation(s) Nix counted were found on the vendor cache by direct probe; the nix-daemon did not consult it)"
  fi
  if [ -n "$incomplete" ]; then
    note+=" — ⚠ check incomplete: $incomplete"
  fi
  echo "$host: will-be-built=$count flagged=$nflag$note" >&2
  summary_lines+="$host: will-be-built=$count flagged=$nflag"$'\n'

  if [ "$nflag" -gt 0 ]; then
    any_flagged=true
    md_body+=$'\n'"#### \`$host\` — ⚠ $nflag kernel/firmware derivation(s) would be built locally"$'\n\n'
    md_body+="Total will-be-built: **$count**$note"$'\n\n'
    md_body+='```'$'\n'
    while read -r d; do md_body+="$(basename "$d")"$'\n'; done <"$WORK/$host.flagged"
    md_body+='```'$'\n'
  elif [ -n "$incomplete" ]; then
    md_body+=$'\n'"#### \`$host\` — ⚠ check incomplete"$'\n\n'
    md_body+="Total will-be-built: **$count**$note"$'\n'
  else
    md_body+=$'\n'"#### \`$host\` — ✓ Pi kernel/firmware substitutable"$'\n\n'
    md_body+="Total will-be-built: **$count**$note"$'\n'
  fi
  sed 's/^/  /' "$WORK/$host.flagged" >&2
done

if $any_flagged; then
  headline="⚠ **Pi cache miss:** kernel/firmware would be built from source on the device. Do not deploy to the Pi until this is resolved (wait for the vendor cache, or pin \`nixos-raspberrypi\` to a cached rev)."
elif $check_failed; then
  headline="⚠ **Pi cache check did not complete** — see the workflow log. Absence of a flag here is NOT a green."
else
  headline="✓ Pi kernel/firmware substitutable from the vendor cache."
fi

md="### Raspberry Pi cache check"$'\n\n'"$headline"$'\n'"$md_body"$'\n'"<sub>scripts/pi-cache-miss.sh — dry-run only; substituters read from each host's nix.settings.</sub>"$'\n'

printf '%s\n' "$summary_lines" >&2
if [ -n "$MD_OUT" ]; then printf '%s' "$md" >"$MD_OUT"; else printf '%s' "$md"; fi
if [ -n "$GH_OUT" ]; then
  {
    echo "miss=$any_flagged"
    echo "failed=$check_failed"
  } >>"$GH_OUT"
  outputs_written=true
fi

$check_failed && exit 2
exit 0
