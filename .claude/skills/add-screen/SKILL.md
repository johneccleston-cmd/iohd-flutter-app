---
name: add-screen
description: Add a new page/screen to the IOHD app and wire it into the GoRouter and the top navigation menu. Use when asked to create a new screen, page, tab, or section, or to replace the remaining placeholder (`/office`, `_PlaceholderScreen` in main.dart).
---

# Adding a screen

A screen needs four things to be reachable: the widget file, a route in `lib/main.dart`, an
`AccessResource` in `lib/config/access.dart`, and a menu row in `lib/widgets/main_navigation_shell.dart`.
Missing any of them gives a dead link, a page non-admins can't see, or an `accessIcon()` throw.

## 1. Create the file

`lib/<feature>_screen.dart`, with the class named `<Feature>Screen`. Pick the base:

- **Dashboard / analytics page**: use the `dashboard-screen` skill (`DashboardLayout`).
- **List / table page** (customers, jobs, vendors): a flat full page: `PageBanner(icon: accessIcon('<key>'))`
  plus the kit in `lib/widgets/flat_page.dart` (`FlatTable`, `FlatTableHeader`, `FlatPager`). Payments, Invoices
  and Customers are current examples; Jobs/Estimates share `record_list_view.dart`. See the `data-tables` skill.
- **Detail view**: a child route, like `jobDetailRoute()` (`/jobs/<n>`) or `customerDetailRoute()` (`/customers/<id>`).

Add `with AutomaticKeepAliveClientMixin` (and call `super.build(context)`) on heavy list screens
so switching branches doesn't refetch.

## 2. Register the route (`lib/main.dart`)

Routes live inside `StatefulShellRoute.indexedStack`. **Branch order matters**: `_goBranch(i)` in the
shell uses the index.

| Index | Branch | Root path |
|-------|--------|-----------|
| 0 | Office | `/office` (+ `/statuses`, `/payments`, `/invoices`, `/documents`, `/site-checks`, `/takeoffs`) |
| 1 | Customers | `/customers` |
| 2 | Projects | `/projects` |
| 3 | Estimates | `/estimates` |
| 4 | Jobs | `/jobs` |
| 5 | Calendar | `/calendar` |
| 6 | Inventory | `/inventory` (+ `catalog`, `purchase-orders`, `vendors`) |
| 7 | HR | `/hr` (redirects to `/hr/payroll`; + `payroll`, `kpis`, `kpis/:id`, `team`, `corrections`) |
| 8 | Dashboards | `/dashboards` (+ `financial`, `commissions`, …) |
| 9 | Profile | `/profile` |

- A sub-page of an existing area is a child `GoRoute` with a **relative** path (`'vendors'`, no leading slash).
- A page in the Office dropdown goes into branch 0's `routes:` list as a top-level path.
- Only add a new `StatefulShellBranch` for a new top-level nav item, and append it at the end so
  existing indexes don't shift.
- Read query params with `state.uri.queryParameters['q']` (global search sends `?q=`).
- All routes except `/login` are auth-guarded by the router `redirect`. Don't add per-screen checks.

## 3. Add the menu entry (`main_navigation_shell.dart`)

Add the page's `AccessResource` (key, label, icon, route, group) in `lib/config/access.dart`, then a
`('<access key>', Icons.x_rounded, 'Label', '/route')` row in the right `group(...)` inside `_navFor()`.
Dashboards are listed from `kAccessGroups` automatically. Use a `*_rounded` Material icon; menu labels
are Title Case, with no emoji.

## 4. Check

- Run `grep -n "'/your-path'" lib/main.dart lib/widgets/main_navigation_shell.dart lib/config/access.dart`. All should match.
- The page starts with the standard ribbon (`PageBanner(icon: accessIcon('<key>'))` or `DashboardLayout`).
- The page has a visible title, plus loading, error and empty states (`ux-states` skill).
- `flutter analyze` is clean.
