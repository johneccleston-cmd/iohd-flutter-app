// Before/after captures for the payroll register and its PDF. Writes PNGs and PDFs to build/payroll_audit/<phase>/
// (gitignored); nothing under test/shots is touched. Skipped unless a phase is given:
//
//   flutter test test/payroll_audit_shots_test.dart --dart-define=PAYROLL_SHOTS=after
//
// Uses only the screen's public entry points, so the same file captures any version of the screen.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/payroll_screen.dart';

import 'payroll_fixture.dart';

const _phase = String.fromEnvironment('PAYROLL_SHOTS');

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

String _runs() => jsonEncode({
  'success': true,
  'runs': [
    {'id': 9, 'week_start': '2026-10-05', 'status': 'finalized', 'total_amount_paid': 2310.4, 'created_at': '2026-10-13T14:05:00Z'},
  ],
});

Future<void> _shot(
  WidgetTester t,
  String name,
  String body, {
  Size size = const Size(1440, 900),
  String start = '2026-10-12',
  String end = '2026-10-18',
  String? tech,
  Future<void> Function(WidgetTester t)? steps,
}) async {
  t.view.devicePixelRatio = 1.0;
  t.view.physicalSize = size;
  addTearDown(t.view.reset);
  await http.runWithClient(
    () async {
      await t.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
          home: Scaffold(body: PayrollScreen(initialStart: start, initialEnd: end, initialTech: tech)),
        ),
      );
      for (var i = 0; i < 14; i++) {
        await t.pump(const Duration(milliseconds: 120));
      }
      if (steps != null) await steps(t);
      final overflow = t.takeException();
      if (overflow != null) debugPrint('[$name] $overflow');
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('../build/payroll_audit/$_phase/$name.png'));
      await t.pumpWidget(const SizedBox());
    },
    () => MockClient((r) async {
      if (r.url.path.endsWith('/runs')) return http.Response(_runs(), 200);
      if (r.url.path.endsWith('/pending')) {
        return http.Response('{"success":true,"totals":{"share":0,"retainage":0,"net":0},"techs":[]}', 200);
      }
      return http.Response.bytes(utf8.encode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    }),
  );
}

void main() {
  if (_phase.isEmpty) {
    test('payroll audit captures (pass --dart-define=PAYROLL_SHOTS=before|after)', () {}, skip: true);
    return;
  }
  autoUpdateGoldenFiles = true;
  final edge = jsonEncode(payrollEdgeReport());
  final standard = payrollReport(DateTime(2026, 10, 18), 1);
  final crowd = jsonEncode(payrollCrowdReport(40));

  setUpAll(() async {
    await _loadFont('Segoe UI', [
      r'C:\Windows\Fonts\segoeui.ttf',
      r'C:\Windows\Fonts\segoeuib.ttf',
      r'C:\Windows\Fonts\seguisb.ttf',
    ]);
    final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter';
    await _loadFont('MaterialIcons', ['$flutterRoot/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
  });

  group('register', () {
    testWidgets('edge 1920', (t) => _shot(t, 'register_edge_1920', edge, size: const Size(1920, 1080)));
    testWidgets('edge 1440', (t) => _shot(t, 'register_edge_1440', edge));
    testWidgets('edge 1366', (t) => _shot(t, 'register_edge_1366', edge, size: const Size(1366, 768)));
    testWidgets('edge 1280', (t) => _shot(t, 'register_edge_1280', edge, size: const Size(1280, 800)));
    testWidgets('edge 1180', (t) => _shot(t, 'register_edge_1180', edge, size: const Size(1180, 900)));
    testWidgets('standard 1440', (t) => _shot(t, 'register_standard_1440', standard));
    testWidgets('crowd 40 1440', (t) => _shot(t, 'register_crowd40_1440', crowd, size: const Size(1440, 4200)));
  });

  group('person', () {
    testWidgets('carry recovered', (t) => _shot(t, 'person_carry_1440', edge, tech: '21', size: const Size(1440, 1300)));
    testWidgets('advance recovered', (t) => _shot(t, 'person_recovered_1440', edge, tech: '22', size: const Size(1440, 1300)));
    testWidgets('under hurdle, shortfall carried', (t) => _shot(t, 'person_under_1440', edge, tech: '23', size: const Size(1440, 1300)));
    testWidgets('negative total due', (t) => _shot(t, 'person_negative_1440', edge, tech: '27', size: const Size(1440, 1000)));
  });

  group('logs', () {
    testWidgets('total due log', (t) => _shot(t, 'log_total_due_1440', edge, size: const Size(1440, 1200), steps: (t) async {
      await t.tap(find.text('Total Due').first);
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 120));
      }
    }));
  });

  group('pdf', () {
    final out = Directory('build/payroll_audit/$_phase')..createSync(recursive: true);
    Future<void> pdf(String name, Map<String, dynamic> report) async {
      final watch = Stopwatch()..start();
      final bytes = await buildPayrollPdfForTest(
        report,
        generatedAt: DateTime(2026, 10, 21, 9, 30),
        generatedBy: 'Heather Vera',
        weekStatus: {'2026-10-12': (label: 'Not run yet', paid: false)},
      );
      File('${out.path}/$name.pdf').writeAsBytesSync(bytes);
      debugPrint('[pdf] $name: ${bytes.length} bytes in ${watch.elapsedMilliseconds} ms');
    }

    test('edge week', () => pdf('edge_one_week', payrollEdgeReport()));
    test('standard week', () => pdf('standard_one_week', jsonDecode(standard) as Map<String, dynamic>));
    test('crowd of 40', () => pdf('crowd_40', payrollCrowdReport(40)));
    test('year to date, 8 people x 45 weeks', () => pdf('ytd_8x45', payrollCrowdReport(8, weeks: 45, lastSunday: DateTime(2026, 11, 8))));
  });
}
