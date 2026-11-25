# Stock Levels: UI, UX, formatting and functional audit (2026-11-25)

Audit only. Nothing was changed, committed, published or deployed.

- **Screen:** `lib/inventory_screen.dart` (route `/inventory`, menu "Stock Levels"), built from `lib/widgets/catalog_kit.dart` and `lib/widgets/flat_page.dart`.
- **Data:** backend `GET /get_full_inventory` (`integrity-backend/src/inventory.js:58`, `src/stockLevels.js`), read from the Inventory Google Sheet.
- **Version audited:** the source at `HEAD` (`17c4609`). **Production runs an older build** (published 19 Nov, `ed10bbf5` in the backend, from desktop `ae3e01e`). The Catalog-style redesign of this screen (`b5ae131`) hasn't been published yet. Each item below says whether it is also live.
- **How:** read the code; rendered the screen with the app's real theme and fonts (IBM Plex Sans) against the 446-part Sheet snapshot from the 18 Nov audit (`docs/stock-levels-audit-2026-11-18/harness/stock_rows.json`), at 1920, 1500, 1366, 1280, 1180, 1000, 760 and 420 px wide and at 130% and 150% text; ran widget checks for refresh order, copy, filter counts and cut-off text. Renders were made in a scratch copy, so the repo's `build/` was untouched. The scripts are in `stock-levels-ui-audit-2026-11-25/harness/` and the pictures in `stock-levels-ui-audit-2026-11-25/shots/`.
- **Baseline:** `test/stock_levels_test.dart` 13/13 pass; `flutter analyze` is clean on `inventory_screen.dart` and `catalog_kit.dart`.
- **Not in scope:** how stock is written (checkouts, scans, counts). That's the 18 Nov audit (`docs/stock-levels-audit-2026-11-18/`). Where one of its items still shows on this screen, it is listed here with its old number.

Labels: **Confirmed** = seen in a render or proven by a test. **By code** = read in the code, not run.
Severity: **High** = shows wrong or misleading stock, or breaks a task. **Medium** = real friction or inconsistency. **Low** = polish.

Note on the pictures: Flutter's test renderer draws dialog and menu shadows as a solid grey ring (`debugDisableShadows`). That ring is a test artifact, not a bug.

---

## Summary

The page looks clean at common desktop sizes (12 rows visible at 1366×768, no overflow at any size tried), and its status rule matches the Inventory dashboard. The problems are mostly about trust and getting work done:

1. **You can't tell how current the numbers are**, and two quick Refresh clicks can leave **older numbers on screen** (F1, F2).
2. **The page never says how many parts need attention.** Both filter groups start closed, so the 57 out / 57 low counts are hidden, and those counts never change with the other filters (U1, F3).
3. **It's a dead end.** You can't open a part, copy a part number, see how many to order, export, or start a purchase order (F4, G1–G5).
4. **Text gets cut off with no way to read it.** This affects long names at 1150–1300 px windows, categories at 1366 px, and headers and the sidebar title at large text sizes (L1–L3).

Counts: 45 problems (2 High, 15 Medium, 28 Low), plus 6 missing capabilities and 1 publishing note.

---

## Functional

| # | Sev | Problem | Evidence | Where | Live too? |
|---|---|---|---|---|---|
| F1 | High | **Refresh can leave older data on screen.** Refresh stays enabled while a refresh is running. Two clicks send two requests; if the first answer comes back last, it replaces the newer one. The ribbon spinner also stops when the first request finishes, while the other is still running. | Confirmed: test with the newer answer landing first ends showing the older list. Refresh is enabled during a refresh. | `inventory_screen.dart:207-242`, `:739` | Yes |
| F2 | High | **No sign of how fresh the numbers are.** No "as of" time anywhere. The screen stays alive in its tab, so it shows whatever it loaded when first opened, with no timer and no reload on return, while checkouts change stock all day. The backend adds up to 60 s of cache. After a failed refresh the notice says the list "may be out of date" but not from when. (18 Nov H7, still open.) | By code | `inventory_screen.dart:149-151`, `:860`; `services.js:1845` | Yes |
| F3 | Medium | **Filter counts never change.** Status and category counts always count all 446 parts, whatever else is picked or searched. With Category = Remote (15 parts) the status rows still say Out 57 / Low 57 / In 138 / Not kept 194. Combinations that give zero results look as promising as any other. | Confirmed (`shots/counts_with_category_1366.png`) | `:249-258` | Yes |
| F4 | Medium | **Nothing in a row can be selected or copied.** Every row is wrapped in `SelectionContainer.disabled`. The app's rule is that all text can be highlighted and copied, and these rows aren't clickable, so the cursor reason for disabling selection doesn't apply. Dragging over a part number and pressing Ctrl+C copies nothing (the count label above copies fine). | Confirmed (test) | `:452` | No, new in source |
| F5 | Medium | **Placeholder part numbers look real.** Only an exact "N/A" is hidden. "na1"–"na11" (11 parts) and "Discontinued" (2 parts) show in the Part # column, and searching "na" matches them. The two discontinued operators show a green "In stock" with nothing marking them as discontinued. | Confirmed (`shots/search_discontinued_1366.png`, Sheet data) | `:95`; `stockLevels.js:35` | Yes |
| F6 | Medium | **"Not kept in stock" depends on quantity, not on policy.** A part with no reorder point shows "In stock" while it has any stock (56 parts today) and flips to "Not kept in stock" when it reaches 0. The label reads as a stocking decision but behaves like a quantity status. A negative quantity on such a part also reads "Not kept in stock" instead of a warning. | By code; data | `:102-110` | Yes |
| F7 | Medium | **Sorting by On hand scatters the parts that need reordering.** Ties are broken by name only, so on the last pages the "Out of stock" parts are mixed in among "Not kept in stock" parts, all with 0. | Confirmed (`shots/page9_1366.png`) | `:285-288` | Yes |
| F8 | Low | Sorting Reorder at ascending puts the blank ("—") rows first. The text columns keep blanks last either way. | By code | `:281` | Yes |
| F9 | Low | Search doesn't cover status ("low" and "out" don't find low or out parts) and doesn't highlight what matched. | By code | `:266` | Yes |
| F10 | Low | No "/" key to jump to search, and no key hint in the box. The Product Catalog has both. | By code | `:628-631` vs `product_catalog_screen.dart:1142` | Yes |
| F11 | Low | Sort, page size, filters and the hidden sidebar reset on every app start and can't be linked. There are no URL parameters, so the Inventory dashboard's "At or below reorder point" card can't open this page already filtered. | By code | `:178-185`; `inventory_dashboard_screen.dart:273` | Yes |
| F12 | Low | Every keystroke in search rebuilds the whole page (a `setState` just to show the clear button), which filters, sorts and recounts all 446 parts each time. The 18 Nov audit measured 200 ms stalls on an older PC (M2). Still present. | By code | `:637` | Yes |
| F13 | Low | A category that disappears after a refresh is quietly dropped from the active filters, with no message. | By code | `:228` | Yes |

## Missing capabilities (functional gaps)

| # | Gap |
|---|---|
| G1 | No part page. A row leads nowhere: no checkout or count history, no last-counted date, no link to the catalog product. (18 Nov H8.) |
| G2 | No office correction path (adjust, receive, count). Corrections still mean editing the Google Sheet directly, with no log row. (H8.) |
| G3 | No "how many to order" (reorder point minus on hand) and no way to start a purchase order from low or out parts, though the new Purchase Orders screen exists. |
| G4 | No export or print (CSV, or a printable reorder list for the warehouse). |
| G5 | No cost or stock value, and no total units on hand. The dashboard shows value; this page shows none. |
| G6 | No view of checkout lines that matched no part (the "Stop Mold \| 7' White" name mismatches, 18 Nov C1). The backend only logs them. |

## UX

| # | Sev | Problem | Evidence | Where | Live too? |
|---|---|---|---|---|---|
| U1 | Medium | **Nothing says how many parts need attention.** Both filter groups open closed, so the 57 out / 57 low counts are hidden behind a click. There is no summary line. At 1280–1920 px the 248 px sidebar is two words over empty white. | Confirmed (`shots/default_1366x768.png`) | `:475`, `:486` | Partly (live has the groups open) |
| U2 | Medium | No one-click "Needs attention" view (out + low). It takes opening Stock status and ticking two boxes. | Confirmed | `:468-495` | Yes |
| U3 | Medium | Rows have no hover state and do nothing on click, so a list of 446 parts gives no way to drill in (goes with G1). | Confirmed (cursor stays an arrow) | `:446-463` | Yes |
| U4 | Medium | **Disagrees with the Inventory dashboard.** The dashboard counts "At or below reorder point" (out and low together, from the Postgres copy); this page splits Out and Low and reads the live Sheet. The numbers and the words differ for the same parts. (18 Nov C7.) | By code | `inventory_dashboard_screen.dart:272-278` | Yes |
| U5 | Low | 43 categories in one flat list with no search box: a long scroll, and long names are cut ("Commercial Operator H…"). | Confirmed (`shots/sidebar_open_1366.png`) | `:484-491` | Yes |
| U6 | Low | "Clear all" (sidebar and dialog) clears the filters but leaves the search; the no-results button clears both. The dialog's "Clear all" is enabled with nothing to clear. | By code | `:322-333`, `:574` | Yes |
| U7 | Low | Under 900 px the rows-per-page choice disappears, so narrow windows are stuck at 50. | Confirmed (`shots/default_760x800.png`) | `catalog_kit.dart:927` | No |
| U8 | Low | The Filters dialog grows, shrinks and re-centres as groups open and close. | Confirmed (`shots/filters_dialog_low_1000.png`) | `:564-576` | Yes |
| U9 | Low | Tab goes Refresh → sidebar → search: the search box, the main control, isn't first, and nothing starts focused. | Confirmed (tab-order run) | `:771-778` | Yes |
| U10 | Low | The no-results message says "Try other words" even when nothing was typed and only filters are on. | By code | `:872-873` | Yes |
| U11 | Low | The error state repeats itself ("Could not load stock levels" over "Could not load stock levels (server error 500)."), and "server error 500" means nothing to office staff. (18 Nov L4.) | Confirmed (`shots/error_1366.png`) | `:129`, `:756` | Yes |
| U12 | Low | Once hidden, the sidebar comes back through a "Filters" button that looks and reads the same as the narrow-window dialog button; nothing says it re-opens the panel, and the hidden state isn't remembered. | Confirmed (render) | `:554-563` | No |

## UI and layout

| # | Sev | Problem | Evidence | Where | Live too? |
|---|---|---|---|---|---|
| L1 | Medium | **The Part column is squeezed on 1150–1300 px windows.** At 1180 it is about 175 px, so most names wrap and long ones are cut ("…Reflective Monitored Ph…"), while the fixed columns keep their full width. | Confirmed (`shots/longname_1180.png`) | `:354-365` | No |
| L2 | Medium | **Cut-off text has no tooltip anywhere on the page.** 5–11 labels are cut on page 1 depending on width (categories at 1366: "Residential Operato…", "Commercial Operat…"). The app's `OverflowTooltip`, used on the PO list, isn't used here. | Confirmed (test count; `shots/default_1366x768.png`) | `:401`, `:404` | Partly |
| L3 | Medium | **Larger text breaks the layout.** At 150% the sidebar title breaks into "Filte / rs" and is clipped, because the invisible "Clear all" button still takes its space. Column headers are cut to "ON HA…" and "REORDE…" because column widths are fixed pixels that don't grow with the text. | Confirmed (`shots/text150_1920.png`) | `:514-525`, `:354-365` | Partly |
| L4 | Medium | **The layout jumps when the data arrives.** The loading skeleton has no REORDER AT column (it can't know reorder points yet), so every column shifts about 110 px left when the list loads. The search box and the sidebar's collapse button also appear only then. | Confirmed (`shots/loading_slow_1366.png` vs `shots/default_1366x768.png`) | `:782-786` | Yes |
| L5 | Low | At 1920 the Part column is about 820 px wide, so names sit far from their numbers and the eye travels a long way across each row. | Confirmed (`shots/default_1920x940.png`) | `:357` | No |
| L6 | Low | Out-of-stock rows are red twice (a bold red "0" and a red status), and the page opens on 57 red rows, so red stops standing out. (18 Nov M3.) | Confirmed | `:367-374` | Yes |
| L7 | Low | Location is "—" for 64% of parts (284 of 446) but always takes 84–96 px. | Confirmed (data) | `:359` | Yes |
| L8 | Low | The "refresh failed" notice is inset 24 px while the table is inset 20, so its icon and text don't line up with the columns. It is red text on white with no tinted band. | Confirmed (`shots/stale_1366.png`) | `flat_page.dart:681` | Yes |
| L9 | Low | The search placeholder is cut under about 800 px ("Search part, part #, shelf or …", "Search part, par…"). | Confirmed (`shots/default_760x800.png`, `default_420x800.png`) | `:630`, `:651` | Yes |
| L10 | Low | Narrow-window rows set 13 px labels beside 14.5 px figures, centred rather than on one baseline ("On hand **0**"). | Confirmed (`shots/narrow_filtered_420.png`) | `:437-438` | Yes |
| L11 | Low | Two-line names make row heights uneven (42 and 54 px side by side). | Confirmed | `:401` | Yes |

## Formatting and wording

| # | Sev | Problem | Where |
|---|---|---|---|
| C1 | Low | The footer says "Showing 1–50" with no total; the app's other lists (FlatPager) say "1–50 of 446". | `catalog_kit.dart:936-950` vs `flat_page.dart:638` |
| C2 | Low | One thing, three names: the column says "LOCATION", narrow rows say "Shelf BO6", and the search hint says "shelf". | `:359`, `:414`, `:630` |
| C3 | Low | "Reorder at" here, "reorder point" on the Inventory dashboard and in the catalog. | `:362` |
| C4 | Low | Status labels mix "Out of stock" / "Low stock" / "In stock" with "Not kept in stock", which isn't a level (see F6), and the old-server label "None on hand". | `:48-53`, `:385` |

## Accessibility

| # | Sev | Problem | Evidence | Where |
|---|---|---|---|---|
| A1 | Medium | A screen reader hears only the name, the quantities and the status for each row ("Back Hang Bolt, 0 on hand, reorder at 3,000, Out of stock"). Part #, location and category are left out, so a part can't be told apart from a near-twin or found on the shelf. | Confirmed (semantics dump) | `:450` |
| A2 | Low | Column widths are fixed pixels, so at larger text sizes the columns don't grow and more text is cut (see L3). | Confirmed | `:354-365` |

## Backend items that show on this screen

| # | Sev | Problem | Where |
|---|---|---|---|
| B1 | Medium | `GET /get_full_inventory` checks no page permission: anyone signed in, or holding the shared app key, can read all stock whatever their Stock Levels access. (18 Nov L1, still open.) | `integrity-backend/src/inventory.js:58` |
| B2 | Low | A failure returns the raw Google error text to the caller. | `inventory.js:64` |
| B3 | Low | Each cache miss also downloads the whole PickedItems tab (A:Z, growing daily), which this screen doesn't use. | `services.js:1850` |

## Sheet data that shows badly on screen

Not screen bugs, but they show up on this page and make it look wrong: 6 part numbers used on two parts each (for example 4128527 on the 893LM and 893MAX remotes); 5 names with double spaces; 4 parts "Uncategorized"; Back Hang Nut, Back Hang Bolt and Small Driller have a reorder point of 3,000, which looks like pieces against a cost per box; category suffixes "- Com", "- RC", "- Res" are inconsistent abbreviations. (18 Nov M6.)

## Publishing

D1. The redesign in source hasn't been published (see the top). Production users still see the 19 Nov layout. Items marked "No" under "Live too?" appear only once the new build ships, so fix them before publishing. Publishing is a deploy and needs your OK.

---

## Re-running the renders

Copy the app to a scratch folder (lib, assets, pubspec, `.dart_tool`), put `docs/stock-levels-audit-2026-11-18/harness/stock_rows.json` at `build/stock_shots/data.json`, put the two files from `harness/` in `test/`, and run `flutter test test/audit_render_test.dart --concurrency=1`. PNGs go to `build/audit/`. Use a copy because a running `flutter run -d chrome` rewrites `build/web` in the real repo.

---

## Fixes (2026-11-25, same day)

All items were worked the same day. Nothing is committed, pushed, published or deployed. **Fixed** = done and covered by a test or
a render; **Partly** = what is left is said; **Open** = needs a decision.

New files: `lib/stock_levels_api.dart` (model, requests, CSV, PDF), `lib/stock_part_panel.dart` (part page, Change stock,
unmatched checkouts), `test/stock_levels_fixes_test.dart`; backend `src/stockOffice.js`, `test/stock_office.test.js`.
Changed: `lib/inventory_screen.dart` (rewritten), `lib/widgets/catalog_kit.dart` (opt-in pager total and compact page
sizes; filter rows dim at 0 and show cut names on hover), `lib/inventory_dashboard_screen.dart` (card opens Stock Levels),
`lib/main.dart` (route passes the link), `test/stock_levels_test.dart` (new wording); backend `src/inventory.js`,
`src/stockLevels.js`, `src/services.js`, `src/inventory_dashboard.js`, test fakes.

| # | Status | What changed |
|---|---|---|
| F1 | Fixed | Each load has a ticket; an older answer is dropped. Refresh is off while any load is out; the spinner stops with the last one. |
| F2 | Fixed | The count line says "Sheet read 2:14 PM" (server's read time, `X-Stock-Read-At`), amber with the age after 15 min; reloads by itself every 5 min while on screen and when you come back to the tab after a minute; the refresh-failed notice says from when. |
| F3 | Fixed | Each filter group's counts follow the search and the other group; rows that would show nothing are greyed. |
| F4 | Fixed | Rows open the part page, which has Copy part # / Copy name and selectable text; Ctrl+C on a row copies name and part #. |
| F5 | Fixed | "na1"…"na11", "N/A", "TBD", "-" hidden; "Discontinued" becomes a Discontinued tag (and is searchable); the Sheet value is kept for writes. |
| F6 | Fixed | Statuses are all levels: Below zero, Out of stock, Low stock, In stock, None on hand. Below zero is a warning whatever the reorder point. |
| F7 | Fixed | On hand ties put the parts that need attention first. |
| F8 | Fixed | Part #, Shelf, Reorder point and To order keep blanks last both ways. |
| F9 | Fixed | Search covers the status and "discontinued"; matches are marked in the name, part # and shelf. |
| F10 | Fixed | "/" jumps to search, with the key hint in the box. |
| F11 | Fixed | `/inventory?view=attention`, `?status=out|low`, `?cat=…`, `?q=…` open it filtered; the dashboard card links there. Sort, rows per page and the hidden sidebar are remembered. The address is not rewritten as filters change. |
| F12 | Fixed | Typing redraws only the box; the list, counts and sort are worked out once per change. |
| F13 | Fixed | A category filter dropped by a refresh says so in a snack bar. |
| G1 | Fixed | Part page: status and what it means, part #, shelf, on hand, reorder point, to order, cost and value (if allowed), last cycle count, the last 40 movements from the stock log, Open in Product Catalog when linked. Backend `GET /stock_part_history`. |
| G2 | Fixed (admins) | Change stock: Receive, Remove or Set count with a reason, preview, refused when the Sheet changed since the page loaded or a row moved. Backend `POST /stock_adjust`, Admin/Owner only, logged with kinds the Sheet's undo script reverses. **Decision for you:** a Team-screen switch (Stock Levels > Update) so Office Manager can do it too. |
| G3 | Fixed | To order column (wide windows), on the part page, in the export; "Order low stock" starts a purchase order with those lines. Uses the uncommitted Purchase Orders screen, so the two ship together. |
| G4 | Fixed | More > Export CSV and Print this list (PDF, with a Picked column). |
| G5 | Fixed | Unit cost and value on the part page and value on hand in the count line, only for people with Line Items & Costs > View. |
| G6 | Fixed | More > Checkouts that missed the shelf: each name, how often, units, jobs, the part it probably is, Show part. Backend `GET /stock_unmatched_checkouts`. Matching the names is still decision D7. |
| U1 | Fixed | Stock status opens by default; Needs attention shows its count on the command row. |
| U2 | Fixed | Needs attention button (inked while on). |
| U3 | Fixed | Rows hover, show the arrow and open the part page. |
| U4 | Partly | The dashboard's "At or below reorder point" now counts the live Sheet (falls back to the copy), uses the same words and opens Stock Levels on those parts. Its stock value and category chart still read the database copy (18 Nov C7/D9). |
| U5 | Fixed | Category list gets a find box past 12 categories; cut names show on hover. |
| U6 | Fixed | Clear all clears the search and filters everywhere, and is off when there is nothing to clear. |
| U7 | Fixed | Narrow windows keep 50 / 100. |
| U8 | Fixed | The Filters dialog has a fixed height. |
| U9 | Fixed | Tab: ribbon, search, Needs attention, sort, headers, rows, pager, then the filters. |
| U10 | Fixed | Three messages: search, filters, or both, each with the matching button. |
| U11 | Fixed | The message under the title is the server's or a plain sentence; no status codes. |
| U12 | Fixed | "Show filters" with a tooltip; remembered. |
| L1 | Fixed | The part column never goes under 280 px (x text size): To order, Category, then Shelf give way first (still on the part page, in the sort menu and the export). |
| L2 | Fixed | Every cut cell and filter label shows its full text on hover. |
| L3 | Fixed | "Clear all" only takes room when shown; column widths grow with the text size. |
| L4 | Fixed | The loading frame has the real columns, search box, sidebar header and ribbon buttons. |
| L5 | Fixed | The part column stops at 560 px; extra room goes to Category and the end of the row. |
| L6 | Fixed | On hand is bold ink when it needs attention; only the status is coloured. |
| L7 | Partly | Shelf column narrowed to 72 px and dropped before Category at tight widths; still "—" for parts with no shelf on the Sheet. |
| L8 | Fixed | The refresh-failed notice is a tinted band lined up with the table. |
| L9 | Fixed | A short hint ("Search parts") when the box is narrow, scaled with text size. |
| L10 | Fixed | Narrow rows put labels and figures in one line of text. |
| L11 | Partly | Wider part column means fewer two-line names; a long name still takes a second line (the catalog rule). |
| C1 | Fixed | "Showing 1–50 of 446". |
| C2 | Fixed | "Shelf" everywhere. |
| C3 | Fixed | "Reorder point" everywhere. |
| C4 | Fixed | One name per status (see F6). |
| A1 | Fixed | Rows read name, part #, shelf, category, on hand, reorder point, to order and status. |
| A2 | Fixed | Columns scale with text size. |
| B1 | Fixed | Office users need Stock Levels > View; phones (technicians, warehouse1) unchanged. |
| B2 | Fixed | 502 with a sentence; the Google error stays in the log. |
| B3 | Fixed | Stock Levels reads only the Inventory tab. |
| D1 | Open | Publishing the web build and deploying the backend need your OK. |
