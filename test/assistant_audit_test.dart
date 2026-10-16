// Screenshots of the Ask Jarvis panel in less common states, for a visual formatting audit.
// Run:  flutter test test/assistant_audit_test.dart --update-goldens   (writes test/shots/audit_*.png)

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
    loader.addFont(Future.value(ByteData.view(File(p).readAsBytesSync().buffer)));
  }
  await loader.load();
}

String _reply = '';
int _status = 200;

Future<http.Response> _server(http.Request r) async => http.Response.bytes(
  utf8.encode(jsonEncode(_status == 200 ? {'success': true, 'answer': _reply, 'toolsUsed': ['jobs_summary', 'payroll_runs']} : {'success': false, 'error': 'The assistant could not answer right now.'})),
  _status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Future<void> _pump(WidgetTester t, int ms) async {
  for (var i = 0; i < ms ~/ 50; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Finder get _composer => find.byWidgetPredicate((w) => w is TextField && (w.decoration?.hintText ?? '').startsWith('Ask Jarvis'));

const _long = 'This is a deliberately long question that keeps going so that the user bubble has to wrap over several lines and we can see how the bubble, the sidebar title and the header title all cope with it when it is far longer than they were designed for';

Future<void> _scene(
  WidgetTester tester,
  String name,
  Size size, {
  String reply = 'Short answer.',
  int status = 200,
  String question = 'How many jobs are open?',
  bool ask = true,
  bool hideSidebar = false,
  String? typed,
  Future<void> Function()? after,
}) async {
  _reply = reply;
  _status = status;
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  AssistantChat.instance.clear();
  await http.runWithClient(() async {
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
        home: Scaffold(
          body: Builder(builder: (context) => Center(child: ElevatedButton(onPressed: () => showAssistantPanel(context), child: const Text('open')))),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await _pump(tester, 500);
    // the sidebar choice is remembered between opens, so only toggle when it differs
    final open = find.byTooltip('Hide chats').evaluate().isNotEmpty;
    if (hideSidebar == open) {
      await tester.tap(find.byTooltip(open ? 'Hide chats' : 'Show chats'));
      await _pump(tester, 400);
    }
    if (ask) {
      await tester.enterText(_composer, question);
      await _pump(tester, 100);
      await tester.tap(find.byTooltip('Send'));
      await _pump(tester, 3000);
    }
    if (typed != null) {
      await tester.enterText(_composer, typed);
      await _pump(tester, 300);
    }
    await after?.call();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/audit_$name.png'));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  }, () => MockClient(_server));
}

const _mixed = '''Here is a mixed answer with a number list, a table and a heading.

## Open work by status

1. First numbered item with **bold** text and enough words to wrap onto a second line in a narrow panel.
2. Second item.
3. Third item with `1095809012` as inline code.

| Customer | Jobs | Balance |
|---|---|---|
| Lennar Homes of California | 12 | \$45,200 |
| Schuber Mitchell Homes | 7 | \$12,300 |
| Rosedale Property Management | 3 | \$980 |

::: stats
12 | Open
\$58,480 | Balance
:::

> Quoted text the model might emit.

Closing paragraph.

::: followups
What changed since last week?
Which of these are over 60 days old?
Show me the top 3 as a chart
:::''';

void main() {
  AssistantChat.animateAnswers = false; // these mock servers send one JSON reply; do not wait for it to be typed out
  setUpAll(() async {
    await _loadFont('Segoe UI', [r'C:\Windows\Fonts\segoeui.ttf', r'C:\Windows\Fonts\segoeuib.ttf', r'C:\Windows\Fonts\seguisb.ttf']);
    final root = Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter';
    await _loadFont('MaterialIcons', ['$root/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('narrow window with sidebar', (t) => _scene(t, 'narrow_sidebar', const Size(700, 800), reply: _mixed));
  testWidgets('narrow window sidebar hidden', (t) => _scene(t, 'narrow_nosidebar', const Size(700, 800), reply: _mixed, hideSidebar: true));
  testWidgets('phone width', (t) => _scene(t, 'phone', const Size(420, 800), reply: _mixed, hideSidebar: true));
  testWidgets('mixed answer wide', (t) => _scene(t, 'mixed_wide', const Size(1500, 1100), reply: _mixed));
  testWidgets('long question', (t) => _scene(t, 'long_question', const Size(1400, 700), question: _long, reply: 'Understood.'));
  testWidgets('server error', (t) => _scene(t, 'error', const Size(1400, 600), status: 502));
  testWidgets('multi-line composer', (t) => _scene(t, 'multiline', const Size(1400, 700), ask: false, typed: 'Line one\nLine two\nLine three\nLine four\nLine five\nLine six\nLine seven'));
  testWidgets('long unsent text', (t) => _scene(t, 'longtext', const Size(1400, 700), ask: false, typed: _long * 3));
  testWidgets('empty narrow', (t) => _scene(t, 'empty_narrow', const Size(700, 800), ask: false));
  testWidgets('empty no sidebar', (t) => _scene(t, 'empty_nosidebar', const Size(1400, 800), ask: false, hideSidebar: true));
}
