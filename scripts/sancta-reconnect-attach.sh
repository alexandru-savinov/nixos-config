#!/usr/bin/env bash
# Reviewed replacement template for the owner script on the soul volume.
# NOT installed by the NixOS module. Applying it requires separate approval.
set -eu
if [ "${SANCTA_RECONNECT_KILLONLY:-0}" = 1 ]; then
  echo "pile-sweep REFUSED: attachment-only launcher never stops writers — 0 killed"
  exit 0
fi
if [ "${SANCTA_RECONNECT_DRYRUN:-0}" = 1 ]; then
  echo "[dry-run] attach existing Sancta backend; no kill and no Claude launch"
  exit 0
fi
if [ "$#" -ne 0 ]; then
  echo "usage: sancta-reconnect" >&2
  exit 2
fi
if [ "$(id -un)" != sancta ]; then
  echo "sancta-reconnect: use sessions attach sancta as the sancta account" >&2
  exit 1
fi
exec /run/current-system/sw/bin/sessions attach sancta
