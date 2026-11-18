// The payroll toolbar at common desktop widths and larger text, with the fonts the app really uses: Segoe UI (Windows
// app) and Roboto (web app). Checks nothing overflows and the range controls stay on one line ("Pending" used to drop
// under the date). Text is never shrunk to fit; the toolbar moves to two rows instead.
//
//   flutter test test/payroll_toolbar_fit_test.dart
//   flutter test test/payroll_toolbar_fit_test.dart --dart-define=TOOLBAR_SHOTS=after   (also saves toolbar PNGs)
//
// PNGs go to build/payroll_audit/toolbar_<phase>/ (gitignored); nothing under test/shots is touched.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/payroll_screen.dart';

import 'payroll_fixture.dart';

const _phase = String.fromEnvironment('TOOLBAR_SHOTS');

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

/// Renders the payroll screen and checks the toolbar. [loading] checks it while the report is still loading, when a
/// spinner sits beside the range controls and takes room of its own.
Future<void> _check(
  WidgetTester t, {
  required String family,
  required double width,
  double scale = 1.0,
  String start = '2026-10-12',
  String end = '2026-10-18',
  required String label,
  bool loading = false,
  String? shot,
}) async {
  t.view.devicePixelRatio = 1.0;
  t.view.physicalSize = Size(width, 400);
  addTearDown(t.view.reset);
  final body = jsonEncode(payrollEdgeReport()..['range'] = {'start': start, 'end': end});
  final hold = Completer<void>();
  await http.runWithClient(
    () async {
      await t.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(fontFamily: family, useMaterial3: true),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(body: PayrollScreen(initialStart: start, initialEnd: end)),
        ),
      );
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 120));
      }
      expect(t.takeException(), isNull, reason: 'nothing may overflow');
      if (loading) expect(find.byType(CircularProgressIndicator), findsWidgets, reason: 'still loading');

      final date = t.getRect(find.text(label));
      final pending = t.getRect(find.text('Pending').first);
      final title = t.getRect(find.text('PAYROLL'));
      final oneRow = (title.center.dy - date.center.dy).abs() < 8;
      final beside = (pending.center.dy - date.center.dy).abs() < 8;
      debugPrint('[toolbar] $family x$scale ${width.toInt()}${loading ? ' loading' : ''} "$label": '
          '${oneRow ? 'one row' : 'two rows'}, Pending ${beside ? 'beside the date' : 'WRAPPED'}');
      expect(beside, isTrue, reason: '"Pending" stays beside the date');
      expect(pending.right, lessThanOrEqualTo(width), reason: 'controls stay on screen');

      if (shot != null) {
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('../build/payroll_audit/toolbar_$_phase/$shot.png'));
      }
      if (!hold.isCompleted) hold.complete();
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 1));
    },
    () => MockClient((r) async {
      if (r.url.path.endsWith('/runs')) return http.Response('{"success":true,"runs":[]}', 200);
      if (r.url.path.endsWith('/pending')) {
        return http.Response('{"success":true,"totals":{"share":0,"retainage":0,"net":0},"techs":[]}', 200);
      }
      if (loading) await hold.future;
      return http.Response.bytes(utf8.encode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    }),
  );
}

void main() {
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter';
  final fonts = '$flutterRoot/bin/cache/artifacts/material_fonts';

  setUpAll(() async {
    await _loadFont('Segoe UI', [r'C:\Windows\Fonts\segoeui.ttf', r'C:\Windows\Fonts\segoeuib.ttf', r'C:\Windows\Fonts\seguisb.ttf']);
    await _loadFont('Roboto', ['$fonts/roboto-regular.ttf', '$fonts/roboto-medium.ttf', '$fonts/roboto-bold.ttf']);
    await _loadFont('MaterialIcons', ['$fonts/materialicons-regular.otf']);
  });

  const widths = [1180.0, 1228.0, 1280.0, 1366.0, 1440.0, 1536.0, 1600.0, 1680.0, 1920.0];
  for (final family in ['Segoe UI', 'Roboto']) {
    group(family, () {
      for (final scale in [1.0, 1.15, 1.3]) {
        for (final width in widths) {
          testWidgets('${width.toInt()} px, text x$scale', (t) => _check(
            t,
            family: family,
            width: width,
            scale: scale,
            label: 'Oct 12 – 18, 2026',
            shot: _phase.isNotEmpty && scale == 1.0 ? '${family.replaceAll(' ', '')}_${width.toInt()}' : null,
          ));
        }
      }
      // The longest label the stepper shows (a range across New Year carries both years), loaded and still loading.
      for (final loading in [false, true]) {
        for (final width in widths) {
          testWidgets('${width.toInt()} px, range across New Year${loading ? ', loading' : ''}', (t) => _check(
            t,
            family: family,
            width: width,
            start: '2026-12-28',
            end: '2027-01-03',
            label: 'Dec 28, 2026 – Jan 3, 2027',
            loading: loading,
          ));
        }
      }
    });
  }

  if (_phase.isNotEmpty) autoUpdateGoldenFiles = true;
}
