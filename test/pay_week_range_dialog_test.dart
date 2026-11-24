// The payroll Custom range picker picks whole pay weeks (Monday to Sunday). Screenshots go to build/shots/ when
// the SHOTS=1 environment variable is set:  SHOTS=1 flutter test test/pay_week_range_dialog_test.dart --update-goldens
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/widgets/pay_week_range_dialog.dart';

final _shots = Platform.environment['SHOTS'] == '1';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    if (!File(p).existsSync()) return;
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

final _today = DateTime(2026, 11, 24); // a Tuesday

Future<DateTimeRange?> _open(WidgetTester t, Size size, {DateTimeRange? initial, double scale = 1}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  DateTimeRange? result;
  await t.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(fontFamily: 'Segoe UI', visualDensity: VisualDensity.compact),
      home: MediaQuery(
        data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          backgroundColor: const Color(0xFFEDEDED),
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () async {
                  result = await showPayWeekRangePicker(
                    context,
                    initial: initial ?? DateTimeRange(start: DateTime(2026, 11, 9), end: DateTime(2026, 11, 22)),
                    firstDate: DateTime(2020),
                    lastDate: DateTime(2026, 12, 24),
                    today: _today,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
  return result;
}

// Writes to build/shots/ (not test/shots/, nothing to commit) with --update-goldens.
Future<void> _shot(WidgetTester t, String name) async {
  if (!_shots) return;
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('../build/shots/$name.png'));
}

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', ['C:/Windows/Fonts/segoeui.ttf', 'C:/Windows/Fonts/segoeuib.ttf', 'C:/Windows/Fonts/seguisb.ttf']);
    final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter';
    await _loadFont('MaterialIcons', ['$flutterRoot/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
  });

  testWidgets('opens on the current range as whole weeks, two months side by side', (t) async {
    await _open(t, const Size(1366, 800));
    expect(find.text('Pick pay weeks'), findsOneWidget);
    expect(find.text('October 2026'), findsOneWidget);
    expect(find.text('November 2026'), findsOneWidget);
    expect(find.text('Nov 9 – Nov 22, 2026'), findsOneWidget);
    expect(find.text('2 pay weeks'), findsOneWidget);
    await _shot(t, 'pay_week_picker_1366');
  });

  testWidgets('two clicks pick a run of weeks; Apply returns Monday to Sunday', (t) async {
    DateTimeRange? got;
    t.view.physicalSize = const Size(1366, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => got = await showPayWeekRangePicker(
              context,
              initial: DateTimeRange(start: DateTime(2026, 11, 9), end: DateTime(2026, 11, 22)),
              firstDate: DateTime(2020),
              lastDate: DateTime(2026, 12, 24),
              today: _today,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();

    // Wednesday Oct 28 picks the week of Oct 26; then Thursday Nov 12 picks through Sunday Nov 15.
    await t.tap(find.bySemanticsLabel('Pay week Oct 26 to Nov 1, 2026').first);
    await t.pump();
    expect(find.text('Pick the last week'), findsOneWidget);
    await t.tap(find.bySemanticsLabel('Pay week Nov 9 to Nov 15, 2026').last);
    await t.pumpAndSettle();
    expect(find.text('Oct 26 – Nov 15, 2026'), findsOneWidget);
    expect(find.text('3 pay weeks'), findsOneWidget);
    await t.tap(find.text('Apply'));
    await t.pumpAndSettle();
    expect(got, DateTimeRange(start: DateTime(2026, 10, 26), end: DateTime(2026, 11, 15)));
  });

  testWidgets('a quick pick sets whole weeks; Cancel returns nothing', (t) async {
    await _open(t, const Size(1366, 800));
    await t.tap(find.text('Last month'));
    await t.pumpAndSettle();
    expect(find.text('Sep 29 – Nov 2, 2026'), findsNothing);
    expect(find.text('Sep 28 – Nov 1, 2026'), findsOneWidget, reason: 'October widened to the weeks it touches');
    expect(find.text('5 pay weeks'), findsOneWidget);
    await _shot(t, 'pay_week_picker_last_month');
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(find.text('Pick pay weeks'), findsNothing);
  });

  testWidgets('no overflow from a small window to a wide one, at 1.3x text', (t) async {
    for (final scale in [1.0, 1.3]) {
      for (final size in const [Size(1920, 1080), Size(1280, 720), Size(1024, 700), Size(700, 700), Size(420, 760)]) {
        await _open(t, size, scale: scale);
        expect(t.takeException(), isNull, reason: '$size at $scale');
        if (scale == 1.0 && size.width == 700) await _shot(t, 'pay_week_picker_700');
        await t.tap(find.text('Cancel'));
        await t.pumpAndSettle();
      }
    }
  });
}
