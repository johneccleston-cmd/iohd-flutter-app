// Renders the Run payroll dialog with fake API data and saves screenshots to test/shots/.
// Run:  flutter test test/payroll_run_render_test.dart --update-goldens

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/payroll_run_dialog.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

Map<String, dynamic> _line(String name, double gross, double payable, {double before = 0, double recovered = 0, bool sales = false}) => {
      'tech_name': name,
      'is_sales': sales,
      'weekly_gross': gross,
      'hurdle': sales ? 0 : 750,
      'payable': payable,
      'previously_paid': before,
      'carry_recovered': recovered,
      'amount_paid': payable - before - recovered,
    };

String _preview({required bool over, required bool prior}) {
  final lines = [
    _line('Andrew Johnson', 1480.5, 730.5, before: prior ? 600 : 0),
    _line('Brett Miller', 920, 170, before: prior ? 170 : 0),
    _line('Daniel Baty', 1210.4, 460.4, recovered: 60),
    _line('Nick Smith', 400, 0),
  ];
  double sum(String k) => lines.fold(0.0, (s, l) => s + (l[k] as num));
  return jsonEncode({
    'success': true,
    'week': {'start': '2026-10-05', 'end': '2026-10-11'},
    'lines': lines,
    'totals': {'payable': sum('payable'), 'previously_paid': sum('previously_paid'), 'amount_paid': sum('amount_paid')},
    'has_prior_runs': prior,
    'week_is_over': over,
  });
}

String _runs(bool prior) => jsonEncode({
      'success': true,
      'runs': prior
          ? [
              {'id': 7, 'week_start': '2026-10-05', 'run_type': 'regular', 'status': 'finalized', 'run_by_name': 'John Eccleston', 'notes': 'First pass', 'total_amount_paid': 770, 'created_at': '2026-10-12T14:05:00Z'},
              {'id': 6, 'week_start': '2026-09-28', 'run_type': 'regular', 'status': 'finalized', 'run_by_name': 'John Eccleston', 'total_amount_paid': 100, 'created_at': '2026-10-05T14:05:00Z'},
            ]
          : [],
    });

Future<void> _shot(WidgetTester tester, String name, {bool over = true, bool prior = false, bool fail = false}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1100, 760);
  addTearDown(tester.view.reset);
  await http.runWithClient(() async {
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
      home: Builder(
        builder: (c) => Scaffold(
          backgroundColor: const Color(0xFFF1F5F9),
          body: Center(
            child: FilledButton(
              onPressed: () => showPayrollRunDialog(c, initialDate: DateTime(2026, 10, 7)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/$name.png'));
  }, () => MockClient((r) async {
    if (fail) return http.Response(jsonEncode({'success': false, 'error': 'Payroll preview failed.'}), 500);
    if (r.url.path.endsWith('/preview')) return http.Response(_preview(over: over, prior: prior), 200);
    return http.Response(_runs(prior), 200);
  }));
}

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', [r'C:\Windows\Fonts\segoeui.ttf', r'C:\Windows\Fonts\segoeuib.ttf', r'C:\Windows\Fonts\seguisb.ttf']);
    final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter';
    await _loadFont('MaterialIcons', ['$flutterRoot/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
  });

  testWidgets('ready to run', (t) async => _shot(t, 'payroll_run_ready'));
  testWidgets('adjustment with history', (t) async => _shot(t, 'payroll_run_adjust', prior: true));
  testWidgets('week not over', (t) async => _shot(t, 'payroll_run_open', over: false));
  testWidgets('error', (t) async => _shot(t, 'payroll_run_error', fail: true));
}
