// Renders the Calendar screen with fake events at several window sizes. Run:
//   flutter test test/calendar_render_test.dart --update-goldens
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/calendar_screen.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

const _cust = ['Schuber Mitchell Homes', 'Quality Building Systems Inc.', 'Lennar', 'Moser Construction LLC', 'Trinitas', 'OZ Homes, LLC', 'Heather & Tom Whitfield'];
const _st = ['Scheduled - Full Day', 'Need To Schedule', 'Complete', 'Partially Complete', 'Estimate Provided', 'Need Deposit'];
const _tech = ['Brett Hall', 'Marcus Lee', 'Dan Ruiz', ''];

http.Client _mock() => MockClient((req) async {
      final now = DateTime.now();
      final events = <Map<String, dynamic>>[];
      for (var d = 1; d <= 28; d++) {
        final n = (d * 7) % 6; // 0..5 events per day
        for (var i = 0; i < n; i++) {
          final k = d + i;
          events.add({
            'event_date': '${now.year}-${now.month.toString().padLeft(2, '0')}-${d.toString().padLeft(2, '0')}',
            'job_number': '${1099000000 + k}',
            'customer_name': _cust[k % _cust.length],
            'status': _st[k % _st.length],
            if (k % 3 == 1) ...{'time_start': '${8 + k % 6}:${k % 2 == 0 ? '00' : '30'}:00', 'time_end': '${10 + k % 6}:00:00'},
            'techs': k % 3 == 0 ? 'Brett Hall, Marcus Lee' : _tech[k % _tech.length],
            'is_estimate': k % 4 == 0,
          });
        }
      }
      return http.Response(jsonEncode({'events': events}), 200);
    });

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', ['C:/Windows/Fonts/segoeui.ttf', 'C:/Windows/Fonts/segoeuib.ttf']);
    // Without this every icon renders as an empty box in the screenshots.
    await _loadFont('MaterialIcons', ['C:/src/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
  });

  Future<void> pumpCalendar(WidgetTester t, Size size) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await http.runWithClient(() async {
      await t.pumpWidget(MaterialApp(theme: _theme(), home: const CalendarScreen()));
      await t.pumpAndSettle();
    }, _mock);
  }

  testWidgets('every event on every day is shown, with no "+N more"', (t) async {
    await pumpCalendar(t, const Size(1280, 720));
    expect(t.takeException(), isNull);
    expect(find.textContaining(' more'), findsNothing);
    // One chip per event: the mock puts (day * 7) % 6 events on each of days 1-28.
    final expected = [for (var d = 1; d <= 28; d++) (d * 7) % 6].fold<int>(0, (a, b) => a + b);
    final chips = find.byWidgetPredicate((w) {
      final m = w is Tooltip ? (w.message ?? '') : '';
      return m.contains('Techs: ') || m.contains('No tech assigned');
    });
    expect(chips, findsNWidgets(expected));
    // The month is taller than the window, so it scrolls rather than hiding events.
    expect(find.byType(SingleChildScrollView), findsWidgets);
  });

  testWidgets('week view title has a real dash, and Today and Clear filters appear', (t) async {
    await pumpCalendar(t, const Size(1280, 720));
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Clear filters'), findsNothing);
    await t.tap(find.text('Jobs'));
    await t.pumpAndSettle();
    expect(find.text('Clear filters'), findsOneWidget);
    await t.tap(find.text('Clear filters'));
    await t.pumpAndSettle();
    expect(find.text('Clear filters'), findsNothing);

    await t.tap(find.text('Week'));
    await t.pumpAndSettle();
    expect(find.textContaining('\u00e2'), findsNothing); // the old title showed "â€“"
    // The period title ("Oct 11 \u2013 17, 2026"); times on the cards use an en dash too ("9:30\u201311:00 AM").
    expect(find.textContaining(RegExp(r'^[A-Z][a-z]{2} \d+ \u2013 .*\d{4}$')), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('a slow reply for a month you already left cannot empty the grid', (t) async {
    t.view.physicalSize = const Size(1280, 720);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final slow = Completer<http.Response>();
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      if (calls == 1) return _mock().get(req.url); // the first load: a full month of events
      return slow.future; // Next: held back until we say so
    });
    await http.runWithClient(() async {
      await t.pumpWidget(MaterialApp(theme: _theme(), home: const CalendarScreen()));
      await t.pumpAndSettle();
      expect(find.text('Lennar'), findsWidgets);

      await t.tap(find.byTooltip('Next month (→)')); // Nov is not in the loaded window: request #2 starts
      await t.pump();
      await t.tap(find.byTooltip('Previous month (←)')); // back to Oct, which is held: #2 is now stale
      await t.pumpAndSettle();
      slow.complete(http.Response(jsonEncode({'events': <dynamic>[]}), 200)); // the stale reply: no events at all
      await t.pumpAndSettle();
      expect(find.text('Lennar'), findsWidgets, reason: 'Oct must keep its events');
      expect(find.text('Nothing scheduled this month'), findsNothing);
    }, () => client);
    expect(t.takeException(), isNull);
  });

  testWidgets('calendar filtered 1280', (t) async {
    t.view.physicalSize = const Size(1280, 720);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await http.runWithClient(() async {
      await t.pumpWidget(RepaintBoundary(
        key: const ValueKey('shot'),
        child: MaterialApp(theme: _theme(), home: const CalendarScreen()),
      ));
      await t.pumpAndSettle();
      await t.tap(find.text('All techs'));
      await t.pumpAndSettle();
      await t.tap(find.text('Brett Hall'));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('Filter by tech (select several)')); // toggling the button closes the menu
      await t.pumpAndSettle();
    }, _mock);
    expect(t.takeException(), isNull);
    await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('shots/calendar_filtered_1280.png'));
  });

  testWidgets('calendar tech menu 1280', (t) async {
    t.view.physicalSize = const Size(1280, 720);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await http.runWithClient(() async {
      await t.pumpWidget(RepaintBoundary(
        key: const ValueKey('shot'),
        child: MaterialApp(theme: _theme(), home: const CalendarScreen()),
      ));
      await t.pumpAndSettle();
      await t.tap(find.text('All techs'));
      await t.pumpAndSettle();
      await t.tap(find.text('Brett Hall'));
      await t.pumpAndSettle();
    }, _mock);
    expect(t.takeException(), isNull);
    await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('shots/calendar_tech_menu_1280.png'));
  });

  testWidgets('calendar status menu 1280', (t) async {
    t.view.physicalSize = const Size(1280, 720);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await http.runWithClient(() async {
      await t.pumpWidget(RepaintBoundary(
        key: const ValueKey('shot'),
        child: MaterialApp(theme: _theme(), home: const CalendarScreen()),
      ));
      await t.pumpAndSettle();
      await t.tap(find.text('All statuses'));
      await t.pumpAndSettle();
      await t.tap(find.text('Need Deposit').first);
      await t.pumpAndSettle();
    }, _mock);
    expect(t.takeException(), isNull);
    await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('shots/calendar_status_menu_1280.png'));
  });

  testWidgets('ticking tech names does not move the tech button or its menu', (t) async {
    await pumpCalendar(t, const Size(1280, 720));
    final button = find.byTooltip('Filter by tech (select several)');
    final before = t.getRect(button);
    await t.tap(button);
    await t.pumpAndSettle();
    final itemBefore = t.getTopLeft(find.text('Brett Hall'));

    await t.tap(find.text('Brett Hall'));
    await t.pumpAndSettle();
    await t.tap(find.text('Dan Ruiz'));
    await t.pumpAndSettle();
    await t.tap(find.text('Marcus Lee'));
    await t.pumpAndSettle();

    expect(t.getRect(button), before, reason: 'the button keeps its size and place however many names are ticked');
    expect(t.getTopLeft(find.text('Brett Hall')), itemBefore, reason: 'so the open menu stays put too');
    expect(t.takeException(), isNull);
  });

  testWidgets('the jump-to-date picker is black, not the app red', (t) async {
    t.view.physicalSize = const Size(1280, 720);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    // The app's own accent, which is what the picker would otherwise be painted in.
    final red = _theme().copyWith(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFCC0007), primary: const Color(0xFFCC0007)));
    await http.runWithClient(() async {
      await t.pumpWidget(RepaintBoundary(
        key: const ValueKey('shot'),
        child: MaterialApp(theme: red, home: const CalendarScreen()),
      ));
      await t.pumpAndSettle();
      await t.tap(find.text('October 2026'));
      await t.pumpAndSettle();
      expect(find.text('JUMP TO DATE'), findsOneWidget);
      final picker = t.element(find.text('JUMP TO DATE'));
      expect(Theme.of(picker).colorScheme.primary, isNot(const Color(0xFFCC0007)));
      expect(Theme.of(picker).colorScheme.primary, const Color(0xFF1A1C1E));
    }, _mock);
    expect(t.takeException(), isNull);
    await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('shots/calendar_date_picker_1280.png'));
  });

  testWidgets('an empty day cannot be opened, a day with events can', (t) async {
    await pumpCalendar(t, const Size(1280, 720));
    // The mock puts no events on day 6 ((6 * 7) % 6 == 0) and several on day 5.
    final empty = find.bySemanticsLabel(RegExp(r'October 6, nothing scheduled'));
    final handle = t.ensureSemantics();
    expect(empty, findsOneWidget);
    await t.tapAt(t.getTopLeft(empty) + const Offset(40, 14));
    await t.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing, reason: 'nothing to show, so no popup');

    await t.tapAt(t.getTopLeft(find.bySemanticsLabel(RegExp(r'October 5, '))) + const Offset(40, 14));
    await t.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    handle.dispose();
    expect(t.takeException(), isNull);
  });

  testWidgets('calendar week 1280', (t) async {
    t.view.physicalSize = const Size(1280, 720);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await http.runWithClient(() async {
      await t.pumpWidget(RepaintBoundary(
        key: const ValueKey('shot'),
        child: MaterialApp(theme: _theme(), home: const CalendarScreen()),
      ));
      await t.pumpAndSettle();
      await t.tap(find.text('Week'));
      await t.pumpAndSettle();
    }, _mock);
    expect(t.takeException(), isNull);
    await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('shots/calendar_week_1280.png'));
  });

  for (final s in const [(1920.0, 1080.0), (1280.0, 720.0), (800.0, 700.0), (420.0, 800.0)]) {
    testWidgets('calendar month ${s.$1.toInt()}', (t) async {
      t.view.physicalSize = Size(s.$1, s.$2);
      t.view.devicePixelRatio = 1;
      await http.runWithClient(() async {
        await t.pumpWidget(RepaintBoundary(
          key: const ValueKey('shot'),
          child: MaterialApp(theme: _theme(), home: const CalendarScreen()),
        ));
        await t.pumpAndSettle();
      }, _mock);
      expect(t.takeException(), isNull);
      await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('shots/calendar_month_${s.$1.toInt()}.png'));
    });
  }
}

// Material buttons build their own text style, which the test engine would draw in the placeholder font.
ThemeData _theme() {
  const label = TextStyle(fontFamily: 'Segoe UI');
  return ThemeData(
    useMaterial3: true,
    fontFamily: 'Segoe UI',
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(textStyle: label)),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(textStyle: label)),
  );
}
