// Renders Brett's (technician) KPI page with real-looking Google reviews -> test/shots/kpi_reviews_*.png
// Run:  flutter test test/kpi_reviews_render_test.dart --update-goldens

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

const _long =
    'We had excellent experience from the first call, to getting scheduled, to the quality of service with Brett. Brett was on time, explained exactly what was wrong with our springs, and had everything fixed in under an hour. He also showed us how to do basic maintenance so the springs and rollers last longer. Highly recommend Integrity Overhead Door to anyone.';

bool _veryLong = false;

List<Map<String, dynamic>> _reviews(int n) => [
      for (var i = 0; i < n; i++)
        {
          'quote': i == 0 ? (_veryLong ? '$_long $_long $_long' : _long) : (i % 3 == 1 ? 'Brett responded to my call very quickly. He arrived on time and quickly diagnosed the issue.' : 'Brett did a great job and taught me how I could do maintenance on it to help the springs and different things last longer in the future.'),
          'customer': ['Rachel F.', 'Richard M.', 'Jason S.'][i % 3],
          'source': 'Google · 5★',
          'date': ['2026-07-29T00:00:00Z', '2025-10-21T00:00:00Z', '2025-05-09T00:00:00Z'][i % 3],
        },
    ];

http.Response _handle(http.Request r, Map<String, dynamic>? conversion, int reviews) {
  if (r.url.path.endsWith('/users') || r.url.path.endsWith('/admin/users')) {
    return http.Response(
      jsonEncode({
        'users': [
          {'id': 'brett', 'name': 'Brett Smith', 'role': 'Technician', 'integrity_score': 95.0, 'years_worked': 3.0, 'avatar_url': ''},
          {'id': 'bella', 'name': 'Bella Hansberger', 'role': 'Office', 'integrity_score': 97.0, 'years_worked': 2.0, 'avatar_url': ''},
        ],
      }),
      200,
    );
  }
  if (r.url.path.endsWith('/tech_stats')) {
    return http.Response(
      jsonEncode({
        'techs': [
          {'id': 'brett', 'callbackCount': 1, 'completedJobsYtd': 120, 'jobsSinceCallback': 5},
          {'id': 'andrew', 'callbackCount': 2, 'completedJobsYtd': 80},
        ],
      }),
      200,
    );
  }
  if (r.url.path.contains('/bella/')) {
    return http.Response(
      jsonEncode({
        'employee': {'id': 9, 'role': 'Office', 'inventoryStrikes': 0, 'warehouseStrikes': 0},
        'office': {
          'outstanding': 238133,
          'over90': 22577,
          'collected': 2440000,
          'collectionRatePct': 91.2,
          'aging': [
            {'label': 'Final Invoice Sent', 'amount': 68400, 'jobs': 105},
            {'label': '14 Day Notice', 'amount': 44500, 'jobs': 30},
            {'label': '90 Day Notice', 'amount': 22577, 'jobs': 40},
          ],
          'tracking': {},
          'reviews': [
            {'quote': 'Bella responded the same morning that I left a message and set up an appointment for a technician to come out.', 'customer': 'Dana K.', 'source': 'Google · 5★', 'date': '2025-08-13T00:00:00Z'},
            {'quote': 'Bella was very helpful and able to have someone out to fix the problem the same day.', 'customer': 'Pat R.', 'source': 'Google · 5★', 'date': '2025-04-16T00:00:00Z'},
          ],
          'satisfaction': {'avg': 5.0, 'count': 2},
        },
      }),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }
  return http.Response(
    jsonEncode({
      'employee': {'id': 3, 'role': 'Technician', 'inventoryStrikes': 0, 'warehouseStrikes': 0},
      'tech': {
        'jobs': 120,
        'laborJobs': 100,
        'laborDollars': 52000,
        'laborPerDay': 480,
        'monthly': [for (var m = 1; m <= 10; m++) {'month': m, 'jobs': 12, 'labor': 5000, 'laborPerDay': 440 + m * 5}],
        'tracking': {},
        'reviews': _reviews(reviews),
        if (reviews > 0) 'satisfaction': {'avg': 5.0, 'count': 25},
        if (reviews > 0) 'satisfactionMonthly': [{'month': 7, 'avg': 5.0}],
        'evalConversion': ?conversion,
      },
    }),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

Future<void> _shot(WidgetTester tester, Size size, String name, {Map<String, dynamic>? conversion, bool preview = false, int reviews = 25, String? tapText, String id = 'brett', bool midStep = false, int waitSeconds = 0}) async {
  _veryLong = tapText != null;
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
    if (preview) {
      await tester.tap(find.text('Preview').first);
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
    for (var i = 0; i < waitSeconds * 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    if (midStep) {
      await tester.tap(find.byIcon(Icons.chevron_right_rounded).first);
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 200));
    }
    if (tapText != null) {
      await tester.tap(find.text(tapText).first);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
    final ex = tester.takeException();
    if (ex != null) debugPrint('EXCEPTION: $ex');
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/$name.png'));
  }, () => MockClient((r) async => _handle(r, conversion, reviews)));
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

  testWidgets('reviews 1500x720', (t) async => _shot(t, const Size(1500, 720), 'kpi_reviews_1500'));
  testWidgets('reviews 1366x688', (t) async => _shot(t, const Size(1366, 688), 'kpi_reviews_1366'));
  testWidgets('reviews 1280x600', (t) async => _shot(t, const Size(1280, 600), 'kpi_reviews_1280'));
  testWidgets('reviews 1920x940', (t) async => _shot(t, const Size(1920, 940), 'kpi_reviews_1920'));
  testWidgets('full review dialog 1280x600', (t) async => _shot(t, const Size(1280, 600), 'kpi_reviews_dialog', tapText: 'Read full review'));
  testWidgets('mid transition', (t) async => _shot(t, const Size(1500, 720), 'kpi_reviews_midstep', midStep: true));
  testWidgets('progress line', (t) async => _shot(t, const Size(1500, 720), 'kpi_reviews_progress', waitSeconds: 6));
  testWidgets('bella 1500x720', (t) async => _shot(t, const Size(1500, 720), 'kpi_reviews_bella', id: 'bella'));
  testWidgets('no reviews 1500x720', (t) async => _shot(t, const Size(1500, 720), 'kpi_reviews_none', reviews: 0));
}
