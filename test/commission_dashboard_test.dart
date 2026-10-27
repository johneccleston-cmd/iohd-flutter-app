// The Commissions dashboard (redesigned like Collections): it fits the window with no scrolling at desktop sizes,
// everyone paid is on screen with this week's hurdle (current year only), a long list is a click away instead of
// scrolling, the chart's two views, the payroll card and the retainage release, and the loading, empty, error and
// reduced-motion states. Uses test/fixtures/dashboards/commissions.json and the clock pinned to Oct 22, 2026.
// Screenshots go to build/dash_shots/commissions_*.png (not goldens).
//
// Run: flutter test test/commission_dashboard_test.dart

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:iohd_desktop/commission_dashboard_screen.dart';
import 'package:iohd_desktop/widgets/dashboard_kit.dart';

import 'dashboard_fit.dart';
import 'dashboard_harness.dart';

const _path = '/api/commissions_stats';

DashFakeApi _api() => DashFakeApi()
  ..extra.add((req) async => req.url.path == '/api/payroll/runs' ? http.Response(json.encode({'runs': []}), 200) : null);

/// The fixture with [n] people (the five saved ones, then made-up technicians).
DashFakeApi _withPeople(int n) => _api()
  ..extra.add((req) async {
    if (req.url.path != _path) return null;
    final f = dashFixture('commissions');
    final techs = (f['technicians'] as List).cast<Map<String, dynamic>>();
    for (var i = techs.length; i < n; i++) {
      techs.add({
        ...techs.first,
        'id': 'tech$i',
        'name': 'Technician ${i + 1}',
        'ytdCommission': 100 + i,
        'weekGross': 100.0 * i,
        'hurdleStreak': 0,
        'isSales': false,
        'onPool': true,
      });
    }
    f['technicians'] = techs.take(n).toList();
    return http.Response(json.encode(f), 200);
  });

void main() {
  setUpAll(loadDashFonts);
  setUp(() async {
    pinDashClock();
    await dashSignIn();
  });
  tearDown(unpinDashClock);

  final names = [for (final t in dashFixture('commissions')['technicians'] as List) t['name'] as String];

  group('fits the window, no scrolling', () {
    dashFitTests(
      'commissions',
      () => const CommissionDashboardScreen(),
      _api,
      mustShow: [
        'Total payouts',
        'Commission % of revenue',
        ...names,
        'Paid by month',
        'Run payroll',
        'Retainage release',
      ],
      extra: (t, size, scale) async {
        expect(find.textContaining('All 5'), findsNothing, reason: 'everyone has a row; nothing is a click away');
      },
    );

    for (final n in [8, 12]) {
      testWidgets('$n people at 1280x600 and 1500x800 at 130%: no overflow, never a scrolling list', (t) async {
        for (final (size, scale) in const [(Size(1280, 600), 1.0), (Size(1500, 800), 1.3)]) {
          late List<String> scrollers;
          final errors = await pumpDashboard(t, const CommissionDashboardScreen(), api: _withPeople(n), size: size,
              textScale: scale, body: () async {
            await saveDashShot(t, 'commissions_${n}_people_${size.width.toInt()}_${(scale * 100).round()}');
            scrollers = dashVerticalScrollers(t);
          });
          expect(errors.overflowed, isFalse, reason: errors.messages.toSet().join('\n'));
          expect(scrollers, isEmpty);
        }
      });
    }

    testWidgets('more people than rows: the rest are one click away, in a list of everyone', (t) async {
      await pumpDashboard(t, const CommissionDashboardScreen(), api: _withPeople(14), body: () async {
        expect(find.text('All 14'), findsOneWidget);
        expect(find.text('Technician 14'), findsNothing);
        await t.tap(find.text('All 14'));
        await settleDashboard(t, frames: 5);
        expect(find.text('Everyone paid commission · 2026'), findsOneWidget);
        await t.scrollUntilVisible(find.text('Technician 14'), 200, scrollable: find.byType(Scrollable).last);
        expect(find.text('Technician 14'), findsOneWidget);
        await saveDashShot(t, 'commissions_all_people');
      });
    });

    for (final (size, tag) in const [(Size(1000, 700), '1000x700')]) {
      testWidgets('$tag (narrower than a desktop window): one column with no overflow', (t) async {
        final errors = await pumpDashboard(t, const CommissionDashboardScreen(), api: _api(), size: size,
            body: () async => saveDashShot(t, 'commissions_$tag'));
        expect(errors.overflowed, isFalse, reason: errors.messages.toSet().join('\n'));
      });
    }
  });

  group('people and the hurdle', () {
    testWidgets('paid this year, locked retainage, and this pay week against the hurdle', (t) async {
      final handle = t.ensureSemantics();
      await pumpDashboard(t, const CommissionDashboardScreen(), api: _api(), body: () async {
        final f = dashFixture('commissions');
        final techs = (f['technicians'] as List).cast<Map<String, dynamic>>();
        for (final p in techs) {
          final paid = p['onPool'] == false ? 'Sales' : dashMoney((p['ytdCommission'] as num).toDouble());
          expect(find.text(paid), findsWidgets, reason: '${p['name']} paid');
        }
        final hurdle = (f['meta']['weeklyThreshold'] as num).toDouble();
        final onHurdle = techs.where((p) => p['isSales'] != true);
        final cleared = onHurdle.where((p) => (p['weekGross'] as num) >= hurdle).length;
        expect(find.text('$cleared of ${onHurdle.length} cleared'), findsOneWidget);
        expect(find.text('This week'), findsOneWidget);
        expect(find.bySemanticsLabel(RegExp(r'^Alex Rivera: paid \$2,410\.00 in 2026, locked retainage \$0\.00\. '
            r'This pay week \$781\.74, \$31\.74 over the \$750 hurdle, 2 weeks in a row at or above it$')), findsOneWidget);
        await saveDashShot(t, 'commissions_people');
      });
      handle.dispose();
    });

    testWidgets('a past year has no hurdle column (the meters are for the current pay week)', (t) async {
      final api = _api()..yearFixture['$_path?year=2025'] = 'commissions_empty';
      await pumpDashboard(t, const CommissionDashboardScreen(), api: api, body: () async {
        await t.tap(find.byTooltip('Previous year'));
        await settleDashboard(t);
        expect(api.to(_path).last.url.queryParameters['year'], '2025');
        expect(find.text('This week'), findsNothing);
        expect(find.textContaining('cleared'), findsNothing);
        expect(find.textContaining('Retainage release · '), findsOneWidget, reason: 'the next release is about today');
        await saveDashShot(t, 'commissions_2025');
      });
    });
  });

  group('chart, payroll, release', () {
    testWidgets('two views picked by hand; nothing switches on its own', (t) async {
      await pumpDashboard(t, const CommissionDashboardScreen(), api: _api(), body: () async {
        expect(find.text('Paid by month · \$4.6k in 2026'), findsOneWidget);
        expect(find.textContaining('vs Sep'), findsNothing, reason: 'only October has payouts, and it is not over');
        await t.pump(const Duration(seconds: 12));
        expect(find.text('Paid by month · \$4.6k in 2026'), findsOneWidget);
        await t.tap(find.text('Revenue'));
        await settleDashboard(t, frames: 10);
        expect(find.textContaining('Revenue by month · '), findsOneWidget);
        await saveDashShot(t, 'commissions_view_revenue');
      });
    });

    testWidgets('payroll says whether last week is run, offers the run and the history; the release counts down', (t) async {
      await pumpDashboard(t, const CommissionDashboardScreen(), api: _api(), body: () async {
        expect(find.text('Pay week Oct 12 – Oct 18'), findsOneWidget);
        expect(find.text('Not run yet'), findsOneWidget);
        expect(find.text('Run payroll'), findsOneWidget);
        expect(find.byTooltip('No payroll has been finalized yet.'), findsOneWidget);
        expect(find.text('Run history'), findsOneWidget, reason: 'the full run history is one click away');
        expect(find.text('Retainage release · Apr 1'), findsOneWidget);
        expect(find.text('Nothing scheduled'), findsOneWidget);
      });
    });

    testWidgets('the payroll runs failing to load says so plainly, with Try again', (t) async {
      final api = DashFakeApi()
        ..extra.add((req) async => req.url.path == '/api/payroll/runs' ? http.Response('{}', 500) : null);
      await pumpDashboard(t, const CommissionDashboardScreen(), api: api, body: () async {
        expect(find.text("Couldn't load the payroll runs (error 500)."), findsOneWidget);
        expect(find.text('Try again'), findsOneWidget);
        expect(find.text('\$4,622.40'), findsWidgets, reason: 'the rest of the page still shows');
      });
    });
  });

  group('states', () {
    testWidgets('loading shows the skeleton in the same layout', (t) async {
      final held = Completer<http.Response>();
      final api = _api()..extra.insert(0, (req) async => req.url.path == _path ? held.future : null);
      final errors = await pumpDashboard(t, const CommissionDashboardScreen(), api: api, body: () async {
        expect(find.byType(SkeletonPulse), findsOneWidget);
        expect(dashVerticalScrollers(t), isEmpty);
        await saveDashShot(t, 'commissions_loading');
        held.complete(http.Response(json.encode(dashFixture('commissions')), 200));
        await settleDashboard(t);
        expect(find.text('Total payouts'), findsOneWidget);
      });
      expect(errors.overflowed, isFalse, reason: errors.messages.toSet().join('\n'));
    });

    testWidgets('an empty year renders without errors and says so', (t) async {
      final api = _api()..fixture[_path] = 'commissions_empty';
      final errors = await pumpDashboard(t, const CommissionDashboardScreen(), api: api, body: () async {
        expect(find.text('Nothing recorded for 2026 yet.'), findsOneWidget);
        await saveDashShot(t, 'commissions_empty');
      });
      expect(errors.overflowed, isFalse, reason: errors.messages.toSet().join('\n'));
    });

    testWidgets('reduced motion: figures are final at once and the flames stand still', (t) async {
      final held = Completer<http.Response>();
      final api = _api()..extra.insert(0, (req) async => req.url.path == _path ? held.future : null);
      await pumpDashboard(t, const CommissionDashboardScreen(), api: api, reduceMotion: true, body: () async {
        held.complete(http.Response(json.encode(dashFixture('commissions')), 200));
        await t.pump();
        await t.pump();
        expect(find.text('\$4,622.40'), findsOneWidget);
        await t.pump();
        expect(t.binding.hasScheduledFrame, isFalse);
      });
    });
  });
}
