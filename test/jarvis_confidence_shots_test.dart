// Review screenshots for the 2026-11-24 Jarvis pass (not goldens), written to <JARVIS_SHOTS_DIR or build/jarvis_shots>/confidence/:
// a catalog answer with product and service links and the table's Save CSV / Copy table buttons, the thumbs-down
// "What was wrong?" box, and "How I got this" with the newer lookups' names and a wrongly-asked lookup left out.
// Run:  flutter test test/jarvis_confidence_shots_test.dart

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

final String _dir = '${Platform.environment['JARVIS_SHOTS_DIR'] ?? 'build/jarvis_shots'}/confidence';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    final f = File(p);
    if (f.existsSync()) loader.addFont(Future.value(ByteData.view(f.readAsBytesSync().buffer)));
  }
  await loader.load();
}

const _answer = '''[Service | Tune-Up](service:sf%3Aservice%20%7C%20tune-up) is \$149, and 2 of the 3 garage door springs and openers asked about have a price.

| Product | Part number | Price | On hand |
|---|---|---|---|
| [Torsion Spring 250 x 2 x 30](product:12) | 4154066 | \$89.50 | 14 |
| [LiftMaster 8500W](product:13) | | Not set | 0 |
| [Bottom Seal 16ft](product:21) | BS16 | \$38.25 | 40 |

::: followups
Which other products have no price?
What does iStore supply?
:::''';

final List<Map<String, dynamic>> _events = [
  {'type': 'status', 'text': 'Looking into it…'},
  {'type': 'reset'},
  {'type': 'tool', 'id': 't0', 'name': 'run_sql', 'input': '{"sql":"SELECT * FROM catalog","purpose":"Products"}', 'state': 'start', 'text': 'Running a custom query…'},
  {'type': 'tool', 'id': 't0', 'name': 'run_sql', 'state': 'done', 'ok': true, 'skip': true, 'ms': 12},
  {'type': 'tool', 'id': 't1', 'name': 'catalog_lookup', 'input': '{"query":"tune-up","kind":"services"}', 'state': 'start', 'text': 'Checking the price list…'},
  {'type': 'tool', 'id': 't1', 'name': 'catalog_lookup', 'state': 'done', 'ok': true, 'ms': 380},
  {'type': 'tool', 'id': 't2', 'name': 'catalog_lookup', 'input': '{"query":"spring opener seal","kind":"products","missing":"price"}', 'state': 'start', 'text': 'Checking the price list…'},
  {'type': 'tool', 'id': 't2', 'name': 'catalog_lookup', 'state': 'done', 'ok': true, 'ms': 240},
  {'type': 'tool', 'id': 't3', 'name': 'door_counts', 'input': '{"start_from":"2026-10-28","customer":["Lennar","Schuber Mitchell"]}', 'state': 'start', 'text': 'Counting doors on open jobs…'},
  {'type': 'tool', 'id': 't3', 'name': 'door_counts', 'state': 'done', 'ok': true, 'ms': 610},
  {'type': 'delta', 'text': _answer},
  {
    'type': 'done',
    'status': 200,
    'success': true,
    'answer': _answer,
    'toolsUsed': ['catalog_lookup', 'catalog_lookup', 'door_counts'],
    'calls': [
      {'tool': 'catalog_lookup', 'input': '{"query":"tune-up","kind":"services"}', 'ok': true, 'ms': 380},
      {'tool': 'catalog_lookup', 'input': '{"query":"spring opener seal","kind":"products","missing":"price"}', 'ok': true, 'ms': 240},
      {'tool': 'door_counts', 'input': '{"start_from":"2026-10-28","customer":["Lennar","Schuber Mitchell"]}', 'ok': true, 'ms': 610},
    ],
    'lookups': [
      {'tool': 'catalog_lookup', 'input': '{"query":"tune-up","kind":"services"}'},
    ],
    'links': [],
    'logId': '7',
  },
];

final List<Map<String, Object?>> _feedback = [];

MockClient _server() => MockClient.streaming((req, body) async {
  final sent = await body.bytesToString();
  if (req.url.path.endsWith('/feedback')) {
    _feedback.add(json.decode(sent) as Map<String, Object?>);
    return http.StreamedResponse(Stream.value(utf8.encode('{"success":true,"saved":true}')), 200, headers: {'content-type': 'application/json'});
  }
  List<int> ev(Map<String, dynamic> e) => utf8.encode('data: ${jsonEncode(e)}\n\n');
  return http.StreamedResponse(Stream.fromIterable(_events.map(ev)), 200, headers: {'content-type': 'text/event-stream'});
});

final _shotKey = GlobalKey();

Future<void> _pump(WidgetTester t, int ms) async {
  for (var i = 0; i < ms ~/ 50; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
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

void main() {
  AssistantChat.animateAnswers = false;
  AssistantChat.now = () => DateTime(2026, 11, 24, 9, 5);

  setUpAll(() async {
    await _loadFont('Segoe UI', [r'C:\Windows\Fonts\segoeui.ttf', r'C:\Windows\Fonts\segoeuib.ttf', r'C:\Windows\Fonts\seguisb.ttf']);
    final root = Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter';
    await _loadFont('MaterialIcons', ['$root/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AssistantChat.instance.clear();
    _feedback.clear();
  });

  testWidgets('a catalog answer, a thumbs-down with a note, and How I got this', (tester) async {
    await http.runWithClient(() async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1400, 900);
      addTearDown(tester.view.reset);
      Widget page(BuildContext context, GoRouterState state) => Scaffold(
        backgroundColor: const Color(0xFFE2E8F0),
        body: Center(child: ElevatedButton(onPressed: () => showAssistantPanel(context), child: const Text('open'))),
      );
      final router = GoRouter(initialLocation: '/inventory/catalog', routes: [GoRoute(path: '/inventory/catalog', builder: page)]);
      await tester.pumpWidget(
        RepaintBoundary(
          key: _shotKey,
          child: MaterialApp.router(debugShowCheckedModeBanner: false, theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true), routerConfig: router),
        ),
      );
      await tester.tap(find.text('open'));
      await _pump(tester, 600);
      expect(AssistantChat.instance.pageContext, 'Product Catalog');
      await _save(tester, '01_welcome_product_catalog');

      final box = find.byWidgetPredicate((w) => w is TextField && (w.decoration?.hintText ?? '').startsWith('Ask Jarvis'));
      await tester.enterText(box, 'What do we charge for a tune-up, and which springs and openers have a price?');
      await _pump(tester, 100);
      await tester.tap(find.byTooltip('Send'));
      await _pump(tester, 300);
      for (var ms = 0; ms < 20000 && AssistantChat.instance.busy; ms += 50) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await _pump(tester, 600);

      final answer = AssistantChat.instance.messages.last;
      expect(answer.logId, '7');
      expect(answer.lookups.map((l) => l.tool), ['catalog_lookup', 'catalog_lookup', 'door_counts'], reason: 'the wrongly-asked query is not listed');
      expect(find.text('Save CSV'), findsOneWidget);
      expect(find.textContaining('Checked Products & Services · Doors on open jobs'), findsOneWidget);

      await tester.tap(find.byTooltip('Not helpful'));
      await _pump(tester, 300);
      expect(find.text('Send'), findsOneWidget);
      await tester.enterText(find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'What was wrong? (optional)'), 'The tune-up price is old');
      await _pump(tester, 200);
      await _save(tester, '02_answer_with_why_box');

      await tester.tap(find.text('Send'));
      await _pump(tester, 400);
      expect(_feedback.single['logId'], '7');
      expect(_feedback.single['note'], 'The tune-up price is old');
      expect(answer.rating, 'down');

      await tester.tap(find.textContaining('Checked Products & Services'));
      await _pump(tester, 600);
      await _save(tester, '03_how_i_got_this');

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }, _server);
  });
}
