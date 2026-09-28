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
#   3. Probes every remaining will-be-built output directly on those
#      substituters over HTTP (<hash>.narinfo). This makes the result correct
#      even when the local nix-daemon ignores the extra substituters (untrusted
#      user), and says so when it happens.
#   4. Flags kernel / firmware / dtb derivations that remain to-be-built.
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
trap 'rm -rf "$WORK"' EXIT

# Heavy Pi derivations, matched on the real names nixos-raspberrypi produces
# (observed 2026-09-28): linux_rpi-bcm2712-<ver>, linux-config-<ver>,
# raspberrypi-firmware-<ver>, raspberrypi-wireless-firmware-<ver>,
# firmware-nonfree, bluez-firmware, linux-firmware-<ver>, *dtbs*, device-tree-overlays.
FLAG_RE='^(linux[_-]rpi[^ ]*|linux-config-[0-9][^ ]*|raspberrypi(-wireless)?-firmware[^ ]*|linux-firmware[^ ]*|firmware-nonfree[^ ]*|bluez-firmware[^ ]*|[^ ]*dtbs[^ ]*|device-tree-overlays[^ ]*)$'
# Cheap local assembly steps (aggregateModules "<kernel>-modules", modules-shrunk,
# initrd, compressed copies, scripts) that are always built on the host and are never
# in any cache — matching the patterns above but not worth a flag.
SKIP_RE='(-modules|-modules-shrunk|-zstd|\.sh|\.conf)$|^initrd-'

drv_name() { basename "$1" .drv | cut -d- -f2-; }

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

  # Direct probe: drop every derivation whose outputs ALL exist on a vendor
  # substituter. Conservative: a partially cached derivation still counts.
  : >"$WORK/$host.built"
  probed_hits=0
  if [ "$nix_count" -gt 0 ] && [ ${#extra_subs[@]} -gt 0 ]; then
    # shellcheck disable=SC2046
    nixw derivation show $(cat "$WORK/$host.built.raw") 2>/dev/null \
      | jq -r 'to_entries[] | .key as $d | [.value.outputs[] | .path // empty] | "\(if ($d|startswith("/nix/store/")) then $d else "/nix/store/"+$d end) \(join(" "))"' \
      >"$WORK/$host.outs"
    # one line per output path -> hash, probed in parallel against each sub
    awk '{for (i=2;i<=NF;i++) print $i}' "$WORK/$host.outs" | sort -u >"$WORK/$host.outpaths"
    : >"$WORK/$host.cached"
    for sub in "${extra_subs[@]}"; do
      # shellcheck disable=SC2016
      xargs -r -P 16 -I{} sh -c '
        h=$(basename "$1" | cut -d- -f1)
        code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 20 "$2/$h.narinfo" || echo 000)
        [ "$code" = 200 ] && echo "$1"
        true' _ {} "$sub" <"$WORK/$host.outpaths" >>"$WORK/$host.cached"
    done
    sort -u -o "$WORK/$host.cached" "$WORK/$host.cached"
    while read -r drv outs; do
      all=true
      for o in $outs; do grep -qxF "$o" "$WORK/$host.cached" || { all=false; break; }; done
      if [ -n "$outs" ] && $all; then probed_hits=$((probed_hits + 1)); else echo "$drv" >>"$WORK/$host.built"; fi
    done <"$WORK/$host.outs"
    # Any drv that derivation-show did not return stays in the list.
    comm -23 <(sort -u "$WORK/$host.built.raw") <(awk '{print $1}' "$WORK/$host.outs" | sort -u) >>"$WORK/$host.built"
  else
    cp "$WORK/$host.built.raw" "$WORK/$host.built"
  fi
  sort -u -o "$WORK/$host.built" "$WORK/$host.built"
  count=$(wc -l <"$WORK/$host.built")

  : >"$WORK/$host.flagged"
  while read -r drv; do
    [ -n "$drv" ] || continue
    n=$(drv_name "$drv")
    if [[ "$n" =~ $FLAG_RE ]] && ! [[ "$n" =~ $SKIP_RE ]]; then echo "$drv" >>"$WORK/$host.flagged"; fi
  done <"$WORK/$host.built"
  nflag=$(wc -l <"$WORK/$host.flagged")

  note=""
  if [ "$probed_hits" -gt 0 ]; then
    note=" (nix listed $nix_count; $probed_hits found on the vendor cache by direct probe — the local nix-daemon did not consult it)"
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
fi

$check_failed && exit 2
exit 0
