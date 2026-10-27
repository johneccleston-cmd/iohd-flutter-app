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
        for (final d in doors) d['type'] as String,
        'Team',
      ],
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
      expect(find.textContaining('most deals won first'), findsOneWidget);
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
  });

  group('chart and doors', () {
    testWidgets('team against last year to date, then one person at a time', (t) async {
      final handle = t.ensureSemantics();
      await pumpDashboard(t, const SalesDashboardScreen(), api: _api(), body: () async {
        expect(find.text('Won revenue · \$740.4k in 2026'), findsOneWidget);
        expect(find.text('65% vs 2025 to date'), findsOneWidget, reason: 'same dates a year earlier, as the server counts');
        await t.tap(find.bySemanticsLabel('Chart view: Taylor'));
        await settleDashboard(t, frames: 10);
        expect(find.text('Taylor Reed · \$703.1k won in 2026'), findsOneWidget);
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
        expect(find.textContaining('door lines on won estimates'), findsOneWidget);
        await t.tap(find.text(first['type'] as String));
        await settleDashboard(t, frames: 5);
        expect(api.requests.last.url.path, '$_path/door-estimates');
        expect(api.requests.last.url.queryParameters['type'], first['type']);
        expect(find.text('${first['type']} estimates'), findsOneWidget);
        await saveDashShot(t, 'sales_drill_door');
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
