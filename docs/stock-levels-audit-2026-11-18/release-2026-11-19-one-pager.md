# Stock Levels release: 19 Nov 2026 (R1 + R1b)

**Status:** LIVE since 09:14 Chicago on 19 Nov (deploy `dep-dbvh43ui0phs73cpkm00`, `main` = `62ec46e1`). Commits: R1 `d397ac23`,
R1b `4dbb626e` and the 8:30 removal `62ec46e1`, rebased onto that morning's Services Catalog push (`d311619e`).
Backend only. There are no app or phone updates, no database changes, and nothing is written to Service Fusion.

## What gets fixed

| Before | After |
|---|---|
| A shelf holding **1,250** was read as **1** (the Sheet shows "1,250.00"), so the next checkout could set it to 0 | Quantities are read correctly, commas, decimals and "$" included |
| One part on **two jobs in the same checkout** came off stock only once; the other lines were lost | All the lines for a part are added up and taken off together |
| A Sheet cell holding text ("n/a") was overwritten with a number | That cell is left alone and logged as `❌ … is not a number` for the office to fix |
| Every checkout answered "success", even when some lines took nothing off stock | The answer says `partial` and lists what happened to each line (the current phones don't show it yet; see below) |
| Quantities of 0.5 were dropped and 2.5 became 2, silently | Quantities must be whole numbers from 1 to 10,000; anything else is refused with a reason |
| A scan with a mistyped action **deducted** stock, and a bad quantity became 1 | Only "add" or "deduct" is accepted, and a bad quantity is refused |
| Cycle counts accepted formulas and text | Counts must be whole numbers from 0 to 100,000, written as plain numbers; the same part twice in one count is refused |
| Warehouse staging before 8:31: the same job and part twice in one send kept only the last | They're added together |

## New: likely name mismatches are logged for the office

Some job lines use a different name from the stock sheet, for example "Stop Mold | 7' White" vs "Weather Seal | Stop Mold | 7' White".
Those lines take nothing off stock. When that happens the server now writes a line like this to the log:

> 🧩 Likely name mismatch, not taken off stock: "Stop Mold | 7' White" (job 4001, qty 2) is probably "Weather Seal | Stop Mold | 7' White" (Inventory row …, part 0650747), checked out by …

Only near-misses are flagged (one matching shelf part); doors, services and labor never are. It **doesn't change stock**, and the shelf still needs a manual adjustment.

**Phone notifications are built but switched off.** The installed phone apps never register for notifications, so this release only logs.

## Removed: the 8:30 AM warehouse audit

warehouse1 no longer gets a morning strike when a tech's stock jobs weren't picked or staged by 8:30. On 16 Nov it was struck twice during a
deploy. Strikes already recorded stay on Dennis's Warehouse KPI; the count just stops growing. **Unchanged:** warehouse staging before 8:31,
the 8:31 flush, and the 4 PM tech inventory audit.

## What does NOT change yet

- **Phone screens:** a partial checkout still shows "Checkout Successful!" (old app) or "Checked out N items" / "Your list is done" (current app).
  The missed line still drops off the pick list, so watch the 🧩 lines.
- **Mismatched names still don't come off stock** until the name aliases are approved (decision D7).
- Warehouse staging before 8:31 is still held in server memory (fixed in R2), and there's no protection against a repeated checkout.

## One rare side effect

On the **old app (build 33)**, a leftover quantity below 1 (rare, seen only on Stop Mold service lines) is sent as 0. The whole checkout is then refused with
"Checkout Failed" until that line is unticked. The current app (build 34) isn't affected.

## After the push

- **Watch:** `🧩` lines (name fixes needed), `❌ … is not a number` lines (fix that Sheet cell), and the 8:31 flush message tomorrow.
- **Should NOT appear:** `📵 No phone registered` or `Mismatch notice failed`. Either one would mean the phone notification is on.
- **Rollback**, if needed: Render → Deploys → `dep-dbvh3g6i0phs73cpjam0` (Services Catalog, kept) → Rollback, then
  `git revert 62ec46e1 4dbb626e d397ac23` on `main` and push. No data to undo.

**Technical:** 13 files: `src/inventory.js` plus new `stockQuantity.js`, `stockSheet.js` and `stockMismatch.js`, comments in `employee_kpis.js` and
`users_repo.js`, and tests and fixtures. The full suite on the combined code gives 682 tests, 562 pass and the same 2 environment failures as `main` before the push. Details: `r1-r1b-release-readiness.md`.
**Follow-up (desktop app, not in this push):** the Warehouse KPI caption still says "Strikes the 8:30 AM audit records…"; it should say the audit stopped on 19 Nov.
