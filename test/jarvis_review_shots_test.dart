// Review screenshots of Jarvis, written to <JARVIS_SHOTS_DIR or build/jarvis_shots>/<JARVIS_SHOTS phase>/ (not goldens).
// The same scenes render with the current panel ("after": the backend evaluation's event streams in
// test/fixtures/jarvis/) or with a copy of the panel from before 2026-10-27's rework ("before": the same facts written
// the way the earlier prompt and lookups produced them). It only uses what both versions have, so it runs in either tree.
// Run:  JARVIS_SHOTS=after flutter test test/jarvis_review_shots_test.dart

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

final String _phase = Platform.environment['JARVIS_SHOTS'] ?? 'after';
final bool _after = _phase == 'after';
final String _dir = '${Platform.environment['JARVIS_SHOTS_DIR'] ?? 'build/jarvis_shots'}/$_phase';

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

// --- "before": what the earlier prompt asked for, from the same facts ---------------------------------------------------

const _beforePriorities = '''Five things need attention today.

::: stats
\$17,090 | Owed over 60 days
6 | Jobs stuck 14+ days
\$71,150 | Quiet estimates
:::

- **Order Clopay 16x7 White doors:** jobs booked in the next 7 days need 5 and only 2 are on hand.
- **Chase Northgate Property Group:** [1095802214](job:1095802214) owes \$9,860 and is 96 days old, on a 90 Day Notice.
- **Follow up on the Riverside Logistics estimate:** \$52,400 with no status change for 22 days.
- **Move [1095810231](job:1095810231) for Ozark Ridge Homes:** in Need To Order for 41 days.
- **Book [1095810877](job:1095810877) for Hartwell Builders:** Need To Schedule for 29 days.

Since Monday: \$8,555 collected and 5 status changes.

::: followups
Which other jobs are stuck?
Show every balance over 60 days
:::''';

const _beforeCompare =
    '''October so far is ahead of September on cash collected (up 6%) and jobs started, but completed revenue is well below it.

| Measure | Oct 1–27 | Sep 1–27 | Change |
|---|---|---|---|
| Cash collected | \$19,405 | \$18,300 | +6.04% |
| Jobs started | 11 | 10 | +10% |
| Completed revenue | \$13,050 | \$41,426 | -68.5% |
| Estimates created | 7 | 4 | +75% |
| Win rate | 50% | 66.67% | -16.67 pts |
| Expenses | \$5,520 | \$4,130 | +33.66% |
| Callback visits | 3 | 1 | +200% |

- Completed revenue and the win rate count jobs by today's status, so October reads low.
- 7 estimates were created worth \$89,300, against 4 worth \$49,250.

::: followups
Which October jobs are waiting to be invoiced?
Show cash collected by week
:::''';

const _beforeStuck = '''6 active jobs have been in the same status for 14 days or more. The oldest is [1095810231](job:1095810231) for Ozark Ridge Homes, 41 days in Need To Order.

| Job | Customer | Status | Days in status |
|---|---|---|---|
| 1095810231 | Ozark Ridge Homes | Need To Order | 41 |
| 1095810877 | Hartwell Builders | Need To Schedule | 29 |
| 1095811302 | Maple Street Bakery | Delayed | 26 |
| 1095806650 | Northgate Property Group | Check on Payment | 24 |
| 1095811020 | Bella Vista Dental | Partially Complete | 22 |
| 1095811500 | Lakeside Apartments | Need To Order | 15 |

The lookup shows each job's status and how long it has been there, not what is holding it up. Worth checking the two Need To Order jobs with the supplier.

::: followups
What is the Ozark Ridge job worth?
Show the status history of 1095810231
:::''';

const _beforeOwed =
    '''Northgate Property Group owes the most: \$18,240 across 3 invoices. In all, \$43,371 is owed on 8 invoiced jobs.

- **Northgate Property Group:** \$18,240 (3 jobs)
- **Riverside Logistics:** \$12,900 (1 job)
- **Cedar Creek HOA:** \$4,480 (1 job)
- **Lakeside Apartments:** \$3,615 (1 job)
- **Summit Storage Co:** \$2,750 (1 job)
- and 1 other, under \$1,400

Over 60 days: [1095802214](job:1095802214) (Northgate, \$9,860, 96 days), [1095804410](job:1095804410) (Cedar Creek, \$4,480, 74 days) and [1095801777](job:1095801777) (Summit, \$2,750, 119 days).

::: followups
Which of these are on a 90 Day Notice?
How fast does Northgate usually pay?
:::''';

/// What the earlier server sent for a question: progress lines, then the answer in pieces, then the reply.
List<Map<String, dynamic>> _beforeStream(String status, String answer, List<(String, String)> calls) => [
  {'type': 'status', 'text': 'Looking into it…'},
  {'type': 'reset'},
  {'type': 'status', 'text': status},
  {'type': 'status', 'text': 'Putting it together…'},
  for (final piece in RegExp(r'[\s\S]{1,8}').allMatches(answer)) {'type': 'delta', 'text': piece.group(0)},
  {
    'type': 'done',
    'status': 200,
    'success': true,
    'answer': answer,
    'toolsUsed': [for (final c in calls) c.$1],
    'calls': [
      for (final c in calls) {'tool': c.$1, 'input': c.$2},
    ],
  },
];

List<Map<String, dynamic>> _scene(String name) => switch ((name, _after)) {
  ('priorities', true) => _events('priorities'),
  ('priorities', false) => _beforeStream("Pulling together today's priorities…", _beforePriorities, [('daily_briefing', '{}')]),
  ('compare', true) => _events('compare'),
  ('compare', false) => _beforeStream('Comparing the two periods…', _beforeCompare, [('compare_periods', '{}')]),
  ('stuck', true) => _events('stuck'),
  ('stuck', false) => _beforeStream('Finding stuck jobs…', _beforeStuck, [('jobs_stuck', '{}')]),
  ('owed', true) => _events('owed'),
  ('owed', false) => _beforeStream('Checking what is owed…', _beforeOwed, [
    ('outstanding_balances', '{"group_by":"customer"}'),
    ('oldest_unpaid_jobs', '{"min_days":60,"order_by":"balance"}'),
  ]),
  _ => throw ArgumentError(name),
};

// --- the fake server and the app around the panel ------------------------------------------------------------------------

Object? _reply; // a list of events (sent at once), a StreamController (fed by the scene), or (status, body)

MockClient _server() => MockClient.streaming((req, body) async {
  await body.drain<void>();
  final r = _reply;
  List<int> ev(Map<String, dynamic> e) => utf8.encode('data: ${jsonEncode(e)}\n\n');
  if (r is List<Map<String, dynamic>>) {
    return http.StreamedResponse(Stream.fromIterable(r.map(ev)), 200, headers: {'content-type': 'text/event-stream'});
  }
  if (r is StreamController<Map<String, dynamic>>) {
    return http.StreamedResponse(r.stream.map(ev), 200, headers: {'content-type': 'text/event-stream'});
  }
  final (code, json_) = r as (int, Map<String, dynamic>);
  return http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(json_))), code, headers: {'content-type': 'application/json'});
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

Future<void> _open(WidgetTester tester, {String at = '/'}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1400, 860);
  addTearDown(tester.view.reset);
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
    ],
  );
  await tester.pumpWidget(
    RepaintBoundary(
      key: _shotKey,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
        routerConfig: router,
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await _pump(tester, 600);
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
}

Future<void> _done(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
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
    AssistantChat.instance.clear();
    AssistantChat.instance.pagePath = '';
    AssistantChat.instance.pageContext = '';
  });

  testWidgets('01 welcome', (tester) async {
    await http.runWithClient(() async {
      await _open(tester);
      await _save(tester, '01_welcome');
      await _done(tester);
    }, _server);
  });

  testWidgets('02 welcome from the Collections dashboard', (tester) async {
    await http.runWithClient(() async {
      await _open(tester, at: '/dashboards/collections');
      await _save(tester, '02_welcome_collections');
      await _done(tester);
    }, _server);
  });

  testWidgets('03 working on the briefing', (tester) async {
    final live = StreamController<Map<String, dynamic>>();
    _reply = live;
    await http.runWithClient(() async {
      await _open(tester);
      await _ask(tester, "Give me today's priorities and tell me why each one matters.");
      await _pump(tester, 300);
      if (_after) {
        var done = 0;
        for (final e in _events('priorities')) {
          if (e['type'] == 'delta') break;
          live.add(e);
          if (e['type'] == 'step' && e['state'] == 'done' && ++done == 6) break;
        }
      } else {
        live
          ..add({'type': 'status', 'text': 'Looking into it…'})
          ..add({'type': 'reset'})
          ..add({'type': 'status', 'text': "Pulling together today's priorities…"});
      }
      await _pump(tester, 1200);
      await _save(tester, '03_working');
      await live.close();
      await _done(tester);
    }, _server);
  });

  for (final (n, scene, question) in [
    ('04', 'priorities', "Give me today's priorities and tell me why each one matters."),
    ('05', 'compare', 'Compare this month with last month and explain the major differences.'),
    ('06', 'stuck', 'Which jobs are stuck, and what is holding them up?'),
    ('07', 'owed', 'Which customers owe us the most money, especially overdue balances?'),
  ]) {
    testWidgets('$n $scene', (tester) async {
      _reply = _scene(scene);
      await http.runWithClient(() async {
        await _open(tester);
        await _ask(tester, question);
        await _settle(tester);
        // a streamed answer is followed to its end as it is written; start the picture at the question
        await tester.drag(find.byType(SingleChildScrollView).first, const Offset(0, 3000));
        await _pump(tester, 600);
        await _save(tester, '${n}_$scene');
        if (scene == 'priorities') {
          // the rest of the answer, and "How I got this" opened
          await tester.drag(find.byType(SingleChildScrollView).first, const Offset(0, -3000));
          await _pump(tester, 600);
          await tester.tap(find.textContaining('Checked '));
          await _pump(tester, 600);
          await tester.drag(find.byType(SingleChildScrollView).first, const Offset(0, -3000));
          await _pump(tester, 600);
          await _save(tester, '${n}_${scene}_end');
        }
        await _done(tester);
      }, _server);
    });
  }

  testWidgets('08 a question that took too long', (tester) async {
    _reply = (
      504,
      {
        'success': false,
        'error': 'That took too long to work out. Try a narrower question, such as one year, one customer or one part of it.',
      },
    );
    await http.runWithClient(() async {
      await _open(tester);
      await _ask(tester, 'Show every job and payment since 2019, by customer and month.');
      await _settle(tester);
      await _save(tester, '08_error');
      await _done(tester);
    }, _server);
  });
}
