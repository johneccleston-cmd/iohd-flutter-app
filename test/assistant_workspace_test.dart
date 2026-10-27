// Jarvis, round 2 (2026-10-27): the welcome workspace, the live checklist, priorities / comparisons / dates-and-definitions,
// links to records, errors with a way forward, the page chip, keyboard use and saved lookups.
//
// The answers are the backend evaluation's real event streams (test/fixtures/jarvis/*.json): the backend route ran the
// real lookups and SQL on a made-up company in a throwaway Postgres, with a scripted model, and saved what it sent the app.
// Regenerate them from the backend repo with:
//   TEST_DATABASE_URL=postgres://... JARVIS_TRANSCRIPTS_DIR=<this repo>/test/fixtures/jarvis node --test test/assistant_eval_sql.test.js
// Run:  flutter test test/assistant_workspace_test.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/widgets/assistant_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    final f = File(p);
    if (f.existsSync()) loader.addFont(Future.value(ByteData.view(f.readAsBytesSync().buffer)));
  }
  await loader.load();
}

Map<String, dynamic> _transcript(String name) =>
    json.decode(File('test/fixtures/jarvis/$name.json').readAsStringSync()) as Map<String, dynamic>;

List<int> _event(Map<String, dynamic> e) => utf8.encode('data: ${jsonEncode(e)}\n\n');

/// The fake server. Each request is answered by [_reply]: a live stream the test feeds ([_Live]), a whole transcript,
/// a JSON body with a status code, or an exception (no connection).
final List<Map<String, dynamic>> _asked = [];
Object? _reply;

class _Live {
  final controller = StreamController<List<int>>();
  void send(Map<String, dynamic> e) => controller.add(_event(e));
  Future<void> close() => controller.close();
}

MockClient _server() => MockClient.streaming((req, body) async {
  _asked.add(json.decode(await body.bytesToString()) as Map<String, dynamic>);
  final r = _reply;
  if (r is _Live) return http.StreamedResponse(r.controller.stream, 200, headers: {'content-type': 'text/event-stream'});
  if (r is Map<String, dynamic> && r['events'] is List) {
    final events = [for (final e in r['events'] as List) e as Map<String, dynamic>];
    return http.StreamedResponse(Stream.fromIterable(events.map(_event)), 200, headers: {'content-type': 'text/event-stream'});
  }
  if (r is (int, Map<String, dynamic>)) {
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(r.$2))),
      r.$1,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }
  throw const SocketException('no route to host');
});

Future<void> _pump(WidgetTester t, int ms) async {
  for (var i = 0; i < ms ~/ 50; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

/// Until the answer is in: a streamed answer is written out at a steady pace, and Jarvis stays busy until it is done.
Future<void> _settle(WidgetTester t) async {
  await _pump(t, 300);
  for (var ms = 0; ms < 20000 && AssistantChat.instance.busy; ms += 50) {
    await t.pump(const Duration(milliseconds: 50));
  }
  await _pump(t, 300);
}

late GoRouter _router;

/// The panel over a small app whose pages say where they are, so a link can be followed.
Future<void> _open(WidgetTester tester, {String at = '/', Size size = const Size(1400, 860), double textScale = 1.0}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  Widget page(BuildContext context, GoRouterState state) => Scaffold(
    body: Column(
      children: [
        Text('AT ${state.uri}'),
        ElevatedButton(onPressed: () => showAssistantPanel(context), child: const Text('open')),
      ],
    ),
  );
  _router = GoRouter(
    initialLocation: at,
    routes: [
      GoRoute(path: '/', builder: page),
      GoRoute(path: '/dashboards/collections', builder: page),
      GoRoute(path: '/jobs/:id', builder: page),
      GoRoute(path: '/estimates/:id', builder: page),
      GoRoute(path: '/customers', builder: page),
      GoRoute(path: '/customers/:id', builder: page),
      GoRoute(path: '/inventory', builder: page),
    ],
  );
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(size: size, textScaler: TextScaler.linear(textScale)),
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
        routerConfig: _router,
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await _pump(tester, 500);
}

Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

final Finder _composer = find.byWidgetPredicate((w) => w is TextField && (w.decoration?.hintText ?? '').startsWith('Ask Jarvis'));

Future<void> _ask(WidgetTester tester, String q) async {
  await tester.enterText(_composer, q);
  await _pump(tester, 100);
  await tester.tap(find.byTooltip('Send'));
  await _pump(tester, 300);
}

String get _where => _router.routerDelegate.currentConfiguration.uri.toString();

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
    _asked.clear();
    _reply = null;
    AssistantChat.instance.clear();
    AssistantChat.instance.pagePath = '';
    AssistantChat.instance.pageContext = '';
  });

  testWidgets('the welcome screen leads with the briefing, then this page\'s questions, then what else Jarvis can look up', (
    tester,
  ) async {
    _reply = _transcript('inventory');
    await http.runWithClient(() async {
      await _open(tester, at: '/dashboards/collections');
      expect(find.text('Good morning'), findsOneWidget);
      expect(find.text('Today’s priorities'), findsOneWidget);
      expect(find.textContaining('what changed since yesterday'), findsOneWidget, reason: 'a Tuesday looks back one day');
      expect(find.text('For the Collections dashboard'), findsOneWidget);
      expect(find.text('Over 90 days'), findsOneWidget);
      expect(find.text('Explore what Jarvis can look up'), findsOneWidget);
      for (final area in ['Money', 'Jobs', 'Sales', 'Team', 'Stock']) {
        expect(find.text(area), findsOneWidget);
      }
      expect(find.text('Who owes us'), findsOneWidget, reason: 'Money is the first group');
      await tester.tap(find.text('Stock'));
      await _pump(tester, 200);
      expect(find.text('Upcoming shortages'), findsOneWidget);
      expect(find.text('Who owes us'), findsNothing);
      await tester.tap(find.text('Upcoming shortages'));
      await _settle(tester);
      final sent = _asked.single;
      expect((sent['messages'] as List).last['content'], 'What inventory issues could affect upcoming jobs?');
      expect(sent['context'], 'Collections dashboard');
      expect(sent['stream'], isTrue);
      expect(sent['formats'], ['priorities', 'compare', 'basis'], reason: 'so the server sends the blocks this build draws');
      expect(find.textContaining('Two items are short for work booked'), findsOneWidget);
      await tester.tap(find.byTooltip('New chat'));
      await _pump(tester, 300);
      expect(find.text('Upcoming shortages'), findsOneWidget, reason: 'the group last looked at is kept');
      await _close(tester);
    }, _server);
  });

  testWidgets(
    'the daily briefing shows a live checklist of what it reads, then ranked priorities with reasons, links and definitions',
    (tester) async {
      final events = [for (final e in _transcript('priorities')['events'] as List) e as Map<String, dynamic>];
      final live = _Live();
      _reply = live;
      await http.runWithClient(() async {
        await _open(tester);
        await tester.tap(find.text('Today’s priorities'));
        await _pump(tester, 300);
        expect(
          (_asked.single['messages'] as List).last['content'],
          "Give me today's priorities and tell me why each one matters.",
        );

        // Up to the fifth section done: the briefing is running, five parts ticked off and five still being read.
        var doneSteps = 0;
        var i = 0;
        for (; i < events.length && doneSteps < 5; i++) {
          live.send(events[i]);
          if (events[i]['type'] == 'step' && events[i]['state'] == 'done') doneSteps++;
        }
        await _pump(tester, 400);
        expect(
          find.text('Pulling together today’s priorities…'),
          findsNothing,
          reason: 'the server phrase uses a straight apostrophe',
        );
        expect(find.text("Pulling together today's priorities…"), findsOneWidget);
        expect(find.textContaining('Daily briefing  · 5 of 10 parts'), findsOneWidget, reason: 'a running briefing counts its parts');
        for (final part in [
          'Today\'s schedule',
          'Stuck jobs',
          'Money owed',
          'Quiet estimates',
          'Materials for booked jobs',
          'Changes since Oct 26',
        ]) {
          expect(find.text(part), findsOneWidget, reason: part);
        }
        expect(find.bySemanticsLabel(RegExp(r'Daily briefing: 5 of 10 parts done')), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsWidgets);

        for (; i < events.length; i++) {
          live.send(events[i]);
        }
        await live.close();
        await _settle(tester);

        expect(find.text('Daily briefing'), findsNothing, reason: 'the checklist folds away once the answer is in');
        expect(find.text('High'), findsNWidgets(2));
        expect(find.text('Medium'), findsNWidgets(2));
        expect(find.text('Low'), findsOneWidget);
        expect(find.textContaining('Suggested: Order 3 today'), findsOneWidget);
        expect(find.textContaining('The biggest of 3 invoices over 60 days'), findsOneWidget);
        expect(find.text('Dates and definitions'), findsOneWidget);
        expect(find.textContaining('invoiced jobs (Final Invoice Sent or Check on Payment)'), findsOneWidget);
        expect(find.text('Which other jobs are stuck?'), findsOneWidget);
        expect(find.textContaining(':::'), findsNothing);
        expect(find.textContaining('](job:'), findsNothing);

        // What was looked up, how it went and how long it took
        expect(find.textContaining('Checked Daily briefing · 9:05 AM'), findsOneWidget);
        await tester.tap(find.textContaining('Checked Daily briefing'));
        await _pump(tester, 300);
        expect(find.text('How I got this'), findsOneWidget);
        expect(find.text('Looked up 9:05 AM'), findsOneWidget);
        expect(find.text('Daily briefing'), findsOneWidget);
        expect(find.text('Office tasks'), findsOneWidget, reason: 'its parts are listed');
        expect(find.textContaining(RegExp(r'^(<0\.1|\d+\.\d) s$')), findsWidgets);

        // "Ask more about this" asks about that priority
        expect(find.byTooltip('Ask more about this'), findsNWidgets(5));

        // The job named in the second priority opens its page
        await tester.ensureVisible(find.text('1095802214'));
        await _pump(tester, 300);
        await tester.tap(find.text('1095802214'));
        await _pump(tester, 600);
        expect(_where, '/jobs/1095802214');
        expect(find.text('Dates and definitions'), findsNothing, reason: 'the panel closed to show the job');
        await _close(tester);
      }, _server);
    },
  );

  testWidgets('record links open jobs, estimates, customers and pages; anything else stays plain text', (tester) async {
    const answer =
        'See [1095809931](estimate:1095809931), [Riverside Logistics](customer:Riverside Logistics), [their page](customer:20000002), '
        '[Inventory](page:inventory). Not links: [Pay now](https://pay.example.com/x), [admin](page:admin), [bad](job:../../etc), '
        '[script](javascript:alert(1)).';
    _reply = (200, {'success': true, 'answer': answer, 'toolsUsed': <String>[], 'calls': <Object>[]});
    await http.runWithClient(() async {
      for (final (label, where) in [
        ('1095809931', '/estimates/1095809931'),
        ('Riverside Logistics', '/customers?q=Riverside+Logistics'),
        ('their page', '/customers/20000002'),
        ('Inventory', '/inventory'),
      ]) {
        AssistantChat.instance.clear();
        await _open(tester);
        await _ask(tester, 'Links?');
        await _pump(tester, 1000);
        expect(find.byTooltip('Open estimate 1095809931'), findsOneWidget);
        expect(find.byTooltip('Find Riverside Logistics in Customers'), findsOneWidget);
        expect(find.textContaining('pay.example.com'), findsNothing, reason: 'a web link shows its words only');
        expect(find.textContaining('Pay now'), findsOneWidget);
        expect(find.byTooltip('Open admin'), findsNothing);
        expect(find.bySemanticsLabel(RegExp(r'^(Pay now|admin|bad|script)\. ')), findsNothing, reason: 'none of those are links');
        await tester.tap(find.text(label));
        await _pump(tester, 600);
        expect(_where, where, reason: label);
        await _close(tester);
      }
    }, _server);
  });

  testWidgets('a period comparison shows both periods, with an arrow, the sign and good-or-bad colour on each change', (
    tester,
  ) async {
    _reply = _transcript('compare');
    await http.runWithClient(() async {
      await _open(tester);
      await _ask(tester, 'Compare this month with last month and explain the major differences.');
      await _settle(tester);
      expect(find.text('October so far vs the same days of September'), findsOneWidget);
      expect(find.text('OCT 1–27'), findsOneWidget);
      expect(find.text('SEP 1–27'), findsOneWidget);
      expect(find.text('Cash collected'), findsOneWidget);
      expect(find.text(r'$19,405'), findsOneWidget);
      expect(find.bySemanticsLabel('+6%, better'), findsOneWidget);
      expect(find.bySemanticsLabel('-68.5%, worse'), findsOneWidget);
      expect(find.bySemanticsLabel('+200%, worse'), findsOneWidget, reason: 'more callbacks is bad news, whatever the sign');
      expect(find.byIcon(Icons.arrow_downward_rounded), findsWidgets);
      expect(find.textContaining('read low for October'), findsOneWidget);
      await _close(tester);
    }, _server);
  });

  testWidgets('a table of stuck jobs links each job, and the cell still sorts and copies as plain text', (tester) async {
    _reply = _transcript('stuck');
    await http.runWithClient(() async {
      await _open(tester);
      await _ask(tester, 'Which jobs are stuck, and what is holding them up?');
      await _settle(tester);
      expect(find.text('WHAT IS HOLDING IT UP'), findsOneWidget);
      expect(find.byTooltip('Open job 1095811020'), findsOneWidget);
      expect(find.textContaining('treated it as text only'), findsOneWidget);
      await tester.tap(find.text('1095811020'));
      await _pump(tester, 600);
      expect(_where, '/jobs/1095811020');
      await _close(tester);
    }, _server);
  });

  testWidgets('when part of a lookup could not be read, the answer says so under it and in How I got this', (tester) async {
    _reply = _transcript('partial');
    await http.runWithClient(() async {
      await _open(tester);
      await _ask(tester, 'Give me today\'s priorities');
      await _settle(tester);
      expect(find.textContaining('1 part not fully read'), findsOneWidget);
      await tester.tap(find.textContaining('1 part not fully read'));
      await _pump(tester, 300);
      expect(find.textContaining('partly read'), findsOneWidget);
      expect(find.bySemanticsLabel('Low stock, could not be read'), findsOneWidget);
      expect(find.bySemanticsLabel('Money owed, done'), findsOneWidget);
      await _close(tester);
    }, _server);
  });

  testWidgets('errors say what happened and what to do; Edit question puts it back in the box', (tester) async {
    await http.runWithClient(() async {
      _reply = (504, {'success': false, 'error': 'That took too long to work out. Try a narrower question.'});
      await _open(tester);
      await _ask(tester, 'Everything about every job ever');
      await _pump(tester, 800);
      expect(find.text('No answer in time'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      await tester.tap(find.text('Edit question'));
      await _pump(tester, 300);
      expect(tester.widget<TextField>(_composer).controller!.text, 'Everything about every job ever');
      expect(find.text('No answer in time'), findsNothing);
      expect(find.text('Today’s priorities'), findsOneWidget, reason: 'the failed question left the thread');

      _reply = (429, {'success': false, 'error': 'Too many questions. Please wait a minute.'});
      await tester.tap(find.byTooltip('Send'));
      await _pump(tester, 800);
      expect(find.text('Jarvis is busy'), findsOneWidget);

      _reply = (403, {'success': false, 'error': 'Admins only.'});
      await tester.tap(find.text('Try again'));
      await _pump(tester, 800);
      expect(find.text('No access'), findsOneWidget);
      expect(find.text('Try again'), findsNothing, reason: 'asking again cannot help');

      _reply = null; // the connection fails
      await _ask(tester, 'Hello?');
      await _pump(tester, 800);
      expect(find.text('No connection'), findsOneWidget);
      await _close(tester);
    }, _server);
  });

  testWidgets('Stop ends the question cleanly; the next one starts with an empty checklist', (tester) async {
    final events = [for (final e in _transcript('priorities')['events'] as List) e as Map<String, dynamic>];
    final live = _Live();
    _reply = live;
    await http.runWithClient(() async {
      await _open(tester);
      await tester.tap(find.text('Today’s priorities'));
      await _pump(tester, 300);
      for (final e in events.take(12)) {
        live.send(e);
      }
      await _pump(tester, 300);
      expect(find.textContaining(RegExp(r'^Daily briefing')), findsOneWidget);
      await tester.tap(find.byTooltip('Stop'));
      await _pump(tester, 300);
      expect(find.text('Stopped.'), findsOneWidget);
      expect(find.textContaining('Daily briefing'), findsNothing);
      expect(AssistantChat.instance.messages.where((m) => m.role == AssistantRole.assistant), isEmpty);
      await live.close();

      final next = _Live();
      _reply = next;
      await _ask(tester, 'How many jobs are open?');
      next.send({'type': 'status', 'text': 'Counting open jobs…'});
      await _pump(tester, 300);
      expect(AssistantChat.instance.live, isEmpty, reason: 'nothing left over from the stopped question');
      expect(find.textContaining('Daily briefing'), findsNothing);
      next.send({
        'type': 'done',
        'status': 200,
        'answer': 'There are 42 open jobs.',
        'toolsUsed': ['open_jobs_by_status'],
      });
      await next.close();
      await _pump(tester, 800);
      expect(find.text('There are 42 open jobs.'), findsOneWidget);
      await _close(tester);
    }, _server);
  });

  testWidgets('the page chip shows which page goes with the question, and switches it off and on', (tester) async {
    _reply = (200, {'success': true, 'answer': 'Okay.', 'toolsUsed': <String>[]});
    await http.runWithClient(() async {
      await _open(tester, at: '/dashboards/collections');
      expect(find.text('Using: Collections dashboard'), findsOneWidget);
      await _ask(tester, 'What is over 90 days here?');
      await _pump(tester, 800);
      expect(_asked.last['context'], 'Collections dashboard');
      await tester.tap(find.text('Using: Collections dashboard'));
      await _pump(tester, 200);
      expect(find.text('Use this page'), findsOneWidget);
      await _ask(tester, 'And in total?');
      await _pump(tester, 800);
      expect(_asked.last.containsKey('context'), isFalse);
      await tester.tap(find.text('Use this page'));
      await _pump(tester, 200);
      await _ask(tester, 'And this week?');
      await _pump(tester, 800);
      expect(_asked.last['context'], 'Collections dashboard');
      await _close(tester);
    }, _server);
  });

  testWidgets('a briefing run earlier today is offered again on the welcome screen, and Open it goes back to it', (tester) async {
    _reply = _transcript('priorities');
    await http.runWithClient(() async {
      await _open(tester);
      expect(find.text('Run briefing'), findsOneWidget);
      await tester.tap(find.text('Today’s priorities'));
      await _settle(tester);
      await tester.tap(find.byTooltip('New chat'));
      await _pump(tester, 300);
      expect(find.text('Last run 9:05 AM'), findsOneWidget);
      expect(find.text('Run again'), findsOneWidget);
      await tester.tap(find.text('Open it'));
      await _pump(tester, 500);
      expect(find.text('Dates and definitions'), findsOneWidget, reason: 'back on the briefing chat');
      await _close(tester);
    }, _server);
  });

  testWidgets('keyboard: Tab reaches the briefing and Enter runs it; a link opens with Enter; Ctrl+J and Esc close the panel', (
    tester,
  ) async {
    _reply = _transcript('estimates');
    await http.runWithClient(() async {
      await _open(tester);
      // Esc closes, Ctrl+J closes (the shell's Ctrl+J opens it)
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _pump(tester, 500);
      expect(find.text('Explore what Jarvis can look up'), findsNothing);
      await tester.tap(find.text('open'));
      await _pump(tester, 500);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await _pump(tester, 500);
      expect(find.text('Explore what Jarvis can look up'), findsNothing);

      await tester.tap(find.text('open'));
      await _pump(tester, 500);
      // Tab from the message box until the briefing card has focus, then Enter
      var found = false;
      for (var n = 0; n < 40 && !found; n++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final f = FocusManager.instance.primaryFocus?.context;
        found =
            f != null &&
            find.descendant(of: find.byWidget(f.widget), matching: find.text('Today’s priorities')).evaluate().isNotEmpty;
      }
      expect(found, isTrue, reason: 'the briefing card is a tab stop');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _settle(tester);
      expect((_asked.single['messages'] as List).last['content'], "Give me today's priorities and tell me why each one matters.");

      // a link is a tab stop too, and Enter follows it
      var onLink = false;
      for (var n = 0; n < 80 && !onLink; n++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        // the link's own focus, not the answer's selection area around it (which also contains the text)
        final f = FocusManager.instance.primaryFocus?.context;
        onLink = f?.findAncestorWidgetOfExactType<Tooltip>()?.message == 'Open estimate 1095810102';
      }
      expect(onLink, isTrue, reason: 'record links take focus');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _pump(tester, 600);
      expect(_where, '/estimates/1095810102');
      await _close(tester);
    }, _server);
  });

  testWidgets('saved chats keep each answer\'s lookups (with timings and parts) and the time it was looked up', (tester) async {
    _reply = _transcript('priorities');
    await http.runWithClient(() async {
      await _open(tester);
      await tester.tap(find.text('Today’s priorities'));
      await _settle(tester);
      await _close(tester);
    }, _server);
    final prefs = await SharedPreferences.getInstance();
    final saved = json.decode(prefs.getString('iohd_assistant_chat')!) as Map<String, dynamic>;
    final answer = ((saved['tabs'] as List).first['messages'] as List).last as Map<String, dynamic>;
    expect(answer['at'], startsWith('2026-10-27T09:05'));
    final lookup = (answer['lookups'] as List).single as Map<String, dynamic>;
    expect(lookup['tool'], 'daily_briefing');
    expect(lookup['ok'], isTrue);
    expect(lookup['ms'], isA<int>());
    expect((lookup['steps'] as List), hasLength(10));
    final back = AssistantLookup.fromJson(lookup);
    expect([back.tool, back.ok, back.partial, back.steps.length, back.running], ['daily_briefing', true, false, 10, false]);
  });

  for (final scale in [1.0, 1.5]) {
    testWidgets('text at ${(scale * 100).round()}% fits: the welcome screen, a priorities answer and a comparison', (
      tester,
    ) async {
      final errors = <String>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (d) => errors.add(d.exceptionAsString());
      try {
        await http.runWithClient(() async {
          await _open(tester, textScale: scale, size: const Size(1100, 760));
          _reply = _transcript('priorities');
          await tester.tap(find.text('Today’s priorities'));
          await _settle(tester);
          _reply = _transcript('compare');
          await _ask(tester, 'Compare this month with last month');
          await _settle(tester);
          await _close(tester);
        }, _server);
      } finally {
        FlutterError.onError = previous;
      }
      expect(errors.where((e) => e.contains('overflowed')), isEmpty);
    });
  }
}
