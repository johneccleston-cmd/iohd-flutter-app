# Integrity score design

> **Status 2026-11-10: ON HOLD.** The user wants to revisit this design before any plan or build. Live today is only
> the placeholder `integrityScore = max(0, 100 - 2 x missed completions)` on `/users` in the backend.

Status: awaiting John's review. Nothing here is built yet.

## Purpose

One score, used in reviews for every employee. Everyone starts at 100. Broken everyday promises and conduct
incidents lower it. Standout things win points back. It replaces today's placeholder (100 minus 2 per missed
completion, calendar year).

## The formula

Rolling 12 months, always between 0 and 100.

```
score = min(100, Reliability (0-70) + Conduct (0-30) + Recognition (0-10))
```

### Reliability (70 points)

The 70 points are split evenly across the promises for the person's role.

- At or above target: the promise keeps all its points.
- Below target: it loses 5% of its points for each percentage point under target, down to zero.
- Fewer than 10 chances in the window: the promise doesn't count yet and keeps full points.
- Nobody with no measured promises loses Reliability points.

| Role | Promise | Kept means | Target | Counts from |
|---|---|---|---|---|
| Techs | No callbacks | Job had no callback | 95% | 2026-10-05 |
| Techs | Stock checked out | No 4 PM strike, out of days with jobs needing stock | 95% | 2026-11-04 (strike reset) |
| Techs | Visits marked complete | Office didn't have to fix the visit | 98% | 2026-10-05 |
| Dennis | Cycle counts | Each zone counted once each month, early is fine | 95% | 2026-10-01 |
| Dennis | No callbacks | Job had no callback | 95% | 2026-10-05 |
| Bella | Callers reach a person | Answered live, or phoned back within 60 working minutes | 90% | 2026-03-07 |
| Bella | Unpaid invoices get notices | Unpaid invoice has a notice stage by day 30 | 90% | Launch day |
| Sales (Heather, Zac) | Estimates sent on time | Sent within 3 days, or 14 for Commercial Hard Bid | 90% | 2026-09-10 |
| Sales (Heather, Zac) | Estimates followed up | Sent estimate doesn't go quiet for 14 days | 90% | 2026-09-10 |

Warehouse strikes don't count toward any score. They stay on the KPI page.

### Conduct (30 points)

Starts at 30. An admin logs each incident with a date, a tier and a reason.

| Tier | Points |
|---|---|
| Minor | 1 |
| Moderate | 3 |
| Major | 8 |
| Severe | 15 |

### Recognition (up to 10 points)

Only wins back lost points, because the score is capped at 100. An admin logs each one.

| Event | Points |
|---|---|
| Five-star review naming the person | 2 |
| Manager kudos | 2 |
| Standout moment | 5 |

Recognition always shows on the profile, so someone already at 100 still sees it (for example "3 kudos this year").

### Excusing

An admin can excuse any missed promise or incident with a reason. It stays visible and scores nothing.

## Decisions

Made by John on 2026-11-04: rolling 12 months; clean record is 100; capped at 100; warehouse strikes don't count;
cycle counts are on Dennis; Dennis's promises and targets. John delegated Bella's promises to Claude ("do the best
thing"). The other targets, the conduct tiers and the recognition points are Claude's proposals.

## Data

| Promise | Source |
|---|---|
| Callbacks | Existing commission work days |
| Visits marked complete | Existing `commission_corrections.missed_completion`, over verified visits |
| Cycle counts | Existing `cycle_count_zones` |
| Callers reach a person | Existing `quo_activity`, same rules as Bella's missed-calls KPI |
| Estimates | Existing `job_status_history` and the sales KPI rules in `employee_kpis.js` |
| Stock checked out | New: the 4 PM audit must record every chance, not just strikes |
| Invoice notices | New: a daily check, because notice changes aren't logged anywhere |

Two new tables in the backend:

- `integrity_promise_results` (user, promise, day, reference, kept, excused by, excused reason): one row per chance,
  for the two promises with no history. The 4 PM audit writes stock rows. A daily job writes a notice row the day an
  unpaid invoice reaches 30 days.
- `integrity_events` (user, type, tier, day, points, reason, created by, excused by, excused reason): conduct and
  recognition.

`users.inventory_strikes` stays as it is for the existing strike displays.

## Backend

- New module `src/integrity.js`: one function takes a person and returns the score plus each part. It holds the
  promise list, targets and points in one place.
- `/users` keeps sending `integrityScore`, so the desktop and Android apps keep working without changes.
- New `GET /api/integrity/:userId` returns the breakdown.
- New admin routes add an event and excuse an item. Admin session only, with who and when recorded.
- Scores are worked out when asked for and cached like the other KPI responses. Keep the queries light: production
  memory is limited and heavy queries have caused trouble before.

## App

- Score breakdown on each person's KPI page: every promise with its plain-language label, rate, target and points
  lost, then conduct and recognition. A person's score must explain itself.
- Admin log on the Team screen: add a conduct incident or recognition, and excuse an item with a reason.
- Keep every existing KPI metric and animation.

## Testing

- Unit tests for the formula: on target, below target, floor of zero, under 10 chances, cap at 100, excused items.
- A test per promise using fixed sample data, including early cycle counts and Commercial Hard Bid estimates.
- A test that warehouse strikes never change a score.
- Render the KPI breakdown and Team admin log at several heights with no overflow.

## Estimated starting scores

Reliability only, using callback counts as of 2026-11-03. Other promises are at full points because they have no
misses or too few chances yet.

| Person | Callback rate | Estimated score |
|---|---|---|
| Brett | 95.7% | 100 |
| Andrew | 94.3% | 99 |
| Nick | 93.3% | 98 |
| Dennis | 92.9% | 96 |
| Daniel | 90.9% | 95 |

Bella is estimated at 98 on calls (about 89% against a 90% target). That figure combines two counts from different
dates, so it needs checking in the build. Heather and Zac aren't estimated yet.

## Open before launch

- Confirm Bella is the person who sends the 14, 30, 60 and 90 day notices. If not, drop that promise and put her
  70 points on calls, or choose another.
- Bella's notice promise starts clean on launch day, so older invoices don't count. About 40-50% of today's unpaid
  invoices over 30 days old carry a notice, measured from the job's end date. The build should use the invoice date
  if the synced invoices table has one.
- Tell staff how the score works before it goes live.
