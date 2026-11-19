# R1 release hold: findings, proposal, deployment and rollback

19 Nov 2026. Nothing was deployed, committed, pushed or installed. Production reads only (Render logs, read-only SQL).
R1 = commit `983535d7` on `origin/stock-phase1`, a single commit directly on top of the live commit `030f3b90`.

## 1. What the installed Android builds do with `status: "partial"`

The builds that can be on phones today, read from git:

| Build | Commit | After any HTTP 200 checkout the phone shows | Reads `status` / `lines` / `message`? |
|---|---|---|---|
| versionCode 33 ("old app") | `1fe6546` | Toast **"Checkout Successful!"** | No |
| versionCode 34 (pushed 11-09/11-10) | `23140f7`, `6ce02a4`, `551c61b` | Snackbar **"Checked out N items. M still to pick."**, or the **"Your list is done"** panel when nothing is left | Only `message`, and only to spot the "Items staged" prefix |
| versionCode 36 | local, uncommitted | Same as 34 (pick list unchanged) | Same |

**Verified on unchanged build 34 (`551c61b`)** with its own Robolectric harness: a scratch test, never committed, fed it the exact
answer the real R1 router returns for a mixed checkout. Evidence is in `r1-hold-evidence/`.

- Lines: `Stop Mold | 7' White` ×2 (job 4001), `Keypad | Genie` ×1 (job 4001), `Keypad | Genie` ×1 (job 4002).
- R1 answer: `{"status":"partial","itemsUpdated":2,"lines":[{"outcome":"not_stocked",…},{"outcome":"deducted","remaining":8},…],"message":"1 of 3 lines did not come off stock: Stop Mold | 7' White."}`
- The Sheet afterwards: Keypad 10 → 8 (correct, both jobs). Weather Seal | Stop Mold | 7' White stays at 60. All three lines are logged to PickedItems, as before R1.
- **What the employee sees:** before checkout, the Stop Mold row carries a grey "Not stocked" chip, the same chip a door or service line
  gets (`r1_A1_before.png`). After checkout, **"Your list is done"** (`r1_A2_after.png`), or **"Checked out 3 items. 1 item still to pick."**
  when another job is left (`r1_B_after.png`). Stop Mold is never mentioned again.

## 2. Can an employee mistake a partial checkout for a full one?

**Yes, on every installed build.** Nothing on screen differs between a full and a partial checkout. The unmatched line also leaves the pick
list, because it is logged to PickedItems like any other line.

This is **not a regression from R1**: production today answers `"status":"success"` for the same checkout and the phone shows the same
words. R1 makes the server's answer truthful (`partial`, per-line outcomes) for builds that read it. It changes nothing on the screens of
the builds people have now.

## 3. Mixed matched and unmatched lines, tested

| Test | Where | Result |
|---|---|---|
| Real R1 router, Stop Mold ×2 + Keypad ×1 on two jobs | `r1-hold-evidence/mixed_checkout.js` → `mixed_checkout_out.txt` | HTTP 200, `partial`, `itemsUpdated` 2, Keypad 10 → 8, Weather Seal unchanged at 60, 3 log rows |
| R1 unit test "C1: a line that matches no Inventory row is returned as an exception" | `test/stock_writes.test.js` | Pass |
| Build 34 screen fed that answer (2 scenarios) | `r1-hold-evidence/R1PartialCheckoutTest.kt`, `android_build34_screen_text.txt`, 3 PNGs | Shows success wording; no exception shown |

## 4. Stop Mold

- In the audit snapshot, the Service Fusion name `Stop Mold | 7' White` has no Sheet row. The shelf part is
  `Weather Seal | Stop Mold | 7' White` (missed 9 times, 18 units, latest 18 Nov). Six more near-miss names are listed in the audit (C1).
- **Today the employee is not told clearly.** Build 34 says "Not stocked", which reads like "a part with no shelf" (doors, services), not
  "this IS on the shelf under another name and nothing came off stock". Build 33 says nothing at all.
- The cause is the name, and only an alias mapping fixes it (decision D7: approve the 7 aliases from the audit, or wait for Phase 2 id
  matching). Until then, communication can only tell people about it, not fix it.

## 5. Proposal (the current builds cannot display the exceptions)

**A. Backward-compatible, server only, works on builds 33 and 34 today: a push notification on a partial checkout.**
Both builds already display FCM messages that carry a title and body (`MyFcmService.kt`); the 4 PM "Inventory Overdue" alert uses that path.

- When a checkout has a line that is `unreadable`, or `not_stocked` **and looks like a stocked part**, the server sends the signed-in
  person a push:
  title **"⚠️ Not taken off stock"**, body **"Stop Mold | 7' White (job 4001) isn't on the stock sheet under that name, so nothing came off
  stock for it. Tell the office."**
- "Looks like a stocked part": every word of the line's name appears in exactly one Sheet part name. That catches Stop Mold and the
  audit's other near-misses, and skips doors and service lines. Most of the 142 unmatched log rows are those, and pushing for each would
  teach people to ignore the alerts.
- The same lines go to the server log with a 🚨 marker, so the office sees them as well.
- Limits: best effort (needs the device's FCM token; arrives a second after the "Checked out" message); build 33 shows one line of text.
  It does not stop the line leaving the pick list.
- Size: about half a day. It is a change to R1, so it needs your approval as "R1b" before release.

**B. In the Android release plan (next build, S11): show the exceptions on the phone.**
- Read `status` and `lines`. On `partial`, show a dialog before "Checked out…" or "Your list is done", listing each line that did not come
  off stock with its reason, and "Tell the office".
- Separate "not on the stock sheet under this name" (a likely mapping problem) from genuine "Not stocked" service lines, using a new
  optional field from `/get_job_materials`. Older builds ignore it.
- Never show "Your list is done" after a partial checkout.

**My recommendation:** release R1 (it fixes daily stock loss, N1 and C2, and is no worse on screen than today), with A as R1b if you approve it,
B in the next Android build, and decide D7 so Stop Mold stops being a mismatch at all. If you'd rather not add A, R1 alone is still safe
to release.

## 6. Exact deployment and rollback procedure for R1 (to run only after your separate release approval)

**Before**
1. `git fetch origin` and confirm `origin/main` is still `030f3b906f115aeb017b00d817c968022b8a0806`. R1 must be a fast-forward; if main
   has moved, stop and rebase R1 for a new review.
2. On a clean checkout of `983535d7`: `npm ci && node --test test/*.test.js`. Expected: every stock test passes; the only failures are the
   known environment ones listed in `r2-evidence/failures_R1.txt`.
3. Note the live deploy for rollback: `dep-dbuu7itg1s2s739ipe30` (commit `030f3b90`, live since 2026-11-18 17:44 UTC).
4. Pick the window: **a weekday between 10:00 and 15:30 Chicago, or after 16:10**. Not 08:00–08:35: warehouse staging is held in memory,
   so a deploy before 8:31 drops staged picks (H4). Not 15:50–16:05: two servers overlap for about a minute during a deploy and both would
   run the 4 PM audit (N3).

**Deploy**
5. `git push origin 983535d7:main` (fast-forward). Render auto-deploys in about a minute.

**Verify (read-only)**
6. Render: the new deploy is `live`; start-up log shows `✅ Server live on port 3000` and no `TOKEN_SECRET is not set` line.
7. `GET /get_full_inventory` answers 200 (the office Stock Levels page loads).
8. On the next real checkout: the log shows no `❌ Checkout: Inventory!D… is not a number` lines (or, if it does, that cell really is text),
   the Sheet's D cells for the parts taken are plain numbers, and PickedItems has one row per line as before.
9. Next morning at 8:31: `🎉 Flushed and processed N staged items.` once per server, and the staged parts' D values drop by the full staged
   amount.

**Rollback (no schema, no data to undo)**
- Fastest: Render dashboard → the service → Deploys → `dep-dbuu7itg1s2s739ipe30` → Rollback. Then also run
  `git revert 983535d7 && git push origin main`, because the next push to main would otherwise redeploy R1.
- Values R1 wrote stay correct numbers on the Sheet. After a rollback the old `parseInt` bugs (C2, N1) come back.
