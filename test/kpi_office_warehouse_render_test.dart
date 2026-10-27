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
final _bellaOffice = <String, Object?>{
  'companyWide': true,
  'outstanding': 238133,
  'over90': 22577,
  'collected': 2440000,
  'collectedMonthly': [230676, 195153, 269204, 395785, 326921, 207158, 293602, 362004, 153804, 78272, 0, 0],
  'collectionRatePct': 91.1,
  // Incoming Quo calls to Bella per month and the ones nobody answered (2026 counts on the main office number 479-238-2493 and Bella's own line, from prod 2026-10-27, Mon-Fri 8-5 only).
  'missedCalls': {
    'missed': [3, 5, 4, 0, 4, 2, 1, 0, 1, 5, 0, 0],
    'total': [5, 11, 5, 0, 7, 4, 2, 1, 2, 10, 0, 0],
  },
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

final _dennisWarehouse = {
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
  'callbackStrikes': 0,
  'jobsCompleted': 41,
  'jobsMonthly': [0, 0, 3, 6, 5, 8, 7, 6, 4, 2, 0, 0],
  'cycleMonthly': [0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0],
  'history': {
    'lowStock': [41, 40, 42, 39, 37, 38, 35],
    'teamStrikes': [3, 3, 4, 4, 4, 5, 5],
  },
  'inventoryAccuracy': {'counted': 160, 'matched': 151, 'pct': 94.4},
  'openPos': {
    'count': 7,
    'value': 18420.5,
    'overdue': 2,
    'oldest': '2026-09-14',
    'aging': [
      {'label': '0-7 days', 'count': 2, 'value': 3200.0},
      {'label': '8-14 days', 'count': 1, 'value': 1100.5},
      {'label': '15-30 days', 'count': 3, 'value': 9120.0},
      {'label': '31+ days', 'count': 1, 'value': 5000.0},
    ],
  },
  'accuracyTrend': [
    {'week': '2026-08-03', 'counted': 22, 'pct': 90.9},
    {'week': '2026-08-10', 'counted': 30, 'pct': 93.3},
    {'week': '2026-08-17', 'counted': 18, 'pct': 94.4},
    {'week': '2026-08-24', 'counted': 25, 'pct': 92.0},
    {'week': '2026-09-07', 'counted': 28, 'pct': 96.4},
    {'week': '2026-09-14', 'counted': 20, 'pct': 95.0},
    {'week': '2026-09-21', 'counted': 17, 'pct': 94.1},
  ],
  'topMisses': [
    {'name': 'Torsion Spring | 0.234 x 2 | 32 in', 'systemQty': 14, 'countedQty': 6},
    {'name': 'Belt Drive | 6690L | LiftMaster', 'systemQty': 4, 'countedQty': 1},
    {'name': 'Hinge | Shim Kit | Up to 9" Wide', 'systemQty': 10, 'countedQty': 12},
    {'name': 'Fire Chain', 'systemQty': 3, 'countedQty': 2},
  ],
  'cycleHistory': [
    for (final n in [1, 2, 3, 4])
      {
        'zone': 'Zone $n',
        'weeks': [
          for (final m in [5, 6, 7, 8, 9, 10])
            {'periodStart': '2026-${m.toString().padLeft(2, '0')}-${(n * 7 + 6).toString().padLeft(2, '0')}', 'status': (m + n) % 4 == 0 ? 'Missed' : (m == 10 && n > 2 ? 'Pending' : 'Complete')},
        ],
      },
  ],
  'itemCount': 443,
  'tracking': {'pickAccuracy': false, 'receivingTime': false, 'orderFillRate': false},
};

bool _oldBackend = false;

// What GET /api/dashboards/collections returns (the figures Bella's page takes from it).
final _collections = {
  'summary': {'collected': 2440000, 'outstanding': 238177, 'over90': 22577},
  'stages': [
    for (final (i, a) in [('Final Invoice Sent', 68400, 105), ('14 Day Notice', 44500, 30), ('30 Day Notice', 10500, 8), ('60 Day Notice', 8600, 6), ('90 Day Notice', 22577, 40), ('Check on Payment', 83600, 20)].indexed)
      {'stage': '$i', 'label': a.$1, 'amount': a.$2, 'jobCount': a.$3},
  ],
  'monthly': [
    for (final (i, v) in [230676, 195153, 269204, 395785, 326921, 207158, 293602, 362004, 153804, 78272].indexed) {'month_num': i + 1, 'collected': v},
  ],
};

http.Response _handle(http.Request r) {
  if (r.url.path.endsWith('/dashboards/collections')) {
    return http.Response(jsonEncode(_collections), 200, headers: {'content-type': 'application/json; charset=utf-8'});
  }
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
  if (r.url.path.endsWith('/quo/backfill')) {
    return http.Response(
      jsonEncode({
        'running': false,
        'finishedAt': '2026-10-27T20:10:00Z',
        'calls': 4120,
        'messages': 9300,
        'errors': 0,
        'perLine': {
          '+14793331210': {'id': 'PNUKNtIVIy', 'name': 'Bella Hansberger', 'conversations': 310, 'calls': 640, 'messages': 1500},
          '+14792382493': {'id': 'PNXpkhqe5B', 'name': 'Main office', 'conversations': 900, 'calls': 2100, 'messages': 700},
        },
      }),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }
  if (r.url.path.endsWith('/missed_calls')) {
    return http.Response(
      jsonEncode({
        'success': true,
        'matched': true,
        'count': 6,
        'items': [
          {'id': 'a', 'at': '2026-10-26T11:15:00', 'phone': '4796406178', 'name': null, 'nameFrom': null, 'line': 'Main', 'status': 'no-answer', 'seconds': 0},
          {'id': 'b', 'at': '2026-10-23T11:28:00', 'phone': '4795315715', 'name': 'Jared T. (Quo)', 'nameFrom': 'Quo contact', 'line': 'Main', 'status': 'no-answer', 'seconds': 0},
          {'id': 'c', 'at': '2026-10-23T10:13:00', 'phone': '9186886136', 'name': 'Maxwell Barn Company LLC', 'nameFrom': 'Customer', 'line': 'Main', 'status': 'no-answer', 'seconds': 0},
          {'id': 'd', 'at': '2026-09-22T13:50:00', 'phone': '4794384437', 'name': null, 'nameFrom': null, 'line': 'Bella Hansberger', 'status': 'no-answer', 'seconds': 0},
          {'id': 'e', 'at': '2026-04-13T09:52:00', 'phone': '4798412737', 'name': 'Thomas Good', 'nameFrom': 'Customer', 'line': 'Main', 'status': 'no-answer', 'seconds': 32},
          {'id': 'f', 'at': '2026-01-05T15:13:00', 'phone': '9137270331', 'name': null, 'nameFrom': null, 'line': 'Main', 'status': 'no-answer', 'seconds': 0},
        ],
      }),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
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

Future<void> _shot(WidgetTester tester, Size size, String name, {required String id, bool oldBackend = false, Future<void> Function(WidgetTester)? after}) async {
  _oldBackend = oldBackend;
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  final prevOnError = FlutterError.onError;
  FlutterError.onError = (d) {
    debugPrint(d.toString(minLevel: DiagnosticLevel.debug));
    prevOnError?.call(d);
  };
  addTearDown(() => FlutterError.onError = prevOnError);
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
    if (after != null) await after(tester);
    // A RenderFlex overflow or any other build error fails the test instead of just painting a stripe.
    final ex = tester.takeException();
    if (ex is FlutterError) debugPrint(ex.toStringDeep());
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
  testWidgets('bella 1280x720', (t) async => _shot(t, const Size(1280, 720), 'kpi_office_bella_1280x720', id: 'bella'));
  testWidgets('bella 1100x600', (t) async => _shot(t, const Size(1100, 600), 'kpi_office_bella_1100x600', id: 'bella'));
  testWidgets('bella 1366x640', (t) async => _shot(t, const Size(1366, 640), 'kpi_office_bella_1366x640', id: 'bella'));
  testWidgets('bella missed calls list', (t) async => _shot(t, const Size(1280, 720), 'kpi_office_bella_missed_list', id: 'bella', after: (t) async {
        await t.tap(find.text('View list'));
        for (var i = 0; i < 10; i++) {
          await t.pump(const Duration(milliseconds: 100));
        }
      }));
  testWidgets('bella no quo match', (t) async {
    final saved = _bellaOffice['missedCalls'];
    (_bellaOffice as Map).remove('missedCalls');
    addTearDown(() => (_bellaOffice as Map)['missedCalls'] = saved);
    await _shot(t, const Size(1280, 600), 'kpi_office_bella_nomissed', id: 'bella');
  });
  testWidgets('dennis 1500x720', (t) async => _shot(t, const Size(1500, 720), 'kpi_office_dennis_1500', id: 'dgray'));
  testWidgets('dennis 1280x600', (t) async => _shot(t, const Size(1280, 600), 'kpi_office_dennis_1280', id: 'dgray'));
  testWidgets('dennis 1000x700 narrow', (t) async => _shot(t, const Size(1000, 700), 'kpi_office_dennis_1000', id: 'dgray'));
  testWidgets('dennis old backend', (t) async => _shot(t, const Size(1500, 720), 'kpi_office_dennis_old', id: 'dgray', oldBackend: true));
}
