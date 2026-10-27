// The Estimates dashboard (redesigned like Collections): it fits the window with no scrolling at desktop sizes, the
// chart's three views, the open pipeline by age and the lost reasons each opening their estimates, the stale estimates
// (the oldest on screen, every one a click away, in place of the old scrolling ticker), and the loading, empty, error
// and reduced-motion states. Uses test/fixtures/dashboards/estimates.json and the clock pinned to Oct 22, 2026.
// Screenshots go to build/dash_shots/estimates_*.png (not goldens).
//
// Run: flutter test test/estimates_dashboard_test.dart

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:iohd_desktop/estimates_dashboard_screen.dart';
import 'package:iohd_desktop/widgets/dashboard_kit.dart';

import 'dashboard_fit.dart';
import 'dashboard_harness.dart';

const _path = '/api/dashboards/estimates';
const _drill = '/api/dashboards/estimates/drill';

http.Response _list(http.Request req) => http.Response(
      json.encode({
        'success': true,
        'items': [
          {'jobId': '9300001', 'customerName': 'Lakeside Residence', 'status': 'Estimate Provided', 'location': '',
            'description': '', 'startDate': '2026-02-01', 'value': 5800, 'outcome': 'open', 'daysOld': 263},
        ],
      }),
      200,
    );

DashFakeApi _api() => DashFakeApi()..extra.add((req) async => req.url.path == _drill ? _list(req) : null);

void main() {
  setUpAll(loadDashFonts);
  setUp(() async {
    pinDashClock();
    await dashSignIn();
  });
  tearDown(unpinDashClock);

  final f = dashFixture('estimates');
  final stale = (f['stalePipeline'] as List).cast<Map<String, dynamic>>();

  group('fits the window, no scrolling', () {
    dashFitTests(
      'estimates',
      () => const EstimatesDashboardScreen(),
      _api,
      mustShow: [
        'Open value',
        'Estimates sent',
        'Open pipeline by age',
        '31+ days',
        'Lost reasons',
        for (final r in (f['lostReasons'] as List)) r['reason'] as String,
        'Stale estimates',
        stale.first['customer_name'] as String,
        stale[1]['customer_name'] as String,
      ],
    );

    testWidgets('1000x700 (narrower than a desktop window): one column with no overflow', (t) async {
      final errors = await pumpDashboard(t, const EstimatesDashboardScreen(), api: _api(), size: const Size(1000, 700),
          body: () async => saveDashShot(t, 'estimates_1000x700'));
      expect(errors.overflowed, isFalse, reason: errors.messages.toSet().join('\n'));
    });

    testWidgets('no ticker or other endless animation on the page', (t) async {
      await pumpDashboard(t, const EstimatesDashboardScreen(), api: _api());
      expect(find.byType(AutoScrollTicker), findsNothing);
      await t.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 5));
    });
  });

  group('drill-downs', () {
    testWidgets('an age opens its open estimates, oldest first', (t) async {
      final api = _api();
      await pumpDashboard(t, const EstimatesDashboardScreen(), api: api, body: () async {
        await t.tap(find.text('31+ days'));
        await settleDashboard(t, frames: 5);
        final q = api.to(_drill).last.url.queryParameters;
        expect(q['kind'], 'aging');
        expect(q['bucket'], '31+ days');
        expect(find.text('Open estimates · 31+ days'), findsOneWidget);
        await saveDashShot(t, 'estimates_drill_aging');
      });
    });

    testWidgets('a lost reason opens its lost estimates; a reason with none has nothing to open', (t) async {
      final handle = t.ensureSemantics();
      final api = _api();
      await pumpDashboard(t, const EstimatesDashboardScreen(), api: api, body: () async {
        await t.tap(find.text('Price'));
        await settleDashboard(t, frames: 5);
        final q = api.to(_drill).last.url.queryParameters;
        expect(q['kind'], 'lost');
        expect(q['reason'], 'Price');
        expect(find.text('Lost estimates · Price'), findsOneWidget);
        await t.tap(find.byTooltip('Close'));
        await settleDashboard(t, frames: 5);
        final timing = t.getSemantics(find.bySemanticsLabel(RegExp(r'^Timing: \$0 lost on 0 estimates')));
        expect(timing.flagsCollection.isButton, isFalse);
      });
      handle.dispose();
    });

    testWidgets('every stale estimate is a click away, oldest first; a row opens that customer\'s', (t) async {
      final api = _api();
      await pumpDashboard(t, const EstimatesDashboardScreen(), api: api, body: () async {
        final before = api.requests.length;
        await t.tap(find.text('All ${stale.length}'));
        await settleDashboard(t, frames: 5);
        expect(api.requests.length, before, reason: 'the dashboard already has the list; nothing is fetched');
        final total = stale.fold<num>(0, (s, e) => s + (e['value'] as num));
        expect(find.textContaining('${stale.length} estimates · ${_usd(total)} open'), findsOneWidget);
        await saveDashShot(t, 'estimates_stale_all');
        await t.tap(find.byTooltip('Close'));
        await settleDashboard(t, frames: 5);

        final name = stale.first['customer_name'] as String;
        await t.tap(find.text(name).first);
        await settleDashboard(t, frames: 5);
        expect(find.text('$name · stale estimates'), findsOneWidget);
        final theirs = stale.where((e) => e['customer_name'] == name).toList();
        expect(find.textContaining('${dashCountText(theirs.length)} · ${_usd(theirs.fold<num>(0, (s, e) => s + (e['value'] as num)))} open'),
            findsOneWidget, reason: 'only their estimates, adding up');
      });
    });
  });

  group('chart and figures', () {
    testWidgets('three views by hand', (t) async {
      final handle = t.ensureSemantics();
      await pumpDashboard(t, const EstimatesDashboardScreen(), api: _api(), body: () async {
        expect(find.textContaining('Sent and won · '), findsOneWidget);
        await t.tap(find.bySemanticsLabel('Chart view: Count'));
        await settleDashboard(t, frames: 10);
        expect(find.text('Sent and won · 355 sent in 2026'), findsOneWidget);
        await t.tap(find.bySemanticsLabel('Chart view: Avg value'));
        await settleDashboard(t, frames: 10);
        expect(find.textContaining('Average estimate · '), findsOneWidget);
        await saveDashShot(t, 'estimates_view_avg');
      });
      handle.dispose();
    });

    testWidgets('the open pipeline by age adds up to the open value, with counts', (t) async {
      await pumpDashboard(t, const EstimatesDashboardScreen(), api: _api());
      for (final b in (f['agingBuckets'] as List)) {
        expect(find.text(_usd(b['value'] as num)), findsWidgets);
        expect(find.text('· ${b['count']}'), findsOneWidget);
      }
      expect(find.text('All years · 312 before 2026'), findsOneWidget);
    });
  });

  group('states', () {
    testWidgets('loading shows the skeleton in the same layout', (t) async {
      final held = Completer<http.Response>();
      final api = _api()..extra.insert(0, (req) async => req.url.path == _path ? held.future : null);
      final errors = await pumpDashboard(t, const EstimatesDashboardScreen(), api: api, body: () async {
        expect(find.byType(SkeletonPulse), findsOneWidget);
        expect(dashVerticalScrollers(t), isEmpty);
        await saveDashShot(t, 'estimates_loading');
        held.complete(http.Response(json.encode(dashFixture('estimates')), 200));
        await settleDashboard(t);
        expect(find.text('Open value'), findsOneWidget);
      });
      expect(errors.overflowed, isFalse, reason: errors.messages.toSet().join('\n'));
    });

    testWidgets('an empty year says so in every panel', (t) async {
      final api = _api()..fixture[_path] = 'estimates_empty';
      final errors = await pumpDashboard(t, const EstimatesDashboardScreen(), api: api, body: () async {
        expect(find.text('No estimates for 2026 yet.'), findsOneWidget);
        expect(find.text('No estimates dated 2026 were lost.'), findsOneWidget);
        expect(find.text('No stale estimates today.'), findsOneWidget);
        await saveDashShot(t, 'estimates_empty');
      });
      expect(errors.overflowed, isFalse, reason: errors.messages.toSet().join('\n'));
    });

    testWidgets('reduced motion: the first frame after the data arrives is already final', (t) async {
      final held = Completer<http.Response>();
      final api = _api()..extra.insert(0, (req) async => req.url.path == _path ? held.future : null);
      await pumpDashboard(t, const EstimatesDashboardScreen(), api: api, reduceMotion: true, body: () async {
        held.complete(http.Response(json.encode(dashFixture('estimates')), 200));
        await t.pump();
        await t.pump();
        expect(find.text('\$12,055,908'), findsOneWidget);
        await t.pump();
        expect(t.binding.hasScheduledFrame, isFalse);
      });
    });
  });
}

String dashCountText(int n) => '$n estimate${n == 1 ? '' : 's'}';

final _thousands = RegExp(r'(\d)(?=(\d{3})+$)');
String _usd(num v) => '\$${v.round().toString().replaceAllMapped(_thousands, (m) => '${m[1]},')}';
