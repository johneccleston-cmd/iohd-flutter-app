// Renders the Jobs dashboard with fake API data and saves screenshots to test/shots/.
// Run:  flutter test test/jobs_render_test.dart --update-goldens

import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/jobs_dashboard_screen.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    final bytes = File(p).readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

// Numbers are the live ones: 239 active jobs across 13 statuses; 1,506 completed jobs this year, none with categories.
Map<String, dynamic> _payload({bool coverage = true}) => {
      'success': true,
      'year': 2026,
      'scorecards': {'completedYtd': 1506, 'activeOpenJobs': 239, 'avgJobRevenue': 1597.0, 'newCustomersYtd': 412, 'avgProfitMargin': 38.2},
      'monthlyVolume': [
        for (final r in const [(1, 159, 104, 42), (2, 131, 75, 41), (3, 159, 102, 38), (4, 168, 122, 35), (5, 183, 127, 34), (6, 196, 137, 37), (7, 178, 114, 38), (8, 167, 107, 45), (9, 157, 108, 39), (10, 8, 4, 0)])
          {'month_num': r.$1, 'completed_count': r.$2, 'install_count': r.$3, 'service_count': r.$4},
      ],
      'monthlySplit': [
        for (var m = 1; m <= 10; m++) {'month_num': m, 'commercial_rev': 40000.0 + (m % 4) * 45000, 'residential_rev': 150000.0 + (m % 3) * 30000},
      ],
      'weeklySplit': [],
      'statusCounts': [
        {'status': 'Need To Schedule', 'count': 130},
        {'status': 'Scheduled - Full Day', 'count': 33},
        {'status': 'Complete', 'count': 21},
        {'status': 'Need Deposit', 'count': 13},
        {'status': 'Delayed', 'count': 12},
        {'status': 'Partially Complete', 'count': 11},
        {'status': 'Need To Sell', 'count': 9},
        {'status': 'Manage Project', 'count': 5},
        {'status': 'Appointment', 'count': 1},
        {'status': '14 Day Notice', 'count': 1},
        {'status': 'Check on Payment', 'count': 1},
        {'status': 'Need To Order', 'count': 1},
        {'status': 'Part Ordered', 'count': 1},
      ],
      'pipelineStages': [],
      if (coverage) 'splitCoverage': {'completedJobs': 1506, 'jobsWithCategories': 1349, 'jobsWithLineItems': 1446},
    };

http.Response _handle(http.Request r) {
  if (r.url.path.endsWith('/jobs/drill')) {
    final statuses = r.url.queryParametersAll['status'] ?? ['Need To Schedule'];
    final items = [
      for (var i = 0; i < 26; i++)
        {
          'jobId': '10980${i}2417',
          'customerName': ['Lennar Homes', 'Smith Residence', 'Pick-it Construction', 'JN3C Consulting'][i % 4],
          'status': statuses[i % statuses.length],
          'description': 'Replace 16x7 door and operator',
          'location': '123 Main St, Bentonville AR',
          'owner': i % 3 == 0 ? 'Brett Miller, Daniel Baty' : 'Bella Hansberger',
          'startDate': '2026-1${i % 3}-${(3 + i).clamp(1, 28).toString().padLeft(2, '0')}',
          'value': 900.0 + i * 235,
          'daysOld': i % 5 == 0 ? -(10 + i) : 30 + i * 9,
          'outcome': 'open',
        },
    ];
    return http.Response(jsonEncode({'success': true, 'count': items.length, 'totalValue': 70000, 'items': items}), 200);
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
        home: const JobsDashboardScreen(),
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
      await tester.pump(const Duration(milliseconds: 100));
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
    await _loadFont('Segoe UI', [r'C:\Windows\Fonts\segoeui.ttf', r'C:\Windows\Fonts\segoeuib.ttf', r'C:\Windows\Fonts\seguisb.ttf']);
    final root = Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter';
    await _loadFont('MaterialIcons', ['$root/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
    await _loadFont('Ahem', ['$root/bin/cache/artifacts/material_fonts/roboto-regular.ttf']);
  });

  testWidgets('jobs default', (t) async => _shot(t, const Size(1500, 800), 'jobs_default'));
  testWidgets('jobs hover slice', (t) async => _shot(t, const Size(1500, 800), 'jobs_hover', hoverText: 'Need To Schedule'));
  testWidgets('jobs install split view', (t) async => _shot(t, const Size(1500, 800), 'jobs_install_split', tapText: 'Install Split'));
  testWidgets('jobs slice click', (t) async => _shot(t, const Size(1500, 800), 'jobs_status_list', tapText: 'Need To Schedule'));
  testWidgets('jobs other click', (t) async => _shot(t, const Size(1500, 800), 'jobs_other_list', tapText: 'Other'));
}