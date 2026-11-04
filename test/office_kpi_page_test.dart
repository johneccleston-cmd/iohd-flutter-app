// The office KPI page (lib/employee_kpi_office.dart) for Bella Hansberger, on production's figures
// (test/office_kpi_fixture.dart): it fits the desktop sizes without scrolling, every metric and animation of the page
// before it is still there, the figures and captions match the records, the year picker and Refresh ask the server
// again, and failures and an older server are handled. Screenshots go to build/dash_shots/.
//   flutter test test/office_kpi_page_test.dart

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:iohd_desktop/config/auth_session.dart';
import 'package:iohd_desktop/kpi_dashboard_screen.dart';

import 'dashboard_fit.dart';
import 'dashboard_harness.dart';
import 'office_kpi_fixture.dart';

/// Oct 30, 2026, 9:30 AM.
final _now = DateTime(2026, 10, 30, 9, 30);

/// A fake server for the office page. [kpisStatus] forces an error on the page's own request (the first one, which
/// decides the page, always answers); [kpisGate] holds that answer back; [mutate] changes the office part before it goes out.
DashFakeApi offApi({
  bool withOffice = true,
  int Function()? kpisStatus,
  Completer<void>? kpisGate,
  Completer<void>? detailsGate,
  void Function(Map<String, dynamic> office)? mutate,
  bool collections = true,
  void Function(Map<String, dynamic> collections)? mutateCollections,
}) {
  final api = DashFakeApi();
  var kpiCalls = 0;
  api.extra.add((req) async {
    final path = req.url.path;
    if (path == '/users') return offJson(offUsersBody());
    final kpis = RegExp(r'^/api/employees/([^/]+)/kpis$').firstMatch(path);
    if (kpis != null) {
      // The first request is the details load that decides which page this person gets; the page's own follow.
      final first = ++kpiCalls == 1;
      if (first && detailsGate != null) await detailsGate.future;
      if (!first && kpisGate != null) await kpisGate.future;
      final status = first ? 200 : (kpisStatus?.call() ?? 200);
      if (status != 200) return offJson({'error': 'simulated'}, status);
      if (Uri.decodeComponent(kpis[1]!) != bella.username) return offJson({'success': false, 'error': 'Employee not found.'}, 404);
      final year = int.parse(req.url.queryParameters['year'] ?? '2026');
      final body = offKpisBody(year: year, withOffice: withOffice);
      if (withOffice && mutate != null) mutate(body['office'] as Map<String, dynamic>);
      return offJson(body);
    }
    if (path == '/api/dashboards/collections') {
      if (!collections) return offJson({'error': 'no access'}, 403);
      final body = offCollectionsBody(year: int.parse(req.url.queryParameters['year'] ?? '2026'));
      mutateCollections?.call(body);
      return offJson(body);
    }
    if (RegExp(r'^/api/employees/[^/]+/missed_calls$').hasMatch(path)) return offJson(offMissedListBody());
    return null;
  });
  return api;
}

Widget _page() => EmployeeKpiScreen(employeeId: bella.username);

/// A server that sends no call-back figures (an older one): the response graph has only its Preview.
void _noCallbacks(Map<String, dynamic> office) => (office['missedCalls'] as Map).remove('callbacks');

Finder _rich(String text) => find.textContaining(text, findRichText: true);

/// Lets [n] seconds pass a second at a time: the chart's clock is an animation, and a ticker only counts the time
/// between frames it sees (one long pump would just start it).
Future<void> _seconds(WidgetTester t, int n) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(seconds: 1));
  }
}

void main() {
  setUpAll(loadDashFonts);
  setUp(() async {
    pinDashClock(_now);
    await dashSignIn();
  });
  tearDown(unpinDashClock);

  // ---------------------------------------------------------------------------------------------------------------
  // Fits every desktop size, at 100% and 130% text.
  // ---------------------------------------------------------------------------------------------------------------
  dashFitTests(
    'office_bella',
    _page,
    () => offApi(),
    mustShow: [
      'BELLA HANSBERGER',
      'Outstanding',
      r'$238,133',
      'Over 90 days',
      'Collection rate',
      'Call answer rate',
      'Missed calls',
      'Customer response time',
      'Scheduling errors',
      'Unpaid invoices by stage',
      r'$83,575', // the last stage, Check on Payment (named "Checking" in the smallest layout)
      'Customer reviews',
    ],
    // The review quote is cut short on purpose, with a link to read it whole.
    mayCut: (text) => text.contains('Bella responded the same morning'),
  );

  // ---------------------------------------------------------------------------------------------------------------
  // Nothing the page showed before is gone (a rule for every KPI page)
  // ---------------------------------------------------------------------------------------------------------------
  testWidgets('every metric of the previous page is still on it', (t) async {
    await pumpDashboard(t, _page(), api: offApi(), size: const Size(1500, 800), body: () async {
      // Profile: rank, years badge, integrity score; morale in the title bar (nothing records it yet).
      expect(find.textContaining('Rank #'), findsOneWidget);
      expect(find.text('2 yrs'), findsOneWidget);
      expect(find.text('100%'), findsOneWidget);
      expect(find.text('Morale'), findsOneWidget);
      // Only the technician and warehouse pages carry a peer rating.
      expect(find.text('Peer rating'), findsNothing);
      // The scorecards, and scheduling errors, which nothing records yet.
      for (final label in ['Outstanding', 'Over 90 days', 'Collection rate', 'Call answer rate', 'Scheduling errors']) {
        expect(find.text(label), findsWidgets, reason: label);
      }
      expect(find.text('Not tracked yet'), findsOneWidget);
      // Customer response time is a graph (asked for 2026-10-30), now of how long customers wait for a call back after a
      // missed call, from Quo (asked for 2026-11-03).
      expect(_rich('Customer response time · last 30 days'), findsOneWidget);
      expect(find.text('typical wait'), findsOneWidget);
      expect(find.text('called back within the hour'), findsOneWidget);
      // The missed-calls graph, its list and the lead-to-booked line. Cash by month moved to the Collections dashboard
      // (asked for 2026-10-30); the collection rate still carries the year's cash.
      expect(_rich('Missed calls · last 30 days'), findsOneWidget);
      expect(find.text('View list'), findsOneWidget);
      for (final tab in ['Missed calls', 'Leads']) {
        expect(find.text(tab), findsWidgets, reason: tab);
      }
      expect(find.text('Cash'), findsNothing);
      // Unpaid invoices by stage, all six, and the reviews.
      for (final stage in ['Final Invoice Sent', '14 Day Notice', '30 Day Notice', '60 Day Notice', '90 Day Notice', 'Check on Payment']) {
        expect(find.text(stage), findsOneWidget, reason: stage);
      }
      expect(find.text('Customer reviews'), findsOneWidget);
      expect(find.textContaining('Bella responded the same morning'), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------------------------------------------------
  // The figures, against the records
  // ---------------------------------------------------------------------------------------------------------------
  testWidgets("every figure and caption matches the server's answer", (t) async {
    final api = offApi();
    final errors = await pumpDashboard(t, _page(), api: api, size: const Size(1500, 800), body: () async {
      expect(find.text(r'$238,133'), findsOneWidget);
      expect(find.text(r'$22,577'), findsOneWidget); // the scorecard
      expect(_rich(r'$22,577  40 jobs · 9%'), findsOneWidget); // the 90 Day Notice stage
      expect(find.text('91.3%'), findsOneWidget);
      expect(find.text(r'$2,512,579 collected'), findsOneWidget);
      expect(find.text('Owed on 209 invoiced jobs'), findsOneWidget);
      // Calls: 1,299 of 2,090 answered this year (the caption says which stretch); 123 of 328 missed in the last 30 days.
      expect(find.text('62.2%'), findsOneWidget);
      expect(find.textContaining('1,299 of 2,090'), findsOneWidget);
      expect(find.textContaining(RegExp(r'^1,299 of 2,090.* · Jan 1 – today$')), findsOneWidget);
      expect(find.text('123'), findsWidgets);
      expect(find.text('of 328 calls · last 30 days'), findsOneWidget);
      // The headline of the first chart view and its finding.
      expect(find.text('calls missed'), findsOneWidget);
      expect(find.text('answered'), findsOneWidget);
      // 205 of the last 30 days' 328, to one decimal like the year's 62.2%: two figures, not one rounded two ways.
      expect(find.text('62.5%'), findsOneWidget);
      expect(find.text('Worst day: Mon Oct 12, 11 of 24 calls missed'), findsOneWidget);
      // The stages: the amount, jobs and share.
      expect(_rich(r'$83,575  12 jobs · 35%'), findsOneWidget);
      // A stage, not an age: the 90 Day Notice is the notice the job has reached.
      expect(find.text(r'$22,577 is at the 90 Day Notice stage'), findsOneWidget);
      // One request for the page itself, for this year, by username; the Collections dashboard for the same year.
      expect(api.to('/api/employees/bella/kpis').last.url.queryParameters['year'], '2026');
      expect(api.to('/api/dashboards/collections').last.url.queryParameters['year'], '2026');
      // The header: name, title, time with the company, and how old the figures are.
      expect(find.text('BELLA HANSBERGER'), findsOneWidget);
      expect(find.text('Office · 2 yrs at IOHD'), findsOneWidget);
      expect(find.text('Updated just now'), findsOneWidget);
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  // ---------------------------------------------------------------------------------------------------------------
  // Animations
  // ---------------------------------------------------------------------------------------------------------------
  testWidgets('the chart steps through its two views every 8 seconds, and holds while the pointer is on it', (t) async {
    await pumpDashboard(t, _page(), api: offApi(), size: const Size(1500, 800), body: () async {
      expect(_rich('Missed calls · last 30 days'), findsOneWidget);
      // The chart rings the worst day its callout names, and the key says what the ring is.
      expect(find.text('Worst day'), findsOneWidget);
      await _seconds(t, 8);
      await settleDashboard(t, frames: 12);
      expect(_rich('Lead to booked job · by month'), findsOneWidget);
      expect(find.textContaining('No leads are recorded yet'), findsOneWidget);
      await saveDashShot(t, 'office_bella_leads_view');
      // Pointer on the chart: it stays put.
      final title = _rich('Lead to booked job · by month');
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: t.getCenter(title));
      await mouse.moveTo(t.getCenter(title) + const Offset(0, 120));
      await _seconds(t, 9);
      expect(_rich('Lead to booked job · by month'), findsOneWidget);
      await mouse.removePointer();
      await _seconds(t, 9);
      await settleDashboard(t, frames: 12);
      expect(_rich('Missed calls · last 30 days'), findsOneWidget);
    });
  });

  for (final scale in const [1.0, 1.3]) {
    testWidgets('every chart view fits the smallest window (1280x600, text ${(scale * 100).round()}%)', (t) async {
      final errors = await pumpDashboard(t, _page(), api: offApi(), size: const Size(1280, 600), textScale: scale, body: () async {
        for (final view in ['Leads']) {
          await t.tap(find.text(view));
          await settleDashboard(t, frames: 25);
          await saveDashShot(t, 'office_bella_1280x600_${view.toLowerCase()}_${(scale * 100).round()}');
        }
      });
      expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
    });
  }

  testWidgets('stage shares add up to 100, and a sliver reads "<1%", never 0%', (t) async {
    final errors = await pumpDashboard(
      t,
      _page(),
      api: offApi(mutateCollections: (c) {
        final stages = (c['stages'] as List).cast<Map<String, dynamic>>();
        stages[3]['amount'] = 500; // 60 Day Notice
        stages[3]['jobCount'] = 1;
      }),
      size: const Size(1500, 800),
      body: () async {
        expect(_rich(r'$500  1 job · <1%'), findsOneWidget);
        // 68,390, 44,494, 10,492, 500, 22,577 and 83,575: largest remainders, so the six add up to 100.
        var sum = 0;
        for (final m in RegExp(r'· (\d+)%').allMatches(
          t.widgetList<RichText>(find.byType(RichText)).map((r) => r.text.toPlainText()).where((s) => s.contains(' job')).join('\n'),
        )) {
          sum += int.parse(m[1]!);
        }
        expect(sum, 100);
      },
    );
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('every stage at \$0 is nothing owed: the plain empty state, not six rows of zeros', (t) async {
    final errors = await pumpDashboard(
      t,
      _page(),
      api: offApi(mutateCollections: (c) {
        for (final s in (c['stages'] as List).cast<Map<String, dynamic>>()) {
          s['amount'] = 0;
          s['jobCount'] = 0;
        }
        (c['summary'] as Map<String, dynamic>)
          ..['outstanding'] = 0
          ..['over90'] = 0;
      }),
      size: const Size(1500, 800),
      body: () async {
        expect(find.text('Nothing is waiting to be collected'), findsOneWidget);
        expect(find.text('Final Invoice Sent'), findsNothing);
      },
    );
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('leads, once recorded, tell their story', (t) async {
    final errors = await pumpDashboard(
      t,
      _page(),
      api: offApi(mutate: (o) {
        o['leadToBooked'] = {
          'leads': [10, 12, 20, 25, 30, 28, 26, 24, 22, 15, 0, 0],
          'booked': [4, 6, 10, 15, 18, 14, 13, 12, 12, 9, 0, 0],
        };
      }),
      size: const Size(1500, 800),
      body: () async {
        await t.tap(find.text('Leads'));
        await settleDashboard(t, frames: 25);
        expect(find.text('of leads booked'), findsOneWidget);
        expect(find.text('of 212 leads'), findsOneWidget);
        expect(find.textContaining('Best month:'), findsOneWidget);
        await saveDashShot(t, 'office_bella_leads_recorded');
      },
    );
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('hovering a scorecard brings its definition in as an animated card, inside the window', (t) async {
    final errors = await pumpDashboard(t, _page(), api: offApi(), size: const Size(1500, 800), body: () async {
      Finder card() => find.textContaining('Everything customers still owe on jobs that have been invoiced');
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(1, 400));
      await mouse.moveTo(t.getCenter(find.text('Outstanding').first));
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 80));
      expect(card(), findsOneWidget);
      await settleDashboard(t, frames: 5);
      await saveDashShot(t, 'office_bella_hover_card');
      // The last scorecard's card opens leftwards, so it stays inside the window.
      await mouse.moveTo(t.getCenter(find.text('Scheduling errors')));
      await settleDashboard(t, frames: 8);
      // The call answer rate says which lines count and from when.
      await mouse.moveTo(t.getCenter(find.text('Call answer rate')));
      await settleDashboard(t, frames: 8);
      expect(find.textContaining("Bella's own line all year and the main office number from Mar 7, 2026"), findsOneWidget);
      await mouse.moveTo(t.getCenter(find.text('Scheduling errors')));
      await settleDashboard(t, frames: 8);
      final last = find.textContaining('Jobs booked wrongly');
      expect(last, findsOneWidget);
      expect(t.getRect(last).right, lessThanOrEqualTo(1500));
      await mouse.removePointer();
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  Finder moraleBadge() => find.byWidgetPredicate((w) => w is Tooltip && (w.message ?? '').startsWith('Morale'));

  testWidgets('morale in the title bar previews sample scores, tries others, then hides', (t) async {
    final errors = await pumpDashboard(t, _page(), api: offApi(), size: const Size(1500, 800), body: () async {
      await t.tap(moraleBadge());
      await settleDashboard(t, frames: 12);
      expect(find.text('3.6'), findsOneWidget);
      expect(find.text('Morale · sample'), findsOneWidget);
      await t.tap(moraleBadge());
      await settleDashboard(t, frames: 4);
      expect(find.text('4.5'), findsOneWidget);
      for (var i = 0; i < 3; i++) {
        await t.tap(moraleBadge());
        await settleDashboard(t, frames: 4);
      }
      expect(find.text('Morale · sample'), findsNothing);
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  // ---------------------------------------------------------------------------------------------------------------
  // Customer response time: nothing records it, so it says so; the Preview shows its story on sample days
  // ---------------------------------------------------------------------------------------------------------------
  for (final (size, scale, tag) in const [
    (Size(1500, 800), 1.0, '1500x800'),
    (Size(1280, 600), 1.0, '1280x600'),
    (Size(1366, 768), 1.0, '1366x768'),
    (Size(1920, 940), 1.0, '1920x940'),
    (Size(1280, 600), 1.3, '1280x600_text130'),
  ]) {
    testWidgets('the response graph previews sample days and tells their story ($tag)', (t) async {
      final errors = await pumpDashboard(t, _page(), api: offApi(mutate: _noCallbacks), size: size, textScale: scale, body: () async {
        expect(find.text('No call-back times from the server yet'), findsOneWidget);
        await t.tap(find.text('Preview with sample data'));
        await settleDashboard(t, frames: 25);
        // Labelled a sample, with the headline, the slowest day and the goal it is measured against.
        expect(_rich('Customer response time · sample'), findsOneWidget);
        expect(find.text('typical wait'), findsOneWidget);
        expect(find.text('called back within the hour'), findsOneWidget);
        // The finding's last parts give way, whole, when the line is too narrow for all of it (never cut mid-word):
        // the calls not called back always show, the slowest day and the days over the hour where they fit.
        expect(find.textContaining(RegExp(r'^\d+ calls? not called back')), findsOneWidget);
        expect(dashTruncatedTexts(t).where((s) => s.contains('not called back')), isEmpty, reason: 'the finding is not cut short');
        if (size.width >= 1500) {
          expect(find.textContaining('lowest day: '), findsOneWidget);
          expect(find.textContaining('days over the hour'), findsOneWidget);
        }
        // The same Preview as morale's: the title bar's morale shows its sample too.
        if (size.width >= 1400) expect(find.text('Morale · sample'), findsOneWidget);
        await saveDashShot(t, 'office_bella_response_sample_$tag');
        // Hide sample puts it back.
        await t.tap(find.text('Hide sample'));
        await settleDashboard(t, frames: 12);
        expect(find.text('No call-back times from the server yet'), findsOneWidget);
      });
      expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
    });
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Customer response time from Quo: how long the customers behind the missed calls waited for a call back
  // ---------------------------------------------------------------------------------------------------------------
  for (final (size, scale, tag) in const [(Size(1500, 800), 1.0, '1500x800'), (Size(1280, 600), 1.0, '1280x600'), (Size(1920, 940), 1.0, '1920x940')]) {
    testWidgets("the response graph tells the call-back story from the server's figures ($tag)", (t) async {
      final errors = await pumpDashboard(t, _page(), api: offApi(), size: size, textScale: scale, body: () async {
        expect(_rich('Customer response time · last 30 days'), findsOneWidget);
        // The headline: the typical wait (the server's median over the 30 days) and the share called back within the hour,
        // where calls nobody returned count against it: 76 of 116 called back + 3 never = 64%.
        expect(_rich('23 min'), findsOneWidget);
        expect(find.text('typical wait'), findsOneWidget);
        expect(_rich('64%'), findsOneWidget);
        expect(find.text('called back within the hour'), findsOneWidget);
        // The callout names the calls nobody returned and the slowest weekday.
        expect(find.text('3 calls not called back · slowest day: Mon Oct 12, 1 h 14 min'), findsOneWidget);
        // No sample: real figures need no Preview.
        expect(find.text('Preview with sample data'), findsNothing);
        await saveDashShot(t, 'office_bella_callbacks_$tag');
      });
      expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
    });
  }

  testWidgets('the response definition says how a wait is counted and who made the call backs', (t) async {
    await pumpDashboard(t, _page(), api: offApi(), size: const Size(1500, 800), body: () async {
      final tip = t.widget<Tooltip>(find.byWidgetPredicate((w) => w is Tooltip && (w.message ?? '').startsWith('How long a customer waits to be called back')));
      expect(tip.message, contains('counted in working hours, Monday to Friday, 8 AM to 5 PM'));
      expect(tip.message, contains('A text back is not a call back'));
      expect(tip.message, contains('108 of the 116 call backs were made by Bella'));
    });
  });

  testWidgets('a month with no missed calls says nobody waited, in words', (t) async {
    await pumpDashboard(
      t,
      _page(),
      api: offApi(mutate: (o) {
        final cb = (o['missedCalls'] as Map)['callbacks'] as Map;
        cb['daily'] = [for (final d in cb['daily'] as List) {...(d as Map), 'missed': 0, 'calledBack': 0, 'within': 0, 'notCalledBack': 0, 'pending': 0, 'gotThrough': 0, 'byMe': 0, 'medianMinutes': null}];
        cb['totals'] = {'missed': 0, 'calledBack': 0, 'within': 0, 'notCalledBack': 0, 'pending': 0, 'gotThrough': 0, 'byMe': 0, 'medianMinutes': null};
      }),
      size: const Size(1500, 800),
      body: () async {
        expect(find.text('No missed calls in the last 30 days, so nobody waited for a call back'), findsOneWidget);
      },
    );
  });

  testWidgets("morale's Preview in the title bar fills in the response graph too", (t) async {
    await pumpDashboard(t, _page(), api: offApi(mutate: _noCallbacks), size: const Size(1500, 800), body: () async {
      await t.tap(moraleBadge());
      await settleDashboard(t, frames: 12);
      expect(_rich('Customer response time · sample'), findsOneWidget);
    });
  });

  testWidgets('reduced motion: final figures at once, nothing left animating', (t) async {
    await pumpDashboard(t, _page(), api: offApi(), size: const Size(1280, 600), reduceMotion: true, body: () async {
      expect(find.text(r'$238,133'), findsOneWidget);
      expect(t.binding.hasScheduledFrame, isFalse, reason: 'the heartbeat, the scorecards and the chart hold still');
    });
  });

  // ---------------------------------------------------------------------------------------------------------------
  // Filters, refresh and drill-downs
  // ---------------------------------------------------------------------------------------------------------------
  testWidgets("the year picker loads 2025 from the server; what is owed and the last 30 days say they are today's", (t) async {
    final api = offApi();
    final errors = await pumpDashboard(t, _page(), api: api, size: const Size(1500, 800), body: () async {
      await t.tap(dashYearArrow('Previous year'));
      await settleDashboard(t);
      expect(api.to('/api/employees/bella/kpis').map((r) => r.url.queryParameters['year']).toList().sublist(1), ['2026', '2025']);
      expect(api.to('/api/dashboards/collections').last.url.queryParameters['year'], '2025');
      // 2025's cash against today's balance would be no rate at all, so an earlier year has none, and says why.
      expect(find.text('92.9%'), findsNothing);
      expect(find.text('Current year only'), findsOneWidget);
      expect(find.textContaining('as of today'), findsWidgets);
      expect(_rich('Unpaid invoices by stage · as of today'), findsOneWidget);
      expect(find.textContaining('· all of 2025'), findsWidgets); // the call answer rate's stretch
      await saveDashShot(t, 'office_bella_2025');
      await t.tap(dashYearArrow('Next year'));
      await settleDashboard(t);
      expect(api.to('/api/employees/bella/kpis').last.url.queryParameters['year'], '2026');
      expect(find.text('91.3%'), findsOneWidget);
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('an earlier year keeps "as of today" on the balances even in the smallest window', (t) async {
    final errors = await pumpDashboard(t, _page(), api: offApi(), size: const Size(1280, 600), body: () async {
      await t.tap(dashYearArrow('Previous year'));
      await settleDashboard(t);
      // Outstanding and Over 90 days, however short their captions get.
      expect(find.textContaining(RegExp('[Aa]s of today')), findsAtLeastNWidgets(2));
      await saveDashShot(t, 'office_bella_2025_1280x600');
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('Refresh asks the server again past its cache and keeps the figures on screen', (t) async {
    final api = offApi();
    await pumpDashboard(t, _page(), api: api, size: const Size(1500, 800), body: () async {
      await t.tap(dashRefreshButton);
      await t.pump(const Duration(milliseconds: 10));
      expect(find.text(r'$238,133'), findsOneWidget, reason: 'figures stay while it refreshes');
      await settleDashboard(t);
      expect(api.to('/api/employees/bella/kpis').last.url.queryParameters['fresh'], '1');
    });
  });

  testWidgets('View list opens the calls behind the graph, and so does the Missed calls scorecard', (t) async {
    final api = offApi();
    await pumpDashboard(t, _page(), api: api, size: const Size(1500, 800), body: () async {
      await t.tap(find.text('View list'));
      await settleDashboard(t, frames: 12);
      expect(find.text('Maxwell Barn Company LLC'), findsOneWidget);
      await saveDashShot(t, 'office_bella_missed_list');
      expect(api.requests.where((r) => r.url.path.endsWith('/missed_calls')), hasLength(1));
      await t.tapAt(const Offset(10, 10)); // outside the dialog
      await settleDashboard(t, frames: 8);
      expect(find.text('Maxwell Barn Company LLC'), findsNothing);
      await t.tap(find.text('Missed calls').first);
      await settleDashboard(t, frames: 12);
      expect(find.text('Maxwell Barn Company LLC'), findsOneWidget);
    });
  });

  testWidgets('the back button returns to the list', (t) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(1500, 800);
    addTearDown(t.view.reset);
    final api = offApi();
    final router = GoRouter(
      initialLocation: '/hr/kpis/bella',
      routes: [
        GoRoute(path: '/hr/kpis', builder: (_, _) => const Text('KPI list'), routes: [
          GoRoute(path: ':id', builder: (_, s) => EmployeeKpiScreen(employeeId: s.pathParameters['id']!)),
        ]),
      ],
    );
    await http.runWithClient(() async {
      await t.pumpWidget(MaterialApp.router(routerConfig: router, theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true)));
      await settleDashboard(t);
      expect(find.text('BELLA HANSBERGER'), findsOneWidget);
      await t.tap(find.byTooltip('All employees'));
      await settleDashboard(t, frames: 5);
      expect(find.text('KPI list'), findsOneWidget);
    }, api.client);
  });

  // ---------------------------------------------------------------------------------------------------------------
  // Loading, failures, an older server, empty states
  // ---------------------------------------------------------------------------------------------------------------
  testWidgets('a skeleton while the figures load, then the page', (t) async {
    final gate = Completer<void>();
    await pumpDashboard(t, _page(), api: offApi(kpisGate: gate), size: const Size(1280, 600), body: () async {
      expect(find.bySemanticsLabel('Loading figures'), findsOneWidget);
      await saveDashShot(t, 'office_bella_loading');
      gate.complete();
      await settleDashboard(t);
      expect(find.bySemanticsLabel('Loading figures'), findsNothing);
      expect(find.text(r'$238,133'), findsOneWidget);
    });
  });

  testWidgets("while the person's details load, the new page's frame shows, never the old page", (t) async {
    final gate = Completer<void>();
    await pumpDashboard(t, _page(), api: offApi(detailsGate: gate), size: const Size(1280, 600), body: () async {
      // The people have loaded (the title bar has the name), the details that decide the page have not.
      expect(find.text('BELLA HANSBERGER'), findsOneWidget);
      expect(find.bySemanticsLabel('Loading figures'), findsOneWidget);
      expect(find.textContaining('Current Morale'), findsNothing);
      expect(find.text('Customer response time'), findsNothing);
      gate.complete();
      await settleDashboard(t);
      expect(find.text('BELLA HANSBERGER'), findsOneWidget);
      expect(find.text(r'$238,133'), findsOneWidget);
    });
  });

  testWidgets('a failed load says so in words, with Try again that works', (t) async {
    var status = 500;
    final api = offApi(kpisStatus: () => status);
    await pumpDashboard(t, _page(), api: api, size: const Size(1280, 600), body: () async {
      expect(find.text("Couldn't load Bella's figures"), findsOneWidget);
      expect(find.textContaining('error 500'), findsOneWidget);
      await saveDashShot(t, 'office_bella_error');
      status = 200;
      await t.tap(find.text('Try again'));
      await settleDashboard(t);
      expect(find.text(r'$238,133'), findsOneWidget);
    });
  });

  testWidgets('a signed-out answer signs out', (t) async {
    await pumpDashboard(t, _page(), api: offApi(kpisStatus: () => 401), size: const Size(1280, 600), body: () async {
      expect(AuthSession.instance.isLoggedIn, isFalse);
      expect(find.text('Your session ended'), findsOneWidget);
    });
  });

  testWidgets('without the Collections dashboard the KPI answer carries the same figures', (t) async {
    await pumpDashboard(t, _page(), api: offApi(collections: false, mutate: (o) => o['outstanding'] = 240000), size: const Size(1500, 800), body: () async {
      expect(find.text(r'$240,000'), findsOneWidget);
      expect(find.text('91.3%'), findsOneWidget);
    });
  });

  testWidgets("with the Collections dashboard its numbers win over the KPI answer's, so the two screens agree", (t) async {
    await pumpDashboard(t, _page(), api: offApi(mutate: (o) => o['outstanding'] = 240000), size: const Size(1500, 800), body: () async {
      expect(find.text(r'$238,133'), findsOneWidget);
      expect(find.text(r'$240,000'), findsNothing);
    });
  });

  testWidgets("a server that stops sending the office figures says so, and doesn't show a page of zeros", (t) async {
    // The details load (which decides the page) gets them, the page's own request does not.
    var calls = 0;
    final api = offApi();
    api.extra.insert(0, (req) async {
      if (RegExp(r'^/api/employees/bella/kpis$').hasMatch(req.url.path) && ++calls > 1) return offJson(offKpisBody(withOffice: false));
      return null;
    });
    final errors = await pumpDashboard(t, _page(), api: api, size: const Size(1280, 600), body: () async {
      expect(find.text("Office figures aren't available yet"), findsOneWidget);
      expect(find.text('Outstanding'), findsNothing);
      await saveDashShot(t, 'office_bella_old_server');
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('no Quo match and nothing owed: dashes and plain empty states, not zeros or made-up percentages', (t) async {
    final errors = await pumpDashboard(
      t,
      _page(),
      api: offApi(
        collections: false,
        mutate: (o) {
          o
            ..remove('missedCalls')
            ..['outstanding'] = 0
            ..['over90'] = 0
            ..['collected'] = 0
            ..['collectionRatePct'] = null
            ..['collectedMonthly'] = <Object>[]
            ..['aging'] = <Object>[]
            ..['reviews'] = <Object>[]
            ..['satisfaction'] = null;
        },
      ),
      size: const Size(1500, 800),
      body: () async {
        expect(find.text('Not tracked yet'), findsOneWidget); // scheduling
        expect(find.text('No call-back times from the server yet'), findsOneWidget); // the response graph says it in its own words
        // No call figures: not matched to a Quo line, or the calls couldn't be read (the page can't tell which, so it says both).
        expect(find.text('No call figures'), findsNWidgets(2)); // call answer rate, missed calls
        expect(find.textContaining('No call figures came back from the server'), findsOneWidget);
        expect(find.text('No payments or balances yet'), findsOneWidget); // collection rate
        expect(find.text('Nothing is waiting to be collected'), findsOneWidget);
        expect(find.text('No Google reviews mention Bella yet.'), findsOneWidget);
        await saveDashShot(t, 'office_bella_empty');
        await t.tap(find.text('Leads'));
        await settleDashboard(t, frames: 25);
        expect(find.textContaining('No leads are recorded yet'), findsOneWidget);
      },
    );
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('a clean month reads green: no missed calls in the last 30 days', (t) async {
    final errors = await pumpDashboard(
      t,
      _page(),
      api: offApi(mutate: (o) {
        final mc = o['missedCalls'] as Map<String, dynamic>;
        mc['daily'] = [for (final d in offRecentDays()) {...d, 'missed': 0}];
      }),
      size: const Size(1500, 800),
      body: () async {
        expect(find.text('No missed calls in the last 30 days'), findsWidgets);
        expect(find.text('of 328 calls · last 30 days'), findsOneWidget);
      },
    );
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  // ---------------------------------------------------------------------------------------------------------------
  // Narrow windows scroll in one column, like the dashboards
  // ---------------------------------------------------------------------------------------------------------------
  for (final size in const [Size(1000, 700), Size(800, 900), Size(480, 900)]) {
    testWidgets('below desktop width: one scrolling column (${size.width.round()}x${size.height.round()})', (t) async {
      final errors = await pumpDashboard(t, _page(), api: offApi(), size: size, body: () async {
        await saveDashShot(t, 'office_bella_${size.width.round()}x${size.height.round()}');
      });
      expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
    });
  }
}
