// Renders the main Payroll screen (register, one person, scorecard logs, loading/error/empty states) with fake API
// data at several window sizes and saves screenshots to test/shots/payroll_screen_*.png.
// Run:  flutter test test/payroll_screen_render_test.dart --update-goldens
//
// The data comes from payroll_fixture.dart. A RenderFlex overflow or any other framework error fails the test, so it
// doubles as an overflow check.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/payroll_screen.dart';
import 'package:iohd_desktop/widgets/dashboard_kit.dart';

import 'payroll_fixture.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

final _lastSunday = DateTime(2026, 10, 18);
final _oneWeek = payrollReport(_lastSunday, 1);
final _elevenWeeks = payrollReport(_lastSunday, 11);

String _runs() => jsonEncode({
  'success': true,
  'runs': [
    {
      'id': 9,
      'week_start': '2026-10-05',
      'status': 'finalized',
      'total_amount_paid': 2310.4,
      'created_at': '2026-10-13T14:05:00Z',
    },
  ],
});

const _emptyPending =
    '{"success":true,"totals":{"share":0,"retainage":0,"net":0},"counts":{"techs":0,"jobs":0},"techs":[]}';

Future<void> _pumpN(WidgetTester t, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 120));
  }
}

Widget _app({
  String start = '2026-10-12',
  String end = '2026-10-18',
  String? tech,
  double textScale = 1,
  bool reduceMotion = false,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale), disableAnimations: reduceMotion),
      child: Scaffold(
        body: PayrollScreen(initialStart: start, initialEnd: end, initialTech: tech),
      ),
    ),
  ),
);

/// The fake backend: [body] (or one pay week) for the report, no pending jobs, one finalized run. [gate] holds the
/// report back until it completes; [seen] collects every request.
http.Client _server({String? body, int status = 200, Future<void>? gate, List<Uri>? seen, String? runs}) =>
    MockClient((r) async {
      seen?.add(r.url);
      if (r.url.path.endsWith('/runs')) return http.Response(runs ?? _runs(), 200);
      if (r.url.path.endsWith('/pending')) return http.Response(_emptyPending, 200);
      if (gate != null) await gate;
      return http.Response(body ?? _oneWeek, status);
    });

/// Mounts the screen at [size], lets the first load finish and runs [body]; for tests that check behaviour rather
/// than take a picture.
Future<void> _withScreen(
  WidgetTester t,
  Future<void> Function() body, {
  Size size = const Size(1700, 1000),
  String? report,
  int status = 200,
  String start = '2026-10-12',
  String? tech,
  double textScale = 1,
  bool reduceMotion = false,
  List<Uri>? seen,
  String? runs,
}) async {
  t.view.devicePixelRatio = 1.0;
  t.view.physicalSize = size;
  addTearDown(t.view.reset);
  await http.runWithClient(() async {
    await t.pumpWidget(_app(start: start, tech: tech, textScale: textScale, reduceMotion: reduceMotion));
    await _pumpN(t, 12);
    await body();
    await t.pumpWidget(const SizedBox());
  }, () => _server(body: report, status: status, seen: seen, runs: runs));
}

/// Pumps the screen at [size] and saves `shots/payroll_screen_<name>.png`. [steps] runs after the first load.
Future<void> _shot(
  WidgetTester tester,
  String name, {
  Size size = const Size(1440, 900),
  String? body,
  int status = 200,
  String start = '2026-10-12',
  String end = '2026-10-18',
  String? tech,
  double textScale = 1,
  bool hold = false,
  Future<void> Function(WidgetTester t)? steps,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  final gate = Completer<void>();
  await http.runWithClient(() async {
    await tester.pumpWidget(_app(start: start, end: end, tech: tech, textScale: textScale));
    await _pumpN(tester, hold ? 3 : 12);
    if (steps != null) await steps(tester);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/payroll_screen_$name.png'));
    if (!gate.isCompleted) gate.complete();
    await _pumpN(tester, 3);
  }, () => _server(body: body, status: status, gate: hold ? gate.future : null));
  // Unmount before the framework checks for pending timers (entrance animations, the slow-server hint).
  await tester.pumpWidget(const SizedBox());
}

Future<void> _tapText(WidgetTester t, String text) async {
  final f = find.text(text).first;
  await t.ensureVisible(f);
  await t.pump();
  await t.tap(f);
  await _pumpN(t, 8);
}

void main() {
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
    testWidgets('1920', (t) => _shot(t, 'register_1920', size: const Size(1920, 1000)));
    testWidgets('1440', (t) => _shot(t, 'register_1440'));
    testWidgets('1280x720', (t) => _shot(t, 'register_1280', size: const Size(1280, 720)));
    testWidgets('1024', (t) => _shot(t, 'register_1024', size: const Size(1024, 768)));
    testWidgets('800', (t) => _shot(t, 'register_800', size: const Size(800, 1000)));
    testWidgets('390 phone', (t) => _shot(t, 'register_390', size: const Size(390, 1100)));
    testWidgets('text 1.3', (t) => _shot(t, 'register_text130', size: const Size(1440, 900), textScale: 1.3));
    testWidgets(
      'sorted by due',
      (t) => _shot(
        t,
        'register_sorted',
        steps: (t) async {
          await t.tap(find.byTooltip('Sort by amount due, highest first'));
          await _pumpN(t, 4);
        },
      ),
    );
  });

  group('person', () {
    testWidgets(
      'one week, job open',
      (t) => _shot(
        t,
        'person_week',
        size: const Size(1440, 1300),
        tech: '12',
        steps: (t) async {
          final job = find.textContaining('Job 10958', findRichText: true).first;
          await t.tap(job);
          await _pumpN(t, 6);
        },
      ),
    );
    testWidgets(
      'under hurdle with shortfall',
      (t) => _shot(t, 'person_under', size: const Size(1440, 1100), tech: '11'),
    );
    testWidgets('sales rep', (t) => _shot(t, 'person_sales', size: const Size(1440, 1100), tech: '36'));
    testWidgets(
      'eleven weeks',
      (t) =>
          _shot(t, 'person_weeks', size: const Size(1440, 1300), tech: '14', body: _elevenWeeks, start: '2026-08-03'),
    );
    testWidgets('one week at 800', (t) => _shot(t, 'person_800', size: const Size(800, 1300), tech: '12'));
    testWidgets(
      'phone width, big text',
      (t) => _shot(t, 'person_360_text130', size: const Size(360, 1600), tech: '13', textScale: 1.3),
    );
  });

  group('logs', () {
    testWidgets(
      'total due, everyone',
      (t) => _shot(t, 'log_total', size: const Size(1440, 1100), steps: (t) => _tapText(t, 'Total Due')),
    );
    testWidgets(
      'commission log at 800',
      (t) => _shot(t, 'log_800', size: const Size(800, 1100), steps: (t) => _tapText(t, 'Closed-Job Commission')),
    );
  });

  group('states', () {
    testWidgets('first load', (t) => _shot(t, 'loading', hold: true));
    testWidgets(
      'first load, slow server',
      (t) => _shot(t, 'loading_slow', hold: true, steps: (t) => t.pump(const Duration(seconds: 9))),
    );
    testWidgets(
      'no access',
      (t) => _shot(t, 'forbidden', status: 403, body: '{"success":false,"error":"Admin access required"}'),
    );
    testWidgets(
      'error',
      (t) => _shot(
        t,
        'error',
        status: 500,
        body: '{"success":false,"error":"Failed to generate the commission detail report."}',
      ),
    );
    testWidgets(
      'empty',
      (t) => _shot(
        t,
        'empty',
        body: jsonEncode({
          'success': true,
          'range': {'start': '2026-10-12', 'end': '2026-10-18'},
          'rules': {},
          'techs': [],
        }),
      ),
    );
  });

  group('behaviour', () {
    testWidgets('register totals equal the report summed column by column', (t) async {
      // Summed here straight from the JSON the server sent, so a change in how the screen adds things up shows.
      final techs = ((jsonDecode(_oneWeek) as Map)['techs'] as List).cast<Map<String, dynamic>>();
      double tot(String k) => techs.fold(0.0, (s, x) => s + ((x['totals'] as Map)[k] as num).toDouble());
      double weeks(String k) => techs.fold(
        0.0,
        (s, x) => s + (x['weeks'] as List).fold(0.0, (a, w) => a + (((w as Map)[k] as num?) ?? 0).toDouble()),
      );
      final jobs = techs.fold<int>(
        0,
        (n, x) => n + (x['weeks'] as List).fold<int>(0, (a, w) => a + ((w as Map)['jobs'] as List).length),
      );
      final expected = [
        '$jobs',
        dashMoney(weeks('jobNet')),
        dashMoney(tot('advancesPaid')),
        dashMoney(tot('callbackPay')),
        dashMoney(weeks('repPay')),
        dashMoney(tot('weeklyGross')),
        dashMoney(tot('cashPay')),
        dashMoney(tot('retainageReleased')),
        dashMoney(tot('totalDue')),
      ];
      await _withScreen(t, () async {
        await _pumpN(t, 10); // let the scorecards finish counting up
        final y = t.getCenter(find.text('Total')).dy;
        for (final e in expected) {
          final onTotalRow = find.text(e).evaluate().where((el) {
            final box = el.renderObject! as RenderBox;
            return (box.localToGlobal(box.size.center(Offset.zero)).dy - y).abs() < 3;
          });
          expect(onTotalRow, isNotEmpty, reason: 'the Total row should show $e');
        }
        expect(find.text(dashMoney(tot('totalDue'))), findsNWidgets(2), reason: 'Total Due card = register total');
      });
    });

    testWidgets('keyboard only: Tab reaches a scorecard and Enter opens its log', (t) async {
      final semantics = t.ensureSemantics();
      await _withScreen(t, () async {
        final card = find.bySemanticsLabel(RegExp(r'^Total Due, \$'));
        expect(card, findsOneWidget);
        var reached = false;
        for (var i = 0; i < 60 && !reached; i++) {
          await t.sendKeyEvent(LogicalKeyboardKey.tab);
          await t.pump();
          reached = isSemantics(isFocused: true).matches(t.getSemantics(card), {});
        }
        expect(reached, isTrue, reason: 'Tab never reached the Total Due card');
        await t.sendKeyEvent(LogicalKeyboardKey.enter);
        await _pumpN(t, 4);
        expect(find.textContaining('Weekly cash pay and retainage released'), findsOneWidget);
      });
      semantics.dispose();
    });

    testWidgets('keyboard only: Tab reaches a range pill and Space picks it', (t) async {
      final semantics = t.ensureSemantics();
      final seen = <Uri>[];
      await _withScreen(t, seen: seen, () async {
        final pill = find.bySemanticsLabel('Last Month');
        var reached = false;
        for (var i = 0; i < 60 && !reached; i++) {
          await t.sendKeyEvent(LogicalKeyboardKey.tab);
          await t.pump();
          reached = isSemantics(isFocused: true).matches(t.getSemantics(pill), {});
        }
        expect(reached, isTrue, reason: 'Tab never reached the Last Month pill');
        seen.clear();
        await t.sendKeyEvent(LogicalKeyboardKey.space);
        await _pumpN(t, 4);
        final now = DateTime.now();
        final asked = seen.where((u) => u.path.endsWith('/commission-detail')).map((u) => u.queryParameters['start']);
        expect(asked, contains(payrollYmd(DateTime(now.year, now.month - 1, 1))), reason: 'Space loads last month');
      });
      semantics.dispose();
    });

    testWidgets('a long log shows 100 entries at a time and still totals every one', (t) async {
      final year = payrollReport(_lastSunday, 52);
      final n = ((jsonDecode(year) as Map)['techs'] as List).fold<int>(
        0,
        (n, x) => n + ((x as Map)['weeks'] as List).fold<int>(0, (a, w) => a + ((w as Map)['jobs'] as List).length),
      );
      await _withScreen(t, report: year, start: '2025-10-20', () async {
        await t.tap(find.text('Closed-Job Commission').first);
        await _pumpN(t, 4);
        expect(find.text('Showing 100 of $n entries'), findsOneWidget);
        expect(find.text('Total  ·  $n entries'), findsOneWidget);
        await t.ensureVisible(find.text('Show 100 more'));
        await t.tap(find.text('Show 100 more'));
        await _pumpN(t, 2);
        expect(find.text('Showing 200 of $n entries'), findsOneWidget);
      });
    });

    testWidgets('a full page of runs: weeks older than the oldest listed run show no status, not "Not run yet"', (
      t,
    ) async {
      // 200 runs, all for the week of Oct 5: the server's limit, so anything older is unknown.
      final runs = jsonEncode({
        'success': true,
        'runs': [
          for (var i = 0; i < 200; i++)
            {
              'id': 1000 - i,
              'week_start': '2026-10-05',
              'status': 'finalized',
              'total_amount_paid': 10,
              'created_at': '2026-10-13T14:05:00Z',
            },
        ],
      });
      await _withScreen(
        t,
        size: const Size(2400, 1000),
        report: _elevenWeeks,
        start: '2026-08-03',
        tech: '14',
        runs: runs,
        () async {
          // Oct 12 (newer than every listed run, none for it) is the one week that is known not to be run: its chip and
          // the open week's header. The eight older weeks say nothing.
          expect(find.text('Not run yet'), findsNWidgets(2));
          expect(find.textContaining('Paid · run #1000'), findsOneWidget);
        },
      );
    });

    testWidgets('403 says there is no access and offers no retry', (t) async {
      await _withScreen(t, status: 403, report: '{"success":false,"error":"Admin access required"}', () async {
        expect(find.text('No access to payroll'), findsOneWidget);
        expect(find.text('Try again'), findsNothing);
      });
    });

    testWidgets('reduced motion: nothing left animating once the report is up', (t) async {
      await _withScreen(t, reduceMotion: true, () async {
        await t.pump(const Duration(seconds: 1));
        expect(t.binding.hasScheduledFrame, isFalse);
      });
    });

    testWidgets('no overflow from 360 to 1920 px wide, at normal and 1.3x text, register and person', (t) async {
      const widths = <double>[
        360,
        420,
        520,
        600,
        700,
        800,
        900,
        940,
        1000,
        1024,
        1100,
        1180,
        1250,
        1366,
        1440,
        1560,
        1920,
      ];
      for (final scale in [1.0, 1.3]) {
        for (final tech in [null, '13', '36']) {
          for (final w in widths) {
            await _withScreen(t, size: Size(w, 900), textScale: scale, tech: tech, () async {
              expect(t.takeException(), isNull, reason: '${w.round()} px, text x$scale, tech $tech');
            });
          }
        }
      }
    });
  });
}
