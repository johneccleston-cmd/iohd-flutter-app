// Renders the per-employee KPI page for Zac (sales rep) with fake API data -> test/shots/zac_kpi_*.png
// Run:  flutter test test/zac_kpi_render_test.dart --update-goldens

import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
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

http.Response _handle(http.Request r) {
  if (r.url.path.endsWith('/stale_estimates')) {
    return http.Response(
      jsonEncode({
        'success': true,
        'count': 3,
        'limits': {'requestedDays': 5, 'requestedHardBidDays': 14, 'providedDays': 14},
        'items': [
          {'jobId': '1096788101', 'customerName': 'DC Sparks Construction', 'category': 'Commercial Hard Bid', 'status': 'Estimate Provided', 'statusColor': '#5f0069', 'lastActivity': '2026-09-10', 'days': 27, 'allowedDays': 14},
          {'jobId': '1096788102', 'customerName': 'Cline Construction Group', 'category': 'Commercial Hard Bid', 'status': 'Estimate Provided', 'statusColor': '#5f0069', 'lastActivity': '2026-09-10', 'days': 27, 'allowedDays': 14},
          {'jobId': '1097001234', 'customerName': 'JBurr Construction', 'category': '', 'status': 'Estimate Requested', 'statusColor': '#eb36ff', 'lastActivity': '2026-10-01', 'days': 6, 'allowedDays': 5},
        ],
      }),
      200,
    );
  }
  if (r.url.path.endsWith('/late_estimates')) {
    return http.Response(
      jsonEncode({
        'success': true,
        'count': 3,
        'limits': {'turnaroundDays': 3, 'hardBidDays': 14},
        'items': [
          {'jobId': '1097413576', 'customerName': 'Southern Brothers Construction LLC', 'category': 'Commercial Hard Bid', 'created': '2026-09-17', 'provided': '2026-10-07', 'days': 20, 'allowedDays': 14},
          {'jobId': '1097603903', 'customerName': 'MacCo Builders', 'category': 'Commercial Hard Bid', 'created': '2026-09-18', 'provided': '2026-10-07', 'days': 19, 'allowedDays': 14},
          {'jobId': '1097841881', 'customerName': 'Steve Curtis', 'category': '', 'created': '2026-09-22', 'provided': '2026-09-29', 'days': 7, 'allowedDays': 3},
        ],
      }),
      200,
    );
  }
  if (r.url.path.endsWith('/users')) {
    return http.Response(
      jsonEncode({
        'users': [
          {'id': 'zac', 'name': 'Zac Clemens', 'role': 'Sales Rep', 'integrity_score': 96.0, 'years_worked': 1.4, 'avatar_url': ''},
          {'id': 'heather', 'name': 'Heather Vera', 'role': 'Office Manager', 'integrity_score': 98.0, 'years_worked': 4.0, 'avatar_url': ''},
          {'id': 'andrew', 'name': 'Andrew Johnson', 'role': 'Technician', 'integrity_score': 91.0, 'years_worked': 0.2, 'avatar_url': ''},
        ],
      }),
      200,
    );
  }
  if (r.url.path.endsWith('/dashboards/sales')) {
    return http.Response(
      jsonEncode({
        'people': [
          {'name': 'Heather Vera', 'monthlyWon': [31520, 84674, 77961, 87599, 79919, 38780, 87263, 53342, 137118, 24931, 0, 0]},
          {'name': 'Zac Clemens', 'monthlyWon': [0, 0, 0, 0, 0, 0, 33867, 0, 2926, 478, 0, 0]},
        ],
      }),
      200,
    );
  }
  if (r.url.path.contains('/heather/')) {
    // Heather: residential, no hard bids and nothing categorised.
    return http.Response(
      jsonEncode({
        'employee': {'id': 8, 'role': 'Office Manager', 'inventoryStrikes': 0, 'warehouseStrikes': 0},
        'sales': {
          'monthlyByType': {
            'hardBid': [for (var m = 0; m < 12; m++) {'revenue': 0, 'profit': 0}],
            'commercial': [for (var m = 0; m < 12; m++) {'revenue': 0, 'profit': 0}],
            'other': [for (var m = 0; m < 12; m++) {'revenue': const [31520, 84674, 77961, 87599, 79919, 38780, 87263, 53342, 137118, 24931, 0, 0][m], 'profit': const [13000, 36000, 33000, 37500, 34000, 16500, 37200, 22800, 58500, 10600, 0, 0][m]}],
          },
          'focus': 'Residential Sales',
          'turnaroundSince': '2026-09-10',
          'monthlyClose': [
            for (final wl in const [(11, 4), (26, 5), (23, 1), (16, 0), (21, 0), (17, 4), (16, 0), (17, 1), (18, 4), (12, 0), (0, 0), (0, 0)]) {'won': wl.$1, 'lost': wl.$2},
          ],
          'largestDeal': {'amount': 38608.12, 'customer': 'David and Molli Snell', 'date': '2026-09-25', 'jobId': '1095251088'},
          'pipeline': {
            'requested': {'count': 27, 'value': 11611.59},
            'provided': {'count': 222, 'value': 1510224.69},
            'staleValue': 1390000,
          },
          'wonCount': 129,
          'lostCount': 18,
          'closeRatePct': 87.8,
          'wonValue': 703112,
          'grossProfit': 301000,
          'markupPct': 75.0,
          'marginPct': 42.8,
          'profitCoverage': {'withProfit': 120},
          'turnaround': {'count': 80, 'avgDays': 1.9, 'medianDays': 1},
          'tracking': {},
          'strikes': {'staleEstimates': 232, 'agingEstimates': 4, 'openEstimates': 246, 'slowEstimates': 12},
          'byType': [
            {'type': 'Uncategorized', 'estimates': 147, 'wonCount': 129, 'wonValue': 703112, 'grossProfit': 301000, 'markupPct': 75.0},
          ],
        },
      }),
      200,
    );
  }
  return http.Response(
    jsonEncode({
      'employee': {'id': 7, 'role': 'Sales Rep', 'inventoryStrikes': 0, 'warehouseStrikes': 0},
      'sales': {
        'monthlyByType': {
          'hardBid': [for (var m = 0; m < 12; m++) {'revenue': const [0, 0, 0, 0, 0, 0, 24000, 0, 6100, 0, 0, 0][m], 'profit': const [0, 0, 0, 0, 0, 0, 9100, 0, 2700, 0, 0, 0][m]}],
          'commercial': [for (var m = 0; m < 12; m++) {'revenue': const [0, 0, 0, 0, 0, 0, 9867, 0, 2926, 478, 0, 0][m], 'profit': const [0, 0, 0, 0, 0, 0, 2400, 0, 1576, 381, 0, 0][m]}],
          'other': [for (var m = 0; m < 12; m++) {'revenue': 0, 'profit': 0}],
        },
        'focus': 'Commercial Sales',
        'largestDeal': {'amount': 24000, 'customer': 'Southern Brothers Construction LLC', 'date': '2026-07-14', 'jobId': '1097413576'},
        'pipeline': {
          'requested': {'count': 4, 'value': 48073.63},
          'provided': {'count': 24, 'value': 1185196.31},
          'staleValue': 351290.33,
        },
        'monthlyClose': [
          for (final wl in const [(0, 0), (0, 0), (0, 0), (0, 0), (0, 0), (0, 0), (2, 0), (0, 0), (1, 0), (1, 1), (0, 0), (0, 0)]) {'won': wl.$1, 'lost': wl.$2},
        ],
        'wonCount': 4,
        'lostCount': 0,
        'closeRatePct': 100,
        'wonValue': 37272,
        'grossProfit': 14210,
        'markupPct': 61.6,
        'marginPct': 38.1,
        'profitCoverage': {'withProfit': 3},
        'turnaround': {'count': 9, 'avgDays': 2.4, 'medianDays': 2},
        'bidTurnaround': {'count': 3, 'avgDays': 4.0, 'medianDays': 4},
        'bids': {'total': 6, 'wonCount': 2, 'lostCount': 0, 'openCount': 4, 'closeRatePct': 100},
        'tracking': {},
        'strikes': {'staleEstimates': 17, 'agingEstimates': 6, 'openEstimates': 28, 'slowEstimates': 3},
        'byType': [
          {'type': 'Commercial Hard Bid', 'estimates': 6, 'wonCount': 2, 'wonValue': 30120, 'grossProfit': 11800, 'markupPct': 64.0},
          {'type': 'Commercial Service', 'estimates': 14, 'wonCount': 2, 'wonValue': 7152, 'grossProfit': 2410, 'markupPct': 50.9},
          {'type': 'Uncategorized', 'estimates': 8, 'wonCount': 0, 'wonValue': 0, 'grossProfit': 0},
        ],
      },
    }),
    200,
  );
}

Future<void> _shot(WidgetTester tester, Size size, String name, {bool main = false, String id = 'zac', bool preview = false, bool hoverCards = false, String? tapText}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await http.runWithClient(() async {
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
        home: main ? const KPIDashboardScreen() : EmployeeKpiScreen(employeeId: id),
      ),
    );
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    if (hoverCards) {
      final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await g.addPointer(location: Offset.zero);
      await g.moveTo(const Offset(60, 258));
      await tester.pump(const Duration(milliseconds: 300));
      await g.moveBy(const Offset(3, 0));
      await tester.pump(const Duration(milliseconds: 300));
    }
    if (tapText != null) {
      await tester.tap(find.text(tapText).first);
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
    if (preview) {
      await tester.tap(find.text('Preview').first);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
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

  testWidgets('renders heather 1500x720', (tester) async => _shot(tester, const Size(1500, 720), 'heather_kpi_1500x720', id: 'heather'));
  testWidgets('renders heather 1366x688', (tester) async => _shot(tester, const Size(1366, 688), 'heather_kpi_1366x688', id: 'heather'));

  testWidgets('renders zac preview', (tester) async => _shot(tester, const Size(1500, 720), 'zac_kpi_preview', preview: true));

  testWidgets('renders zac hover', (tester) async => _shot(tester, const Size(1500, 720), 'zac_kpi_hover', hoverCards: true));

  testWidgets('late dialog', (tester) async => _shot(tester, const Size(1500, 720), 'zac_kpi_late', tapText: 'Late to send estimates'));

  testWidgets('stale dialog', (tester) async => _shot(tester, const Size(1500, 720), 'zac_kpi_stale', tapText: 'ESTIMATE PIPELINE'));

  testWidgets('type chart', (tester) async => _shot(tester, const Size(1500, 720), 'zac_kpi_typechart', tapText: 'Hard bids'));

  testWidgets('type chart 1366x688', (tester) async => _shot(tester, const Size(1366, 688), 'zac_kpi_typechart_1366', tapText: 'Hard bids'));

  testWidgets('chart steps to the next tab every 8 seconds, and holds under the cursor', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1500, 720);
    addTearDown(tester.view.reset);
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true), home: const EmployeeKpiScreen(employeeId: 'zac')));
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Revenue'), findsOneWidget); // tab 1, hard bids: the revenue and profit lines (legend)
      for (var i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 100)); // 11s in: past the first 8s tick, before the second
      }
      expect(find.text('Revenue'), findsOneWidget); // tab 2, commercial: still lines
      for (var i = 0; i < 70; i++) {
        await tester.pump(const Duration(milliseconds: 100)); // 18s in: past the second tick
      }
      expect(find.text('Revenue'), findsNothing); // tab 3, close rate: no revenue legend
      final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await g.addPointer(location: const Offset(800, 220));
      await g.moveTo(const Offset(820, 230));
      await tester.pump(const Duration(milliseconds: 100));
      for (var i = 0; i < 200; i++) {
        await tester.pump(const Duration(milliseconds: 100)); // 20s under the cursor: it must not move on to tab 1
      }
      expect(find.text('Revenue'), findsNothing);
    }, () => MockClient((r) async => _handle(r)));
  });

  testWidgets('chart tab labels show a pointer, not a text cursor', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1500, 720);
    addTearDown(tester.view.reset);
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true), home: const SelectionArea(child: EmployeeKpiScreen(employeeId: 'zac'))));
      for (var i = 0; i < 30; i++) { await tester.pump(const Duration(milliseconds: 100)); }
      final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await g.addPointer(location: Offset.zero);
      for (final label in const ['Hard bids', 'Close rate']) {
        await g.moveTo(tester.getCenter(find.text(label)));
        await tester.pump();
        expect(RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1), SystemMouseCursors.click, reason: label);
      }
      await g.moveTo(tester.getCenter(find.text('ESTIMATE PIPELINE')));
      await tester.pump();
      expect(RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1), SystemMouseCursors.click, reason: 'pipeline card');
    }, () => MockClient((r) async => _handle(r)));
  });

  testWidgets('heather close rate', (tester) async => _shot(tester, const Size(1500, 720), 'heather_kpi_closerate', id: 'heather', tapText: 'Close rate'));

  testWidgets('heather type chart', (tester) async => _shot(tester, const Size(1500, 720), 'heather_kpi_typechart', id: 'heather', tapText: 'Sales'));

  testWidgets('main kpi page', (tester) async => _shot(tester, const Size(1500, 720), 'kpi_main', main: true));

  for (final s in const [
    (Size(1280, 600), 'zac_kpi_1280x600'),
    (Size(1366, 688), 'zac_kpi_1366x688'),
    (Size(1500, 720), 'zac_kpi_1500x720'),
    (Size(1920, 940), 'zac_kpi_1920x940'),
  ]) {
    testWidgets('renders ${s.$2}', (tester) async => _shot(tester, s.$1, s.$2));
  }
}
