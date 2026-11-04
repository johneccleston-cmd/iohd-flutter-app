// The Technicians dashboard (redesigned like Collections): it fits the window with no scrolling at desktop sizes,
// every technician is on screen ranked by callbacks with their jobs and revenue, the Work pace view (each tech against
// their targets, on pace or off, sample or from the server), the chart's four views against last year, the callback
// period wording, and the loading, empty, error and reduced-motion states. Uses
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

    testWidgets('nothing cycles on its own: after the entrance only the fire on the streak card moves', (t) async {
      // The fire around the streak leader's photo burns on purpose; everything else must settle.
      await pumpDashboard(t, const TechniciansDashboardScreen(), api: DashFakeApi(), body: () async {
        await t.pump(const Duration(seconds: 12));
        expect(find.textContaining('Profit per tech per day · '), findsOneWidget);
      });
    });

    testWidgets('without the streak card (an older server), the page settles completely', (t) async {
      final api = DashFakeApi()
        ..extra.add((req) async {
          if (req.url.path != _path) return null;
          final f = dashFixture('technicians');
          for (final tech in (f['techs'] as List).cast<Map<String, dynamic>>()) {
            tech.remove('jobsSinceCallback');
          }
          return http.Response(json.encode(f), 200);
        });
      await pumpDashboard(t, const TechniciansDashboardScreen(), api: api, body: () async {
        expect(find.text('Longest callback-free streak'), findsNothing);
        await t.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 5));
      });
    });

    testWidgets('the longest callback-free streak: the leader, their number, and the fire only this year', (t) async {
      await pumpDashboard(t, const TechniciansDashboardScreen(), api: DashFakeApi(), size: const Size(1500, 800), body: () async {
        // Sam Carter 7, Alex Rivera 5, Jordan Lee 1, Casey Morgan 0.
        expect(find.text('Longest callback-free streak'), findsOneWidget);
        expect(find.text('7'), findsOneWidget);
        expect(find.text('jobs in a row'), findsOneWidget);
        expect(find.text('Sam Carter · no callbacks'), findsOneWidget);
        expect(find.bySemanticsLabel(RegExp(r'^Longest callback-free streak: Sam Carter, 7 jobs in a row.*Next: Alex 5, Jordan 1, Casey 0\.')), findsOneWidget);
        await saveDashShot(t, 'technicians_streak');
      });
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
              '${RegExp.escape(_wholeUsd((first['revenue'] as num).toDouble()))} revenue in 2026\\. ${first['callbackCount']} '
              'callbacks? on ${first['callbackJobs']} completed jobs since Oct 5')),
          findsOneWidget,
        );
        for (final x in techs) {
          expect(find.textContaining(_wholeUsd((x['revenue'] as num).toDouble())), findsOneWidget, reason: '${x['name']} revenue');
        }
        expect(find.text('AR'), findsWidgets, reason: 'initials, never an outside avatar service');
        await saveDashShot(t, 'technicians_ranked');
      });
      handle.dispose();
    });
  });

  group('a year before callback tracking', () {
    // What the server really sends for 2025: no callback figures at all, and no period to count them in.
    DashFakeApi past() => DashFakeApi()
      ..extra.add((req) async {
        if (req.url.path != _path || req.url.queryParameters['year'] != '2025') return null;
        final f = dashFixture('technicians');
        final m = f['summary']['metrics'] as Map<String, dynamic>;
        m.addAll({'year': 2025, 'callbackRatePct': null, 'callbacks': 0, 'callbackJobs': 0, 'callbackPeriod': null});
        for (final tech in (f['techs'] as List).cast<Map<String, dynamic>>()) {
          tech.addAll({'callbackJobs': 0, 'callbackCount': 0});
        }
        return http.Response(json.encode(f), 200);
      });

    testWidgets('says callbacks start in 2026, not that nothing was completed, and lists by revenue', (t) async {
      final handle = t.ensureSemantics();
      final errors = await pumpDashboard(t, const TechniciansDashboardScreen(), api: past(), size: const Size(1500, 800),
          body: () async {
        await t.tap(find.byIcon(Icons.chevron_left_rounded)); // the ribbon's previous-year arrow
        await settleDashboard(t, frames: 25);
        expect(find.text('Counted from Oct 5, 2026'), findsOneWidget);
        expect(find.textContaining('No completed jobs since'), findsNothing);
        expect(find.text('Callbacks are counted from Oct 5, 2026, so 2025 has no callback ranking'), findsOneWidget);
        expect(find.text('Technicians · by revenue'), findsOneWidget);
        expect(find.text('Revenue 2025'), findsOneWidget);
        expect(find.text('Longest callback-free streak'), findsNothing);
        final byRevenue = [...techs]..sort((a, b) => (b['revenue'] as num).compareTo(a['revenue'] as num));
        final tops = [for (final x in byRevenue) t.getRect(find.text(x['name'] as String)).top];
        expect(tops, orderedEquals([...tops]..sort()), reason: 'highest revenue first');
        await saveDashShot(t, 'technicians_2025_callbacks');
        // A finished year has nothing "still to work".
        await t.tap(find.bySemanticsLabel('Chart view: Work days'));
        await settleDashboard(t, frames: 10);
        expect(find.textContaining('still to work'), findsNothing);
        expect(find.textContaining('days short of the 1,013-day target'), findsOneWidget);
      });
      expect(errors.overflowed, isFalse, reason: errors.messages.toSet().join('\n'));
      handle.dispose();
    });
  });

  group('work pace', () {
    // The office's targets (240 work days, $1,900 a day, $456k with a $600k fire goal; Dennis 53 days, $99k, $130k
    // fire goal) against sample figures, by roster place (ids sorted, Dennis last): Alex ahead on both, Casey behind
    // on both, Jordan short on profit a day but ahead for the year, Sam the other way round. On Oct 22, 211 of 2026's
    // 261 weekdays have gone by.
    Future<void> openPace(WidgetTester t) async {
      await t.tap(find.text('Work pace'));
      await settleDashboard(t, frames: 25);
    }

    for (final (size, scale, tag) in dashFitSizes) {
      testWidgets('$tag: every tech on screen, nothing scrolls, no overflow', (t) async {
        late List<String> scrollers;
        late List<String> truncated;
        final errors = await pumpDashboard(t, const TechniciansDashboardScreen(), api: DashFakeApi(), size: size, textScale: scale,
            body: () async {
          await openPace(t);
          await saveDashShot(t, 'technicians_pace_$tag');
          scrollers = dashVerticalScrollers(t);
          truncated = dashTruncatedTexts(t);
          final window = Offset.zero & size;
          final all = find.text('All 5').evaluate().isNotEmpty;
          for (final name in [for (final x in techs) x['name'] as String, 'Dennis Gray']) {
            final f = find.text(name);
            if (all && f.evaluate().isEmpty) continue;
            final r = t.getRect(f.first);
            expect(window.contains(r.topLeft) && window.contains(r.bottomRight - const Offset(0.01, 0.01)), isTrue,
                reason: '$name is on screen at $tag');
          }
          if (scale == 1.0) expect(all, isFalse, reason: 'at normal text size every tech fits at $tag');
        });
        expect(errors.overflowed, isFalse, reason: errors.messages.toSet().join('\n'));
        expect(t.takeException(), isNull);
        expect(scrollers, isEmpty, reason: 'nothing scrolls at $tag');
        if (scale == 1.0) expect(truncated, isEmpty, reason: 'no text is cut short at $tag');
      });
    }

    testWidgets('the story first, then every tech best first with all three goals against their pace', (t) async {
      final handle = t.ensureSemantics();
      await pumpDashboard(t, const TechniciansDashboardScreen(), api: DashFakeApi(), size: const Size(1500, 800), body: () async {
        expect(find.text('Technicians · fewest callbacks first'), findsOneWidget, reason: 'the callback podium comes first');
        await openPace(t);
        expect(find.text('Technicians · fewest callbacks first'), findsNothing);
        // The panel says these are sample figures; the headline answers "are they on pace?" and names who is behind.
        expect(find.bySemanticsLabel('Technicians, sample figures'), findsOneWidget);
        expect(find.text('3 of 5'), findsOneWidget);
        expect(find.text('on pace for their profit target'), findsOneWidget);
        expect(find.text('▼ 1%'), findsOneWidget);
        expect(find.text('Furthest behind: Casey Morgan, \$39k short of pace on profit'), findsOneWidget);
        // Best against their profit pace first.
        final order = ['Dennis Gray', 'Alex Rivera', 'Jordan Lee', 'Sam Carter', 'Casey Morgan'];
        final tops = [for (final n in order) t.getRect(find.text(n)).top];
        expect(tops, orderedEquals([...tops]..sort()));
        expect(find.text('On pace'), findsNWidgets(3));
        expect(find.text('Off pace'), findsNWidgets(2));
        // Each goal: done / target, and the gap to where they should be by today, in words.
        for (final s in ['198 / 240', '\$2,014 / \$1,900', '\$399k / \$456k', '▲ 4 ahead', '▲ \$114 over', '▲ \$30k ahead',
            '▼ \$57 under', '▼ 15.5 short', '▼ \$39k short',
            // Dennis: his own targets.
            '43 / 53', '\$90k / \$99k']) {
          expect(find.text(s, findRichText: true), findsOneWidget, reason: s);
        }
        for (final s in ['Team work days', 'Team profit a day', 'Team profit', "Today's pace", 'Ahead', 'Short',
            'Main goal', 'Fire goal']) {
          expect(find.text(s), findsOneWidget, reason: s);
        }
        // The fire goal is read out with the year's profit.
        expect(
          find.bySemanticsLabel(RegExp(r'^Number 2\. Alex Rivera: on pace\. Work days 198 of 240, 4 ahead\. '
              r'Profit a day \$2,014 of \$1,900, \$114 over\. Profit for the year \$399k of \$456k, fire goal \$600k, \$30k ahead\. Sample figures\.$')),
          findsOneWidget,
        );
        expect(find.bySemanticsLabel(RegExp(r'^Number 1\. Dennis Gray: .*Profit for the year \$90k of \$99k, fire goal \$130k,')), findsOneWidget);
      });
      handle.dispose();
    });

    testWidgets('a bar explains itself in the hover card', (t) async {
      await pumpDashboard(t, const TechniciansDashboardScreen(), api: DashFakeApi(), size: const Size(1500, 800), body: () async {
        await openPace(t);
        final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(t.getCenter(find.text('198 / 240', findRichText: true)));
        await settleDashboard(t, frames: 8);
        expect(find.textContaining('Alex has worked 198 days of a 240-day target for 2026. By today they should be on 194'), findsOneWidget);
        expect(find.textContaining('Sample figures until the real ones are sent.'), findsOneWidget);
        await saveDashShot(t, 'technicians_pace_hover');
        await mouse.removePointer();
      });
    });

    testWidgets('the view stays on Work pace through a change of year, and a past year speaks of targets hit or missed', (t) async {
      await pumpDashboard(t, const TechniciansDashboardScreen(), api: DashFakeApi(), size: const Size(1500, 800), body: () async {
        await openPace(t);
        await t.tap(find.byIcon(Icons.chevron_left_rounded)); // the ribbon's previous-year arrow
        await settleDashboard(t, frames: 25);
        expect(find.text('hit their profit target'), findsOneWidget);
        expect(find.text('Target'), findsOneWidget, reason: 'the line on a finished year is the target');
        expect(find.text('On pace'), findsNothing);
        expect(find.text('Hit target').evaluate().length + find.text('Missed').evaluate().length, 5);
        await saveDashShot(t, 'technicians_pace_2025');
      });
    });

    testWidgets("the server's work days and profit (the commission work days) are measured against the office's targets", (t) async {
      final api = DashFakeApi()
        ..extra.add((req) async {
          if (req.url.path != _path) return null;
          final f = dashFixture('technicians');
          // Work days to the half day, and profit so far; Dennis is not in the technicians list.
          f['pace'] = [
            {'id': 'alex.rivera', 'name': 'Alex Rivera', 'jobTitle': 'Lead Technician', 'avatarUrl': '', 'workDays': 215, 'profit': 400000},
            {'id': 'sam.carter', 'name': 'Sam Carter', 'jobTitle': 'Technician', 'avatarUrl': '', 'workDays': 144.5, 'profit': 296000},
            {'id': 'jordan.lee', 'name': 'Jordan Lee', 'jobTitle': 'Technician', 'avatarUrl': '', 'workDays': 52, 'profit': 52000},
            {'id': 'casey.morgan', 'name': 'Casey Morgan', 'jobTitle': 'Technician', 'avatarUrl': '', 'workDays': 190, 'profit': 370000},
            {'id': 'dgray', 'name': 'Dennis Gray', 'jobTitle': 'Warehouse Technician', 'avatarUrl': '', 'workDays': 29, 'profit': 27905},
          ];
          return http.Response(json.encode(f), 200);
        });
      final handle = t.ensureSemantics();
      await pumpDashboard(t, const TechniciansDashboardScreen(), api: api, size: const Size(1500, 800), body: () async {
        await openPace(t);
        expect(find.bySemanticsLabel('Technicians, against their targets'), findsOneWidget, reason: 'real figures, no sample note');
        // 240 days and $456k for the techs; Dennis 53 days and $99k. By Oct 22 that is 194 days and $369k (Dennis 43, $80k).
        for (final s in ['215 / 240', '144.5 / 240', '52 / 240', '190 / 240', '29 / 53', '\$400k / \$456k', '\$28k / \$99k']) {
          expect(find.text(s, findRichText: true), findsOneWidget, reason: s);
        }
        expect(find.text('▲ 21 ahead', findRichText: true), findsOneWidget, reason: 'Alex: 215 days against 194');
        expect(find.text('▼ 14 short', findRichText: true), findsOneWidget, reason: 'Dennis: 29 days against 43');
        expect(find.bySemanticsLabel(RegExp('Sample figures')), findsNothing);
      });
      handle.dispose();
    });

    testWidgets('targets from the server replace the sample ones', (t) async {
      final api = DashFakeApi()
        ..extra.add((req) async {
          if (req.url.path != _path) return null;
          final f = dashFixture('technicians');
          final list = (f['techs'] as List).cast<Map<String, dynamic>>();
          // Dennis comes from the server too (no fire goal for him here), so nobody is a sample.
          list.add({...list.first, 'id': 'dgray', 'name': 'Dennis Gray', 'jobTitle': 'Warehouse Technician'});
          for (final tech in list) {
            tech['pace'] = {'workDayTarget': 200, 'dayProfitTarget': 1000, 'yearProfitTarget': 200000, 'workDays': 150, 'profit': 180000};
          }
          return http.Response(json.encode(f), 200);
        });
      final handle = t.ensureSemantics();
      await pumpDashboard(t, const TechniciansDashboardScreen(), api: api, size: const Size(1500, 800), body: () async {
        await openPace(t);
        expect(find.bySemanticsLabel('Technicians, against their targets'), findsOneWidget);
        expect(find.text('5 of 5'), findsOneWidget);
        expect(find.text('150 / 200', findRichText: true), findsNWidgets(5));
        expect(find.text('\$1,200 / \$1,000', findRichText: true), findsNWidgets(5));
        expect(find.text('Fire goal'), findsNothing, reason: 'no fire goal sent, none drawn');
        expect(find.bySemanticsLabel(RegExp('Sample figures')), findsNothing);
      });
      handle.dispose();
    });

    testWidgets('ten technicians at 1280x600: the rest of the pace board a click away', (t) async {
      final errors = await pumpDashboard(t, const TechniciansDashboardScreen(), api: _withTechs(10), body: () async {
        await openPace(t);
        await saveDashShot(t, 'technicians_pace_10_techs');
        expect(find.text('All 11'), findsOneWidget, reason: 'ten technicians and Dennis');
        await t.tap(find.text('All 11'));
        await settleDashboard(t, frames: 15);
        expect(find.text('All technicians · work pace · 2026'), findsOneWidget);
        expect(find.text('Technician 10'), findsWidgets);
        await saveDashShot(t, 'technicians_pace_all_dialog');
        await t.tap(find.byTooltip('Close'));
        await settleDashboard(t, frames: 5);
      });
      expect(errors.overflowed, isFalse, reason: errors.messages.toSet().join('\n'));
    });

    testWidgets('reduced motion: the board is final on the first frame', (t) async {
      await pumpDashboard(t, const TechniciansDashboardScreen(), api: DashFakeApi(), size: const Size(1500, 800), reduceMotion: true,
          body: () async {
        await t.tap(find.text('Work pace'));
        await t.pump();
        await t.pump();
        expect(find.text('3 of 5'), findsOneWidget);
        expect(find.text('Off pace'), findsNWidgets(2));
      });
    });
  });

  group('chart', () {
    testWidgets('four views by hand; the average line is the scorecard figure', (t) async {
      final handle = t.ensureSemantics();
      // 1500x800: room for the change chip beside the title (a narrower window leaves it to the headline).
      await pumpDashboard(t, const TechniciansDashboardScreen(), api: DashFakeApi(), size: const Size(1500, 800), body: () async {
        expect(find.text('Profit per tech per day · by start month'), findsOneWidget);
        expect(find.text('Year average \$1,127'), findsOneWidget);
        expect(find.textContaining('Sep vs Aug'), findsOneWidget, reason: 'never the October in progress');
        for (final (tab, title) in const [('Work days', 'Work days against target · '), ('Actual / day', 'Actual profit per work day · ')]) {
          await t.tap(find.bySemanticsLabel('Chart view: $tab'));
          await settleDashboard(t, frames: 10);
          expect(find.textContaining(title), findsOneWidget);
        }
        expect(find.bySemanticsLabel('Chart view: Jobs'), findsNothing);
        expect(find.bySemanticsLabel('Chart view: Total'), findsNothing);
        expect(find.bySemanticsLabel('Chart view: Per job'), findsNothing);
        await t.tap(find.bySemanticsLabel('Chart view: Work days'));
        await settleDashboard(t, frames: 10);
        // The targets of every tech and Dennis added up (1,013 days) against the fixture's work days.
        expect(find.textContaining('target days still to work'), findsOneWidget);
        await saveDashShot(t, 'technicians_view_work_days');
        await t.tap(find.bySemanticsLabel('Chart view: Actual / day'));
        await settleDashboard(t, frames: 10);
        expect(find.textContaining('under the \$1,900 target'), findsOneWidget);
        // The finding reads finished months only: October is in progress, its open jobs' profit still to come.
        expect(find.textContaining('Oct was'), findsNothing);
        expect(find.textContaining('Sep was'), findsOneWidget);
        await saveDashShot(t, 'technicians_view_actual_per_day');
      });
      handle.dispose();
    });

    // The fixture: $874,320 of profit Jan-Oct over the roster's 727 days is $1,203 a day. With ten more field days a
    // month (Zac's install days, say) it is $874,320 over 827 days, $1,057; the Work days view keeps the roster's 727.
    Future<void> actualPerDay(WidgetTester t, DashFakeApi api, String perDay) async {
      await pumpDashboard(t, const TechniciansDashboardScreen(), api: api, size: const Size(1500, 800), body: () async {
        await t.tap(find.bySemanticsLabel('Chart view: Actual / day'));
        await settleDashboard(t, frames: 10);
        expect(find.text(perDay), findsOneWidget);
        await t.tap(find.bySemanticsLabel('Chart view: Work days'));
        await settleDashboard(t, frames: 10);
        expect(find.textContaining('727 of '), findsOneWidget);
      });
    }

    testWidgets("Actual / day: an older server without field days divides by the roster's work days", (t) async {
      await actualPerDay(t, DashFakeApi(), r'$1,203');
    });

    testWidgets("Actual / day divides by the server's field days (Zac's installs, former techs) when it sends them", (t) async {
      await actualPerDay(
        t,
        DashFakeApi()
          ..extra.add((req) async {
            if (req.url.path != _path) return null;
            final f = dashFixture('technicians');
            f['fieldDaysMonthly'] = [
              for (final m in (f['paceMonthly'] as List).cast<Map<String, dynamic>>())
                {'month': m['month'], 'workDays': (m['workDays'] as num) + 10},
            ];
            return http.Response(json.encode(f), 200);
          }),
        r'$1,057',
      );
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
        expect(find.text('Callback rate'), findsWidgets, reason: "the scorecard and the list's column");
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

/// "$388,910": whole dollars, as the technicians list shows revenue.
String _wholeUsd(double v) =>
    '\$${v.round().toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},')}';
