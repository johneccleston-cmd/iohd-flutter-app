// Behaviour tests for all eight dashboards on the shared data layer, using the saved responses in
// test/fixtures/dashboards and a clock pinned to Oct 22, 2026 (dashboard_harness.dart).
//
// For each dashboard: the headline figures shown equal the figures in the response, and those figures reconcile
// with the parts they summarize; captions are drawn; a 500 / 403 / 401 / empty year each behave; the header says
// how old the figures are; a refresh keeps the figures on screen. Plus the cross-cutting rules: a late answer for an
// old year never replaces the current one, a month in progress is never compared, nothing asks an outside avatar
// service for anyone's name, and Inventory has no year selector.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:iohd_desktop/collections_dashboard_screen.dart';
import 'package:iohd_desktop/commission_dashboard_screen.dart';
import 'package:iohd_desktop/config/auth_session.dart';
import 'package:iohd_desktop/estimates_dashboard_screen.dart';
import 'package:iohd_desktop/inventory_dashboard_screen.dart';
import 'package:iohd_desktop/jobs_dashboard_screen.dart';
import 'package:iohd_desktop/reports_screen.dart';
import 'package:iohd_desktop/sales_dashboard_screen.dart';
import 'package:iohd_desktop/technicians_dashboard_screen.dart';
import 'package:iohd_desktop/widgets/dashboard_kit.dart';

import 'dashboard_harness.dart';

final _whole = NumberFormat('#,##0');
String _usd(num v) => '\$${_whole.format(v)}';
double _num(dynamic v) => v is num ? v.toDouble() : double.parse('$v'.replaceAll(RegExp(r'[^0-9.\-]'), ''));
double _sum(Iterable<dynamic> xs) => xs.fold<double>(0, (t, x) => t + _num(x));

class _Dash {
  final String fixture;
  final String path;
  final String what;
  final Widget Function() screen;

  /// Headline figures as the screen formats them, worked out from the fixture.
  final List<String> Function(Map<String, dynamic> f) headline;

  /// Each total in the fixture against the parts it summarizes: (label, total, sum of parts).
  final List<(String, double, double)> Function(Map<String, dynamic> f) reconcile;

  /// A caption that has to be drawn under a figure.
  final String caption;

  const _Dash(this.fixture, this.path, this.what, this.screen, this.headline, this.reconcile, this.caption);
}

final _dashboards = <_Dash>[
  _Dash(
    'financial',
    '/api/financial_dashboard',
    'financials',
    () => const ReportsScreen(),
    (f) => [f['revenueYtd'] as String, f['grossProfitYtd'] as String, f['outstandingMoney'] as String],
    (f) {
      final months = (f['chartData'] as List).cast<Map<String, dynamic>>();
      return [
        ('revenue + deposits = completed revenue + deposits', _num(f['revenueYtd']), _sum(months.map((m) => m['revenue'])) + _num(f['depositsYtd'])),
        ('revenue + deposits = the four segments', _num(f['revenueYtd']),
            _num(f['highVolumeRevenue']) + _num(f['commercialRevenue']) + _num(f['residentialRevenue']) + _num(f['otherRevenue'])),
        ('gross profit = monthly profit', _num(f['grossProfitYtd']), _sum(months.map((m) => m['profit']))),
        ('expense categories = monthly expenses', _sum((f['operatingExpenses'] as List).map((e) => e['amount'])), _sum(months.map((m) => m['expense']))),
        ('projection = revenue + deposits / share of year gone (295/365)', _num(f['yearlyProjected']), (_num(f['revenueYtd']) / (295 / 365)).roundToDouble()),
      ];
    },
    'Jobs + deposits · YTD',
  ),
  _Dash(
    'commissions',
    '/api/commissions_stats',
    'commissions',
    () => const CommissionDashboardScreen(),
    (f) => [
      dashMoney(_num(f['summary']['totalPayoutsYtd'])),
      dashMoney(_num(f['summary']['avgCommissionPerRecipient'])),
      '${_num(f['summary']['commissionRate']['pct']).toStringAsFixed(1)}%',
    ],
    (f) {
      final s = f['summary'] as Map<String, dynamic>;
      final rate = s['commissionRate'] as Map<String, dynamic>;
      final weeks = rate['weeks'] as List;
      final onPool = (f['technicians'] as List).where((t) => t['onPool'] == true);
      return [
        ('total payouts = per-person paid', _num(s['totalPayoutsYtd']), _sum((f['technicians'] as List).map((t) => t['ytdCommission']))),
        ('total payouts = monthly payouts', _num(s['totalPayoutsYtd']), _sum((f['monthlyData'] as List).map((m) => m['payout']))),
        ('average = paid to the job pool ÷ its headcount', _num(s['avgCommissionPerRecipient']),
            _sum(onPool.map((t) => t['ytdCommission'])) / _num(f['meta']['averageHeadcount'])),
        ('headcount = people on the job pool', _num(f['meta']['averageHeadcount']), onPool.length.toDouble()),
        ('commission % = payouts ÷ completed revenue', _num(rate['pct']), _num(rate['payouts']) / _num(rate['completedRevenue']) * 100),
        ('commission % payouts = weekly payouts', _num(rate['payouts']), _sum(weeks.map((w) => w['payouts']))),
        ('commission % revenue = weekly completed revenue', _num(rate['completedRevenue']), _sum(weeks.map((w) => w['completedRevenue']))),
        ('commission % jobs = weekly completed jobs', _num(rate['completedJobs']), _sum(weeks.map((w) => w['completedJobs']))),
        ('commission % payouts = total payouts (every 2026 payout is after go-live)', _num(rate['payouts']), _num(s['totalPayoutsYtd'])),
      ];
    },
    'Finalized runs · 2026 pay weeks',
  ),
  _Dash(
    'technicians',
    '/api/tech_stats',
    'technicians',
    () => const TechniciansDashboardScreen(),
    (f) => ['${(_num(f['summary']['metrics']['callbackRatePct'])).toStringAsFixed(1)}%'],
    (f) {
      final m = f['summary']['metrics'] as Map<String, dynamic>;
      final techs = f['techs'] as List;
      return [
        ('callbacks = per-tech callbacks', _num(m['callbacks']), _sum(techs.map((t) => t['callbackCount']))),
        ('callback rate = callbacks ÷ completed jobs since go-live', _num(m['callbackRatePct']), _num(m['callbacks']) / _num(m['callbackJobs']) * 100),
        ('avg profit per tech = chart profit / techs', _num(m['avgProfitYtd']), _sum((f['summary']['chartData'] as List).map((c) => c['totalProfit'])) / _num(m['techCount'])),
      ];
    },
    '5 ÷ 72 completed jobs since Oct 5',
  ),
  _Dash(
    'inventory',
    '/api/dashboards/inventory',
    'inventory',
    () => const InventoryDashboardScreen(),
    (f) => [_usd(_num(f['totalValuation'])), '${f['lowStockCount']}'],
    (f) => [
      ('stock value = categories', _num(f['totalValuation']), _sum((f['categories'] as List).map((c) => _num(c['activeValue']) + _num(c['lowStockValue'])))),
    ],
    'Active items at cost · today',
  ),
  _Dash(
    'sales',
    '/api/dashboards/sales',
    'sales',
    () => const SalesDashboardScreen(),
    (f) => [_usd(_num(f['summary']['wonValue'])), _whole.format(f['summary']['wonCount'])],
    (f) {
      final months = (f['monthly'] as List).cast<Map<String, dynamic>>();
      return [
        ('won revenue = monthly won', _num(f['summary']['wonValue']), _sum(months.map((m) => m['won_value']))),
        ('won revenue = per-person won', _num(f['summary']['wonValue']), _sum((f['people'] as List).map((p) => p['wonValue']))),
        ('deals won = monthly won count', _num(f['summary']['wonCount']), _sum(months.map((m) => m['won_count']))),
        ('win rate = won / closed', _num(f['summary']['winRate']), _sum(months.map((m) => m['won_count'])) / _sum(months.map((m) => m['closed_count'])) * 100),
      ];
    },
    'Sales team estimates won · Jan 1 – today',
  ),
  _Dash(
    'collections',
    '/api/dashboards/collections',
    'collections',
    () => const CollectionsDashboardScreen(),
    (f) => [_usd(_num(f['summary']['collected'])), _usd(_num(f['summary']['outstanding']).round())],
    (f) => [
      ('collected = monthly collected', _num(f['summary']['collected']), _sum((f['monthly'] as List).map((m) => m['collected']))),
      ('collected = payment methods', _num(f['summary']['collected']), _sum((f['methods'] as List).map((m) => m['amount']))),
      ('outstanding = stage balances', _num(f['summary']['outstanding']), _sum((f['stages'] as List).map((s) => s['amount']))),
      ('over 90 = the 90-day stage', _num(f['summary']['over90']), _num((f['stages'] as List).firstWhere((s) => s['stage'] == '90')['amount'])),
      ('written-off balance = monthly write-offs', _num(f['summary']['writeOffBalance']), _sum((f['writeOffMonthly'] as List).map((w) => w['balance']))),
    ],
    'Invoiced, not yet paid · today',
  ),
  _Dash(
    'jobs',
    '/api/dashboards/jobs',
    'jobs',
    () => const JobsDashboardScreen(),
    (f) => [_whole.format(f['scorecards']['completedYtd']), _whole.format(f['scorecards']['activeOpenJobs'])],
    (f) => [
      ('completed = monthly completed', _num(f['scorecards']['completedYtd']), _sum((f['monthlyVolume'] as List).map((m) => m['completed_count']))),
      ('active open = jobs by status', _num(f['scorecards']['activeOpenJobs']), _sum((f['statusCounts'] as List).map((s) => s['count']))),
    ],
    'Open, from any year · today',
  ),
  _Dash(
    'estimates',
    '/api/dashboards/estimates',
    'estimates',
    () => const EstimatesDashboardScreen(),
    (f) => [_usd(_num(f['scorecards']['openValue'])), _usd(_num(f['scorecards']['lostValue']))],
    (f) {
      final months = (f['monthlyValue'] as List).cast<Map<String, dynamic>>();
      return [
        ('open value = aging buckets', _num(f['scorecards']['openValue']), _sum((f['agingBuckets'] as List).map((b) => b['value']))),
        ('open count = aging buckets', _num(f['scorecards']['openCount']), _sum((f['agingBuckets'] as List).map((b) => b['count']))),
        ('lost value = monthly lost', _num(f['scorecards']['lostValue']), _sum(months.map((m) => m['lost_value']))),
        ('lost value = lost reasons', _num(f['scorecards']['lostValue']), _sum((f['lostReasons'] as List).map((r) => r['lost_value']))),
        ('sent = monthly sent', _num(f['scorecards']['sentYtd']), _sum(months.map((m) => m['sent_count']))),
      ];
    },
    'Estimates marked lost · Jan 1 – today',
  ),
];

/// The Commissions page also lists payroll runs; everything else is answered from the fixtures.
DashFakeApi _api() => DashFakeApi()
  ..extra.add((req) async => req.url.path == '/api/payroll/runs' ? http.Response(json.encode({'runs': []}), 200) : null);

void main() {
  setUpAll(loadDashFonts);
  setUp(() async {
    pinDashClock();
    await dashSignIn();
  });
  tearDown(unpinDashClock);

  for (final d in _dashboards) {
    group('${d.fixture} dashboard', () {
      test('the fixture reconciles: each total equals the parts it summarizes', () {
        final f = dashFixture(d.fixture);
        for (final (label, total, parts) in d.reconcile(f)) {
          expect(total, closeTo(parts, 0.01), reason: label);
        }
      });

      testWidgets('shows the response\'s headline figures and their captions, with no overflow at 1280x600', (t) async {
        final api = _api();
        final errors = await pumpDashboard(t, d.screen(), api: api);
        for (final text in d.headline(dashFixture(d.fixture))) {
          expect(find.text(text), findsWidgets, reason: 'headline figure $text');
        }
        expect(find.text(d.caption), findsOneWidget, reason: 'caption drawn under the figure');
        expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
        expect(t.takeException(), isNull);
      });

      testWidgets('the header says how old the figures are, and Refresh keeps them on screen', (t) async {
        final api = _api();
        await pumpDashboard(t, d.screen(), api: api, body: () async {
          expect(find.text('Updated 3 min ago'), findsOneWidget);
          final headline = d.headline(dashFixture(d.fixture)).first;
          final before = api.to(d.path).length;

          api.delay[d.path] = const Duration(seconds: 2);
          await t.tap(find.byTooltip('Refresh now'));
          await t.pump(const Duration(milliseconds: 200));
          expect(find.text('Refreshing…'), findsOneWidget);
          expect(find.text(headline), findsWidgets, reason: 'figures stay up while a refresh runs (no skeleton)');

          await t.pump(const Duration(seconds: 3));
          await settleDashboard(t, frames: 5);
          final refreshes = api.to(d.path).skip(before).toList();
          expect(refreshes, hasLength(1));
          expect(refreshes.single.url.queryParameters['fresh'], '1');
          expect(find.text('Updated 3 min ago'), findsOneWidget);
        });
      });

      testWidgets('a refresh that fails keeps the last good figures and says so', (t) async {
        final api = _api();
        await pumpDashboard(t, d.screen(), api: api, body: () async {
          api.status[d.path] = 500;
          await t.tap(find.byTooltip('Refresh now'));
          await settleDashboard(t, frames: 5);
          expect(find.text("Couldn't refresh"), findsOneWidget);
          expect(find.text(d.headline(dashFixture(d.fixture)).first), findsWidgets);
        });
      });

      testWidgets('a server error shows a plain failure with Try again, and no raw error text', (t) async {
        final api = _api()..status[d.path] = 500;
        await pumpDashboard(t, d.screen(), api: api, body: () async {
          expect(find.text("Couldn't load ${d.what}"), findsOneWidget);
          expect(find.text('Try again'), findsOneWidget);
          expect(find.textContaining('Exception'), findsNothing);
          expect(find.textContaining('simulated'), findsNothing);

          api.status.remove(d.path);
          await t.tap(find.text('Try again'));
          await settleDashboard(t);
          expect(find.text(d.headline(dashFixture(d.fixture)).first), findsWidgets);
        });
      });

      testWidgets('403: "no access", no retry button, still signed in', (t) async {
        final api = _api()..status[d.path] = 403;
        await pumpDashboard(t, d.screen(), api: api);
        expect(find.text('No access to ${d.what}'), findsOneWidget);
        expect(find.text('Try again'), findsNothing);
        expect(AuthSession.instance.isLoggedIn, isTrue);
      });

      testWidgets('401: the session ends', (t) async {
        final api = _api()..status[d.path] = 401;
        await pumpDashboard(t, d.screen(), api: api);
        expect(AuthSession.instance.isLoggedIn, isFalse);
        expect(find.text('Your session ended'), findsOneWidget);
      });

      testWidgets('an empty year renders without errors or overflow', (t) async {
        final api = _api()..fixture[d.path] = '${d.fixture}_empty';
        final errors = await pumpDashboard(t, d.screen(), api: api);
        expect(t.takeException(), isNull);
        expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
      });
    });
  }

  testWidgets('a late answer for the year you left never replaces the year you are on', (t) async {
    final held = Completer<http.Response>();
    final api = _api()
      ..yearFixture['/api/financial_dashboard?year=2025'] = 'financial_empty'
      ..extra.add((req) async => req.url.path == '/api/financial_dashboard' && req.url.queryParameters['year'] == '2026'
          ? held.future
          : null);
    await pumpDashboard(t, const ReportsScreen(), api: api, body: () async {
      await t.tap(find.byTooltip('Previous year'));
      await settleDashboard(t);
      expect(find.text('Full year 2025'), findsOneWidget);

      held.complete(http.Response(json.encode(dashFixture('financial')), 200)); // 2026 answers late
      await settleDashboard(t);
      expect(find.text(dashFixture('financial')['revenueYtd'] as String), findsNothing);
      expect(find.text('Full year 2025'), findsOneWidget);
    });
  });

  testWidgets('Jobs compares September with August, never the October still in progress', (t) async {
    await pumpDashboard(t, const JobsDashboardScreen(), api: _api(), size: const Size(1500, 800));
    expect(find.textContaining('Oct vs Sep'), findsNothing);
    expect(find.textContaining('Sep vs Aug'), findsWidgets);
  });

  testWidgets('Commissions has no month-over-month chip when only the month in progress has payouts', (t) async {
    await pumpDashboard(t, const CommissionDashboardScreen(), api: _api(), size: const Size(1500, 800));
    expect(find.textContaining('Oct vs'), findsNothing);
    expect(find.textContaining('vs Sep'), findsNothing);
  });

  testWidgets('staff photos fall back to initials; nobody\'s name is sent to an outside avatar service', (t) async {
    for (final screen in [const CommissionDashboardScreen(), const TechniciansDashboardScreen()]) {
      await pumpDashboard(t, screen, api: _api(), size: const Size(1500, 800));
      expect(dashNetworkImageUrls(t).where((u) => u.contains('ui-avatars')), isEmpty);
      expect(find.text('AR'), findsWidgets); // Alex Rivera
    }
  });

  testWidgets('Inventory has no year selector and asks for no year', (t) async {
    final api = _api();
    await pumpDashboard(t, const InventoryDashboardScreen(), api: api);
    expect(find.byTooltip('Previous year'), findsNothing);
    expect(api.to('/api/dashboards/inventory').single.url.queryParameters.containsKey('year'), isFalse);
  });

  testWidgets('scorecards read as one phrase to a screen reader: label, figure and meaning', (t) async {
    final handle = t.ensureSemantics();
    await pumpDashboard(t, const CollectionsDashboardScreen(), api: _api());
    final f = dashFixture('collections');
    expect(
      find.bySemanticsLabel(RegExp('^Collected 2026: ${RegExp.escape(_usd(_num(f['summary']['collected'])))}\\. Payments received')),
      findsOneWidget,
    );
    handle.dispose();
  });
}
