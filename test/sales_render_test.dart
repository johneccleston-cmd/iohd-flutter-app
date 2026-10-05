// Renders the real Sales dashboard with fake API data and saves screenshots to test/shots/.
// Run:  flutter test test/sales_render_test.dart --update-goldens
// Uses the machine's Segoe UI so text metrics match the Windows app.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/sales_dashboard_screen.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    final bytes = File(p).readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
  }
  await loader.load();
}

List<double> _months(List<double> v) => v;

Map<String, dynamic> _person(String name, String role, double won, int wonN, int sent, int lost, double largest, double winRate, List<double> monthly) => {
      'name': name,
      'role': role,
      'imageUrl': '',
      'wonValue': won,
      'wonCount': wonN,
      'sentCount': sent,
      'lostCount': lost,
      'largestDeal': largest,
      'winRate': winRate,
      'monthlyWon': monthly,
    };

Map<String, dynamic> _month(int m, double v, int n) => {'month_num': m, 'won_value': v, 'won_count': n, 'closed_count': n + 2, 'sent_count': n + 6};

final _heatherMonths = _months([31520, 84674, 77961, 87599, 79919, 38780, 87263, 53342, 137118, 24931, 0, 0]);
final _zacMonths = _months([0, 0, 0, 0, 0, 0, 33867, 0, 2926, 478, 0, 0]);

Map<String, dynamic> _payload() => {
      'success': true,
      'year': 2026,
      'summary': {
        'wonValue': 740385.0,
        'wonCount': 133,
        'winRate': 87.6,
        'largestDeal': 119076.0,
        'sentCount': 385,
        'priorWonValue': 1650000.0,
      },
      'doorTypes': [
        for (final d in const [
          ('Canyon Ridge', 16, 6, 0, 86724.0),
          ('Unspecified', 45, 25, 5, 55466.0),
          ('Modern Steel', 34, 13, 0, 41824.0),
          ('Bridgeport Steel', 25, 9, 0, 27451.0),
          ('Classic Steel', 52, 10, 3, 16761.0),
          ('Gallery Steel', 40, 11, 1, 13621.0),
          ('Avante', 9, 1, 0, 13290.0),
          ('Architectural Series', 6, 1, 0, 12567.0),
          ('Energy Series', 10, 1, 0, 9602.0),
          ('Industrial Series', 27, 5, 2, 6059.0),
          ('Rolling Doors', 7, 0, 0, 0.0),
        ])
          {'type': d.$1, 'sentCount': d.$2, 'wonCount': d.$3, 'lostCount': d.$4, 'winRate': 0, 'revenue': d.$5},
      ],
      'monthly': [for (var i = 0; i < 10; i++) _month(i + 1, _heatherMonths[i] + _zacMonths[i], 12)],
      'priorMonthly': [for (var i = 0; i < 12; i++) _month(i + 1, 100000.0 + (i % 5) * 60000, 25)],
      'people': [
        _person('Heather Vera', 'Residential Sales', 703112, 129, 357, 18, 38608, 87.8, _heatherMonths),
        _person('Zac Clemens', 'Commercial Sales', 37272, 4, 28, 0, 33867, 100, _zacMonths),
      ],
    };

http.Response _handle(http.Request r) {
  if (r.url.path.endsWith('/sales/door-estimates')) {
    final type = r.url.queryParameters['type'] ?? 'Classic Steel';
    final names = ['Robert Hufnagle', 'Pick-it Construction', 'Smith Residence', 'JN3C Consulting', 'Lennar Homes'];
    final items = [
      for (var i = 0; i < 22; i++)
        {
          'jobId': '10982${i}6084',
          'customerName': names[i % names.length],
          'status': i % 7 == 3 ? 'Lost - Competitor' : (i % 4 == 0 ? 'Estimate Provided' : 'Estimate Won'),
          'description': '',
          'location': '123 Main St, Bentonville AR',
          'startDate': '2026-09-${(28 - i).clamp(1, 28).toString().padLeft(2, '0')}',
          'value': 2400.0 + i * 410,
          'doorValue': 1000.0 + i * 130,
          'doorLines': [
            {'name': '1 x Clopay $type | T42S | Complete Door | Taxable', 'total': 700.0 + i * 90},
            if (i % 3 == 0) {'name': 'Clopay $type | 4050 | Complete Door', 'total': 300.0},
          ],
          'owner': i % 6 == 5 ? 'Zac Clemens' : 'Heather Vera',
          'outcome': i % 7 == 3 ? 'lost' : (i % 4 == 0 ? 'open' : 'won'),
        },
    ];
    return http.Response(jsonEncode({'success': true, 'count': items.length, 'totalValue': 30000, 'items': items}), 200);
  }  if (r.url.path.endsWith('/sales/estimates')) {
    final items = [
      for (var i = 0; i < 25; i++)
        {
          'jobId': '10981${i}000',
          'customerName': ['Robert Hufnagle', 'JN3C Consulting', 'Lennar Homes', 'Smith Residence'][i % 4],
          'status': i % 5 == 0 ? 'Lost - Competitor' : 'Estimate Won',
          'description': 'Total Techs Needed: 1\r\nHours On Site: 3 hr 30 min',
          'location': '123 Main St, Bentonville AR',
          'startDate': '2026-09-${(28 - i).clamp(1, 28).toString().padLeft(2, '0')}',
          'value': 1200.0 + i * 310,
          'outcome': i % 5 == 0 ? 'lost' : 'won',
        },
    ];
    return http.Response(jsonEncode({'success': true, 'count': items.length, 'totalValue': 50000, 'items': items}), 200);
  }
  return http.Response(jsonEncode(_payload()), 200);
}

Future<void> _shot(WidgetTester tester, Size size, String name, {String? tapText, bool afterCycle = false}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);

  await http.runWithClient(() async {
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
        home: const SalesDashboardScreen(),
      ),
    );
    // Let the (fake) request finish, then let the count-up / intro animations settle.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    if (afterCycle) {
      for (var i = 0; i < 90; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    if (tapText != null) {
      await tester.tap(find.text(tapText).first);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/$name.png'));
  }, () => MockClient((r) async => _handle(r)));
}

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', [
      r'C:\Windows\Fonts\segoeui.ttf',
      r'C:\Windows\Fonts\segoeuib.ttf',
      r'C:\Windows\Fonts\seguisb.ttf',
    ]);
    final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter';
    // The chart paints text with bare TextStyles (no theme), which fall back to this family.
    await _loadFont('Ahem', [
      '$flutterRoot/bin/cache/artifacts/material_fonts/roboto-regular.ttf',
    ]);
    await _loadFont('Roboto', [
      '$flutterRoot/bin/cache/artifacts/material_fonts/roboto-regular.ttf',
      '$flutterRoot/bin/cache/artifacts/material_fonts/roboto-medium.ttf',
      '$flutterRoot/bin/cache/artifacts/material_fonts/roboto-bold.ttf',
    ]);
    await _loadFont('MaterialIcons', ['$flutterRoot/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
  });

  for (final s in const [
    (Size(1280, 600), 'sales_1280x600'),
    (Size(1366, 700), 'sales_1366x700'),
    (Size(1500, 720), 'sales_1500x720'),
    (Size(1440, 800), 'sales_1440x800'),
    (Size(1600, 860), 'sales_1600x860'),
    (Size(1920, 940), 'sales_1920x940'),
  ]) {
    testWidgets('renders ${s.$2}', (tester) async => _shot(tester, s.$1, s.$2));
  }

  testWidgets('door chart after cycle', (tester) async => _shot(tester, const Size(1500, 800), 'sales_doors_revenue', afterCycle: true));

  testWidgets('drill-down dialog', (tester) async => _shot(tester, const Size(1500, 800), 'sales_drill', tapText: 'LOST'));

  testWidgets('door style click-through', (tester) async => _shot(tester, const Size(1500, 800), 'sales_door_drill', tapText: 'Classic Steel'));
}
