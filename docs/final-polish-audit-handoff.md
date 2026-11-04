# Final polish audit: handoff

**Last updated:** 2026-11-04 (session 2, end)
**Status:** audit pass complete and reported. "Session 2 progress" below supersedes items 0-5 of "Still to do"; what is
left is listed under "Left for the user or a later pass".

## Session 2 progress (2026-11-04 afternoon)

- **The 10 test failures are fixed. All were stale assertions on wording changed on purpose:** Commissions titles and captions
  (metrics file); Financial, Commissions, Collections and Jobs captions; "a late answer" (the past-year Financial page no longer
  has a "Full year 2025" card, so it now checks "All of 2025" and no "Yearly projection"); "scorecards read as one phrase"
  (`Collected:`, no year in the title).
- **Goldens:** `dashboards_audit_render_test`, `sales_render_test` and `estimates_render_test` fail 24 of 24 on the
  pre-audit lib too, with the same 24 names (A/B copy in the session scratchpad), so they predate the audit. Not updated.
- **Shared kit, done and tested:**
  - `dashMonthStory`: "same months" now counts a finished month with $0 this year when last year had some. Only Sales
    passes `prior`. New optional `average` (callout measures against the chart's dashed line) and `points` (a rate says
    "N points under"). Jobs per job, Estimates avg value and Financial margin pass `average`; margin also passes `points`.
  - Bar labels within 9 px of the average line move to just above it (`dashboard_panels.dart`, after the prior-tick block).
  - `dashTrend` returns null when every point is zero. `_SparklinePainter` scales from min to max (positive lines unchanged).
  - `DashErrorPanel` takes `retryLabel` and a null `onRetry`. Sales KPI empty year: "Refresh" this year, no button for a past year.
  - Wording: kit key "Cash collected" and "Average month"; Commissions "Average month"; Technicians and Jobs/Estimates/
    Financial margin "Year average"; Technicians "on 2025, same months" (was "vs"); Bella's key "Average day"/"Average month";
    "all time" on Commissions and Financial pool captions.
  - Not done: `DashSplitPanel` separator option (cosmetic, skipped).
- **Tests:** 19 files, 546 of 546 passed (14:2x CT), including new tests in `dashboard_data_test.dart` and
  `sales_kpi_page_test.dart`. Analyzer: the same 23 pre-existing issues, no errors.
- **Web release build:** `flutter build web --release` succeeded (14:4x CT).
- **Production checks: all 12 ran (read-only, 2026-11-04 ~14:45 CT).**
  - **Lost statuses:** "Other" = plain "Lost" (31, $241,962) + "Lost - Other" (1, $554), 84% of 2026 lost value. The callout
    "no specific reason" stands. No "Lost - Timing" status exists, so that row never shows (zero rows are already dropped).
  - **Sent overcount:** refuted. No 2026 estimate sits at a no-quote status. Sent = 704; 32 of those are $0.
  - **Door styles:** 11 in 2026, plus "Unspecified" (46 sent), which isn't charted. The blank space under 5 styles is fixture-only.
  - **Reorder:** low 132 = empty 86 + low 46. Reconciles.
  - **Duplicate gaps:** 0. The table's PK dedupes, so the employee_kpis.js comment is right.
  - **Write-offs after today:** 0. **Duplicate job_id:** 0. **Future expenses:** 0. These queries aren't capped at today,
    which is latent only.
  - **Heather "left out":** prod has 8, all $0 won estimates. Fixed in the front end: `employee_kpi_sales.dart` no longer says
    "left out" when the unpriced won estimates carry no value. Tests cover both cases.
  - **Callback visits on non-completed jobs:** 0 of 10 since Oct 5. Latent.
  - **Actual / day denominator:** inactive Aaron 12 days. Jarred (no users row) and Zac (sales role + name exclusion) add 215
    weighted days whose profit is in the numerator, so the figure reads ~28% high (590 vs 817 days). User decision.
  - **Commercial pool:** both definitions give $448.29 today. Company pool: Financial -$10.92 (settled rule); Commissions'
    unused `company_pool` (commissions.js:166) has no settled filter ($512.05). Suggest one shared rule.
  - **Commissions chart vs card:** both $3,908.41. No gap today.
- **Visual reviews (two read-only agents, every shot) and the fixes made from them:**
  - Bar labels: my first "lift above the line" rule floated Jobs' Feb label 20 px over its bar. Replaced: a label the
    average line crosses stays on its bar and is drawn after the line on a white patch (`dashboard_panels.dart`).
  - Story callouts (`dash_story.dart` `_Callout`): when the finding doesn't fit, its trailing " · " parts drop whole
    instead of the text being cut mid-word (Bella "3 calls not called back · slo…", Financial "…$301.5k reven…").
  - **Financial now fits 1280x600 at 130% text without scrolling.** The fit rule assumed two-line expense rows; it now
    uses the real row height. That size is no longer excluded from `financial_dashboard_test.dart`.
  - Financial Net income: loss months red, keyed "Loss month" (new `DashSeries.below`/`belowLabel`).
  - Technicians: the Callback rate shows "—" on a year before tracking (it showed 2026's 6.9% beside "Counted from Oct 5,
    2026"). The Actual / day note is shortened so the toggle keeps its row.
  - Commissions: "Pay week Oct 12–18" (was cut at 130%); past-year empty note "No one was paid commission in 2025."
  - $0 shows ink, not red/amber: Estimates Lost value, Collections Written off / Outstanding / Over 90, Financial
    Not yet collected.
  - Sales person view: "of the team's sales" (was a dangling "of the team's").
  - KPI list and General page: server errors read "The server had a problem (error 500). Try again in a moment.", like
    the other KPI pages, with no "check your connection" hint; the list's empty-state Refresh is the green button.
- **Final run:** 19 files, 548 of 548 passed. Analyzer: same 23 pre-existing issues. Web release build OK.
- **Checked, not defects:** Jobs per-job $1,682 vs tile $1,597 is fixture-only (backend AVG = sum/count of the same
  jobs); Commissions 2025 "$0.00 locked" is the empty fixture (the pool is lifetime on the server).

### Technicians: Jarred out, Zac in (user decision, 2026-11-04)

The user: "don't factor Jarred into anything for the techs, not his profit either; Zac should be in it."
- **Backend (`integrity-backend/src/tech_stats.js`, saved, uncommitted; live on the next push):**
  - Every profit figure on the Technicians dashboard leaves out Jarred's day-weight share. That covers the year's
    profit, each month's profit and last year's overlay (`PROFIT_EXCLUDED_TECH_PATTERNS`, matched on the work-day row's
    tech name, since he has no users row).
  - New `fieldDaysMonthly`: the Work pace roster's days, plus Zac's install days (`FIELD_INSTALL_USERNAMES`: day weight
    above 0 and not an estimate, so his estimate visits don't count; marked complete from Oct 5), plus former techs' days.
  - `paceMonthly` (the Work days view against the roster's targets) is unchanged.
  - New test in `test/dashboard_metrics.test.js`. The suite gives 177 passed, 0 failed, 30 skipped.
  - SQL run read-only on prod: no fan-out (1,783 rows either way).
- **App (`technicians_dashboard_screen.dart`):** Actual / day divides by `fieldDaysMonthly` when the server sends it, and
  falls back to `paceMonthly` otherwise. The "Avg profit per tech" definition names Jarred's share as left out. Two new
  tests; the Technicians suite passes 37 of 37.
- **Prod 2026 so far:**
  - Profit $1,395,128 less Jarred's $46,954 = $1,348,174.
  - Days 590 + Zac 138 + Aaron (inactive) 12 = 740.
  - Actual / day goes from $2,365 to $1,822.
  - 2025 overlay: $1,511,571 less $14,493.
- **Still open:**
  - "Avg profit per tech" divides by the 4 active techs, though Zac's $216k share is in the profit.
  - About $86.7k of 2026 profit sits on jobs with no work days and stays in "company profit".

### Left for the user or a later pass (not fixed)
- **Kit-level, pre-existing:** on short charts (1280x600 at 130%) the story key gives up its row and the headline
  scales down (`DashStoryFrame`, FittedBox). Hits Sales, Estimates, Jobs, Collections, Commissions, Technicians pace,
  Bella. Fixing it needs a layout change, not a tweak.
- **Cut text at 1280x600 130%, pre-existing:** Estimates (lost callout, stale rows, pipeline buckets), Collections biggest
  balances, Sales KPI "Sent, awaiting…", "Inventory stri…", tile titles on 6-7 card rows (Zac, Dennis, Daniel, Brett).
- **Tech KPI:** streak flame missing at 1280x600 130% (all four) and at 1280x600 for Daniel (flair rule; no baseline for
  Daniel); bar labels collide with the rest-of-team markers.
- **Smaller:** Commissions compact list has no "Streak" heading and uneven hurdle-bar lengths; Estimates Avg view bar
  labels run together; Inventory "Stock received" chart has no callout; Warehouse 2025 "Cycle count zones · as of today"
  says "in 2025"; `DashSplitPanel` separator option not added.

To pick this up in a new session, paste:

> Read docs/final-polish-audit-handoff.md and continue the audit from "Still to do".

## First steps in a new session

1. Check nothing else is mid-edit: `git status --short lib test | head`. Other sessions share this tree.
2. Refresh how far each screen got (the table below goes stale):
   ```bash
   for f in reports_screen commission_dashboard_screen technicians_dashboard_screen inventory_dashboard_screen \
     sales_dashboard_screen estimates_dashboard_screen jobs_dashboard_screen collections_dashboard_screen \
     kpi_dashboard_screen employee_kpi_tech employee_kpi_sales employee_kpi_office employee_kpi_warehouse \
     employee_kpi_screen; do
     printf "%-34s %s\n" $f "$(diff --strip-trailing-cr build/audit_baseline/lib/$f.dart lib/$f.dart | grep -c '^[<>]')"
   done
   ```
3. Run `flutter analyze lib`. A reviewer may have stopped mid-edit, so fix any compile error first.
4. The reviewers can't be resumed from a new session. For any screen without a report below, read its diff against
   the baseline, then finish it using that screen's checklist.

## Baseline

| What | Where |
| --- | --- |
| `lib/` before any audit change | `build/audit_baseline/lib/` |
| Screenshots before any change (284 PNGs) | `build/audit_baseline/shots/` |
| Baseline test output | `build/audit_baseline/baseline_tests.txt` |

`build/` is git-ignored, and `flutter clean` deletes this folder. Don't run it until the audit is finished.

Baseline result: **481 of 481 passed** across the 18 dashboard and KPI test files. The command is under "Still to do".

## Where each screen stands

"Lines" is changed lines against the baseline at 12:49 CT. "reported" means its reviewer stopped and reported, not that the screen is finished: most were told to wrap up early.

| Screen | File | Lines | Report |
| --- | --- | --- | --- |
| Financial | `lib/reports_screen.dart` | 193 | reported |
| Commissions | `lib/commission_dashboard_screen.dart` | 368 | reported |
| Technicians | `lib/technicians_dashboard_screen.dart` | 205 | reported |
| Inventory | `lib/inventory_dashboard_screen.dart` | 143 | reported |
| Sales | `lib/sales_dashboard_screen.dart` | 120 | reported |
| Estimates | `lib/estimates_dashboard_screen.dart` | 106 | reported |
| Jobs | `lib/jobs_dashboard_screen.dart` | 178 | reported |
| Collections | `lib/collections_dashboard_screen.dart` | 117 | reported |
| Tech KPI (Andrew, Nick, Brett, Daniel) | `lib/employee_kpi_tech.dart` | 169 | reported |
| Sales KPI (Heather, Zac) | `lib/employee_kpi_sales.dart` | 192 | reported |
| Office KPI (Bella) | `lib/employee_kpi_office.dart` | 87 | reported |
| Warehouse KPI (Dennis) | `lib/employee_kpi_warehouse.dart` | 186 | reported |
| Team KPIs list | `lib/kpi_dashboard_screen.dart`, new `test/kpi_list_fit_test.dart` | 99 | reported |
| General KPI page (John) | `lib/employee_kpi_screen.dart` | 91 | reported |

## Shared changes already made

These are in the tree but **not yet covered by a test run**.

- **Average lines:** `dashAverageLine` (`lib/widgets/dash_story.dart`) is now slate (`DashUi.subtle`), matching
  `DashMonthChart`. It was amber, which reads as a warning.
- **Best month:** new `dashBestMark` keeps the amber for the best-month diamond. The Technicians flames use it too.
- **KPI charts:** `_MonthlyChart` in `lib/employee_kpi_screen.dart` and `_dashedKey` in `lib/employee_kpi_office.dart`
  use those two constants. `_amberLine` is gone.
- **Split panels:** `DashSplitPanel` says "mostly X" only for a majority and "led by X (41%)" otherwise. The gap before
  the finding is tighter. Collections has its own copy of this wording, on the Collections checklist below.

## Reviewer reports

Each reviewer tested only its own files. The lead has not re-run anything, and the test counts below are the reviewers' own.

### Sales KPI and Office KPI

Reviewer's tests: 95 of 95 passed (sales 49, office 46). Analyzer clean on the 5 files it covered.

**Done**
- Sales: plainer captions and chart keys; "Hard bids won" and "Other commercial won" titles; the Open estimates panel no
  longer repeats one fact four times; the dollar bar shortens to "Moving"/"Quiet" at 130% so amounts aren't cut.
- Sales defect fixed: the Mix callout said "Most are..." at exactly 50%. It now says "Most" only above half.
- Office: moved to the shared `DashStoryFrame` and keys; shorter chart keys; the Missed calls headline shows one decimal
  (62.5%) so it can't read as the year's 62.2%; removed the "Goal: within an hour" key, since the line is labelled.
- `test/office_kpi_fixture.dart` now uses the Collections stages, so the two pages' renders agree.

**Checked, no defect:** Bella and Collections read the same rules (`STAGE_SQL`, `RECEIVABLE_WHERE`, `CASH_TYPES`). The
$83,600 vs $83,575 gap was fixture data only.

**Needs the user's review**
- Heather's ring centre now shows the open count. The big red "93% gone quiet" no longer shows by default; 93% appears
  once, in the Stale row. The standing rule says flair stays, so ask whether they want it back.
- The "9 left out" wording on the Gross profit caption is the reviewer's own choice. The optional production check
  below would confirm it.

**Optional production check**
```sql
SELECT status, COUNT(*), SUM(total_revenue) FROM jobs
WHERE is_estimate AND COALESCE(total_profit,0)=0 AND LOWER(TRIM(opportunity_owner))='heather vera' GROUP BY 1;
```

**Proposals for shared files:** give `DashErrorPanel` a retry label option ("Try again" is wrong on an empty past year);
`_KpiTile` cuts "Inventory strikes" at 130% on Zac's seven-card row.

**Left unchanged:** collection rate is always green whatever its value; the Open estimates panel mixes $1.4M with
$1,510,225; the close rate headline says "won" twice; "Sent, awaiting ..." is cut at 130%; the short stage name
"Checking" is ambiguous; past-year caption "Current year only" could show that year's cash.

**Not re-viewed after final edits:** Heather at 130%, 2025 past years, 1366 and 1500 sizes (fit tests pass), Bella's
response callout at 130%.

### Tech KPI

Reviewer's tests: 72 of 72 passed in `test/tech_kpi_page_test.dart`, with new fit tests for Daniel and Brett at all 7
sizes. Analyzer clean on its 3 files. Stopped early at the lead's request.

**Done**
- Inv. strikes no longer shows red for everyone. It now follows the callbacks rule (amber more, green fewer, ink within
  5%). This also fixed Nick's 25 showing red above a green "Ahead" chip.
- Chart headline reads "below the rest of the team, Jul–Oct ($1,849)", so it can't be mistaken for the Sep-vs-Aug chip.
- Callout names the months: "Behind the rest of the team in Aug ($1,083) and Sep ($408)". With 3 or more months it says
  "best full month" when a short month is taller.
- "$366 average per labor job"; "Most:" became "Highest:" on the team tile.
- No flat sparkline on an all-zero year; the Jobs view's work-days line starts at the tech's first month.
- Empty reviews collapse to a one-line strip and the team table takes the height.
- Daniel's dark tile keeps its bars at 1280 with six tiles.

**Defect fixed:** an empty year showed the pooled row as "— / 0 days", because `sameMonths` has no months. It now falls
back to the team's whole year.

**Checked by hand, correct:** $755, $1,849 (336,499.89 ÷ 182), 59%, 62%, the 27 avg and the callback pools. Past-year
captions traced through `tech_stats.js` are truthful.

**Shared widgets it changed, so other pages must be re-tested:** `_ReviewsCard` (compact only below `height(g,1)`),
`_TileSpec` (`captionFor` refactor, new `captionWidth`), `_KpiTile` (bars logic). Office, sales and warehouse tests have
not been run since these changes.

**Needs the user's decision**
- "Rank #1" and the gold ring show on everyone because integrity is tied at 100, next to "Ranked 4th of 4". This is the
  shared `_HeaderBadges` widget. Rewording it to name integrity would help.
- Andrew's 29 is amber while Brett's 29 is ink on the same page, a side effect of the callbacks rule. It's explained in
  the hover, but a single reference may read better.
- The dark team tile's accent is amber whatever the value, which sits awkwardly with the amber-means-a-problem rule.

**Proposals for shared files:** `dashTrend` (`dashboard_kit.dart:911`) should return null when every point is zero, since
dashboards get the same flat line; office and sales could adopt `_ReviewsCard.emptyHeight`.

**Left unchanged:** at 130% with six tiles, titles are still cut ("Completed jobs w…", "Service call conve…") and the
labor caption falls back to "Labor ÷ days worked", losing the comparison. "Only Aug is a whole month so far" (kit
wording) can still sit beside a short month's bar. "Strike" is kept here because the team total double-counts two-tech
jobs, while the Technicians dashboard says "callbacks".

**Not viewed:** the final callout wording in a render, including 1280x600 at 130% where the old wording was cut. Old-server,
no-callbacks and Nick 2025 were seen at baseline only.

### Sales and Estimates dashboards

Reviewer's tests: 38 of 38 passed in `test/sales_dashboard_test.dart` and `test/estimates_dashboard_test.dart`, 5 of them
new. Analyzer: no errors or warnings on its 4 files.

**Done: Sales**
- Shorter captions; Win rate and the month tooltip show "—" / "None decided" instead of a misleading 0%.
- Past-year hovers say "dated in 2025". Largest now shows whole dollars. The Lost count is ink, not red.
- Win-rate bars are one colour (the thresholds were arbitrary, with no target or key).
- Removed the 10-style cap, which hid styles 11-13 entirely.
- The team moves over the door styles whenever every style fits there, removing the blank panel from 1280x720 to 1500x800.

**Done: Estimates**
- Defect fixed: the Win rate sparkline plotted won ÷ sent while the tile is won ÷ (won + lost). It now uses
  `closed_count`, which the backend already sends.
- Defect fixed: the age drill-down was labelled with the selected year though it covers every year. It says "As of today".
- Defect fixed: "10 quotes 14+ days old" sat beside "31+ days · 602" because stale also needs $1,000+. The note now says so.
- Zero reasons dropped ("Timing $0 0 lost"). "Unresponsive $0 1 lost" stays, since it is a real estimate.
- Chart headlines show amounts ("$1,695,000 won so far"), so nothing competes with the 87.9% tile.
- Callout reads "83% of lost value has no specific reason".
- Removed the change chip on Value and Count, because with two series "↑ 4%" can't say which moved. The Avg view keeps it.
- Removed "Nothing is closed or changed here." from the Open value hover. It may trace to the approved Oct 22 pipeline
  rule, so restore it if the user wanted it.

**Failures to investigate first.** `test/dashboard_metrics_test.dart` and `test/dashboard_screens_test.dart` were still
failing, 10 listed by name plus "... and 6 more" that weren't reviewed:
- 4 Commissions metrics tests, and the collections, commissions, financial and jobs caption cases. Other reviewers were
  editing those screens at the time, so these may just need their assertions updated.
- "a late answer for the year you left": cause not confirmed.
- "scorecards read as one phrase" (`dashboard_screens_test.dart:345`): cause not confirmed, could involve the caption
  changes.
- These suites passed at baseline, so each failure must be explained, not assumed stale.
- The reviewer also edited 3 strings in those two files for the intended new text (`dashboard_screens_test.dart:146, :191`,
  `dashboard_metrics_test.dart:212`).

`sales_render_test` and `estimates_render_test` show 15 golden failures. The one golden checked dates from Oct 7, before
the redesign, so they look stale, but pre-change code was not run against them. No goldens were updated.

**Needs a decision**
- "Sent" may overcount: `st != 'estimate requested'` (`sales.js:114`, `estimates.js:91`) includes Estimate Site Check,
  though the hover says a quote was given.
- A 14-day-old estimate is both in "8-14 days" and stale (`STALE_MIN_DAYS` = 14). Left as is, since changing it alters a
  definition.
- "Other" row label stays until the production check on lost statuses is read.

**Proposals for shared files**
- `dashMonthStory`: the "same months" comparison skips months with $0 this year, which flatters the change. Count them
  when `prior[i] > 0`. This one affects numbers, so treat it as a likely defect.
- `DashSplitPanel`: a separator option, so "today" can go back to note style on Estimates.

**Left unchanged:** about 200 px stays blank under 5 door styles at 1920x940 and 1500x800 at 130% (whether production shows
it depends on how many styles exist). At 1280x600 with 130% text the lost callout, stale title and callout, and age finding
are still cut, as at baseline.

**Not viewed after changes:** Estimates Count view, Sales 2025, 1280x720, 1500x800, empty and loading shots, Estimates 1366x768.

### Technicians and Inventory dashboards

Reviewer's tests: 54 of 54 passed in their two test files. Analyzer clean on those four files.

**Done: Technicians**
- Ranking ties break by revenue, so the order is stable.
- Years before tracking no longer say "No completed jobs since Oct 5, 2026" (false for 2025). They read "Counted from
  Oct 5, 2026", with a "by revenue" note and an honest finding.
- "Callbacks" column is now "Callback rate". Hover tips on all three columns; Jobs says callback visits, site checks and
  deliveries are included (the honesty fix for Andrew's 144 vs 103, definition unchanged).
- Actual / day callout uses finished months only. Work days callout no longer says "still to work" for a finished year.
  "on 2025" became "vs 2025, same months".
- Work pace compact head and key fixed at 1280x600 with 130% text (the key had scaled to about 9 px).

**Done: Inventory**
- Category rows fill the panel at 1366x768 and 1920x940, and bars thicken from 8 to 14 px.
- Accuracy caption "41 of 45 counts matched · 2026". The empty state is "Starts with the next count", because accuracy is
  tracked now and "Not tracked yet" was untrue.
- Stock movement empty state shortened. Tile row is shared by need, fixing cuts at 130%.
- Title is "Fewest inventory strikes · all time", because the server sends only 3.

**Checked, correct:** "Per tech ÷ 20 days a month" (divisor is 240 × share of the year, `tech_stats.js:443-447`); "5 ÷ 72"
matches the backend fields; accuracy uses the same query as the KPI page.

**Backend issues, not fixed (the user decides)**
- `callback_visits` (`commissionRules.js:749`) doesn't require a completed status while `callback_jobs` does, so a callback
  on a reopened job counts on top only.
- Actual / day: profit is by job start month and work days by date worked, so recent months read low.
- Actual / day and Work days use active users only (`tech_stats.js:390-396`) while profit is company-wide, so a departed
  tech's days drop out but their profit stays.

**Left unchanged:** 2025 Callbacks view at 1500x800 has blank space; Work pace shows 3 of 5 rows at 1280x600 with 130% text;
past-year work-day targets use today's roster.

**Not viewed after edits:** 1000x700, loading, error, 2025 Work pace.

### Jobs and Collections dashboards

Reviewer's tests: 47 of 47 passed in their two test files. Analyzer: 2 infos on untouched lines.

**Done: Jobs**
- "Quick insights" is now "Job mix · completed jobs, 2026", holding the two splits with bars. "Busiest month" and "Jobs a
  month" left the strip and stay on the chart's Completed view.
- "Active open jobs" is now "Active jobs". Past-year wording fixed ("in 2025", not "all of 2025").
- Definitions name the completed statuses. This hard-codes `statusRules.js` into app text, so it goes stale if that list
  changes.

**Done: Collections**
- Titles are "Collected" and "Written off", with the period in each caption. Shorter captions keep the trend lines.
- `_VsPrior` replaced by the shared `DashChangeChip`: "6% on 2025, same dates". "mostly" only above 50%. Link reads "All 209".

**Defects fixed:** "1 days" age text; "by ach" in the payment tooltip; "mostly" for a minority share.

**Checked, correct:** the year-on-year chip compares the same dates (-5.9%); average month, stages, top 5 and write-offs sum
correctly in the fixture.

**Not fixed**
- Per job chart: the dashed line is the weighted $1,682, the callout's average the $1,699 mean of months.
- Ticker "overdue" counts days since work finished, so a job finished 4 days ago reads "4 days overdue". `collections.js`
  documents this as deliberate, but the label misleads. The user decides.
- Bar labels colliding with the average line, and Collections' wordy chart key (both need shared-file edits, listed in
  "Still to do").

**Not viewed:** Collections 1280x600 after the final wording, Jobs 1000x700, all past-year states.

### Warehouse KPI, Team KPIs list, General page

Reviewer's tests: 40 of 40 in the warehouse file; 187 of 187 across the tech, office, sales, list-fit and general files, which
also covers the shared-widget changes from the Tech KPI report. Analyzer clean on the files it covered.

**Done: Warehouse**
- Captions: "Under the 95% target", "86 empty · 46 low" (adds up to 132), "2 past due · $18,421", "Dennis 15 + techs 5, all time".
- Accuracy callout shortened to "On target in 2 of 7 weeks · latest week 0.9 points under target".
- Zones stay rows up to 84 px each, then become a 2x2 board. Icons, ripples and hover tints are kept.

**Done: Team KPIs list**
- Hover definitions on all four cards, sentence-case labels, "Average tenure", and a fix for overflow at 130%.
- Team integrity colour now matches the cards (visible for an average below 90: 80-89 blue, under 80 gold).
- New `test/kpi_list_fit_test.dart`, 11 tests.

**Done: General:** cards centred, failed load uses `DashErrorPanel`, tighter copy. Still light, because nothing more is
recorded for an admin.

**Correction to the brief:** `/users` no longer hardcodes integrity 100. `src/index.js` ~209 computes
`GREATEST(0, 100 - missed*2)`, and the hover matches. The brief's "known fact" is out of date.

**Needs the user's decision**
- "of 160 item counts matched" no longer shows on Dennis's tile at 1500. The 160 stays in the Accuracy headline and hover,
  but the chart cycles away. Check this against the keep-every-metric rule.
- With ties, about 7 people show Rank #1 with a gold ring on the list. Truthful, but gold loses its meaning.

**Proposals:** `_AccuracyTrendChart` spaces weeks evenly, so a week with no counts vanishes from the axis (space by date).
`employee_kpis.js` topMisses comment says "first count of each item per period" but the SQL has no dedupe.

**Left unchanged:** zone cells are airy at 1920x940; gap above the fix cards at 1500x800; Stock levels callout cut at 1280x600
130%; list hero cards have no captions; `test/warehouse_kpi_fixture.dart` contradicts itself (`cycleDone` 2 vs "12 of 15").

**Not viewed:** warehouse 1920 final caption, new empty state, Cycles view, `general_john_error`, list loading/error/empty.

### Financial and Commissions dashboards

Reviewer's tests: 46 of 46 passed in their two test files, 6 of them new. Analyzer clean on those four files. **No render was
viewed after these edits**, so both screens need a visual check.

**Done: Financial**
- "Outstanding (all jobs)" is now "Not yet collected", caption "2026 jobs, finished or not". Definition unchanged.
- "YTD" is gone; captions use `dashPeriodLabel`.
- Past years drop the projection card, because the server sends the same figure as card 1. The page shows 4 cards.
- "8 categories" removed; the expenses note reads "$929,140 in 2026" ("YTD" couldn't be proven: expenses aren't cut off at
  today, `financial_dashboard.js:225-226`).
- "Paid pay weeks" is now "Set aside from jobs". The dashed lines at 1920 were the kit's no-data placeholder, so a line now
  draws only from real readings.

**Done: Commissions**
- Tiles: "Locked retainage", "Average per person", "Commission ÷ revenue". A test confirms no card title or caption is cut
  at any size, including 1280x600 at 130%.
- Cents on every pay amount, so the chart headline matches Total payouts.
- "1 of 4 cleared" is now "1 of 4 past the $750 hurdle this week". A "Streak" heading sits over the flames.
- Not-yet-cleared hurdle bar is slate, not amber. Chart rebuilt on `dashMonthStory`; note "finalized payroll, since Oct 5".
- "Nothing scheduled" is now "Nothing due yet". The clock shows as many chips as fit at full size.

**Defects fixed:** "Best month" with one finished month (would have appeared once a November pay week was finalized); chart
total summed positive months only; "yet" on past years.

**Backend issues, not fixed**
- Commercial pool has two definitions: Financial uses the job's close-week run (`financial_dashboard.js:123-137`), Commissions
  a settlement item (`commissions.js:160-167`). Use one rule.
- The chart can exceed the card: the chart sums all non-sales lines (`commissions.js:67-75`), the card only listed users
  (`commissions.js:351`).

**Needs the user's decision**
- **Financial at 1280x600 with 130% text still scrolls, and its fit test excludes that size, so the no-scrolling rule is unmet
  there.** This predates the audit.
- The glowing seconds chip probably drops out around 1280 wide, and only "160d" shows at 1280 with 130% text. That loses motion.
- "Not yet collected" stays amber to match Collections, though much of it is normal unbilled work.
- The finding line reads "Top: Alex Rivera, 52% · 1 of 4 past…"; "of payouts" was cut to fit 130%.

**Proposals:** `_SparklinePainter` floors `maxV` at 0, so negative readings draw the placeholder or run off the box. The company
pool can go negative, so scale from min to max. `generate_fixtures.js` `nextDisbursement.date` is stale.

**Note:** the caption "Commercial · all-time" still has the hyphen; the standard is "all time".

## Combined test run

Run once after all reviewers stopped, across the 19 dashboard and KPI test files: **531 passed, 10 failed**. The baseline was
481 of 481 on 18 files, so these failures are new and must each be explained. `flutter analyze lib`: 23 issues, no errors.
Full output: `build/audit_baseline/after_tests.txt`. `flutter build web --release` has not been run.

The failures are all in `dashboard_metrics_test.dart` and `dashboard_screens_test.dart`. These test files weren't owned by any
reviewer, so stale wording is the likely cause of most, but that isn't confirmed for all of them. The 10 are: 4 Commissions tests
in the metrics file; the collections, commissions, financial and jobs caption cases; "a late answer for the year you left"; and
"scorecards read as one phrase".

## Still to do

0. **Do these first; they come out of the reviewer reports.**
   - **Test failures.** See "Combined test run" below, then fix each failure. Stale assertions already identified:
     - `test/dashboard_screens_test.dart`: `:161` to `'Invoiced, unpaid · today'`, `:173` to `'From any year · today'`, and the
       `:350` regex `^Collected 2026:` to `^Collected:`.
     - `test/dashboard_metrics_test.dart`: lines 87, 89, 90, 98, 100, 102, 116, 158 use old Commissions text. New text: "Average
       per person", "5 on the job pool · 2026", "4 on the job pool · 2026", "Commission ÷ revenue", "Jobs closed Oct 5–18",
       "Locked retainage". Lines 115 and 157 use `findsNothing` on an old title, so they now pass without testing anything.
     - "a late answer for the year you left" and "scorecards read as one phrase" had no confirmed cause when reported. Find it.
   - **Goldens.** `dashboards_audit_render_test`, `sales_render_test` and `estimates_render_test` fail. Check whether each
     failed before the audit. Never update goldens to clear them.
   - **Likely defect, shared kit.** `dashMonthStory` (`dash_story.dart`): the "same months" comparison skips months with $0 this
     year, which flatters the change. Count them when `prior[i] > 0`.
   - **Shared wording.** `dash_story.dart:997` says `on ${year - 1}, same months`; Technicians now says "vs". Pick one
     (`test/sales_dashboard_test.dart:141` asserts the old text). `dash_story.dart:312` "Cash received that month" to "Cash
     collected"; `:322` "Average of the finished months" to "Average month".
   - **Bar label collision.** `dashboard_panels.dart` ~:2142, after the prior-tick block: if the label sits within 9 px of the
     average line, move it to `y(avg) - 10`. Untested.
   - **Smaller shared proposals.** `dashTrend` returns null when every point is zero; `_SparklinePainter` scales from min to
     max; `dashMonthStory` takes an optional `average`; `DashErrorPanel` gets a retry label; `DashSplitPanel` gets a separator.
   - **Visual check.** Financial and Commissions have had no render viewed since their edits. Each report lists what else
     wasn't viewed.
   - **Production checks: none have been run.** The Render connector stopped working mid-session (404), so reconnect it first.
     - Lost statuses: `SELECT status, COUNT(*) FROM jobs WHERE is_estimate AND LOWER(TRIM(status)) LIKE 'lost%' GROUP BY 1;`
       (is "Other" really no reason?)
     - Sent overcount: `SELECT status, COUNT(*) FROM jobs WHERE is_estimate AND start_date >= '2026-01-01' GROUP BY 1;`
     - Door style count on 2026 team estimates, using `DOOR_TYPE_SQL` and `DOOR_LINE_WHERE` from `sales.js`.
     - Reorder: among active `inventory_items` with a reorder point, low stock should equal empty + low.
     - Duplicate gaps: `SELECT item_name, COUNT(*) FROM cycle_count_results WHERE system_qty<>counted_qty AND counted_at>='2026-01-01' GROUP BY 1 HAVING COUNT(*)>1;`
     - Write-offs dated after today should be 0, and `SELECT job_id, COUNT(*) FROM jobs GROUP BY 1 HAVING COUNT(*) > 1;` should be empty.
     - Future expenses: `SELECT COUNT(*), COALESCE(SUM(amount),0) FROM expenses WHERE expense_date > CURRENT_DATE;`
     - "9 left out": `SELECT status, COUNT(*), SUM(total_revenue) FROM jobs WHERE is_estimate AND COALESCE(total_profit,0)=0 AND LOWER(TRIM(opportunity_owner))='heather vera' GROUP BY 1;`
     - Callbacks on non-completed jobs since Oct 5; work days lost to inactive users; the two commercial pool definitions;
       chart vs card payouts. Build these from the backend lines named in the reports.
1. Get every screen in the table to finished, using the checklists below.
2. Run any production number checks the reviewers ask for. Rules:
   - Read-only SQL only, one light query at a time. The production database has run out of memory during probes.
   - Use `query_render_postgres`. The IDs are in the `iohd-backend-and-render` memory.
   - **Don't call the live dashboard API to check numbers.** Loading a dashboard writes snapshot rows, and the brief
     says not to modify production data.
3. Cross-screen consistency pass:
   - Average key wording differs: "Monthly average", "Average month", "Year average", "Average revenue", "Average".
   - Period wording: "Jan 1 – today" via `dashPeriodLabel`, not "YTD". Check past years too.
   - "all time" with no hyphen.
   - View all the screens side by side at 1366x768.
4. Line endings were restored to CRLF at the end of the first session; recheck any file edited since.
5. Validate, and compare against the baseline:
   ```bash
   flutter analyze lib
   flutter test test/collections_dashboard_test.dart test/commission_dashboard_test.dart \
     test/estimates_dashboard_test.dart test/financial_dashboard_test.dart test/inventory_dashboard_test.dart \
     test/jobs_dashboard_test.dart test/sales_dashboard_test.dart test/technicians_dashboard_test.dart \
     test/dashboard_data_test.dart test/dashboard_metrics_test.dart test/dashboard_screens_test.dart \
     test/dashboard_shots_test.dart test/general_kpi_page_test.dart test/office_kpi_page_test.dart \
     test/sales_kpi_page_test.dart test/tech_kpi_page_test.dart test/warehouse_kpi_page_test.dart \
     test/dash_hover_card_test.dart test/kpi_list_fit_test.dart
   flutter build web --release
   ```
   Re-render and look at the changed screens at every size, including 130% text. Renders land in `build/dash_shots/`.
6. Send the final summary. It must contain: every screen audited; specific improvements; numerical or logical issues
   found and corrected; visual consistency improvements; tests run and results; remaining failures or concerns; files
   modified.

**Don't:** commit, push, deploy, change production data, edit `C:\Users\opera\integrity-backend` (saved backend edits
can go live within a minute), update goldens, or run `dart format` on a whole file.

## Per-screen checklists

These are the problems seen in the baseline renders. Verify each one, fix what's real, and expect to find more.

**Financial**
- "Outstanding (all jobs)" has the caption "Unpaid · 2026 jobs", which contradicts it. Label what it really is.
- "YTD" in captions and the expenses header: check past years.
- "Company pool $17 / Paid pay weeks" is cryptic.
- Dashed filler lines beside the pool labels at 1920x940.
- "8 categories" note; expense rows spread apart at large sizes.
- The change chip appears at 1920 but not at 1366.

**Commissions**
- Tile titles and captions cut off at 1280x600 with 130% text. Use shorter, plainer wording.
- "Nothing scheduled" sits beside a running countdown under "Retainage release".
- "1 of 4 cleared" and the flame counts have no explanation.
- Cents here, whole dollars elsewhere: decide what's right and keep it consistent within the screen.
- "by pay week" over monthly bars.
- "Paid ÷ 5 on the job pool" caption.

**Technicians**
- Confirm "Per tech ÷ 20 days a month" is really how the tile is computed.
- Check "5 ÷ 72 completed jobs since Oct 5" against the backend.
- "Revenue 2026" must follow the year picker.
- The Jobs column counts callback-only visits (open user decision). Keep the definition, make the label honest.
- Work pace wording at 1280x600 with 130% text.

**Inventory**
- Blank space under "Value by category".
- Wordy "Stock movement" empty state.
- Two "Not tracked yet" tiles: a real `accuracyPct` from the backend must render properly.
- "all-time" should be "all time".

**Sales**
- The team table mixes "$703,107" and "$38.6k".
- Blank space under "Door styles".
- Wordy tile captions.
- Red "18" lost count: is the colour meaningful?
- Won revenue / Win rate vs the KPI page's Sales won / Close rate is an open user decision. Leave the names.

**Estimates**
- "312 before 2026": 312 of what?
- Lost reasons rows at zero.
- 41% of value won vs the 87.9% win rate must not be confusable.
- Two "·" segments in the pipeline header.

**Jobs**
- "Quick insights" is a generic heading, and two of its items repeat the chart. Keep the Install/service and
  Res/commercial splits.
- Bar labels collide with the average line.
- Past-year wording on tiles.

**Collections**
- `_methodsFinding` needs the same majority rule as `DashSplitPanel`.
- Wordy chart key.
- "Collected 2026" title; past-year state of every tile and panel.
- Check "6% vs 2025 to date" compares the same months.

**Tech KPI**
- Every "Inv. strikes" figure is red, so the colour means nothing.
- Change chip and headline carry two different comparisons in one header.
- "both full months · best: Aug" sits beside a taller Jul bar.
- Plain wording in tile captions, including a past year.
- Large empty reviews panel.
- Check Daniel, Brett and the loading, error, empty-year and old-server states.

**Sales KPI**
- Open estimates states the same "gone quiet" fact four times. Keep every metric and the donut.
- "Profit on it" key.
- "42.8% · on 168 of 177 won" caption.

**Office KPI**
- Wordy chart keys.
- Confirm Bella's stage figures and Collections read the same source in production.
- Check definitions and past-year wording.
- Keep the "Scheduling errors" tile.

**Warehouse KPI**
- Zone rows spread far apart.
- Tile captions, including a past year.
- Long Accuracy callout.

**Team KPIs list**
- Had no baseline screenshots, and `test/kpi_list_render_test.dart` goldens are stale. Use the new fit test.

**General page**
- Check it isn't sparse or generic.

## Appendix: the full reviewer brief

The user's request, standing rules and known data facts. Standing rules win over the request's wording.


You are one of several reviewers doing the final quality pass on the IOHD Office Flutter app (C:\iohd_desktop) before
its dashboards and KPI screens are called finished. Each reviewer owns a few screens. Read this whole brief, then the
project's CLAUDE.md, then do the work for your screens.

### What the user asked for (their words, condensed)

"One final, comprehensive audit and refinement pass across all KPI screens and all 7 business dashboards. Bring every
screen to a polished, cohesive, professional, production-ready standard. Identify and fix anything unfinished,
awkward, inconsistent, unnecessarily complicated, visually weak, or like generic AI-generated UI. This is NOT a
redesign: preserve the current visual direction and improve what is already there."

Look for and fix: generic/unnecessary headings; redundant labels that repeat what context already says; wordy or
awkward chart titles, legends and captions; explanatory text that adds nothing; excess containers/borders/dividers;
inconsistent spacing and alignment; decorative elements that only fill space; awkward empty space or crowding;
over-complicated metric presentation; robotic or unnatural wording; unnecessary badges/pills; inconsistent
capitalization, terminology and number formatting (e.g. one table mixing "$703,107" and "$38.6k").

Data accuracy: verify every displayed number against its source (Flutter parsing + the backend SQL), calculations and
percentages, totals, date ranges/reporting periods (does a past year still say "YTD" or "today"?), comparisons and
trends, chart data vs labels, KPI definitions, empty and zero handling, and whether a label truthfully describes what
the number means. Look for misleading metrics and wording that could make an office employee misread a number
(e.g. "mostly X" for a 41% share). Do not change business logic or KPI definitions to make things look better; fix
real defects at their source; never fabricate or approximate data.

Charts: is it useful, is the title immediately understandable, axes/labels clear, legend needed, colours consistent,
right takeaway, unnecessary labels? Simplify without losing information.

Execution rules: actually make the improvements. No redesigns of what works, no change for change's sake, no removing
useful information, no new features, no permission/security changes, no commits/pushes/deploys/prod writes, never
update goldens to make tests pass. Prioritise meaningful improvements over cosmetic churn. Stop when your screens are
genuinely polished; don't manufacture work.

### The user's standing rules (from past sessions; these win over the brief's wording)

1. No vertical scrolling on dashboards or KPI pages at the desktop sizes 1280x600, 1280x720, 1366x768, 1500x800,
   1920x940, plus 1280x600 and 1500x800 at 130% text. Never fix fit by shrinking text or hiding meaningful content.
   Section headings that cost a row of height are unwelcome; period cues go in panel titles (" · today").
2. KPI pages (employee pages): keep EVERY metric already on screen and every animation/flair (count-ups, sparklines,
   flames, heartbeat, ring fills, confetti, auto-cycling charts, staggered entrances). Restyle or reword; never delete a
   metric. (Removing a pure duplicate of the same number in the same panel is OK if the metric stays visible.)
3. Scorecards explain themselves: label + big value + plain caption; full definition in the hover card
   (`DashHoverCard`, never a plain Tooltip for scorecards).
4. Charts tell a story to someone who doesn't know the business: headline in words/numbers, a callout with the main
   finding, plain labels, a key when colour carries meaning, never colour alone.
5. Tabs/segmented controls: selected label is ink (`DashUi.ink`), never blue; tab controls in a panel title row sit
   flush right.
6. Standard navy ribbon from lib/widgets/app_ribbon.dart on every screen; don't hand-build a dark bar.
7. Use tokens (`DashUi`, `AppTheme`), no new hex literals. Amber/red mean a problem; don't colour non-problems amber.
8. Motion gated on `MediaQuery.disableAnimationsOf`.
9. Plain English, no internal codes/raw field names. Sentence case for titles and buttons.
10. Dashboards use the shared kit in lib/widgets/dashboard_panels.dart and dash_story.dart.

### Facts you need

- Backend source is at C:\Users\opera\integrity-backend (read only for you; its own git repo). Routes: src/*.js
  (financial in index.js or financial*.js, tech_stats.js, jobs.js, estimates.js, sales.js, collections.js,
  receivables.js, inventory_dashboard.js, employee_kpis.js, payroll*). DO NOT EDIT THE BACKEND: anything saved there can
  auto-deploy to production within a minute. Report backend defects to the lead instead, with file:line and the fix.
- Do NOT query the production database or Render. If a number needs checking against prod data, write the read-only
  SQL you'd want run and the expected relationship in your report; the lead will run it.
- Known data facts (don't "fix" these): commission go-live 2026-10-05 so callback/commission figures start then;
  callback strikes count from Oct 5; Collections "Outstanding" (Final Invoice Sent + Check on Payment due_total, as of
  today) is deliberately different from Financial "Outstanding (all jobs)" (all contract revenue not yet collected);
  Financial completed revenue excludes 'Check on Payment'; inventory movement isn't tracked (no data); /users
  hardcodes integrityScore 100 (stays visible, explained in its hover); Jobs status bar colours are Service Fusion's
  own status colours (keep them); Service Fusion dates are Chicago time labelled UTC.
- Other Claude sessions may edit files in this repo at the same time. Re-read a file region right before each Edit.
  Never run `dart format` on a whole file (the repo isn't formatter-clean; it reflows hundreds of lines).
- Many files are hand-wrapped at ~120-160 columns. Match the surrounding code's style and comment density.

### Shared files: do not edit (propose changes to the lead instead)

lib/widgets/dashboard_panels.dart, dash_story.dart, dashboard_kit.dart, dashboard_layout.dart, dashboard_data.dart,
app_ribbon.dart, dash_hover_card.dart, estimate_list_dialog.dart, lib/employee_kpi_screen.dart (shared KPI-page parts),
test/dashboard_fit.dart, test/dashboard_harness.dart. The lead is changing these in parallel:
- `DashSplitPanel` default finding: "mostly X (N%)" only when N >= 50, otherwise "largest: X (N%)".
- The average line and its key in `DashMonthBars` (dash_story.dart, amber today) become the same slate dashed line
  `DashMonthChart` already uses (`DashUi.subtle`). The best-month diamond stays amber.
So don't work around those two in your screen files.

The KPI pages are one Dart library: kpi_dashboard_screen.dart with parts employee_kpi_screen.dart,
employee_kpi_tech.dart, employee_kpi_sales.dart, employee_kpi_office.dart, employee_kpi_warehouse.dart. Private
widgets are shared across those parts (e.g. `_KpiTile`, `_ScoreHover`, `_HeaderLead`, `_HeaderBadges`, `_TechRatings`
live in employee_kpi_tech.dart but are used by the warehouse/office/sales pages). Only change a widget used by pages you
don't own if the change is clearly right for every page using it, and say so in your report. If a test run fails to
compile because of an error in a file you don't own, wait a minute and rerun; don't edit that file.

### How to work

1. Read your screen files fully. Read the matching tests and fixtures.
2. Look at the rendered screenshots. Baseline renders for every size and state are in
   C:\Users\opera\AppData\Local\Temp\claude\c--iohd-desktop\822c6098-f0e8-4ee6-89d6-22995e97f592\scratchpad\baseline_shots
   (names like financial_1280x600.png, financial_1280x600_text130.png, *_loading, *_empty, *_error, tech_kpi_*,
   sales_heather_*, office_bella_*, warehouse_dennis_*, general_john_*). Look at every size, the 130% ones, and the
   loading/empty/error states. The test harness draws chart text from bare TextStyles as grey blocks and shadows without
   blur; those are test-only artifacts.
3. Trace every number to its source and check the label says what it is, for the current year AND a past year.
4. Make a short list of real problems, then fix them in your files. Keep each change small and purposeful.
5. If a fix changes text a test asserts, update that assertion only when the new text is the intended behaviour; add a
   test for any defect you fix in logic. Never pass --update-goldens.
6. Run your screens' tests (`flutter test test/<file>_test.dart`); they re-render screenshots into build/dash_shots/.
   Look at the new renders at the tightest sizes (1280x600, 1280x600_text130) and one large size, and compare to the
   baseline. Run `flutter analyze <your files>` and keep it free of new issues.
7. Final report (this is all the lead sees, keep it tight, no preamble):
   - Screens audited.
   - Changes made: file:line, what, why (one line each).
   - Numerical/logical issues: found, traced to, fixed or not (and why).
   - Proposals for shared files or backend (exact change).
   - Prod checks you want run (SQL + what it should show).
   - Tests run and results (pass/fail counts, any failure explained), analyzer result.
   - Anything left that you could not safely resolve.
