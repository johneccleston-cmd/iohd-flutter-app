// Probes the Calendar screen for UX/logic bugs: text scaling, tiny windows, load errors, empty data, and how the
// job and estimate status filters interact. Run:  flutter test test/calendar_audit_test.dart
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
import 'package:iohd_desktop/config/auth_session.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

String _today(int day) {
  final n = DateTime.now();
  return '${n.year}-${n.month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
}

List<Map<String, dynamic>> _events() => [
  for (var d = 1; d <= 20; d++) ...[
    {'event_date': _today(d), 'job_number': '10$d', 'customer_name': 'Customer number $d with a long name', 'status': 'Scheduled', 'techs': 'Brett Hall, Marcus Lee', 'is_estimate': false, 'time_start': '09:00:00', 'time_end': '11:00:00'},
    {'event_date': _today(d), 'job_number': '20$d', 'customer_name': 'Estimate customer $d', 'status': 'Scheduled', 'techs': '', 'is_estimate': true},
  ],
];

Future<void> _pump(WidgetTester t, Size size, http.Client Function() client, {double textScale = 1.0}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await http.runWithClient(() async {
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
        builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)), child: child!),
        home: const CalendarScreen(),
      ),
    );
    await t.pumpAndSettle();
  }, client);
}

http.Client _ok() => MockClient((r) async => http.Response(jsonEncode({'events': _events()}), 200));

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', ['C:/Windows/Fonts/segoeui.ttf', 'C:/Windows/Fonts/segoeuib.ttf']);
    await _loadFont('MaterialIcons', ['C:/src/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
  });

  for (final size in const [Size(360, 740), Size(800, 700), Size(1280, 720)]) {
    for (final scale in const [1.0, 1.3]) {
      testWidgets('no layout errors at ${size.width.toInt()}px, text x$scale', (t) async {
        await _pump(t, size, _ok, textScale: scale);
        expect(t.takeException(), isNull);
        await t.tap(find.text('Week'));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
      });
    }
  }

  testWidgets('a dropped connection shows a plain message, not the raw exception', (t) async {
    await _pump(t, const Size(1280, 720), () => MockClient((r) async => throw http.ClientException('Failed to fetch', r.url)));
    expect(find.textContaining('ClientException'), findsNothing);
    expect(find.textContaining('http'), findsNothing);
    expect(find.textContaining('connection'), findsWidgets);
  });

  testWidgets('403 says the account has no access, 500 says the server failed', (t) async {
    await _pump(t, const Size(1280, 720), () => MockClient((r) async => http.Response('{}', 403)));
    expect(find.textContaining("doesn't have access"), findsOneWidget);
    await t.pumpWidget(const SizedBox()); // a fresh screen, not the one that already failed
    await _pump(t, const Size(1280, 720), () => MockClient((r) async => http.Response('{}', 500)));
    expect(find.textContaining('500'), findsOneWidget);
  });

  testWidgets('no events at all shows the empty note and no filter legend', (t) async {
    await _pump(t, const Size(1280, 720), () => MockClient((r) async => http.Response(jsonEncode({'events': <dynamic>[]}), 200)));
    expect(find.text('Nothing scheduled this month'), findsOneWidget);
    expect(find.text('JOB STATUS'), findsNothing);
  });

  testWidgets('a job status and an estimate status with the same name are separate filters', (t) async {
    await _pump(t, const Size(1280, 720), _ok);
    await t.tap(find.text('All statuses')); // the status filter menu
    await t.pumpAndSettle();
    expect(find.text('JOB STATUS'), findsOneWidget);
    expect(find.text('ESTIMATE STATUS'), findsOneWidget);
    final scheduledChips = find.widgetWithText(CheckboxMenuButton, 'Scheduled');
    expect(scheduledChips, findsNWidgets(2));
    int chipCount() => find.byWidgetPredicate((w) => w is Tooltip && (w.message ?? '').contains('Techs: ')).evaluate().length;
    int estimateCount() => find.byWidgetPredicate((w) => w is Tooltip && (w.message ?? '').contains('(estimate)')).evaluate().length;
    final jobsBefore = chipCount(), estBefore = estimateCount();
    expect(estBefore, greaterThan(0));
    await t.tap(scheduledChips.first); // the job one (listed first)
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Filter by status (select several)')); // toggling the button closes the menu
    await t.pumpAndSettle();
    expect(estimateCount(), estBefore, reason: 'picking a job status must not hide estimates');
    expect(chipCount(), jobsBefore);
  });

  testWidgets('a slow load past 8 seconds explains that the server is waking up', (t) async {
    final never = Completer<http.Response>();
    t.view.physicalSize = const Size(1280, 720);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await http.runWithClient(() async {
      await t.pumpWidget(MaterialApp(theme: ThemeData(fontFamily: 'Segoe UI'), home: const CalendarScreen()));
      await t.pump(const Duration(seconds: 3));
      expect(find.textContaining('Waking up'), findsNothing);
      await t.pump(const Duration(seconds: 6));
      expect(find.textContaining('Waking up'), findsOneWidget);
      never.complete(http.Response(jsonEncode({'events': <dynamic>[]}), 200));
      await t.pumpAndSettle();
    }, () => MockClient((r) => never.future));
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));
  _techTests();
  _layoutTests();

  testWidgets('there is no loading popup, only the thin bar', (t) async {
    final never = Completer<http.Response>();
    t.view.physicalSize = const Size(1280, 720);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await http.runWithClient(() async {
      await t.pumpWidget(MaterialApp(theme: ThemeData(fontFamily: 'Segoe UI'), home: const CalendarScreen()));
      await t.pump(const Duration(seconds: 1));
      expect(find.text('Loading schedule…'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      never.complete(http.Response(jsonEncode({'events': <dynamic>[]}), 200));
      await t.pumpAndSettle();
    }, () => MockClient((r) => never.future));
  });

  testWidgets('each day is announced with its date and event count', (t) async {
    await _pump(t, const Size(1280, 720), _ok);
    final n = DateTime.now();
    final label = RegExp('${_weekday(DateTime(n.year, n.month, 5))}, ${_month(n.month)} 5, 2 events');
    expect(find.bySemanticsLabel(label), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r', today, ')), findsOneWidget);
  });

  testWidgets('nothing readable is under 12px except the EST badge', (t) async {
    await _pump(t, const Size(1280, 720), _ok);
    final small = <String>[];
    for (final w in t.widgetList<Text>(find.byType(Text))) {
      final size = w.style?.fontSize;
      if (size != null && size < 12 && w.data != 'EST') small.add('${w.data} ($size)');
    }
    expect(small, isEmpty);
  });

  testWidgets('a background refresh picks up new events without a spinner or an error', (t) async {
    var calls = 0;
    await _pump(t, const Size(1280, 720), () => MockClient((r) async {
      calls++;
      if (calls == 1) return http.Response(jsonEncode({'events': _events().take(2).toList()}), 200);
      if (calls == 2) return http.Response('{}', 500); // a failed background refresh must stay silent
      return http.Response(jsonEncode({'events': _events()}), 200);
    }));
    expect(find.text('Customer number 3 with a long name'), findsNothing);
    await t.pump(const Duration(minutes: 5, seconds: 1)); // refresh #1 fails quietly
    await t.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.textContaining('500'), findsNothing);
    await t.pump(const Duration(minutes: 5));
    await t.pump();
    expect(find.text('Customer number 3 with a long name'), findsWidgets);
  });

  testWidgets('the details dialog for an event with no job number hides ids and raw field names', (t) async {
    await _pump(t, const Size(1280, 720), () => MockClient((r) async => http.Response(jsonEncode({'events': [
      {'event_date': _today(10), 'customer_name': 'No Number Co', 'status': 'Scheduled', 'techs': 'Brett Hall', 'is_estimate': false,
       'time_start': '09:00:00', 'time_end': '11:00:00', 'visit_id': 991, 'created_at': '2026-01-01', 'crew_notes': 'Gate code 4411'},
    ]}), 200)));
    await t.tap(find.text('No Number Co'));
    await t.pumpAndSettle();
    expect(find.text('9:00–11:00 AM'), findsOneWidget);
    expect(find.text('Gate code 4411'), findsOneWidget);
    expect(find.textContaining('Visit Id'), findsNothing);
    expect(find.textContaining('Created At'), findsNothing);
    expect(find.textContaining('Time Start'), findsNothing);
  });
}

void _layoutTests() {
  testWidgets('a phone-width window shows a day-by-day list, a laptop window shows the grid', (t) async {
    await _pump(t, const Size(420, 800), _ok);
    expect(find.textContaining('2 events'), findsWidgets, reason: 'the agenda headers count each day');
    expect(t.takeException(), isNull);
    await _pump(t, const Size(1280, 720), _ok);
    expect(find.textContaining('2 events'), findsNothing, reason: 'the month grid has no such headers');
  });

  testWidgets('a saved tech with nothing in these months can still be unticked', (t) async {
    SharedPreferences.setMockInitialValues({
      'calendar_techs_${AuthSession.instance.name}': ['Gone Person'],
    });
    await _pump(t, const Size(1280, 720), _ok);
    await t.tap(find.text('Gone Person')); // the button itself names the saved tech
    await t.pumpAndSettle();
    expect(find.widgetWithText(CheckboxMenuButton, 'Gone Person'), findsOneWidget);
    expect(t.widget<CheckboxMenuButton>(find.widgetWithText(CheckboxMenuButton, 'Gone Person')).value, isTrue);
  });

  testWidgets('two techs with the same first name are told apart on the month chips', (t) async {
    SharedPreferences.setMockInitialValues({});
    await _pump(t, const Size(1920, 1000), () => MockClient((r) async => http.Response(jsonEncode({'events': [
      {'event_date': _today(10), 'job_number': '1', 'customer_name': 'Alpha Co', 'status': 'Scheduled', 'techs': 'Brett Hall', 'is_estimate': false},
      {'event_date': _today(10), 'job_number': '2', 'customer_name': 'Beta Co', 'status': 'Scheduled', 'techs': 'Brett Young', 'is_estimate': false},
      {'event_date': _today(11), 'job_number': '3', 'customer_name': 'Gamma Co', 'status': 'Scheduled', 'techs': 'Marcus Lee', 'is_estimate': false},
    ]}), 200)));
    expect(find.textContaining('Brett H.'), findsOneWidget);
    expect(find.textContaining('Brett Y.'), findsOneWidget);
    expect(find.textContaining('Marcus Lee'), findsNothing, reason: 'a first name nobody else shares stays short');
    expect(find.textContaining('Marcus'), findsOneWidget);
  });

  testWidgets('a failed background refresh says the schedule may be out of date', (t) async {
    var calls = 0;
    t.view.physicalSize = const Size(1280, 720);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await http.runWithClient(() async {
      await t.pumpWidget(MaterialApp(theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true), home: const CalendarScreen()));
      await t.pumpAndSettle();
      expect(find.textContaining('in the background'), findsNothing);
      await t.pump(const Duration(minutes: 5, seconds: 1)); // the timer fires, and the server is now down
      await t.pumpAndSettle();
      expect(find.textContaining("Couldn't refresh in the background"), findsOneWidget);
      expect(find.textContaining('Customer number 1 '), findsWidgets, reason: 'what was loaded stays on screen');
    }, () => MockClient((r) async {
      if (++calls > 1) throw http.ClientException('offline');
      return http.Response(jsonEncode({'events': _events()}), 200);
    }));
  });
}

void _techTests() {
  testWidgets('the chosen techs survive the refresh button and a reload of the screen', (t) async {
    SharedPreferences.setMockInitialValues({});
    await _pump(t, const Size(1280, 720), _ok);
    await t.tap(find.text('All techs'));
    await t.pumpAndSettle();
    await t.tap(find.text('Marcus Lee'));
    await t.pumpAndSettle();
    await t.tapAt(const Offset(600, 40)); // click away to close the menu
    await t.pumpAndSettle();
    expect(find.text('Marcus Lee'), findsOneWidget); // shown on the button

    await t.tap(find.byTooltip('Refresh'));
    await t.pumpAndSettle();
    expect(find.text('Marcus Lee'), findsOneWidget, reason: 'refresh keeps the selection');

    await t.pumpWidget(const SizedBox()); // leave the screen, as a page reload does
    await _pump(t, const Size(1280, 720), _ok);
    expect(find.text('Marcus Lee'), findsOneWidget, reason: 'a fresh screen restores the selection');
    expect(find.text('All techs'), findsNothing);

    await t.tap(find.text('Clear filters'));
    await t.pumpAndSettle();
    await t.pumpWidget(const SizedBox());
    await _pump(t, const Size(1280, 720), _ok);
    expect(find.text('All techs'), findsOneWidget, reason: 'clearing is remembered too');
  });
}

String _weekday(DateTime d) => const ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'][d.weekday - 1];
String _month(int m) => const ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'][m - 1];
