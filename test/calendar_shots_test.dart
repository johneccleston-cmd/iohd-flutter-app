// Renders the Calendar at the window sizes the office uses, with a realistic volume of work (about 16 visits on every
// weekday, as on the live schedule in Oct 2026), plus its loading, empty, error and keyboard states.
// Screenshots go to build/cal_shots/*.png for review. They are not goldens. Any layout overflow fails the test.
// Run:  flutter test test/calendar_shots_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:iohd_desktop/calendar_screen.dart';
import 'package:iohd_desktop/widgets/dashboard_data.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    if (!File(p).existsSync()) continue;
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

const _customers = [
  'Ridgeline Homes',
  'Harbor Freight Storage',
  'Oakmont Builders LLC',
  'Maple Creek Apartments',
  'Summit Commercial Group',
  'Delgado Residence',
  'Pine Hollow HOA',
  'Northwind Logistics',
  'Cedar Point Storage',
  'Whitfield, Heather & Tom',
  'Bluestem Construction',
  'Garcia Residence',
  'Lakeside Dental',
  'Ironwood Self Storage',
  'Patel Residence',
];
const _statuses = [
  'Need To Schedule',
  'Scheduled - Full Day',
  'Scheduled - Full Day',
  'Complete',
  'Partially Complete',
  'Delayed',
  'Need Deposit',
  'Need To Order',
  'Final Invoice Sent',
  'Appointment',
];
const _estStatuses = ['Estimate Requested', 'Estimate Provided', 'Estimate Follow Up'];
const _techs = ['Alex Moreno', 'Jamie Price', 'Sam Okafor', 'Riley Chen', 'Jordan Blake', 'Casey Hart', 'Drew Patel'];

List<Map<String, dynamic>> _realistic({int perWeekday = 16}) {
  final out = <Map<String, dynamic>>[];
  var k = 0;
  for (var d = DateTime(2026, 9, 1); d.isBefore(DateTime(2026, 12, 1)); d = DateTime(d.year, d.month, d.day + 1)) {
    final n = d.weekday <= 5 ? perWeekday - (d.day % 5) + 2 : (d.weekday == 6 ? 1 : 0);
    for (var i = 0; i < n; i++, k++) {
      final est = k % 6 == 0;
      out.add({
        'event_date': '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}',
        'job_number': '${1095800000 + k}',
        'customer_name': _customers[(k * 7) % _customers.length],
        'status': est ? _estStatuses[k % _estStatuses.length] : _statuses[k % _statuses.length],
        'techs': k % 9 == 0
            ? 'Unassigned'
            : (k % 4 == 0
                  ? '${_techs[k % _techs.length]}, ${_techs[(k + 3) % _techs.length]}'
                  : _techs[k % _techs.length]),
        'is_estimate': est,
        if (k % 11 == 0) ...{'time_start': '08:00', 'time_end': '10:00'},
      });
    }
  }
  return out;
}

final _shot = GlobalKey();

class _Errors {
  final list = <String>[];
}

Future<_Errors> _pump(
  WidgetTester t,
  Size size,
  http.Client Function() client, {
  double textScale = 1,
  Future<void> Function()? body,
  bool settle = true,
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final errors = _Errors();
  final previous = FlutterError.onError;
  FlutterError.onError = (d) {
    errors.list.add(d.exceptionAsString().split('\n').first);
  };
  try {
    await http.runWithClient(() async {
      await t.pumpWidget(
        MediaQuery(
          data: MediaQueryData(size: size, textScaler: TextScaler.linear(textScale)),
          child: RepaintBoundary(
            key: _shot,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
              home: const CalendarScreen(),
            ),
          ),
        ),
      );
      if (settle) {
        await t.pumpAndSettle();
      } else {
        await t.pump(const Duration(milliseconds: 400));
      }
      if (body != null) await body();
    }, client);
  } finally {
    FlutterError.onError = previous;
  }
  return errors;
}

Future<void> _save(WidgetTester t, String name) async {
  final boundary = _shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await t.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1.0);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory(const String.fromEnvironment('CAL_SHOT_DIR', defaultValue: 'build/cal_shots'))
      ..createSync(recursive: true);
    File('${dir.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

http.Client _ok(List<Map<String, dynamic>> events) =>
    MockClient((r) async => http.Response(jsonEncode({'events': events}), 200));

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', [
      'C:/Windows/Fonts/segoeui.ttf',
      'C:/Windows/Fonts/segoeuib.ttf',
      'C:/Windows/Fonts/seguisb.ttf',
    ]);
    await _loadFont('MaterialIcons', ['C:/src/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DashClock.debugOverride = () => DateTime(2026, 10, 29, 10, 30);
  });
  tearDown(() => DashClock.debugOverride = null);

  final events = _realistic();
  // Window sizes minus the app's top navigation (about 60px): what the calendar itself gets.
  const sizes = [
    (1920.0, 1020.0, 1.0),
    (1366.0, 708.0, 1.0),
    (1280.0, 660.0, 1.0),
    (1280.0, 660.0, 1.3),
    (1100.0, 660.0, 1.0),
    (1000.0, 660.0, 1.0),
    (800.0, 640.0, 1.0),
    (420.0, 740.0, 1.0),
  ];
  for (final s in sizes) {
    final name = '${s.$1.toInt()}x${s.$2.toInt()}${s.$3 == 1 ? '' : '_text${(s.$3 * 100).round()}'}';
    testWidgets('month and week at $name', (t) async {
      final errors = await _pump(
        t,
        Size(s.$1, s.$2),
        () => _ok(events),
        textScale: s.$3,
        body: () async {
          await _save(t, 'month_$name');
          await t.tap(find.text('Week'));
          await t.pumpAndSettle();
          await _save(t, 'week_$name');
        },
      );
      expect(errors.list, isEmpty);
    });
  }

  // The window sizes the visual polish pass is judged at (the calendar gets the window less the ~60px top nav), each
  // with a hover preview open on a month chip. Run with --dart-define=CAL_SHOT_DIR=... to keep before/after sets apart.
  for (final w in const [(1280.0, 720.0), (1366.0, 768.0), (1500.0, 800.0), (1920.0, 940.0)]) {
    final name = 'win_${w.$1.toInt()}x${w.$2.toInt()}';
    testWidgets('polish set at $name', (t) async {
      final errors = await _pump(
        t,
        Size(w.$1, w.$2 - 60),
        () => _ok(events),
        body: () async {
          await _save(t, '${name}_month');
          final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
          await mouse.addPointer(location: Offset.zero);
          addTearDown(mouse.removePointer);
          await mouse.moveTo(t.getCenter(find.text('Lakeside Dental').hitTestable().first));
          await t.pump(const Duration(milliseconds: 600));
          await t.pumpAndSettle();
          await _save(t, '${name}_hover');
          await mouse.moveTo(Offset.zero);
          await t.pumpAndSettle();
          await t.tap(find.text('Week'));
          await t.pumpAndSettle();
          await _save(t, '${name}_week');
        },
      );
      expect(errors.list, isEmpty);
    });
  }

  testWidgets('filters on, at the narrowest one-row width', (t) async {
    SharedPreferences.setMockInitialValues({
      'calendar_techs_': ['Alex Moreno'],
    });
    final errors = await _pump(
      t,
      const Size(1180, 660),
      () => _ok(events),
      body: () async {
        await t.tap(find.text('Jobs'));
        await t.pumpAndSettle();
        await _save(t, 'filters_1180x660');
        await t.tap(find.text('Week'));
        await t.pumpAndSettle();
        await _save(t, 'filters_week_1180x660');
      },
    );
    expect(errors.list, isEmpty);
  });

  testWidgets('a quiet month fits without scrolling', (t) async {
    final quiet = [
      for (final e in events)
        if (e['job_number'].hashCode % 7 == 0) e,
    ];
    final errors = await _pump(t, const Size(1366, 708), () => _ok(quiet), body: () => _save(t, 'quiet_1366x708'));
    expect(errors.list, isEmpty);
  });

  testWidgets('status menu and tech menu', (t) async {
    final errors = await _pump(
      t,
      const Size(1366, 708),
      () => _ok(events),
      body: () async {
        await t.tap(find.text('All statuses'));
        await t.pumpAndSettle();
        await _save(t, 'status_menu');
        await t.tap(find.byTooltip('Filter by status (select several)'));
        await t.pumpAndSettle();
        await t.tap(find.text('All techs'));
        await t.pumpAndSettle();
        await _save(t, 'tech_menu');
      },
    );
    expect(errors.list, isEmpty);
  });

  testWidgets('day dialog', (t) async {
    final handle = t.ensureSemantics();
    final errors = await _pump(
      t,
      const Size(1366, 708),
      () => _ok(events),
      body: () async {
        await t.tapAt(t.getTopLeft(find.bySemanticsLabel(RegExp(r'October 29, today'))) + const Offset(60, 12));
        await t.pumpAndSettle();
        await _save(t, 'day_dialog');
      },
    );
    handle.dispose();
    expect(errors.list, isEmpty);
  });

  testWidgets('keyboard focus ring on the toolbar', (t) async {
    final errors = await _pump(
      t,
      const Size(1366, 708),
      () => _ok(events),
      body: () async {
        for (var i = 0; i < 4; i++) {
          await t.sendKeyEvent(LogicalKeyboardKey.tab);
          await t.pump();
        }
        await t.pumpAndSettle();
        await _save(t, 'keyboard_focus');
      },
    );
    expect(errors.list, isEmpty);
  });

  testWidgets('first load in progress', (t) async {
    final never = Completer<http.Response>();
    final errors = await _pump(
      t,
      const Size(1366, 708),
      () => MockClient((r) => never.future),
      settle: false,
      body: () async {
        await _save(t, 'loading');
        never.complete(http.Response(jsonEncode({'events': <dynamic>[]}), 200));
        await t.pumpAndSettle();
      },
    );
    expect(errors.list, isEmpty);
  });

  testWidgets('first load failed, and no access', (t) async {
    var errors = await _pump(
      t,
      const Size(1366, 708),
      () => MockClient((r) async => throw http.ClientException('x')),
      body: () => _save(t, 'error_first_load'),
    );
    expect(errors.list, isEmpty);
    await t.pumpWidget(const SizedBox());
    errors = await _pump(
      t,
      const Size(1366, 708),
      () => MockClient((r) async => http.Response('{}', 403)),
      body: () => _save(t, 'error_forbidden'),
    );
    expect(errors.list, isEmpty);
  });

  testWidgets('a partly loaded month after a failed load', (t) async {
    var calls = 0;
    final errors = await _pump(
      t,
      const Size(1366, 708),
      () => MockClient((r) async {
        if (++calls == 1) return http.Response(jsonEncode({'events': events}), 200);
        throw http.ClientException('offline');
      }),
      body: () async {
        await t.tap(find.byTooltip('Next month (→)'));
        await t.pumpAndSettle();
        await _save(t, 'error_partial_nov');
        await t.tap(find.text('Week'));
        await t.pumpAndSettle();
        for (var i = 0; i < 2; i++) {
          await t.tap(find.byTooltip('Next week (→)'));
          await t.pumpAndSettle();
        }
        await _save(t, 'error_partial_week');
      },
    );
    expect(errors.list, isEmpty);
  });

  testWidgets('nothing scheduled, and filters that hide everything', (t) async {
    var errors = await _pump(t, const Size(1366, 708), () => _ok(const []), body: () => _save(t, 'empty'));
    expect(errors.list, isEmpty);
    await t.pumpWidget(const SizedBox());
    SharedPreferences.setMockInitialValues({
      'calendar_techs_': ['Nobody Here'],
    });
    errors = await _pump(t, const Size(1366, 708), () => _ok(events), body: () => _save(t, 'empty_filtered'));
    expect(errors.list, isEmpty);
  });
}
