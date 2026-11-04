// Date boundaries, load/failure states and server load for the Calendar, with "today" pinned through DashClock so the
// month and year edges are tested on purpose instead of on whatever day the suite runs.
// Run:  flutter test test/calendar_logic_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:iohd_desktop/calendar_screen.dart';
import 'package:iohd_desktop/widgets/dashboard_data.dart';
import 'package:iohd_desktop/widgets/dashboard_kit.dart' show SkeletonPulse;

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

String _ymd(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

Map<String, dynamic> _ev(String date, String customer, {String techs = 'Brett Hall', bool estimate = false}) => {
  'event_date': date,
  'job_number': '${customer.hashCode.abs()}',
  'customer_name': customer,
  'status': 'Scheduled',
  'techs': techs,
  'is_estimate': estimate,
};

/// Answers every request with [events] and remembers the asked-for windows.
class _Server {
  final List<Uri> asked = [];
  List<Map<String, dynamic>> events;
  _Server([this.events = const []]);
  http.Client client() => MockClient((r) async {
    asked.add(r.url);
    return http.Response(jsonEncode({'events': events}), 200);
  });
}

Future<void> _pump(
  WidgetTester t,
  http.Client client, {
  Size size = const Size(1280, 720),
  Widget Function(Widget)? wrap,
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await http.runWithClient(() async {
    const screen = CalendarScreen();
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
        home: wrap == null ? screen : wrap(screen),
      ),
    );
    await t.pumpAndSettle();
  }, () => client);
}

void _today(DateTime d) {
  DashClock.debugOverride = () => DateTime(d.year, d.month, d.day, 10, 30);
  addTearDown(() => DashClock.debugOverride = null);
}

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', ['C:/Windows/Fonts/segoeui.ttf', 'C:/Windows/Fonts/segoeuib.ttf']);
    await _loadFont('MaterialIcons', ['C:/src/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('dates', () {
    testWidgets('the first load asks for the month before through the month after, as whole days', (t) async {
      _today(DateTime(2026, 10, 29));
      final s = _Server();
      await _pump(t, s.client());
      expect(s.asked.single.queryParameters, {'start': '2026-09-01', 'end': '2026-12-01'});
    });

    testWidgets('December to January and back crosses the year in both directions', (t) async {
      _today(DateTime(2026, 12, 15));
      final s = _Server([_ev('2027-01-04', 'New Year Co'), _ev('2026-11-30', 'November Co')]);
      await _pump(t, s.client());
      expect(find.text('December 2026'), findsOneWidget);
      await http.runWithClient(() async {
        await t.tap(find.byTooltip('Next month (→)'));
        await t.pumpAndSettle();
        expect(find.text('January 2027'), findsOneWidget);
        expect(find.text('New Year Co'), findsOneWidget);
        await t.tap(find.byTooltip('Previous month (←)'));
        await t.pumpAndSettle();
        await t.tap(find.byTooltip('Previous month (←)'));
        await t.pumpAndSettle();
      }, s.client);
      expect(find.text('November 2026'), findsOneWidget);
      expect(find.text('November Co'), findsOneWidget);
      // Dec (Nov-Jan held), Jan (needs Feb 1-6: Dec-Feb), back to Dec (needs Nov 29-30: Nov-Jan again); Nov is then held.
      expect(s.asked.map((u) => u.queryParameters['start']), ['2026-11-01', '2026-12-01', '2026-11-01']);
      // Every window asked for starts on the 1st and ends on the 1st three months later.
      for (final u in s.asked) {
        expect(u.queryParameters['start'], endsWith('-01'));
        expect(u.queryParameters['end'], endsWith('-01'));
      }
    });

    testWidgets('a week that runs into the new year names both years', (t) async {
      _today(DateTime(2026, 12, 30));
      await _pump(t, _Server().client());
      await t.tap(find.text('Week'));
      await t.pumpAndSettle();
      expect(find.text('Dec 27, 2026 – Jan 2, 2027'), findsOneWidget);
    });

    testWidgets('February has 29 days in a leap year and 28 otherwise, and the grid has only the weeks it needs', (
      t,
    ) async {
      final handle = t.ensureSemantics();
      _today(DateTime(2028, 2, 10));
      await _pump(t, _Server([_ev('2028-02-29', 'Leap Day Co')]).client(), size: const Size(1500, 900));
      expect(find.bySemanticsLabel(RegExp(r'^Tuesday, February 29')), findsOneWidget);
      expect(find.text('Leap Day Co'), findsOneWidget);

      // February 2026 starts on a Sunday and has 28 days: exactly four weeks, no March days at all.
      DashClock.debugOverride = () => DateTime(2026, 2, 10, 10);
      await t.pumpWidget(const SizedBox());
      await _pump(t, _Server().client(), size: const Size(1500, 900));
      expect(find.bySemanticsLabel(RegExp(r'February 29')), findsNothing);
      expect(find.bySemanticsLabel(RegExp(r'^Saturday, February 28')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'March 1,')), findsNothing);
      handle.dispose();
    });

    testWidgets('the week the clocks fall back still has seven different days, each event on its own day', (t) async {
      // US daylight saving ends on Sunday 1 November 2026: adding 24 hours to that midnight would repeat the day.
      _today(DateTime(2026, 11, 1));
      final s = _Server([
        _ev('2026-11-01', 'Sunday Co'),
        _ev('2026-11-02', 'Monday Co'),
        _ev('2026-11-07', 'Saturday Co'),
      ]);
      await _pump(t, s.client());
      await t.tap(find.text('Week'));
      await t.pumpAndSettle();
      expect(find.text('Nov 1 – 7, 2026'), findsOneWidget);
      for (final d in ['SUN', 'MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT']) {
        expect(find.text(d), findsOneWidget, reason: '$d appears exactly once');
      }
      double colOf(String text) => t.getCenter(find.text(text)).dx;
      expect(colOf('Sunday Co'), lessThan(colOf('Monday Co')));
      expect(colOf('Monday Co'), lessThan(colOf('Saturday Co')));
      expect((colOf('Saturday Co') - colOf('Sunday Co')) / (1280 / 7), closeTo(6, 0.1));
    });

    testWidgets('a date sent with a time or a time zone stays on its own day', (t) async {
      _today(DateTime(2026, 10, 29));
      await _pump(
        t,
        _Server([
          _ev('2026-10-29T00:00:00.000Z', 'Utc Midnight Co'),
          _ev('2026-10-30T23:30:00-05:00', 'Late Evening Co'),
        ]).client(),
      );
      await t.tap(find.text('Week'));
      await t.pumpAndSettle();
      final colW = 1280 / 7;
      expect((t.getCenter(find.text('Utc Midnight Co')).dx / colW).floor(), 4, reason: 'Thursday the 29th');
      expect((t.getCenter(find.text('Late Evening Co')).dx / colW).floor(), 5, reason: 'Friday the 30th');
    });
  });

  group('data', () {
    testWidgets('a tech listed twice for one day (two visits) is shown once', (t) async {
      _today(DateTime(2026, 10, 29));
      await _pump(t, _Server([_ev('2026-10-29', 'Twice Co', techs: 'Brett Hall, Marcus Lee, Brett Hall')]).client());
      await t.tap(find.text('Week'));
      await t.pumpAndSettle();
      expect(find.text('Brett Hall, Marcus Lee'), findsOneWidget);
    });

    testWidgets('a busy month opens on the week with today in it, and Today brings it back', (t) async {
      final handle = t.ensureSemantics();
      _today(DateTime(2026, 10, 29));
      // Real volume: about 16 visits on every weekday.
      final events = <Map<String, dynamic>>[
        for (var d = DateTime(2026, 9, 27); d.isBefore(DateTime(2026, 11, 8)); d = DateTime(d.year, d.month, d.day + 1))
          if (d.weekday <= 5)
            for (var i = 0; i < 16; i++) _ev(_ymd(d), 'Customer ${d.day}-$i'),
      ];
      await _pump(t, _Server(events).client());
      final today = find.bySemanticsLabel(RegExp(r'October 29, today'));
      expect(today, findsOneWidget);
      final top = t.getRect(today).top;
      expect(top, inInclusiveRange(60, 400), reason: "today's week is at the top of the grid, not four screens down");

      // Scroll back to the first week, then Today.
      await t.drag(find.byType(Scrollable).last, const Offset(0, 6000));
      await t.pumpAndSettle();
      expect(t.getRect(today).top, greaterThan(720));
      await t.tap(find.text('Today'));
      await t.pumpAndSettle();
      expect(t.getRect(today).top, inInclusiveRange(60, 400));
      handle.dispose();
    });
  });

  group('loading and failures', () {
    testWidgets("a month that failed to load says so, and never claims it shows the last data or that it is empty", (
      t,
    ) async {
      _today(DateTime(2026, 10, 29));
      var calls = 0;
      final client = MockClient((r) async {
        if (++calls == 1) {
          return http.Response(
            jsonEncode({
              'events': [_ev('2026-10-12', 'October Co'), _ev('2026-11-30', 'Late Nov Co')],
            }),
            200,
          );
        }
        throw http.ClientException('offline');
      });
      await _pump(t, client);
      expect(find.text('October Co'), findsOneWidget);
      Future<void> go(String tooltip, int times) => http.runWithClient(() async {
        for (var i = 0; i < times; i++) {
          await t.tap(find.byTooltip(tooltip));
          await t.pumpAndSettle();
        }
      }, () => client);

      // December: the window held for October (Sep 1 - Dec 1) still has Nov 29-30, the rest did not load.
      await go('Next month (→)', 2);
      expect(find.text('December 2026'), findsOneWidget);
      expect(find.text('Late Nov Co'), findsOneWidget, reason: 'the loaded days still show their events');
      expect(find.textContaining("Couldn't load all of December 2026"), findsOneWidget);
      expect(find.text('Not loaded'), findsWidgets, reason: 'each day the load missed says so');
      expect(find.textContaining('Showing the last loaded data'), findsNothing);
      expect(find.textContaining('Nothing scheduled'), findsNothing, reason: 'an unloaded month is not an empty month');

      // February: nothing on screen is loaded, so the grid itself says what happened, with Retry.
      await go('Next month (→)', 2);
      expect(find.text('February 2027'), findsOneWidget);
      expect(find.text("Couldn't load February 2027"), findsOneWidget);
      expect(find.text('Not loaded'), findsNothing, reason: 'said once on the grid, not in every day');
      expect(find.text('Retry'), findsOneWidget);
      expect(find.textContaining('Nothing scheduled'), findsNothing);

      // Back to a month that is held: the error goes and its events are there.
      await go('Previous month (←)', 4);
      expect(find.text('October 2026'), findsOneWidget);
      expect(find.text('October Co'), findsOneWidget);
      expect(find.textContaining("Couldn't"), findsNothing);
      expect(find.text('Not loaded'), findsNothing);
    });

    testWidgets('while a new week loads its days show placeholders, not "No events"', (t) async {
      _today(DateTime(2026, 10, 29));
      final slow = Completer<http.Response>();
      var calls = 0;
      final client = MockClient((r) {
        if (++calls == 1) return Future.value(http.Response(jsonEncode({'events': <dynamic>[]}), 200));
        return slow.future;
      });
      await _pump(t, client);
      await http.runWithClient(() async {
        await t.tap(find.text('Week'));
        await t.pumpAndSettle();
        for (var i = 0; i < 6; i++) {
          await t.tap(find.byTooltip('Next week (→)'));
          await t.pump();
        }
        await t.pump(const Duration(milliseconds: 300));
        expect(find.text('Dec 6 – 12, 2026'), findsOneWidget);
        expect(find.text('No events'), findsNothing);
        expect(find.byType(SkeletonPulse), findsWidgets);
        slow.complete(http.Response(jsonEncode({'events': <dynamic>[]}), 200));
        await t.pumpAndSettle();
      }, () => client);
      expect(find.text('No events'), findsNWidgets(7));
    });

    testWidgets('no access (403) says so and offers no Retry, since retrying cannot help', (t) async {
      _today(DateTime(2026, 10, 29));
      await _pump(t, MockClient((r) async => http.Response('{}', 403)));
      expect(find.textContaining("doesn't have access"), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
    });

    testWidgets('pressing Refresh again while it is loading does not send another request', (t) async {
      _today(DateTime(2026, 10, 29));
      final slow = Completer<http.Response>();
      var calls = 0;
      final client = MockClient((r) {
        if (++calls == 1) return Future.value(http.Response(jsonEncode({'events': <dynamic>[]}), 200));
        return slow.future;
      });
      await _pump(t, client);
      await http.runWithClient(() async {
        for (var i = 0; i < 4; i++) {
          await t.tap(find.byTooltip('Refresh'));
          await t.pump();
        }
        expect(calls, 2);
        slow.complete(http.Response(jsonEncode({'events': <dynamic>[]}), 200));
        await t.pumpAndSettle();
      }, () => client);
    });

    testWidgets('the 5-minute refresh pauses while another page is on top and catches up on return', (t) async {
      _today(DateTime(2026, 10, 29));
      final s = _Server();
      final active = ValueNotifier(true);
      Widget wrap(Widget child) => ValueListenableBuilder<bool>(
        valueListenable: active,
        builder: (_, on, c) => TickerMode(enabled: on, child: c!),
        child: child,
      );
      await _pump(t, s.client(), wrap: wrap);
      expect(s.asked, hasLength(1));
      await http.runWithClient(() async {
        active.value = false; // the user opened another page; the shell keeps the calendar alive behind it
        await t.pump();
        await t.pump(const Duration(minutes: 16));
        expect(s.asked, hasLength(1), reason: 'no polling for a page nobody is looking at');
        active.value = true;
        await t.pump();
        await t.pump();
        expect(s.asked, hasLength(2), reason: 'coming back after more than 5 minutes refreshes once');
        await t.pump(const Duration(minutes: 5, seconds: 1));
        expect(s.asked, hasLength(3), reason: 'and the regular refresh carries on');
      }, s.client);
    });
  });
}
