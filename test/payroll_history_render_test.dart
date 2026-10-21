// Renders the Payroll history dialog with fake API data and saves screenshots to test/shots/, then checks keyboard
// use (Escape closes, Tab + Enter opens a run).
// Run:  flutter test test/payroll_history_render_test.dart --update-goldens
//
// The run detail is shaped like GET /api/payroll/runs/:id in payroll_runs.js: lines with retainage_held, and
// company_pool { total, jobs[] } for the jobs that closed in that pay week.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/payroll_history_dialog.dart';

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
        {'id': 9, 'week_start': '2026-10-12', 'week_end': '2026-10-18', 'run_type': 'regular', 'status': 'finalized', 'run_by_name': 'Heather Vera', 'notes': 'Paid by direct deposit', 'total_amount_paid': 2310.4, 'created_at': '2026-10-20T14:05:00Z'},
        {'id': 8, 'week_start': '2026-10-05', 'week_end': '2026-10-11', 'run_type': 'adjustment', 'status': 'finalized', 'run_by_name': 'John Eccleston', 'total_amount_paid': 40, 'created_at': '2026-10-16T14:05:00Z'},
        {'id': 7, 'week_start': '2026-10-05', 'week_end': '2026-10-11', 'run_type': 'regular', 'status': 'voided', 'run_by_name': 'John Eccleston', 'voided_by_name': 'John Eccleston', 'void_reason': 'Ran before Dennis verified his days.', 'total_amount_paid': 1500, 'created_at': '2026-10-13T14:05:00Z'},
        {'id': 6, 'week_start': '2026-09-28', 'week_end': '2026-10-04', 'run_type': 'regular', 'status': 'finalized', 'run_by_name': 'John Eccleston', 'total_amount_paid': 1413.66, 'created_at': '2026-10-06T14:05:00Z'},
      ],
    });

/// A full page from the server: the newest 200 runs, one a week going back.
String _manyRuns() => jsonEncode({
      'success': true,
      'runs': [
        for (var i = 0; i < 200; i++)
          {
            'id': 400 - i,
            'week_start': _ymd(DateTime(2026, 10, 12).subtract(Duration(days: 7 * i))),
            'run_type': 'regular',
            'status': 'finalized',
            'run_by_name': i.isEven ? 'Heather Vera' : 'John Eccleston',
            'total_amount_paid': 2000 + (i * 37) % 900,
            'created_at': '2026-10-20T14:05:00Z',
          },
      ],
    });

String _ymd(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String _run() => jsonEncode({
      'success': true,
      'run': {'id': 9},
      'lines': [
        {'tech_name': 'Brett Miller', 'weekly_gross': 1014.42, 'retainage_held': 8.65, 'payable': 264.42, 'previously_paid': 0, 'carry_recovered': 0, 'amount_paid': 264.42},
        {'tech_name': 'Christopher Montgomery-Alexander', 'weekly_gross': 1478.73, 'retainage_held': 0, 'payable': 728.73, 'previously_paid': 0, 'carry_recovered': 0, 'amount_paid': 728.73},
        {'tech_name': 'Nick Smith', 'weekly_gross': 1425.93, 'retainage_held': 42.1, 'payable': 675.93, 'previously_paid': 0, 'carry_recovered': 0, 'amount_paid': 675.93},
        {'tech_name': 'Zac Clemens', 'weekly_gross': 641.32, 'retainage_held': 0, 'payable': 641.32, 'previously_paid': 0, 'carry_recovered': 0, 'amount_paid': 641.32},
      ],
      'company_pool': {
        'total': 31.62,
        'jobs': [
          {'job_id': '1095800001', 'customer': 'Lennar Homes - Cypress Creek Ranch Phase 4', 'amount': 8.43},
          {'job_id': '1095800002', 'customer': 'Trulove Construction', 'amount': 11.41},
          {'job_id': '1095800003', 'customer': 'Robert & Linda Fitzgerald-Harrington', 'amount': 11.78},
        ],
      },
    });

http.Client _server(String mode) => MockClient((r) async {
      if (mode == 'error') return http.Response(jsonEncode({'success': false, 'error': 'Payroll history failed.'}), 500);
      if (mode == 'forbidden') return http.Response(jsonEncode({'success': false, 'error': 'Admin only'}), 403);
      if (mode == 'empty') return http.Response(jsonEncode({'success': true, 'runs': []}), 200);
      if (mode == 'hold') await Future<void>.delayed(const Duration(seconds: 30));
      if (RegExp(r'/runs/\d+$').hasMatch(r.url.path)) return http.Response(_run(), 200);
      if (mode == 'capped') return http.Response(_manyRuns(), 200);
      return http.Response(_runs(), 200);
    });

Widget _host() => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
      home: Builder(
        builder: (c) => Scaffold(
          backgroundColor: const Color(0xFFF1F5F9),
          body: Center(
            child: FilledButton(onPressed: () => showPayrollHistoryDialog(c), child: const Text('open')),
          ),
        ),
      ),
    );

Future<void> _pumpN(WidgetTester t, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _shot(
  WidgetTester tester,
  String name, {
  String mode = 'list',
  String? open,
  Size size = const Size(1100, 760),
  bool scrollToEnd = false,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await http.runWithClient(() async {
    await tester.pumpWidget(_host());
    await tester.tap(find.text('open'));
    await _pumpN(tester);
    if (open != null) {
      await tester.tap(find.text(open));
      await _pumpN(tester);
    }
    if (scrollToEnd) {
      await tester.drag(find.byType(ListView), const Offset(0, -40000));
      await _pumpN(tester);
    }
    expect(tester.takeException(), isNull, reason: 'no overflow or other framework error');
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/$name.png'));
    // Let a held-back response arrive after the dialog is gone, so no timer is left running.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 61));
  }, () => _server(mode));
}

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', [r'C:\Windows\Fonts\segoeui.ttf', r'C:\Windows\Fonts\segoeuib.ttf', r'C:\Windows\Fonts\seguisb.ttf']);
    final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter';
    await _loadFont('MaterialIcons', ['$flutterRoot/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
  });

  testWidgets('list', (t) async => _shot(t, 'payroll_history_list'));
  testWidgets('one run open', (t) async => _shot(t, 'payroll_history_open', open: '#9'));
  testWidgets('voided run open', (t) async => _shot(t, 'payroll_history_voided', open: '#7'));
  testWidgets('empty', (t) async => _shot(t, 'payroll_history_empty', mode: 'empty'));
  testWidgets('loading', (t) async => _shot(t, 'payroll_history_loading', mode: 'hold'));
  testWidgets('phone width, run open', (t) async {
    await _shot(t, 'payroll_history_phone', open: '#9', size: const Size(420, 900));
  });
  testWidgets('a short history sizes the dialog to its runs', (t) async {
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1100, 760);
    addTearDown(t.view.reset);
    await http.runWithClient(() async {
      await t.pumpWidget(_host());
      await t.tap(find.text('open'));
      await _pumpN(t);
      // The dialog's own surface; the Dialog widget itself fills the screen to centre it.
      final dialog = t.getSize(find.descendant(of: find.byType(Dialog), matching: find.byType(Material)).first);
      expect(dialog.height, lessThan(520), reason: 'four runs should not fill a 760 px tall box');
    }, () => _server('list'));
  });
  testWidgets('error', (t) async => _shot(t, 'payroll_history_error', mode: 'error'));
  testWidgets('no access', (t) async => _shot(t, 'payroll_history_forbidden', mode: 'forbidden'));
  testWidgets('a full page of 200 runs says older ones are not listed', (t) async {
    await _shot(t, 'payroll_history_capped', mode: 'capped', scrollToEnd: true);
  });
  testWidgets('narrow window, run open', (t) async {
    await _shot(t, 'payroll_history_narrow', open: '#9', size: const Size(720, 760));
  });

  testWidgets('403 offers no retry; a full page shows the not-listed note; a short list does not', (t) async {
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1100, 760);
    addTearDown(t.view.reset);
    for (final (mode, retry, note) in [('forbidden', false, false), ('error', true, false), ('capped', false, true), ('list', false, false)]) {
      await http.runWithClient(() async {
        await t.pumpWidget(_host());
        await t.tap(find.text('open'));
        await _pumpN(t);
        expect(find.text('Try again'), retry ? findsOneWidget : findsNothing, reason: mode);
        expect(find.textContaining('200 most recent runs'), note ? findsOneWidget : findsNothing, reason: mode);
        await t.pumpWidget(const SizedBox());
      }, () => _server(mode));
    }
  });

  testWidgets('keyboard: Tab + Enter opens a run, Escape closes the dialog', (t) async {
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1100, 760);
    addTearDown(t.view.reset);
    await http.runWithClient(() async {
      await t.pumpWidget(_host());
      await t.tap(find.text('open'));
      await _pumpN(t);
      expect(find.text('Paid in this run'), findsNothing);
      // Close button first, then the first run.
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await _pumpN(t);
      expect(find.text('Paid in this run'), findsOneWidget, reason: 'Enter on the focused run opens it');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await _pumpN(t);
      expect(find.text('Payroll history'), findsNothing, reason: 'Escape closes the dialog');
    }, () => _server('list'));
  });
}
