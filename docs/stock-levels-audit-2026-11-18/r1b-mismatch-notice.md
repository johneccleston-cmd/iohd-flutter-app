# R1b: push notification for likely stocked-part name mismatches

19 Nov 2026. Approved for **local implementation and testing only**. Not committed, pushed or deployed; R1 stays on release hold.

## What it does

After a checkout answers, the server looks at the lines that took nothing off stock (`not_stocked`). For each one that is **probably a
stocked part under another name**, it logs it for the office and pushes one notification to the signed-in person's phone, through the
existing channel (`admin.messaging().send`, the same FCM path and display as the 4 PM "Inventory Overdue" alert; both builds 33 and 34
show it).

Example (the real text):

> **⚠️ Not taken off stock**
> 1 part was not taken off stock: "Stop Mold | 7' White" (job 4001) looks like "Weather Seal | Stop Mold | 7' White" on the stock sheet
> (part 0650732, shelf BD). Tell the office so the names can be matched; the rest of your checkout went through.

With several lines it lists three and says "And N more". The office log gets one `🧩 Likely name mismatch…` line per item, with the job,
quantity, Sheet row, part number and who checked it out.

## The rule (src/stockMismatch.js)

A `not_stocked` line counts only if exactly **one** Sheet row matches. A row matches when, after normalising (lower case, split on `|` `,` `()` and
spaces, "×" read as "x", plural to singular, "Taxable" and "&" ignored):
- every word of the line is in the row's name, and the line has at least 3 words, or
- every word of the row is in the line, the row has at least 3 words, and the line has at most 2 extra words.

No match, or more than one: no push. An exact name never gets here (it came off stock).

## Requirements, and how each was met

| Requirement | How | Test |
|---|---|---|
| Use the existing notification channel | `admin.messaging().send({ notification: { title, body }, token })` with the token from `services.getTechToken` (the 4 PM alert's path) | router tests check the exact message and token |
| No notice for doors, services, ordinary non-stock lines | Rule above. Run over **every distinct job line name in production** (3,537 names, 30,729 job lines; read-only, 19 Nov): of the 3,425 without an exact Sheet row, **170 are flagged and none is a door, service, labour line or fee** | "every production job line name: nothing that reads as a door, service…"; synthetic doors/services/"Stop Mold \| Install New Standard Color"; mixed checkout with a door and a tune-up line |
| Include the unmatched name and enough to resolve it | Line name, job number, the Sheet row's exact name, its part number and shelf, and "tell the office" | message text test |
| Mixed checkouts | Stop Mold + Keypad on two jobs + a door + a service line → one push naming only Stop Mold; stock and answer unchanged | "mixed checkout…" |
| False positives | Exact name, two candidate rows, too few words: no push; the flagged set is pinned to a reviewed list (below) | four tests |
| No duplicate notice on a retry | Fingerprint = person + Chicago day + the unmatched lines (job, name, qty), claimed once for 12 h. R1b alone: in this server's memory. R2: claimed in Postgres (`stock_job_runs`, key `mismatch_notice:<fingerprint>`), so it also holds across servers; a retry replayed by its request id never runs the notice at all | "same checkout sent again", "replayed by its Idempotency-Key" (R2), "two servers" (R2, memory store and **real Postgres**) |
| Never break a checkout | Sent after the answer, not awaited; token lookup or FCM failure only logged | "no phone registered, or the push service down" |
| Warehouse staging | Staging reads no stock, so the names are checked against the cached Sheet when staged (the person is there), and the 8:31 flush doesn't notify again | "warehouse staging before 8:31" |

## False positives found, and what they mean

The 170 flagged names, each checked against Service Fusion's own link (`product`) on its job lines (full list:
`test/fixtures/stock_mismatch_flagged_2026-11-19.json`, pinned by a test so the rule can't drift unnoticed):
- **85**: SF's product **is** that Sheet row. Correct.
- **73**: older lines with no product link. Name-only evidence; the review found one clearly wrong: `16' Bottom Seal` → "Weather Seal | Aluminum
  Bottom Seal Retainer | 16'" (a seal is not its retainer). Its last use was 2021.
- **12**: SF's product names something else. 5 are the same item spelled differently (e.g. "Operator Parts |" vs "Operator Rail |",
  a double space, the pusher spring's "QUIET"). 2 are `Lubricant | Garage Lube` / `Lubricant | Clopay Garage Lube` → the Sheet's
  "Clopay Heavy Duty Garage Door Lube | 12 Pack 20 oz." row (probably the same stock, counted by the pack). 5 are doubtful: `Stop Mold | 7' Iron Ore` and `16' Iron Ore` (SF product says Gray), `Stop Mold | 8' Walnut Finish`
  (SF says 9'), `7' 81550 Operator Belt & Rail` (SF says Chain & Rail), and `Chain Drive | 12' TDC7S1BMC L5` (SF says T501). Each was
  used once or twice in 2026.

That is why the push says "**looks like**" and asks the person to tell the office: it never changes stock, it only asks for a check. A wrong
suggestion costs a short conversation; a missed one is today's silent stock loss.

## Limits

- Best effort: no FCM token for that login means no push (logged). The push arrives just after the phone's own "Checked out" message,
  which still says nothing about the miss on builds 33 and 34.
- R1b alone dedupes in each server's memory. A retry that lands on the other server during the minute-long deploy overlap can notify twice. R2
  closes this.
- Build 33 shows one line of the text; build 34 shows it all (BigTextStyle).
- The match uses the Sheet as read for the checkout (normal checkout) or the cached copy (staging, at most the cache's age).

## Test results

| Where | Result |
|---|---|
| R2 tree, `stock_mismatch.test.js` | 18 / 18 pass |
| R2 tree, `stock_r2_sql.test.js` incl. "the same checkout on two servers sends the mismatch push once" (real PostgreSQL 18.6) | 19 / 19 |
| R1 + R1b only (`983535d7` + `r1b-evidence/r1b.patch`), stock tests | 70 pass, 0 fail, 2 skipped (the two R2-only cases), 14 todo |
| R1 + R1b only, full suite (no database) | 579 tests: 469 pass, 2 fail (the same two environment failures as R1), 94 skipped, 14 todo (`r1b-evidence/full_suite_r1b_no_db.txt`) |

## Files

R1b alone, against R1 (`r1b-evidence/r1b.patch`): `src/stockMismatch.js` (new), `src/inventory.js` (+20 lines: the notifier, staging
check, call after the checkout answer), `test/stock_mismatch.test.js` (new), `test/stock_fakes.js` (phone tokens and pushes), three
fixtures (Sheet snapshot, production line names, the reviewed flagged list). In the R2 tree the same module is wired into
`stockWrites.checkout` (returns the rows it read) and `inventory.js` (Postgres claim).

## Android (next build, not started)

As you required: the phone must read `status` and `lines`; on `partial` it shows the lines that didn't come off stock and why, and it never
shows "Checked out N items" or "Your list is done" as if everything came off.
