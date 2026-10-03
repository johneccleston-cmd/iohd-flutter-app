---
name: data-tables
description: Build list and table screens in the IOHD app (customers, jobs, inventory, vendors, payments, invoices) with search, filters, sorting, pagination, number/date formatting and row actions. Use when creating or improving any list, table, DataTable, search box, filter chips, or paginated view.
---

# Lists and tables

Reference implementation: `lib/customers_screen.dart` (debounced search, server paging, sort,
page cache with prefetch, stale-response guard). Copy its structure for new list screens.

## Search

- Debounce typing by ~300ms with a `Timer`, and reset to page 1 on a new query.
- Show the query in the empty state ("No results for …") with a clear (x) suffix button.
- Read an initial `?q=` from the route. The global search in the nav bar sends job IDs to `/jobs`
  and everything else to `/customers`.
- Ignore stale responses with a request counter (`_requestId`).

## Filters and sort

- Status filters are chips with the status colour dot (see `design-system`). Include "All" plus a count per chip when the API gives one.
- Sortable columns show an arrow on the active column. Clicking toggles asc/desc. Sort server-side when paging server-side.
- Keep the filter, sort and page in state so returning to the tab (keep-alive) restores the view.

## Pagination

- Server paging for anything unbounded (customers, jobs, estimates). Footer: "1–50 of 1,284" + prev/next + page-size select (25/50/100).
- Cache pages by `query|page|size|sort|dir` and prefetch the next page.
- Client-side paging is fine only for small, bounded lists (vendors, statuses).

## Table layout

- Header row: 12px UPPERCASE, w600, slate. Rows are 44–52px tall with a hairline divider, plus a hover
  tint (`DashUi.faint`) when the row is clickable, and `MouseRegion(cursor: SystemMouseCursors.click)`.
- **Right-align** money and numbers, left-align text, and centre short status badges. Keep consistent decimals.
- First column is the identifier (bold, w600). Truncate long text with `TextOverflow.ellipsis` +
  a `Tooltip` showing the full value.
- Wide tables: wrap `DataTable` in a horizontal `SingleChildScrollView` inside a `LayoutBuilder`
  with `ConstrainedBox(minWidth: constraints.maxWidth)` so it fills the space on wide screens and
  scrolls on narrow ones. On compact widths (<600), consider switching to cards.
- Row click opens details (dialog like `job_details_dialog.dart`). Row actions go in a trailing
  `PopupMenuButton` (`Icons.more_horiz_rounded`) with tooltip "More actions".
- Sticky header and totals row for long financial tables (payroll, commissions).

## Formatting (intl)

```dart
final money = NumberFormat.simpleCurrency(locale: 'en_US');   // or dashMoney(v)
final count = NumberFormat.decimalPattern();                  // 1,284
final date  = DateFormat('MMM d, yyyy');                      // Oct 1, 2026
```

Negative money is shown in red with a minus sign. Use "—" for missing values, not "0" or "null".
Show phone numbers formatted and emails as selectable text.

## Performance

Use `ListView.builder` / lazily built rows for long lists. Don't build 1,000 `DataRow`s at once;
page instead. Avoid calling `setState` on every keystroke without debounce.
