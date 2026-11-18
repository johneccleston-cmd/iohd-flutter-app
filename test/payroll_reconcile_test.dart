// The payroll register must be something an office can sign off on: every row adds across, every figure is the
// server's own, the screen and the PDF show the same numbers, and the PDF holds up for big and long payrolls.
//
// The PDF checks read the text back out of the real file (the pdf package writes each word as a literal string in a
// deflated page stream), so they test what would be printed, not what the code meant to print.
//
// Run:  flutter test test/payroll_reconcile_test.dart

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

double _n(Object? v) => (v as num?)?.toDouble() ?? 0;

/// How the register shows a figure: money, a job count, or a dash for zero.
String _cell(String head, double v) => v.abs() < 0.005 ? '—' : (head == 'Jobs' ? '${v.round()}' : dashMoney(v));

/// The text strings drawn on each page of a PDF made by the pdf package, one list per content stream, in order.
List<List<String>> _pdfPages(List<int> bytes) {
  final raw = latin1.decode(bytes);
  final pages = <List<String>>[];
  // "[(word)]TJ" (an array, possibly with kerning numbers between pieces) or "(word)Tj".
  final op = RegExp(r'\[((?:\((?:\\.|[^\\)])*\)|[^\]])*)\]\s*TJ|\(((?:\\.|[^\\)])*)\)\s*Tj');
  final piece = RegExp(r'\(((?:\\.|[^\\)])*)\)');
  var at = 0;
  while (true) {
    final start = raw.indexOf('stream\n', at);
    if (start < 0) break;
    final end = raw.indexOf('endstream', start);
    if (end < 0) break;
    at = end + 9;
    var body = raw.substring(start + 7, end);
    if (body.endsWith('\n')) body = body.substring(0, body.length - 1);
    String text;
    try {
      text = latin1.decode(zlib.decode(latin1.encode(body)));
    } catch (_) {
      continue; // not a deflated stream
    }
    String unescape(String s) => s.replaceAllMapped(RegExp(r'\\(.)'), (e) => switch (e.group(1)) {
      'n' => '\n',
      'r' => '\r',
      't' => '\t',
      final c => c!,
    });
    final words = [
      for (final m in op.allMatches(text))
        m.group(1) != null
            ? piece.allMatches(m.group(1)!).map((p) => unescape(p.group(1)!)).join()
            : unescape(m.group(2)!),
    ];
    if (words.isNotEmpty) pages.add(words);
  }
  return pages;
}

/// What the PDF's built-in fonts print for [s] (WinAnsi bytes, as written into the page).
String _printed(String s) => payrollPdfSafeForTest(s);

Future<List<List<String>>> _pdf(Map<String, dynamic> report) async => _pdfPages(
  await buildPayrollPdfForTest(report, generatedAt: DateTime(2026, 10, 21, 9, 30), generatedBy: 'Heather Vera'),
);

void main() {
  final standard1 = jsonDecode(payrollReport(DateTime(2026, 10, 18), 1)) as Map<String, dynamic>;
  final standard11 = jsonDecode(payrollReport(DateTime(2026, 10, 18), 11)) as Map<String, dynamic>;
  final reports = <String, Map<String, dynamic> Function()>{
    'one ordinary week': () => standard1,
    'eleven ordinary weeks': () => standard11,
    'edge cases, one week': payrollEdgeReport,
    'edge cases, three weeks (an owed balance recovered over several weeks)': () => payrollEdgeReport(weeks: 3),
    '40 people': () => payrollCrowdReport(40),
    'year to date, 8 people x 45 weeks': () => payrollCrowdReport(8, weeks: 45, lastSunday: DateTime(2026, 11, 8)),
  };
  // Optional saved commission-detail reports (real data, or the backend's rounding test), checked the same way:
  //   --dart-define=PAYROLL_REPORTS=build/a.json,build/b.json
  final files = {
    for (final p in const String.fromEnvironment('PAYROLL_REPORTS').split(',').map((p) => p.trim()).where((p) => p.isNotEmpty))
      'file $p': () => jsonDecode(File(p).readAsStringSync()) as Map<String, dynamic>,
  };
  reports.addAll(files);

  group('every register row adds across and is the server\'s figure', () {
    for (final e in reports.entries) {
      test(e.key, () {
        final report = e.value();
        final reg = payrollRegisterForTest(report);
        final techs = (report['techs'] as List).cast<Map<String, dynamic>>();
        double v(List<double> row, String head) {
          final i = reg.heads.indexOf(head);
          return i < 0 ? 0 : row[i];
        }

        expect(reg.heads.first, 'Jobs');
        expect(reg.heads.last, 'Total Due');
        expect(reg.heads, containsAllInOrder(['Closed-Job Net', 'Advances', 'Callbacks', 'Gross', 'Cash Pay']));
        // Retainage Released is optional like the other extras: there exactly when someone has a release.
        final anyRelease = techs.any((t) => _n((t['totals'] as Map)['retainageReleased']).abs() >= 0.005);
        expect(reg.heads.contains('Retainage Released'), anyRelease);

        for (var r = 0; r < reg.rows.length; r++) {
          final row = reg.rows[r];
          final t = techs[r];
          final totals = t['totals'] as Map;
          final why = '${reg.names[r]} in "${e.key}"';
          final parts = [
            'Closed-Job Net', 'Advances', 'Callbacks', 'Sales Commission', 'Retainage Held', 'Other', 'Rounding',
          ].fold<double>(0, (s, h) => s + v(row, h));
          expect(parts, closeTo(v(row, 'Gross'), 0.005), reason: 'pieces = gross: $why');
          expect(v(row, 'Gross') + v(row, 'Hurdle') + v(row, 'Advances Recovered'), closeTo(v(row, 'Cash Pay'), 0.005),
              reason: 'gross - hurdle - recovered = cash pay: $why');
          expect(v(row, 'Cash Pay') + v(row, 'Retainage Released') + v(row, 'Owed Recovered'), closeTo(v(row, 'Total Due'), 0.005),
              reason: 'cash + released - owed = total due: $why');

          // The figures are the server's, not recomputed.
          expect(v(row, 'Gross'), closeTo(_n(totals['weeklyGross']), 0.001), reason: why);
          expect(v(row, 'Cash Pay'), closeTo(_n(totals['cashPay']), 0.001), reason: why);
          expect(v(row, 'Total Due'), closeTo(_n(totals['totalDue']), 0.001), reason: why);
          expect(v(row, 'Hurdle'), closeTo(-_n(totals['hurdleApplied']), 0.001), reason: why);
          expect(v(row, 'Retainage Released'), closeTo(_n(totals['retainageReleased']), 0.001), reason: why);
        }

        final dueTotal = techs.fold<double>(0, (s, t) => s + _n((t['totals'] as Map)['totalDue']));
        expect(reg.total.last, closeTo(dueTotal, 0.005), reason: 'the Total row\'s Total Due is everyone\'s, summed');
      });
    }

    test('optional columns appear only when someone has them, and rounding is called rounding', () {
      final plain = payrollRegisterForTest(standard1).heads;
      for (final h in ['Advances Recovered', 'Owed Recovered', 'Other', 'Rounding']) {
        expect(plain, isNot(contains(h)), reason: 'an ordinary week has no "$h"');
      }
      expect(plain, contains('Hurdle'));

      final edge = payrollRegisterForTest(payrollEdgeReport()).heads;
      expect(edge, containsAllInOrder(['Retainage Held', 'Other', 'Gross', 'Hurdle', 'Advances Recovered', 'Cash Pay', 'Retainage Released', 'Owed Recovered', 'Total Due']));

      // Only a cent of per-job rounding: the column says so instead of calling it an adjustment.
      final cents = payrollApplyEdges(
        jsonDecode(payrollReport(DateTime(2026, 10, 18), 1)) as Map<String, dynamic>,
        const {12: PayrollEdge(drift: 0.01), 16: PayrollEdge(drift: -0.01)},
      );
      final heads = payrollRegisterForTest(cents).heads;
      expect(heads, contains('Rounding'));
      expect(heads, isNot(contains('Other')));
    });

    test('a register of only sales and callback-only people has no hurdle column', () {
      final r = jsonDecode(payrollReport(DateTime(2026, 10, 18), 1, people: [payrollPeople[4], payrollPeople[6]]))
          as Map<String, dynamic>;
      expect(payrollRegisterForTest(r).heads, isNot(contains('Hurdle')));
    });
  });

  group('the PDF prints the register\'s figures', () {
    for (final source in {'edge cases': payrollEdgeReport, ...files}.entries) {
    test('cover register: every person, every figure, in column order, and the grand total (${source.key})', () async {
      final report = source.value();
      final reg = payrollRegisterForTest(report);
      final pages = await _pdf(report);
      final cover = pages.firstWhere((p) => p.contains('Payroll') && p.contains('register'));

      for (var r = 0; r < reg.rows.length; r++) {
        // The row starts after the person's last name; its cells follow in column order.
        final last = _printed(reg.names[r].split(' ').last);
        var at = cover.indexOf(last);
        expect(at, greaterThanOrEqualTo(0), reason: '${reg.names[r]} is on the cover');
        for (var i = 0; i < reg.heads.length; i++) {
          final want = _printed(_cell(reg.heads[i], reg.rows[r][i]));
          final found = cover.indexOf(want, at + 1);
          expect(found, greaterThan(at), reason: '${reg.names[r]}: ${reg.heads[i]} should print $want');
          at = found;
        }
      }
      for (var i = 0; i < reg.heads.length; i++) {
        expect(cover, contains(_printed(reg.heads[i] == 'Jobs' ? '${reg.total[i].round()}' : dashMoney(reg.total[i]))),
            reason: 'Total row: ${reg.heads[i]}');
      }
      // The big "Total due" at the top of the cover is the same figure.
      expect(cover.where((w) => w == dashMoney(reg.total.last)).length, greaterThanOrEqualTo(2));
    });
    }

    test('each week\'s ledger prints the advance recovery and the shortfall carried, not a sum that does not add', () async {
      final report = payrollEdgeReport();
      final pages = await _pdf(report);
      final all = pages.expand((p) => p).toList();
      for (final t in (report['techs'] as List).cast<Map<String, dynamic>>()) {
        for (final w in (t['weeks'] as List).cast<Map<String, dynamic>>()) {
          expect(all, contains(dashMoney(_n(w['weeklyGross']))), reason: '${t['name']} gross');
          expect(all, contains(dashMoney(_n(w['cashPay']))), reason: '${t['name']} cash pay');
          if (_n(w['advanceRecovered']) > 0) {
            expect(all, contains(dashMoney(-_n(w['advanceRecovered']))), reason: '${t['name']} advances recovered');
          }
          if (_n(w['carryRecovered']) > 0) {
            expect(all, contains(dashMoney(_n(w['cashPay']) - _n(w['carryRecovered']))), reason: '${t['name']} paid after recovery');
          }
        }
      }
      // The shortfall that carries forward is said in words beside its amount, outside the ledger's sum.
      final under = pages.firstWhere((p) => p.contains('Lukasz') && p.contains('forward:'));
      expect(under.join(' '), contains('Advance shortfall carried forward: \$120.00.'));
    });

    test('names outside the fonts print as plain letters, punctuation as itself, nothing as a question mark', () async {
      expect(_printed('Łukasz Wójcik-Nguyễn'), 'Lukasz W\u00f3jcik-Nguyen');
      expect(_printed('O’Brien – “Main St”'), 'O\x92Brien \x96 \x93Main St\x94');
      expect(_printed('—'), '\x97');
      expect(_printed('Jose\u0301'), 'Jose'); // a combining accent is dropped, the letter kept
      expect(_printed('Ærøskøbing Çağrı'), '\u00c6r\u00f8sk\u00f8bing \u00c7agri');
      expect(_printed('漢字'), '??');

      final report = payrollEdgeReport();
      final words = (await _pdf(report)).expand((p) => p).join(' ');
      expect(words, contains('Lukasz'));
      expect(words, isNot(contains('?')), reason: 'no name or customer in the fixture should print as a question mark');
    });

    test('40 people: the cover register runs onto a second page with its header repeated, then one section each', () async {
      final report = payrollCrowdReport(40);
      final pages = await _pdf(report);
      final coverStart = pages.indexWhere((p) => p.contains('register'));
      final coverEnd = pages.indexWhere((p) => p.contains('Each') && p.contains('across:'));
      expect(coverEnd, greaterThan(coverStart), reason: '40 rows do not fit one landscape page');
      expect(pages[coverEnd], contains('Technician'), reason: 'the register header repeats on the next page');
      expect(pages[coverEnd], contains('Total'));
      // Every person's section exists (each starts on a new page), and the document is numbered throughout.
      for (final t in (report['techs'] as List).cast<Map<String, dynamic>>()) {
        final last = (t['name'] as String).split(' ').last;
        expect(pages.skip(coverEnd + 1).any((p) => p.contains(last)), isTrue, reason: '${t['name']} has a section');
      }
      expect(pages.length, greaterThanOrEqualTo(41));
      expect(pages.last.join(' '), contains('Page ${pages.length} of ${pages.length}'));
    });

    test('a year to date (8 people x 45 weeks) builds every page, with continued headers on long sections', () async {
      final watch = Stopwatch()..start();
      final report = payrollCrowdReport(8, weeks: 45, lastSunday: DateTime(2026, 11, 8));
      final pages = await _pdf(report);
      debugPrint('year to date: ${pages.length} pages in ${watch.elapsedMilliseconds} ms');
      expect(pages.length, greaterThan(100));
      expect(pages.where((p) => p.contains('(continued)')).length, greaterThan(50));
      final reg = payrollRegisterForTest(report);
      final cover = pages.firstWhere((p) => p.contains('register'));
      expect(cover, contains(dashMoney(reg.total.last)));
    });

    test('an empty report and a person with nothing in range still make a valid PDF', () async {
      final r = jsonDecode(payrollReport(DateTime(2026, 10, 18), 1)) as Map<String, dynamic>;
      final t = (r['techs'] as List).first as Map;
      t['weeks'] = <dynamic>[];
      t['retainageReleases'] = <dynamic>[];
      t['totals'] = <String, dynamic>{};
      final pages = await _pdf(r);
      expect(pages.expand((p) => p).join(' '), contains('Nothing to report for this person in these dates.'));
      final empty = await _pdf({...r, 'techs': <dynamic>[]});
      expect(empty, isNotEmpty);
    });
  });

  group('the screen shows the register the PDF prints', () {
    Future<void> loadFont(String family, List<String> paths) async {
      final loader = FontLoader(family);
      for (final p in paths) {
        loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
      }
      await loader.load();
    }

    setUpAll(() async {
      await loadFont('Segoe UI', [
        r'C:\Windows\Fonts\segoeui.ttf',
        r'C:\Windows\Fonts\segoeuib.ttf',
        r'C:\Windows\Fonts\seguisb.ttf',
      ]);
      final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter';
      await loadFont('MaterialIcons', ['$flutterRoot/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
    });

    Future<void> withScreen(
      WidgetTester t,
      Map<String, dynamic> report,
      Future<void> Function() body, {
      Size size = const Size(1920, 1300),
      String? tech,
      double textScale = 1,
    }) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = size;
      addTearDown(t.view.reset);
      final json = jsonEncode(report);
      await http.runWithClient(() async {
        await t.pumpWidget(
          MaterialApp(
            theme: ThemeData(fontFamily: 'Segoe UI'),
            home: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
                child: Scaffold(
                  body: PayrollScreen(initialStart: '2026-10-12', initialEnd: '2026-10-18', initialTech: tech),
                ),
              ),
            ),
          ),
        );
        for (var i = 0; i < 24; i++) {
          await t.pump(const Duration(milliseconds: 120));
        }
        await body();
        await t.pumpWidget(const SizedBox());
      }, () => MockClient((r) async {
        if (r.url.path.endsWith('/runs')) return http.Response('{"success":true,"runs":[]}', 200);
        return http.Response.bytes(utf8.encode(json), 200, headers: {'content-type': 'application/json; charset=utf-8'});
      }));
    }

    testWidgets('every register heading and figure on screen is the one the PDF prints', (t) async {
      final report = payrollEdgeReport();
      final reg = payrollRegisterForTest(report);
      await withScreen(t, report, () async {
        for (final h in reg.heads) {
          expect(find.text(h), findsWidgets, reason: 'heading $h');
        }
        for (var r = 0; r < reg.rows.length; r++) {
          final y = t.getCenter(find.text(reg.names[r]).first).dy;
          for (var i = 0; i < reg.heads.length; i++) {
            final want = _cell(reg.heads[i], reg.rows[r][i]);
            final onRow = find.text(want).evaluate().where((el) {
              final box = el.renderObject! as RenderBox;
              return (box.localToGlobal(box.size.center(Offset.zero)).dy - y).abs() < 20;
            });
            expect(onRow, isNotEmpty, reason: '${reg.names[r]}: ${reg.heads[i]} should show $want');
          }
        }
        expect(find.textContaining('Each row adds across'), findsOneWidget);
      });
    });

    testWidgets('sorting by Total Due keeps people with the same amount in name order', (t) async {
      final report = payrollEdgeReport();
      final techs = (report['techs'] as List).cast<Map<String, dynamic>>();
      // Zac and Dennis owe the same; so do Andrew and Brett.
      for (final t in techs) {
        final totals = t['totals'] as Map<String, dynamic>;
        if (t['name'] == 'Zac Clemens') totals['totalDue'] = 100.0;
        if (t['name'] == 'Brett Miller') totals['totalDue'] = 432.7;
      }
      await withScreen(t, report, () async {
        await t.tap(find.text('Total Due').last);
        await t.pump(const Duration(milliseconds: 300));
        double y(String name) => t.getCenter(find.text(name).first).dy;
        expect(y('Andrew Johnson'), lessThan(y('Brett Miller')));
        expect(y('Dennis Ortega'), lessThan(y('Zac Clemens')));
        expect(y('Christopher Montgomery-Alexander'), lessThan(y('Andrew Johnson')), reason: 'bigger amounts first');
      });
    });

    testWidgets('the Total Due log adds up to the Total Due card, owed recoveries included', (t) async {
      final report = payrollEdgeReport();
      final due = (report['techs'] as List).fold<double>(0, (s, t) => s + _n(((t as Map)['totals'] as Map)['totalDue']));
      await withScreen(t, report, () async {
        await t.tap(find.text('Total Due').first);
        for (var i = 0; i < 6; i++) {
          await t.pump(const Duration(milliseconds: 120));
        }
        expect(find.text('Advance owed from an earlier week'), findsNWidgets(2), reason: 'Andrew and Daniel');
        // The card, the Everyone row, and the log's header and footer totals all say the same.
        expect(find.text(dashMoney(due)), findsAtLeastNWidgets(3));
      });
    });

    testWidgets('a week ledger adds down: the shortfall carried forward sits below the cash pay, out of the sum', (t) async {
      await withScreen(t, payrollEdgeReport(), tech: '23', () async {
        final cash = t.getCenter(find.text('Cash pay for the week')).dy;
        expect(t.getCenter(find.text('Advance shortfall carried forward')).dy, greaterThan(cash));
        expect(t.getCenter(find.text('Weekly hurdle')).dy, lessThan(cash));
      });
      await withScreen(t, payrollEdgeReport(), tech: '22', () async {
        expect(find.text('Advances recovered'), findsOneWidget);
        expect(find.text('-\$150.00'), findsWidgets);
      });
      await withScreen(t, payrollEdgeReport(), tech: '26', () async {
        expect(find.text('Rounding'), findsOneWidget, reason: 'a cent of per-job rounding is named, not hidden');
      });
    });

    testWidgets('no overflow with every optional column, at desktop widths and 1.3x text', (t) async {
      for (final scale in [1.0, 1.3]) {
        for (final w in <double>[1024, 1180, 1280, 1366, 1440, 1536, 1600, 1920, 2560]) {
          for (final tech in [null, '21', '22', '23', '27']) {
            await withScreen(t, payrollEdgeReport(), size: Size(w, 1000), textScale: scale, tech: tech, () async {
              expect(t.takeException(), isNull, reason: '${w.round()} px, text x$scale, tech $tech');
            });
          }
        }
      }
    });
  });
}
