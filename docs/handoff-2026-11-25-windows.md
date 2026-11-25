# Handoff 2026-11-25: verify the job page fixes on Windows

**Status:** the 15 Must fix items from `docs/job-detail-ui-audit-2026-11-24.md` are fixed in code on `main`, but
**not analyzed, tested or rendered yet**. Flutter can't run on the Mac they were written on (macOS 13; this SDK's
Dart needs macOS 14). Treat `main` as unverified until the steps below pass.

## What happened today

1. **The Mac's repos were pulled up to date.** For this repo that brought in the 11-24 audit (109 findings).
2. **The 15 Must fix items were fixed** (audit items 1–10, 38–40, 67, 68; marked **[FIXED 11-25]** in the audit):
   - **1** The paid bar holds at 99% while anything is owed (it showed "100% paid" with money still due).
   - **2** Status and sub-status are read-only pills ("Not set" when empty). The picker that couldn't save is gone.
   - **3, 4** Details and Job Info tabs measure whether their names fit: beside the title, under it, or icons only
     when nothing fits. No more `FittedBox` shrinking at 1.3× text.
   - **5** The copy button (PO #, phone) is always shown in quiet grey, also on narrow stacked rows; no hover wash.
   - **6** Picture tiles open from the keyboard (Tab, then Enter or Space) and have screen-reader labels.
   - **7** Service Fusion documents that are only a file name no longer look clickable; they say
     "Open it in Service Fusion".
   - **8** Not-found page: `DashErrorPanel`, "Estimate" wording on estimates, "Back to jobs / estimates"; Try again
     only for real load failures.
   - **9** The "Description ⌄" toggle drops under a long name instead of landing mid-name.
   - **10** Summary labels (Gross profit, Payments/Deposits) stay on one line and shrink slightly at large text.
   - **38, 68** New shared `dashNoHoverOverlay` (`lib/widgets/dashboard_kit.dart`) on the table's quiet buttons, the
     "Use last billed" button and the option buttons (Accept, New option, Open job, Undo acceptance, Exit preview…).
   - **39** Move up / Move down are disabled at the ends of each part (products vs discounts and fees).
   - **40** The recent-price hint says "Check the price before quoting." once a price is typed.
   - **67** Service Fusion discounts and fees are listed once, not twice, in Tax, discounts & fees.
3. **Tests updated** for the new behaviour: `test/job_page_behavior_test.dart` (not-found page) and
   `test/job_detail_render_test.dart` (status is read-only; the old status-menu test is replaced).
   `test/shots/job_detail_status_menu.png` is now unused; it was left in place.
4. **The Mac's Flutter SDK was reset** to `ab2912035` while chasing the macOS problem. That didn't help (the old
   commit needs macOS 14 too). The Windows SDK is unaffected.

Files changed: `lib/job_detail_screen.dart`, `lib/job_detail_items.dart`, `lib/widgets/line_items_editor.dart`,
`lib/widgets/charges_panel.dart`, `lib/widgets/dashboard_kit.dart`, the two tests above, and the audit doc.

## What the Windows machine needs to do

```
git checkout main
git pull
flutter pub get
flutter analyze
flutter test
```

1. **`flutter analyze` must be clean.** Nothing was compiled, so typos or type errors are possible. Most likely spots:
   - `_DetailTabs.fullWidth` and `_textWidth` in `job_detail_screen.dart`;
   - the `_PicTile` `Semantics` / `FocusableActionDetector` wrapper;
   - the `moves` record on `_ViewRow` / `_EditRow` / `_RowMenu` in `line_items_editor.dart`.
2. **Run the tests.** The ones that touch these changes: `job_page_behavior_test.dart`, `job_detail_render_test.dart`,
   `line_items_summary_payments_test.dart`, `line_items_preview_test.dart`, `service_products_test.dart` and the
   `ps_*` tests.
3. **Golden (screenshot) failures:** expected where the page now looks different. Many goldens were already stale.
   Look at each one before running `--update-goldens`; don't regenerate them all blindly.
4. **Look at the page** (`flutter run -d windows`) on a job and an estimate:
   - Details and Job Info tab bars at window widths 1920, 1366, 1280, 1100, 900 and 800, and at 1.3× text;
   - the summary blocks (Gross profit, Payments/Deposits) at 1.3× text;
   - a long product name with a description (toggle under the name);
   - Tab to a picture and press Enter; Tab to the copy button on PO #;
   - hover the option buttons and the Tax, discounts & fees button: no shading;
   - open a missing job (`/jobs/1999999999`) and a missing estimate.
5. **If anything fails,** fix it on `main` or paste the output to Claude. Check `flutter analyze` is clean before
   committing.

## Still open

94 audit items remain (all Should fix and Nice to have). Five need a decision first (**ASK**):

- **20** Should the Products & Services block line up with the blocks above it?
- **45** Keep the 400 px item column, or let it grow on wide screens?
- **66** Totals block: 460 px (code) or 420 (the 11-24 note)?
- **88** Does the no-hover rule cover the Tax, discounts & fees panel?
- **109** Right- or left-align value boxes?

The full list is in `docs/job-detail-ui-audit-2026-11-24.md`.
