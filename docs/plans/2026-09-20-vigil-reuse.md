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

## Agent assessment

Gatus supports agents through its
[external-endpoint push API](https://github.com/TwiN/gatus/blob/v5.31.0/api/external_endpoint.go).
The pinned handler requires `success=true` or `success=false`; `error` can carry
additional text on failure. It assigns `time.Now()` at ingestion and inserts a
result on every call, without an observation timestamp or idempotency key.
Therefore an agent can report NECITIT as text, but consumers must still distinguish
it from picat, and buffered/retried pushes must not become fresh observations or
extra failure samples. This is an integration gap, not a claim that Gatus cannot
have agents. Pushing the existing aggregate would add credentials and delivery
code to a view that the existing `/status` pull already supplies.

The community [sys-agent](https://github.com/umputun/sys-agent) is a real host
collector usable by Gatus. Source reviewed at revision
`8b91897e605102657d2c58e1fd1528eba63a5f37`:

| Candidate probe | Concrete difference from the required contract |
| --- | --- |
| [HTTP](https://github.com/umputun/sys-agent/blob/8b91897e605102657d2c58e1fd1528eba63a5f37/app/status/external/http_provider.go) | Reads the entire body with `io.ReadAll` and exposes it in the response; Vigil requires a 64 KiB limit and fixed public diagnostics. |
| [File age](https://github.com/umputun/sys-agent/blob/8b91897e605102657d2c58e1fd1528eba63a5f37/app/status/external/file_provider.go) | Supplies modification time, but also reads and returns up to 100 bytes of file content. Vigil needs metadata only. |
| [Program](https://github.com/umputun/sys-agent/blob/8b91897e605102657d2c58e1fd1528eba63a5f37/app/status/external/program.go) | Returns command arguments, stdout, stderr and raw error text; output buffers are not capped. Existing privacy and bounded-output requirements still need an implementation. |

Sys-agent can collect disk utilization too. Adopting it solely for this metric
would replace one local `statfs` call with a new service, package, configuration
and response reader while leaving the other probes and incident engine in place.
That is not a demonstrated reduction in maintained code. The selected v1 reuse
remains Gatus for display and existing monitoring, with Vigil supplying only its
required local evidence and incident behavior. This conclusion is scoped to the
reviewed candidates and requirements, not all possible Gatus agents.
