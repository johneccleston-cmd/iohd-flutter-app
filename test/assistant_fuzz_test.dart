// Feeds the Ask Jarvis panel awkward model replies (unclosed blocks, ragged tables, NaN chart values, very long
// words, ...) at narrow and wide sizes. Any exception, including a RenderFlex overflow, fails the test.
// Run:  flutter test test/assistant_fuzz_test.dart

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

String _reply = '';

Future<http.Response> _server(http.Request r) async => http.Response.bytes(
  utf8.encode(jsonEncode({'success': true, 'answer': _reply, 'toolsUsed': ['jobs_summary']})),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

final _long = 'Supercalifragilisticexpialidocious' * 6;

final Map<String, String> _cases = {
  'unclosed stats keeps the rest of the answer': 'Intro line.\n\n::: stats\n\$10 | Total\n5 | Jobs\n\nThis text must still show.\n\n- bullet after',
  'unclosed followups': 'Answer.\n\n::: followups\nAsk one\nAsk two',
  'unclosed chart': 'Answer.\n\n::: chart\ntype: bar\nJan | 1\nFeb | 2\n\nTrailing paragraph.',
  'empty stats block': 'Hello\n\n::: stats\n:::\n\nAfter.',
  'four stats with long labels': '::: stats\n\$1,234,567,890.12 | $_long\n12345678 | Another very long label that wraps over several lines in a narrow card\n99% | x\n-5 | y\n:::',
  'chart with NaN and Infinity': 'Chart:\n\n::: chart\ntype: line\nformat: money\nJan | NaN\nFeb | Infinity\nMar | 5\n:::',
  'chart with a single point': '::: chart\ntype: bar\nJan | 5\n:::\nok',
  'chart with all zeros': '::: chart\ntype: bar\nformat: money\nJan | 0\nFeb | 0\nMar | 0\n:::',
  'chart with huge and negative values': '::: chart\ntype: bar\nformat: money\nJan | 123456789012\nFeb | -987654321\nMar | 0.0001\n:::',
  'chart with 24+ points and long labels': '::: chart\ntype: hbar\ntitle: $_long\nformat: count\n${[for (var i = 0; i < 30; i++) '$_long$i | ${i * 3}'].join('\n')}\n:::',
  'ragged table': '| A | B | C |\n|---|---|---|\n| 1 |\n| 2 | 3 | 4 | 5 |\n| | | |',
  'single data row table': '| A | B |\n|---|---|\n| 1 | 2 |',
  'table with only a total row': '| Item | Amount |\n|---|---|\n| Total | \$5 |',
  'table with very long cells': '| Customer | Notes |\n|---|---|\n| $_long | $_long |\n| b | c |',
  'wide table of 9 columns': '| ${List.generate(9, (i) => 'Col$i').join(' | ')} |\n|${'---|' * 9}\n| ${List.generate(9, (i) => '\$${i * 1000}').join(' | ')} |\n| ${List.generate(9, (i) => 'x$i').join(' | ')} |',
  'table of 40 rows': '| Name | Value |\n|---|---|\n${[for (var i = 0; i < 40; i++) '| Row $i | \$${i * 10} |'].join('\n')}',
  'status table with odd status': '| Status | Jobs |\n|---|---|\n| ??? | 1 |\n| Final Invoice Sent | 2 |\n| | 3 |',
  'pipes inside text lines': 'a | b | c\n| not a table |\n|||',
  'very long unbroken word': 'Here is $_long and more.\n\n- bullet $_long\n\n## Heading $_long\n\n1. numbered $_long',
  'markdown the renderer does not know': 'Use `code` and *italic* and [link](http://x.y) and ~~strike~~.\n\n---\n\n> quote\n\n```\nblock\n```',
  'bold edge cases': '****\n**unclosed bold\n** spaced **\n**a****b**',
  'headings and lists edge cases': '#\n##\n###### too deep\n-\n- \n1.\n100. hundredth\n  - nested bullet\n    - deeper',
  'unicode and emoji': 'Total: \$5 ✅ — naïve café 日本語 العربية 👨‍👩‍👧‍👦',
  'only whitespace-ish': '\n\n   \n',
  'huge answer': List.generate(300, (i) => 'Paragraph $i with **bold** words and a number \$$i.').join('\n\n'),
  'stats value that is not a number': '::: stats\nabc | label\n | only label\nvalue |\n12.5.3 | odd\n:::',
  'followups that are very long': 'x\n\n::: followups\n$_long\n$_long ${_long}2\n- bulleted follow-up\n:::',
};

Future<void> _show(WidgetTester tester, String answer, Size size) async {
  _reply = answer;
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
          body: Builder(
            builder: (context) => Center(child: ElevatedButton(onPressed: () => showAssistantPanel(context), child: const Text('open'))),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.enterText(find.byWidgetPredicate((w) => w is TextField && (w.decoration?.hintText ?? '').startsWith('Ask Jarvis')), 'q');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byTooltip('Send'));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // scroll through the whole thread so every part is laid out
    final scrollable = find.byType(SingleChildScrollView).first;
    for (var i = 0; i < 6; i++) {
      await tester.drag(scrollable, const Offset(0, -900));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  }, () => MockClient(_server));
}

void main() {
  AssistantChat.animateAnswers = false; // these mock servers send one JSON reply; do not wait for it to be typed out
  setUpAll(() async {
    await _loadFont('Segoe UI', [r'C:\Windows\Fonts\segoeui.ttf', r'C:\Windows\Fonts\segoeuib.ttf', r'C:\Windows\Fonts\seguisb.ttf']);
    await _loadFont('Cambria', [r'C:\Windows\Fonts\cambria.ttc', r'C:\Windows\Fonts\cambriab.ttf']);
    final root = Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter';
    await _loadFont('MaterialIcons', ['$root/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final entry in _cases.entries) {
    for (final size in const [Size(700, 800), Size(1400, 860)]) {
      testWidgets('${entry.key} @ ${size.width.toInt()}', (tester) async {
        await _show(tester, entry.value, size);
      });
    }
  }

  testWidgets('unclosed stats block does not swallow the text after it', (tester) async {
    _reply = _cases.values.first;
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 860);
    addTearDown(tester.view.reset);
    AssistantChat.instance.clear();
    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
          home: Scaffold(
            body: Builder(builder: (context) => Center(child: ElevatedButton(onPressed: () => showAssistantPanel(context), child: const Text('open')))),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
      await tester.enterText(find.byWidgetPredicate((w) => w is TextField && (w.decoration?.hintText ?? '').startsWith('Ask Jarvis')), 'q');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byTooltip('Send'));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.textContaining('This text must still show.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }, () => MockClient(_server));
  });

  testWidgets('inline code, italic and links render without their markdown characters', (tester) async {
    _reply = 'Job `1095809012` is *late*, see [the job](http://x.y/z) and 5 * 3 * 2 stays.';
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 860);
    addTearDown(tester.view.reset);
    AssistantChat.instance.clear();
    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
          home: Scaffold(
            body: Builder(builder: (context) => Center(child: ElevatedButton(onPressed: () => showAssistantPanel(context), child: const Text('open')))),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.enterText(find.byWidgetPredicate((w) => w is TextField && (w.decoration?.hintText ?? '').startsWith('Ask Jarvis')), 'q');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byTooltip('Send'));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.textContaining('Job 1095809012 is late, see the job and 5 * 3 * 2 stays.', findRichText: true), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }, () => MockClient(_server));
  });
}
