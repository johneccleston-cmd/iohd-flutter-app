# R1 + R1b release readiness, final (phone push deferred)

19 Nov 2026. Owner's decision: **option A**, which releases R1 + R1b with employee push notifications deferred until Android supports them.
Nothing was committed, pushed, merged, deployed, migrated or installed. No notification was sent. Production was only read: read-only SQL,
Render logs and `git ls-remote`.

## Why the push is off

The installed builds never register for pushes:
- Build 33 (`1fe6546`) has `//registerFcmToken()` commented out.
- Build 34 (`551c61b`) has `ENABLE_PUSH = false`.
- Neither build has `onNewToken`.

Production `users`: 1 of 13 has an FCM token (a Technician, 2026-11-12), and `warehouse1` has none.

## Exact candidate

| | |
|---|---|
| Base (live) | `030f3b906f115aeb017b00d817c968022b8a0806`, still remote `main` and live deploy `dep-dbuu7itg1s2s739ipe30` on 19 Nov |
| R1 | `983535d7835a2d2fc7a31ba6795aa50afc4608f9` (parent `030f3b90`, fast-forward; = remote `stock-phase1`) |
| R1b, release form | `r1b-evidence/r1b-final.patch`, sha256 `65e3b15fe4b662ecaef39301892390cd1c27bb8b8aa73fd64320dab6b069fb5b` |
| What changed since the approved R1b | `r1b-evidence/r1b-push-off.patch` (sha256 `e8825e2f…a05f`), which is the approved `r1b.patch` (`43ad76d7…a606a`) plus the push switch |

Apply the patch with `patch --binary -p1` on a CRLF (autocrlf) checkout of `983535d7`. A fresh `git archive 983535d7` with `r1b-final.patch`
applied is **byte-identical** to the tree that was tested.

**Excluded:** all R2 work (`db/`, `scripts/stock_migrate.js`, `src/stockAuth|Errors|Requests|Store|Writes.js`, `test/stock_r2*.test.js`,
and the R2 edits in the worktree). **Migration 001 is not part of this release.** R1/R1b run no SQL and touch no R2 table.

### The push switch (the only change since approval)

- `src/stockMismatch.js`: `createMismatchNotifier({ …, push = false })`. Unless `push === true`, it finds the mismatches, writes the
  `🧩 Likely name mismatch…` office log line for each, and returns `{ sent: false, reason: 'push_off' }`. It does no token lookup, no
  dedupe claim and no send.
- `src/inventory.js`: `push: process.env.STOCK_MISMATCH_PUSH === 'on'`. The variable is not set on Render, so production needs **no
  configuration change** to keep the push off. Only the exact string `on` enables it; `true`, `1`, `ON`, ` on` and the like do not.
- Unchanged: the rule, the message text, the dedupe and the FCM path. The push only needs switching on later.

## Files changed vs live (11)

`src/inventory.js` (modified). New: `src/stockQuantity.js`, `src/stockSheet.js`, `src/stockMismatch.js`, `test/stock_fakes.js`,
`test/stock_quantity.test.js`, `test/stock_writes.test.js`, `test/stock_mismatch.test.js`, `test/fixtures/stock_sheet_rows_2026-11-18.json`,
`test/fixtures/stock_job_line_names_2026-11-19.json`, `test/fixtures/stock_mismatch_flagged_2026-11-19.json`.

## Tests (exact candidate, Node 24.14.0, no database, `STOCK_MISMATCH_PUSH` and `FIREBASE_JSON` unset)

| Run | Tests | Pass | Fail | Skip | Todo |
|---|---|---|---|---|---|
| `stock_quantity.test.js` | 11 | 11 | 0 | 0 | 0 |
| `stock_writes.test.js` | 31 | 17 | 0 | 0 | 14 |
| `stock_mismatch.test.js` | 23 | 21 | 0 | 2 (R2 only) | 0 |
| stock_* + pick_list + inventory_strikes + catalog_inventory_link | 93 | 77 | 0 | 2 | 14 |
| **Full suite, final candidate** | 584 | 474 | **2** | 94 | 14 |
| Full suite, approved R1+R1b (before the switch) | 579 | 469 | 2 | 94 | 14 |
| Full suite, live `030f3b90` | 519 | 425 | **2** | 92 | 0 |

- **The same 2 failures appear on live (baseline):** `action_permissions` "keys match the office app" reads the desktop repo's
  `access.dart`, which has uncommitted `services_catalog` work; `catalog_products` "reads the export" hits a CRLF fixture. **No new failures.**
- **Five new tests** cover the push-off path: the default, the strict `on` value, an answer and stock identical to push on, staging, and a
  notifier that never calls getToken, claim or send.
- **Mutation check:** with the push forced on, those router tests fail (4) while the rest pass.
- **No real-Postgres tests apply.** Outputs: `r1-r1b-release-evidence/final-push-off/`.

## What was verified

- **Mismatch detection works:** the rule tests (7 audit near-misses, 3,425 production names, the 170-name reviewed list) all pass. A mixed
  checkout (Stop Mold, Keypad on two jobs, a door, a tune-up) flags only Stop Mold.
- **The office log works:** with the push off, exactly one `🧩 Likely name mismatch, not taken off stock: "Stop Mold | 7' White" (job 4001,
  qty 2) is probably "Weather Seal | Stop Mold | 7' White" (Inventory row 2, part 0650747), checked out by Brett Miller.` line. Warehouse
  staging logs too.
- **No stock change from detection:** with the push off and on, the answer, every Sheet write, the PickedItems rows and the final Inventory
  all match. Stop Mold stays at 60 and Keypad goes 10 → 8.
- **No push sent:** with the push off, the fake FCM records 0 messages and the token map is never read, even with a failing FCM.
- **Nothing sent during testing or validation:** every test replaces `config.js` with a fake `admin.messaging()`. `FIREBASE_JSON` is unset, the
  test trees have no `.env`, and no device or production FCM was used. The full run logged no `📵`, `Mismatch notice failed` or `Push failed` line.

**Not changed, and worth knowing:** the live 4 PM "🚨 Inventory Overdue!" push (`inventory.js`, existing code) still runs and can reach the one
registered token. This release neither adds nor alters it.

## Turning the push on later (needs separate approval)

1. **Android:** a build with `ENABLE_PUSH = true` (or the call un-commented), `onNewToken` → `/update_fcm_token`, the Android 13+
   `POST_NOTIFICATIONS` request, and the partial-checkout dialog (read `status`/`lines`; never "Your list is done" on `partial`). Install it
   on the phones, including the warehouse phone signed in as `warehouse1`.
2. **Check reach:** read-only, `users` rows with `fcm_token` for the people who check out, and `warehouse1`.
3. **Test safely:** a test phone and a test user against a non-production backend and a copy of the Sheet, or FCM validate-only
   (`send(message, true)`). Check delivery, title, body and item details, plus no-token, expired-token and FCM-error handling.
4. **Enable:** set `STOCK_MISMATCH_PUSH=on` on Render. That is an environment change, it needs approval, and it restarts the service, so use the
   window below. Rollback: remove the variable.
5. **Prefer R2's Postgres dedupe:** R1b alone dedupes in one server's memory, so a retry during the deploy overlap can notify twice.
6. **R2 must carry this switch:** the R2 worktree wires the notifier without `push`. After this change it would default to off, but R2's
   wiring and tests have to be brought in line before R2 is reviewed for release.

## Known limitations accepted for this release

- **Build 33 zero quantity:** R1 refuses the whole checkout (400) if any line isn't a whole number from 1 to 10,000. Build 33 sends
  `getInt(qtyNeeded)`, so a fractional remainder below 1 goes out as 0, and the phone shows "Checkout Failed" until that line is unticked. Live
  silently dropped such a line. Last 90 days: the only fractional pickable lines were 5 "Stop Mold | Install New … Color" service lines.
  Build 34 rounds up (1–9999), so it isn't affected. **For the next Android build:** never send below 1 and show the server's 400 `error` text.
- **Partial checkout (not fixed):** build 33 shows "Checkout Successful!". Build 34 shows "Checked out N items. M still to pick." or
  "Your list is done". The unmatched line leaves the pick list and the employee is not told. Mitigation: the office watches the `🧩` log lines.
  The fix comes in the next Android build, and the D7 aliases would stop Stop Mold mismatching at all.

## Deployment checklist (prepared, not run; each step needs the owner's go)

1. `git ls-remote origin refs/heads/main` → `030f3b906f115aeb017b00d817c968022b8a0806`. If it differs, stop and rebuild the candidate.
2. On a branch from `983535d7` (CRLF checkout): `patch --binary -p1 < r1b-final.patch`. Commit **only** the 7 R1b files as one commit.
3. Clean checkout of that commit: `npm ci && node --test test/*.test.js`. Expect 584 / 474 pass / 2 fail (the two above) / 94 / 14.
4. Confirm `STOCK_MISMATCH_PUSH` is **not** set on Render (read-only look). Don't add it.
5. Window: weekday **10:00–15:30 Chicago, or after 16:10**. Not 08:00–08:35 (staged picks in memory are lost) and not 15:50–16:05 (deploy
   overlap runs the 4 PM audit twice).
6. Fast-forward push of the R1b commit to `main` (carries `983535d7` with it). Render auto-deploys in about a minute.

**Verify (read-only):**
- The deploy is `live` and `✅ Server live on port 3000` appears.
- `GET /get_full_inventory` returns 200.
- On the next checkout: no `❌ Checkout: Inventory!D… is not a number`, the D cells are numbers, and there is one PickedItems row per line.
- Any `🧩 Likely name mismatch` line names a real near-miss, and **no** `📵 No phone registered` or `Mismatch notice failed` line appears.
  Those only appear when the push is on, so their absence proves it is off.
- Next day at 8:31: `🎉 Flushed and processed N staged items.`

**Rollback** (no schema or data to undo):
1. Render → integrity-backend → Deploys → `dep-dbuu7itg1s2s739ipe30` → Rollback.
2. Then `git revert <R1b commit> 983535d7` (newest first) and push `main`. Otherwise the next push redeploys them.

R1's Sheet values stay valid numbers. The old `parseInt` bugs (C2, N1) come back.
