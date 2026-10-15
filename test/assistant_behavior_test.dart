// Behaviour checks for the Ask Jarvis panel: the saved thread, edit-and-resend, and stop.
// Run:  flutter test test/assistant_behavior_test.dart --update-goldens   (also writes test/shots/assistant_edit.png)

import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
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

String? _answerOverride;
final List<List<dynamic>> _sent = []; // the messages array of every request the fake server saw

Future<http.Response> _server(http.Request r) async {
  _sent.add((json.decode(r.body)['messages'] as List).map((m) => '${m['role']}: ${m['content']}').toList());
  return http.Response.bytes(
    utf8.encode(
      jsonEncode({
        'success': true,
        'answer': _answerOverride ?? 'Answer ${_sent.length}',
        'toolsUsed': ['jobs_summary'],
      }),
    ),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

Future<void> _pumpMs(WidgetTester t, int ms) async {
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
      debugShowCheckedModeBanner: false,
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
  await _pumpMs(tester, 500);
}

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', [r'C:\Windows\Fonts\segoeui.ttf', r'C:\Windows\Fonts\segoeuib.ttf', r'C:\Windows\Fonts\seguisb.ttf']);
    await _loadFont('Cambria', [r'C:\Windows\Fonts\cambria.ttc', r'C:\Windows\Fonts\cambriab.ttf']);
    await _loadFont('Georgia', [r'C:\Windows\Fonts\georgia.ttf', r'C:\Windows\Fonts\georgiab.ttf']);
    final root = Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter';
    await _loadFont('MaterialIcons', ['$root/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
  });

  // The chat is a process-wide singleton that loads its saved thread once, so these run in order in one file.
  testWidgets('a saved thread comes back when the panel opens', (tester) async {
    SharedPreferences.setMockInitialValues({
      'iohd_assistant_chat': json.encode({
        'user': '',
        'messages': [
          {'role': 'user', 'text': 'How many jobs are open?', 'sources': <String>[]},
          {
            'role': 'assistant',
            'text': 'There are 42 open jobs.',
            'sources': ['Jobs'],
          },
        ],
      }),
    });
    await http.runWithClient(() async {
      await _open(tester);
      expect(find.text('How many jobs are open?'), findsNWidgets(3)); // the thread, its sidebar entry and the header title
      expect(find.textContaining('42 open jobs'), findsOneWidget);
      expect(find.textContaining('Ask about jobs'), findsNothing);
    }, () => MockClient(_server));
  });

  testWidgets('editing a question replaces it and everything after it', (tester) async {
    _sent.clear();
    await http.runWithClient(() async {
      await _open(tester);
      // hover the question so the edit button shows, then press it
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.text('How many jobs are open?').last));
      await _pumpMs(tester, 300);
      await tester.tap(find.byTooltip('Edit and ask again'));
      await _pumpMs(tester, 300);
      await tester.enterText(find.byType(TextField).first, 'How many jobs are open this week?');
      await _pumpMs(tester, 100);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/assistant_edit.png'));
      await tester.tap(find.text('Send'));
      await _pumpMs(tester, 800);

      expect(_sent, hasLength(1));
      expect(_sent.single, ['user: How many jobs are open this week?']); // the old answer is not sent back
      expect(find.textContaining('42 open jobs'), findsNothing);
      expect(find.text('Answer 1'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }, () => MockClient(_server));

    final saved = json.decode((await SharedPreferences.getInstance()).getString('iohd_assistant_chat')!);
    expect((((saved['tabs'] as List).single as Map)['messages'] as List).map((m) => m['text']), [
      'How many jobs are open this week?',
      'Answer 1',
    ]);
  });

  testWidgets('the sidebar starts new chats, renames and deletes them', (tester) async {
    await http.runWithClient(() async {
      await _open(tester);
      await tester.tap(find.text('New chat').first);
      await _pumpMs(tester, 300);
      expect(find.textContaining('Ask about jobs'), findsOneWidget); // the new chat is empty
      expect(find.text('Answer 1'), findsNothing);
      expect(find.text('How many jobs are open this week?'), findsOneWidget); // the old chat is listed in the sidebar

      await tester.tap(find.byTooltip('Chat options').last);
      await _pumpMs(tester, 300);
      await tester.tap(find.text('Rename'));
      await _pumpMs(tester, 300);
      await tester.enterText(find.byType(TextField).last, 'Open jobs');
      await tester.tap(find.text('Save'));
      await _pumpMs(tester, 300);
      expect(find.text('Open jobs'), findsOneWidget);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/assistant_sidebar.png'));

      await tester.tap(find.byTooltip('Chat options').last);
      await _pumpMs(tester, 300);
      await tester.tap(find.text('Delete'));
      await _pumpMs(tester, 300);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await _pumpMs(tester, 300);
      expect(find.text('Open jobs'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }, () => MockClient(_server));
    final saved = json.decode((await SharedPreferences.getInstance()).getString('iohd_assistant_chat') ?? 'null');
    expect(saved, isNull); // only an empty chat is left
  });

  testWidgets('the panel scales with the window and can be dragged wider', (tester) async {
    await http.runWithClient(() async {
      await _open(tester);
      double panelWidth() => tester.getSize(find.byType(AnimatedContainer).first).width;
      expect(panelWidth(), closeTo(1400 * 0.62, 1));
      tester.view.physicalSize = const Size(1920, 900);
      await _pumpMs(tester, 400);
      expect(panelWidth(), closeTo(1920 * 0.62, 1)); // bigger window, bigger panel

      await tester.dragFrom(Offset(1920 - panelWidth() + 3, 400), const Offset(-200, 0));
      await _pumpMs(tester, 400);
      expect(panelWidth(), greaterThan(1920 * 0.62 + 150)); // the first ~20px of a drag is touch slop

      await tester.tap(find.byTooltip('Wide view')); // the button goes back to a share of the window
      await _pumpMs(tester, 400);
      expect(panelWidth(), closeTo(1920 * 0.92, 1));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }, () => MockClient(_server));
  });

  test('chats are capped', () {
    final chat = AssistantChat.instance..clear();
    for (var i = 0; i < AssistantChat.maxChats + 2; i++) {
      chat.messages.add(AssistantMessage(AssistantRole.user, 'q$i'));
      chat.newChat();
    }
    expect(chat.chats.length, AssistantChat.maxChats);
    expect(chat.canAddChat, isFalse);
    chat.clear();
  });

  testWidgets('Copy includes the stat cards as label: value lines', (tester) async {
    _answerOverride = '''Pool summary.

::: stats
\$19.74 | Total pool deposits
7 | Deposit entries
:::

Done.''';
    AssistantChat.instance.clear(); // earlier tests leave chats behind in the shared instance
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await http.runWithClient(() async {
      await _open(tester);
      await tester.enterText(find.byWidgetPredicate((w) => w is TextField && (w.decoration?.hintText ?? '').startsWith('Ask Jarvis')), 'pool?');
      await _pumpMs(tester, 100);
      await tester.tap(find.byTooltip('Send'));
      await _pumpMs(tester, 1500);
      await tester.tap(find.text('Copy').last);
      await _pumpMs(tester, 300);
      expect(copied, contains('Total pool deposits: \$19.74'));
      expect(copied, contains('Deposit entries: 7'));
      expect(copied, isNot(contains('::: stats')));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }, () => MockClient(_server));
    _answerOverride = null;
  });
}
