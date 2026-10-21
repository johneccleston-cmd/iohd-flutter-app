// Renders Bella's (office) and Dennis's (warehouse) KPI pages with live-shaped data -> test/shots/kpi_office_*.png
// Run:  flutter test test/kpi_office_warehouse_render_test.dart --update-goldens

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/kpi_dashboard_screen.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    final bytes = File(p).readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
  }
  await loader.load();
}

/// What the backend sends for the two roles (values from the live database, 2026-10-20).
const _bellaOffice = {
  'companyWide': true,
  'outstanding': 238133,
  'over90': 22577,
  'collected': 2440000,
  'collectedMonthly': [230676, 195153, 269204, 395785, 326921, 207158, 293602, 362004, 153804, 78272, 0, 0],
  'collectionRatePct': 91.1,
  'aging': [
    {'label': 'Final Invoice Sent', 'amount': 68400, 'jobs': 105},
    {'label': '14 Day Notice', 'amount': 44500, 'jobs': 30},
    {'label': '30 Day Notice', 'amount': 10500, 'jobs': 8},
    {'label': '60 Day Notice', 'amount': 8600, 'jobs': 6},
    {'label': '90 Day Notice', 'amount': 22577, 'jobs': 40},
    {'label': 'Check on Payment', 'amount': 83600, 'jobs': 20},
  ],
  'tracking': {},
  'reviews': [
    {'quote': 'Bella responded the same morning that I left a message and set up an appointment for a technician to come out.', 'customer': 'Dana K.', 'source': 'Google · 5★', 'date': '2025-08-13T00:00:00Z'},
  ],
  'satisfaction': {'avg': 5.0, 'count': 1},
};

const _dennisWarehouse = {
  'companyWide': true,
  'strikes': 10,
  'zones': [
    {'zone': 'Zone 1', 'periodStart': '2026-10-07', 'status': 'Not started', 'counted': 0, 'completedAt': null, 'overdue': true},
    {'zone': 'Zone 2', 'periodStart': '2026-10-14', 'status': 'In progress', 'counted': 31, 'completedAt': null, 'overdue': true},
    {'zone': 'Zone 3', 'periodStart': '2026-09-16', 'status': 'Complete', 'counted': 82, 'completedAt': '2026-10-16T18:41:57Z', 'overdue': false},
    {'zone': 'Zone 4', 'periodStart': '2026-10-28', 'status': 'Not started', 'counted': 0, 'completedAt': null, 'overdue': false},
  ],
  'cycleDone': 2,
  'itemsCounted': 159,
  'lastCycleCount': '2026-10-16T18:41:57Z',
  'lowStockCount': 132,
  'stockValue': 55199,
  'openPos': {'count': 7, 'value': 18420.5, 'overdue': 2, 'oldest': '2026-09-14'},
  'itemCount': 443,
  'tracking': {'pickAccuracy': false, 'receivingTime': false, 'orderFillRate': false},
};

bool _oldBackend = false;

http.Response _handle(http.Request r) {
  if (r.url.path.endsWith('/users') || r.url.path.endsWith('/admin/users')) {
    return http.Response(
      jsonEncode({
        'users': [
          {'id': 'bella', 'name': 'Bella Hansberger', 'role': 'Office', 'integrity_score': 97.0, 'years_worked': 2.0, 'avatar_url': ''},
          {'id': 'dgray', 'name': 'Dennis Gray', 'role': 'warehouse', 'job_title': 'Warehouse Technician', 'integrity_score': 90.0, 'years_worked': 2.0, 'avatar_url': ''},
        ],
      }),
      200,
    );
  }
  final isBella = r.url.path.contains('/bella/');
  return http.Response(
    jsonEncode({
      'employee': isBella
          ? {'id': 37, 'role': 'Office', 'inventoryStrikes': 0, 'warehouseStrikes': 0}
          : {'id': 31, 'role': 'warehouse', 'inventoryStrikes': 15, 'warehouseStrikes': 0},
      if (isBella) 'office': _bellaOffice,
      if (!isBella && !_oldBackend) 'warehouse': _dennisWarehouse,
    }),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

Future<void> _shot(WidgetTester tester, Size size, String name, {required String id, bool oldBackend = false}) async {
  _oldBackend = oldBackend;
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await http.runWithClient(() async {
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
        home: EmployeeKpiScreen(employeeId: id),
      ),
    );
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // A RenderFlex overflow or any other build error fails the test instead of just painting a stripe.
    final ex = tester.takeException();
    expect(ex, isNull, reason: '$name threw: $ex');
    final scrolls = find.byType(SingleChildScrollView);
    if (scrolls.evaluate().isNotEmpty) {
      final sc = tester.state<ScrollableState>(find.descendant(of: scrolls.first, matching: find.byType(Scrollable)).first);
      debugPrint('$name: scrolls=${sc.position.maxScrollExtent > 0.5} (extent ${sc.position.maxScrollExtent.toStringAsFixed(1)})');
    }
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/$name.png'));
  }, () => MockClient((r) async => _handle(r)));
}

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', [r'C:\Windows\Fonts\segoeui.ttf', r'C:\Windows\Fonts\segoeuib.ttf', r'C:\Windows\Fonts\seguisb.ttf']);
    final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter';
    await _loadFont('Roboto', [
      '$flutterRoot/bin/cache/artifacts/material_fonts/roboto-regular.ttf',
      '$flutterRoot/bin/cache/artifacts/material_fonts/roboto-medium.ttf',
      '$flutterRoot/bin/cache/artifacts/material_fonts/roboto-bold.ttf',
    ]);
    await _loadFont('MaterialIcons', ['$flutterRoot/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
  });

  testWidgets('bella 1500x720', (t) async => _shot(t, const Size(1500, 720), 'kpi_office_bella_1500', id: 'bella'));
  testWidgets('bella 1280x600', (t) async => _shot(t, const Size(1280, 600), 'kpi_office_bella_1280', id: 'bella'));
  testWidgets('bella 1000x700 narrow', (t) async => _shot(t, const Size(1000, 700), 'kpi_office_bella_1000', id: 'bella'));
  testWidgets('dennis 1500x720', (t) async => _shot(t, const Size(1500, 720), 'kpi_office_dennis_1500', id: 'dgray'));
  testWidgets('dennis 1280x600', (t) async => _shot(t, const Size(1280, 600), 'kpi_office_dennis_1280', id: 'dgray'));
  testWidgets('dennis 1000x700 narrow', (t) async => _shot(t, const Size(1000, 700), 'kpi_office_dennis_1000', id: 'dgray'));
  testWidgets('dennis old backend', (t) async => _shot(t, const Size(1500, 720), 'kpi_office_dennis_old', id: 'dgray', oldBackend: true));
}
