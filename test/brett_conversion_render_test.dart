// Renders Brett's (technician) KPI page with the Eval -> Package card -> test/shots/brett_kpi_*.png
// Run:  flutter test test/brett_conversion_render_test.dart --update-goldens

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

http.Response _handle(http.Request r, Map<String, dynamic>? conversion) {
  if (r.url.path.endsWith('/users') || r.url.path.endsWith('/admin/users')) {
    return http.Response(
      jsonEncode({
        'users': [
          {'id': 'brett', 'name': 'Brett Smith', 'role': 'Technician', 'integrity_score': 95.0, 'years_worked': 3.0, 'avatar_url': ''},
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
        'evalConversion': ?conversion,
      },
    }),
    200,
  );
}

Future<void> _shot(WidgetTester tester, Size size, String name, {Map<String, dynamic>? conversion, bool preview = false}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await http.runWithClient(() async {
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
        home: const EmployeeKpiScreen(employeeId: 'brett'),
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
    expect(tester.takeException(), isNull);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/$name.png'));
  }, () => MockClient((r) async => _handle(r, conversion)));
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

  testWidgets('brett with conversions 1500x720', (t) async => _shot(t, const Size(1500, 720), 'brett_kpi_conversion_1500', conversion: {'evals': 14, 'converted': 6}));
  testWidgets('brett no evals 1366x688', (t) async => _shot(t, const Size(1366, 688), 'brett_kpi_conversion_empty_1366', conversion: {'evals': 0, 'converted': 0}));
  testWidgets('brett short 1280x600', (t) async => _shot(t, const Size(1280, 600), 'brett_kpi_conversion_1280', conversion: {'evals': 14, 'converted': 6}));
  testWidgets('brett preview', (t) async => _shot(t, const Size(1500, 720), 'brett_kpi_conversion_preview', conversion: {'evals': 0, 'converted': 0}, preview: true));
  testWidgets('brett preview null', (t) async => _shot(t, const Size(1500, 720), 'brett_kpi_conversion_preview_null', preview: true));
}
