// Behaviour checks for the newer Ask Jarvis features: page-aware suggestions, the page sent with a question, clickable
// job numbers, "How I got this", and thumbs up / down.
// Run:  flutter test test/assistant_features_test.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/widgets/assistant_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    final bytes = File(p).readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

final List<Map<String, dynamic>> _asked = []; // bodies of /api/assistant
final List<Map<String, dynamic>> _feedback = []; // bodies of /api/assistant/feedback

Future<http.Response> _server(http.Request r) async {
  final body = json.decode(r.body) as Map<String, dynamic>;
  Map<String, dynamic> out;
  if (r.url.path.endsWith('/feedback')) {
    _feedback.add(body);
    out = {'success': true};
  } else {
    _asked.add(body);
    out = {
      'success': true,
      'answer': 'Job [1096719829](job:1096719829) is the biggest one, worth **\$4,200**.',
      'toolsUsed': ['search_jobs', 'run_sql'],
      'calls': [
        {'tool': 'search_jobs', 'input': '{"query":"Lennar","year":2026,"limit":5}'},
        {'tool': 'run_sql', 'input': '{"sql":"SELECT 1","purpose":"Check the biggest job"}'},
        {'tool': 'describe_data', 'input': '{}'},
      ],
    };
  }
  return http.Response.bytes(utf8.encode(jsonEncode(out)), 200, headers: {'content-type': 'application/json; charset=utf-8'});
}

Future<void> _pump(WidgetTester t, int ms) async {
  for (var i = 0; i < ms ~/ 50; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _open(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1400, 860);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(onPressed: () => showAssistantPanel(context), child: const Text('open')),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await _pump(tester, 500);
}

/// Without a router above the panel the page is unknown, so set it as showAssistantPanel would and let the panel redraw.
Future<void> _fromPage(WidgetTester tester, String path) async {
  AssistantChat.instance.pagePath = path;
  AssistantChat.instance.renameChat(0, ''); // any change notifies the panel
  await _pump(tester, 100);
}

Finder get _composer => find.byWidgetPredicate((w) => w is TextField && (w.decoration?.hintText ?? '').startsWith('Ask Jarvis'));

void main() {
  AssistantChat.animateAnswers = false; // these mock servers send one JSON reply; do not wait for it to be typed out
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
    _feedback.clear();
    AssistantChat.instance.clear();
    AssistantChat.instance.pagePath = '';
    AssistantChat.instance.pageContext = '';
  });

  testWidgets('the welcome screen suggests questions for the page it was opened from', (tester) async {
    await http.runWithClient(() async {
      await _open(tester);
      await _fromPage(tester, '/dashboards/collections');
      expect(find.text('Over 90 days'), findsOneWidget); // collections-specific
      expect(find.text('Unpaid jobs'), findsOneWidget); // general ones fill the rest
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }, () => MockClient(_server));
  });

  testWidgets('a job page gets a "summarize this job" suggestion', (tester) async {
    await http.runWithClient(() async {
      await _open(tester);
      await _fromPage(tester, '/jobs/1096719829');
      expect(find.text('Summarize this job'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }, () => MockClient(_server));
  });

  testWidgets('the page, job links, How I got this and thumbs all work', (tester) async {
    await http.runWithClient(() async {
      await _open(tester);
      // Without a router above the panel the page is unknown; set it as showAssistantPanel would from a job page.
      AssistantChat.instance.pageContext = 'Job 1096719829 detail page';
      await tester.enterText(_composer, 'Which Lennar job is biggest?');
      await _pump(tester, 100);
      await tester.tap(find.byTooltip('Send'));
      await _pump(tester, 2000);

      expect(_asked.single['context'], 'Job 1096719829 detail page'); // sent with the question

      // The job number is a link, shown as plain text without the markdown.
      expect(find.text('1096719829'), findsOneWidget);
      expect(find.textContaining('(job:'), findsNothing);

      // "Checked ..." opens the list of lookups; housekeeping calls are left out.
      expect(find.text('How I got this'), findsNothing);
      await tester.tap(find.textContaining('Checked Jobs'));
      await _pump(tester, 200);
      expect(find.text('How I got this'), findsOneWidget);
      expect(find.textContaining('Jobs: query Lennar, year 2026'), findsOneWidget);
      expect(find.textContaining('Custom query: Check the biggest job'), findsOneWidget);
      expect(find.textContaining('describe'), findsNothing);

      // Thumbs up goes to the server once, with the question, and cannot be repeated.
      await tester.tap(find.byTooltip('Good answer'));
      await _pump(tester, 300);
      expect(_feedback, hasLength(1));
      expect(_feedback.single['rating'], 'up');
      expect(_feedback.single['question'], 'Which Lennar job is biggest?');
      await tester.tap(find.byTooltip('Not helpful'), warnIfMissed: false);
      await _pump(tester, 300);
      expect(_feedback, hasLength(1));

      // Tapping the job number closes the panel (there is no router in this test to navigate with).
      await tester.tap(find.text('1096719829'));
      await _pump(tester, 500);
      expect(_composer, findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }, () => MockClient(_server));
  });

  // A server that streams progress sends text/event-stream: "data: {json}" lines, then a done (or error) event.
  Future<void> ask(WidgetTester tester, String q) async {
    await tester.enterText(_composer, q);
    await _pump(tester, 100);
    await tester.tap(find.byTooltip('Send'));
  }

  String event(Map<String, dynamic> e) => 'data: ${jsonEncode(e)}\n\n';

  testWidgets('progress from the server replaces the generic thinking text, then the answer lands', (tester) async {
    final body = StreamController<List<int>>();
    final client = MockClient.streaming((req, _) async {
      return http.StreamedResponse(body.stream, 200, headers: {'content-type': 'text/event-stream; charset=utf-8'});
    });
    await http.runWithClient(() async {
      await _open(tester);
      await ask(tester, 'What is owed?');
      await _pump(tester, 200);

      body.add(utf8.encode(event({'type': 'status', 'text': 'Looking into it…'})));
      await _pump(tester, 300);
      expect(find.text('Looking into it…'), findsOneWidget);

      body.add(utf8.encode(': ping\n\n')); // heartbeats are ignored
      body.add(utf8.encode(event({'type': 'status', 'text': 'Checking what is owed…'})));
      await _pump(tester, 600);
      expect(find.text('Checking what is owed…'), findsOneWidget);
      expect(find.text('Looking into it…'), findsNothing);

      body.add(
        utf8.encode(
          event({
            'type': 'done',
            'status': 200,
            'success': true,
            'answer': 'You are owed **\$5**.',
            'toolsUsed': ['outstanding_balances'],
            'calls': [],
          }),
        ),
      );
      await body.close();
      await _pump(tester, 500);
      expect(find.textContaining('You are owed'), findsOneWidget);
      expect(find.text('Checking what is owed…'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }, () => client);
  });

  testWidgets('a stream that ends without an answer shows an error with retry', (tester) async {
    final client = MockClient.streaming((req, _) async {
      final body = Stream<List<int>>.fromIterable([
        utf8.encode(event({'type': 'status', 'text': 'Looking into it…'})),
      ]);
      return http.StreamedResponse(body, 200, headers: {'content-type': 'text/event-stream'});
    });
    await http.runWithClient(() async {
      await _open(tester);
      await ask(tester, 'What is owed?');
      await _pump(tester, 800);
      expect(find.textContaining('connection closed'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }, () => client);
  });

  testWidgets('an error event from the server shows its message', (tester) async {
    final client = MockClient.streaming((req, _) async {
      final body = Stream<List<int>>.fromIterable([
        utf8.encode(event({'type': 'error', 'status': 429, 'error': 'The assistant is busy. Try again in a moment.'})),
      ]);
      return http.StreamedResponse(body, 200, headers: {'content-type': 'text/event-stream'});
    });
    await http.runWithClient(() async {
      await _open(tester);
      await ask(tester, 'What is owed?');
      await _pump(tester, 800);
      expect(find.textContaining('assistant is busy'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }, () => client);
  });

  testWidgets('the answer is written out as it arrives, and half-finished blocks stay hidden', (tester) async {
    final body = StreamController<List<int>>();
    final client = MockClient.streaming((req, _) async {
      return http.StreamedResponse(body.stream, 200, headers: {'content-type': 'text/event-stream; charset=utf-8'});
    });
    void delta(String t) => body.add(utf8.encode(event({'type': 'delta', 'text': t})));
    await http.runWithClient(() async {
      await _open(tester);
      await ask(tester, 'What is owed?');
      await _pump(tester, 200);

      // a lookup turn's chatter is thrown away
      delta('Let me check');
      await _pump(tester, 200);
      expect(find.textContaining('Let me check'), findsOneWidget);
      body.add(utf8.encode(event({'type': 'reset'})));
      body.add(utf8.encode(event({'type': 'status', 'text': 'Checking what is owed…'})));
      await _pump(tester, 300);
      expect(find.textContaining('Let me check'), findsNothing);
      expect(find.text('Checking what is owed…'), findsOneWidget);

      // the answer starts writing; the status line gives way to it
      delta('You are owed ');
      delta('**\$5');
      await _pump(tester, 300);
      expect(find.textContaining('You are owed'), findsOneWidget);
      expect(find.textContaining('**'), findsNothing); // a half-typed bold marker is held back
      expect(find.text('Checking what is owed…'), findsNothing);
      // the pulsing mark stays under the text for as long as it is being written
      expect(find.bySemanticsLabel('Jarvis is still writing'), findsOneWidget);
      expect(find.byTooltip('Good answer'), findsNothing); // no buttons until it is done

      delta('** in total.\n\n::: chart\ntype: bar\ntitle: Owed\nJan | 1\n');
      await _pump(tester, 300);
      expect(find.textContaining('::: chart'), findsNothing); // an unfinished chart block is not shown as raw text
      expect(find.textContaining('type: bar'), findsNothing);
      expect(find.text('Drawing the chart…'), findsOneWidget); // and the person is told what is coming

      delta('Feb | 2\n:::\n');
      await _pump(tester, 300);
      expect(find.textContaining('::: chart'), findsNothing);

      final done = {
        'type': 'done',
        'status': 200,
        'success': true,
        'answer': 'You are owed **\$5** in total.',
        'toolsUsed': [],
        'calls': [],
      };
      body.add(utf8.encode(event(done)));
      await body.close();
      await _pump(tester, 3000); // the last of the text is still being written out when the stream ends
      expect(find.textContaining('You are owed'), findsOneWidget); // the live view was replaced, not duplicated
      expect(find.byTooltip('Good answer'), findsOneWidget); // buttons appear with the finished answer
      expect(find.bySemanticsLabel('Jarvis is still writing'), findsNothing); // and the mark is gone: it is finished

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }, () => client);
  });

  testWidgets('an answer that arrives in one burst is still written out gradually', (tester) async {
    const answer =
        'You are owed five dollars in total across three jobs, mostly from Lennar, and the oldest one is ninety five days old '
        'so it is worth chasing first. After that the next oldest is sixty days old and worth two dollars, then a thirty day one.';
    final body = StreamController<List<int>>();
    final client = MockClient.streaming((req, _) async {
      return http.StreamedResponse(body.stream, 200, headers: {'content-type': 'text/event-stream; charset=utf-8'});
    });
    await http.runWithClient(() async {
      await _open(tester);
      await ask(tester, 'What is owed?');
      await _pump(tester, 200);

      // everything lands within the same instant, like the log from the real server
      for (final w in answer.split(' ')) {
        body.add(utf8.encode(event({'type': 'delta', 'text': '$w '})));
      }
      await _pump(tester, 250);
      expect(find.textContaining('You are owed'), findsOneWidget); // started
      expect(find.textContaining('chasing first'), findsNothing); // but not all there yet
      expect(find.textContaining('thirty day one'), findsNothing);

      await _pump(tester, 3000);
      expect(find.textContaining('thirty day one'), findsOneWidget); // all written out

      final done = {'type': 'done', 'status': 200, 'success': true, 'answer': answer, 'toolsUsed': [], 'calls': []};
      body.add(utf8.encode(event(done)));
      await body.close();
      await _pump(tester, 800);
      expect(find.textContaining('thirty day one'), findsOneWidget); // one copy, now with its buttons
      expect(find.byTooltip('Good answer'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }, () => client);
  });

  testWidgets('a server that does not stream still gets its whole answer written out', (tester) async {
    AssistantChat.animateAnswers = true;
    addTearDown(() => AssistantChat.animateAnswers = false);
    await http.runWithClient(() async {
      await _open(tester);
      await ask(tester, 'Which Lennar job is biggest?');
      await _pump(tester, 600);
      // the plain JSON reply is typed out: begun but not finished a moment after it arrives
      expect(find.textContaining('is the biggest one, worth'), findsNothing);
      await _pump(tester, 3000);
      expect(find.textContaining('is the biggest one, worth'), findsOneWidget);
      expect(find.byTooltip('Good answer'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }, () => MockClient(_server));
  });

  testWidgets('a tiny chart or a single stat is shown as plain text, not drawn', (tester) async {
    final client = MockClient((req) async {
      const answer =
          'Two techs are booked.\n\n::: stats\n7 | Visits booked\n:::\n\n'
          '::: chart\ntype: bar\ntitle: Visits per tech\nformat: count\nHeather | 7\nBrett | 4\nNick | 3\n:::\n\nThat is it.';
      return http.Response.bytes(
        utf8.encode(jsonEncode({'success': true, 'answer': answer, 'toolsUsed': [], 'calls': []})),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    await http.runWithClient(() async {
      await _open(tester);
      await ask(tester, 'Who is booked?');
      await _pump(tester, 1500);
      expect(find.textContaining('Visits booked: 7'), findsOneWidget); // one stat -> a line of text
      expect(find.textContaining('Heather: 7'), findsOneWidget); // three bars -> a short list
      expect(find.textContaining('Nick: 3'), findsOneWidget);
      expect(find.textContaining('That is it.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }, () => client);
  });
}
