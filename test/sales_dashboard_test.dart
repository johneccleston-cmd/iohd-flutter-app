// The Sales dashboard (redesigned like Collections): it fits the window with no scrolling at desktop sizes, each
// person's figures open the estimates behind them, the chart's team and per-person views against last year, door
// styles by win rate or revenue (each opening its estimates), and the loading, empty, error and reduced-motion states.
// Uses test/fixtures/dashboards/sales.json and the clock pinned to Oct 22, 2026.
// Screenshots go to build/dash_shots/sales_*.png (not goldens).
//
// Run: flutter test test/sales_dashboard_test.dart

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:iohd_desktop/sales_dashboard_screen.dart';
import 'package:iohd_desktop/widgets/dashboard_kit.dart';

import 'dashboard_fit.dart';
import 'dashboard_harness.dart';

const _path = '/api/dashboards/sales';

/// The monthly chart's plot.
final _plot = find.byWidgetPredicate((w) => w is CustomPaint && w.painter.runtimeType.toString() == '_DashChartPainter');

http.Response _list(http.Request req) => http.Response(
      json.encode({
        'success': true,
        'items': [
          {'jobId': '9400001', 'customerName': 'Summit Builders', 'status': 'Won', 'location': '', 'description': '',
            'startDate': '2026-05-01', 'value': 38608, 'outcome': 'won', 'owner': 'Taylor Reed'},
        ],
      }),
      200,
    );

DashFakeApi _api() => DashFakeApi()
  ..extra.add((req) async => req.url.path.startsWith('$_path/') ? _list(req) : null);

void main() {
  setUpAll(loadDashFonts);
  setUp(() async {
    pinDashClock();
    await dashSignIn();
  });
  tearDown(unpinDashClock);

  final f = dashFixture('sales');
  final people = (f['people'] as List).cast<Map<String, dynamic>>();
  final doors = [for (final d in (f['doorTypes'] as List).cast<Map<String, dynamic>>()) if (d['type'] != 'Unspecified') d];

  group('fits the window, no scrolling', () {
    dashFitTests(
      'sales',
      () => const SalesDashboardScreen(),
      _api,
      mustShow: [
        'Won revenue',
        'Largest deal won',
        for (final p in people) p['name'] as String,
        'Door styles',
        'Team',
      ],
      extra: (t, size, scale) async {
        // Every door style has a row, except in a short window where the team moves over the door styles so the chart
        // keeps a readable height (it was a ~90 px sliver at 1280x600): there at least three show and the rest are
        // one click away in "All N". Either way the chart's plot gets real height. With this few styles the team also
        // sits over them at larger sizes when it fits on one line, so the door panel isn't a tall, mostly empty column.
        final window = Offset.zero & size;
        final shown = [
          for (final d in doors)
            if (find.text(d['type'] as String).evaluate().isNotEmpty &&
                window.contains(t.getRect(find.text(d['type'] as String)).bottomRight - const Offset(0.01, 0.01)))
              d,
        ];
        if (shown.length < doors.length) {
          expect(shown.length, greaterThanOrEqualTo(3), reason: 'at least three door styles show at $size');
          expect(find.text('All ${doors.length}'), findsOneWidget, reason: 'the rest are a click away');
        }
        if (scale == 1 && size.height <= 720) {
          expect(shown.length, size.height < 700 ? greaterThanOrEqualTo(3) : doors.length);
        }
        if (scale == 1) expect(t.getRect(_plot).height, greaterThan(150), reason: 'the chart has room to read at $size');
      },
    );

    testWidgets('1000x700 (narrower than a desktop window): one column with no overflow', (t) async {
      final errors = await pumpDashboard(t, const SalesDashboardScreen(), api: _api(), size: const Size(1000, 700),
          body: () async => saveDashShot(t, 'sales_1000x700'));
      expect(errors.overflowed, isFalse, reason: errors.messages.toSet().join('\n'));
    });

    testWidgets('nothing cycles on its own: the door styles stay on the view that was picked', (t) async {
      await pumpDashboard(t, const SalesDashboardScreen(), api: _api());
      await t.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 5));
      await t.pump(const Duration(seconds: 12));
      expect(find.textContaining('Wins most often: '), findsOneWidget); // the win-rate view's finding
    });

    testWidgets('no trophy or rank badge on the sales team', (t) async {
      await pumpDashboard(t, const SalesDashboardScreen(), api: _api());
      expect(find.byIcon(Icons.emoji_events_rounded), findsNothing);
      expect(find.textContaining('Rank #'), findsNothing);
    });
  });

  group('the team', () {
    testWidgets('every figure on a person\'s row opens the estimates behind it', (t) async {
      final handle = t.ensureSemantics();
      final api = _api();
      final p = people.first;
      await pumpDashboard(t, const SalesDashboardScreen(), api: api, body: () async {
        for (final (pattern, filter, heading) in [
          ('^${p['name']}: \\\$703,107 won', 'won', 'Won estimates'),
          ('^${p['name']}: 298 estimates sent', 'sent', 'Estimates sent'),
          ('^${p['name']}: largest deal', 'won', 'Won estimates, largest first'),
          ('^${p['name']}: 18 estimates lost', 'lost', 'Lost estimates'),
          ('^${p['name']}: win rate', 'closed', 'Closed estimates (won and lost)'),
        ]) {
          await t.tap(find.bySemanticsLabel(RegExp(pattern)));
          await settleDashboard(t, frames: 5);
          final q = api.requests.last.url.queryParameters;
          expect(q['owner'], p['name']);
          expect(q['filter'], filter);
          expect(find.text('${p['name']} · $heading'), findsOneWidget);
          await t.tap(find.byTooltip('Close'));
          await settleDashboard(t, frames: 5);
        }
        expect(find.text('95% of team'), findsOneWidget, reason: "Taylor's share of the team's won revenue");
      });
      handle.dispose();
    });

    testWidgets('whole dollars in both money columns; a lost count is not a warning', (t) async {
      await pumpDashboard(t, const SalesDashboardScreen(), api: _api());
      expect(find.text('\$33,867'), findsOneWidget, reason: "Riley's largest, in the same format as the Won column");
      expect(find.text('\$38.6k'), findsNothing, reason: 'no compact figure beside "\$703,107"');
      expect(t.widget<Text>(find.text('18')).style!.color, DashUi.ink);
    });

    testWidgets('scorecard captions: the period on each, the largest deal names its owner', (t) async {
      await pumpDashboard(t, const SalesDashboardScreen(), api: _api());
      expect(find.text('Sales team · Jan 1 – today'), findsOneWidget);
      expect(find.text('Won ÷ (won + lost) · Jan 1 – today'), findsOneWidget);
      expect(find.text('Won by Taylor · Jan 1 – today'), findsOneWidget);
    });
  });

  group('chart and doors', () {
    testWidgets('team against last year (same months), then one person at a time', (t) async {
      final handle = t.ensureSemantics();
      await pumpDashboard(t, const SalesDashboardScreen(), api: _api(), body: () async {
        expect(find.text('Won revenue · by estimate date'), findsOneWidget);
        // One answer to "how does this compare with last year": the story's like-for-like finished months. The old
        // "65% vs 2025 to date" chip beside it counted the month in progress and gave a different number.
        expect(find.text('on 2025, same months'), findsOneWidget);
        expect(find.textContaining('vs 2025 to date'), findsNothing);
        await t.tap(find.bySemanticsLabel('Chart view: Taylor'));
        await settleDashboard(t, frames: 10);
        expect(find.text('Taylor Reed · won revenue, by estimate date'), findsOneWidget);
        await saveDashShot(t, 'sales_view_person');
      });
      handle.dispose();
    });

    testWidgets('door styles: win rate or revenue by hand; a style opens its estimates', (t) async {
      final api = _api();
      await pumpDashboard(t, const SalesDashboardScreen(), api: api, body: () async {
        final first = doors.reduce((a, b) => (a['wonCount'] as num) >= (b['wonCount'] as num) ? a : b);
        expect(find.text('${first['wonCount']}/${(first['wonCount'] as num) + (first['lostCount'] as num)}'), findsOneWidget);
        await t.tap(find.text('Revenue'));
        await settleDashboard(t, frames: 10);
        expect(find.textContaining('Brings in most: '), findsOneWidget); // the revenue view's finding
        await t.tap(find.text(first['type'] as String));
        await settleDashboard(t, frames: 5);
        expect(api.requests.last.url.path, '$_path/door-estimates');
        expect(api.requests.last.url.queryParameters['type'], first['type']);
        expect(find.text('${first['type']} estimates'), findsOneWidget);
        await saveDashShot(t, 'sales_drill_door');
      });
    });

    testWidgets('every door style is listed, not just the first ten', (t) async {
      final body = dashFixture('sales');
      body['doorTypes'] = [
        for (var i = 0; i < 13; i++)
          {'type': 'Style $i', 'sentCount': 20, 'wonCount': 13 - i, 'lostCount': 1, 'winRate': 0, 'revenue': 1000 * (13 - i)},
      ];
      final api = _api()..extra.insert(0, (req) async => req.url.path == _path ? http.Response(json.encode(body), 200) : null);
      await pumpDashboard(t, const SalesDashboardScreen(), api: api, size: const Size(1280, 600), body: () async {
        await t.tap(find.text('All 13'));
        await settleDashboard(t, frames: 5);
        expect(find.text('Style 12'), findsWidgets);
      });
    });
  });

  group('states', () {
    testWidgets('loading shows the skeleton in the same layout', (t) async {
      final held = Completer<http.Response>();
      final api = _api()..extra.insert(0, (req) async => req.url.path == _path ? held.future : null);
      final errors = await pumpDashboard(t, const SalesDashboardScreen(), api: api, body: () async {
        expect(find.byType(SkeletonPulse), findsOneWidget);
        expect(dashVerticalScrollers(t), isEmpty);
        await saveDashShot(t, 'sales_loading');
        held.complete(http.Response(json.encode(dashFixture('sales')), 200));
        await settleDashboard(t);
        expect(find.text('Won revenue'), findsOneWidget);
      });
      expect(errors.overflowed, isFalse, reason: errors.messages.toSet().join('\n'));
    });

    testWidgets('an empty year renders and says so', (t) async {
      final api = _api()..fixture[_path] = 'sales_empty';
      final errors = await pumpDashboard(t, const SalesDashboardScreen(), api: api, body: () async {
        expect(find.text('No won estimates for 2026 yet.'), findsOneWidget);
        expect(find.text('—'), findsOneWidget, reason: 'nothing decided is no win rate, not 0%');
        expect(find.text('0.0%'), findsNothing);
        await saveDashShot(t, 'sales_empty');
      });
      expect(errors.overflowed, isFalse, reason: errors.messages.toSet().join('\n'));
    });

    testWidgets('reduced motion: the first frame after the data arrives is already final', (t) async {
      final held = Completer<http.Response>();
      final api = _api()..extra.insert(0, (req) async => req.url.path == _path ? held.future : null);
      await pumpDashboard(t, const SalesDashboardScreen(), api: api, reduceMotion: true, body: () async {
        held.complete(http.Response(json.encode(dashFixture('sales')), 200));
        await t.pump();
        await t.pump();
        expect(find.text('\$740,378'), findsWidgets);
        await t.pump();
        expect(t.binding.hasScheduledFrame, isFalse);
      });
    });
  });
}
