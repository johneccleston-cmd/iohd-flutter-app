// Renders real commission-detail reports (saved JSON) through the payroll screen and the PDF, for a visual check of
// live data. Skipped unless a folder is given; it reads report_<start>_<end>.json and runs.json from it and writes the
// PNGs and PDFs next to them. Keep that folder under build/ (gitignored): it holds real pay.
//
//   flutter test test/payroll_live_shots_test.dart --dart-define=PAYROLL_LIVE_DIR=build/payroll_audit/live

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/payroll_screen.dart';

const _dir = String.fromEnvironment('PAYROLL_LIVE_DIR');

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

void main() {
  if (_dir.isEmpty) {
    test('live payroll captures (pass --dart-define=PAYROLL_LIVE_DIR=<folder>)', () {}, skip: true);
    return;
  }
  autoUpdateGoldenFiles = true;
  final runs = File('$_dir/runs.json').readAsStringSync();
  final paidWeeks = {
    for (final r in (jsonDecode(runs)['runs'] as List))
      if (r['status'] == 'finalized') r['week_start'] as String,
  };
  String report(String start, String end) => File('$_dir/report_${start}_$end.json').readAsStringSync();

  setUpAll(() async {
    await _loadFont('Segoe UI', [r'C:\Windows\Fonts\segoeui.ttf', r'C:\Windows\Fonts\segoeuib.ttf', r'C:\Windows\Fonts\seguisb.ttf']);
    final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter';
    await _loadFont('MaterialIcons', ['$flutterRoot/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
  });

  Future<void> shot(WidgetTester t, String name, String start, String end,
      {Size size = const Size(1440, 900), String? tech, Future<void> Function(WidgetTester t)? steps}) async {
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = size;
    addTearDown(t.view.reset);
    final body = report(start, end);
    await http.runWithClient(
      () async {
        await t.pumpWidget(MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
          home: Scaffold(body: PayrollScreen(initialStart: start, initialEnd: end, initialTech: tech)),
        ));
        for (var i = 0; i < 14; i++) {
          await t.pump(const Duration(milliseconds: 120));
        }
        if (steps != null) await steps(t);
        expect(t.takeException(), isNull, reason: 'nothing may overflow');
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('../$_dir/$name.png'));
        await t.pumpWidget(const SizedBox());
      },
      () => MockClient((r) async {
        if (r.url.path.endsWith('/runs')) return http.Response(runs, 200);
        if (r.url.path.endsWith('/pending')) {
          return http.Response('{"success":true,"totals":{"share":0,"retainage":0,"net":0},"techs":[]}', 200);
        }
        return http.Response.bytes(utf8.encode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
      }),
    );
  }

  const w1 = ['2026-10-26', '2026-11-01'];
  const w2 = ['2026-11-02', '2026-11-08'];
  const all = ['2026-10-05', '2026-11-15'];
  testWidgets('register, week of Oct 26, 1366', (t) => shot(t, 'register_oct26_1366', w1[0], w1[1], size: const Size(1366, 768)));
  testWidgets('register, week of Oct 26, 1440', (t) => shot(t, 'register_oct26_1440', w1[0], w1[1]));
  testWidgets('register, week of Oct 26, 1920', (t) => shot(t, 'register_oct26_1920', w1[0], w1[1], size: const Size(1920, 1080)));
  testWidgets('register, week of Nov 2, 1440', (t) => shot(t, 'register_nov2_1440', w2[0], w2[1]));
  testWidgets('register, six weeks, 1440', (t) => shot(t, 'register_6wk_1440', all[0], all[1]));
  testWidgets('register, six weeks, 1280', (t) => shot(t, 'register_6wk_1280', all[0], all[1], size: const Size(1280, 720)));
  testWidgets('total due log, week of Oct 26', (t) => shot(t, 'log_total_oct26_1440', w1[0], w1[1], size: const Size(1440, 1100),
      steps: (t) async {
        await t.tap(find.text('Total Due').first);
        for (var i = 0; i < 6; i++) {
          await t.pump(const Duration(milliseconds: 120));
        }
      }));
  // One person per kind: sales commission on many jobs, retainage held, and the six-week view.
  for (final id in ['34', '35', '36']) {
    testWidgets('person $id, week of Oct 26', (t) => shot(t, 'person_${id}_oct26_1440', w1[0], w1[1], tech: id, size: const Size(1440, 1400)));
  }
  testWidgets('person 33, six weeks', (t) => shot(t, 'person_33_6wk_1440', all[0], all[1], tech: '33', size: const Size(1440, 1400)));

  for (final range in [w1, w2, all]) {
    test('pdf ${range[0]} to ${range[1]}', () async {
      final data = jsonDecode(report(range[0], range[1])) as Map<String, dynamic>;
      final weeks = <String>{
        for (final t in data['techs'] as List)
          for (final w in t['weeks'] as List) w['weekStart'] as String,
      };
      final bytes = await buildPayrollPdfForTest(
        data,
        generatedAt: DateTime(2026, 11, 16, 9, 0),
        generatedBy: 'Live data check',
        weekStatus: {
          for (final w in weeks) w: paidWeeks.contains(w) ? (label: 'Paid', paid: true) : (label: 'Not run yet', paid: false),
        },
      );
      File('$_dir/payroll_${range[0]}_${range[1]}.pdf').writeAsBytesSync(bytes);
    });
  }
}
