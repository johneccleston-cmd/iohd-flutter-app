# Backend latency audit: report (2026-11-05)

Scope: API latency and app responsiveness for IOHD Office and the backend on Render.
Nothing has been committed, pushed or deployed. The changes below wait for your approval.

## 1. Overall assessment

The backend is not overloaded. Traffic is small (peak about 400 requests an hour), there were no 5xx errors from Nov 4 00:00 UTC
to Nov 5 14:00 UTC, and CPU minute peaks are about 0.13 of the 0.5 available. Dashboards and KPI pages are usually answered from
a warmed cache, so staff rarely wait on the slow path.

The things that actually cost staff time were:

- **The web app re-downloaded itself after every backend deploy.** The ETag on `main.dart.js` came from the file's modified time,
  and every deploy resets it. That is 1.70 MB per browser per deploy, and there were about 9 deploys on Nov 4. **Fixed (not deployed).**
- **Every app download was gzipped on the fly** on the 0.5 CPU. One production sample took 1.50 s with gzip against 0.71 s without.
  **Fixed (not deployed).**
- **The money and KPI endpoints are slow when not cached:** 0.5 to 1.1 s (table in section 3).
- **There was no per-endpoint timing at all in production**, so nobody could rank screens. **Fixed (not deployed):** timing middleware.

## 2. Endpoint inventory

- 151 route handlers in 31 files (counted from the code).
- Cached and refreshed by the warm-up: 8 dashboards, one KPI page per active employee, last week's payroll commission detail, and pending payroll.
- **Not finished:** the full per-route table (auth, query count, payload) was stopped to save usage. The timing middleware will
  give the real list of routes in use, with their times, after a few days.

## 3. Slowest endpoints (measured)

Source: the warm-up calls these one at a time and logs each arrival, so the gap to the next call is that request's full
server time with no cache. **29 cycles**, Nov 4 16:00-17:00 and 22:00-23:00 UTC, **before** the `8bf0055f` speed deploy.
P99 is not given because 29 samples cannot support it. Network time is not included.

| Endpoint | Mean | P50 | P95 | Max | Class |
|---|---|---|---|---|---|
| `/api/employees/bmiller/kpis` | 1,098 | 1,092 | 1,291 | 1,492 | Critical |
| `/api/commissions_stats` | 722 | 699 | 949 | 1,230 | Slow |
| `/api/payroll/commission-detail` | 626 | 606 | 776 | 1,199 | Slow |
| `/api/tech_stats` | 535 | 499 | 678 | 686 | Slow / Acceptable |
| `/api/dashboards/jobs` | 398 | 390 | 538 | 619 | Acceptable |
| `/api/financial_dashboard` | 390 | 386 | 450 | 703 | Acceptable |
| `/api/employees/gbaty/kpis` | 321 | 323 | 449 | 469 | Acceptable |
| Other KPI pages (5 people) | 66-221 | 77-210 | 99-358 | | Excellent / Good |
| Collections, sales, estimates, inventory dashboards | 15-113 | 8-100 | 73-180 | | Excellent / Good |

All figures are in ms.

- Brett's KPI page (1.1 s) costs 3 to 6 times more than any other tech's (0.17-0.32 s). The cause is not found yet.
- The 2 ms results for `ryan` and `jeccleston` are real. Those people have no KPI module, so the route runs one lookup (checked in the code).
- The short results for the sales, estimates and inventory dashboards look plausible (no hidden cache in the code) but are not proven.
- The largest single database statement (18% of all DB time over 7 days, mean 317 ms) is the `name_lookup` part of the commission
  engine (`commissionRules.js`). Commissions stats, payroll and commission detail all use it, and those are the three slow money
  endpoints the warm-up refreshed every 4 minutes. `8bf0055f` now runs the warm-up hourly outside office hours, which should
  cut this. Not re-measured.

## 4. Worst screen load sequences

**Not measured.** That needs either the timing middleware live or a real admin session; no token was minted or lifted from this machine.
What is known from the code and logs:

- The Calendar re-reads 3 months of visits every 5 minutes. It already paused when you switched pages inside the app, but kept
  going in a hidden browser tab or minimised window, which is the all-night polling seen in the logs. **Fixed.**
- The Quo panel polls every 15 s, but only while a conversation dialog is open. That is fine.
- Dashboards paint from the cache on first load.

## 5. Frontend communication problems

1. Calendar polling while hidden: fixed (above).
2. App re-download after each deploy: fixed (section 1).
3. About a third of office-hour responses were `204`s. No route returns 204, and `cors()` answers preflight `OPTIONS` requests with 204
   before the logger runs, so these are almost certainly CORS preflights. Staff use the app on the same origin as the API, so they
   don't pay these. The preflights most likely come from running the app locally (`flutter run -d chrome`).
   Added a 2-hour preflight cache (`maxAge: 7200`). The impact on staff is small.

## 6. Render findings

| Item | Finding |
|---|---|
| Plan | starter, 0.5 CPU, 512 MB, 1 instance. No CPU evidence for an upgrade. |
| Memory | Usually 220-310 MB. One instance jumped to about 420-445 MB at about 04:00 UTC on Nov 5 and stayed there for 10 hours, until the deploy. Cause not found. The new heartbeat line will catch the next one. |
| Health check | No path is set. Setting `/health` would stop Render sending traffic to an instance that hasn't finished booting. This is a Render config change, so it needs your approval. |
| Stability | 5 crashes (exit 1) from Oct 22 to Oct 29, none since. |
| Deploys | During a deploy, old and new instances both run the sync for a short time. Low impact; left alone. |
| Static files | `main.dart.js.map` (7 MB, your Dart source) is in `src/public`, and nothing in the code stops it being served. This is a security issue, not a speed one; it should come out of the published build. |

## 7. External integrations

- Service Fusion sync: before `8bf0055f` it overran its 1-minute slot. That deploy fixed the page-size parameter (`per-page`).
  The effect has not been re-measured.
- Stripe, Quo, Google and Anthropic call times: **not measured.** The new middleware counts axios calls (Service Fusion, Google) as `ext`.
  Calls made through `fetch` or SDKs (Anthropic, Stripe) still appear only in the total.

## 8. Improvements made (in a separate worktree, not deployed)

Patch: `C:\Users\opera\integrity-backend-latency\latency-audit-changes.patch`. It applies cleanly to `main` at `8bf0055f`.

| Change | Files | What it does |
|---|---|---|
| Request timing | `src/requestTiming.js`, `src/index.js` | One `⏱` log line per request with total, time to first byte, DB time and query count, outside-call time, wire and raw bytes, and cache hit. Signed-in callers get a `Server-Timing` header. A `🫀` line every minute reports memory, event-loop lag and pool waiting. Logging only: no response, status or permission changes. |
| Web app delivery | `src/staticAssets.js`, `src/index.js` | ETags come from file content, so a deploy with an unchanged build gets a 304. Each file is gzipped once and kept in memory (24 MB cap; `main.dart.js` is 1.7 MB). |
| CORS preflight cache | `src/index.js` | `cors({ maxAge: 7200 })` |
| Calendar polling | `lib/calendar_screen.dart` (Flutter) | Skips the 5-minute refresh while the tab or window is hidden, and catches up once on return. |

Payment, commission, inventory and financial logic were not touched.

## 9. Before / after measurements

| What | Before | After | Where measured |
|---|---|---|---|
| Server CPU per gzip download of `main.dart.js` | 141 ms (median of 5) | about 0 ms | This PC. Render's 0.5 CPU is slower, so the saving there should be larger (expected, not measured). |
| Download time, server side | 143 ms | 3 ms | This PC, loopback |
| Returning browser after a redeploy | `200`, 1.70 MB | `304`, 0 bytes | This PC, simulated redeploy |
| Backend tests | 253/256 | 256/259 | The same 3 failures before and after, on untouched code (callback rate, 2 payments list) |
| Calendar tests | 37 pass / 15 fail | 37 / 15 | The failures already existed (date-dependent); identical with and without the change |
| `flutter analyze lib/calendar_screen.dart` | | clean | |

**API latency before/after: none yet.** That needs the timing middleware deployed first.

## 10. Remaining recommendations, in order

1. **Approve the backend deploy** (apply the patch on `main`, commit and push). Expected effect: no app re-download after deploys,
   less CPU per page load, and real P50/P95/P99 per route within a day. Rollback: revert the commit.
   The heartbeat adds 1,440 log lines a day and the request lines one per request.
2. After 2 or 3 days of `⏱` lines, rank routes by P95 and by total time (frequency × duration). That ranking replaces section 3.
3. Brett's KPI page (1.1 s): use the `db=` split to see whether the time is in queries, then run a single read-only `EXPLAIN` on production.
4. Commission engine `name_lookup`: rewrite only behind an original-vs-new comparison test, since it is a money path.
5. `responseCache` re-serializes on every hit. Decide whether to store the serialized body once the `raw=` sizes are known, and
   only after the memory jump is understood (about 200 MB of headroom).
6. Remove `main.dart.js.map` from the published build. Set the Render health check path to `/health` (needs approval).
7. Later: brotli for `main.dart.js` (typically 15-20% smaller than gzip).
