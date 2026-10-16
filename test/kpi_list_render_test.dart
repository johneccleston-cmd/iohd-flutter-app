// Renders the KPI list page (/hr/kpis) with the live /users shape -> test/shots/kpilist_*.png
// Run:  flutter test test/kpi_list_render_test.dart --update-goldens

import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
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

// Same columns, types and values the backend /users route returns today (integrityScore is hardcoded to 100,
// yearsWorked is a Postgres numeric, so it arrives as a string).
List<Map<String, dynamic>> _live() => [
      for (final u in const [
        ('AndrewJohnson', 'Andrew Johnson', 'Technician', '0.2203'),
        ('bhansberger', 'Bella Hansberger', 'Office', '2.3080'),
        ('bmiller', 'Brett Miller', 'Technician', '1.6208'),
        ('gbaty', 'Daniel Baty', 'Lead Technician', '2.6941'),
        ('dgray', 'Dennis Gray', 'warehouse', '2.3053'),
        ('hvera', 'Heather Vera', 'Office Manager', '4.1697'),
        ('jeccleston', 'John Eccleston', 'ADMIN', '1.1252'),
        ('nsmith', 'Nick Smith', 'Lead Technician', '2.3409'),
        ('zclemens', 'Zac Clemens', 'Sales Rep', '2.6064'),
      ])
        {'id': u.$1, 'name': u.$2, 'jobTitle': u.$3, 'avatarUrl': 'https://example.invalid/${u.$1}.jpg', 'integrityScore': 100, 'yearsWorked': u.$4},
    ];

Future<void> _shot(WidgetTester tester, Size size, String name,
    {List<Map<String, dynamic>>? users, int status = 200, Offset? hover}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await http.runWithClient(() async {
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
        home: const KPIDashboardScreen(),
      ),
    );
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    if (hover != null) {
      final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await g.addPointer(location: Offset.zero);
      await g.moveTo(hover);
      await tester.pump(const Duration(milliseconds: 300));
      await g.moveBy(const Offset(3, 0));
      await tester.pump(const Duration(milliseconds: 300));
    }
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/$name.png'));
  }, () => MockClient((r) async {
    if (r.url.path.endsWith('/users')) {
      return status == 200 ? http.Response(jsonEncode(users ?? _live()), 200) : http.Response('{"error":"x"}', status);
    }
    return http.Response('{}', 200);
  }));
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

  for (final s in const [
    (Size(1280, 600), 'kpilist_1280x600'),
    (Size(1366, 688), 'kpilist_1366x688'),
    (Size(1920, 940), 'kpilist_1920x940'),
    (Size(900, 700), 'kpilist_900x700'),
  ]) {
    testWidgets(s.$2, (tester) async => _shot(tester, s.$1, s.$2));
  }
  testWidgets('hover', (tester) async => _shot(tester, const Size(1366, 688), 'kpilist_hover', hover: const Offset(300, 400)));
  testWidgets('error', (tester) async => _shot(tester, const Size(1366, 688), 'kpilist_error', status: 500));
  testWidgets('session expired', (tester) async => _shot(tester, const Size(1366, 688), 'kpilist_401', status: 401));
  testWidgets('empty', (tester) async => _shot(tester, const Size(1366, 688), 'kpilist_empty', users: const []));
}
