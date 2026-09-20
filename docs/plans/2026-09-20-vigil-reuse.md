# Vigil and Gatus

Gatus remains the dashboard and existing service monitor. Vigil contributes its
three-valued aggregate through `/status`; Gatus evaluates `[BODY].stare == verde`.
A failed condition retains the actual `picat` or `NECITIT` value in Gatus's
condition details. No additional dashboard, storage service, or notification
provider is introduced. Vigil alone owns its incident notifications.

The status response includes only the existing public tick fields and `stare`.
It reports NECITIT for a tick older than 15 minutes, a future timestamp, or an
aggregate row that does not match the published tick. Missing/corrupt evidence
fails the HTTP check. Reading the dashboard never advances incident state or
counts a sample. The peer endpoint `/` retains its original timestamp semantics.

## Why the remaining code exists

The rpi5 package is pinned to Gatus 5.31.0. Its
[result structure](https://github.com/TwiN/gatus/blob/v5.31.0/config/endpoint/result.go)
exports status, conditions, errors and a timestamp, but not the response body.
Its [condition evaluator](https://github.com/TwiN/gatus/blob/v5.31.0/config/endpoint/condition.go)
uses its own comparison/pattern language. These are not a replacement for the
required ECMAScript body matching and embedded peer-timestamp checks.

| Retained component | Requirement it supplies |
| --- | --- |
| Local checks | Unit state, successful unit/file age, exact mounts, disk space and allow-listed commands |
| HTTP/HA checks | Bounded responses, exact body semantics, private token/contract handling, fixed public diagnostics |
| Incident state | Distinct NECITIT, acknowledgement rearming and continuous recovery hold-down |
| Delivery queue | Durable ordered open/close retries and active-episode retention |
| Tick socket | Independent peer freshness and a narrow public status surface |

Gatus already supports thresholded alerts, but its documented alert model uses
consecutive successes for recovery; its
[delivery state](https://github.com/TwiN/gatus/blob/v5.31.0/alerting/alert/alert.go)
also describes different retry treatment for recovery notifications. Substituting
it would not preserve Vigil's exact timing and FIFO semantics.

None of the current Gatus probes exactly matches a Vigil public contract:
Gatus checks HA's authenticated `/api/`, whereas Vigil checks `/manifest.json`;
Gatus's Tailscale probe is ICMP, whereas Vigil checks the local unit. Reusing a
service name would silently change what is measured.

Delegating additional basic probes to Gatus would require a configuration
mapping, API reader, stale-data handling and durable sample deduplication. The
existing TCP probe is a small standard-library call, and HTTP transport is still
needed for HA and peer checks. That adapter has no demonstrated code reduction,
so it is not added. Gatus is reused at the presentation boundary where it already
provides the required capability; custom incident semantics remain explicit.

This decision supersedes the original plan's prohibition on necessary Gatus
integration changes. Other protected infrastructure remains unchanged.
