// Scrolling the Jarvis thread while an answer is being typed: the reader stays where they scrolled to.
// Run:  flutter test test/assistant_scroll_test.dart

import 'dart:async';
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

Future<void> _pump(WidgetTester t, int ms) async {
  for (var i = 0; i < ms ~/ 50; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Finder get _composer => find.byWidgetPredicate((w) => w is TextField && (w.decoration?.hintText ?? '').startsWith('Ask Jarvis'));

String _event(Map<String, dynamic> e) => 'data: ${jsonEncode(e)}\n\n';

/// A long answer, so the thread is taller than the window while it is being written.
final String _long = [
  for (var i = 1; i <= 40; i++) 'Paragraph $i: the jobs in this group were closed on time and paid within the month, nothing more to chase.',
].join('\n\n');

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', [r'C:\Windows\Fonts\segoeui.ttf', r'C:\Windows\Fonts\segoeuib.ttf', r'C:\Windows\Fonts\seguisb.ttf']);
    final root = Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter';
    await _loadFont('MaterialIcons', ['$root/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AssistantChat.instance.clear();
    AssistantChat.instance.pagePath = '';
    AssistantChat.instance.pageContext = '';
  });

  testWidgets('scrolling up while Jarvis is typing is not undone by the next words or the finished answer', (tester) async {
    final body = StreamController<List<int>>();
    final client = MockClient.streaming((req, _) async {
      return http.StreamedResponse(body.stream, 200, headers: {'content-type': 'text/event-stream; charset=utf-8'});
    });
    await http.runWithClient(() async {
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

      await tester.enterText(_composer, 'How did the month go?');
      await _pump(tester, 100);
      await tester.tap(find.byTooltip('Send'));
      await _pump(tester, 200);

      // the whole answer arrives in a burst and is typed out over the next few seconds
      for (final w in _long.split(' ')) {
        body.add(utf8.encode(_event({'type': 'delta', 'text': '$w '})));
      }
      await _pump(tester, 1500);

      final pos = tester.state<ScrollableState>(find.byType(Scrollable).at(_threadIndex(tester))).position;
      expect(pos.maxScrollExtent, greaterThan(300), reason: 'the thread should be taller than the window by now');
      expect(pos.maxScrollExtent - pos.pixels, lessThan(2), reason: 'while nobody scrolls, it follows the words');

      // one small wheel notch up, well under the 160px that shows the "Latest" button
      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      final at = tester.getCenter(find.byType(Scrollable).at(_threadIndex(tester)));
      await tester.sendEventToBinding(mouse.hover(at));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, -60)));
      await tester.pump();
      final readingAt = pos.pixels;
      expect(pos.maxScrollExtent - readingAt, greaterThan(40));

      // more words are typed: the reader is left where they are
      await _pump(tester, 1000);
      expect(pos.pixels, readingAt, reason: 'the next words must not pull the reader back down');

      // the answer finishes: still left where they are
      body.add(
        utf8.encode(
          _event({'type': 'done', 'status': 200, 'success': true, 'answer': _long, 'toolsUsed': [], 'calls': []}),
        ),
      );
      await body.close();
      await _pump(tester, 12000);
      expect(AssistantChat.instance.busy, isFalse);
      expect(pos.pixels, readingAt, reason: 'the finished answer must not pull the reader back down');

      // scrolling back to the very bottom picks the following back up for the next question
      await tester.sendEventToBinding(mouse.scroll(Offset(0, pos.maxScrollExtent - pos.pixels + 50)));
      await _pump(tester, 300);
      expect(pos.maxScrollExtent - pos.pixels, lessThan(2));

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }, () => client);
  });
}

/// The thread is the tallest vertical Scrollable on screen (the chat list and composer are smaller).
int _threadIndex(WidgetTester tester) {
  final all = tester.stateList<ScrollableState>(find.byType(Scrollable)).toList();
  var best = 0;
  var bestH = -1.0;
  for (var i = 0; i < all.length; i++) {
    final p = all[i].position;
    if (p.axis != Axis.vertical || !p.hasContentDimensions) continue;
    if (p.maxScrollExtent > bestH) {
      bestH = p.maxScrollExtent;
      best = i;
    }
  }
  return best;
}
