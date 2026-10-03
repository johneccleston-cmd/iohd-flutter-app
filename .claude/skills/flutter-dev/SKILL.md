---
name: flutter-dev
description: Build, run, analyze and test the IOHD Flutter app (web, Windows, macOS). Use when asked to run the app, fix analyzer warnings or build errors, add or upgrade a package, point the app at a different backend, or prepare a release build.
---

# Flutter dev workflow

## 1. Check the toolchain first

```bash
flutter --version || echo "NO FLUTTER SDK"
```

If the SDK is missing (common in cloud containers), don't pretend checks passed. Do static review
instead, and tell the user which commands they need to run locally.

## 2. Standard loop

```bash
flutter pub get
flutter analyze
flutter test            # there is no test/ folder yet; create one if adding tests
```

`flutter analyze` uses `package:flutter_lints/flutter.yaml` (see `analysis_options.yaml`). Platform
folders are excluded. Fix warnings in the files you touched. Don't add blanket
`// ignore_for_file:` lines.

## 3. Running

| Target  | Command |
|---------|---------|
| Web     | `flutter run -d chrome` |
| Windows | `flutter run -d windows` |
| macOS   | `flutter run -d macos` |
| Local backend | add `--dart-define=API_BASE_URL=http://localhost:3000` |

`kApiBaseUrl` and `kAuthToken` come from `String.fromEnvironment` in `lib/config/api_config.dart`.
The default backend is the Render instance, which can take up to a minute to wake up. That's why
requests use long timeouts.

## 4. Dependencies

- Add with `flutter pub add <pkg>`, never by hand-editing `pubspec.lock`.
- Current stack: `go_router`, `http`, `intl`, `table_calendar`, `pdf`, `printing`, `cached_network_image`.
  Prefer these before adding something new. There's no state-management package; screens use
  `StatefulWidget` + `setState`, and `AuthSession` is a `ChangeNotifier`.
- Root `package.json` / `node_modules` (only `cors`) are leftovers and unrelated to the Flutter build.

## 5. Release

```bash
flutter build web --release --dart-define=API_BASE_URL=<prod url>
flutter build windows --release
```

Bump `version:` in `pubspec.yaml` (`x.y.z+build`) for releases.

## Done means

- `flutter analyze` reports no new issues in touched files (or you've said it couldn't be run).
- The app still starts at `/login` → `/calendar` after sign-in.
