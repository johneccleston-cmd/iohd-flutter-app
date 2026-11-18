# Jarvis audit report (2026-11-10)

Scope: the whole Jarvis path, from the panel in the office app (`lib/widgets/assistant_panel.dart`, `assistant_workspace.dart`) through `POST /api/assistant` and its tools (`integrity-backend/src/assistant.js`) down to the read-only database role (`assistant_ro`) and the production data.

**Nothing has been committed, pushed or deployed.** All changes sit uncommitted in both working trees for your review. Backend note: the next commit-all push of `integrity-backend` deploys everything below, including the one-time grant step (section 4).

---

## 1. Overall health

**Before:** Jarvis was solid on the questions it had a lookup for, such as money owed, briefings, comparisons, doors and calls. It was weak in four places:

- **Gaps fell back to SQL.** Technician revenue, salespeople, conversion timing, invoices and transcript search had no lookup. Jarvis fell back to listing the schema and writing its own SQL: 12 of the 22 real questions in the Nov 5–6 logs, taking 8–56 s and up to $0.21 each.
- **Follow-ups lost context.** History carried only the answer text. Once you had to paste "How I got this" back in by hand.
- **Permissions leaked.** Switching Jarvis on gave someone pay, profit, call transcripts and free-form SQL, whatever their other Team switches said.
- **Tables were missing.** Jarvis could not read invoices, site checks, the status list, projects, purchase orders, Stripe payments or estimate options at all.

**After:** each of these is fixed and tested.

- **Coverage:** the 35-question live test used no hand-written SQL at all.
- **Accuracy:** every new figure matches the matching dashboard or page on production data, to the cent.
- **Speed and cost:** median 5.4 s and $0.023 per question in the live test.

---

## 2. Issues found

Severity: **High** = wrong or unsafe answers, or common questions not answerable; **Medium** = unreliable or slow; **Low** = polish.

| # | Severity | Issue | Status |
|---|---|---|---|
| 1 | High (security) | The Ask Jarvis switch alone unlocked payroll, commission pay, profit and costs, call transcripts and free-form SQL, even for someone whose Payroll, Line items or Calls switches are off. The server only checked `jarvis.view`. | **Fixed:** server-side scoping (section 3.1) |
| 2 | High | No lookup for technician revenue, average job, revenue per day or cash collected, so "who brought in the most", "highest average job" and "compare technicians" went to hand-written SQL. | **Fixed:** `tech_performance` |
| 3 | High | No lookup for salespeople's sales (jobs where they are the Agent, the KPI page's rule): "jobs Heather was sales agent on" went to SQL (Nov 6 log). | **Fixed:** `sales_performance` |
| 4 | High | Follow-ups could not see what earlier answers looked up ("show the full 70-job list", "why are these two charts different"). | **Fixed:** lookups round trip (section 3.3) |
| 5 | High | Jarvis's database role could not read 19 tables, including invoices (10,676), site checks, the status list, projects, purchase orders, Stripe payments and estimate options. | **Fixed on deploy:** grant step (section 4), at your request |
| 6 | Medium | No conversion timing ("average time from estimate to approval") and no estimate vs final job vs cash comparison. | **Fixed:** `estimate_conversion`, `sold_vs_final` |
| 7 | Medium | No invoice lookup, so "payments vs invoices" questions could not be answered the Invoices page's way. | **Fixed:** `invoices_summary` |
| 8 | Medium | Calls and texts could not be searched by words ("how many times does Brett say …" went to SQL). | **Fixed:** `communications` `contains` + mention counts + matching lines |
| 9 | Medium | The model did not know the status vocabulary. Many statuses are also sub-statuses (Callback 23×, Warranty Work 10×, Part Ordered…), and `search_jobs` could only filter on exact status. | **Fixed:** `job_statuses`, `search_jobs` `any_status` / `sub_status` / `agent`, status list and terms in the prompt |
| 10 | Medium | `search_jobs` left out the 30 jobs whose `is_estimate` is NULL. An impossible date (Feb 30) came back as "The database query failed". | **Fixed** |
| 11 | Medium | Office staff who logged a visit (Heather Vera, Ryan Schwartz, a "Collections" placeholder) showed up as technicians in technician data. | **Fixed:** listed separately as `office_staff_left_out`; role text, not names (Zac and Dennis do field work) |
| 12 | Medium | `describe_data` listed a system table (`pg_stat_statements`, 52 columns), had no join guide and was re-run on most complex questions. | **Fixed:** system and held-back tables hidden; join keys and data traps included (also in `run_sql`'s description); several tables in one call; cached 10 min |
| 13 | Medium | The prompt had no company terms (SMH, FIS, COP, Agent, day weight) and no rules for the four money figures, wrong assumptions, or the two meanings of "overdue". | **Fixed** (all checked by tests) |
| 14 | Low | `top_customers_by_revenue` split one customer into two when names differed by case or spacing. | **Fixed** |
| 15 | Low | The model divided revenue by jobs itself for the average job. | **Fixed:** `avg_job_value` returned |
| 16 | Low (UI) | Tables split a job number over two lines ("109580665 / 0") and broke words ("Complet / e"). | **Fixed:** columns never narrower than their longest word |
| 17 | Low (UI) | The welcome screen left about 60% of the panel empty under the cards, away from the message box. | **Improved:** the welcome block now sits a little above centre; sizes unchanged |
| 18 | Low (UI) | Red was used for links, High chips *and* every "Suggested:" line in priorities, so nothing stood out. | **Fixed:** suggestions are ink; red is links and urgency only |
| 19 | Low | The Team screen's help line said Jarvis "can read every report, profit and pay included". | **Fixed** (see the goldens note in section 8) |
| 20 | Low (test) | The live-test grader flagged rank numbers in tables and "90th percentile" as made-up figures. | **Fixed**; one known false positive remains (section 6) |

**Found but not changed (data, for you to know):**

- **Uncredited revenue:** 221 of 1,718 completed 2026 jobs ($194,193 of $2.87M, 6.8%) have no technician day weights, so neither the Technicians dashboard nor Jarvis credits that revenue to anyone. Jarvis now says so (`company.revenue_not_credited`).
- **Old unpaid invoices:** of the 264 invoices awaiting payment ($236,402), 258 are past due ($224,971), the oldest by 1,023 days. Many look like old Service Fusion invoices never marked paid. The Invoices page shows the same.
- **Short status history:** status history is only trustworthy from 2026-09-10. Estimate timing currently rests on 52 won estimates (median 5 days to win, average 18.6) and 124 sent ones (median 1 day). Jarvis states the sample size every time.

---

## 3. Changes made

### 3.1 Permissions enforced server-side (`src/assistantAccess.js`, new)

- **Areas tied to switches:** each Jarvis lookup now belongs to an area tied to the same Team switches as the app's pages. Examples: payroll → Payroll or Commissions; profit and costs → Line items and costs; calls → Calls and texts; technicians → Technicians dashboard or KPI pages; invoices → Invoices; documents → Documents.
- **The model only sees allowed lookups.** It is offered only the person's lookups, and a lookup asked for anyway is refused.
- **Briefings drop parts cleanly.** Composite lookups (briefing, what changed, comparisons) leave out the parts the person may not see and say so.
- **Profit and costs are stripped** from every result without the Line items switch.
- **The prompt tells the model what is off,** so it says "not included in your access; an admin can switch it on in Team" instead of guessing.
- **Free-form SQL needs every switch,** because a query can reach every table.
- **Admins and owners see no change,** and nor does anyone with every switch on. They get the same shared tool list and prompt, so the prompt cache is not split.

### 3.2 Seven new lookups (`src/assistantInsights.js`, new) and extended ones

Each one follows an existing screen's rule, and each was checked on production data against that screen's own query:

| Lookup | What it answers | Production check |
|---|---|---|
| `tech_performance` | Per technician: completed jobs, revenue share (day-weight split), average job, revenue per day, cash collected on their jobs, jobs that later needed a callback, role and active | Revenue identical to the Technicians dashboard for every tech (e.g. Daniel Baty $749,413.41, Nick Smith $642,853.59) |
| `sales_performance` | Per salesperson: closed jobs where they are the Agent, sales, profit, average job, plus their estimates and close rate; by month; list of jobs | Identical to the KPI page (Heather Vera 1,568 jobs, $1,767,919.41) |
| `estimate_conversion` | Created / won / lost / decided / open, conversion rate, days to send and to win with sample size | Counts identical to a direct count (765 / 277 won / 37 lost); 8 ms |
| `sold_vs_final` | Won estimates against the job each became and cash collected (the job page's "Became job" rule) | 277 won, 220 matched; 3.4 s for a full year |
| `invoices_summary` | The Invoices page's awaiting / overdue / invoiced figures, by customer, month or age | Identical to the page: $236,401.87 awaiting on 264, $224,971.25 overdue on 258 |
| `job_statuses` | The Statuses page list, with how many records carry each status and sub-status | n/a |
| `site_checks` | Site check submissions: job, tech, type, doors, photos, done / failed, PDF | n/a |

Extended:

- `search_jobs`: status or sub-status, sub-status, sales agent, totals for all matches, real-date check.
- `jobs_summary`: `avg_job_value`, project-type grouping.
- `get_job`: category, agents, owner, PO, created date.
- `communications`: `contains` word search. A full-year scan of every transcript takes about 1 s on production.

### 3.3 Follow-ups remember their lookups

- **Server:** each answer now returns `lookups` (tool and exact arguments). The app saves them with the chat and sends them back with that answer. The server accepts only known lookup names, caps their size, and keeps them for the newest three answers only.
- **Model:** it sees them as one line under the earlier answer and is told to start follow-ups from them, never to quote them.
- **App:** `AssistantMessage.replay` in `assistant_panel.dart`; test `test/assistant_followup_test.dart`.

### 3.4 Prompt

- **Terms and statuses:** company terms and the status pipeline, including "waiting on materials".
- **Four money figures:** quoted, job revenue, cash and owed, never mixed. "How much did we make" is answered one way and the other is offered.
- **Wrong assumptions:** corrected in the first sentence.
- **"Overdue":** both meanings handled.
- **Missing data:** what is truly not in the data, stated exactly (vendors, the product catalog, stock movement in the Google Sheet).
- **Routing:** each new lookup has a routing line.

### 3.5 Interface

- **Tables:** columns never break job numbers or words.
- **Welcome screen:** balanced vertically.
- **Priorities:** calmer colouring.
- **Team screen:** the Jarvis help line is corrected.

Everything else in the visual identity is unchanged.

---

## 4. Database coverage (your rule: every column except the sensitive user-specific ones)

`src/assistantViews.js` now grants the read-only role SELECT on every table at startup and holds back three things:

- **Whole tables:**
  - `drive_connections` (OAuth refresh tokens)
  - `user_avatars`
  - `user_admin_audit` (it records old and new PINs)
  - the raw Quo tables, because calls stay behind the existing view, with no recordings and ignored personal numbers left out
- **Columns on `users`:** `pin`, `needs_pin_change`, `email`, `fcm_token`, `fcm_token_updated_at`, `access_denied`, `dashboard_access`, `view_access`, `avatar_url`. Also `job_files.storage_key`, which was already held back.
- **Any column on any table whose name says it is a secret** (`*pin*`, `*password*`, `*token*`, `*secret*`, `*api_key*`, `*_enc`, `*_hash`), so a column added later is protected by its name.

The step only changes something when the current grants differ, so a normal restart changes nothing. It is tested for idempotence and revocation.

**Dry run against production** (read-only), showing what the first deploy will do:

- **19 tables become readable:** invoices, site_check_submissions, status_definitions, projects, purchase_orders, stripe_payments, record_options, record_line_items, record_option_revisions, customer_phones, deleted_records, job_activity, cycle_count_results, cycle_count_non_inventory, commission_settings, app_settings, google_review_sync, app_migrations, projects_sheet_skipped.
- **On `users`, these become readable:** hire_date, job_title, can_see_commissions, the badge flags, and the commission-rate columns (install_rate_pct, sales_rate_pct, sales_account_rate_pct, sales_builder_rate_pct). **Decision for you:** I treated pay rates as business data, since Jarvis already reads payroll amounts, and only people with every switch on can query them freely. If you count them as sensitive, add them to `SENSITIVE_COLUMNS.users`.
- **Nothing sensitive** is readable now or after.

---

## 5. Testing

### Backend (`node --test`, real tree, throwaway Postgres)

- **383 tests: 380 pass, 3 fail.** The 3 are the same 3 that failed before any change: the callback-rate test and two payments-list tests, none of them Jarvis.
- **New test files:**
  - `assistant_insights_sql.test.js`: 12 checks, every figure worked out by hand in the fixture.
  - `assistant_access.test.js`: 9 checks covering who sees what, refusals, profit stripping, composites, and the follow-up round trip.
  - `assistant_grants_sql.test.js`: the sensitive-column rule, revocation, idempotence, and a secret column added later.

### Live model evaluation (`test/assistant_live_eval.js`)

The real production model (`claude-sonnet-5-5`) ran through the real route, lookups and SQL, on a made-up company with known answers.

**Run 1:** 35 questions covering your list (technicians, sales, conversion, invoices vs receivables, materials, lifetime revenue, a wrong assumption, a person who doesn't exist, word search, a follow-up that changes an earlier lookup, a person without payroll access) plus the earlier 17.

- **Raw result:** 31 of 35 pass.
- **After review:** three failures were grader false positives (a stated "120 days" rule, a "90th percentile" label, table rank numbers). The grader was fixed for two of them; re-graded, 33 of 35 pass.
- **Real failure:** one, minor. Jarvis added 3 won + 2 lost = 5 by hand without saying so. The lookup now returns `decided`.

**Run 2:** 8 key questions asked twice each, to confirm the fix and measure consistency.

- **15 of 16 pass.** The one failure is the known "120 days" false positive; the second ask of the same question passed.
- **Consistent:** every repeated question gave the same key figures both times.

**Measured across both runs:**

| | |
|---|---|
| Hand-written SQL used | 0 of 51 questions |
| Made-up figures found | none, other than the grader false positives above |
| Questions answered with the right lookup | 51 of 51 |
| Payroll asked by someone without access | refused in 3 s, no lookups, says an admin can switch it on |
| "Why did Jordan's revenue drop to zero?" (it didn't) | corrected in the first sentence, with the real $1,700 |
| "Sam Whitaker" (no such person) | "no employee has that name", no figures invented |
| "Material used this month" | says stock movement isn't tracked; offers product lines on jobs instead, labelled |
| Cost of both live runs | $1.40 total |

**Not judged automatically:** whether the advice in answers is sensible. I read the key answers myself; they were relevant and correctly hedged.

### Production checks (read-only)

Each new lookup's own SQL was run on production next to the matching screen's query. The results are in the table in section 3.2.

### Flutter

- **Analyzer:** `flutter analyze` on the Jarvis files is clean. Project-wide it reports 23 existing issues, none in the files I changed.
- **Jarvis tests:** 102 pass, 24 fail. A baseline copy with my visual changes removed fails on exactly the same 24, so none are new. They are older stale goldens and expectations from earlier redesigns and today's permission change.
- **Review shots:** all 16 home scenes pass the overflow check, including 1024×700, 150% text and 1920×1080. The 8 review shots render cleanly.
- **Team permissions:** 2 goldens (`team_permissions.png`, `team_permissions_900.png`) differ only because of the corrected Jarvis help line. Confirmed by restoring the old text in a copy, where they pass.
- **Web build:** `flutter build web --release` compiled cleanly into the scratchpad only (not `build/web_release`, not published), and its `flutter_bootstrap.js` parses.

---

## 6. Performance and cost, before and after

| | Before: production logs, 22 real questions, Nov 5–6 | After: live test, 51 questions |
|---|---|---|
| Median time | 13.9 s (average 18 s, worst 56 s) | 5.4 s (worst 9.5 s) |
| Average cost | $0.078 (worst $0.21) | $0.027 (median $0.023, worst $0.11 for the daily briefing) |
| Questions that fell back to describe_data + SQL | 12 of 22 | 0 of 51 |

These are not the same questions on the same data. The test company is small, so its lookup results are smaller than production's. The real gain is that questions which used to loop through SQL are now one lookup each.

**Cost trade-off:**

- **Prompt size:** the fixed prompt grew from about 26.4k to 33.5k tokens with the new lookups.
- **Warm cache:** about $0.0014 more per model call.
- **Cold cache:** about $0.08 for the first question after five quiet minutes, which is most of the cost of a one-off question.
- **People with switches off** get their own cached prompt, so their first question costs about $0.08.

---

## 7. Remaining limitations

- **No stock movement:** what was picked or received lives in the warehouse Google Sheet, so "material used" can only be shown as product lines on jobs.
- **Data not in the system:** vendors, the product catalog, email, and purchase orders beyond the few entered in the app.
- **Short history:** status history (and so estimate timing, "days in status" and change dates) is only trustworthy from 2026-09-10. Callback flags only exist from 2026.
- **Thin estimate-owner data:** owner is only filled in on estimates synced since early Oct 2026. Agent-based sales go back further.
- **Grader false positive:** the live-test grader still flags a rule number such as "the last 120 days".
- **Office staff left out by role:** this relies on role text starting with Owner, Admin or Office.
- **Read-only:** Jarvis still cannot change anything, as you decided earlier.

---

## 8. What needs your decision

1. **Review, then deploy the backend.** Pushing `integrity-backend` deploys the new lookups, the permission scoping and the grant step. The grant step runs once at startup and is logged as `🤖 [ASSISTANT] views: {...}`. The office web app also needs a publish for the follow-up memory and UI changes. Until then, older app builds still work, just without lookups in their history.
2. **Pay rates on `users`:** readable by Jarvis (current choice) or held back (section 4).
3. **Goldens:** 2 Team-screen goldens differ because of the corrected help line, plus the 24 already-stale Jarvis ones. Regenerate only with your OK.
4. **Welcome screen:** I kept your approved compact layout and only balanced it vertically. A bigger change, putting the message box straight under the greeting, is possible if you want it.
5. **Prompt cache:** if most questions are one-offs, a 1-hour cache costs double to write but would cut the $0.08 cold-start charge for questions spread through the day. Worth trying only if the logs show long gaps between questions.

---

## 9. Recommended next steps

- **Re-run the live test after deploy** against production-style data volumes, then read 10 real answers a week from the `[ASSISTANT]` log lines. Thumbs-down feedback is already logged as `ASSISTANT-FEEDBACK`.
- **Fix the uncredited jobs:** add day weights to the 221 jobs without them, or decide on a rule, so technician revenue covers 100% of completed work.
- **Old unpaid invoices:** decide what to do with the old past-due invoices (mark them paid or written off in Service Fusion), so "overdue" means something.
- **Stock movement:** once it moves out of the Google Sheet, a `materials_used` lookup is a small addition.
