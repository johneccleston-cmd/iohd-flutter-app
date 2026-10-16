// The Pending commission tab sits right of Custom in the payroll banner and swaps the pay-week report for the
// projected commission on jobs that are not closed yet.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/payroll_screen.dart';

http.Response _handle(http.Request r) {
  final p = r.url.path;
  if (p.endsWith('/pending')) {
    return http.Response(
      jsonEncode({
        'success': true,
        'totals': {'share': 910.58, 'retainage': 0, 'net': 910.58},
        'counts': {'techs': 1, 'jobs': 1},
        'techs': [
          {
            'name': 'Daniel Baty',
            'role': 'Lead Technician',
            'totals': {'share': 910.58, 'retainage': 0, 'net': 910.58},
            'jobs': [
              {
                'jobId': '1095809012',
                'customer': 'Ideal Structures LLC',
                'status': 'Scheduled - Full Day',
                'splitPct': 100,
                'share': 910.58,
                'retainage': 0,
                'net': 910.58,
                'unverifiedDays': 0,
              },
            ],
          },
        ],
      }),
      200,
    );
  }
  if (p.endsWith('/runs')) return http.Response(jsonEncode({'success': true, 'runs': []}), 200);
  return http.Response(
    jsonEncode({
      'success': true,
      'range': {'start': '2026-10-05', 'end': '2026-10-11'},
      'rules': {},
      'techs': [
        {
          'userId': 7,
          'name': 'Alex Rivera',
          'role': 'Technician',
          'totals': {'weeklyGross': 320, 'cashPay': 0, 'totalDue': 0},
          'weeks': [],
          'retainageReleases': [],
        },
      ],
    }),
    200,
  );
}

Future<void> _pumpN(WidgetTester t, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', [r'C:\Windows\Fonts\segoeui.ttf', r'C:\Windows\Fonts\segoeuib.ttf', r'C:\Windows\Fonts\seguisb.ttf']);
    final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? r'C:\srclutter';
    await _loadFont('MaterialIcons', ['$flutterRoot/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
  });

  testWidgets('Pending commission is a tab after Custom that swaps the report for the pending list', (t) async {
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1700, 900);
    addTearDown(t.view.reset);

    await http.runWithClient(() async {
      await t.pumpWidget(MaterialApp(theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true), home: const Scaffold(body: PayrollScreen())));
      await _pumpN(t);

      // The tab is the last pill, to the right of Custom, and the report is showing.
      expect(find.text('Alex Rivera'), findsWidgets);
      expect(find.text('Daniel Baty'), findsNothing);
      final custom = t.getTopLeft(find.text('Custom'));
      final pending = t.getTopLeft(find.text('Pending'));
      expect(pending.dx, greaterThan(custom.dx));
      expect((pending.dy - custom.dy).abs(), lessThan(4), reason: 'same row');

      await t.tap(find.text('Pending'));
      await _pumpN(t);
      expect(find.text('Daniel Baty'), findsOneWidget, reason: 'the pending list loads straight away');
      expect(find.text('Ideal Structures LLC'), findsNothing, reason: "jobs stay folded until a tech's row is opened");
      expect(find.text('Alex Rivera'), findsNothing, reason: 'the pay-week report is replaced');
      expect(find.byIcon(Icons.chevron_left_rounded), findsNothing, reason: 'no date stepper on this tab');

      await t.tap(find.text('Daniel Baty'));
      await _pumpN(t, 3);
      expect(find.text('Ideal Structures LLC'), findsOneWidget);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/payroll_pending_tab.png'));

      await t.tap(find.text('Last Week'));
      await _pumpN(t);
      expect(find.text('Daniel Baty'), findsNothing);
      expect(find.text('Alex Rivera'), findsWidgets, reason: 'back on the report');
      expect(find.byIcon(Icons.chevron_left_rounded), findsOneWidget);
    }, () => MockClient((r) async => _handle(r)));
    expect(t.takeException(), isNull);
  });

  testWidgets('on a mid-size window the range collapses to a menu but Pending stays a visible tab', (t) async {
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1300, 900);
    addTearDown(t.view.reset);

    await http.runWithClient(() async {
      await t.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
        home: const Scaffold(body: PayrollScreen()),
      ));
      await _pumpN(t);
      expect(find.text('Custom'), findsNothing, reason: 'the ranges are folded into one menu');
      expect(find.text('Last Week'), findsOneWidget);
      expect(find.text('Pending'), findsOneWidget, reason: 'Pending is still its own tab');

      await t.tap(find.text('Pending'));
      await _pumpN(t);
      expect(find.text('Daniel Baty'), findsOneWidget);
    }, () => MockClient((r) async => _handle(r)));
    expect(t.takeException(), isNull);
  });
}
