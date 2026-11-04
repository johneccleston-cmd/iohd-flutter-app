// The KPI page of someone whose role has no page of its own (John Eccleston, ADMIN, on production's /users answer of
// Nov 2, 2026): the standard title bar (photo, rank, milestone, integrity score; no year picker, since nothing on it
// depends on a year), the morale card with its Preview, and a plain statement that nothing else is measured for the
// role. It fits the desktop sizes without scrolling. Screenshots go to build/dash_shots/.
//   flutter test test/general_kpi_page_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/kpi_dashboard_screen.dart';

import 'dashboard_fit.dart';
import 'dashboard_harness.dart';
import 'tech_kpi_fixture.dart' show jsonResponse;

final _now = DateTime(2026, 11, 2, 9, 30);

/// /users as production sends it (yearsWorked is a numeric, so it arrives as a string).
List<Map<String, dynamic>> _users() => [
      {'id': 'jeccleston', 'name': 'John Eccleston', 'jobTitle': 'ADMIN', 'displayTitle': 'ADMIN', 'avatarUrl': '', 'integrityScore': 100, 'yearsWorked': '1.1691'},
      {'id': 'nsmith', 'name': 'Nick Smith', 'jobTitle': 'Lead Technician', 'displayTitle': 'Lead Technician', 'avatarUrl': '', 'integrityScore': 100, 'yearsWorked': '2.3874'},
    ];

/// GET /api/employees/jeccleston/kpis: an admin gets no role parts, and morale has no source yet.
Map<String, dynamic> _kpis() => {
      'success': true,
      'year': 2026,
      'employee': {'id': 29, 'name': 'John Eccleston', 'username': 'jeccleston', 'role': 'ADMIN', 'jobTitle': 'ADMIN', 'inventoryStrikes': 0, 'warehouseStrikes': 0},
      'sales': null,
      'tech': null,
      'supervisor': null,
      'office': null,
      'warehouse': null,
      'morale': null,
    };

DashFakeApi _api({int kpisStatus = 200}) {
  final api = DashFakeApi();
  api.extra.add((req) async {
    final path = req.url.path;
    if (path == '/users') return jsonResponse(_users());
    if (path == '/api/employees/jeccleston/kpis') return kpisStatus == 200 ? jsonResponse(_kpis()) : jsonResponse({'error': 'simulated'}, kpisStatus);
    return null;
  });
  return api;
}

Widget _page() => const EmployeeKpiScreen(employeeId: 'jeccleston');

void main() {
  setUpAll(loadDashFonts);
  setUp(() async {
    pinDashClock(_now);
    await dashSignIn();
  });
  tearDown(unpinDashClock);

  dashFitTests(
    'general_john',
    _page,
    () => _api(),
    mustShow: ['JOHN ECCLESTON', 'Integrity', "John's morale", 'No performance figures for the Admin role yet'],
  );

  testWidgets('the standard title bar carries what the old profile card showed; no year picker', (t) async {
    await pumpDashboard(t, _page(), api: _api(), size: const Size(1500, 800), body: () async {
      expect(find.text('JOHN ECCLESTON'), findsOneWidget);
      expect(find.textContaining('Rank #'), findsOneWidget);
      expect(find.text('1 yr'), findsOneWidget); // the milestone badge
      expect(find.text('100%'), findsOneWidget); // the integrity score
      expect(find.textContaining('1 yr 2 mo at IOHD'), findsOneWidget);
      // Morale is in its card (with the Preview), not twice in the title bar.
      expect(find.text("John's morale"), findsOneWidget);
      expect(find.text('Morale'), findsNothing);
      expect(dashYearArrow('Previous year'), findsNothing);
      expect(find.byTooltip('All employees'), findsOneWidget);
    });
  });

  testWidgets('a failed details request says so and retries', (t) async {
    await pumpDashboard(t, _page(), api: _api(kpisStatus: 500), size: const Size(1500, 800), body: () async {
      expect(find.text("Couldn't load employee details"), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      // Nothing else on the page: no gap where the morale card would be.
      expect(find.text("John's morale"), findsNothing);
      await saveDashShot(t, 'general_john_error');
    });
  });
}
