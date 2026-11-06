# Backend latency audit: handoff (2026-11-05)

> **Update, later on 2026-11-05: the audit is finished.** Read `docs/backend-latency-audit-report.md` first.
> The backend patch is at `C:\Users\opera\integrity-backend-latency\latency-audit-changes.patch` (detached worktree, not committed),
> and the Flutter calendar change is uncommitted in this repo. The next step is the user's deploy approval.
> The rest of this file is the earlier mid-audit state, kept for its raw evidence.

Stopped early at about 90% usage. This is the read-only audit phase, partly done.

**Nothing has been changed.** No code edits in either repo, no commits, no deploys, no Render or production changes.
No improvements are implemented, so there are no before/after numbers yet, and the final report has not been written.

## The brief, in short

The user asked for a full audit of API latency and app responsiveness, then safe fixes, then measured before/after.
Goal: the app feels very fast with several office staff and techs on it at once.

Final report needs these 10 parts: overall assessment, full endpoint inventory, slowest endpoints ranked, worst screen
load sequences, frontend communication problems, Render findings, external integration bottlenecks, improvements made,
before/after measurements, remaining recommendations.

Latency classes: Excellent under 100 ms, Good 100-250, Acceptable 250-500, Slow 500-1,000, Critical over 1,000.
Report average, P50, P95, P99 (where samples allow), max, error rate, frequency and payload size. Separate app, database,
external and network time. Also cover screen load: calls per screen, what blocks first paint, duplicates, polling.

Strict rules from the user:
- Real measurements only. Never invent a latency figure. Say when telemetry is missing.
- Do not commit, push, merge or deploy. No Render or production config changes without approval.
- Do not change auth or permissions. No breaking API changes. No unrelated UI changes.
- Never trade payment, commission, inventory or financial accuracy for speed.
- Production tests must be controlled and low volume. No load tests on live production.
- Anything needing a deploy: prepare it, explain the expected impact, stop for approval.
- A separate Postgres audit is running. Complement it, do not duplicate it (no index or schema work here).

## Read this before touching the backend

- **Do not edit `C:\Users\opera\integrity-backend` in place.** The user's commit-all pushes sweep the working tree and Render
  auto-deploys on commit, so a saved edit can go live within a minute. That would break the "stop for approval" rule.
  Do backend work in a separate git worktree or copy, and hand it over as a patch.
- **The database audit is shipping as we go.** Commit `8bf0055f` "Fixing Speed" went live at 14:17 UTC today. It skips unchanged
  job writes, makes the warm-up hourly outside office hours, and speeds up the calendar query. Re-check `git log` before
  relying on anything below. All log samples here are from BEFORE that deploy.
- **Measuring admin routes:** most dashboards need a real admin session. The shared app key is not enough. Do not mint a token
  or lift a stored session from this machine. Ask the user how they want to provide one. So far only unauthenticated static
  requests have been sent to production; the shared key has not been used.
- **Keep prod probes light.** A probe caused a database out-of-memory event on 2026-10-29.
- **Log pages are expensive** (about 16k tokens per 100 lines). Send paging to a subagent, never the main thread.

## Environment (verified today)

| Item | Value |
|---|---|
| Web service | `srv-d7bs4ulm5p6s73f51itg`, starter, 0.5 CPU, 512 MB, 1 instance, Oregon, Node 22.22, WEB_CONCURRENCY=1 |
| Health check path | Not set |
| Postgres | `dpg-dag0d367bikc73ds58d0-a`, PG 18.6, 0.5 CPU, 1 GB, shared_buffers 256 MB, work_mem about 6.5 MB, statement_timeout off |
| Edge | Cloudflare in front; every asset shows `cf-cache-status: DYNAMIC`, so nothing is cached there |
| Workspace | `tea-d71al5gule4c73cp7lsg` |

## Telemetry available

- Render `http_latency` returns nothing, and logs have only `app` and `build` types. **No per-endpoint latency exists in production.**
- `http_request_count` by status works. `pg_stat_statements` is on (7-day window from 2026-10-29 15:46 UTC). `track_io_timing` is off.
- **Warm-up log gaps:** the warm-up calls about 24 endpoints one at a time, and each request logs a timestamp, so the gap
  between lines approximates uncached server time at zero added load.
  **Not fully validated:** some gaps are too short to be real work (inventory 9 ms, estimates 17 ms, one KPI 2 ms). They may
  be non-200s or short-circuits. Check before publishing any short gap. Longer gaps look credible.
- Best next step: a small timing middleware (Server-Timing or a slow-request log) would give true P50/P95/P99. It needs a deploy, so it needs approval.

## Measured so far

### Uncached server time, 5 warm-up cycles only

Small sample. Four cycles ran after hours (03:45-03:57 UTC, old instance), one just after boot (14:18 UTC). Not percentiles.
These are the cold path. A user who hits a warmed cache gets a stored copy instead.

| Endpoint | Gaps in ms | Class |
|---|---|---|
| `/api/employees/bmiller/kpis` | 1325, 996, 1010, 1199, 1286 | Critical / Slow |
| `/api/payroll/commission-detail` | 682, 932, 633, 721, 993 | Slow |
| `/api/commissions_stats` | 688, 677, 760, 797, 990 | Slow |
| `/api/tech_stats` | 591, 507, 522, 790, 698 | Slow |
| `/api/dashboards/jobs` | 356, 448, 471, 397, 571 | Acceptable / Slow |
| `/api/financial_dashboard` | 345, 348, 335, 387, 505 | Acceptable / Slow |

One full warm cycle takes about 6 s.

### Network, from this machine (6 samples)

TCP about 15-30 ms, TLS about 30 ms more. HEAD `/` TTFB 146-298 ms on a new connection.

### Web app delivery (one sample each)

- `main.dart.js` is 5.88 MB raw and 1.76 MB gzipped. **Gzip took 1.50 s in total, uncompressed took 0.71 s**, so compressing on the fly
  on 0.5 CPU cost more than it saved from this fast connection. A slower link would see this differently. One sample only.
- `Cache-Control: public, max-age=0`. The ETag is size plus modified time, and `last-modified` equals the deploy time even
  though the build is from yesterday. **So every backend deploy appears to force a full re-download of the app.** About 9 deploys
  happened on Nov 4 (counted from instance changes). Confirm with a conditional request across a deploy.
- `main.dart.js.map` (7 MB) is in `src/public`. Whether it is publicly served has not been checked.

### Render

- Traffic is small: peak about 400 external requests an hour (Nov 4, 15:00 UTC: 213 x 200, 141 x 204, 43 x 304).
- Errors: only one 413 and one 401 from Nov 4 00:00 UTC to Nov 5 14:00 UTC. No 5xx in that window. That count excludes local warm-up calls.
- CPU: 1-minute peaks about 0.13 of 0.5, spiking every 4-5 minutes (likely the warm-up), usually about 0.01. **No CPU evidence for an upgrade so far.**
  Caveat: minute averages hide short throttling bursts.
- Memory: normally 220-310 MB. **Instance 77vfm jumped to about 420-445 MB of 512 MB around 04:00 UTC and stayed there for 10 hours**
  until today's deploy. The new instance sits at 256 MB. Cause unknown. The nearest visible activity is Jarvis calls and the payroll,
  KPI and users screens opened around 03:44-03:59 UTC, but no link is proven.
- Stability: 5 `server_failed` events (exit 1) from Oct 22 to Oct 29, none since. No OOM events listed.
- Boot takes about 5 s. During a deploy, old and new instances both run sync at once (seen at 14:17).
- 204s are about a third of office-hour requests. **Probably CORS preflights**, since `cors()` has no `maxAge` and runs before the logger.
  Unconfirmed. If so they come from a cross-origin client, perhaps `flutter run -d chrome`, as the hosted web app is same-origin.

### Database attribution (7 days, 17,987 s total)

- Largest single statement: a `WITH name_lookup ...` query, 10,370 calls, 3,284 s (18%), mean 317 ms, max 2,385 ms. Which route runs it is not yet confirmed.
- Calendar query: 923 calls, mean 1,098 ms, about 874 rows a call. This predates the speed-up in `8bf0055f` (claimed 2.6x, not re-measured).
- Sync writes dominate call counts (jobs upsert 2.6M, `retainage_ledger` delete 5.8M). `8bf0055f` targets the jobs half. Leave this to the DB audit.

### Client and background behaviour seen in logs

- `GET /api/calendar/sync?start=2026-10-01&end=2027-01-01` fired exactly every 5 minutes at night, so an open client is polling a 3-month range.
- The Android app calls `/get_schedule` and `/get_briefing` together, several times within seconds (Ryan's device, 03:42 UTC).
- The 1-minute Service Fusion sync overran its slot ("skipped: previous run still going"), and one pass logged "8 page(s) timed out for jobs".
  An incremental pass took about 9 s.

## Candidate fixes (none built, all need testing)

1. Timing middleware, so real percentiles exist. Do this first, it unblocks everything else.
2. Web delivery: content-hash ETag so deploys stop busting the client cache; compress once instead of per request.
3. `cors({ maxAge })` if 204s are confirmed as preflights.
4. Calendar polling: stop when hidden, narrow the range, use conditional requests.
5. Tech KPI cost (`bmiller` about 1-1.3 s) and the `name_lookup` query path.
6. `responseCache` re-serializes and re-compresses on every hit. Check whether storing the serialized body is worth it.
7. Find the memory jump before adding any new caches. There is only about 200 MB of headroom on a normal day.
8. Skip running sync on two instances during a deploy, if cheap and safe.

Be careful with any caching on payments, commissions, inventory and financial data.

## Not done yet

- Endpoint inventory and screen-to-API map (see below)
- Real P50/P95/P99 and payload sizes for API routes
- Stripe, Quo, Google, Anthropic and Service Fusion call timing and timeouts
- Pool, keep-alive and timeout settings review (`src/index.js` read only to about line 200)
- Screen load measurements, all implementation, testing, before/after, final report

## Work in progress when this was written

Three background agents were running. Their output goes to this session's scratchpad and may or may not have finished:

`C:\Users\opera\AppData\Local\Temp\claude\099a4ba3c039071a\0d78536a-22f9-4789-98b9-efbb44f9eca1\scratchpad\`

| File | Contents |
|---|---|
| `backend_inventory.md` | Every route, plus backend processing findings |
| `frontend_map.md` | Screen-by-screen API map, polling, duplicates |
| `requests_A.tsv`, `requests_B.tsv` | Request lines for Nov 4 16:00-17:00 and 22:00-23:00 UTC, for request mix and about 30 warm cycles |
| `sync_lines.tsv`, `assistant_lines.tsv` | Sync and Jarvis timing |
| `memory_jump.md`, `errors.md` | Memory jump cause, grouped errors |

If a file is missing or incomplete, redo that part. Treat agent findings as unverified until spot-checked against the code.

**Inventory and frontend map agents were stopped before writing anything.** `backend_inventory.md` and `frontend_map.md`
do not exist. Both jobs have to be redone from scratch. The only files saved are the two request logs below.

**Log agent result (finished partially):** the Render connector disconnected partway through ("Server not found", 404). Reconnect it before resuming.
- `requests_A.tsv`: 345 rows, complete (Nov 4, 16:02:22 to 16:59:32 UTC, instance g7bd5).
- `requests_B.tsv`: 300 rows, stops at 22:53:20.036 UTC. To finish it, resume from startTime `2026-11-04T22:53:20.036500775Z` to `23:00:00Z` with text `📢`.
- `memory_jump.md`, `sync_lines.tsv`, `errors.md` and `assistant_lines.tsv` were never started. Those jobs need redoing.
- What the agent saw, not yet checked: a warm-up burst of about 21 `?fresh=1` requests every 4 minutes in both windows, and
  `/api/calendar/sync` every 5 minutes in window A only until 16:17. Window A also has real user traffic: a payroll session
  around 16:19 to 16:20 and a job search around 16:38.

## Where to resume

1. Check `git log` in the backend and read what shipped since `8bf0055f`.
2. Collect the scratchpad files. Validate the warm-gap method using the short gaps above.
3. Finish the inventory, then rank endpoints and screens.
4. Ask the user two things: how to measure admin routes, and whether to prepare the timing middleware.
5. Build fixes in an isolated backend worktree, and in the Flutter tree for frontend changes. Run `npm test` (local Postgres 18 is
   running) and `flutter analyze` / `flutter test`.
6. Write the final report and publish it for the user.
