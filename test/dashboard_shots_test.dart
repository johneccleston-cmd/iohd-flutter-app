// Renders all eight dashboards from the saved fixtures and saves screenshots to build/dash_shots/ for review
// (git-ignored; these are not goldens). Fails on any layout overflow at the target sizes: 1280x600 (the smallest
// desktop window that must fit without scrolling) and 1500x800.
//
// Run: flutter test test/dashboard_shots_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:iohd_desktop/collections_dashboard_screen.dart';
import 'package:iohd_desktop/commission_dashboard_screen.dart';
import 'package:iohd_desktop/estimates_dashboard_screen.dart';
import 'package:iohd_desktop/inventory_dashboard_screen.dart';
import 'package:iohd_desktop/jobs_dashboard_screen.dart';
import 'package:iohd_desktop/reports_screen.dart';
import 'package:iohd_desktop/sales_dashboard_screen.dart';
import 'package:iohd_desktop/technicians_dashboard_screen.dart';

import 'dashboard_harness.dart';

final _screens = <String, Widget Function()>{
  'financial': () => const ReportsScreen(),
  'commissions': () => const CommissionDashboardScreen(),
  'technicians': () => const TechniciansDashboardScreen(),
  'inventory': () => const InventoryDashboardScreen(),
  'sales': () => const SalesDashboardScreen(),
  'collections': () => const CollectionsDashboardScreen(),
  'jobs': () => const JobsDashboardScreen(),
  'estimates': () => const EstimatesDashboardScreen(),
};

DashFakeApi _api() => DashFakeApi()
  ..extra.add((req) async => req.url.path == '/api/payroll/runs' ? http.Response('{"runs":[]}', 200) : null);

void main() {
  setUpAll(loadDashFonts);
  setUp(() async {
    pinDashClock();
    await dashSignIn();
  });
  tearDown(unpinDashClock);

  for (final size in const [Size(1280, 600), Size(1500, 800)]) {
    for (final e in _screens.entries) {
      final tag = '${e.key}_${size.width.toInt()}x${size.height.toInt()}';
      testWidgets('$tag fits with no overflow', (t) async {
        final errors = await pumpDashboard(t, e.value(), api: _api(), size: size);
        await saveDashShot(t, tag);
        expect(errors.overflowed, isFalse, reason: errors.messages.toSet().join('\n'));
      });
    }
  }

  // The failure and refresh states, once each, for a look.
  testWidgets('states for review: no access, server error, refreshing, refresh failed', (t) async {
    await pumpDashboard(t, const ReportsScreen(), api: _api()..status['/api/financial_dashboard'] = 403);
    await saveDashShot(t, 'state_no_access');
    await pumpDashboard(t, const SalesDashboardScreen(), api: _api()..status['/api/dashboards/sales'] = 500);
    await saveDashShot(t, 'state_server_error');
    final api = _api();
    await pumpDashboard(t, const CollectionsDashboardScreen(), api: api, body: () async {
      await saveDashShot(t, 'state_updated');
      api.delay['/api/dashboards/collections'] = const Duration(seconds: 2);
      await t.tap(find.byTooltip('Refresh now'));
      await t.pump(const Duration(milliseconds: 300));
      await saveDashShot(t, 'state_refreshing');
      await t.pump(const Duration(seconds: 3));
      api.delay.clear();
      api.status['/api/dashboards/collections'] = 500;
      await t.tap(find.byTooltip('Refresh now'));
      await settleDashboard(t, frames: 5);
      await saveDashShot(t, 'state_refresh_failed');
    });
  });
}
