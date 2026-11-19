# R2 for review: request ids, cross-server lock, row confirmation, identity (log only)

19 Nov 2026. Local development only, in the Stock Levels worktree `C:\Users\opera\integrity-backend-stock-phase1` (branch
`stock-phase1`, on top of R1 `983535d7`). **Not committed, pushed, deployed or applied to production.** No Sheet writes, no Render
changes, no Android work. The Services Catalog worktree and its frozen files were not touched. Full diff:
`r2-evidence/r2.patch`.

**Status after your 19 Nov review:** accepted for continued local review. Migration 001 not applied; Render untouched; R2 not deployed.
Since then the R2 tree has gained R1b, the likely-mismatch push (see `r1b-mismatch-notice.md`). In R2 its retry dedupe is shared
across servers through `stock_job_runs`.

## Limitations kept documented (your list, 19 Nov)

These four stay true after R2 and must stay in front of any release decision:

1. **In-memory warehouse staging can still be lost during a deployment.** Picks staged before 8:31 live in one server's memory until
   S9; a deploy or restart before the 8:31 flush drops them, and stock is never taken off for them.
2. **Direct Sheet edits are not coordinated by the Postgres application lock.** The lock keeps program writers apart. A person editing
   the Inventory tab is never locked. Row confirmation and read-back narrow the risk to a sub-second window and repair a wrong-row write,
   but a hand edit of the very same cell in that window can still be overwritten.
3. **The shared app key remains authorized for stock changes** until the later enforcement step (S13, after the Android build). R2
   records `shared_key_only` writes; it refuses nothing.
4. **No real Sheet or phone validation has occurred.** Every Sheet behaviour was tested against the in-memory fake, every database
   behaviour against a local PostgreSQL 18.6, and no phone has run against R2.

## What R2 does

| Area | Behaviour |
|---|---|
| Migration 001 | `db/migrations/stock/001_stock_core.sql`, applied only by `scripts/stock_migrate.js`. Additive: 8 new `stock_*` tables, no existing table touched. Until it is applied, stock writes answer **503 "Nothing was changed"** (fail closed). |
| Request ids (H5, N4, N5) | `Idempotency-Key: <UUID>` header. The `stock_requests` primary key decides, across servers. The same key and payload replay the stored answer (`replayed: true`); another payload or another person gets 409; a request still running gets 409 "still being processed". Old builds send no key, so the server makes one (`key_source = server`) and they behave exactly as today. |
| Failure endings | Nothing written yet → `rejected`, 503 "Nothing was changed", and a retry with the same key runs once. Something written → `needs_review`, 500 "may be partly saved… Do not send it again", a 🚨 log line, and a retry with the same key is refused. |
| Cross-server lock (C3, N3) | Every program write to the Inventory Sheet (checkout, staging, scan, cycle count, 8:31 flush) holds one `pg_advisory_xact_lock`. Writers queue on their own server first, so each server uses at most one pooled connection for stock. They wait up to 8 s for the lock, then get 503 busy. If a holder hangs, Postgres ends its session after 120 s, which frees the lock. |
| Crons (N3) | The **4 PM audit** runs once per Chicago day (`stock_job_runs`). The **8:30 strike** is applied at most once per day. Each server still judges from its own staging, which stays in memory until S9. The **8:31 flush** still runs on every server, because each holds its own staged picks; it now goes under the lock as a server request. |
| Row identity (C4) | Read → plan → re-read just those rows and confirm the part name and the cell are unchanged (else plan again) → write RAW → read back. If a row moved in that moment, the other part's value is put back (only if our number is still in the cell) and the write is redone. After 3 tries with nothing written: 503. |
| Order (H6) | Stock first, then the PickedItems log (2 retries). A failed stock write leaves nothing logged. |
| Movements | One `stock_movements` row per line (applied, short, not_stocked, staged, rejected, unchanged), with person, job, before and after. Append-only, enforced by a database trigger. |
| Identity (C5, N6, N7), **log only** | The person comes from the login, never the typed name. On `warehouse1` the person sends `x-stock-operator-id` plus `x-stock-operator-pin` (their own PIN, checked with the existing `auth.verifyPin`, scrypt). Only people in `stock_station_operators` count, and **that table is empty until you send the list**. Results: `user`, `station_operator`, `station_unverified`, `shared_key_only`, `untrusted_token`, `service`. Nothing is refused; anything short of a personal identity is recorded and logged. |
| PIN rate limit | In Postgres, per person and per station, held across servers by an advisory lock per person: 5 wrong in 15 min, 10 in 24 h, 20 per station in 15 min. Inactive users, people not on the list and temporary PINs count as failures. |

**Unchanged on purpose:** what the phone is told (plus `requestId` and `replayed`), the PickedItems columns and the typed name in them, the
staging rule (still the typed name or `x-user-role`; S5/S9), the in-memory staging (S9), the clamp at 0 (S8), name matching (C1/D7), the
Sheet as the record (D1). R2 implements only `identity = log` and `idempotency_key = optional`. Other values in `stock_settings` are logged
and ignored.

## The migration file

`db/migrations/stock/001_stock_core.sql`, sha256 (line endings normalised) `f15406f9118e104d9a6c1110b5bcf29112c97d152fa4f7842fb2cd9122648e70`.

Differences from the plan's section 3:
1. The runner writes the version row and checksum (a file can't hold its own hash).
2. `stock_requests` records route, identity, identity detail, station, `needs_review` and attempts.
3. Two new tables for the warehouse PIN: `stock_station_operators` (empty) and `stock_pin_attempts` (no PIN or hash is ever stored).
4. `stock_settings` values are constrained by a CHECK.
5. Movement kind `staging` was added.

**Apply (your step, never on deploy), in this order:**
1. Confirm a Postgres backup or point-in-time restore exists (S0).
2. `node scripts/stock_migrate.js --database-url "<prod url>" --confirm-database <db name> --status` (the database name must match, or
   nothing runs; `DATABASE_URL` is never read; the password is never printed).
3. The same with `--dry-run`: it applies inside a transaction and rolls back.
4. The same with `--apply --applied-by "John Eccleston"`.
5. Only then deploy the R2 code. The other order would answer 503 on every stock write until the migration is in.

**Rollback**
- Code: redeploy the previous commit (R1). The tables stay unused and harmless. No data moves.
- Schema (a separate decision, after a backup): `pg_dump --data-only -t 'stock_*'`, then
  `node scripts/stock_migrate.js … --rollback 1`. It runs `001_stock_core.rollback.sql` in one transaction and drops only the `stock_*`
  objects. Roll the code back first, or stock writes go back to 503.
- Settings: `UPDATE stock_settings SET value = 'paused', updated_by = '<name>' WHERE key = 'writes'` stops every stock write with 503
  "Nothing was changed", without a deploy (a production write: only with your OK).

## Test results (re-run 19 Nov after R1b was added)

| Run | Result |
|---|---|
| Stock tests (`stock_r2`, `stock_r2_sql`, `stock_mismatch`, `stock_writes`, `stock_quantity`) with the local database | **110 tests: 101 pass, 0 fail, 9 todo** (`r2-evidence/stock_tests_r2.txt`) |
| `stock_r2.test.js` (router + in-memory store) | 31 / 31 |
| `stock_r2_sql.test.js` (real PostgreSQL 18.6, the version production runs; throwaway local cluster) | 19 / 19, five clean runs in a row |
| `stock_mismatch.test.js` (R1b) | 18 / 18 |
| R1 todo tests now passing (promoted) | C3 two servers, C4 row inserted mid-write, H5 same id twice, H6 nothing logged on a failed write, N3 one strike on two servers |
| Still todo (later steps, untouched) | C1 aliases, C5 enforcement, H1, H3, H4 x3, H9, N2 |
| Full suite, no database | 629 tests: 507 pass, 2 fail, 9 todo, 111 skipped (`full_suite_no_db.txt`) |
| Full suite with the local database, R2 vs untouched R1 | 699 tests: 677 pass, 13 fail, 9 todo. **The 13 failures are the same as R1's** (`failures_R1.txt` = `failures_R2.txt`, no new and none fixed): environment- and date-dependent tests (the access.dart cross-repo check, CRLF in a catalog fixture, commission/payments SQL tests on a scratch database). |

One run in the middle of the day stalled: a database connection was left idle inside a transaction until Postgres's 120 s limit ended
it, and the local server then crashed with a Windows process error (0xC0000142, "could not reserve shared memory"). After a clean restart
the SQL file passed five times in a row, with no idle-transaction terminations or lock waits in the server log. I could not reproduce the
stall and can't rule out that it came from the R2 code rather than the crashing server, so it is listed under risks.

The SQL tests ran against a scratch cluster in the session's temp folder (port 55433), never against Render. Each run creates and drops its
own database.

## Changed files (backend worktree, uncommitted)

| File | Change |
|---|---|
| `db/migrations/stock/001_stock_core.sql` | new: migration 001 |
| `db/migrations/stock/001_stock_core.rollback.sql` | new: rollback |
| `scripts/stock_migrate.js` | new: runner (status, dry-run, apply, rollback; checksums; confirm-database guard) |
| `src/stockStore.js` | new: Postgres store (schema check, settings, requests, lock, job claims, PIN check) |
| `src/stockRequests.js` | new: the request lifecycle (key, replay, failure endings) |
| `src/stockAuth.js` | new: identity, log only |
| `src/stockWrites.js` | new: the write path (checkout, staging, flush, scan, count) and movements |
| `src/stockErrors.js` | new: `StockError` (did anything change?) |
| `src/stockSheet.js` | `writeConfirmed`, `appendLog`; `planDeductions` adds `key` and `beforeRaw` |
| `src/inventory.js` | write routes and the 3 crons moved onto the above; optional third argument for tests; `index.js` unchanged |
| `test/stock_fakes.js` | `batchGet`, `beforeBatchGet`, repeated failures, in-memory store |
| `test/stock_r2.test.js`, `test/stock_r2_sql.test.js` | new |
| `test/stock_writes.test.js`, `test/stock_quantity.test.js` | 5 todos promoted; expectations take the new fields |
| `src/stockMismatch.js` | new (R1b): likely-mismatch rule, message, once-per-checkout notifier |
| `src/stockWrites.js`, `src/inventory.js` | (R1b) checkout returns the rows it read; the route sends the notice after answering; claim in `stock_job_runs` |
| `test/stock_mismatch.test.js` | new (R1b), 18 tests |
| `test/fixtures/stock_sheet_rows_2026-11-18.json`, `stock_job_line_names_2026-11-19.json`, `stock_mismatch_flagged_2026-11-19.json` | new: Sheet snapshot, every production job line name (names and counts only), the reviewed flagged list |

Not changed: `index.js`, `services.js`, `auth.js`, `accessKeys.js`, `dashboardAccess.js`, `test/support.js`, the catalog files, the Android
app and the office app.

## Security evidence

- **PIN never stored, logged or returned.** It is read from the header and the header is deleted at once (test: "the router removes the
  PIN header…"). The test that captures console output plus every stored request, movement, attempt, answer and log row finds neither
  PIN. The SQL test dumps `stock_pin_attempts` and finds no PIN. No request logger records headers (`requestTiming.js` was checked).
- **No oracle:** in log mode the answer says nothing about the PIN (test asserts no "pin", "operator" or "verif" in the answer).
- **Brute force:** at most 10 wrong guesses per person per 24 h, across servers, including parallel guesses (SQL test: 8 parallel guesses
  on 2 pools give 5 `bad_pin` and 3 `rate_limited`; then even the right PIN is refused). Temporary PINs never verify.
- **Existing hash check reused:** `auth.verifyPin` (scrypt, timing-safe). No new hashing code; nothing rehashes or writes `users`.
- **SQL:** every value is a bound parameter. The only interpolations are two `SET LOCAL` timeouts: a constant, and `lockWait`, which is
  checked against `^\d+(ms|s)$` when the store is created.
- **Fail closed:** schema missing or writes paused → 503 before the Sheet is read (tests on both stores).
- **Identity cannot be borrowed:** a key reused by another signed-in person is a conflict, never a replay of their answer.
- **Production TOKEN_SECRET (D3, N7):** the 18 Nov start-up log of instance `w55jg` has no "TOKEN_SECRET is not set" line, so it is set and
  differs from the app key. This is inferred from the log; I did not read the environment.
- **No secrets added.** The migration runner never reads `DATABASE_URL` and redacts the URL in its output.

## Remaining risks

1. **Identity is log only.** The app key alone still changes stock until S13. That needs the Android build that sends tokens, keys and
   operator headers.
2. **The operator list is empty.** Every warehouse1 write is recorded as `station_unverified` until you send the list and the phone sends
   the headers (Android).
3. **People on the Sheet can't be locked.** A hand edit of the very same cell between the confirm and the write can still be overwritten.
   The window is sub-second, and only Option B removes it.
4. **Staging is still in memory (S9).** A deploy before 8:31 drops staged picks. With two servers up at 8:30, the server without the staging
   can strike (now at most once).
5. **A Sheet outage or quota limit** gives 503s (nothing changed). The extra confirm and read-back reads (2 per write) add a little quota
   use and about 0.3–0.6 s per write.
6. **`needs_review` requests** need someone to look at them. There is no screen yet (Phase 4). They show in the logs and in
   `SELECT * FROM stock_requests WHERE status = 'needs_review'`.
7. **Zone progress after a count** is saved after the request is marked applied. If that insert fails, a retry replays success without
   saving the progress (rare; the same as R1's 500 there).
8. **Deploy order:** deploying R2 before migration 001 stops stock writes (503) until it is applied.
9. **Not tested on real phones or the real Sheet.** All Sheet behaviour is against the in-memory fake.
10. **One unexplained test stall** (above): not reproduced in five clean runs. If it was the code, the symptom is a stock write
    holding the lock until Postgres ends the session after 120 s (other writers get 503 "busy, nothing changed" meanwhile).
