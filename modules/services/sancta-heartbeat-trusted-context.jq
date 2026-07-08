# Mechanical trusted-context for the Sancta heartbeat tick (membrane reflection, #519).
#
# Computed OUTSIDE the model from the mirrored JSONL, so a crafted inbox line
# cannot fake the counts or claim it is already answered — the model is told to
# trust ONLY this block. Consumed by sancta-heartbeat-tick.nix via `jq -f`, and
# exercised directly by the flake check `heartbeat-trusted-context` so the two
# can never drift.
#
# Inputs (via --slurpfile): $inbox, $replies  (arrays of parsed JSONL objects).
#
# epoch: seconds for an ISO-8601 ts, or null if absent/unparseable. jq's
# fromdateiso8601 accepts ONLY %Y-%m-%dT%H:%M:%SZ and REJECTS the fractional
# form (…20.784Z) that new Date().toISOString() actually emits — every real
# membrane line carries .NNN. Left unhandled it made every message unparseable
# → answered=0, open=inbox_count, newest_open_message=null → the reflection
# could never fire (bare-ACK forever). Strip the ".NNN" before the trailing Z;
# non-fractional / already-Z inputs pass through unchanged.
def epoch: (.ts // "")
  | sub("\\.[0-9]+Z$"; "Z")
  | (try fromdateiso8601 catch null);

($replies | map(epoch) | map(select(. != null))) as $rep_epochs
| ($inbox
    | map(. + {e: epoch})
    | map(.e as $me
          | . + {answered: ($me != null and ($rep_epochs | any(. > $me)))})
  ) as $msgs
| ($msgs | map(select(.answered)) | length) as $answered
| ($msgs | length) as $n
| ($msgs
    | map(select(.answered | not))
    | map(select(.e != null))
    | sort_by(.e)
    | last) as $newest_open
| {
    inbox_count: $n,
    replies_count: ($replies | length),
    answered: $answered,
    open: ($n - $answered),
    newest_open_message:
      ( ($newest_open.message // null)
        | if type == "string" then .[0:600] else null end )
  }
