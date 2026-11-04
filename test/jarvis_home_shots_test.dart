// Review screenshots of Jarvis (the welcome screen at the desktop sizes the app runs at, each question group, and
// answers drawn from the backend evaluation's event streams in test/fixtures/jarvis/), written to
// <JARVIS_SHOTS_DIR or build/jarvis_home_shots>/ (not goldens). Each scene also fails on any layout overflow.
// Run:  flutter test test/jarvis_home_shots_test.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/widgets/assistant_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

final String _dir = Platform.environment['JARVIS_SHOTS_DIR'] ?? 'build/jarvis_home_shots';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    final f = File(p);
    if (f.existsSync()) loader.addFont(Future.value(ByteData.view(f.readAsBytesSync().buffer)));
  }
  await loader.load();
}

List<Map<String, dynamic>> _events(String name) => [
  for (final e in (json.decode(File('test/fixtures/jarvis/$name.json').readAsStringSync())['events'] as List))
    e as Map<String, dynamic>,
];

/// What the fake server answers, one entry per question: a fixture name, or a StreamController the scene feeds.
final List<Object> _replies = [];

MockClient _server() => MockClient.streaming((req, body) async {
  await body.drain<void>();
  final r = _replies.isEmpty ? 'priorities' : _replies.removeAt(0);
  List<int> ev(Map<String, dynamic> e) => utf8.encode('data: ${jsonEncode(e)}\n\n');
  final Stream<Map<String, dynamic>> events = r is StreamController<Map<String, dynamic>>
      ? r.stream
      : Stream.fromIterable(_events(r as String));
  return http.StreamedResponse(events.map(ev), 200, headers: {'content-type': 'text/event-stream'});
});

final _shotKey = GlobalKey();

Future<void> _pump(WidgetTester t, int ms) async {
  for (var i = 0; i < ms ~/ 50; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _settle(WidgetTester t) async {
  await _pump(t, 300);
  for (var ms = 0; ms < 20000 && AssistantChat.instance.busy; ms += 50) {
    await t.pump(const Duration(milliseconds: 50));
  }
  await _pump(t, 600);
}

Future<void> _ask(WidgetTester tester, String q) async {
  final box = find.byWidgetPredicate((w) => w is TextField && (w.decoration?.hintText ?? '').startsWith('Ask Jarvis'));
  await tester.enterText(box, q);
  await _pump(tester, 100);
  await tester.tap(find.byTooltip('Send'));
}

Future<void> _save(WidgetTester tester, String name) async {
  final boundary = _shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1.0);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory(_dir)..createSync(recursive: true);
    File('${dir.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
  // Is any of it hidden below the fold? (The welcome screen scrolls, but at desktop sizes it should not need to.)
  for (final e in find.byType(Scrollable).evaluate()) {
    final p = ((e as StatefulElement).state as ScrollableState).position;
    if (p.axis == Axis.vertical && p.maxScrollExtent > 0) {
      debugPrint('$name: a vertical list scrolls by ${p.maxScrollExtent.toStringAsFixed(0)} px');
    }
  }
}

Future<void> _scene(
  WidgetTester tester,
  Size size,
  Future<void> Function() body, {
  String at = '/',
  double textScale = 1.0,
  bool wide = false,
  bool hideSidebar = false,
}) async {
  final errors = <String>[];
  final previous = FlutterError.onError;
  FlutterError.onError = (d) => errors.add(d.exceptionAsString());
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  try {
    await http.runWithClient(() async {
      Widget page(BuildContext context, GoRouterState state) => Scaffold(
        backgroundColor: const Color(0xFFE2E8F0),
        body: Center(
          child: ElevatedButton(onPressed: () => showAssistantPanel(context), child: const Text('open')),
        ),
      );
      final router = GoRouter(
        initialLocation: at,
        routes: [
          GoRoute(path: '/', builder: page),
          GoRoute(path: '/dashboards/collections', builder: page),
          GoRoute(path: '/hr/kpis/:id', builder: page),
        ],
      );
      await tester.pumpWidget(
        RepaintBoundary(
          key: _shotKey,
          child: MediaQuery(
            data: MediaQueryData(size: size, textScaler: TextScaler.linear(textScale)),
            child: MaterialApp.router(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
              routerConfig: router,
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await _pump(tester, 600);
      // the panel remembers its width and a hidden sidebar from an earlier scene
      if (wide != find.byTooltip('Narrow view').evaluate().isNotEmpty &&
          find.byTooltip(wide ? 'Wide view' : 'Narrow view').evaluate().isNotEmpty) {
        await tester.tap(find.byTooltip(wide ? 'Wide view' : 'Narrow view'));
        await _pump(tester, 500);
      }
      if (hideSidebar != find.byTooltip('Show chats').evaluate().isNotEmpty) {
        await tester.tap(find.byTooltip(hideSidebar ? 'Hide chats' : 'Show chats'));
        await _pump(tester, 400);
      }
      await body();
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }, _server);
  } finally {
    FlutterError.onError = previous;
  }
  expect(errors.where((e) => e.contains('overflowed')), isEmpty, reason: errors.join('\n'));
}

void main() {
  AssistantChat.animateAnswers = false;
  AssistantChat.now = () => DateTime(2026, 10, 27, 9, 5);

  setUpAll(() async {
    await _loadFont('Segoe UI', [
      r'C:\Windows\Fonts\segoeui.ttf',
      r'C:\Windows\Fonts\segoeuib.ttf',
      r'C:\Windows\Fonts\seguisb.ttf',
    ]);
    final root = Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter';
    await _loadFont('MaterialIcons', ['$root/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _replies.clear();
    AssistantChat.instance.clear();
    AssistantChat.instance.pagePath = '';
    AssistantChat.instance.pageContext = '';
  });

  // --- the welcome screen at the sizes the app runs at
  for (final (name, size) in [
    ('home_1280x720', const Size(1280, 720)),
    ('home_1366x768', const Size(1366, 768)),
    ('home_1440x900', const Size(1440, 900)),
    ('home_1920x1080', const Size(1920, 1080)),
  ]) {
    testWidgets(name, (t) => _scene(t, size, () => _save(t, name)));
  }
  testWidgets(
    'home_1920x1080_wide',
    (t) => _scene(t, const Size(1920, 1080), () => _save(t, 'home_1920x1080_wide'), wide: true),
  );
  testWidgets(
    'home_1024x700',
    (t) => _scene(t, const Size(1024, 700), () => _save(t, 'home_1024x700'), hideSidebar: true),
  );
  testWidgets(
    'home_text130',
    (t) => _scene(t, const Size(1440, 900), () => _save(t, 'home_text130_1440x900'), textScale: 1.3),
  );
  testWidgets(
    'home_text150',
    (t) => _scene(t, const Size(1100, 760), () => _save(t, 'home_text150_1100x760'), textScale: 1.5),
  );

  // --- opened from a page: its own questions, and the chip saying the page goes with the question
  testWidgets(
    'home_collections',
    (t) => _scene(t, const Size(1440, 900), () => _save(t, 'home_collections_1440x900'), at: '/dashboards/collections'),
  );
  testWidgets(
    'home_collections_1280',
    (t) => _scene(t, const Size(1280, 720), () => _save(t, 'home_collections_1280x720'), at: '/dashboards/collections'),
  );
  testWidgets(
    'home_kpi_page',
    (t) => _scene(t, const Size(1440, 900), () => _save(t, 'home_kpi_page_1440x900'), at: '/hr/kpis/12'),
  );

  // --- every question group
  testWidgets('groups', (t) {
    return _scene(t, const Size(1440, 900), () async {
      for (final g in ['Jobs', 'Sales', 'Team', 'Stock', 'Money']) {
        await t.tap(find.text(g));
        await _pump(t, 200);
        await _save(t, 'group_${g.toLowerCase()}');
      }
    });
  });

  // --- answers
  testWidgets('answer_normal', (t) {
    _replies.add('owed');
    return _scene(t, const Size(1440, 900), () async {
      await _ask(t, 'Which customers owe us the most money, especially overdue balances?');
      await _settle(t);
      await t.drag(find.byType(SingleChildScrollView).first, const Offset(0, 3000));
      await _pump(t, 600);
      await _save(t, 'answer_normal_1440x900');
    });
  });
  testWidgets('answer_table', (t) {
    _replies.add('stuck');
    return _scene(t, const Size(1440, 900), () async {
      await _ask(t, 'Which jobs are stuck, and what is holding them up?');
      await _settle(t);
      await _save(t, 'answer_table_end_1440x900'); // followed to its end as it was written
      await t.drag(find.byType(SingleChildScrollView).first, const Offset(0, 3000));
      await _pump(t, 600);
      await _save(t, 'answer_table_top_1440x900');
    });
  });
  testWidgets('answer_followup', (t) {
    _replies.addAll(['owed', 'compare']);
    return _scene(t, const Size(1280, 720), () async {
      await _ask(t, 'Which customers owe us the most money, especially overdue balances?');
      await _settle(t);
      await _ask(t, 'Compare this month with last month and explain the major differences.');
      await _settle(t);
      await _save(t, 'answer_followup_1280x720');
    }, at: '/dashboards/collections');
  });
  testWidgets('answer_generating', (t) {
    final live = StreamController<Map<String, dynamic>>();
    _replies.add(live);
    return _scene(t, const Size(1440, 900), () async {
      await _ask(t, "Give me today's priorities and tell me why each one matters.");
      await _pump(t, 300);
      var done = 0;
      for (final e in _events('priorities')) {
        if (e['type'] == 'delta') break;
        live.add(e);
        if (e['type'] == 'step' && e['state'] == 'done' && ++done == 6) break;
      }
      await _pump(t, 1200);
      await _save(t, 'answer_generating_1440x900');
      await live.close();
      await _pump(t, 600);
    });
  });
}
