// Renders the Estimates dashboard with fake API data and saves screenshots to test/shots/.
// Run:  flutter test test/estimates_render_test.dart --update-goldens
// Same approach as sales_render_test.dart (real Segoe UI, http MockClient via runWithClient).

import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/estimates_dashboard_screen.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    final bytes = File(p).readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

Map<String, dynamic> _payload() => {
      'success': true,
      'year': 2026,
      'scorecards': {'openValue': 6743267.0, 'lostValue': 246922.0, 'winRate': 87.6, 'sentYtd': 385},
      'stalePipeline': [
        for (var i = 0; i < 6; i++)
          {'job_id': '10${i}1', 'customer_name': 'Stale Customer $i', 'value': 4000.0 + i * 900, 'days_old': 40 + i * 9},
      ],
      'agingBuckets': [
        {'bucket': '0-7 days', 'count': 17, 'value': 202797.0},
        {'bucket': '8-14 days', 'count': 10, 'value': 241384.0},
        {'bucket': '15-30 days', 'count': 31, 'value': 433864.0},
        {'bucket': '31+ days', 'count': 290, 'value': 5865223.0},
      ],
      'history': {'openValue': [for (var i = 0; i < 30; i++) 6000000.0 + i * 25000 + (i % 5) * 40000]},
      'monthlyValue': [
        for (var m = 1; m <= 10; m++)
          {'month_num': m, 'sent_value': 300000.0 + m * 20000, 'won_value': 120000.0 + m * 9000, 'sent_count': 30 + m, 'won_count': 12 + m ~/ 2, 'lost_value': 15000.0 + (m % 4) * 12000},
      ],
      'lostReasons': [
        {'reason': 'Other', 'lost_value': 241962.0, 'count': 31},
        {'reason': 'Competitor', 'lost_value': 4960.0, 'count': 1},
        {'reason': 'Price', 'lost_value': 0.0, 'count': 0},
        {'reason': 'Unresponsive', 'lost_value': 0.0, 'count': 0},
        {'reason': 'Timing', 'lost_value': 0.0, 'count': 0},
      ],
    };

http.Response _handle(http.Request r) {
  if (r.url.path.endsWith('/estimates/drill')) {
    final aging = r.url.queryParameters['kind'] == 'aging';
    final items = [
      for (var i = 0; i < 24; i++)
        {
          'jobId': '10970${i}4417',
          'customerName': ['Pick-it Construction', 'Smith Residence', 'JN3C Consulting', 'Lennar Homes'][i % 4],
          'status': aging ? (i % 3 == 0 ? 'Estimate Follow Up' : 'Estimate Provided') : 'Lost',
          'description': 'Total Techs Needed: 1',
          'location': '123 Main St, Bentonville AR',
          'owner': i % 5 == 0 ? 'Zac Clemens' : (i % 5 == 1 ? 'Ryan Schwartz' : 'Heather Vera'),
          'startDate': '2026-0${1 + i % 8}-${(3 + i).clamp(1, 28).toString().padLeft(2, '0')}',
          'value': 2400.0 + i * 610,
          'daysOld': 31 + i * 7,
          'outcome': aging ? 'open' : 'lost',
        },
    ];
    return http.Response(jsonEncode({'success': true, 'count': items.length, 'totalValue': 90000, 'items': items}), 200);
  }
  return http.Response(jsonEncode(_payload()), 200);
}

Future<void> _shot(WidgetTester tester, Size size, String name, {String? hoverText, String? tapText}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);

  await http.runWithClient(() async {
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
        home: const EstimatesDashboardScreen(),
      ),
    );
    for (var i = 0; i < 45; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    if (hoverText != null) {
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.text(hoverText).first));
      await tester.pump(const Duration(milliseconds: 300));
    }

    if (tapText != null) {
      await tester.tap(find.text(tapText).first);
      for (var i = 0; i < 12; i++) {
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
    final root = Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter';
    await _loadFont('MaterialIcons', ['$root/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
    await _loadFont('Ahem', ['$root/bin/cache/artifacts/material_fonts/roboto-regular.ttf']);
  });

  testWidgets('estimates default', (t) async => _shot(t, const Size(1500, 800), 'estimates_default'));
  testWidgets('estimates hover aging bar', (t) async => _shot(t, const Size(1500, 800), 'estimates_hover_aging', hoverText: '31+ days'));
  testWidgets('estimates hover lost reason', (t) async => _shot(t, const Size(1500, 800), 'estimates_hover_lost', hoverText: 'Other'));
  testWidgets('estimates aging click', (t) async => _shot(t, const Size(1500, 800), 'estimates_aging_list', tapText: '31+ days'));
  testWidgets('estimates lost click', (t) async => _shot(t, const Size(1500, 800), 'estimates_lost_list', tapText: 'Other'));
}
