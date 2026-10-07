// Renders the Ask Jarvis panel with a fake /api/assistant answer and saves screenshots to test/shots/.
// Run:  flutter test test/assistant_render_test.dart --update-goldens
// Same approach as sales_render_test.dart (real Segoe UI, http MockClient via runWithClient).

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/widgets/assistant_panel.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    final bytes = File(p).readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

const _answer = '''154 of the 177 jobs that started in the last 30 days (Sep 6 – Oct 6, 2026) are not paid in full, worth **\$230,669** together.

::: stats
154 | Jobs not paid in full
\$230,669 | Total value
115 | Work done, not paid
:::

## By status

| Status | Jobs | Total value |
|---|---|---|
| Final Invoice Sent (awaiting payment) | 110 | \$124,164 |
| Complete | 5 | \$45,206 |
| Scheduled - Full Day | 24 | \$25,175 |
| Need Deposit | 2 | \$13,909 |
| Partially Complete | 1 | \$11,289 |
| Need To Schedule | 5 | \$6,969 |
| Delayed | 3 | \$2,886 |
| Manage Project | 2 | \$873 |
| Appointment | 2 | \$197 |
| Total | 154 | \$230,669 |

- **115 jobs** are "Final Invoice Sent" or "Complete", worth **\$169,370**.
- The other **39 jobs** are scheduled, delayed or waiting on a deposit.

I counted "Paid & Closed" (20) and "Close Job" (3) as paid.

::: followups
List the 110 invoiced jobs by customer
Which of these are over 30 days old?
Redo this for calendar September
:::''';


const _chartAnswer = '''June 2026 was the strongest month this year, with **\$441,040** in completed revenue and **\$248,334** in profit. Revenue fell in August and September.

::: stats
\$441,040 | June revenue
\$248,334 | June profit
\$2,419,397 | Year to date
:::

::: chart
type: line
title: Completed revenue and profit by month, 2026
format: money
series: Revenue | Profit
Jan | 213573 | 111840
Feb | 288891 | 125009
Mar | 246010 | 122201
Apr | 275572 | 128423
May | 285941 | 144019
Jun | 441040 | 248334
Jul | 323896 | 145098
Aug | 168586 | 92002
Sep | 156440 | 87657
Oct | 19448 | 10564
:::

::: chart
type: hbar
title: Biggest unpaid balances
format: money
Trinitas | 64358
Trulove Construction | 13506
Moser Construction LLC | 12821
Ideal Structures LLC | 11092
Adam's Home Inspections | 9999
:::

::: chart
type: bar
title: Win rate by month, 2026
format: percent
Jan | 83.3
Feb | 88.4
Mar | 91.7
Apr | 90.9
May | 96.3
Jun | 73.3
:::

::: chart
type: bar
title: September change vs August (%)
format: percent
Cash collected | -61.7
New customers | -28.1
Revenue | -7.2
Profit | -4.7
Estimates won | 26.1
:::

::: followups
Which month had the best profit margin?
How does this compare with 2025?
:::''';

String _current = _answer;

http.Response _handle(http.Request r) => http.Response.bytes(
      utf8.encode(jsonEncode({'success': true, 'answer': _current, 'toolsUsed': ['jobs_summary', 'search_jobs']})),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

Future<void> _pumpMs(WidgetTester t, int ms) async {
  for (var i = 0; i < ms ~/ 50; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _shot(WidgetTester tester, Size size, String name, {bool ask = false, bool sort = false, bool wide = false, bool end = false, bool charts = false}) async {
  _current = charts ? _chartAnswer : _answer;
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  AssistantChat.instance.clear(); // the chat is a singleton, so start each shot empty

  await http.runWithClient(() async {
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

    if (wide) {
      await tester.tap(find.byTooltip('Wide view'));
      await _pumpMs(tester, 500);
    }
    if (ask) {
      await tester.tap(find.text('Unpaid jobs'));
      await _pumpMs(tester, 300);
      if (name.endsWith('thinking')) {
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/$name.png'));
        return;
      }
      await _pumpMs(tester, 3000);
    }
    if (end) {
      await tester.drag(find.byType(SingleChildScrollView).first, const Offset(0, -3000));
      await _pumpMs(tester, 600);
    }
    if (sort) {
      await tester.tap(find.text('TOTAL VALUE'));
      await _pumpMs(tester, 300);
    }
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/$name.png'));
    // Let the pending reveal/shimmer timers finish before teardown.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  }, () => MockClient((r) async => _handle(r)));
}

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', [
      r'C:\Windows\Fonts\segoeui.ttf',
      r'C:\Windows\Fonts\segoeuib.ttf',
      r'C:\Windows\Fonts\seguisb.ttf',
    ]);
    final root = Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter';
    await _loadFont('MaterialIcons', ['$root/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
  });

  testWidgets('assistant empty', (t) async => _shot(t, const Size(1400, 860), 'assistant_empty'));
  testWidgets('assistant answer', (t) async => _shot(t, const Size(1400, 860), 'assistant_answer', ask: true));
  testWidgets('assistant answer end', (t) async => _shot(t, const Size(1400, 860), 'assistant_answer_end', ask: true, end: true));
  testWidgets('assistant answer wide sorted', (t) async => _shot(t, const Size(1500, 900), 'assistant_wide_sorted', ask: true, sort: true, wide: true));
  testWidgets('assistant charts', (t) async => _shot(t, const Size(1400, 1500), 'assistant_charts', ask: true, charts: true));
}
