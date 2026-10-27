// Checks for the Jarvis improvements of 2026-10-27: the "Today's priorities" suggestion and the labels for the new
// lookups, Google Drive links that open (while every other web link stays plain text), the customer page passed on as
// context, the notice for staff who are not admins, and a greeting that no longer depends on the hour the tests run.
// Run:  flutter test test/assistant_jarvis_test.dart   (add --update-goldens to write test/shots/jarvis_*.png)

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/config/auth_session.dart';
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

final List<Map<String, dynamic>> _asked = []; // bodies sent to /api/assistant
Map<String, dynamic> _reply = {};

Future<http.Response> _server(http.Request r) async {
  _asked.add(json.decode(r.body) as Map<String, dynamic>);
  return http.Response.bytes(utf8.encode(jsonEncode(_reply)), 200, headers: {'content-type': 'application/json; charset=utf-8'});
}

Future<void> _pump(WidgetTester t, int ms) async {
  for (var i = 0; i < ms ~/ 50; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

void _size(WidgetTester tester) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1400, 860);
  addTearDown(tester.view.reset);
}

final ThemeData _theme = ThemeData(fontFamily: 'Segoe UI', useMaterial3: true);

Future<void> _open(WidgetTester tester) async {
  _size(tester);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _theme,
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

Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

Finder _composer(String hintStart) =>
    find.byWidgetPredicate((w) => w is TextField && (w.decoration?.hintText ?? '').startsWith(hintStart));

/// Signs in through the saved-session path, as a page refresh would.
Future<void> _signIn({required bool admin}) async {
  AuthSession.instance.logout();
  final payload = base64Url.encode(utf8.encode(json.encode({'exp': DateTime(2100).millisecondsSinceEpoch})));
  SharedPreferences.setMockInitialValues({
    'iohd_auth_session': json.encode({
      'token': '$payload.sig',
      'name': 'Sam Example',
      'role': admin ? 'Admin' : 'Office Manager',
      'is_admin': admin,
      'denied': <String>[],
    }),
  });
  await AuthSession.instance.restore();
}

const _briefing = '''
Three things need attention today.

::: stats
\$22,577 | Owed over 90 days
6 | Jobs stuck 14+ days
3 | Estimates gone quiet
:::

- **Chase the oldest balance:** [1000000001](job:1000000001) for Acme Builders, \$4,200 and 112 days.
- **Schedule the stuck jobs:** four have sat in Need To Schedule for over three weeks.
- **Follow up on quiet estimates.** Suggestion: start with Northside Homes (\$52,000, no change in 18 days).

Their signed warranty terms are in [Warranty letter 2026](https://docs.google.com/document/d/abc123/edit).

::: followups
Show the jobs over 90 days
Which estimates have gone quiet?
:::''';

void main() {
  AssistantChat.animateAnswers = false; // the mock server sends one JSON reply; do not wait for it to be typed out
  AssistantChat.now = () => DateTime(2026, 10, 27, 14);

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
    AuthSession.instance.logout();
    SharedPreferences.setMockInitialValues({});
    _asked.clear();
    AssistantChat.instance.clear();
    AssistantChat.instance.pagePath = '';
    AssistantChat.instance.pageContext = '';
  });

  testWidgets('"Today’s priorities" asks for the daily briefing, and How I got this names the lookups behind it', (tester) async {
    _reply = {
      'success': true,
      'answer': _briefing,
      'toolsUsed': ['daily_briefing', 'compare_periods'],
      'calls': [
        {'tool': 'daily_briefing', 'input': '{}'},
        {'tool': 'compare_periods', 'input': '{"from":"2026-09-01","to":"2026-10-01"}'},
      ],
      'links': ['https://docs.google.com/document/d/abc123/edit'], // as if a Drive lookup had returned it
    };
    await http.runWithClient(() async {
      await _open(tester);
      expect(find.text('Today’s priorities'), findsOneWidget);
      await tester.tap(find.text('Today’s priorities'));
      await _pump(tester, 1500);

      final sent = (_asked.single['messages'] as List).last as Map;
      expect(sent['content'], "Give me today's priorities and tell me why each one matters.");

      expect(find.textContaining('Checked Daily briefing · Period comparison'), findsOneWidget);
      await tester.tap(find.textContaining('Checked Daily briefing'));
      await _pump(tester, 300);
      expect(find.text('How I got this'), findsOneWidget);
      expect(find.text('Daily briefing'), findsOneWidget);
      expect(find.textContaining('Period comparison  Sep 1 – Sep 30, 2026'), findsOneWidget);
      // the link shows its name, never the address
      expect(find.textContaining('Warranty letter 2026'), findsOneWidget);
      expect(find.textContaining('docs.google.com'), findsNothing);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/jarvis_briefing_answer.png'));
      await _close(tester);
    }, () => MockClient(_server));
  });

  testWidgets('only Drive links the server\'s own lookup returned open; every other link stays plain text', (tester) async {
    final opened = <Uri>[];
    final real = AssistantChat.openLink;
    AssistantChat.openLink = (uri) async {
      opened.add(uri);
      return true;
    };
    addTearDown(() => AssistantChat.openLink = real);
    _reply = {
      'success': true,
      'answer':
          'Here is the letter: [Warranty letter 2026](https://docs.google.com/document/d/abc123/edit)\n\n'
          '- [Lookalike](https://docs.google.com.evil.example/x)\n'
          '- [Plain web](http://docs.google.com/document/d/abc123)\n'
          '- [Outside site](https://evil.example.com/collect?d=balances)\n'
          '- [Planted doc](https://docs.google.com/document/d/planted/edit)\n' // right host, but no lookup returned it
          '- [Pay here](https://docs.google.com/forms/d/e/phish/viewform)',
      'toolsUsed': ['search_drive'],
      'calls': [
        {'tool': 'search_drive', 'input': '{"query":"warranty letter"}'},
      ],
      // what search_drive returned; the answer quotes it without the ?usp=drivesdk, which must still match
      'links': ['https://docs.google.com/document/d/abc123/edit?usp=drivesdk'],
    };
    final handle = tester.ensureSemantics();
    await http.runWithClient(() async {
      await _open(tester);
      await tester.enterText(_composer('Ask Jarvis'), 'Where is the warranty letter?');
      await _pump(tester, 100);
      await tester.tap(find.byTooltip('Send'));
      await _pump(tester, 1500);

      expect(find.textContaining('Checked Google Drive'), findsOneWidget);
      // Read out with its sentence (Flutter merges an inline widget into its paragraph), and announced as Google Drive.
      expect(find.bySemanticsLabel(RegExp(r'Warranty letter 2026, opens in Google Drive')), findsOneWidget);
      for (final label in ['Lookalike', 'Plain web', 'Outside site', 'Planted doc', 'Pay here']) {
        await tester.tap(find.textContaining(label));
        await _pump(tester, 100);
      }
      expect(opened, isEmpty, reason: 'only a Drive link the lookup returned may open');
      expect(find.textContaining('evil.example'), findsNothing);

      await tester.tap(find.textContaining('Warranty letter 2026'));
      await _pump(tester, 100);
      expect(opened.map((u) => u.toString()), ['https://docs.google.com/document/d/abc123/edit']);

      // saved with the thread, so the link still opens after a restart
      final saved = (await SharedPreferences.getInstance()).getString('iohd_assistant_chat') ?? '';
      expect(saved, contains('https://docs.google.com/document/d/abc123/edit?usp=drivesdk'));
      await _close(tester);
    }, () => MockClient(_server));
    handle.dispose();
  });

  testWidgets('a customer page is passed on as "Customer N detail page", so "this customer" can be looked up', (tester) async {
    _reply = {
      'success': true,
      'answer': 'They have spent \$4,000 with us.',
      'toolsUsed': ['customer_lookup'],
      'calls': [],
    };
    await http.runWithClient(() async {
      _size(tester);
      final router = GoRouter(
        initialLocation: '/customers/19234567',
        routes: [
          GoRoute(
            path: '/customers/:id',
            builder: (context, state) => Scaffold(
              body: Center(
                child: ElevatedButton(onPressed: () => showAssistantPanel(context), child: const Text('open')),
              ),
            ),
          ),
        ],
      );
      await tester.pumpWidget(MaterialApp.router(debugShowCheckedModeBanner: false, theme: _theme, routerConfig: router));
      await tester.tap(find.text('open'));
      await _pump(tester, 500);
      await tester.enterText(_composer('Ask Jarvis'), 'How much has this customer spent?');
      await _pump(tester, 100);
      await tester.tap(find.byTooltip('Send'));
      await _pump(tester, 1500);
      expect(_asked.single['context'], 'Customer 19234567 detail page');
      await _close(tester);
    }, () => MockClient(_server));
  });

  testWidgets('staff who are not admins are told Jarvis is for admins instead of getting a box that always fails', (
    tester,
  ) async {
    await _signIn(admin: false);
    await http.runWithClient(() async {
      await _open(tester);
      expect(find.textContaining('only for admin and owner accounts'), findsOneWidget);
      expect(find.text('Today’s priorities'), findsNothing);
      final box = tester.widget<TextField>(_composer('Jarvis is available'));
      expect(box.enabled, isFalse);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/jarvis_not_admin.png'));
      await _close(tester);
    }, () => MockClient(_server));
    expect(_asked, isEmpty);

    await _signIn(admin: true);
    await http.runWithClient(() async {
      await _open(tester);
      expect(tester.widget<TextField>(_composer('Ask Jarvis')).enabled, isTrue);
      expect(find.text('Good afternoon, Sam'), findsOneWidget);
      await _close(tester);
    }, () => MockClient(_server));
    AuthSession.instance.logout();
  });

  testWidgets('the greeting follows the clock it is given (so screenshots do not change with the hour)', (tester) async {
    addTearDown(() => AssistantChat.now = () => DateTime(2026, 10, 27, 14));
    for (final (hour, text) in [(9, 'Good morning'), (14, 'Good afternoon'), (19, 'Good evening')]) {
      AssistantChat.now = () => DateTime(2026, 10, 27, hour);
      await http.runWithClient(() async {
        await _open(tester);
        expect(find.text(text), findsOneWidget, reason: '$hour:00');
        await _close(tester);
      }, () => MockClient(_server));
    }
  });
}
