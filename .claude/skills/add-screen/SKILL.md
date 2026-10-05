---
name: add-screen
description: Add a new page/screen to the IOHD app and wire it into the GoRouter and the top navigation menu. Use when asked to create a new screen, page, tab, or section, or to replace one of the "Under Construction" placeholders.
---

# Adding a screen

A screen needs three things to be reachable: the widget file, a route in `lib/main.dart`, and a
menu entry in `lib/widgets/main_navigation_shell.dart`. Missing any of them gives a dead link.
For example, the nav menu already links `/site-checks` and `/takeoffs`, but `main.dart` has no
routes for them yet.

## 1. Create the file

`lib/<feature>_screen.dart`, with the class named `<Feature>Screen`. Pick the base:

- **Dashboard / analytics page**: use the `dashboard-screen` skill (`DashboardLayout`).
- **List / table page** (customers, jobs, vendors): `StatefulWidget` + `Scaffold` with the light
  theme. Follow `lib/customers_screen.dart` for search, paging and caching. See the `data-tables` skill.
- **Detail view**: prefer a dialog (see `lib/job_details_dialog.dart`) unless it needs a URL.

Add `with AutomaticKeepAliveClientMixin` (and call `super.build(context)`) on heavy list screens
so switching branches doesn't refetch.

## 2. Register the route (`lib/main.dart`)

Routes live inside `StatefulShellRoute.indexedStack`. **Branch order matters**: `_goBranch(i)` in the
shell uses the index.

| Index | Branch | Root path |
|-------|--------|-----------|
| 0 | Office | `/office` (+ `/statuses`, `/payments`, `/invoices`) |
| 1 | Customers | `/customers` |
| 2 | Projects | `/projects` |
| 3 | Estimates | `/estimates` |
| 4 | Jobs | `/jobs` |
| 5 | Calendar | `/calendar` |
| 6 | Inventory | `/inventory` (+ `catalog`, `purchase-orders`, `vendors`) |
| 7 | HR | `/hr` (+ `kpis`, `team`, `corrections`) |
| 8 | Dashboards | `/dashboards` (+ `financial`, `commissions`, …) |

- A sub-page of an existing area is a child `GoRoute` with a **relative** path (`'vendors'`, no leading slash).
- A page in the Office dropdown goes into branch 0's `routes:` list as a top-level path.
- Only add a new `StatefulShellBranch` for a new top-level nav item, and append it at the end so
  existing indexes don't shift.
- Read query params with `state.uri.queryParameters['q']` (global search sends `?q=`).
- All routes except `/login` are auth-guarded by the router `redirect`. Don't add per-screen checks.

## 3. Add the menu entry (`main_navigation_shell.dart`)

Copy a neighbouring `_dropdownMenuItem(icon: ..., label: ..., route: ..., controller: controller)`
under the right `_menuSectionHeader`. Use a `*_rounded` Material icon to match the others.
Labels are Title Case, with no emoji.

## 4. Check

- Run `grep -n "'/your-path'" lib/main.dart lib/widgets/main_navigation_shell.dart`. Both files should match.
- The page has a visible title, plus loading, error and empty states (`ux-states` skill).
- `flutter analyze` is clean.
