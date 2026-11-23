// The Services Catalog UX harness as a Windows desktop app (fake admin, fake data and saves: nothing leaves the
// machine). LOCAL ONLY: never shipped. The browser harness (services_harness.dart) is the one the checks use.
//
//   flutter run -d windows -t tool/ux_harness/services_harness_desktop.dart

import 'services_harness_app.dart';

Future<void> main() => runServicesHarness();
