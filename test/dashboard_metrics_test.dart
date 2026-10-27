// The approved metric corrections (2026-10-22) as the office app shows them, on the saved responses in
// test/fixtures/dashboards with the clock pinned to Oct 22, 2026 (dashboard_harness.dart):
//   - Commissions: a sales rep on the job pool shows his real pay and counts in the average per commission
//     recipient, but is not on the hurdle meters; Commission % of revenue is payouts ÷ completed revenue over the
//     same finalized weeks, and the card is left out when the server has no fair comparison.
//   - Technicians: the callback rate and the leaderboard divide by completed jobs since Oct 5.
//   - Estimates: Open value is every estimate open today, with the prior-year part named.
// Screens are also saved to build/dash_shots/metrics_*.png for review (not goldens).

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:iohd_desktop/commission_dashboard_screen.dart';
import 'package:iohd_desktop/estimates_dashboard_screen.dart';
import 'package:iohd_desktop/technicians_dashboard_screen.dart';
import 'package:iohd_desktop/widgets/dashboard_data.dart';
import 'package:iohd_desktop/widgets/dashboard_kit.dart';

import 'dashboard_harness.dart';

/// A fake API answering from the fixtures, with [path]'s answer passed through [change] first.
DashFakeApi _api([String? path, void Function(Map<String, dynamic> body)? change]) {
  final api = DashFakeApi()
    ..extra.add((req) async => req.url.path == '/api/payroll/runs' ? http.Response(json.encode({'runs': []}), 200) : null);
  if (path != null && change != null) {
    api.extra.add((req) async {
      if (req.url.path != path) return null;
      final body = dashFixture(dashEndpoints[path]!);
      change(body);
      return http.Response(json.encode(body), 200);
    });
  }
  return api;
}

const _commissions = '/api/commissions_stats';
const _techStats = '/api/tech_stats';
const _estimates = '/api/dashboards/estimates';

/// The hurdle meters: one per person on the hurdle, in that person's row of the People panel.
Finder _hurdleMeters() => find.byWidgetPredicate((w) => w.runtimeType.toString() == '_HurdleMeter');

/// [name]'s row in the People panel, if it has a hurdle meter.
Finder _inMeters(String name) => find.ancestor(of: _hurdleMeters(), matching: find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == 'DashPressable' && (w as dynamic).label.toString().startsWith('$name:'),
    ));
Finder _semantics(String pattern) => find.bySemanticsLabel(RegExp(pattern));

List<Map<String, dynamic>> _people(Map<String, dynamic> body) => (body['technicians'] as List).cast<Map<String, dynamic>>();

void main() {
  setUpAll(loadDashFonts);
  setUp(() async {
    pinDashClock();
    await dashSignIn();
  });
  tearDown(unpinDashClock);

  group('dashShortDate / dashDateRange', () {
    test('server dates in caption words', () {
      expect(dashShortDate('2026-10-05'), 'Oct 5');
      expect(dashShortDate('2026-01-01'), 'Jan 1');
      expect(dashShortDate('not a date'), 'not a date');
      expect(dashDateRange('2026-10-05', '2026-10-18'), 'Oct 5–18');
      expect(dashDateRange('2026-09-28', '2026-10-11'), 'Sep 28 – Oct 11');
      expect(dashDateRange('2026-12-28', '2027-01-03'), 'Dec 28 – Jan 3');
    });
  });

  group('Commissions', () {
    testWidgets('a sales rep on the job pool shows his real pay and counts in the average, but is off the hurdle meters',
        (t) async {
      final f = dashFixture('commissions');
      final rep = _people(f).firstWhere((p) => p['isSales'] == true);
      expect(rep['onPool'], isTrue, reason: 'fixture: the install-rate rep');
      final errors = await pumpDashboard(t, const CommissionDashboardScreen(), api: _api(), size: const Size(1500, 800));

      expect(find.text('\$312.40'), findsOneWidget, reason: 'his paid YTD, not "Sales"');
      expect(find.text('Sales'), findsNothing);
      expect(_hurdleMeters(), findsNWidgets(_people(f).where((p) => p['isSales'] != true).length));
      expect(_inMeters('Riley Brooks'), findsNothing, reason: 'sales role: no weekly hurdle');
      expect(_inMeters('Alex Rivera'), findsOneWidget);

      final avg = (f['summary']['avgCommissionPerRecipient'] as num).toDouble();
      expect(find.text('Avg commission per recipient'), findsOneWidget);
      expect(find.text(dashMoney(avg)), findsOneWidget);
      expect(find.text('Paid ÷ 5 on the job pool'), findsOneWidget);
      expect(_semantics(r'^Avg commission per recipient: .*the 5 people on the job pool'), findsOneWidget);
      expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
      await saveDashShot(t, 'metrics_commissions_1500');
    });

    testWidgets('Commission % of revenue: payouts ÷ completed revenue over the same finalized weeks, at 1280x600',
        (t) async {
      final errors = await pumpDashboard(t, const CommissionDashboardScreen(), api: _api());
      expect(find.text('Commission % of revenue'), findsOneWidget);
      expect(find.text('4.8%'), findsOneWidget); // 4,622.40 ÷ 97,240
      expect(find.text('Of completed revenue · Oct 5–18'), findsOneWidget);
      expect(
        _semantics(r'^Commission % of revenue: 4\.8%\. .*Oct 5 to Oct 18 \(\$4,622\.40\).*58 jobs.*\(\$97,240\.00\)'),
        findsOneWidget,
      );
      expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
      await saveDashShot(t, 'metrics_commissions_1280');
    });

    testWidgets('no fair comparison (no finalized week yet): the % card is left out and the row still fits', (t) async {
      final errors = await pumpDashboard(
        t,
        const CommissionDashboardScreen(),
        api: _api(_commissions, (b) => b['summary']['commissionRate'] = null),
      );
      expect(find.text('Commission % of revenue'), findsNothing);
      for (final title in ['Total payouts', 'Sales commission', 'Commercial retainage pool', 'Avg commission per recipient']) {
        expect(find.text(title), findsOneWidget, reason: title);
      }
      expect(find.textContaining('%'), findsNothing, reason: 'no percentage anywhere in the scorecards');
      expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
      await saveDashShot(t, 'metrics_commissions_no_rate_1280');
    });

    testWidgets('a sales-only rep (not on the pool) still reads "Sales"', (t) async {
      await pumpDashboard(
        t,
        const CommissionDashboardScreen(),
        api: _api(_commissions, (b) {
          final rep = _people(b).firstWhere((p) => p['isSales'] == true);
          rep['onPool'] = false;
          rep['ytdCommission'] = 0;
        }),
        size: const Size(1500, 800),
      );
      expect(find.text('Sales'), findsOneWidget);
      expect(find.text('\$312.40'), findsNothing);
    });

    testWidgets('an older server (no onPool, no commissionRate): the old rule, and no % card', (t) async {
      final errors = await pumpDashboard(
        t,
        const CommissionDashboardScreen(),
        api: _api(_commissions, (b) {
          for (final p in _people(b)) {
            p.remove('onPool');
          }
          (b['summary'] as Map).remove('commissionRate');
          (b['summary'] as Map).remove('avgCommissionPerRecipient');
          (b['meta'] as Map).remove('averageHeadcount');
        }),
      );
      expect(find.text('Sales'), findsOneWidget);
      expect(find.text('Commission % of revenue'), findsNothing);
      expect(find.text('Paid ÷ 4 on the job pool'), findsOneWidget, reason: 'headcount from the people marked on the pool');
      expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
    });
  });

  group('Technicians', () {
    testWidgets('callback rate: strikes ÷ completed jobs since Oct 5, and the leaderboard on the same jobs', (t) async {
      final f = dashFixture('technicians');
      final m = f['summary']['metrics'] as Map<String, dynamic>;
      expect(m['callbackRatePct'], closeTo(5 / 72 * 100, 1e-9));
      final errors = await pumpDashboard(t, const TechniciansDashboardScreen(), api: _api(), size: const Size(1500, 800));

      expect(find.text('6.9%'), findsOneWidget);
      expect(find.text('5 ÷ 72 completed jobs since Oct 5'), findsOneWidget);
      expect(_semantics(r'^Callback rate: 6\.9%\. Callback strikes divided by completed jobs.*5 strikes on 72 jobs'), findsOneWidget);
      expect(find.text('Technicians · fewest callbacks first'), findsOneWidget);
      expect(find.text('Callbacks since Oct 5'), findsOneWidget);
      // Alex: 3 strikes on 38 jobs since Oct 5 (not 733 jobs all year).
      expect(find.text('3 of 38'), findsOneWidget);
      expect(find.text('7.9%'), findsWidgets);
      expect(find.text('3 of 733'), findsNothing);
      expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
      await saveDashShot(t, 'metrics_technicians_1500');
    });

    testWidgets('no completed jobs since go-live: no rate (a dash), never 0%', (t) async {
      final errors = await pumpDashboard(t, const TechniciansDashboardScreen(), api: _api()..fixture[_techStats] = 'technicians_empty');
      expect(_semantics(r'^Callback rate: no figure yet\. Callbacks are counted from Oct 5, 2026'), findsOneWidget);
      expect(find.text('No completed jobs since Oct 5'), findsOneWidget);
      expect(find.text('0.0%'), findsNothing);
      expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
    });

    testWidgets('a later year counts from Jan 1', (t) async {
      await pumpDashboard(
        t,
        const TechniciansDashboardScreen(),
        api: _api(_techStats, (b) => b['summary']['metrics']['callbackPeriod'] = {'from': '2027-01-01', 'to': '2027-03-01'}),
      );
      expect(find.text('5 ÷ 72 completed jobs since Jan 1'), findsOneWidget);
    });
  });

  group('Estimates', () {
    testWidgets('Open value is every estimate open today, with the prior-year part named', (t) async {
      final f = dashFixture('estimates');
      final s = f['scorecards'] as Map<String, dynamic>;
      expect(s['openValue'], 12055908);
      final errors = await pumpDashboard(t, const EstimatesDashboardScreen(), api: _api());

      expect(find.text('\$12,055,908'), findsOneWidget);
      expect(find.text('All years · 312 before 2026'), findsOneWidget);
      expect(_semantics(r'^Open value: \$12,055,908\. Every estimate .*whatever year.*\$5,312,640 of it \(312 estimates\) is dated before 2026'),
          findsOneWidget);
      // The oldest open estimates (from earlier years) lead the stale list.
      expect(find.text('#9100001 · 2 years old'), findsOneWidget);
      expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
      await saveDashShot(t, 'metrics_estimates_1280');
    });

    testWidgets('no prior-year estimates: a plain caption', (t) async {
      await pumpDashboard(
        t,
        const EstimatesDashboardScreen(),
        api: _api(_estimates, (b) => b['scorecards']['openPriorYears'] = {'count': 0, 'value': 0, 'before': '2026-01-01'}),
      );
      expect(find.text('All open estimates · today'), findsOneWidget);
    });

    // Production has about 723 stale open estimates once earlier years are included. The old ticker built a card for
    // every one (~73 ms a frame for 723 in the test runner, an open question whether to cap or virtualize it). The
    // panel now builds only the rows that fit and opens the rest in the list dialog, so the page cost no longer grows
    // with the list; this checks it still works at that size and records the time.
    testWidgets('a production-sized stale list (723 estimates, oldest first): only the rows that fit are built', (t) async {
      final stale = [
        for (var i = 0; i < 723; i++)
          {'job_id': '${8000000 + i}', 'customer_name': 'Customer $i', 'value': 1000 + i * 37, 'days_old': 1650 - i * 2},
      ];
      final sw = Stopwatch()..start();
      final errors = await pumpDashboard(
        t,
        const EstimatesDashboardScreen(),
        api: _api(_estimates, (b) => b['stalePipeline'] = stale),
        body: () async {
          final frames = Stopwatch()..start();
          for (var i = 0; i < 60; i++) {
            await t.pump(const Duration(milliseconds: 16));
          }
          frames.stop();
          // ignore: avoid_print
          print('stale list, 723 estimates: first load ${sw.elapsedMilliseconds} ms, 60 frames ${frames.elapsedMilliseconds} ms');
          expect(find.text('Customer 0'), findsOneWidget, reason: 'the oldest estimate leads the list');
          expect(find.text('Customer 300'), findsNothing, reason: 'rows that do not fit are not built');
          await t.tap(find.text('All 723'));
          await settleDashboard(t, frames: 5);
          expect(find.textContaining('723 estimates · '), findsOneWidget);
        },
      );
      expect(t.takeException(), isNull);
      expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
    });
  });
}
