// Times the payroll screen on a year of data (12 people x 52 pay weeks, about 2,000 closed jobs) and checks that the
// screen stops scheduling frames once it has nothing left to animate. Prints the timings; it fails only on framework
// errors or a screen that never goes idle.
// Run:  flutter test test/payroll_perf_test.dart
//
// Timings are flutter_tester in debug (JIT, no rasterizer), so they are much slower than a release build. Compare
// them before and after a change on the same machine, not against a frame budget.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/payroll_screen.dart';

import 'payroll_fixture.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

const _crew = [
  PayrollPerson(1, 'Andrew Johnson', 'Technician', jobsPerWeek: 3, pct: 0.5, advanceDays: 1),
  PayrollPerson(2, 'Brett Miller', 'Lead Technician', jobsPerWeek: 4, pct: 0.5, commercial: true),
  PayrollPerson(3, 'Christopher Montgomery-Alexander', 'Technician', jobsPerWeek: 4, pct: 0.6, callbacks: 1),
  PayrollPerson(4, 'Daniel Baty', 'Lead Technician', jobsPerWeek: 3, pct: 1, releases: 312.5),
  PayrollPerson(5, 'Dennis Ortega', 'Warehouse Tech', callbackOnly: true, jobsPerWeek: 0, callbacks: 2),
  PayrollPerson(6, 'Nick Smith', 'Technician', jobsPerWeek: 4, pct: 0.7),
  PayrollPerson(7, 'Zac Clemens', 'Sales Rep', sales: true, jobsPerWeek: 1, pct: 0.5),
  PayrollPerson(8, 'Luis Hernandez', 'Technician', jobsPerWeek: 4, pct: 0.5),
  PayrollPerson(9, 'Marcus Reed', 'Lead Technician', jobsPerWeek: 4, pct: 0.5, commercial: true),
  PayrollPerson(10, 'Owen Patel', 'Technician', jobsPerWeek: 3, pct: 0.4),
  PayrollPerson(11, 'Ryan Brooks', 'Technician', jobsPerWeek: 4, pct: 0.5, advanceDays: 1),
  PayrollPerson(12, 'Tyler Nguyen', 'Technician', jobsPerWeek: 3, pct: 0.6, callbacks: 1),
];

final _lastSunday = DateTime(2026, 10, 18);
final _year = payrollReport(_lastSunday, 52, people: _crew);
final _week = payrollReport(_lastSunday, 1, people: _crew);
const _emptyPending =
    '{"success":true,"totals":{"share":0,"retainage":0,"net":0},"counts":{"techs":0,"jobs":0},"techs":[]}';

http.Client _client(String body) => MockClient((r) async {
  if (r.url.path.endsWith('/runs')) return http.Response('{"success":true,"runs":[]}', 200);
  if (r.url.path.endsWith('/pending')) return http.Response(_emptyPending, 200);
  return http.Response(body, 200);
});

Widget _app(String start) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
  home: Scaffold(
    body: PayrollScreen(initialStart: start, initialEnd: payrollYmd(_lastSunday)),
  ),
);

/// Wall-clock milliseconds for one pump (build, layout, paint) after [action].
Future<double> _timed(WidgetTester t, Future<void> Function() action) async {
  await action();
  final sw = Stopwatch()..start();
  await t.pump();
  sw.stop();
  return sw.elapsedMicroseconds / 1000;
}

double _median(List<double> xs) {
  final s = [...xs]..sort();
  return s[s.length ~/ 2];
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

  testWidgets('a year of data: load, open the biggest log, rebuild with it open', (t) async {
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1600, 1000);
    addTearDown(t.view.reset);

    final jobs = ((jsonDecode(_year) as Map)['techs'] as List).fold<int>(
      0,
      (n, x) => n + ((x as Map)['weeks'] as List).fold<int>(0, (a, w) => a + ((w as Map)['jobs'] as List).length),
    );
    final firstFrame = <double>[], openLog = <double>[], rebuild = <double>[], openPerson = <double>[];
    var built = 0;

    for (var run = 0; run < 5; run++) {
      await http.runWithClient(() async {
        await t.pumpWidget(_app(payrollYmd(payrollAddDays(_lastSunday, -363))));
        // From the request going out to the report on screen: decode, parse, build, layout and paint. The mock answers
        // at once, so this is all client time.
        final sw = Stopwatch()..start();
        for (var i = 0; i < 50 && find.text('Payroll Register').evaluate().isEmpty; i++) {
          await t.pump();
        }
        firstFrame.add(sw.elapsedMicroseconds / 1000);
        await t.pump(const Duration(seconds: 2));
        expect(find.text('Payroll Register'), findsOneWidget);

        openLog.add(await _timed(t, () => t.tap(find.text('Closed-Job Commission').first)));
        await t.pump(const Duration(seconds: 2));
        built = find.byType(Text).evaluate().length;

        // Step the period with the log open: the whole report rebuilds (dimmed) while the request runs.
        rebuild.add(await _timed(t, () => t.tap(find.byIcon(Icons.chevron_left_rounded))));
        await t.pump(const Duration(seconds: 2));

        await t.tap(find.byTooltip('Close'));
        await t.pump(const Duration(seconds: 2));
        openPerson.add(await _timed(t, () => t.tap(find.text('Nick Smith').first)));
        await t.pump(const Duration(seconds: 2));
        await t.pumpWidget(const SizedBox());
      }, () => _client(_year));
    }

    // ignore: avoid_print
    print(
      'PERF year: ${_crew.length} people, $jobs jobs, ${(_year.length / 1024 / 1024).toStringAsFixed(1)} MB JSON\n'
      'PERF   first data frame     median ${_median(firstFrame).toStringAsFixed(0)} ms  $firstFrame\n'
      'PERF   open commission log  median ${_median(openLog).toStringAsFixed(0)} ms  $openLog\n'
      'PERF   Text widgets with the log open: $built\n'
      'PERF   step period, log open median ${_median(rebuild).toStringAsFixed(0)} ms  $rebuild\n'
      'PERF   open one person      median ${_median(openPerson).toStringAsFixed(0)} ms  $openPerson',
    );
  });

  testWidgets('one pay week goes idle: no frames scheduled once the entrance animations finish', (t) async {
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1600, 1000);
    addTearDown(t.view.reset);

    await http.runWithClient(() async {
      await t.pumpWidget(_app(payrollYmd(payrollAddDays(_lastSunday, -6))));
      // 15 seconds, a frame at a time, counting how many of them asked for another frame.
      var busy = 0;
      for (var i = 0; i < 150; i++) {
        await t.pump(const Duration(milliseconds: 100));
        if (t.binding.hasScheduledFrame) busy++;
      }
      final stillBusy = t.binding.hasScheduledFrame;
      // ignore: avoid_print
      print(
        'PERF idle register: $busy of 150 frames (15 s) asked for another frame; still animating after 15 s: $stillBusy',
      );

      await t.tap(find.text('Nick Smith').first);
      busy = 0;
      for (var i = 0; i < 150; i++) {
        await t.pump(const Duration(milliseconds: 100));
        if (t.binding.hasScheduledFrame) busy++;
      }
      // ignore: avoid_print
      print(
        'PERF idle person:   $busy of 150 frames (15 s) asked for another frame; still animating after 15 s: ${t.binding.hasScheduledFrame}',
      );
      await t.pumpWidget(const SizedBox());
    }, () => _client(_week));
  });
}
