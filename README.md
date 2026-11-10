# IOHD Office

Flutter desktop/web back-office app for Integrity Overhead Door: jobs, estimates, customers, calendar, inventory,
payroll/commissions, KPI pages and dashboards. It talks to the Node backend (`integrity-backend`) on Render.

```bash
flutter pub get
flutter analyze
flutter test
flutter run -d chrome                                   # or -d windows / -d macos
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:3000
```

Project layout, rules and how the web build is published are in [CLAUDE.md](CLAUDE.md). Task guides live in
[.claude/skills/](.claude/skills/).
