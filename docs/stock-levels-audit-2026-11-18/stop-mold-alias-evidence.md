# The seven proposed name mappings (aliases): exact names and evidence

19 Nov 2026. **Proposal only. Nothing implemented**: no alias table, no code change, no Sheet or Service Fusion edit. Waiting for your
approval of each pair.

An alias makes a checkout line with the **source** name come off the Sheet row with the **destination** name. Today those lines are logged
but take nothing off stock (audit C1).

## Sources of evidence (all read-only)

- **Sheet**: the read-only Inventory snapshot of 18 Nov (`harness/stock_rows.json`): name, part number (column A), shelf, quantity.
- **Stock copy**: Postgres `inventory_items`, refreshed 16 Nov: part number, cost, shelf, quantity.
- **SF catalog**: Postgres `catalog_products`, from the Service Fusion export imported 16 Nov: part number, SKU, average cost.
- **Job lines**: production `jobs.raw_items` (Service Fusion job lines, not estimates). Each line has a `name` (what the phone shows and
  sends at checkout) and a `product` (the SF catalog product the line was made from). **When `product` equals the Sheet row's name, the
  line was created from that very catalog item. That is the strongest evidence that the two names are one physical part.**
- **Missed at checkout**: the audit's count of PickedItems rows under the source name that took nothing off stock (snapshot 18 Nov).

## The seven pairs

| # | Source (checkout line name, exact) | Destination (Sheet row name, exact) | Sheet part no. · shelf · qty 18 Nov | SF catalog part no. / SKU · avg cost | Stock copy cost |
|---|---|---|---|---|---|
| 1 | `Stop Mold \| 7' White` | `Weather Seal \| Stop Mold \| 7' White` | 0650732 · BD · 60 | SMWH / **0650732** · $4.31 | $4.31 |
| 2 | `Stop Mold \| 16' White` | `Weather Seal \| Stop Mold \| 16' White` | 0650738 · BE · 48 | SMWH / **0650738** · $10.63 | $10.63 |
| 3 | `Stop Mold \| 7' Black` | `Weather Seal \| Stop Mold \| 7' Black` | 0650832 · BD · 127 | SMBL / **0650832** · $7.98 | $7.98 |
| 4 | `Keypads \| 877LM \| LiftMaster` | `Keypad \| 877LM \| LiftMaster` | 4128529 · (no shelf) · 0 | **4128529** / 4128529 · $32.20 | $32.20 |
| 5 | `Punched Angle \| 1-1/4" x 1-1/4" \| 8'` | `Punched Angle \| 16GA \| 1-1/4" x 1-1/4" x 8' \| Galvanized` | 0170015 · BK1 · 0 | **0170015** / 0170015 · $3.28 | $3.28 |
| 6 | `Punched Angle \| 2" x 2" \| 10' \| Taxable` | `Punched Angle \| 12GA \| 2" × 2" × 10' \| Galvanized` (the "×" is the multiplication sign, U+00D7) | 0170030 · BK1 · 105 | **0170030** / 0170030 · $7.72 | $7.72 |
| 7 | `Operator Parts \| PUSHER SPRING KIT QUIET \| 27" LONG LH & RH` | `Operator Parts \| PUSHER SPRING KIT \| 27" LONG LH & RH` | 4152730 · AL · 11 | **4152730** / 4152730 · $67.73 | $67.73 |

## Evidence per pair

| # | Job lines under the source name whose SF `product` is the destination | Other evidence | Missed at checkout (audit) | Confidence |
|---|---|---|---|---|
| 1 | **165 of 165 job lines** (6 Feb 2026 to jobs scheduled 3 Jan 2027) | Line description "Stop mold for bracket and continuous angle construction"; rate $4.27–4.46 = catalog price | 9 rows, 18 units | High |
| 2 | **169 of 169** | Same description; Sheet part = catalog SKU | 10 rows, 10 units | High |
| 3 | **16 of 16** | Same description; Sheet part = catalog SKU | 2 rows, 4 units | High |
| 4 | **48 of 48** | Description "Wireless Keyless Entry System"; the only 877LM keypad on the Sheet; part number equal on all three sources | 2 rows, 3 units | High |
| 5 | **711 of 711** | Description "Light punched angle \| 16 gauge \| Galvanized" (16GA is the destination's gauge); the only 1-1/4" × 8' angle on the Sheet | 11 rows, 16 units | High |
| 6 | **1 of 88** (the other 87 job lines, from 2025 to Nov 2026, have no `product` link) | All 87 carry the description "Heavy punched angle \| 12 gauge \| Galvanized" and a rate of $10.64, the vendor price of part 0170030. The same name without "Taxable" (`Punched Angle \| 2" x 2" \| 10'`, 34 job lines) is linked to the destination on every line. It is the only 2" × 2" × 10' angle on the Sheet. | 2 rows, 6 units | Medium–high: name, description and price agree, but the product link exists on 1 line only |
| 7 | n/a: here the checkout name **is** the SF product name (9 job lines). The difference is on the Sheet, whose row drops "QUIET". | Identical part number 4152730 on the Sheet, the SF catalog and the stock copy; same shelf AL and quantity 11 in the stock copy; cost $67.73 everywhere. The other pusher-spring row (`Pusher Springs \| 15"`, part 4121214) is a different part. | 3 rows, 7 units | High. A Sheet rename to the SF name would do the same job, but that is a Sheet write, so not proposed. |

The quantities differ between the SF catalog and the Sheet (e.g. 7' White: 643 in SF, 60 on the Sheet). That is expected: SF's
quantity isn't maintained, and the Sheet is the warehouse count. It is not evidence against a pair.

## Things you should know before approving

1. **Part number columns disagree in kind.** For Stop Mold, the SF catalog's "part number" is a colour code shared by every length
   (SMWH for 7', 9', 16', 18' White). The Sheet's part number matches the SF **SKU**. So a pair can't be proven by "part number" alone, which
   is why the table shows both.
2. **The same pattern goes well beyond these seven.** Checking every job line name in production (R1b work) found 170 names that are very
   probably stocked parts under another name: remotes (`Remotes | 893LM | LiftMaster | Taxable`, 121 job lines), keypads, springs
   (`Springs | LW .218 x 2 x 24.5 | Taxable`), operator rails and more Stop Mold lengths and colours. The seven above are only the ones the audit saw
   missed in the PickedItems snapshot. The full list: backend `test/fixtures/stock_mismatch_flagged_2026-11-19.json`.
3. **A broader fix is available.** For 85 of those 170 names, every job line's `product` field already names the Sheet row exactly.
   Matching checkouts on the line's SF product, instead of its display name, would fix those without a hand-made alias list. It needs the phone
   to send the product, or the server to look it up by job and line. That is the Phase 2 "match by catalog id" work, which I haven't started.
4. **Not proven by a physical check.** None of this was confirmed on the shelf. A one-time look by the warehouse at shelves BD, BE, BK1 and AL
   would close it.

## When approved (not done)

Under the plan, an approved alias is a row in `stock_item_aliases` (migration 002, Option B) or, before that, a reviewed list in code.
Either way: only these exact source names, each to one destination row, each with your name and the date as the approver.
