// The Jobs dashboard (redesigned like Collections): it fits the window with no scrolling at desktop sizes, the chart's
// four views, the job mix (with a split hidden when too few jobs carry its data), active jobs by status with
// every status a click away, and the loading, empty, error and reduced-motion states. Uses
// test/fixtures/dashboards/jobs.json and the clock pinned to Oct 22, 2026.
// Screenshots go to build/dash_shots/jobs_*.png (not goldens).
//
// Run: flutter test test/jobs_dashboard_test.dart

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:iohd_desktop/jobs_dashboard_screen.dart';
import 'package:iohd_desktop/widgets/dashboard_kit.dart';

import 'dashboard_fit.dart';
import 'dashboard_harness.dart';

const _path = '/api/dashboards/jobs';
const _drill = '/api/dashboards/jobs/drill';

http.Response _jobs(http.Request req) {
  final items = [
    for (final s in req.url.queryParametersAll['status'] ?? const <String>[])
      {'jobId': '81${s.length}', 'customerName': 'Customer for $s', 'status': s, 'location': '1 Main St', 'description': '',
        'startDate': '2026-03-01', 'value': 1000, 'outcome': 'open', 'daysOld': 200},
  ];
  return http.Response(json.encode({'success': true, 'count': items.length, 'items': items}), 200);
}

DashFakeApi _api() => DashFakeApi()..extra.add((req) async => req.url.path == _drill ? _jobs(req) : null);

void main() {
  setUpAll(loadDashFonts);
  setUp(() async {
    pinDashClock();
    await dashSignIn();
  });
  tearDown(unpinDashClock);

  final f = dashFixture('jobs');
  final statuses = [...(f['statusCounts'] as List).cast<Map<String, dynamic>>()]
    ..sort((a, b) => (b['count'] as num).compareTo(a['count'] as num));

  group('fits the window, no scrolling', () {
    dashFitTests(
      'jobs',
      () => const JobsDashboardScreen(),
      _api,
      mustShow: [
        'Completed jobs',
        'New customers',
        'Job mix',
        'Residential / commercial revenue',
        'Active jobs by status',
        statuses.first['status'] as String,
        'Install vs service',
      ],
    );

    testWidgets('1000x700 (narrower than a desktop window): one column with no overflow', (t) async {
      final errors = await pumpDashboard(t, const JobsDashboardScreen(), api: _api(), size: const Size(1000, 700),
          body: () async => saveDashShot(t, 'jobs_1000x700'));
      expect(errors.overflowed, isFalse, reason: errors.messages.toSet().join('\n'));
    });

    testWidgets('nothing cycles on its own: after the entrance the page stands still', (t) async {
      await pumpDashboard(t, const JobsDashboardScreen(), api: _api());
      await t.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 5));
      await t.pump(const Duration(seconds: 12));
      expect(find.textContaining('Completed jobs · '), findsOneWidget);
    });
  });

  group('statuses', () {
    testWidgets('as many statuses as fit have their own row; the rest share one that adds up and opens all of them',
        (t) async {
      final api = _api();
      await pumpDashboard(t, const JobsDashboardScreen(), api: api, body: () async {
        final other = find.textContaining('Other (');
        if (other.evaluate().isNotEmpty) {
          final n = int.parse(RegExp(r'\((\d+) status').firstMatch(t.widget<Text>(other).data!)!.group(1)!);
          final rest = statuses.skip(statuses.length - n).toList();
          final sum = rest.fold<num>(0, (s, x) => s + (x['count'] as num));
          await t.tap(other);
          await settleDashboard(t, frames: 5);
          expect(api.to(_drill).last.url.queryParametersAll['status'], [for (final x in rest) x['status']]);
          expect(find.text('Other active jobs'), findsOneWidget);
          expect(sum, greaterThan(0));
          await t.tap(find.byTooltip('Close'));
          await settleDashboard(t, frames: 5);
        }
        await t.tap(find.text(statuses.first['status'] as String));
        await settleDashboard(t, frames: 5);
        expect(api.to(_drill).last.url.queryParametersAll['status'], [statuses.first['status']]);
        expect(find.text('${statuses.first['status']} · active jobs'), findsOneWidget);
        await saveDashShot(t, 'jobs_drill_status');
      });
    });

    testWidgets('"All 239" and the Active jobs card open every active job', (t) async {
      final api = _api();
      await pumpDashboard(t, const JobsDashboardScreen(), api: api, body: () async {
        await t.tap(find.text('All 239'));
        await settleDashboard(t, frames: 5);
        expect(api.to(_drill).last.url.queryParametersAll['status'], hasLength(statuses.length));
        expect(find.text('All active jobs'), findsOneWidget);
        await t.tap(find.byTooltip('Close'));
        await settleDashboard(t, frames: 5);
        await t.tap(find.text('Active jobs'));
        await settleDashboard(t, frames: 5);
        expect(find.text('All active jobs'), findsOneWidget);
      });
    });

    testWidgets('at a taller window every status has its own row', (t) async {
      await pumpDashboard(t, const JobsDashboardScreen(), api: _api(), size: const Size(1920, 940), body: () async {
        for (final s in statuses) {
          expect(find.text(s['status'] as String), findsOneWidget);
        }
        expect(find.textContaining('Other ('), findsNothing);
      });
    });
  });

  group('chart and insights', () {
    testWidgets('four views by hand, compared Sep with Aug and never the month in progress', (t) async {
      final handle = t.ensureSemantics();
      // 1500x800: room for the change chip beside the title (a narrower window leaves it to the headline).
      await pumpDashboard(t, const JobsDashboardScreen(), api: _api(), size: const Size(1500, 800), body: () async {
        expect(find.text('Completed jobs · by start month'), findsOneWidget);
        expect(find.textContaining('Sep vs Aug'), findsOneWidget);
        // The dashed average and the callout use the same finished months (Jan-Sep, 1,498 jobs): Sep's 157 is under
        // the 166 line, as the words say. October, still in progress, would have dragged the line down to 151.
        expect(find.text('Average month 166'), findsOneWidget);
        expect(find.textContaining('Sep was 6% under the average'), findsOneWidget);
        expect(find.text('jobs completed so far'), findsOneWidget);
        expect(find.textContaining('Busiest month: '), findsOneWidget);
        expect(find.textContaining('Oct vs Sep'), findsNothing);
        for (final (tab, title) in const [
          ('Per job', 'Revenue and profit per job · '),
          ('Res vs Com', 'Residential vs commercial · '),
          ('Install vs service', 'Install vs service · '),
        ]) {
          await t.tap(find.bySemanticsLabel('Chart view: $tab'));
          await settleDashboard(t, frames: 10);
          expect(find.textContaining(title), findsOneWidget);
        }
        await t.tap(find.bySemanticsLabel('Chart view: Per job'));
        await settleDashboard(t, frames: 10);
        expect(find.text('profit per completed job'), findsOneWidget, reason: 'profit sits beside revenue per job');
        expect(find.text('revenue per completed job'), findsOneWidget);
        await saveDashShot(t, 'jobs_view_per_job');
        await t.tap(find.bySemanticsLabel('Chart view: Install vs service'));
        await settleDashboard(t, frames: 10);
        await saveDashShot(t, 'jobs_view_install');
      });
      handle.dispose();
    });

    testWidgets("job mix: the two splits, and not the busiest month or average the chart's first view already gives",
        (t) async {
      await pumpDashboard(t, const JobsDashboardScreen(), api: _api());
      expect(find.text('Job mix · completed jobs, 2026'), findsOneWidget);
      expect(find.text('Jun · 196'), findsNothing);
      expect(find.text('Busiest month'), findsNothing);
      expect(find.textContaining('Busiest month: Jun, 196 jobs'), findsOneWidget, reason: "the chart's callout");
      expect(find.text('Average month 166'), findsOneWidget, reason: "the chart's key");
      expect(find.text('Install / service jobs'), findsOneWidget);
      expect(find.text('Residential / commercial revenue'), findsOneWidget);
      expect(find.byTooltip('74% Install, 26% Service (share of completed jobs)'), findsOneWidget);
      expect(find.byTooltip('64% Residential, 36% Commercial (share of completed-job revenue)'), findsOneWidget);
    });

    testWidgets('a split most jobs have no data for is hidden, and says why', (t) async {
      final api = _api()
        ..extra.insert(0, (req) async {
          if (req.url.path != _path) return null;
          final body = dashFixture('jobs');
          body['splitCoverage'] = {'completedJobs': 1506, 'jobsWithCategories': 120, 'jobsWithLineItems': 1446};
          return http.Response(json.encode(body), 200);
        });
      await pumpDashboard(t, const JobsDashboardScreen(), api: api);
      expect(find.text('Not enough data'), findsOneWidget);
      expect(find.byTooltip('Only 120 of 1,506 completed jobs in 2026 have install/service data.'), findsOneWidget);
      expect(find.byTooltip('64% Residential, 36% Commercial (share of completed-job revenue)'), findsOneWidget,
          reason: 'the other split is covered');
    });
  });

  group('states', () {
    testWidgets('loading shows the skeleton in the same layout', (t) async {
      final held = Completer<http.Response>();
      final api = _api()..extra.insert(0, (req) async => req.url.path == _path ? held.future : null);
      final errors = await pumpDashboard(t, const JobsDashboardScreen(), api: api, body: () async {
        expect(find.byType(SkeletonPulse), findsOneWidget);
        expect(dashVerticalScrollers(t), isEmpty);
        await saveDashShot(t, 'jobs_loading');
        held.complete(http.Response(json.encode(dashFixture('jobs')), 200));
        await settleDashboard(t);
        expect(find.text('New customers'), findsOneWidget);
      });
      expect(errors.overflowed, isFalse, reason: errors.messages.toSet().join('\n'));
    });

    testWidgets('an empty year says so in every panel', (t) async {
      final api = _api()..fixture[_path] = 'jobs_empty';
      final errors = await pumpDashboard(t, const JobsDashboardScreen(), api: api, body: () async {
        expect(find.text('No job data for 2026 yet.'), findsOneWidget);
        expect(find.text('No completed jobs in 2026 yet.'), findsOneWidget);
        expect(find.text('No active jobs today.'), findsOneWidget, reason: 'no active jobs is a fact, not missing data');
        await saveDashShot(t, 'jobs_empty');
      });
      expect(errors.overflowed, isFalse, reason: errors.messages.toSet().join('\n'));
    });

    testWidgets('a past year: the definitions say "in 2025", the today figures stay today, and nothing says "yet"',
        (t) async {
      final handle = t.ensureSemantics();
      final api = _api()..yearFixture['$_path?year=2025'] = 'jobs_empty';
      await pumpDashboard(t, const JobsDashboardScreen(), api: api, body: () async {
        expect(find.bySemanticsLabel(RegExp(r'^Completed jobs: 1,506\. Jobs that started between Jan 1 and today and')),
            findsOneWidget);
        await t.tap(dashYearArrow('Previous year'));
        await settleDashboard(t);
        expect(api.to(_path).last.url.queryParameters['year'], '2025');
        expect(find.bySemanticsLabel(RegExp(r'^Completed jobs: 0\. Jobs that started in 2025 and')), findsOneWidget);
        expect(find.bySemanticsLabel(RegExp(r'^New customers: 0\. Customers \(matched by name\) whose first-ever job started in 2025\.')),
            findsOneWidget);
        expect(find.text('By start date · all of 2025'), findsOneWidget);
        expect(find.text('From any year · today'), findsOneWidget);
        expect(find.text('No job data for 2025.'), findsOneWidget);
        expect(find.text('No completed jobs in 2025.'), findsOneWidget);
      });
      handle.dispose();
    });

    testWidgets('reduced motion: the first frame after the data arrives is already final', (t) async {
      final held = Completer<http.Response>();
      final api = _api()..extra.insert(0, (req) async => req.url.path == _path ? held.future : null);
      await pumpDashboard(t, const JobsDashboardScreen(), api: api, reduceMotion: true, body: () async {
        held.complete(http.Response(json.encode(dashFixture('jobs')), 200));
        await t.pump();
        await t.pump();
        expect(find.text('1,506'), findsWidgets);
        await t.pump();
        expect(t.binding.hasScheduledFrame, isFalse);
      });
    });
  });
}
