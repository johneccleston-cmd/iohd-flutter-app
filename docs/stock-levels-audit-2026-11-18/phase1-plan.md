# Stock Levels — Phase 1 plan: stop inventory corruption

Plan only, 18 Nov 2026. Nothing was implemented, committed, deployed, published or written to the Sheet or the database.
It builds on the approved Phase 0 audit in this folder (`index.html`), a fresh read of the code it names, and one
in-memory probe (see the appendix).

Labels used below, as in the audit: **Confirmed** (reproduced or measured), **By code** (read in the code, not run),
**Suspected** (evidence points to it, not proven).

---

## Summary

Phase 1 changes how stock is written, not how it is shown. Every write path moves to one design: numbers parsed in one
place, a signed-in person taken from the token, a request id on every change, a lock that holds across servers, a check
that the right row is written, and a movement record for every change. Then the system of record is decided: keep the
Sheet (Option A) or move quantity into a Postgres ledger and publish it to the Sheet (Option B).

**A new critical finding came out of the re-read (N1).** When one checkout names the same part on two jobs, only the last
line comes off stock. The phone sends all of the day's jobs in one checkout, so a part needed on two jobs is the normal
case. The probe sent 3 + 1 Punched Angle against 40 on the Sheet: the log shows 4 taken, the Sheet ends at 39, not 36
(**Confirmed**, in-memory run of the real router). The staging flush has the same flaw.

**Recommendation: Option B, in stages.** First ship the steps both options need (S1–S11 below). They stop most of the
damage within about three weeks and are almost all kept under either option. Then cut over to the ledger after a one-
to two-week shadow period. The decision is yours (D1). Section 9 lists everything that needs your call.

**What Phase 1 does not do:** publish the Stock Levels rewrite (C6), make the dashboard and Stock Levels agree (C7, Phase 2
by default), build office adjust/receive screens (H8, Phase 4), match checkouts by catalog id (C1's full fix, Phase 2),
or clean up the Sheet's data (M6).

### Coverage of the critical and high findings

| Finding | Phase 1 result under A | Phase 1 result under B |
|---|---|---|
| C1 Different-name checkouts reduce nothing | Visible and recorded: the phone is told per line, unmatched lines are kept. Matching stays by name (aliases optional, D7) | Same |
| C2 1,000+ misread as 1 | Fixed on every path | Fixed |
| C3 Lost updates | Fixed between program writers; manual edits by Sheet owners can still race | Fixed; manual edits are recorded as drift, never lost silently |
| C4 Wrong-row writes | Narrowed to a sub-second window, plus Sheet structure protection | Ledger can't be hit; a wrong Sheet write is corrected on the next projection |
| C5 Shared key changes stock | Fixed (needs TOKEN_SECRET verified, D3, D4) | Same |
| C6 Live screen statuses | Not Phase 1 (publish the rewrite, Phase 3) | Same |
| C7 Dashboard disagrees | Not Phase 1 (Phase 2 mirror) | Not Phase 1 by default; B makes it a small change (D9) |
| H1 Over-checkout erases shortfall; undo makes phantom stock | Fixed | Fixed |
| H2 Unchecked cycle-count values | Fixed | Fixed |
| H3 Counts wipe intervening movements | Fixed for movements the backend made; manual edits are invisible | Fixed |
| H4 Staging lost on restart | Fixed | Fixed |
| H5 Retries apply twice | Fixed once the new Android build is out | Same |
| H6 Logged but not deducted | Narrowed; a recovery step closes most cases | Removed: log and stock change in one transaction |
| H7 Freshness unknown | Groundwork only (read-time header); screen work is Phase 3 | Same |
| H8 No office correction path | Interim: Sheet edits are recorded as drift; screens in Phase 4 | Same |
| H9 Duplicate part numbers | Fixed: an ambiguous scan asks which part | Same |

---

## New findings from the re-read

| # | Finding | Label | Where |
|---|---|---|---|
| N1 | One checkout with the same part on two jobs deducts only the last line. Both lines start from one snapshot and the second write overwrites the first. The phone sends every ticked part across all of the day's jobs in one request. | **Confirmed** (probe) | inventory.js:341-347; flush inventory.js:480-485; phone InventoryFragmentV2.kt:437 |
| N2 | If the 8:31 flush fails after the log append, the in-memory staging is kept and flushed again next morning. The log rows and the deduction then repeat, dated the day before. | By code | inventory.js:470-498 (clear only on success, line 495) |
| N3 | During a deploy two servers run at once (memory audit R9). Each one schedules the 8:30, 8:31 and 4 PM jobs and keeps its own staging. A lock inside Node can't cover that, and the 4 PM strikes can be applied twice. | By code | inventory.js:408, 438, 464; BACKEND_MEMORY_AND_QUEUE_RELIABILITY_AUDIT.md R9 |
| N4 | OkHttp can resend a POST by itself after some connection failures (retryOnConnectionFailure is on by default and the bodies are not one-shot). Careful Retry buttons on the phone don't prevent that. | Suspected | ApiClient.kt:60-77 |
| N5 | The cycle-count screen offers Retry after any failure, including a timeout or 500 where the count may already be applied. A retry re-sends absolute values. | By code | CycleCountListFragment.kt:343 |
| N6 | warehouse1 is a shared login. A token proves "the warehouse phone", not which person used it. | By code | index.js:296-305, auth.js:212-226 |
| N7 | If TOKEN_SECRET is unset or equal to API_SECRET, user tokens are signed with the key that ships in every app. Anyone holding a build could then mint a token for any user, and the C5 fix would mean nothing. Not verified in production. | By code | auth.js:33-39 |

A note on N1's size: PickedItems has 63 same-day, same-person groups where one stocked part appears on two or more job
lines (121 units beyond the last line of each group). The tab is sorted newest-first, so row order can't prove those
lines came from one request. The mechanism is confirmed; the amount is an upper bound. It plausibly explains part of
the 1,201-unit cycle-count miss in the audit.

---

## 1. Proposed technical design

### 1.1 Principles

1. **One write path per store.** Every change to stock goes through one module (`src/stockWrites.js`). Routes, jobs and the
   Apps Script replacement call it; nothing else writes quantity.
2. **Movements, not overwrites.** Every change is a signed movement with a reason. A cycle count becomes an adjustment
   (counted minus expected), not an absolute overwrite.
3. **Identity from the token, never the body.** The person on a movement is `req.user`. `techName` and `x-user-role` are
   ignored for attribution and for decisions.
4. **Every change has a request id.** A retry with the same id returns the first answer and changes nothing.
5. **Fail closed.** If identity can't be trusted, the schema is missing, the row can't be confirmed or the input is
   invalid, nothing is written and the caller is told it is safe to retry.
6. **Nothing is silent.** Unmatched lines, shortfalls, conflicts and Sheet drift are recorded and returned, not dropped.

### 1.2 Every writer, and how each would be coordinated

| Writer | Today | After the shared steps (S1–S11) | Option A adds | Option B adds |
|---|---|---|---|---|
| Phone checkout `POST /checkout_inventory` | Logs first, re-reads the tab, writes `D{row}` by row number, clamps at 0 | Validated; person from token; request id; lines merged per part (N1); one Postgres lock across servers; row re-checked just before writing; stock first, log second; movement recorded | Recovery of half-finished writes before each new one | One Postgres transaction (movement + balance); the Sheet is updated afterwards by the projector |
| Barcode scan `POST /scan_checkout` | Same pattern; first row with that part number; any action other than "add" deducts | As above, plus `action` must be add or deduct, and a duplicated barcode returns 409 with the candidates (H9) | Same | Same as checkout |
| Cycle count `POST /cycle_count_update` | Absolute overwrite, USER_ENTERED, unvalidated | Validated whole numbers written RAW; checked against movements since the zone was loaded (H3) | Same | An adjustment movement: counted minus the balance at the moment of counting |
| 8:31 staging flush (cron) | In-process Map; runs in every server process | Staging in Postgres; the job runs once per day across servers; uses the same write path | Same | Ledger movements |
| 8:30 warehouse audit and 4 PM inventory audit (crons; write strikes, not stock) | Read PickedItems and the Map; run in every process | Read staging from Postgres; run once per day | Same | Read the ledger plus the imported PickedItems history |
| Total Warehouse Value `Inventory!I2:I3` | parseInt (C2), 30 s debounce per process | Computed in the stock module with the shared parser, under the lock | Same | Written by the projector |
| Last Count `Inventory!I5:I6` | Written by the count route | Under the lock | Same | Projector |
| Apps Script `onPickedChange` (undo on row delete) | Writes D with no coordination; adds back the requested quantity; restores absolute "previous" values | Unchanged until the A/B step (ask the office not to delete PickedItems rows meanwhile) | Stops writing D. Posts the removed row to the backend, which reverses exactly what was applied, once | Trigger removed. Deleting a log row does nothing; reversals are movements |
| People editing the Sheet | Anything, any time | Edits to D are detected as drift and recorded (the backend knows what it last wrote) | Sort, insert and delete blocked by protection (D5); quantity edits allowed and recorded | The projector notices a hand edit and records it as an adjustment before writing (D5) |
| Catalog import (manual SQL, writes `inventory_items.qty`) | Overwrites Postgres quantities from its export | Unchanged; it is not stock truth in Phase 1 | Unchanged | Must stop writing qty before any C7 mirror (D9) |
| `migrate_invnetory.js` | Dormant, never called | Unchanged | Unchanged | Delete in Phase 2 |
| Two servers during a deploy (N3) | Separate Maps, duplicate crons | Postgres lock plus run-once rows | Same | Same |
| Unknown writers (other script projects, add-ons, other people's triggers) | Not verified | You check them in S0 | Protection blocks non-owners | Drift detection catches them |

An in-process lock solves none of this. Requests on two servers, the cron on the old server and the Apps Script are
separate processes. Every coordination point above is either a Postgres lock or a Postgres unique constraint. People
on the Sheet can't be locked at all. They can only be blocked by protection or caught afterwards as drift.

### 1.3 Option A: the Sheet stays the system of record, with one coordinated writer

- The backend is the only program that writes `Inventory!D`. Each write runs inside `pg_advisory_xact_lock` on one global
  key, held in a short transaction around the Sheet read-modify-write (about 0.5–1.5 s). `lock_timeout` is 8 s; after
  that the caller gets 503 "busy, nothing changed". Volume is tens of writes a day, so one global lock is enough.
- Under the lock: read `Inventory!A:H` fresh with `UNFORMATTED_VALUE` (dates as formatted strings), find the row by part
  key, re-read that single row to confirm the key, write the number RAW, read it back. A mismatch aborts and retries.
- **Recover on acquire.** Before writing, the writer saves its plan (row, key, value before, value after) on the
  `stock_requests` row. Whoever next takes the lock first settles any pending plan. If the cell holds the planned
  after-value, it was applied: log it and mark it applied. If it holds the before-value, mark it rejected so a retry
  re-runs cleanly. Anything else goes to review. This is what A needs to approximate a transaction.
- Postgres is still required for idempotency, staging, locks and the movement log. A therefore still runs two stores,
  with no transaction across them.
- Protection: protect the Inventory tab's structure (every column except D) so non-owners can't sort, insert or delete
  rows. Owners can never be restricted by Google, so C3/C4 against owners remain.
- Apps Script undo is re-routed to `POST /stock/sheet_reversal` (section 5).

*A stronger form of A*, if you want to stay in Sheets: make D a formula (opening + `SUMIFS` over an append-only
Movements tab) so writers only append. That removes read-modify-write. The cost is fragile formulas (one typed value in D
breaks the part), slower recalculation as the tab grows, and appends that would still need a concurrency test against a
copy of the Sheet. I have not costed it further.

### 1.4 Option B: Postgres owns quantity in an append-only ledger; the Sheet is a published view

**Scope in Phase 1: only the quantity (column D) and the movement log move.** Names, part numbers, locations, reorder
points, costs and categories stay on the Sheet. The office keeps adding parts on the Sheet.

- **Tables** (section 3): `stock_items` (one per Sheet part, its own id, *not* `inventory_items`, so Product Catalog data
  is untouched), `stock_item_aliases`, `stock_balances`, `stock_movements` (shared with A), the projection tables and
  `stock_legacy_picks`.
- **Write transaction** (checkout, scan, count, flush, reversal):
  1. `INSERT INTO stock_requests … ON CONFLICT (request_id) DO NOTHING`. A duplicate in flight waits on the unique
     index until the first transaction commits, then replays its stored answer (same payload) or gets 409 (different
     payload).
  2. Resolve each line to a `stock_item_id` (normalised name, then approved aliases). Unmatched lines are recorded as
     `not_stocked`.
  3. `SELECT … FROM stock_balances WHERE stock_item_id = ANY($1) ORDER BY stock_item_id FOR UPDATE`. The order prevents
     deadlocks, and per-part row locks hold across servers.
  4. Insert one movement per request line (job attribution kept). Update each balance by the summed delta, which fixes
     N1 by construction.
  5. Store the response on the request row, commit, then nudge the projector.
- **Projector** (one at a time, by advisory lock; after each commit, debounced about 5 s, plus a full pass every 15 min):
  - Reads `Inventory!A:D`, finds rows by key and compares each D with what it last wrote. If they differ, a person edited
    it: record a `sheet_drift` adjustment (D5) before writing anything.
  - Writes the new D values RAW, then reads them back. A wrong-row write is fixed on the next pass, because Postgres
    holds the truth.
  - Appends PickedItems rows for new movements, with the movement id and request id in columns G and H. It finds where it
    stopped from the last ids on the tab, so a crash never duplicates rows.
  - A Sheet row with an unknown name (the office added a part) is registered as a new stock item, with an opening
    movement for the D value it holds. A part that disappears from the Sheet is reported, never re-added.
  - Writes `I2:I3` and `I5:I6` and a "Stock as of <time>" cell, so anyone reading the Sheet can see how fresh it is.
- **Reads:** `/get_full_inventory` takes metadata from the Sheet and quantity from `stock_balances`. `/get_job_materials`
  and the 8:30/4 PM jobs count picks from the ledger plus `stock_legacy_picks`, so a checkout disappears from the pick
  list at once, even if the Sheet is behind. `/get_techs` lives in index.js, which is frozen. It keeps reading PickedItems
  until the freeze lifts; that affects only the tech picker's counts, seconds behind.
- **Rollback stays cheap.** While the projection is current, the Sheet holds the true numbers, so switching back to A
  needs no data move (section 7).

### 1.5 A and B compared

| | A: Sheet stays the record | B: Postgres ledger, Sheet is a view |
|---|---|---|
| Data integrity | Much better than today. No transactions, so the log and stock can still split on a crash (recovery settles most cases). Owner edits can still overwrite. | Log and stock change in one transaction. Every balance equals the sum of its movements, checked nightly. The Sheet can always be rebuilt. |
| Concurrency | One global lock around every Sheet write. People can't be locked. A sub-second wrong-row window remains for owner-level editors. | Per-part row locks. The projector is the only program writing the Sheet, and its mistakes heal on the next pass. |
| Offline and retry | Request ids live in Postgres, but whether a crashed write reached the Sheet has to be inferred. | The request id and the movements commit together, so a replay is exact. A future offline queue can carry the real time of each pick. |
| Failure recovery | A Sheets outage or quota limit means no stock writes. Half-finished writes need the recovery step. | A Sheets outage only makes the Sheet stale; stock writes continue. A Postgres outage stops writes, which already stops pick lists today. Backups apply. |
| Auditability | PickedItems (editable) plus a Postgres log of backend writes. Manual edits only in Google's version history. | Append-only ledger with person, device, request, reason, before and after. Manual Sheet edits are captured as drift. |
| App and Android changes | The contract in section 4 | The same contract. The phone sees no difference. |
| Migration complexity | Low to medium: protection, script re-route, no data move | Medium to high: map 446 rows, opening balances, import the log history, projector, shadow period, a 20-minute pause |
| Production risks | Owner edits, Google's per-user quota (60 requests a minute by default, and the service account is one user), residual windows | Sheet readers see numbers seconds to minutes old if the projector lags. Mapping mistakes at cutover. The habit of editing the Sheet. Postgres becomes critical for stock, and its allow-list is open to 0.0.0.0/0. |
| Work after the shared steps | About 5 engineering days | About 12–13 engineering days, plus 1–2 weeks of shadow running |

**Why I recommend B.** C3, H6 and part of C4 are transaction problems. The Sheet has no transactions, no conditional
writes and no stable row identity, so A can only make the windows smaller. A also needs Postgres anyway (locks, request
ids, staging, the log), so it carries a second store without making it the truth. B also unlocks the later phases
directly: one stock number for every screen (C7), movement history in the part drawer, and adjustments with reasons.

**When A is the better call:** if the office must keep the Sheet as the place where stock is routinely changed by hand,
or if Phase 1 has to fit in about four weeks.

### 1.6 Shared components (both options), by required area

**Area 1 — Quantity parsing and precision (C2, M5, N1).** New `src/stockQuantity.js`:
- `sheetQty(v)`: a number from an `UNFORMATTED_VALUE` read, or a string with commas, spaces and `$` removed that matches
  `^-?\d+(\.\d+)?$`; `null` for blank; `NaN` for text. A line whose cell is text (a past formula from H2) is refused with
  outcome `rejected` instead of being overwritten.
- `requestQty(v, {allowFraction:false, max:10000})`: JSON numbers or plain digit strings only, finite, above 0, whole
  unless the part allows fractions. 0.5 and 2.5 return 400 instead of being dropped or truncated.
- `countQty(v)`: a whole number from 0 to 100,000.
- Inventory-tab reads use `valueRenderOption: UNFORMATTED_VALUE` with `dateTimeRenderOption: FORMATTED_STRING`; writes use
  `RAW`. PickedItems reads stay formatted, because `pickDateKey` expects text dates.
- Warehouse value moves into the stock module with the same parser. inventory.js stops calling
  `services.scheduleWarehouseUpdate`, which is its only caller, so services.js is not edited.
- Lines for the same part in one request are merged for the stock change and kept separate for the log (N1).

**Area 2 — Trusted identity (C5, N6, N7).** New `src/stockAuth.js` middleware `requireStockWriter`, placed after
`requireAuth`, without editing auth.js:
- Requires `req.user` from a valid user token for an active user. The service token (`svc`) is refused; server jobs call
  the module directly, not over HTTP.
- The refusal message is "Session expired. Please log in again." so the phone's existing check sends the person to sign in.
- **Fails closed if TOKEN_SECRET is unset or equals API_SECRET** (D3).
- The person recorded is `req.user.name`/`id`. Optional `forTech` from the new phone build is recorded as
  `on_behalf_of` when warehouse or an admin checks out a tech's list.
- It starts in `log` mode (records tokenless stock writes, still serves them) and switches to `enforce` (D4). This does
  not depend on ENFORCE_USER_AUTH.

**Area 3 — Server-side authorization.** Inside `requireStockWriter`, by route:

| Action | Allowed |
|---|---|
| Checkout, scan deduct | Any active signed-in employee (as today, now with identity) |
| Scan add | Same as today by default (techs return parts); tightening to warehouse and admin is optional (defaults list) |
| Cycle count | warehouse1, Warehouse role, admins (today's rule, now without the no-token path) |
| Staging | Decided by the server from `req.user` (username warehouse1 or Warehouse role) and Chicago time; never from a header or the body |
| Reversal endpoints (new) | Admins only via `requireAdminSession`. A `stock.adjust` key needs accessKeys.js, which is frozen (section 10) |

**Area 4 — Concurrency.** See 1.2–1.4. Shared steps: one Postgres advisory lock around every Sheet read-modify-write.
B: row locks in the ledger, plus an advisory lock for the projector. Crons: `pg_try_advisory_lock` plus an
`INSERT … ON CONFLICT DO NOTHING` into `stock_job_runs (job, run_date)`, so each job runs once a day even with two servers.

**Area 5 — Wrong-row writes (C4, H9).** Never write to a row number taken from an earlier read. Under the lock: locate
by key, confirm that single row, write, read it back. Under B the projector also heals on its next pass. Barcodes found on
more than one row return 409 with the candidates; the phone resends with `itemKey`.

**Area 6 — Logging and partial failure (H6, C1).**
- Shared steps and A: request row (pending), lock, write stock, record movements, append PickedItems (3 inline retries),
  mark applied, respond. A pending request older than 2 minutes raises an alert, and its missing PickedItems rows are
  appended after searching for the request id first. Under A, recover-on-acquire settles the rest.
- B: one transaction. PickedItems is a projection.
- Every line gets an outcome (`deducted`, `staged`, `not_stocked`, `short`, `rejected`). The response says `partial` when
  any line didn't change stock, and the phone shows those lines. Unmatched lines are recorded as movements with no item,
  feeding Phase 3's "Unmatched checkouts" view.

**Area 7 — Over-checkout (H1).** The movement records the requested quantity, the applied change and the shortfall. Two
policies (D6):
- (a) **recommended:** let on-hand go negative and flag the part for a count, because the parts physically left the shelf;
- (b) clamp at 0 and record the shortfall separately.

Either way, a reversal uses the applied change, never the requested quantity, and can run only once (unique index).
PickedItems column D keeps the requested quantity, which pick lists rely on; the applied quantity and shortfall go in
new columns.

**Area 8 — Request ids and idempotency (H5, N4, N5).**
- Header `Idempotency-Key: <UUID v4>`, made by the phone when the person taps and reused for every retry of that action.
- The same key with the same payload hash returns the stored response, `replayed: true`. The same key with a different
  payload returns 409. A key still in progress (A) returns 409 with "still being processed".
- No key (old builds): processed as today, marked `key_source = 'server'` and logged. It becomes required (400) after the
  Android rollout (S13).
- Keys are kept indefinitely (tens a day).

**Area 9 — Cycle counts (H2, H3).**
- Validation: `countQty`, string names (1–300 characters), at most 500 items, no duplicate names in one submit, zone must
  be `Zone 1`–`Zone 4`. The date comes from the server.
- Conflicts: `/get_full_inventory` returns `X-Stock-Cursor` (the newest movement id). The phone sends it back as
  `loadedCursor`, with `countedAgoMs` per item (milliseconds since the person confirmed it, which avoids phone-clock
  error).
- Server rule per item:
  - No movements since the cursor: adjustment = counted − current.
  - Movements since the cursor and `countedAgoMs` given: adjustment = counted − (balance at the counting moment). Later
    movements are kept.
  - Movements since the cursor and no time given: outcome `conflict`, nothing applied, recount asked.
  - Old builds (no cursor): today's behaviour, logged as legacy, until S13.
- "System quantity" for the accuracy KPI becomes the balance at the counting moment, with the correct parser.
- Reversing a count applies the inverse adjustment, never the old absolute value.

**Area 10 — Staging durability (H4, N2, N3).**
- `stock_staging` in Postgres. The 8:30 audit reads it; the 8:31 flush runs once and turns each staged row into a
  movement under the flush request id (idempotent per staged row).
- A failed flush leaves rows `staged` for a retry at 8:36 and 8:45, never for the next day.
- A tech's own checkout of the same job and part marks the staged row `superseded`, as today's `Map.delete` does.
- Re-staging the same job and part keeps today's *replace* semantics by default. Staged parts stay on the pick list, so
  "add" would double count (D8).

**Area 11 — Apps Script undo.** Section 5.

**Area 12 — Regression tests.** Section 6. Tests come first: each reproduced finding gets a failing test (marked
`todo`) before its fix, and the fix turns it on.

---

## 2. Files and systems to change

### Backend (integrity-backend)

| File | Change | Shared or frozen? |
|---|---|---|
| src/inventory.js | Every write route and the three crons move onto the stock module; `/get_full_inventory` adds headers; `/get_job_materials` reads picks from the ledger (B) | Stock-owned; not in the Services Catalog audit's set |
| **New** src/stockQuantity.js | Parsers (area 1) | New |
| **New** src/stockAuth.js | `requireStockWriter` (areas 2, 3) | New; auth.js untouched |
| **New** src/stockStore.js | Postgres access: requests, movements, staging, settings, job runs, locks (B: balances) | New |
| **New** src/stockSheet.js | Sheets I/O: unformatted reads, RAW writes, locate and confirm a row, read-back, own short cache with read time | New |
| **New** src/stockWrites.js | The one write path: checkout, scan, count, staging, flush, reversal | New |
| **New** src/stockProjector.js (B) | Projection to D, PickedItems, I-cells; drift; new-row registration | New |
| **New** scripts/stock_migrate.js | Applies db/migrations/stock/*.sql with checksums; run by you | New |
| **New** scripts/stock_mapping_report.js (B) | Read-only: Sheet rows to proposed stock items, duplicates, aliases, non-numeric D, formulas | New |
| **New** db/migrations/stock/001_stock_core.sql, 002_stock_ledger.sql | Section 3 | New |
| src/stockLevels.js | Reuse `sheetNumber` for display only; no behaviour change | Stock-owned |
| apps_script/picked_items_undo.gs | A: re-route; B: teardown (section 5) | Stock-owned (repo copy) |
| test/stock_*.test.js, test/stock_fakes.js | Section 6 | New |
| test/phone_route_access.test.js | One test that pins the old no-token cycle-count path changes when identity is enforced (S13) | Stock-related |
| src/services.js | **Not changed.** Its posInt, warehouse-value and cache helpers stop being used by inventory.js | Frozen (Services Catalog audit) |
| src/index.js | **Not changed** in Phase 1. Routes mount through the inventory router. `/get_techs` moves to the ledger after the freeze | Frozen |
| src/accessKeys.js, src/dashboardAccess.js, test/support.js | **Not changed.** Reversal is admin-only until `stock.adjust` can be added | Frozen |
| src/catalogImport.js, src/catalog.js | **Not changed** (Product Catalog). B needs the import to stop writing qty before any C7 mirror (D9) | Product Catalog |

### Android (IOHD-Android-App)

| File | Change |
|---|---|
| **New** StockRequestKey.kt | Makes a UUID per action and keeps it across rotation and Retry |
| InventoryFragmentV2.kt | Key per checkout tap; Retry on every failure with the same key; shows lines that didn't come off stock; sends `forTech` |
| PickList.kt | `Backend.checkout(payload, key)`; header; parse line outcomes |
| ScannerFragment.kt | Key per scan; Retry with the same key; 409 chooser for duplicated barcodes |
| CycleCountListFragment.kt | Key per submit; cursor from the zone load (line 233); `countedAgoMs` per item; per-item conflicts |
| app/src/test: PickListTest.kt, PickListScreenTest.kt, new ScannerRequestTest.kt, CycleCountSubmitTest.kt | JVM tests through the existing backend seam. No render golden refreshed without your OK |

### Other systems

| System | Change | When |
|---|---|---|
| IOHD Inventory Sheet | PickedItems columns G–J (movement id, request id, applied, shortfall). A: structure protection. B: PickedItems protected, a "Stock as of" cell, `_PickedSnapshot` tab removed later | A/B step, with your OK |
| Sheet-bound Apps Script project | Re-route (A) or remove the trigger (B). The repo copy is not deployed automatically; someone with edit rights runs it | A/B step |
| Render Postgres | Migrations 001 (shared) and 002 (B); `stock_settings` switches | Applied by you |
| Render web service | Normal deploys of the backend, each with your OK. No environment variable is required | Per release |
| Office app (iohd-flutter-app) | **None in Phase 1** | — |

---

## 3. Database migrations (proposed, not applied)

**Mechanism (D10):** versioned SQL files, reviewed, applied by you with `scripts/stock_migrate.js` before the deploy that
needs them. The code checks the schema version at start-up and refuses stock writes with 503 ("paused, nothing changed")
if it is missing. All changes are additive: no existing table is altered or dropped.

### 001_stock_core.sql (needed by A and B)

```sql
BEGIN;

CREATE TABLE stock_schema_migrations (
    version     integer     PRIMARY KEY,
    name        text        NOT NULL,
    checksum    text        NOT NULL,
    applied_at  timestamptz NOT NULL DEFAULT now()
);

-- One row per stock-changing request. The Idempotency-Key is the key.
CREATE TABLE stock_requests (
    request_id     uuid        PRIMARY KEY,
    kind           text        NOT NULL CHECK (kind IN ('checkout','scan','cycle_count','staging','staging_flush',
                                                        'reversal','adjustment','sheet_drift','opening')),
    actor_user_id  integer,                    -- users.id from the token; NULL only for server jobs
    actor_name     text        NOT NULL,
    on_behalf_of   text,                       -- the tech whose pick list it was
    client         text        NOT NULL,       -- 'android/35', 'android/legacy', 'server/flush', 'sheet/drift'
    key_source     text        NOT NULL CHECK (key_source IN ('client','server')),
    payload_hash   text        NOT NULL,       -- same key + different payload = 409
    status         text        NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','applied','rejected')),
    plan           jsonb,                      -- A: the Sheet writes about to be made (recover on acquire)
    response       jsonb,                      -- replayed verbatim on a retry
    created_at     timestamptz NOT NULL DEFAULT now(),
    finished_at    timestamptz
);
CREATE INDEX stock_requests_pending_idx ON stock_requests (created_at) WHERE status = 'pending';

-- Append-only. Under A: what the backend did to the Sheet. Under B: the stock itself.
CREATE TABLE stock_movements (
    movement_id           bigserial     PRIMARY KEY,
    request_id            uuid          NOT NULL REFERENCES stock_requests(request_id),
    line_no               integer       NOT NULL,
    kind                  text          NOT NULL CHECK (kind IN ('checkout','scan_deduct','scan_add','count_adjust',
                                            'staging_flush','reversal','adjustment','sheet_drift','opening')),
    outcome               text          NOT NULL CHECK (outcome IN ('applied','short','not_stocked','staged',
                                                                    'conflict','unchanged','rejected')),
    item_key              text,                       -- normalised Sheet name; NULL when nothing matched (C1)
    stock_item_id         integer,                    -- B only
    line_name             text          NOT NULL,     -- exactly as sent
    job_number            text,
    qty_requested         numeric(12,3) NOT NULL,
    qty_delta             numeric(12,3) NOT NULL,     -- signed change actually applied (0 if none)
    shortfall             numeric(12,3) NOT NULL DEFAULT 0,
    balance_before        numeric(12,3),
    balance_after         numeric(12,3),
    sheet_row             integer,                    -- A: diagnosis only
    reverses_movement_id  bigint        REFERENCES stock_movements(movement_id),
    reason                text,
    actor_user_id         integer,
    actor_name            text          NOT NULL,
    business_date         date          NOT NULL,     -- Chicago
    occurred_at           timestamptz   NOT NULL DEFAULT now(),  -- a count: when the shelf was counted
    recorded_at           timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (request_id, line_no)
);
CREATE INDEX stock_movements_item_idx ON stock_movements (item_key, movement_id);
CREATE UNIQUE INDEX stock_movements_reverse_once ON stock_movements (reverses_movement_id)
    WHERE reverses_movement_id IS NOT NULL;

CREATE FUNCTION stock_movements_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'stock_movements is append-only; record a reversal instead';
END $$;
CREATE TRIGGER stock_movements_no_update BEFORE UPDATE OR DELETE ON stock_movements
    FOR EACH ROW EXECUTE FUNCTION stock_movements_append_only();
CREATE TRIGGER stock_movements_no_truncate BEFORE TRUNCATE ON stock_movements
    FOR EACH STATEMENT EXECUTE FUNCTION stock_movements_append_only();

-- Warehouse picks held until 8:31, kept across restarts and deploys (H4).
CREATE TABLE stock_staging (
    staging_id        bigserial     PRIMARY KEY,
    request_id        uuid          NOT NULL REFERENCES stock_requests(request_id),
    business_date     date          NOT NULL,
    job_number        text          NOT NULL,
    item_key          text          NOT NULL,
    line_name         text          NOT NULL,
    qty               numeric(12,3) NOT NULL CHECK (qty > 0),
    staged_by_user_id integer,
    staged_by_name    text          NOT NULL,
    status            text          NOT NULL DEFAULT 'staged'
                          CHECK (status IN ('staged','flushed','superseded','cancelled')),
    flush_request_id  uuid          REFERENCES stock_requests(request_id),
    created_at        timestamptz   NOT NULL DEFAULT now(),
    updated_at        timestamptz   NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX stock_staging_live_idx ON stock_staging (business_date, job_number, item_key)
    WHERE status = 'staged';

-- Each scheduled job runs once a day, even with two servers up during a deploy (N3).
CREATE TABLE stock_job_runs (
    job          text        NOT NULL,   -- 'warehouse_audit', 'staging_flush', 'inventory_audit', 'nightly_check'
    run_date     date        NOT NULL,
    instance     text        NOT NULL,
    started_at   timestamptz NOT NULL DEFAULT now(),
    finished_at  timestamptz,
    outcome      text,
    PRIMARY KEY (job, run_date)
);

-- Switches flipped without a redeploy. Each flip is a production write: only with your OK.
CREATE TABLE stock_settings (
    key         text PRIMARY KEY,
    value       text NOT NULL,
    updated_by  text NOT NULL,
    updated_at  timestamptz NOT NULL DEFAULT now()
);
INSERT INTO stock_settings (key, value, updated_by) VALUES
    ('writes',          'open',     'migration 001'),  -- open | paused
    ('identity',        'log',      'migration 001'),  -- log | enforce          (C5)
    ('idempotency_key', 'optional', 'migration 001'),  -- optional | required    (H5)
    ('mode',            'sheet',    'migration 001');  -- sheet | ledger         (B)

INSERT INTO stock_schema_migrations (version, name, checksum) VALUES (1, 'stock_core', '<sha256 of this file>');
COMMIT;
```

### 002_stock_ledger.sql (B only)

```sql
BEGIN;

-- The parts whose quantity Postgres owns. Separate from inventory_items so Product Catalog data is untouched.
CREATE TABLE stock_items (
    stock_item_id      serial      PRIMARY KEY,
    item_key           text        NOT NULL UNIQUE,   -- lower case, trimmed, single-spaced Sheet name
    sheet_name         text        NOT NULL,
    part_number        text,                          -- not unique: 6 duplicates today (H9)
    inventory_item_id  integer,                       -- optional link to inventory_items.item_id; no FK, checked nightly
    allow_fraction     boolean     NOT NULL DEFAULT false,
    active             boolean     NOT NULL DEFAULT true,
    created_at         timestamptz NOT NULL DEFAULT now(),
    created_by         text        NOT NULL
);
CREATE INDEX stock_items_part_number_idx ON stock_items (part_number) WHERE part_number IS NOT NULL;

ALTER TABLE stock_movements ADD CONSTRAINT stock_movements_item_fk
    FOREIGN KEY (stock_item_id) REFERENCES stock_items(stock_item_id) NOT VALID;

-- Other names for the same part (Service Fusion line names, C1). Only rows you approve.
CREATE TABLE stock_item_aliases (
    alias_key      text        PRIMARY KEY,
    stock_item_id  integer     NOT NULL REFERENCES stock_items(stock_item_id),
    approved_by    text        NOT NULL,
    approved_at    timestamptz NOT NULL DEFAULT now(),
    note           text
);

-- Current on-hand, changed only in the transaction that records the movement explaining it.
CREATE TABLE stock_balances (
    stock_item_id     integer       PRIMARY KEY REFERENCES stock_items(stock_item_id),
    on_hand           numeric(12,3) NOT NULL,         -- add CHECK (on_hand >= 0) only if D6 = clamp
    last_movement_id  bigint        NOT NULL REFERENCES stock_movements(movement_id),
    updated_at        timestamptz   NOT NULL DEFAULT now()
);

-- What the projector last wrote to each Sheet row, so a hand edit can be recognised (drift).
CREATE TABLE stock_sheet_projection (
    stock_item_id  integer       PRIMARY KEY REFERENCES stock_items(stock_item_id),
    sheet_value    numeric(12,3) NOT NULL,
    movement_id    bigint        NOT NULL,
    projected_at   timestamptz   NOT NULL DEFAULT now()
);
CREATE TABLE stock_projection_cursor (
    target            text PRIMARY KEY,               -- 'inventory_qty', 'picked_items_log'
    last_movement_id  bigint NOT NULL DEFAULT 0,
    last_run_at       timestamptz,
    last_error        text
);

-- PickedItems as it stood at cutover, so pick lists and the 4 PM audit still count earlier picks.
CREATE TABLE stock_legacy_picks (
    sheet_row    integer PRIMARY KEY,
    picked_on    date,
    job_number   text,
    item_key     text,
    line_name    text NOT NULL,
    qty          numeric(12,3),
    user_name    text,
    imported_at  timestamptz NOT NULL DEFAULT now()
);

-- Nightly: any row here is a bug.
CREATE VIEW stock_balance_check AS
SELECT b.stock_item_id, b.on_hand, COALESCE(SUM(m.qty_delta), 0) AS ledger_sum
  FROM stock_balances b
  LEFT JOIN stock_movements m ON m.stock_item_id = b.stock_item_id
 GROUP BY b.stock_item_id, b.on_hand
HAVING b.on_hand <> COALESCE(SUM(m.qty_delta), 0);

INSERT INTO stock_schema_migrations (version, name, checksum) VALUES (2, 'stock_ledger', '<sha256 of this file>');
COMMIT;
```

Rollback of either file: the tables stay. They are new, nothing else reads them, and the code can be rolled back
independently. Dropping them is a separate decision, made only after a backup.

---

## 4. API and Android contract changes

Every change is additive. Old builds keep working until S13, and a rolled-back server ignores the new header and fields.

### Common to every stock write

- Request header `Idempotency-Key: <UUID v4>`; optional until S13.
- Response fields added: `requestId`, `replayed`.
- Status codes and whether a retry with the same key is safe:

| Code | Meaning | Changed anything? | Retry with the same key |
|---|---|---|---|
| 200 | Done, or replayed | Yes (once) | Returns the same answer |
| 400 | Invalid input | No | Pointless; fix the input |
| 401 | "Session expired. Please log in again." | No | After sign-in |
| 403 | Role not allowed | No | No |
| 409 | Key used for a different payload, still in progress, or barcode ambiguous | No | Yes for "in progress"; choose a part for "ambiguous" |
| 503 | Busy, paused or schema missing | No | Yes |
| 500 | Unknown | Maybe | **Yes, safe**: it replays or applies once |

The phone's current `changedNothing` rule already treats 4xx (except 408) as safe. With keys, 5xx and timeouts become safe
to retry too.

### `POST /checkout_inventory`

```jsonc
// request
{ "date": "11/18/2026",             // display only; the business date is the server's Chicago date
  "techName": "…",                  // ignored for attribution (kept for old builds)
  "forTech": "Brett Miller",        // new, optional: whose pick list
  "items": [ { "jobNumber": "1101400456", "name": "Keypad | Genie", "qtyUsed": 1 } ] }

// response (old fields kept; "message" still starts with "Items staged" when staged)
{ "status": "success" | "partial", "requestId": "…", "replayed": false,
  "itemsUpdated": 2,                // lines that changed stock (or were staged)
  "lines": [ { "jobNumber": "…", "name": "…", "qtyUsed": 1,
               "outcome": "deducted" | "staged" | "not_stocked" | "short" | "rejected",
               "remaining": 14, "shortfall": 0 } ],
  "message": "…" }
```

### `POST /scan_checkout`

- `action` must be `"add"` or `"deduct"` (400 otherwise; today anything else deducts).
- `qtyUsed` must be a whole number from 1 to 10,000.
- New optional `itemKey`, for resolving an ambiguous barcode.
- 409 for an ambiguous barcode:
  `{ "error": "That barcode is on 2 parts. Pick one.", "candidates": [ { "itemKey", "name", "location", "qty" } ] }`.
- Response adds `requestId`, `replayed`, `shortfall`.

### `POST /cycle_count_update`

```jsonc
// request
{ "zone": "Zone 2", "isComplete": false, "date": "11/18/26",  // date: display only
  "loadedCursor": "48211",                                     // new: X-Stock-Cursor from the zone load
  "items": [ { "name": "…", "countedQty": 12, "countedAgoMs": 420000 } ] }   // countedAgoMs new, optional

// response
{ "status": "success" | "partial", "requestId": "…", "replayed": false,
  "items": [ { "name": "…", "outcome": "applied" | "unchanged" | "conflict" | "not_found" | "invalid",
               "systemQty": 14, "countedQty": 12, "adjustment": -2, "movementsSince": 1 } ] }
```

`techName` is ignored; `counted_by` comes from the token.

### `GET /get_full_inventory`

The body is unchanged (an array), plus an optional `itemKey` per row. New response headers: `X-Stock-Cursor` (newest
movement id) and `X-Stock-Read-At` (when the quantities were read, the H7 groundwork). The office app needs no change.

### New endpoints

- `POST /stock/movements/:id/reverse`: admins (`requireAdminSession`), reason required, once per movement.
- `POST /stock/sheet_reversal`: Option A only. Called by the Apps Script with an HMAC over body and timestamp, using a
  dedicated secret kept in Script Properties, never API_SECRET.
- `GET /stock/health`: admins. Projection lag, pending requests, drift count, last nightly check.

### Android release

One build, versionCode 35 or later. It is distributed before S13, and S13 waits until tokenless and keyless stock writes
in the logs reach zero for 5 working days. Phone UI changes stay small (messages and one chooser dialog) to keep render
goldens stable.

---

## 5. Apps Script changes

Today: `onPickedChange` keeps a hidden copy of PickedItems and, when rows are deleted, writes `Inventory!D` directly. It
uses `parseInt` (C2), adds back the requested quantity (H1 phantom stock), restores absolute count values (H3), and its
script lock does not coordinate with the backend (C3). It runs as whoever installed the trigger. The repo copy is not
deployed from the repo: someone with edit rights to the Sheet's script project has to paste and run any change.

**Before any change (you, read-only):** export the current script and the trigger list from Extensions > Apps Script, and
note any other script projects, add-ons or triggers on the Sheet (S0).

**Until the A/B step:** no script change. Ask the office not to delete PickedItems rows to undo a pick. Corrections are
made in D (recorded as drift after S7).

**Option A:**
- `reverse_` no longer writes the Inventory tab. For each removed row it POSTs `{row content, movement id (G), request id (H)}`
  to `/stock/sheet_reversal`.
- The backend reverses exactly the applied change of that movement, once. A count is reversed by the inverse adjustment.
- Rows from before the change (no movement id) are refused and listed for the office, not guessed at.
- Failures are retried by a 5-minute time trigger from a "pending reversals" queue in Script Properties.
- The parser is fixed for anything the script still reads.

**Option B:** replace the file with `teardown()`, which deletes the `onChange` trigger. Run it at cutover. Deleting a
PickedItems row then does nothing to stock, and PickedItems is protected. The hidden `_PickedSnapshot` tab is deleted later,
with your OK. Reversals are made with `POST /stock/movements/:id/reverse` (Phase 4 adds a button).

**Tests:** `test/apps_script_undo.test.js` runs the .gs file in a Node `vm` with a fake `SpreadsheetApp`, `LockService` and
`UrlFetchApp`. It characterises today's bugs and checks the new behaviour.

---

## 6. Regression test plan

Harness case ids differ from the audit's finding ids: harness C1a–d is audit C2, harness C2 is C3, harness C3 is C4,
harness C4 is C1. The table uses the audit's ids.

Test files (all new unless stated):

- `test/stock_fakes.js`: the harness's fake Sheet (formatted values, delayed reads, a hook to change rows mid-write) and
  an in-memory stock store whose lock is shared between two router instances, which stands in for two servers.
- `test/stock_quantity.test.js`, `test/stock_writes.test.js`, `test/stock_auth.test.js`, `test/apps_script_undo.test.js`.
- `test/stock_writes_sql.test.js`: needs `TEST_DATABASE_URL` (a throwaway local Postgres, never Render), like the
  existing SQL tests.
- `test/stock_projection.test.js` (B).
- Android JVM tests as listed in section 2.

| Finding | Harness case | Test (assert) | Step |
|---|---|---|---|
| C1 different-name checkout | C4 | "Stop Mold \| 7' White" ×2 returns `partial`, line `not_stocked`, an unmatched movement recorded, the Weather Seal row unchanged. With an approved alias it deducts the Weather Seal row (60 → 58) | S8 |
| C2 1,000+ misread | C1a–d | Parser table ("1,250.00", "$1,250.00", 1250, "", "abc", "-3", "=10*10"). Checkout 1 from 1,250 → 1,249. Scan add 5 → 1,255. Count "previous" = 1,250. Warehouse value $200,489.00. The undo script (A) parses 1,250 | S2 |
| C3 lost update | C2 | Two concurrent checkouts (2 and 3 from 163) on **two router instances** → 158. B: the same with two Postgres connections → 158 and two movements | S7 / B |
| C4 wrong-row write | C3 | Row inserted above between read and write: Light Bulb stays 163, Stop Mold → 59 (or a retry, never a write to another part). B: the projector writes a wrong row, and the next pass restores both | S7 / B |
| C5 shared key alone | H-auth, H-auth-cc | Key only → 401 on checkout, scan and count (enforce mode). Inactive user → 401. `svc` token → 401. Body `techName` and `x-user-role` don't change the recorded person or staging. TOKEN_SECRET unset or equal to API_SECRET → 503 on stock writes | S5, S13 |
| C6 live statuses | — | Not Phase 1. Existing `test/stock_levels_test.dart` covers the rewrite's rule; the fix is a release (Phase 3) | — |
| C7 stores disagree | — | Not Phase 1 by default. If D9 pulls it in: after any movement, `inventory_items.qty` for a linked item equals `stock_balances.on_hand` | (B) |
| H1 over-checkout | H-clamp | Take 5 of 2: shortfall 3 recorded and returned; balance −3 or 0 per D6. Reversal returns exactly 2. A second reversal → 409 | S8 |
| H2 count input | H-cc-input | "=10*10", -4, 2.5, "abc", null, non-string name, duplicate names → 400, nothing written. A valid count is written RAW as a number | S3 |
| H3 count wipes movements | — | Counted 10 with countedAgoMs before a checkout of 2 → 8. No time and a movement since the cursor → `conflict`, nothing applied. Reversing a count keeps later checkouts | S10 |
| H4 staging lost | M-staging | Staged rows survive a new router instance. The flush on two instances at once runs once. A flush failing after the log append doesn't repeat next day (N2). The staging decision ignores the header and body | S9 |
| H5 retries double | — | The same key twice → one movement, `replayed: true`. Same key with a different payload → 409. Two in flight → one applied, the other replays. Android: Retry reuses the key | S6, S11 |
| H6 logged not deducted | — | A: the Sheet write throws → nothing logged, request rejected, retry applies once. The log append throws → stock changed, log row appended by recovery exactly once. B: rollback leaves nothing; the projector later appends once | S7 / B |
| H7 freshness | — | `X-Stock-Read-At` equals the read time, not the response time | S10 |
| H8 office corrections | — | Hand edit of D (60 → 55) → `sheet_drift` movement −5 before the next write; nothing lost | S7 / B |
| H9 duplicate barcode | M-dup-part | Scan 4128527 → 409 with both parts, nothing changed. Resend with `itemKey` → the 893MAX row | S8 |
| M5 fractions | M-fraction | 0.5 and 2.5 → 400, nothing written (not dropped or truncated) | S2 |
| N1 same part twice | probe | 3 + 1 from 40 → 36. The same in the staging flush | S2 |
| N3 two servers | — | Each cron registered on two instances runs once per day | S9 |
| N5 count retry | — | A count retried with the same key → applied once, no duplicate log rows | S6 |

The existing stock tests (stock_levels 3/3, phone_route_access 10/10, pick_list 8/8, inventory_strikes 5/5,
catalog_inventory_link 12/12, dashboard_access 19/19) must stay green at every step. The one expected change is the
phone_route_access test that pins the no-token cycle-count path, which flips at S13.

---

## 7. Migration and rollback

### Releases

| Release | Contents | Rollback |
|---|---|---|
| R1 hotfix | S2, S3 (parser, RAW, N1, validation); no schema | Redeploy the previous commit |
| R2 | S4–S7 (schema 001, identity in log mode, request ids, lock, verify, movement log) | Redeploy the previous commit; tables stay unused |
| R3 | S8–S10 | Same |
| Android 35 | S11 | The server stays compatible with old builds |
| R4 | A (A1–A3) or B (B1–B6) | Below |
| R5 | S13 enforcement | Flip `stock_settings` back |

Every release is your OK, then a deploy, then a check on production reads.

### Option B cutover

- **Shadow, 1–2 weeks before.** Mode stays `sheet`. Every backend write also records movements (from R2). A nightly
  report replays an opening snapshot plus the movements and compares the result with the Sheet. Differences are hand
  edits, the Apps Script, or bugs. Each one is explained before cutover.
- **Mapping sign-off.** `scripts/stock_mapping_report.js` (read-only) lists the 446 rows with their proposed keys,
  duplicate keys (cutover is blocked until resolved), the 6 duplicate barcodes, non-numeric or formula D cells (read with
  `FORMULA` rendering), and proposed aliases. You approve the list.
- **Cutover, about 20 minutes after 4:30 PM or on a weekend.** Each step is a production write, made only with your OK:
  1. Set `writes = paused`. Phones get 503 "paused, nothing changed", which is safe to retry.
  2. Run `teardown()` in the Sheet's script.
  3. Read `Inventory!A:H` (unformatted) and PickedItems. Write the opening movements and `stock_legacy_picks`. Check that
     total units equal the Sheet total (4,366 on the audit day).
  4. Set `mode = ledger`. Run a full projection: **0 cells should change**. Any change means stop and roll back.
  5. Set `writes = open`. An admin scans a test part in and out and checks the Sheet, the log and the ledger.
- **Rollback.** Before step 5: `mode = sheet`, reinstall the trigger, `writes = open`. After go-live: pause, let the
  projector catch up, check that Sheet equals balances (report), set `mode = sheet`, reinstall the trigger if wanted,
  unpause. The ledger keeps its history; nothing is deleted.

### Option A

- Protection and the script re-route are applied with your OK, after exporting the current script.
- Rollback: remove the protection, reinstall the exported script.
- No data moves, so there is nothing to restore.

---

## 8. Implementation order and dependencies

| Step | What | Needs | Can run alongside |
|---|---|---|---|
| S0 | Pre-flight, you, no code: check Render logs for the "TOKEN_SECRET is not set" start-up line; export the Sheet's scripts and triggers; confirm Postgres backups and point-in-time restore on the plan; confirm how phones get builds; Services Catalog audit status; decisions in section 9 | — | S1 |
| S1 | Regression tests in the repo, all `todo` | — | S0 |
| S2 | Parser, unformatted reads, RAW writes, N1 merging, warehouse value in the stock module | S1 | S3 |
| S3 | Input validation (zod is already a dependency) | S1 | S2 |
| S4 | Migration runner + 001 (applied by you) | D10 | S2, S3 |
| S5 | Identity and roles in log mode | S4, D2, D3 | S6 |
| S6 | Request ids and replay | S4 | S5 |
| S7 | Cross-server lock, locate-and-confirm, stock then log, movement log, drift record, pending alert | S6 | — |
| S8 | Line outcomes, shortfall, unmatched lines, ambiguous barcodes | S7, D6, D7 | S9, S10 |
| S9 | Durable staging, run-once crons | S7, D8 | S8, S10 |
| S10 | Count conflicts, cursor and read-time headers | S7 | S8, S9 |
| S11 | Android build | Contract agreed (section 4); build against S6–S10 | S6–S10 |
| S12 | A1 recover-on-acquire, A2 protection + drift report, A3 script re-route — **or** B1 mapping, B2 schema 002 + write path, B3 pick-list and audit reads, B4 projector, B5 shadow, B6 cutover + teardown | S7–S10, D1 | B1 can start at S4 |
| S13 | Enforce identity; require request ids; refuse legacy counts | S11 out on every phone | — |

The fastest high-value change is R1: S2 stops N1 and C2, which are losing stock every day. It needs no schema.

---

## 9. Decisions and risks for you

### Decisions needed

| # | Decision | Options | My recommendation | Needed by |
|---|---|---|---|---|
| D1 | System of record | A or B | **B**, after the shared steps | S12 |
| D2 | warehouse1 is shared | (a) personal warehouse accounts (Dennis already has one); (b) keep the station login but ask for a personal PIN on each stock change; (c) accept "Warehouse station" as the identity | (a), or (b) if the phone is passed around | S5 |
| D3 | TOKEN_SECRET | Confirm it is set and differs from API_SECRET. If not, approve setting it, which signs everyone out once. Stock writes refuse until it is right | Confirm before R2 | R2 |
| D4 | When the shared key alone stops working for stock writes | Log-only first, then enforce; or enforce at once | Log for 5 working days after the Android build, then enforce | S13 |
| D5 | What the office may still do on the Sheet in Phase 1 | (a) edit quantities only: structure protected, edits recorded as drift; (b) nothing, via an Adjustments tab the backend applies; (c) as today | (a) until Phase 4 screens | S12 |
| D6 | Over-checkout | Negative on-hand plus a count flag; or clamp at 0 and record the shortfall | Negative plus flag | S8 |
| D7 | Unmatched checkout lines | Accept, record and tell the phone; or reject the whole checkout. Separately: approve the 7 alias mappings from the audit now, or wait for Phase 2 id matching | Accept and record; approve the 7 aliases now | S8 |
| D8 | Staging | Keep it, durable, with replace semantics; switch to add semantics once pick lists show staged quantities; or drop staging and check out at once | Keep, durable, replace | S9 |
| D9 | B and Product Catalog | The catalog import must stop writing `inventory_items.qty` before any C7 mirror. Mirror the ledger into `inventory_items.qty` in Phase 1 or Phase 2 | Phase 2. Don't run the catalog import between cutover and that change | B2 |
| D10 | Schema changes | Versioned SQL applied by you; or the repo's runtime `CREATE TABLE IF NOT EXISTS` pattern | Versioned SQL | S4 |
| D11 | Shared files under the Services Catalog audit | Keep the plan's workarounds (no edits to services.js, index.js, accessKeys.js, test/support.js); or tell me when the freeze lifts | Workarounds now; move `/get_techs` and add `stock.adjust` after the freeze | S7 |
| D12 | B cutover window and the Postgres allow-list | Pick a time; decide whether to restrict the 0.0.0.0/0 allow-list once Postgres holds the stock | After 4:30 PM on a weekday; restrict the allow-list | B6 |

### Defaults I assumed (say if you disagree)

- Scan add stays open to techs (returns), now with identity. Tightening it to warehouse and admin is a one-line change.
- Count conflicts with no counting time are refused for recount, not applied and not held for the office.
- An ambiguous barcode asks the person to pick. Cleaning up the 6 duplicate part numbers on the Sheet is yours to approve.
- Whole numbers only in Phase 1; fractional checkouts get a clear 400.
- One global lock under A; per-part row locks under B.
- Work happens on branches or worktrees named `stock-phase1` in integrity-backend and IOHD-Android-App. Nothing is
  merged, deployed or distributed without your OK, and no golden image is refreshed.

### Risks

| Risk | Option | Mitigation |
|---|---|---|
| Old phones without the new build fail once enforcement is on | Both | Log mode first; enforce only after zero legacy writes for 5 days |
| Apps Script keeps writing D uncoordinated until S12 (2–3 weeks) | Both | Ask the office not to delete PickedItems rows; drift is recorded from S7 |
| Owners can always edit protected ranges | A | Drift detection; habit change |
| Google's per-user quota under morning bursts | A (and today) | 429 handling with backoff; fewer reads per write |
| Wrong mapping at cutover gives wrong opening balances | B | Shadow period, signed-off mapping, "0 cells change" check |
| The office edits D expecting it to stick | B | Drift becomes an adjustment (D5) and the "Stock as of" cell |
| The projector lags and Sheet readers see old numbers | B | Health endpoint, alert after 5 minutes of lag, freshness cell |
| A part renamed on the Sheet looks like a new part | B | Report possible renames (same part number or position) for linking |
| Postgres becomes critical for stock writes | B | It already is for pick lists; backups and point-in-time restore checked in S0 |
| Strike rules change by accident | Both | Only the data source and run-once change; strike tests stay green |

---

## 10. Scope and isolation

### Estimate (one engineer, engineering days)

| Work | Days |
|---|---|
| S1 tests | 1.5 |
| S2 parser, RAW, N1 | 1 |
| S3 validation | 0.5 |
| S4 migrations | 1 |
| S5 identity | 1 |
| S6 request ids | 1.5 |
| S7 lock, verify, log order, drift | 2 |
| S8 outcomes, shortfall, barcodes | 1.5 |
| S9 staging, crons | 1.5 |
| S10 count conflicts | 1.5 |
| S11 Android, plus real-phone testing | 4–5 |
| **Shared total** | **about 17–18** |
| Option A completion | about 5 → **A total about 22–23 days (4–5 weeks)** |
| Option B completion (mapping 2, ledger write path 3, reads 1.5, projector 3, shadow compare 1, cutover rehearsal on a copy of the Sheet 1.5, teardown 0.5) | about 12.5, plus 1–2 weeks of shadow running → **B total about 30 days (6–7 weeks) of calendar time** |

If B is chosen after the shared steps, about 2 days of shared work (the Sheet lock path) is thrown away at cutover. If A is
chosen and B follows later, the A-only work (about 5 days) is thrown away.

### What can safely be isolated from other projects

- **Safe now:** every new file in section 2; src/inventory.js and src/stockLevels.js (Stock Levels' own; both repos are
  clean and the Services Catalog session hasn't touched them); apps_script/picked_items_undo.gs; the Android pick list,
  scanner and cycle-count files and their tests.
- **Frozen while the Services Catalog audit runs, worked around in Phase 1:** src/services.js, src/index.js,
  src/accessKeys.js, src/dashboardAccess.js, src/fieldAccess.js, test/support.js, test/action_permissions.test.js,
  lib/config/access.dart, lib/widgets/flat_page.dart.
- **Out of bounds:** Product Catalog (catalog*.js, catalogImport.js, product screens), Services Catalog, Payroll, other
  screens, golden images, production configuration and permissions.

---

## Appendix: method and limits

**Read:**
- Backend: inventory.js (all of it), stockLevels.js, auth.js, services.js (inventory helpers), pickRules.js,
  migrate_invnetory.js, catalogImport.js (the stock section), the relevant parts of index.js, stock_levels.test.js,
  phone_route_access.test.js, test/support.js.
- picked_items_undo.gs.
- Android: ApiClient, PickList, InventoryFragmentV2, ScannerFragment, CycleCountListFragment, CycleCountApi, Ui.
- The audit's harness and results, and the two Render audits' notes on instances and deploy overlap.

**Ran:** one in-memory probe, `/private/tmp/claude-501/-Users-johneccleston/f49f32f9-077f-4348-aa04-97e67502b0bc/scratchpad/plan_probe/probe_same_part.js`.
It runs the real inventory router against a fake Sheet, with no network, Google or Postgres. I also read the audit's
existing local Sheet snapshot to size N1.

**To know which files to freeze,** I looked at which files the Services Catalog session has been reading.

**Not verified:**
- Production TOKEN_SECRET and ENFORCE_USER_AUTH.
- Other scripts, triggers or add-ons on the Sheet.
- The Postgres plan's backups and point-in-time restore.
- This Google project's actual quotas.
- How phones receive builds.
- Real phones.
