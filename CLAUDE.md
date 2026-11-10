# IOHD Office (`iohd_desktop`)

Flutter desktop/web back-office app for IOHD office staff: jobs, estimates, customers,
calendar, inventory, payroll/commissions and dashboards. Talks to a Node backend on Render.

## Layout

- `lib/main.dart`: the `GoRouter` (auth redirect + `StatefulShellRoute.indexedStack` branches) and the app theme.
- `lib/config/api_config.dart`: `kApiBaseUrl` / `kAuthToken` (overridable with `--dart-define`).
- `lib/config/auth_session.dart`: `AuthSession.instance`, the signed-in user and `headers()` for every API call.
- `lib/config/access.dart`: every page's `AccessResource` (key, icon, route, group). Non-admin visibility, `accessIcon('<key>')` and the
  Dashboards menu all come from here, so a new page needs an entry.
- `lib/widgets/main_navigation_shell.dart`: top nav bar, menus (`_navFor`), Ask Jarvis button, global search. A new page also needs a row in `_navFor`.
- `lib/widgets/app_ribbon.dart`: the standard navy title bar (see Rules).
- `lib/widgets/dashboard_layout.dart` + `dashboard_kit.dart`: the shared dashboard frame and building blocks (`DashUi`, `AnimatedMetricCard`, `SkeletonPulse`, `DashErrorPanel`, `dashMoney`).
- `lib/widgets/dashboard_panels.dart` (`DashPanel`, `DashGeo`, `DashMonthChart`, `DashSegmented`, `DashDrillCard`...), `dash_story.dart` (`DashStoryFrame`,
  `dashMonthStory`, `DashMonthBars`), `dash_hover_card.dart` and `dashboard_data.dart` (`DashRequests`, `DashClock`): used by all 8 dashboards and the KPI pages.
- `lib/widgets/flat_page.dart`: `PageBanner` and the flat full-page kit (`FlatTable`, `FlatTableHeader`, `FlatPager`, `FlatStats`...) for list/detail screens;
  `record_list_view.dart` is the shared Jobs/Estimates list. `lib/widgets/app_dialog.dart`: `AppDialog`, `AppButton`, `appFieldDecoration`, `AppSegmented`.
- `lib/widgets/app_components.dart` + `lib/theme/app_theme.dart`: light-theme tokens and small shared components.
- Screens live flat in `lib/*_screen.dart`. Part files: `payroll_pdf.dart` (of `payroll_screen.dart`), `employee_kpi_*.dart` (of `kpi_dashboard_screen.dart`),
  `team_admin_widgets.dart`, `job_detail_items.dart`, `widgets/assistant_workspace.dart` (of `assistant_panel.dart`).
- Tests: `test/` holds widget tests, per-screen `*_fixture.dart` fake APIs, `test/dashboard_fit.dart` (no-overflow sizes) and golden PNGs in `test/shots/`.
  Many goldens are stale; don't regenerate them (`--update-goldens`) without the user's OK.

## Commands

```bash
flutter pub get
flutter analyze            # must be clean before committing
flutter test
flutter run -d chrome      # or -d windows / -d macos
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:3000
flutter build web --release --output build/web_release   # publishing: see below
```

The office web app is served by the backend (`integrity-backend/src/public`). Publish by building into `build/web_release` (a running
`flutter run` rewrites `build/web`), check that `flutter_bootstrap.js` parses, then copy it over. Copying it in and pushing the backend is a deploy: only with the user's OK.

The cloud container may not have the Flutter SDK. If `flutter` is missing, say so and don't claim
analyze or tests passed.

## Rules

- API calls go through `AuthSession.instance.headers()`, have a `.timeout(...)`, and treat 401 as "sign out".
- Every data screen handles loading, error (with retry) and empty states. See the `ux-states` skill.
- Use the existing tokens (`DashUi`, `AppTheme`) instead of new hex literals.
- Every screen starts with the standard ribbon from `lib/widgets/app_ribbon.dart`, never a hand-built dark bar:
  `DashboardLayout` for dashboards and KPI pages, `PageBanner` (or `AppRibbon`) for full pages and dialogs that
  carry a title bar, `RibbonSurface` + `RibbonIcon`/`RibbonTitle` only when a toolbar needs its own layout (Payroll).
  Pass the page's menu icon (`accessIcon('<key>')`), use `RibbonColors` for anything drawn on it, `PageBanner.button`
  for white buttons and `RibbonRefreshButton` for Refresh. Change the ribbon's look or motion only in `app_ribbon.dart`.
- Don't add new secrets to source. `kAuthToken` is a shared app key, not a user credential.
- Office-only app: sign-in rejects technician accounts (`isTechnicianRole` in `auth_session.dart`; techs use the Android app), and non-admins see
  only the pages allowed in `lib/config/access.dart`, enforced by the router redirect and the nav bar. Don't weaken either check.
- Never write to Service Fusion: the sync is read-only and edits are saved to our own database only.
- UI conventions the user set: dashboards and KPI pages fit the window with no scrolling; other screens are flat full pages (cards only on
  dashboards/KPIs); selected tab text is `DashUi.ink`, never blue, and panel tabs sit flush right; every chart leads with a plain-English
  headline and callout; scorecards get a label plus a caption; motion is welcome but gated on reduced motion. Render UI changes and look
  at them before reporting.

Skills for common tasks are in `.claude/skills/`.
