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
# fromdateiso8601 accepts ONLY %Y-%m-%dT%H:%M:%SZ and REJECTS both the
# fractional form (…20.784Z, from new Date().toISOString()) AND any numeric
# offset (…+03:00 / …-05:00, from `date -Is`). Left unhandled either made a
# message unparseable → answered=0, open=inbox_count, newest_open_message=null.
# #524 fixed the fractional-Z case only; the tick's OWN reply lines still used
# `date -Is`, which emits a LOCAL offset (+HH:MM). Those replies never parsed,
# so they never counted as answered and the tick re-reflected the same
# newest-open message every 30 min forever (the never-close loop). His own
# messages are `.NNN Z` (JS toISOString) so they parsed — only the tick's did not.
#
# Total (never throws): strip fractional seconds regardless of what follows; if
# a trailing ±HH:MM offset remains, parse the wall-clock [0:19] as Z then adjust
# to UTC (+HH:MM is ahead of UTC → SUBTRACT the offset; -HH:MM → ADD it); else
# ensure a single trailing Z and parse. Anything unparseable degrades to null.
def epoch: (.ts // "")
  | sub("\\.[0-9]+"; "")
  | . as $s
  | if test("[+-][0-9]{2}:[0-9]{2}$") then
      ($s | .[0:19]) as $wall
      | ($s | .[19:]) as $off
      | ($off | .[1:3] | tonumber) as $oh
      | ($off | .[4:6] | tonumber) as $om
      | ($oh * 3600 + $om * 60) as $osec
      | (try (($wall + "Z") | fromdateiso8601) catch null) as $base
      | if $base == null then null
        elif ($off | .[0:1]) == "+" then $base - $osec
        else $base + $osec
        end
    else
      ($s | sub("Z$"; "") + "Z")
      | (try fromdateiso8601 catch null)
    end;

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
