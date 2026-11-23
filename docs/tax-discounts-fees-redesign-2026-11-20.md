# Tax, discounts & fees redesign (2026-11-20)

The desktop app is uncommitted. The backend's first version was committed and pushed by you at 15:00 in a39b2d5b
("Adding servie packages"), so it is probably live on Render. That means `/api/tax-settings` and the
`2026-11-20-tax-settings` migration (Update switch off on saved lists). Since then, local and uncommitted: a separate
migration, `2026-11-20-tax-settings-view`, that sets View the way each person's Product Catalog View is, and its tests.
The shipped migration was left exactly as it ran. I made no deploys and changed no production data; production was
only read, with read-only SQL. Line-item editing is still a preview (user rule 2026-11-12), so nothing chosen in the panel is
saved yet.

## What changed

**The panel** (`lib/widgets/charges_panel.dart`). It opens from the "Tax, discounts & fees" button under the lines (the
button now shows a count of what is on the record). It looks and moves like the block's menus, and is laid out like the
Add Line results: a search box, filter tabs flush right (All · Taxes · Discounts · Fees, the selected one in ink), then
sections under headings with counts:

- **On this record.** The record's taxes, discounts and fees, each with a tick. Pick one to change or remove it.
- **State sales tax.** Arkansas, 6.5%, since Jul 1, 2013.
- **County sales tax.** Every county with a tax: its own rate, the rate with the state's, and the day it took effect.
- **City / local sales tax.** Every city with a tax: its county or counties, its own rate, the total, and since when.
- **Out-of-state tax.** One tax whose rate is typed in (0 to 30%). It never uses an Arkansas rate.
- **Discounts and Fees.** The presets from the new settings screen, plus a custom one of each.

Changes DFA has announced show in amber, e.g. "Changes to 1% on Jan 1, 2027".

Picking a choice opens a short form inside the panel:

- **A place's tax** lists its parts (state, county, city) with their rates and since-dates, adding up to what it
  charges. A city in two counties asks which county the job is in. The county and city can be unticked for a county-only
  or state-only tax. A place already on the record can't be added twice: its button reads "Already on this record".
- **A discount or fee** takes a name, % or $ (one fixed box, so nothing moves when you switch), and an amount, and shows
  what it comes to on this record as you type.

Every action closes the panel, so the change shows in the table and the totals, with Undo for removals.

**Keyboard.** The search has focus when the panel opens. Up and Down move through the choices, Enter opens one, and Esc
goes back from a form (even from inside one of its fields) or closes the panel from the list.

**Window sizes.** The panel opens under its button, or over it near the window's bottom edge. When neither side has
room (1280 × 600), it takes the window's height.

**The table and totals** (`lib/widgets/line_items_editor.dart`):

- Fees are their own kind of line, marked "Fee". They are never taxed ("Not taxed" in the Tax column) and have no cost,
  so they no longer hide the gross profit. Discounts and fees can be percentages: the percentage sits in the Rate column,
  the worked-out amount in Amount.
- The totals show one row per tax line ("Sales tax Rogers 9.5%"). A tax no line uses yet shows at $0.00.
- The set's own tax rate (an option's 10.5%) is now changed in the panel. The old field in the totals is gone; the same
  0–30% rule applies.

**The math** (`lib/utils/line_item_math.dart`):

- A percentage discount is worked out on the items. A percentage fee is worked out on the items less discounts, before
  tax.
- Each tax is rounded once to the cent.
- A discount never lowers the tax (your rule: tax is worked out line by line, a discount comes off the total). The old
  per-discount "Off taxed lines" checkbox is gone; a discount's Tax cell says "Off the total". A line saved earlier with
  the box ticked is treated the same way.
- The same rule is in the backend's matching formula (`src/lineItemMath.js`, local). Two of the 11 shared test cases
  that assumed the old behaviour were updated, in both repos' copies; they are still identical.

**Arkansas catalog.** `lib/utils/sales_tax_catalog.dart` plus the generated `arkansas_sales_tax_data.dart`, the import
in `tool/tax/`, and the upkeep notes in `docs/arkansas-sales-tax-catalog.md`.

**Settings screen.** Inventory > Tax, Discounts & Fees (`lib/tax_settings_screen.dart`, route
`/inventory/tax-discounts-fees`). Kept simple, as you asked. It covers:

- discount and fee presets: name, % or $, a starting amount, offered on/off, add and remove;
- the out-of-state tax's starting name and rate;
- where the Arkansas rates come from and when they were checked;
- rate changes typed in ahead of a catalog update;
- a rate look-up for any place.

It has loading, error-with-retry and read-only states, Save/Discard in the ribbon, and a "leave without saving?" guard.

**Backend** (`integrity-backend`; the first version was committed and pushed in a39b2d5b, see the top):

- `src/taxSettings.js`: `GET /api/tax-settings` for any office user; `PUT` needs the Update switch and refuses a stale
  version with 409. One row in a new `tax_settings` table, created on first use.
- New Team switches `tax_settings.view` (on by default) and `tax_settings.update` (off by default).
  - `2026-11-20-tax-settings`, pushed: switches Update off on saved non-admin permission lists.
  - `2026-11-20-tax-settings-view`, local: sets View the way each person's Product Catalog View is.
- Access version goes from 3 to 4 in both repos, so an older app build can't switch the new key by accident.

Until the backend change is deployed, the screen shows the built-in list read-only and says why, and the panel uses the
built-in list.

## Rules as built

- **USER RULE (2026-11-20).** Adding a tax taxes nothing. It becomes a choice in each line's Tax dropdown, and only
  lines set to it are taxed. Fees and discounts are never taxed. Each line's dropdown lists only the record's own tax
  lines (and No tax); the full catalog lives in the panel.
- **USER RULE (2026-11-20).** A discount never lowers the tax: tax is on a line-item basis, and discounts are to the
  total.
- **Built-in presets** are Service Fusion's real names as used on production since 2025:
  - Discounts: Clopay Master Authorized Dealer (%), Builder Relationship (%), Premium Builder Relationship (%),
    Referral (%), Service Partner ($), $45 Same Day Service Credit ($45), 2-10 HBW Deductible Collected ($),
    Multi-Door ($).
  - Fee: Credit Card Convenience Fee (3%).
  - The six old fee names (Trip charge, Delivery fee, ...) are gone: none appears in Service Fusion.
- A record's own tax keeps its own rate. The panel shows DFA's rate today beside it when the two differ.

## Findings from production (read-only)

- **Service Fusion fell behind DFA on Oct 1, 2025.**
  - Madison County places (Huntsville, St. Paul, county-only) kept charging the old 2.5% county rate: under-collected.
  - Benton (city) kept Saline County's rescinded 0.375%: over-collected.
  - Every other tax charged since 2024 matches DFA.
- **Discounts don't lower the tax in Service Fusion.** On 452 of 510 discounted jobs (89%), tax was charged on the
  amount before the discount. That matches your rule.
- **The 3% card fee is never taxed** (357 of 357 jobs checked). When there is also a discount, Service Fusion works the
  fee out before the discount on 83 jobs and after it on 74, depending on the order the charges were entered. The app
  works it out after discounts.

## Open questions for you (and your accountant)

1. ~~Discounts and tax~~: decided. A discount never lowers the tax.
2. **The card fee's base.** Should it be worked out after discounts (as built) or before?
3. **Saving.** Taxes, percentages and fees can't be saved while line items are a preview. When saving is turned on, the
   backend needs fees, percentages and each line's tax snapshot. The app already keeps them in that shape.
4. **Service Fusion's own discounts and fees** on a record show in the panel for reference only ("from Service Fusion ·
   not changed here"). They are in its totals, not lines. Should the preview be able to change them?
5. **Not modelled:** Arkansas's local-tax rebate on single items over $2,500, the reduced state rates, and rates by
   street address.

## Checks run

- `flutter analyze`: no issues in the files changed here; the same 22 notes as before elsewhere.
- **New Flutter tests.** `test/tax_discounts_fees_test.dart` (20: catalog accuracy, including all 50 Service Fusion
  name/rate pairs; the math; the panel flows; keyboard; 1280 × 600 at 1.3× text) and `test/tax_settings_screen_test.dart`
  (5).
- **Updated tests.** The round 2 tax-rate test and the behavior test's discount flow now go through the panel.
- **Backend.** New `test/tax_settings.test.js`; `action_permissions.test.js` updated for access version 4. The full
  backend suite: 708 tests, 0 failures.
- **Review renders** in `build/job_shots/tax_*.png` at 1280 × 600, 1366 × 768, 1500 × 800, 1920 × 940 and 1.3× text,
  plus each form and the settings screen. These are not goldens; none were regenerated.
- **Real Chrome** (`build/tax_harness`, an in-memory fake server, nothing leaves the browser): 39 checks, all pass,
  screenshots in `build/tax_real/`. Chrome found three bugs the widget tests missed; all three are fixed:
  - lines on a set's own rate were labelled with an added tax's name;
  - arrow keys and Enter didn't reach the list from the search box;
  - Esc inside a form's field closed the whole panel.
- **Full `flutter test`:** 1,786 pass, 377 fail (run before the last two fixes below).
  - 353 failures are golden-image diffs. Many goldens were already stale, and none were regenerated. Two sets now
    differ because of this work: `team_permissions*.png` (the new switch row) and the Inventory menu shots (the new row).
  - Of the 24 that aren't goldens, 2 were mine: the nav tests' restricted accounts. Fixed. The new screen's View switch
    now starts as the person's Product Catalog View, so someone kept out of Inventory doesn't get the menu back for this
    page alone.
  - The other 22 are in areas this work doesn't touch (Jarvis, calendar, corrections, payroll, sales, KPI reviews, jobs
    list), or were already failing before it (the job page's Delete button and Request payment link, the Stripe-paid
    job, the 420 px stress tests, "the number can be copied").
