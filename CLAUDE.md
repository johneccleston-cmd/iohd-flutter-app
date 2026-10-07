# IOHD Desktop (`iohd_desktop`)

Flutter desktop/web back-office app for IOHD office staff: jobs, estimates, customers,
calendar, inventory, payroll/commissions and dashboards. Talks to a Node backend on Render.

## Layout

- `lib/main.dart`: the `GoRouter` (auth redirect + `StatefulShellRoute.indexedStack` branches) and the app theme.
- `lib/config/api_config.dart`: `kApiBaseUrl` / `kAuthToken` (overridable with `--dart-define`).
- `lib/config/auth_session.dart`: `AuthSession.instance`, the signed-in user and `headers()` for every API call.
- `lib/widgets/main_navigation_shell.dart`: top nav bar and dropdown menus. Every new page needs an entry here.
- `lib/widgets/dashboard_layout.dart` + `dashboard_kit.dart`: the shared dashboard frame and building blocks (`DashUi`, `AnimatedMetricCard`, `SkeletonPulse`, `DashErrorPanel`, `dashMoney`).
- `lib/widgets/app_components.dart` + `lib/theme/app_theme.dart`: light-theme tokens and small shared components.
- Screens live flat in `lib/*_screen.dart`. `payroll_pdf.dart` is a `part of` `payroll_screen.dart`.

## Commands

```bash
flutter pub get
flutter analyze            # must be clean before committing
flutter test
flutter run -d chrome      # or -d windows / -d macos
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:3000
flutter build web --release
```

The cloud container may not have the Flutter SDK. If `flutter` is missing, say so and don't claim
analyze or tests passed.

## Rules

- API calls go through `AuthSession.instance.headers()`, have a `.timeout(...)`, and treat 401 as "sign out".
- Every data screen handles loading, error (with retry) and empty states. See the `ux-states` skill.
- Use the existing tokens (`DashUi`, `AppTheme`) instead of new hex literals.
- Don't add new secrets to source. `kAuthToken` is a shared app key, not a user credential.
- Office-only app: the login rejects non-admin accounts. Don't weaken that check.

Skills for common tasks are in `.claude/skills/`.
