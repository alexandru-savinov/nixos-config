#!/usr/bin/env bash
#
# check-secret-recipients.sh — agenix recipient-drift + empty-plaintext guard
#
# Why this exists (see issue #448, SECRETS-ROTATION.md):
#   agenix re-encrypts a secret to the recipient set DECLARED in secrets.nix
#   at the time `agenix -e`/`agenix -r` is run on a host. If a recipient SSH
#   host key is rotated, or if secrets.nix is edited without re-running agenix
#   on a decrypting host, the .age file on disk can drift from the declared
#   `publicKeys`. agenix does NOT verify this at activation time — it "fails
#   open": a secret may be readable by stale keys, or unreadable by a host that
#   secrets.nix claims should have access, with no error until the service breaks.
#
# This guard catches two cheap-to-detect symptoms WITHOUT decrypting anything:
#   1. RECIPIENT DRIFT — the number of `-> ` recipient stanzas baked into the
#      .age file != the number of entries in its declared `publicKeys` list.
#   2. EMPTY PLAINTEXT — the ciphertext body is tiny (~empty-string payload),
#      the classic signature of an `agenix -e` that was saved without content.
#
# It is intentionally heuristic and read-only: it never runs `agenix -d`, never
# needs a private key, and is safe to run in CI and on a developer's machine
# (including darwin). The actual re-encryption fix for any flagged file must be
# done ON A HOST THAT HOLDS A DECRYPTING KEY (see SECRETS-ROTATION.md).
#
# Usage:   scripts/check-secret-recipients.sh [SECRETS_DIR]
# Exit:    0 = all consistent, 1 = drift/empty-plaintext found, 2 = usage error
set -euo pipefail

SECRETS_DIR="${1:-secrets}"

if [ ! -d "$SECRETS_DIR" ]; then
  echo "error: secrets dir not found: $SECRETS_DIR" >&2
  exit 2
fi

SECRETS_NIX="$SECRETS_DIR/secrets.nix"
if [ ! -f "$SECRETS_NIX" ]; then
  echo "error: $SECRETS_NIX not found" >&2
  exit 2
fi

# Smallest legitimate ciphertext body in this repo is ~46 bytes; an age file
# encrypting the empty string has a ~16-byte (raw) / ~24-byte (base64) body.
# 32 cleanly separates the two. Bump only with evidence.
EMPTY_PAYLOAD_THRESHOLD=32

# Known-pending recipient drift — reported as a WARNING, not a hard failure, so
# CI stays green while a fix waits on an on-host re-key (the re-encryption cannot
# be done from a darwin box; it needs a host holding a decrypting key). Add an
# entry ONLY while a real drift is pending reconciliation, and REMOVE it the
# moment its .age is re-keyed on-host (`cd secrets && agenix -e <file>.age` on a
# decrypting host such as rpi5). Issue #448.
#
# Currently empty: hermes-env.age is reconciled to its declared 3 recipients
# (on-disk `-> ` stanzas == declared publicKeys), so the hard check is re-armed
# for every secret.
KNOWN_PENDING_DRIFT=()

# ── Resolve DECLARED publicKeys length per .age, keyed by basename. ──────────
# Preferred path: `nix eval` imports secrets.nix (a pure attrset — no flake
# context needed) and reports `builtins.length publicKeys` per file. If nix is
# unavailable (e.g. a minimal CI shell), fall back to "drift check disabled,
# empty-plaintext check still runs" rather than failing the whole guard.
declare -A DECLARED
HAVE_DECLARED=0
if command -v nix >/dev/null 2>&1; then
  # Absolute path so `import` works regardless of CWD (e.g. SECRETS_DIR may be
  # an absolute path supplied by a caller or a test harness).
  SECRETS_NIX_ABS="$(cd "$(dirname "$SECRETS_NIX")" && pwd)/$(basename "$SECRETS_NIX")"
  # Output is `name<TAB>count` lines.
  while IFS=$'\t' read -r name count; do
    [ -n "$name" ] && DECLARED["$name"]="$count"
  done < <(
    # Each line ends in a newline (including the last) so `read` does not
    # silently drop the final entry.
    nix eval --impure --raw --expr "
      let s = import $SECRETS_NIX_ABS;
      in builtins.concatStringsSep \"\" (
        builtins.attrValues (
          builtins.mapAttrs
            (n: v: n + \"\t\" + builtins.toString (builtins.length v.publicKeys) + \"\n\")
            s
        )
      )
    " 2>/dev/null
  ) || true
  [ "${#DECLARED[@]}" -gt 0 ] && HAVE_DECLARED=1
fi

if [ "$HAVE_DECLARED" -eq 0 ]; then
  echo "note: nix eval unavailable or empty — recipient-drift check skipped," >&2
  echo "      empty-plaintext check still runs." >&2
fi

# ── Walk the .age files. ─────────────────────────────────────────────────────
fail=0
checked=0
shopt -s nullglob
for f in "$SECRETS_DIR"/*.age; do
  base="$(basename "$f")"
  checked=$((checked + 1))

  # On-disk recipient stanzas. LC_ALL=C + -a so grep treats the binary
  # ciphertext tail as text and matches the ASCII header reliably.
  ondisk="$(LC_ALL=C grep -a -c '^-> ' "$f" || true)"

  # Empty-plaintext signature: bytes after the single `--- <mac>` header line.
  total="$(wc -c < "$f")"
  macoff="$(LC_ALL=C grep -a -b -m1 '^--- ' "$f" | cut -d: -f1 || true)"
  if [ -n "$macoff" ]; then
    # 49 ≈ len("--- ") + 44 (base64 of 32-byte MAC) + 1 newline.
    payload=$((total - macoff - 49))
    if [ "$payload" -lt "$EMPTY_PAYLOAD_THRESHOLD" ]; then
      echo "FAIL [$base]: ciphertext body ~${payload}b (< ${EMPTY_PAYLOAD_THRESHOLD}b) — looks like EMPTY plaintext" >&2
      fail=1
    fi
  else
    echo "WARN [$base]: no '--- ' MAC header line found (unexpected age format)" >&2
  fi

  # Recipient-drift check (only when declared counts were resolved).
  if [ "$HAVE_DECLARED" -eq 1 ]; then
    declared="${DECLARED[$base]:-}"
    if [ -z "$declared" ]; then
      echo "FAIL [$base]: present on disk but NOT declared in secrets.nix" >&2
      fail=1
    elif [ "$ondisk" != "$declared" ]; then
      pending=0
      # `${arr[@]+...}` keeps an empty array safe under `set -u` (incl. bash 3.2
      # on darwin), so the allowlist can be emptied without breaking the guard.
      for k in ${KNOWN_PENDING_DRIFT[@]+"${KNOWN_PENDING_DRIFT[@]}"}; do
        [ "$k" = "$base" ] && pending=1 && break
      done
      if [ "$pending" -eq 1 ]; then
        echo "WARN [$base]: KNOWN recipient drift (on-disk=$ondisk, declared=$declared) — pending on-host re-key, see issue #448" >&2
      else
        echo "FAIL [$base]: recipient drift — on-disk stanzas=$ondisk, declared publicKeys=$declared" >&2
        echo "       fix ON A DECRYPTING HOST: cd secrets && agenix -e $base   (or: agenix -r)" >&2
        fail=1
      fi
    fi
  fi
done

if [ "$checked" -eq 0 ]; then
  echo "error: no .age files found under $SECRETS_DIR" >&2
  exit 2
fi

if [ "$fail" -eq 0 ]; then
  echo "OK: $checked secret(s) checked, no recipient drift or empty-plaintext detected."
fi
exit "$fail"
