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
        for (final r in (f['lostReasons'] as List))
          if ((r['count'] as num) > 0) r['reason'] as String,
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
        expect(find.textContaining('As of today · '), findsOneWidget, reason: 'open today, whatever year they are dated');
        await saveDashShot(t, 'estimates_drill_aging');
      });
    });

    testWidgets('a lost reason opens its lost estimates; a reason with none has no row', (t) async {
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
        expect(find.text('Timing'), findsNothing, reason: 'nothing was lost to it');
        expect(find.text('Unresponsive'), findsOneWidget, reason: 'one estimate was, even at \$0');
        expect(find.text('83% of lost value has no specific reason'), findsOneWidget);
      });
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
        // Dollars, not a share: "41% of that value won" read as a second win rate beside the 87.9% scorecard.
        expect(find.text('won so far'), findsOneWidget);
        expect(find.textContaining('of that value won'), findsNothing);
        expect(find.textContaining('Sep vs Aug'), findsNothing, reason: 'a bare chip cannot say whether sent or won moved');
        await t.tap(find.bySemanticsLabel('Chart view: Count'));
        await settleDashboard(t, frames: 10);
        expect(find.text('Sent and won · by estimate date'), findsOneWidget);
        expect(find.text('won so far'), findsOneWidget);
        expect(find.textContaining('of them won'), findsNothing);
        await t.tap(find.bySemanticsLabel('Chart view: Avg value'));
        await settleDashboard(t, frames: 10);
        expect(find.text('Average estimate · by estimate date'), findsOneWidget);
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
      expect(find.text('All years · 312 estimates pre-2026'), findsOneWidget);
    });

    testWidgets('the win rate line is won ÷ (won + lost) by month, as the scorecard counts it', (t) async {
      await pumpDashboard(t, const EstimatesDashboardScreen(), api: _api());
      final card = t.widget<AnimatedMetricCard>(
        find.byWidgetPredicate((w) => w is AnimatedMetricCard && w.title == 'Win rate'),
      );
      final jan = (f['monthlyValue'] as List).cast<Map<String, dynamic>>().first;
      expect(card.trend!.first, closeTo((jan['won_count'] as num) / (jan['closed_count'] as num) * 100, 0.001));
    });

    testWidgets('a past year reads as that year', (t) async {
      await pumpDashboard(t, const Scaffold(body: EstimatesDashboardContent(selectedYear: 2025)), api: _api());
      expect(find.text('Quoted · all of 2025'), findsOneWidget);
      expect(find.text('Marked lost · all of 2025'), findsOneWidget);
      expect(find.text('won'), findsOneWidget, reason: 'not "so far" for a finished year');
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
        expect(find.text('—'), findsOneWidget, reason: 'nothing decided is no win rate, not 0%');
        expect(find.text('0.0%'), findsNothing);
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
