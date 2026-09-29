# Gatus coverage audit

Observed 2026-09-22 from the owner's Mac using read-only SSH to rpi5 and choir.
Scope: the approved [coverage plan](2026-09-22-gatus-coverage-plan.md). No
production configuration, credential, marker, or incident state was changed.
All 24 existing Gatus endpoints were green at the initial inspection around
10:58 UTC. This is a current observation, not an availability guarantee.

## Native checks observed from rpi5

All HTTP checks use the current Gatus client defaults (no explicit timeout in
the evaluated host configuration). Fixtures exercise the installed 5.31.0
binary. No new latency threshold is selected from these single observations;
24-hour latency review remains pending.

| Endpoint / entrypoint | Interval | Existing assertion | Observed safe fact / gap | Notification owner |
| --- | --- | --- | --- | --- |
| n8n, local `:5678/healthz` | 1m | HTTP 200 | JSON `status=ok`; `/healthz/readiness` also responds with `status=ok`. Neither runs workflows. | Gatus dashboard only |
| Anki Workflow, local `/webhook/image-to-anki-ui` | 1m | HTTP 200 | HTML with fixed page title and file input; no generation was triggered. The page can contain previous-job details, so failed body values must not be retained. | Gatus dashboard only |
| NixFrame Upload, local `/webhook/nixframe-ui` | 1m | HTTP 200 | HTML with fixed title/file input; no upload was triggered. A working UI does not prove delivery to the frame. | Gatus dashboard only |
| Home Assistant, authenticated local `:8123/api/` | 1m | HTTP 200 | JSON `message=API running.` verified using the existing runtime credential, without printing it or querying entities. | Gatus dashboard only |
| Tailscale, Pi tailnet DNS name | 30s | ICMP connected | Checks the Pi from itself, not a remote application's path. | Gatus dashboard only |
| OpenRouter `/api/v1/models` | 5m | HTTP 200 and <3000ms | Public `data` array verified; no inference or paid request. Does not establish model availability for this account. | Gatus dashboard only |

Successful bounded probes measured 6–204ms across these HTTP/API/UI checks and
selected HTTPS paths. This small snapshot is not sufficient for threshold changes.
Raw response bodies and credentials were not saved in audit artifacts.

The real Home Assistant HTTPS entrypoint is
`https://rpi5.tail4249a9.ts.net:8123/manifest.json`. A verified TLS request returned
200 and `name=Home Assistant`; add this as a native functional view while retaining
Vigil's existing `ha-served` incident. Gatus's own HTTPS page also responded at
`https://rpi5.tail4249a9.ts.net:3001/`. A self-check cannot report the entire Gatus
process or Pi going down. No independent Gatus-process alert currently exists.
Peer Vigil checks cover host/freshness failures, not specifically a dead Gatus
process. That remains a documented gap requiring a separate ownership decision.

Certificate validation is exercised by real HTTPS requests. Proactive expiry
headroom and DNS probes are deferred until certificate renewal timing and a
specific unresolved-path failure justify their thresholds/placement. Do not
monitor provider-owned tailnet domain registration expiry.

## Vigil views and ownership

Gatus polls 16 `/checks/<public-name>` rows and two `/status` summaries every
minute. Those polls read the latest complete run. Their duration measures status
retrieval; their timestamp is not a new probe. Vigil checks every five minutes,
uses a two-sample incident threshold, and retains its existing continuous
30-minute recovery hold-down. Telegram delivery stays owned by Vigil.

| Observer | Public contracts | Evidence / blind spot |
| --- | --- | --- |
| rpi5 | `channel` | Real Telegram success age, 2d threshold; not a human read receipt |
| rpi5 | `choir-host`, `choir-tick` | Choir tick listener plus embedded age <15m; not all choir services |
| rpi5 | `ha-alive`, `ha-served` | Local manifest and HTTPS reachability; no private entity assertions |
| rpi5 | `soul-mirror-pull` | Current-boot successful unit completion, 8d; post-reboot evidence can be NECITIT |
| rpi5 | `tailscaled` | Local unit state; not remote reachability by itself |
| choir | `channel` | Real Telegram success age, 2d; not a human read receipt |
| choir | `rpi5-host`, `rpi5-tick` | Pi tick listener plus embedded age <15m; not the Gatus process specifically |
| choir | `galeria` | HTTP 200 from choir to its own tailnet-bound gallery; not functional content or Pi-to-gallery routing |
| choir | `membrana` | Local TCP listener; not a complete application transaction |
| choir | `build-volume`, `disk-root` | Mounted volume and root usage <85%; not data integrity |
| choir | `soul-mirror` | Current-boot successful unit completion, 8d; not restore acceptance |
| choir | `tailscaled` | Local unit state |

Do not merge local and remote observations just because they name the same
service. No Vigil contract, expected count, alert rule, or state is changed by
the proposed native checks. Private Home Assistant conditions remain deferred.

## Gallery route findings and pilot decision

The deployed server is outside this repository. Bounded source inspection
confirmed `/` serves the fixed gallery shell and `/api/latest` returns `file`,
`mtime`, `server_ts`, and `gate`. With the publish gate active, only artifacts
with an existing publish-pass sidecar are eligible. Both an empty gallery
(`file=null`, `mtime=null`) and a published image are supported by the server.
The live gate was true and a published image existed; no artifact name, image,
or private gallery content was printed or copied.

No fixed vendor asset was referenced by the current shell. Therefore the earlier
“select an item then retrieve its image” proposal is not adopted in this phase.
It would introduce dynamic object identifiers and require privacy-safe diagnostics.

The bounded pilot is **gallery page -> metadata API**, observed from rpi5. Check
that the shell advertises its API and contains an image element, then that the
API supplies its documented fields with the publish gate enabled. The owner explicitly requires at least one published image; null or empty
`file` therefore fails the suite, without exposing its value in diagnostics. Do not claim
that this suite verifies an image's bytes, rendering, or content freshness. It
still detects a broken API behind a healthy page and a Pi-to-gallery routing
failure. No shared context or arbitrary artifact URL is needed for these two
fixed routes. A false gate or missing API field is a useful distinct failure.

## Selected implementation and gates

1. Preserve all six direct endpoint names/groups. Strengthen the five HTTP
   assertions, add separate n8n readiness and HA HTTPS rows, and keep the
   existing OpenRouter latency threshold. Native checks remain dashboard-only.
2. Expose only Gatus's `dont-resolve-failed-conditions` option needed to prevent
   body values from entering diagnostic history. Keep Vigil's safe, fixed
   diagnostic text resolved. Verify with synthetic credential/body sentinels.
3. Prepare the gallery pilot in a separate PR, with explicit per-request timeouts
   and a suite timeout. In pinned 5.31.0 the suite timer is checked between steps;
   it is not reliable request cancellation. Bound each of the two requests to
   10s rather than treating the suite timer as a hard deadline.
4. Require meaningful installed-binary fixtures, Nix evaluation, required CI,
   an exact-revision build, and production approval before activation. Record
   24h native and 48h suite observation only after deployment and elapsed time.
5. Revisit duplicate observations/notification ownership only after that evidence.
   No automatic migrations or additional suites are authorized by these findings.

## Source references

- `hosts/rpi5-full/configuration.nix`, `modules/services/gatus.nix`, and both
  hosts' public Vigil contract directories.
- `n8n-workflows/image-to-anki-ui.json` and `n8n-workflows/nixframe-ui.json`
  establish the public UI markers; no workflow was executed by this audit.
- [Pinned Gatus UI fields](https://github.com/TwiN/gatus/blob/v5.31.0/config/endpoint/ui/ui.go)
  and [suite execution](https://github.com/TwiN/gatus/blob/v5.31.0/config/suite/suite.go).
