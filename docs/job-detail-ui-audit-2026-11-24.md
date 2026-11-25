# Job / Estimate detail page: UI, UX and formatting audit (2026-11-24)

**Status (2026-11-25):** the 15 Must fix items (1–10, 38–40, 67, 68) are fixed in code, marked **[FIXED 11-25]** below.
They have not been analyzed, tested or rendered yet: `flutter` doesn't run on this Mac (macOS 13) since the SDK was
updated to a version that needs macOS 14. Everything else is still open.

**Scope.** The whole job and estimate detail page:

- `lib/job_detail_screen.dart`: ribbon, Details, Job Info, Notes, Payment, dialogs.
- `lib/job_detail_items.dart`: Products & Services block, option tabs, preview strip.
- `lib/widgets/line_items_editor.dart`: the products table and the summary blocks.
- `lib/widgets/charges_panel.dart`: the Tax, discounts & fees panel.

**How it was found.**

- The code was read in full. Two review agents covered the table and panel files, and their claims were spot-checked against the code.
- The page was rendered with the app's `officeTheme()`, IBM Plex Sans and the Windows variant, using the `test/job_page_fixture.dart` fake server:
  - window widths 1920, 1366, 1100, 900 and 800;
  - every Details and Job Info tab;
  - editing preview;
  - text ×1.3;
  - not found;
  - estimate with options;
  - read-only with no cost access.
- The renders are in `build/job_review/*.png`. They are not committed and the render test was deleted.

**Line numbers** are as of commit `b5ae131`. Re-check them before editing.

**User rules this list respects.** It does not flag any of the following:

- no hover shading on the job page;
- P&S tooltips hidden;
- no "lines have no cost" note;
- editing is preview-only;
- quantities shown with two decimals;
- the P&S table look and the summary blocks set on 11-24.

Items marked **ASK** touch a user rule or a design decision. Check with the user before changing them.

## If only a few things get fixed

1. **[FIXED 11-25]** **Hover shading leaks.** Items 21, 38, 68 and 88 share one root cause: `TextButton.styleFrom(foregroundColor: …)` builds its own 8% hover overlay, and that beats the page's `_noHoverShading` theme.
2. **[FIXED 11-25]** **Dead ends.** Controls that look usable but go nowhere: 2, 7, 82, 87 and 96.
3. **[FIXED 11-25]** **Money shown inconsistently or wrong.** Items 1, 15, 16, 50 and 67.

## Main page (`lib/job_detail_screen.dart`) and renders

### Must fix
1. **The paid bar says "100% paid" while money is still owed.** The percent is rounded (`:2492`). Round down while anything is owed.
2. **The status and sub-status picker is a dead end.** It lists every status, but any pick only says "not saved yet". The empty state is a lowercase blue "set status" / "set sub-status" (`:956-970`, `:960`). Show read-only pills until saving exists, and use "Not set".
3. **Details and Job Info tabs go icon-only on common laptop widths.** This happens for windows of 900 to about 1285 px, 1280 included, because each block is under 640 px (`:1148`). At 800 px, where the blocks stack, the labels come back. Switch to icons only when the labels really don't fit.
4. **[FIXED 11-25]** **At text ×1.3 the Details tab bar shrinks to tiny text.** `FittedBox(scaleDown)` scales it down (`:1167`).
5. **[FIXED 11-25]** **The copy button (PO #, phone) is invisible but still active.** It fades to opacity 0 yet can still be focused and clicked. When the row is stacked (under 460 px) it disappears entirely (`:1242`, `_CopyValue` `:4356`).
6. **[FIXED 11-25]** **Picture tiles can't be opened from the keyboard** and have no semantics (`_PicTile` `:4100`, GestureDetector only).
7. **[FIXED 11-25]** **Service Fusion documents look openable but never open.** They show a pointer and an open-in-new icon, then always fail with a "file name only" snackbar (`:1632`, `_DocRow` `:4332`).
8. **[FIXED 11-25]** **The not-found / load-failed screen is a dead end.**
   - Small grey text and a red Retry (theme primary) that can't fix a not-found.
   - No way back to the list.
   - It says "Job #" on estimate pages (`:240-251`, `:467-481`).
   - Fix: use `DashErrorPanel` with a back link, and word it from `_estimatePage`.
9. **[FIXED 11-25]** **The "Description ⌄" toggle lands mid-name when a long name wraps.** At 1366 and 1100 it reads "…Complete Door [Description ⌄]" with "| Sandtone (Clay)" on the next line (view row in `line_items_editor.dart`).
10. **[FIXED 11-25]** **At text ×1.3 the summary labels break.** They render as "Gross (36.4%) / profit" and "Payments/ / Deposits" (`line_items_editor.dart:4668`, `:4748`).

### Should fix
11. **Three date formats on one page.** "10/06/2026 - 10/07/2026" (`_date` `:355`, `:586`) sits right under the banner's "Worked Tue, Oct 6 – Wed, Oct 7" (`:896`), with a hyphen in one and an en dash in the other. Payments and notes use "Oct 9, 2026 10:00 AM".
12. **"Not set" vs "Not Set".** Details uses "Not set" (`:1208`); Job Info uses "Not Set" (`_sfRow` `:2969`, `:618-622`, `:3172`).
13. **Label case differs between blocks.** Details is in sentence case. Job Info is in Title Case: "Arrival Time Window", "Notes For Techs", "Job Total", "Balance Due".
14. **One person under three names:** "Sales owner" (`:552`), "Opportunity Owner" (`:611`) and "Sales Agent" (`:647`). Estimates show it twice.
15. **Overpaid is worded four ways:**
    - "Overpaid by $X" (`:1043`)
    - "Overpaid $X" (`:2499`)
    - "$X over" (`:2475`)
    - a green "Credit" in the P&S summary
16. **Unpaid changes colour.** Invoice-owed is red under Balance Due (`:1046`) but amber in the paid bar (`:2497`). The invoice row's icon is amber (`:2814`) beside a red "Unpaid" pill (`:2700`).
17. **The Upload pictures and Upload documents buttons are bright red filled pills.** FilledButton picks up the theme's brand red, so they read as destructive (`:1481`). Use `AppButton.ink`.
18. **The Request payment dialog is the old style.**
    - It uses Material AlertDialog, ChoiceChip and FilledButton instead of AppDialog, AppButton and `appFieldDecoration` (`:3442-3519`).
    - The title says "Job #" on estimates.
    - "1.2.3" passes the input filter and then errors with "at least $1" (`:3485`).
    - There is no warning when the amount is above the balance or the total.
19. **Hex literals where tokens exist:**
    - `_link` 0xFF2563EB is `DashUi.blue` (`:65`).
    - 0xFFB91C1C is `DashUi.redText` (`:1039`, `:1042`, `:1046`).
    - The skeleton uses 0xFFD4D4D4 (`:1057`).
20. **ASK. The P&S block doesn't line up with the blocks above.** It is inset 8 px with a rounded header and its title sits at 22 px. The Details and Job Info headers are square, run edge to edge, and put their titles at 20 px (`job_detail_items.dart:519`, `:534-539`). This comes from the user's outline rule.
21. **Hover shading is still on in two places:**
    - The document row's file badge tint goes 0.12 → 0.18 (`:4285`). The doc comment at `:4203` still says it tints.
    - The picture Remove button fill goes 0.5 → 0.78 (`:4177`).
22. **Estimates are called "job".** "No pictures on this job", "None on this job yet", "Service Fusion has none on this job either" and "takeoffs for this job" (`:563`, `:1458`, `:1589-1592`, `:1647-1650`). Use `_kind`.
23. **The failed-Refresh banner doesn't fit the page.** It is a rounded amber card with 16 px margins on an edge-to-edge page, with a default TextButton Retry and the text "Server error (500). Showing what we already have." (`:687-704`, `:250`).
24. **Edit mode: the tax select truncates.** It shows "Prairie G… 10.5%" at 1366 (`taxEditW` 156, `line_items_editor.dart:304`).
25. **The preview strip shouts** "will NOT overwrite" (`job_detail_items.dart:1796`).
26. **The loading skeleton doesn't match the page.** It has no grey bands, no Notes and no P&S, so the page jumps when it loads (`:1053-1100`).
27. **Empty Pics and Docs say it three times:** "No pictures", then "None on this job yet", then the empty state's "No pictures yet" (`:1470`, `:1458`, `:1589`).
28. **Ticking a task waits for the server** with no pending state (`:1860`, `_TaskCheck` `:3708`).
29. **Copy fixes:**
    - "Add Notes" / "Add Task" → "Add note" / "Add task" (`:2072`, `:1929`).
    - "Only admins can delete jobs" is wrong now that Team switches control access (`:1820`).
    - "Rest not on file" is unclear (`:2501`).
    - Activity shows "Status Created →", and a bare arrow when the old status is empty (`:2185`).
30. **A note with no author shows an "AH" avatar**, from the fallback name "Added here" (`:2129`).

### Nice to have
31. **"Request $35.97" sits about 6 px right of the row icons** (`:2929`).
32. **Two amber warning icons when overpaid** (`:2602` and `:2620`).
33. **Off-scale styling.** Radii of 9, 10 and 11 (`:1872`, `:2939`, `:3822`, `:4286`, `:689`). Non-rounded icons: `Icons.outgoing_mail` (`:2716`) and `Icons.link` (`:2941`).
34. **Inconsistent "Show all" placement.** "Show all visits" sits above its list (`:3002`); "Show all notes" sits below (`:2096`).
35. **Dead code.**
    - `_HoverLift` is unused (`:3792`).
    - Two doc comments are orphaned (`:1419`, `:1881`).
    - `jumpTo` in `test/job_page_fixture.dart` uses `jump-*` keys that no longer exist.
36. **The estimate's "Estimate Option" (SF) tab shows no margin,** while "Builder grade" with similar lines shows 38.7%. Find out why.
37. **The estimate's "On-Site Visit" splits** date, window and duration onto three lines (`:615-624`), unlike the one-line visit rows.

## Products table (`lib/widgets/line_items_editor.dart`)

### Must fix
38. **[FIXED 11-25]** **The Tax, discounts & fees button and the "Use last billed $X" hint button get an 8% ink hover fill.** `_quietButton` uses `TextButton.styleFrom(foregroundColor)` (`:2003`, used at `:1543`; `:5121-5131`). Add an `overlayColor` that is transparent on hover.
39. **[FIXED 11-25]** **Two line-menu moves look enabled but do nothing:** Move down on the last product and Move up on the first discount/fee. `_moveShown` clamps within each group (`:1858-1862`), but the menu (`:3690-3691`) is given `_rows.length`. Pass the index and size within the group.
40. **[FIXED 11-25]** **The "Recent price change" hint is stale.** It always ends "No price is filled in; check it before quoting.", even after a price is typed (`:4999`, no `line.rate` check).

### Should fix
41. **A read-only table with no charge rows ends in a 2 px bottom line.** The last row's rule, the trailing Divider and the outline all land on it (`:1828`, `:1776-1778`). Drop the Divider.
42. **The Tax, discounts & fees panel can show a different amount from the table.** The panel takes discount and fee amounts from recomputed totals (`:949`, `:964`; `charges_panel.dart:403`). The table uses `_lineFigures`, which are Service Fusion's own amounts. An untouched SF percentage charge can differ between panel and row. Build `ChargeEntry` and `itemsCents` from `_lineFigures`.
43. **Copying a confirmed $0.00 line produces a line that already says "confirmed by X".** `copyWith` keeps `zeroPriceConfirmed` (`:1232`).
44. **Closing a line with Enter or Esc drops keyboard focus to the top of the page** (`:1135-1154`, `:4322`, `:4097`).
45. **ASK. The 400 px item-column cap only holds up to about a 1,250–1,400 px block.** At 1920 with costs the column is about 900 px (`maxSpread` 60, `:283`, `:356`). The user should pick: keep 400 and put the spare width after Tax, or raise `maxSpread`.
46. **Some text isn't ink, against the all-ink rule:**
    - the "—" for no price (`:2141`);
    - a no-cost "$0.00" (`:2151`; a code comment says this was deliberate);
    - the rate in the tax box (`:3460`);
    - "Service package · N lines" (`:2513`);
    - "No charge · confirmed by" (`:5083`).
47. **Editing at about 1280 with any SKU gives every row an empty ~21 px meta line,** discount and fee rows included. The compact charge rows end up taller than the tax rows (`:2698-2705`). Return null for `isCharge`.
48. **The stacked edit layout shows a dollar discount or fee twice:** in the Amount field and again in the grey total box (`:4478-4486`).
49. **The zero chip overflows at a 360 px window.** "$0.00 · Not confirmed as no charge" isn't flexible (`:5041-5047`).
50. **A fully paid job shows "Balance due $0.00" in red.** `dueTone` is always `DashUi.redText` (`:4661`, `:4672`). Use ink when the balance is 0.

### Nice to have
51. **Uneven alignment when other lines have SKUs.** In read-only rows, a no-SKU line with a description is top-aligned, and one without a description is centred (`:2368`).
52. **The stacked figures line is inconsistent** (`:2209-2220`):
    - It is ink on qty-0 lines.
    - It says "no price" where elsewhere it is "—".
    - Capitals are mixed: "1.00 × no price · No tax".
53. **At 360 px, a closed editable line in the stacked layout leaves the name box about 62 px,** so the name disappears (`:2264-2283`).
54. **The "Service package · N lines" caption isn't Flexible,** so it overflows at text ×1.3 near 360 px (`:2510-2514`).
55. **Hit targets under 24 px:** the qty arrows are 20×14 (`:3300`), the Description toggle about 19 px (`:3578`), the zero chip about 21 px (`:5035`).
56. **The drag grip icon is `DashUi.muted`,** about 2.7:1 contrast (`:3669`). Use `DashUi.subtle`.
57. **With unitemized money, the label becomes "Taxes, fees & other charges"** and drops "discounts" (`:4655`).
58. **The no-charge dialog's wording is off** (`:1251-1254`):
    - It uses single quotes where the rest of the app uses double quotes.
    - It says "It will show $0.00 to the customer" even when the eye is off.
59. **One action, two verbs:** "Delete" in the line menu (`:3693`) and "Remove package" (`:2525`).
60. **"Estimate cost" depends on the total label starting with "Estimate".** An SF estimate with no `total_revenue` says "Job cost" (`:4684`).
61. **An unpriced read-only line shows "—" under RATE but a bold "$0.00" under TOTAL** (`:2339-2342`, `:2143`).
62. **The square-ended trailing Divider and add-row border run into the outline's rounded bottom corners** (`:1828`, `:1563`).
63. **Screen-reader labels "Quantity", "Rate" and "Unit cost" don't say which line** ("Line N") (`:4386`, `:4404`, `:4421`).
64. **With no lines, `_empty()` hides the tax and unitemized figure rows** that the summary still adds (`:1484`).
65. **In the stacked edit layout, the total box is the only figure without a heading** (`:4486`).
66. **ASK. The middle totals block is 460 px in code** (`totalW` `:2682`), while the 11-24 note says 420. A code comment says the user widened it.

## Option tabs, strip and band (`lib/job_detail_items.dart`) and Tax, discounts & fees panel (`lib/widgets/charges_panel.dart`)

### Must fix
67. **[FIXED 11-25]** **SF discounts and fees are listed twice under "On this record" in Tax, discounts & fees.** Each shows as an editable line and again as a greyed "Discounts"/"Fees" figure row ("From Service Fusion · in the totals").
    - This breaks the 11-24 rule that SF discounts and fees are lines.
    - Cause: `line_items_editor.dart:951-954` copies every discount/charge summary row, including the `fromLines` totals from `job_detail_items.dart:199-200`. They are shown at `charges_panel.dart:407`.
    - The doc comment at `charges_panel.dart:53-55` is stale.
    - Fix: skip `fromLines` rows.
68. **[FIXED 11-25]** **Hover tints on the option buttons:** emerald on Accept, blue on New option and Open job, grey on Undo acceptance and "From estimate #", and Exit preview lightens. Locations: `:1367`, `:1372`, `:1399-1400`, `_addStyle` `:1611-1615`, `_QuietLink` `:1632`, `:1805-1807`. Same root cause as 38.

### Should fix
69. **A failed lines reload after a good load hides things without saying so.** The "This job | Service Fusion" toggle and the "From estimate" link vanish, with no banner and no Retry. On estimates it fails silently and the option actions use stale versions (`:492`; `job_detail_screen.dart:290-300`).
70. **Retry or Refresh on the "couldn't be loaded" fallback swaps the SF items for the skeleton,** even though the page promises it "never loses them" (`:409-428`; `job_detail_screen.dart:291`).
71. **A tax row's label changes after the first edit:** "Sales tax Sales Tax (Fayetteville) 9.75%" (`:31` and `:236` vs `:261-265`). Use one helper.
72. **Out-of-state rate 0 is rejected, but the message says "between 0% and 30%"** (`charges_panel.dart:1675`, `:1727-1730`).
73. **The percent preview repeats the typed text,** giving "10%%" and "1,5%" (`charges_panel.dart:1928-1929`). Format with `SalesTax.rateText`.
74. **Unchecking county or city on a place form removes the row,** and it can't be turned back on (`charges_panel.dart:1282-1293`).
75. **The part checkboxes have an 18 px target,** and the part's name isn't clickable (`charges_panel.dart:1176-1184`).
76. **At 10 options, New option and Duplicate are disabled** and the reason is only in a hidden tooltip (`:1579-1585`, `:1534`).
77. **The "This job | Service Fusion" toggle disappears.** Its track is the same grey as the band, so "Service Fusion" reads as loose text (`:442-447`, `:541`).
78. **The ⋯ menu heading is cut to one line.** "Accepted … · price locked · sent to job #…" doesn't fit the 300 px menu, and under 640 px that heading is the only place this shows (`:1531`, `ps_menu.dart:437-441`).
79. **Narrow width at text ×1.3: the open tab shrinks to 64 px, ignoring `floorOf`,** and overflows (`:1302-1304`).
80. **The panel's Amount row is fixed at 360 px,** so it overflows in windows under about 408 px (`charges_panel.dart:1948-1975`).
81. **Leaving the page right after Send to job can throw.** `_load()` runs without a mounted check, so setState is called after dispose (`:782`; `job_detail_screen.dart:222`).
82. **New option on the SF tab, or with no options, creates a blank option.** It can never get lines because saving is off, and Accept then says "Add line items…" (`:1595`, `:599`). Offer "Copy of Estimate Option" (`_newOption('service_fusion')`).
83. **A custom discount or fee with no name blocks Add without saying why.** On the out-of-state form an empty name gets a red border with no text (`charges_panel.dart:1942`, `:2008`, `:1704`).
84. **The "DFA rate differs" advice can't be followed.** It says "add <place> again from the list", but that button reads "Already on this record" (`charges_panel.dart:1446-1447`). Offer an update action instead.
85. **The value and name boxes have no accessible name;** screen readers hear only "0" (`charges_panel.dart:1537`, `:1565-1584`).
86. **The error banner wraps the raw error in parentheses,** e.g. "couldn't be loaded (Server error (404).)" (`:421`).
87. **Exit preview drops the changes with no confirmation or undo,** while leaving the page does ask (`:1801-1802`, `:388-400`).
88. **ASK. The Tax, discounts & fees panel has hover effects.** The filter tabs use `hoverColor: DashUi.faint`, and Back, Remove, Add and Save tint on hover (`charges_panel.dart:767`, `:1097-1098`, `:1109-1113`). This matters if the no-hover rule covers the panel.

### Nice to have
89. **Red where it shouldn't be:** a red Retry in the amber banner, and red spinners on Accept and New option (theme primary is brand red) (`:422`, `:1396`, `:1587`).
90. **One action, three names:** "Duplicate as a new option", "Duplicate (as saved)" and "Copy of X (as saved)" (`:1534`, `:1599`).
91. **No year in "Accepted Nov 2" and "saved Nov 2"** (`:1415`, `:1429`).
92. **The title reads "Out-of-state: Out-of-state sales tax"** (`charges_panel.dart:1693`).
93. **A preset with no value shows a bare "%" or "$"** (`charges_panel.dart:483`).
94. **The "Amount" heading sits over tax rates** (`charges_panel.dart:875-878`).
95. **Over $999,999.99, the message says "Enter an amount above $0."** (`charges_panel.dart:1888`, `:1983`).
96. **Under 640 px, someone who can't edit gets no menu,** so "Open job #" can't be reached (`:1357-1358`).
97. **Once one option is accepted, the others lose Accept with no note saying why** (`:1389`).
98. **The docs mention recommend and notes actions that don't exist,** so the star can't be set (`:1509-1539`, `:19`).
99. **The job's own read-only empty state says "Search the catalog below"** with no search shown (`:464-479`).
100. **A failed option delete still clears its amber dot and the leave guard** (`:735`).
101. **Between 640 and 760 px the band title is cut to "PRODUCTS & SE…"** (`:530`).
102. **Open menus look different:** the New option menu tints blue (`:1592`), the ⋯ menu uses faint grey (`:1558`).
103. **In the "+N more" menu, Current and Accepted use the same check icon,** and the recommended star is slate rather than amber (`:1147`).
104. **Jargon:** "set" and an unexplained "DFA" (`charges_panel.dart:371`, `:1792-1793`, `:739`, `:1435`, `:1439`, `:1446`).
105. **Panel heading sizes and styles don't match:** 14 vs 15 px titles and three label styles (`charges_panel.dart:682`, `:1031`, `:1309-1312`, `:1317`, `:1435`, `:1635-1641`).
106. **The county choices show the county's own part rate, not the total there** (`charges_panel.dart:1394-1396`).
107. **"Nothing matches" always talks about Arkansas places,** even under the Discounts or Fees filter (`charges_panel.dart:979-983`).
108. **"Done" on a record tax only goes back,** the same as the back arrow (`charges_panel.dart:1462`).
109. **ASK. `_ValueBox` right-aligns its figure,** but the 11-23 rule left-aligns value boxes after the "$" (`charges_panel.dart:1507`).
