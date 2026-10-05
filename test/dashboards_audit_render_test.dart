// Renders the Financial, Commissions, Technicians and Inventory dashboards with REAL API responses
// (saved JSON files) and writes screenshots to test/shots/.
// Run:  flutter test test/dashboards_audit_render_test.dart --update-goldens
// The JSON files are read from AUDIT_DATA_DIR (an environment variable) and are not part of the repo.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/commission_dashboard_screen.dart';
import 'package:iohd_desktop/inventory_dashboard_screen.dart';
import 'package:iohd_desktop/reports_screen.dart';
import 'package:iohd_desktop/technicians_dashboard_screen.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    final bytes = File(p).readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

final _dataDir = Platform.environment['AUDIT_DATA_DIR'] ?? '';
String _json(String name) => File('$_dataDir/live_$name.json').readAsStringSync();

http.Response _handle(http.Request r) {
  final p = r.url.path;
  if (p.endsWith('/financial_dashboard')) return http.Response(_json('financial'), 200);
  if (p.endsWith('/commissions_stats')) return http.Response(_json('commissions'), 200);
  if (p.endsWith('/tech_stats')) return http.Response(_json('techs'), 200);
  if (p.endsWith('/dashboards/inventory')) return http.Response(_json('inventory'), 200);
  return http.Response('{}', 404);
}

Future<void> _shot(WidgetTester tester, Widget screen, Size size, String name) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);

  await http.runWithClient(() async {
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
        home: screen,
      ),
    );
    for (var i = 0; i < 45; i++) {
      await tester.pump(const Duration(milliseconds: 100));
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

  const sizes = [(Size(1500, 800), '1500x800'), (Size(1280, 640), '1280x640')];
  final screens = <(String, Widget)>[
    ('financial', const ReportsScreen()),
    ('commissions', const CommissionDashboardScreen()),
    ('techs', const TechniciansDashboardScreen()),
    ('inventory', const InventoryDashboardScreen()),
  ];
  for (final (name, screen) in screens) {
    for (final (size, label) in sizes) {
      testWidgets('$name $label', (t) async => _shot(t, screen, size, 'audit_${name}_$label'));
    }
  }
}
