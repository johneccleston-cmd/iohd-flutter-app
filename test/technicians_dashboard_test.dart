// The Technicians dashboard (redesigned like Collections): it fits the window with no scrolling at desktop sizes,
// every technician is on screen ranked by callbacks with their jobs and revenue, the chart's four views against last
// year, the callback period wording, and the loading, empty, error and reduced-motion states. Uses
// test/fixtures/dashboards/technicians.json and the clock pinned to Oct 22, 2026.
// Screenshots go to build/dash_shots/technicians_*.png (not goldens).
//
// Run: flutter test test/technicians_dashboard_test.dart

import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:iohd_desktop/technicians_dashboard_screen.dart';
import 'package:iohd_desktop/widgets/dashboard_kit.dart';

import 'dashboard_fit.dart';
import 'dashboard_harness.dart';

const _path = '/api/tech_stats';

final _plot = find.byWidgetPredicate((w) => w is CustomPaint && w.painter.runtimeType.toString() == '_DashChartPainter');

/// The fixture with [n] technicians.
DashFakeApi _withTechs(int n) => DashFakeApi()
  ..extra.add((req) async {
    if (req.url.path != _path) return null;
    final f = dashFixture('technicians');
    final techs = (f['techs'] as List).cast<Map<String, dynamic>>();
    for (var i = techs.length; i < n; i++) {
      techs.add({...techs.first, 'id': 'tech$i', 'name': 'Technician ${i + 1}', 'callbackCount': i % 3, 'callbackJobs': 10 + i});
    }
    f['techs'] = techs.take(n).toList();
    return http.Response(json.encode(f), 200);
  });

void main() {
  setUpAll(loadDashFonts);
  setUp(() async {
    pinDashClock();
    await dashSignIn();
  });
  tearDown(unpinDashClock);

  final techs = (dashFixture('technicians')['techs'] as List).cast<Map<String, dynamic>>();

  group('fits the window, no scrolling', () {
    dashFitTests(
      'technicians',
      () => const TechniciansDashboardScreen(),
      DashFakeApi.new,
      mustShow: [
        'Avg profit per tech',
        'Callback rate',
        '5 ÷ 72 completed jobs since Oct 5',
        for (final t in techs) t['name'] as String,
        'Profit per tech per day',
      ],
      extra: (t, size, scale) async {
        expect(t.getRect(_plot).height, greaterThan(scale == 1 ? 220 : 180), reason: 'the chart has room to read');
      },
    );

    testWidgets('ten technicians at 1280x600 (100% and 130%): no overflow, and the rest a click away', (t) async {
      for (final scale in const [1.0, 1.3]) {
        late List<String> scrollers;
        final errors = await pumpDashboard(t, const TechniciansDashboardScreen(), api: _withTechs(10), textScale: scale,
            body: () async {
          await saveDashShot(t, 'technicians_10_techs_${(scale * 100).round()}');
          scrollers = dashVerticalScrollers(t);
          if (find.textContaining('All 10').evaluate().isNotEmpty) {
            await t.tap(find.text('All 10'));
            await settleDashboard(t, frames: 5);
            expect(find.text('All technicians · 2026'), findsOneWidget);
            await t.tap(find.byTooltip('Close'));
            await settleDashboard(t, frames: 5);
          }
        });
        expect(errors.overflowed, isFalse, reason: errors.messages.toSet().join('\n'));
        expect(scrollers, isEmpty);
      }
    });

    testWidgets('1000x700 (narrower than a desktop window): one column with no overflow', (t) async {
      final errors = await pumpDashboard(t, const TechniciansDashboardScreen(), api: DashFakeApi(),
          size: const Size(1000, 700), body: () async => saveDashShot(t, 'technicians_1000x700'));
      expect(errors.overflowed, isFalse, reason: errors.messages.toSet().join('\n'));
    });

    testWidgets('nothing cycles on its own: after the entrance the page stands still', (t) async {
      await pumpDashboard(t, const TechniciansDashboardScreen(), api: DashFakeApi());
      await t.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 5));
      await t.pump(const Duration(seconds: 12));
      expect(find.textContaining('Profit per tech per day · '), findsOneWidget);
    });
  });

  group('technicians', () {
    testWidgets('ranked by callbacks per completed job since Oct 5, with jobs and revenue for the year', (t) async {
      final handle = t.ensureSemantics();
      await pumpDashboard(t, const TechniciansDashboardScreen(), api: DashFakeApi(), size: const Size(1280, 720), body: () async {
        // Fewest callbacks per completed job first: the order the old leaderboard used.
        final withJobs = techs.where((x) => (x['callbackJobs'] as num) > 0).toList()
          ..sort((a, b) {
            final ra = (a['callbackCount'] as num) / (a['callbackJobs'] as num);
            final rb = (b['callbackCount'] as num) / (b['callbackJobs'] as num);
            final c = ra.compareTo(rb);
            return c != 0 ? c : (b['callbackJobs'] as num).compareTo(a['callbackJobs'] as num);
          });
        // The top three stand on a podium (second, first, third from left to right, first tallest); the rest are
        // rows below it, fewest callbacks first.
        // The podium shows each of the top three once, and the list shows everyone once.
        Rect at(Map<String, dynamic> x) => t.getRect(find.text(x['name'] as String).first);
        Rect inList(Map<String, dynamic> x) => t.getRect(find.text(x['name'] as String).last);
        final [one, two, three, ...rest] = withJobs;
        expect(at(two).center.dx, lessThan(at(one).center.dx));
        expect(at(one).center.dx, lessThan(at(three).center.dx));
        expect(at(one).top, lessThanOrEqualTo(at(two).top), reason: 'first place stands highest');
        final tops = [for (final x in withJobs) inList(x).top];
        expect(tops, orderedEquals([...tops]..sort()), reason: 'the list is everyone, fewest callbacks first');
        for (final x in withJobs) {
          expect(inList(x).top, greaterThan(at(three).bottom), reason: 'the list is below the podium');
        }
        expect(rest, isNotEmpty);
        final first = withJobs.first;
        expect(
          find.bySemanticsLabel(RegExp('^Number 1\\. ${first['name']}, .*: ${first['completedJobsYtd']} completed jobs and '
              '${RegExp.escape(dashMoney((first['revenue'] as num).toDouble()))} revenue in 2026\\. ${first['callbackCount']} '
              'callbacks? on ${first['callbackJobs']} completed jobs since Oct 5')),
          findsOneWidget,
        );
        for (final x in techs) {
          expect(find.textContaining(dashMoney((x['revenue'] as num).toDouble())), findsOneWidget, reason: '${x['name']} revenue');
        }
        expect(find.text('AR'), findsWidgets, reason: 'initials, never an outside avatar service');
        await saveDashShot(t, 'technicians_ranked');
      });
      handle.dispose();
    });
  });

  group('chart', () {
    testWidgets('four views by hand; the average line is the scorecard figure', (t) async {
      final handle = t.ensureSemantics();
      await pumpDashboard(t, const TechniciansDashboardScreen(), api: DashFakeApi(), body: () async {
        expect(find.text('Profit per tech per day · average \$1,127'), findsOneWidget);
        expect(find.text('Average \$1,127'), findsOneWidget);
        expect(find.textContaining('Sep vs Aug'), findsOneWidget, reason: 'never the October in progress');
        for (final (tab, title) in const [('Total', 'Total profit · '), ('Jobs', 'Jobs completed · '), ('Per job', 'Profit per job · ')]) {
          await t.tap(find.bySemanticsLabel('Chart view: $tab'));
          await settleDashboard(t, frames: 10);
          expect(find.textContaining(title), findsOneWidget);
        }
        await saveDashShot(t, 'technicians_view_per_job');
      });
      handle.dispose();
    });

    testWidgets('hovering a month compares it with the same month last year', (t) async {
      await pumpDashboard(t, const TechniciansDashboardScreen(), api: DashFakeApi(), size: const Size(1500, 800),
          body: () async {
        final r = t.getRect(_plot);
        final slot = (r.width - 58) / 12;
        final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(Offset(r.left + 54 + slot * 0.5, r.center.dy)); // January
        await t.pump(const Duration(milliseconds: 100));
        final jan = ((dashFixture('technicians')['summary'] as Map)['chartData'] as List).first as Map;
        expect(find.text('Jan 2026'), findsOneWidget);
        expect(find.text('\$${jan['avgProfitPerDay']}'), findsOneWidget);
        expect(find.text('\$${jan['priorAvgProfitPerDay']}'), findsOneWidget);
        await saveDashShot(t, 'technicians_chart_hover');
        await mouse.moveTo(Offset(r.left + 54 + slot * 9.5, r.center.dy)); // October, in progress
        await t.pump(const Duration(milliseconds: 100));
        expect(find.text('Oct 2026 so far'), findsOneWidget);
        expect(find.text('Change'), findsNothing, reason: 'a part month is never compared with a whole one');
        await mouse.removePointer();
      });
    });
  });

  group('states', () {
    testWidgets('loading shows the skeleton in the same layout', (t) async {
      final held = Completer<http.Response>();
      final api = DashFakeApi()..extra.add((req) async => req.url.path == _path ? held.future : null);
      final errors = await pumpDashboard(t, const TechniciansDashboardScreen(), api: api, body: () async {
        expect(find.byType(SkeletonPulse), findsOneWidget);
        expect(dashVerticalScrollers(t), isEmpty);
        await saveDashShot(t, 'technicians_loading');
        held.complete(http.Response(json.encode(dashFixture('technicians')), 200));
        await settleDashboard(t);
        expect(find.text('Callback rate'), findsOneWidget);
      });
      expect(errors.overflowed, isFalse, reason: errors.messages.toSet().join('\n'));
    });

    testWidgets('no technicians and no jobs: says so', (t) async {
      final api = DashFakeApi()
        ..extra.add((req) async {
          if (req.url.path != _path) return null;
          final f = dashFixture('technicians_empty')..['techs'] = [];
          return http.Response(json.encode(f), 200);
        });
      final errors = await pumpDashboard(t, const TechniciansDashboardScreen(), api: api, body: () async {
        expect(find.text('No active technicians found. Users with a tech role appear here.'), findsOneWidget);
        expect(find.text('No completed jobs recorded for 2026 yet.'), findsOneWidget);
        await saveDashShot(t, 'technicians_empty');
      });
      expect(errors.overflowed, isFalse, reason: errors.messages.toSet().join('\n'));
    });

    testWidgets('no rating source: no empty "Not tracked yet" rating card', (t) async {
      await pumpDashboard(t, const TechniciansDashboardScreen(), api: DashFakeApi());
      expect(find.text('Avg customer rating'), findsNothing);
    });

    testWidgets('the rating card appears once ratings have a source', (t) async {
      final api = DashFakeApi()
        ..extra.add((req) async {
          if (req.url.path != _path) return null;
          final f = dashFixture('technicians');
          (f['summary']['metrics'] as Map)['avgCustomerRating'] = 4.82;
          return http.Response(json.encode(f), 200);
        });
      await pumpDashboard(t, const TechniciansDashboardScreen(), api: api);
      expect(find.text('Avg customer rating'), findsOneWidget);
      expect(find.text('4.82 ★'), findsOneWidget);
    });

    testWidgets('reduced motion: the first frame after the data arrives is already final', (t) async {
      final held = Completer<http.Response>();
      final api = DashFakeApi()..extra.add((req) async => req.url.path == _path ? held.future : null);
      await pumpDashboard(t, const TechniciansDashboardScreen(), api: api, reduceMotion: true, body: () async {
        held.complete(http.Response(json.encode(dashFixture('technicians')), 200));
        await t.pump();
        await t.pump();
        expect(find.text('6.9%'), findsOneWidget);
        await t.pump();
        expect(t.binding.hasScheduledFrame, isFalse);
      });
    });
  });
}
