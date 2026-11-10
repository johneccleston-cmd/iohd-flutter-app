// The sales KPI page (lib/employee_kpi_sales.dart) for Heather Vera (residential) and Zac Clemens (commercial), on the
// figures in test/sales_kpi_fixture.dart: it fits the desktop sizes without scrolling, every metric and animation of the
// page before it is still there, the figures and captions match the answer, the year picker and Refresh ask the server
// again, the lists open, and failures and empty years are handled. Screenshots go to build/dash_shots/.
//   flutter test test/sales_kpi_page_test.dart

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/config/auth_session.dart';
import 'package:iohd_desktop/kpi_dashboard_screen.dart';
import 'package:iohd_desktop/widgets/dashboard_kit.dart' show DashUi;

import 'dashboard_fit.dart';
import 'dashboard_harness.dart';
import 'sales_kpi_fixture.dart';

/// Oct 30, 2026, 9:30 AM.
final _now = DateTime(2026, 10, 30, 9, 30);

/// A fake server for the sales page. [kpisStatus] forces an error on the KPI request; [kpisGate] holds it back;
/// [mutate] changes the sales part before it goes out.
DashFakeApi salesApi({
  int Function()? kpisStatus,
  Completer<void>? kpisGate,
  void Function(Map<String, dynamic> sales)? mutate,
}) {
  final api = DashFakeApi();
  api.extra.add((req) async {
    final path = req.url.path;
    if (path == '/users') return salesJson(salesUsersBody());
    final kpis = RegExp(r'^/api/employees/([^/]+)/kpis$').firstMatch(path);
    if (kpis != null) {
      if (kpisGate != null) await kpisGate.future;
      final status = kpisStatus?.call() ?? 200;
      if (status != 200) return salesJson({'error': 'simulated'}, status);
      final year = int.parse(req.url.queryParameters['year'] ?? '2026');
      final body = salesKpisBody(Uri.decodeComponent(kpis[1]!), year: year);
      if (mutate != null && body['sales'] != null) mutate(body['sales'] as Map<String, dynamic>);
      return salesJson(body);
    }
    final list = RegExp(r'^/api/employees/[^/]+/(stale_estimates|late_estimates)$').firstMatch(path);
    if (list != null) return salesJson(salesListBody(list[1]!));
    if (RegExp(r'^/api/employees/[^/]+/mix_estimates$').hasMatch(path)) return salesJson(salesMixBody());
    return null;
  });
  return api;
}

Widget _heather() => EmployeeKpiScreen(employeeId: heather.username);
Widget _zac() => EmployeeKpiScreen(employeeId: zac.username);

Finder _rich(String text) => find.textContaining(text, findRichText: true);

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
    'sales_heather',
    _heather,
    () => salesApi(),
    mustShow: ['HEATHER VERA', 'Close rate', r'$703,107', 'Sales revenue', 'Gross profit', 'Late to send', 'Turnaround', 'LARGEST DEAL · 2026', 'Open estimates', 'Customer reviews'],
    mayCut: (text) => text.contains('Heather walked us through') || text.contains('Fast quote') || text == 'David and Molli Snell',
  );
  dashFitTests(
    'sales_zac',
    _zac,
    () => salesApi(),
    mustShow: ['ZAC CLEMENS', 'Close rate', 'Sales revenue', 'Gross profit', 'Late to send', 'Turnaround', 'Inventory strikes', 'LARGEST DEAL · 2026', 'Open estimates'],
    // A long customer name is cut short on the deal card (the full name is in its tooltip).
    mayCut: (text) => text == 'Southern Brothers Construction LLC',
  );

  // ---------------------------------------------------------------------------------------------------------------
  // Nothing the page showed before is gone (a rule for every KPI page)
  // ---------------------------------------------------------------------------------------------------------------
  testWidgets("every metric of Zac's previous page is still on it", (t) async {
    final errors = await pumpDashboard(t, _zac(), api: salesApi(), size: const Size(1500, 800), body: () async {
      // Profile: rank, years badge, integrity score; morale in the title bar.
      expect(find.textContaining('Rank #'), findsOneWidget);
      expect(find.text('1 yr'), findsOneWidget);
      expect(find.text('100%'), findsOneWidget);
      expect(find.text('Morale'), findsOneWidget);
      // Only the technician and warehouse pages carry a peer rating.
      expect(find.text('Peer rating'), findsNothing);
      // The old scorecards (margin now rides in the gross-profit caption) and the old left-column cards.
      for (final label in ['Close rate', 'Sales revenue', 'Gross profit', 'Late to send', 'Turnaround', 'Inventory strikes']) {
        expect(find.text(label), findsWidgets, reason: label);
      }
      expect(find.textContaining('37.3% margin'), findsOneWidget);
      // The chart's tabs: hard bids, commercial, close rate, and the estimate mix that had its own card.
      for (final tab in ['Hard bids', 'Commercial', 'Close rate', 'Mix', 'Sold vs final']) {
        expect(find.text(tab), findsWidgets, reason: tab);
      }
      // Pipeline: dollars still moving / gone quiet, the stale tube's on track / aging / stale, the two stages.
      expect(_rich('Open estimates'), findsOneWidget);
      expect(find.textContaining('Still moving'), findsOneWidget);
      expect(find.textContaining('Gone quiet'), findsOneWidget);
      for (final k in ['On track', 'Aging', 'Stale']) {
        expect(find.text(k), findsOneWidget, reason: k);
      }
      expect(find.text('5'), findsOneWidget); // on track: 28 open - 17 stale - 6 aging
      expect(find.text('6'), findsOneWidget);
      expect(find.text('17'), findsOneWidget);
      expect(_rich(r'Gone quiet $351.3k'), findsOneWidget);
      expect(find.text('61%'), findsOneWidget); // the Stale row: 17 of 28
      expect(find.text('28'), findsOneWidget); // the ring's middle: every open estimate
      expect(find.text('Not sent yet'), findsOneWidget);
      expect(find.text('Sent, awaiting a reply'), findsOneWidget);
      // The largest deal and the reviews card.
      expect(find.textContaining('LARGEST DEAL'), findsOneWidget);
      expect(find.text('Southern Brothers Construction LLC'), findsOneWidget);
      expect(find.text('Customer reviews'), findsOneWidget);
      await saveDashShot(t, 'sales_zac_metrics');
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets("every metric of Heather's previous page is still on it", (t) async {
    final errors = await pumpDashboard(t, _heather(), api: salesApi(), size: const Size(1500, 800), body: () async {
      expect(find.textContaining('Rank #'), findsOneWidget);
      expect(find.text('Morale'), findsOneWidget);
      for (final label in ['Close rate', 'Sales revenue', 'Gross profit', 'Late to send', 'Turnaround']) {
        expect(find.text(label), findsWidgets, reason: label);
      }
      // Residential: no inventory strikes, no mix; Sales and Close rate tabs.
      expect(find.text('Inventory strikes'), findsNothing);
      expect(find.text('Mix'), findsNothing);
      for (final tab in ['Sales', 'Close rate', 'Sold vs final']) {
        expect(find.text(tab), findsWidgets, reason: tab);
      }
      expect(_rich('Open estimates'), findsOneWidget);
      expect(find.textContaining('LARGEST DEAL'), findsOneWidget);
      expect(find.text('Customer reviews'), findsOneWidget);
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  // ---------------------------------------------------------------------------------------------------------------
  // The figures, against the answer
  // ---------------------------------------------------------------------------------------------------------------
  testWidgets("Heather's figures and captions match the server's answer", (t) async {
    final api = salesApi();
    final errors = await pumpDashboard(t, _heather(), api: api, size: const Size(1500, 800), body: () async {
      expect(find.text('90.3%'), findsOneWidget);
      expect(find.textContaining('177 of 196 estimates won'), findsOneWidget);
      expect(find.text(r'$703,107'), findsWidgets);
      expect(find.text(r'$300,930'), findsWidgets);
      expect(find.text('42.8%'), findsOneWidget); // the chart's margin, as on the scorecard
      // The largest deal is the far right card of the top row, level with the scorecards and right of the last one.
      final deal = t.getRect(find.textContaining('LARGEST DEAL'));
      expect(deal.top, lessThan(t.getRect(_rich('Sales revenue · by job start date')).top));
      expect(deal.left, greaterThan(t.getRect(find.text('Turnaround')).right));
      expect(find.textContaining('42.8% margin'), findsOneWidget);
      expect(find.text('Stale estimates'), findsNothing); // the stale counts live in the Open estimates panel
      expect(find.text('232'), findsOneWidget); // the Stale row of the ring
      expect(find.text('93%'), findsOneWidget); // said once: the Stale row
      expect(find.text('12'), findsWidgets);
      expect(find.text('1.9 days'), findsOneWidget);
      // The chart's first story: the year's sales, the profit, the margin and the best month.
      expect(_rich('Sales revenue · by job start date'), findsOneWidget);
      expect(find.text('Best month: Sep, \$137,118'), findsOneWidget);
      // Pipeline headline and finding.
      expect(find.text(r'$1,521,836'), findsOneWidget);
      expect(find.text('249'), findsOneWidget); // the ring's middle
      expect(find.textContaining('has gone quiet'), findsNothing); // the bar under the headline says it, once
      expect(_rich(r'Gone quiet $1.4M'), findsOneWidget);
      // One request, for this year, by username.
      expect(api.to('/api/employees/hvera/kpis').last.url.queryParameters['year'], '2026');
      expect(find.text('HEATHER VERA'), findsOneWidget);
      expect(find.text('Sales Account Manager · 4 yrs at IOHD'), findsOneWidget);
      expect(find.text('Updated just now'), findsOneWidget);
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  // ---------------------------------------------------------------------------------------------------------------
  // Animations
  // ---------------------------------------------------------------------------------------------------------------
  testWidgets("Zac's chart steps through its four stories every 8 seconds, and holds while the pointer is on it", (t) async {
    final errors = await pumpDashboard(t, _zac(), api: salesApi(), size: const Size(1500, 800), body: () async {
      expect(_rich('Hard bids won · by job start date'), findsOneWidget);
      expect(find.text(r'Best month: Jul, $24,000 · 69% of all sales revenue'), findsOneWidget);
      await t.pump(const Duration(seconds: 8));
      await settleDashboard(t, frames: 12);
      expect(_rich('Other commercial won · by job start date'), findsOneWidget);
      await t.pump(const Duration(seconds: 8));
      await settleDashboard(t, frames: 12);
      expect(_rich('Close rate · by estimate date'), findsOneWidget);
      expect(find.text('No whole month has 3 or more estimates decided yet'), findsOneWidget); // Jul 2, Sep 1; Oct is in progress
      await saveDashShot(t, 'sales_zac_close_view');
      // Pointer on the chart: it stays put.
      final title = _rich('Close rate · by estimate date');
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: t.getCenter(title));
      await mouse.moveTo(t.getCenter(title) + const Offset(0, 120));
      await t.pump(const Duration(seconds: 9));
      expect(_rich('Close rate · by estimate date'), findsOneWidget);
      await mouse.removePointer();
      // The next tick (within 8 seconds) moves on to the mix.
      for (var i = 0; i < 9 && _rich('Close rate · by estimate date').evaluate().isNotEmpty; i++) {
        await t.pump(const Duration(seconds: 1));
      }
      await settleDashboard(t, frames: 12);
      expect(_rich('Estimate mix'), findsOneWidget);
      // 14 of 28 is half, not most; the hard bids' $30,100 of $43,371 is more than half.
      expect(find.text(r'Half are commercial estimates: 14 of 28 · most sales from commercial hard bids: $30,100'), findsOneWidget);
      await saveDashShot(t, 'sales_zac_mix_view');
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  for (final who in const ['hvera', 'zclemens']) {
    for (final scale in const [1.0, 1.3]) {
      testWidgets('every chart view fits the smallest window ($who, 1280x600, text ${(scale * 100).round()}%)', (t) async {
        final errors = await pumpDashboard(t, EmployeeKpiScreen(employeeId: who), api: salesApi(), size: const Size(1280, 600), textScale: scale, body: () async {
          final tabs = who == 'hvera' ? ['Close rate', 'Sold vs final'] : ['Commercial', 'Close rate', 'Mix', 'Sold vs final'];
          for (final tab in tabs) {
            await t.tap(find.text(tab).last);
            await settleDashboard(t, frames: 25);
            await saveDashShot(t, 'sales_${who}_1280x600_${tab.replaceAll(' ', '_').toLowerCase()}_${(scale * 100).round()}');
          }
        });
        expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
      });
    }
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Won estimates vs the final job
  // ---------------------------------------------------------------------------------------------------------------
  testWidgets("Sold vs final: what was sold against what the closed jobs came to, month by month, and the list", (t) async {
    final errors = await pumpDashboard(t, _heather(), api: salesApi(), size: const Size(1500, 800), body: () async {
      await t.tap(find.text('Sold vs final').last);
      await settleDashboard(t, frames: 30);
      expect(_rich('Won estimates vs final job · by estimate date'), findsOneWidget);
      // 11 closed jobs: $95,650 sold, $113,485 final, +$17,834 (+19%).
      expect(find.text(r'$95,650'), findsOneWidget);
      expect(find.text(r'$113,485'), findsOneWidget);
      expect(find.text(r'+$17,834'), findsOneWidget);
      expect(find.text('(+19%)'), findsOneWidget);
      expect(
        find.text(r'5 finished higher, 3 lower, 3 at the estimate · biggest move: HTP Contractors +$28,477'),
        findsOneWidget,
      );
      expect(find.text('Not charted: 18 still open, 20 with no job found, 3 cancelled'), findsOneWidget);
      // April: HTP up $28,477 and Arden down $19,339 = +$9.1k over the pair.
      expect(find.text(r'+$9.1k'), findsOneWidget);
      expect(find.text(r'−$240'), findsOneWidget); // March: Tom Reyes
      await saveDashShot(t, 'sales_heather_sold_vs_final');
      // Hovering April's pair gives its figures.
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: t.getCenter(find.text('Apr').last));
      await mouse.moveTo(t.getCenter(find.text('Apr').last) - const Offset(0, 30));
      await settleDashboard(t, frames: 6);
      expect(find.textContaining('2 jobs: 1 higher, 1 lower, 0 the same'), findsOneWidget);
      await saveDashShot(t, 'sales_heather_sold_vs_final_hover');
      await mouse.removePointer();
      // The list: every pair, biggest change first.
      await t.tap(find.text('List jobs'));
      await settleDashboard(t, frames: 12);
      expect(find.text('Heather Vera · Won estimates vs final job'), findsOneWidget);
      expect(find.text('11 closed jobs from estimates won in 2026, biggest change first'), findsOneWidget);
      final htp = t.getTopLeft(find.text('HTP Contractors').last).dy;
      final arden = t.getTopLeft(find.text('Arden Brazzeal').last).dy;
      expect(htp, lessThan(arden));
      expect(find.text(r'+$28,477 (+411%)'), findsOneWidget);
      expect(find.text(r'−$19,339 (−67%)'), findsOneWidget);
      await saveDashShot(t, 'sales_heather_sold_vs_final_list');
      // The list scrolls to the last row; jobs that closed at the estimate read $0.
      await t.scrollUntilVisible(find.text('Ortiz Family'), 200, scrollable: find.descendant(of: find.byType(Dialog), matching: find.byType(Scrollable)));
      await settleDashboard(t, frames: 6);
      expect(find.descendant(of: find.byType(Dialog), matching: find.text(r'$0')), findsWidgets);
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('an older server without estimateVsJob: no Sold vs final tab', (t) async {
    final errors = await pumpDashboard(t, _zac(), api: salesApi(mutate: (s) => s.remove('estimateVsJob')), size: const Size(1500, 800), body: () async {
      expect(find.text('Mix'), findsWidgets);
      expect(find.text('Sold vs final'), findsNothing);
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('no won estimate with a closed job yet: said in words, no list button', (t) async {
    final errors = await pumpDashboard(
      t,
      _zac(),
      api: salesApi(mutate: (s) => s['estimateVsJob'] = {'rows': <Object>[], 'openJobs': 3, 'unmatched': 1, 'cancelled': 0}),
      size: const Size(1500, 800),
      body: () async {
        await t.tap(find.text('Sold vs final').last);
        await settleDashboard(t, frames: 20);
        expect(find.text('No estimate won in 2026 has a closed job yet · 3 still open, 1 with no job found'), findsWidgets);
        expect(find.text('List jobs'), findsNothing);
      },
    );
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('hovering a scorecard brings its definition in as an animated card, inside the window', (t) async {
    final errors = await pumpDashboard(t, _zac(), api: salesApi(), size: const Size(1500, 800), body: () async {
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(1, 400));
      await mouse.moveTo(t.getCenter(find.text('Turnaround')));
      await t.pump(const Duration(milliseconds: 400));
      await settleDashboard(t, frames: 5);
      // Each kind against its own target: the others' average comes out of the whole (2.4 x 9) and the bids' (4 x 3).
      expect(
        find.textContaining('green when the estimates other than hard bids average 3 days or less (1.6 days over 6) and hard bids 14 or less '
            '(4 days on average over 3)'),
        findsOneWidget,
      );
      await saveDashShot(t, 'sales_zac_hover_card');
      await mouse.moveTo(t.getCenter(find.text('Close rate').first));
      await settleDashboard(t, frames: 8);
      expect(find.textContaining('(the Sales dashboard calls this the win rate)'), findsOneWidget);
      expect(find.textContaining('Hard bids 100% (2 of 2) on their own'), findsOneWidget);
      await mouse.moveTo(t.getCenter(find.text('Sales revenue').first));
      await settleDashboard(t, frames: 8);
      expect(find.textContaining("The chart's Hard bids and Commercial views split it by the kind of estimate each job came from; the Mix view is about estimates."), findsOneWidget);
      await mouse.moveTo(t.getCenter(find.text('Inventory strikes')));
      await settleDashboard(t, frames: 8);
      final last = find.textContaining('found by the stock audit');
      expect(last, findsOneWidget);
      expect(t.getRect(last).right, lessThanOrEqualTo(1500));
      await mouse.removePointer();
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  Finder moraleBadge() => find.byWidgetPredicate((w) => w is Tooltip && (w.message ?? '').startsWith('Morale'));

  testWidgets('morale Preview shows sample scores and, with no reviews, sample reviews; then hides', (t) async {
    final errors = await pumpDashboard(t, _zac(), api: salesApi(), size: const Size(1500, 800), body: () async {
      expect(find.textContaining('Quick quote, clear pricing'), findsNothing);
      await t.tap(moraleBadge());
      await settleDashboard(t, frames: 12);
      expect(find.text('Morale · sample'), findsOneWidget);
      expect(find.textContaining('Quick quote, clear pricing'), findsOneWidget);
      await saveDashShot(t, 'sales_zac_preview');
      for (var i = 0; i < 4; i++) {
        await t.tap(moraleBadge());
        await settleDashboard(t, frames: 4);
      }
      expect(find.text('Morale · sample'), findsNothing);
      expect(find.textContaining('Quick quote, clear pricing'), findsNothing);
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('reduced motion: final figures at once, nothing left animating', (t) async {
    await pumpDashboard(t, _heather(), api: salesApi(), size: const Size(1280, 600), reduceMotion: true, body: () async {
      expect(find.text(r'$703,107'), findsWidgets);
      expect(t.binding.hasScheduledFrame, isFalse, reason: 'the confetti, the clock, the scorecards and the chart hold still');
    });
  });

  // ---------------------------------------------------------------------------------------------------------------
  // Filters, refresh and drill-downs
  // ---------------------------------------------------------------------------------------------------------------
  testWidgets('the year picker loads 2025 from the server; the open estimates are every open one today; 2025 was not tracked', (t) async {
    final api = salesApi();
    final errors = await pumpDashboard(t, _heather(), api: api, size: const Size(1500, 800), body: () async {
      expect(_rich('Open estimates · all open · today'), findsOneWidget);
      await t.tap(dashYearArrow('Previous year'));
      await settleDashboard(t);
      expect(api.to('/api/employees/hvera/kpis').map((r) => r.url.queryParameters['year']).toList(), ['2026', '2025']);
      expect(find.text('83.9%'), findsOneWidget);
      // The same open estimates whatever the year.
      expect(_rich('Open estimates · all open · today'), findsOneWidget);
      expect(find.text(r'$1,521,836'), findsOneWidget);
      // Turnaround and late to send didn't exist before Sep 10, 2026: no figure, not a 0.
      expect(find.textContaining('Not tracked'), findsNWidgets(2));
      expect(find.textContaining('since Sep 10'), findsNothing);
      await saveDashShot(t, 'sales_heather_2025');
      // The lists follow the year.
      await t.tap(find.text('Stale list'));
      await settleDashboard(t, frames: 12);
      expect(api.requests.where((r) => r.url.path.endsWith('/stale_estimates')).last.url.queryParameters['year'], '2025');
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('a year with no estimates says so in words', (t) async {
    final errors = await pumpDashboard(t, _zac(), api: salesApi(), size: const Size(1500, 800), body: () async {
      await t.tap(dashYearArrow('Previous year'));
      await settleDashboard(t);
      expect(find.text('No estimates in 2025'), findsOneWidget);
      expect(find.text('Close rate'), findsNothing);
      // A finished year won't fill in: no Try again (nothing failed) and no Refresh.
      expect(find.text('Try again'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Refresh'), findsNothing);
      await saveDashShot(t, 'sales_zac_2025_empty');
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('Refresh asks the server again past its cache and keeps the figures on screen', (t) async {
    final api = salesApi();
    await pumpDashboard(t, _heather(), api: api, size: const Size(1500, 800), body: () async {
      await t.tap(dashRefreshButton);
      await t.pump(const Duration(milliseconds: 10));
      expect(find.text(r'$703,107'), findsWidgets, reason: 'figures stay while it refreshes');
      await settleDashboard(t);
      expect(api.to('/api/employees/hvera/kpis').last.url.queryParameters['fresh'], '1');
    });
  });

  testWidgets('the late scorecard, the Stale list link and a mix slice open their lists', (t) async {
    final api = salesApi();
    await pumpDashboard(t, _zac(), api: api, size: const Size(1500, 800), body: () async {
      Future<void> close() async {
        await t.tapAt(const Offset(10, 10));
        await settleDashboard(t, frames: 8);
      }

      await t.tap(find.text('Late to send'));
      await settleDashboard(t, frames: 12);
      expect(find.text('Southern Brothers Construction LLC'), findsWidgets);
      expect(find.textContaining('with nothing done on it while it waited (a status change, a note or an edit in Service Fusion)'), findsOneWidget);
      await close();
      await t.tap(find.text('Stale list'));
      await settleDashboard(t, frames: 12);
      expect(find.text('DC Sparks Construction'), findsOneWidget);
      await saveDashShot(t, 'sales_zac_stale_list');
      await close();
      await t.tap(find.text('Mix'));
      await settleDashboard(t, frames: 25);
      await t.tap(find.text('Commercial hard bids'));
      await settleDashboard(t, frames: 12);
      expect(api.requests.where((r) => r.url.path.endsWith('/mix_estimates')), isNotEmpty);
      expect(api.requests.where((r) => r.url.path.endsWith('/stale_estimates')), hasLength(1));
      expect(api.requests.where((r) => r.url.path.endsWith('/late_estimates')), hasLength(1));
    });
  });

  // ---------------------------------------------------------------------------------------------------------------
  // Definitions: tracking period, margins, targets, best months, shares
  // ---------------------------------------------------------------------------------------------------------------
  testWidgets('an older server that sent 0 late for an untracked year still reads "not tracked", not 0', (t) async {
    final api = salesApi(mutate: (s) {
      (s['strikes'] as Map)['slowEstimates'] = 0;
      s['turnaround'] = {'count': 1, 'avgDays': 300, 'medianDays': 300};
    });
    final errors = await pumpDashboard(t, _heather(), api: api, size: const Size(1500, 800), body: () async {
      await t.tap(dashYearArrow('Previous year'));
      await settleDashboard(t);
      expect(find.textContaining('Not tracked'), findsNWidgets(2));
      expect(find.text('300 days'), findsNothing);
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('from 2027 the late and turnaround cards cover the whole year, not "since Sep 10"', (t) async {
    pinDashClock(DateTime(2027, 3, 15, 9, 30));
    final errors = await pumpDashboard(t, _heather(), api: salesApi(), size: const Size(1920, 940), body: () async {
      expect(find.textContaining('since Sep 10'), findsNothing);
      expect(find.textContaining('Not tracked'), findsNothing);
      expect(find.textContaining('80 estimates so far'), findsOneWidget);
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets("Zac's turnaround: the overall median beside the hard bids' average, green when each kind meets its own target", (t) async {
    // 4 days on average over 4: hard bids 6 days over 2 (allowed 14), the rest 2 days over 2 (allowed 3).
    final api = salesApi(mutate: (s) {
      s['turnaround'] = {'count': 4, 'avgDays': 4.0, 'medianDays': 3};
      s['bidTurnaround'] = {'count': 2, 'avgDays': 6.0, 'medianDays': 6};
    });
    final errors = await pumpDashboard(t, _zac(), api: api, size: const Size(1920, 940), body: () async {
      await saveDashShot(t, 'sales_zac_turnaround_targets');
      // The fullest wording that fits the card: the overall median beside the hard bids' average, or the latter alone.
      expect(find.textContaining(RegExp(r'^(Half in 3 days · hard bids average 6 days|Hard bids average 6 days|Hard bids avg 6 days)$')), findsOneWidget);
      expect(find.textContaining(RegExp(r'^4 of 5 won · [Hh]ard bids ')), findsOneWidget);
      final value = t.widget<Text>(find.text('4 days'));
      expect(value.style?.color, DashUi.emeraldDeep, reason: 'a 4-day average is over 3, but only because of the hard bids');
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('the gross profit caption keeps its coverage when some won estimates have no profit figure', (t) async {
    // $12,000 of September's won value sits on the 9 estimates without a profit figure.
    final api = salesApi(mutate: (s) => (((s['monthlyByType'] as Map)['other'] as List)[8] as Map)['revenueWithProfit'] = 125118);
    final errors = await pumpDashboard(t, _heather(), api: api, size: const Size(1280, 600), body: () async {
      expect(find.textContaining(RegExp(r'^42\.8%( margin)? · 9 (won )?left out')), findsOneWidget);
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('won estimates worth \$0 without a profit figure change nothing, so the caption does not call them left out', (t) async {
    // The fixture's 9 unpriced won estimates are $0 (as in production): the priced revenue is all $703,107 won.
    final errors = await pumpDashboard(t, _heather(), api: salesApi(), size: const Size(1280, 600), body: () async {
      expect(find.textContaining(RegExp(r'^42\.8%')), findsWidgets);
      expect(find.textContaining('left out'), findsNothing);
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('Sales revenue and Gross profit count the jobs the person is an agent on, not the won estimates', (t) async {
    // 177 estimates were won, but the figures behind the two cards come from 200 jobs (jobCount), 190 of them with a profit figure.
    final api = salesApi(mutate: (s) {
      s['jobCount'] = 200;
      s['profitCoverage'] = {'withProfit': 190, 'won': 200};
      (((s['monthlyByType'] as Map)['other'] as List)[8] as Map)['revenueWithProfit'] = 125118;
    });
    final errors = await pumpDashboard(t, _heather(), api: api, size: const Size(1280, 600), body: () async {
      expect(find.textContaining(RegExp(r'^200 jobs( as agent)?( · |$)')), findsOneWidget, reason: 'the Sales revenue caption counts jobs');
      expect(find.textContaining(RegExp(r'^42\.8%( margin)? · 10 (jobs )?left out')), findsOneWidget, reason: 'the profit caption counts jobs without a profit figure');
      expect(find.textContaining('177 estimate'), findsNothing);
      expect(find.textContaining('177 of 196 estimates won'), findsOneWidget, reason: 'the close rate still counts estimates');
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('a chart margin divides the profit by the won revenue that carries a profit figure', (t) async {
    // July's $24,000 hard bid: $20,000 of it is on estimates with a profit figure. 11,800 / (20,000 + 6,100) = 45.2%.
    final api = salesApi(mutate: (s) => (((s['monthlyByType'] as Map)['hardBid'] as List)[6] as Map)['revenueWithProfit'] = 20000);
    final errors = await pumpDashboard(t, _zac(), api: api, size: const Size(1500, 800), body: () async {
      expect(_rich('Hard bids won · by job start date'), findsOneWidget);
      expect(find.text('45.2%'), findsOneWidget);
      expect(find.text('Revenue'), findsOneWidget);
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('an older server without revenueWithProfit: the chart margin falls back to all won revenue', (t) async {
    final api = salesApi(mutate: (s) {
      for (final cells in (s['monthlyByType'] as Map).values) {
        for (final c in cells as List) {
          (c as Map).remove('revenueWithProfit');
        }
      }
    });
    final errors = await pumpDashboard(t, _zac(), api: api, size: const Size(1500, 800), body: () async {
      expect(find.text('39.2%'), findsOneWidget); // 11,800 / 30,100
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  // "Most" only for more than half (14 of 28 reads "Half are", above), and a tie for the top names both.
  for (final (counts, callout) in const [
    ([20, 5, 3], 'Most are commercial hard bids: 20 of 28'),
    ([12, 9, 7], 'Largest group: commercial hard bids, 12 of 28'),
    ([10, 10, 8], 'Largest group: commercial hard bids and commercial estimates, 10 of 28 each'),
  ]) {
    testWidgets('the mix callout: $callout', (t) async {
      final api = salesApi(mutate: (s) => s['byType'] = [
            {'type': 'Commercial Hard Bid', 'estimates': counts[0], 'wonCount': 0, 'wonValue': 0, 'grossProfit': 0},
            {'type': 'Commercial Service', 'estimates': counts[1], 'wonCount': 0, 'wonValue': 0, 'grossProfit': 0},
            {'type': 'Uncategorized', 'estimates': counts[2], 'wonCount': 0, 'wonValue': 0, 'grossProfit': 0},
          ]);
      await pumpDashboard(t, _zac(), api: api, size: const Size(1500, 800), body: () async {
        await t.tap(find.text('Mix'));
        await settleDashboard(t, frames: 25);
        expect(find.text(callout), findsOneWidget);
      });
    });
  }

  testWidgets('on a narrow bar with large text the open dollars keep their figures and the words shorten', (t) async {
    final errors = await pumpDashboard(t, _zac(), api: salesApi(), size: const Size(1280, 600), textScale: 1.3, body: () async {
      expect(_rich(r'Quiet $351.3k'), findsOneWidget);
      expect(_rich(r'Moving $882k'), findsOneWidget);
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets("hovering a slice of the ring shows its share in the middle, the ring's count otherwise", (t) async {
    final errors = await pumpDashboard(t, _zac(), api: salesApi(), size: const Size(1500, 800), body: () async {
      expect(find.text('61%'), findsOneWidget);
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(1, 400));
      await mouse.moveTo(t.getCenter(find.text('Stale').first));
      await settleDashboard(t, frames: 8);
      expect(find.text('61%'), findsNWidgets(2)); // the row and, while it is lit, the ring
      expect(find.text('stale'), findsOneWidget);
      await mouse.removePointer();
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets("the close rate's best and lowest months are whole months with 3 or more decided", (t) async {
    final errors = await pumpDashboard(t, _heather(), api: salesApi(), size: const Size(1500, 800), body: () async {
      await t.tap(find.text('Close rate').last);
      await settleDashboard(t, frames: 25);
      // Apr, May and Jul were all won; May had the most decided. October (12 of 12) is still in progress.
      expect(find.text('Best month: May, 100% (21 of 21) · lowest: Jan, 73.3% (11 of 15)'), findsOneWidget);
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('shares add up to 100%, and a sliver reads "<1%" rather than 0%', (t) async {
    final api = salesApi(mutate: (s) => s['byType'] = [
          {'type': 'Commercial Hard Bid', 'estimates': 200, 'wonCount': 2, 'wonValue': 30100, 'grossProfit': 11800},
          {'type': 'Commercial Service', 'estimates': 1, 'wonCount': 0, 'wonValue': 0, 'grossProfit': 0},
          {'type': 'Residential Service', 'estimates': 1, 'wonCount': 0, 'wonValue': 0, 'grossProfit': 0},
        ]);
    final errors = await pumpDashboard(t, _zac(), api: api, size: const Size(1500, 800), body: () async {
      await t.tap(find.text('Mix'));
      await settleDashboard(t, frames: 25);
      // 200, 1 and 1 of 202 are 99.0%, 0.5% and 0.5%: rounded alone they read 99 + 0 + 0 (or 99 + 1 + 1).
      expect(find.text('99%'), findsWidgets);
      expect(find.text('1%'), findsOneWidget);
      expect(find.text('<1%'), findsOneWidget);
      // The open estimates' rows and the ring agree: 5, 6 and 17 of 28 are 18%, 21% and 61%.
      expect(find.text('18%'), findsOneWidget);
      expect(find.text('21%'), findsOneWidget);
      expect(find.text('61%'), findsOneWidget);
      expect(find.byTooltip('28 open estimates: 5 on track, 6 aging, 17 stale'), findsOneWidget);
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  // ---------------------------------------------------------------------------------------------------------------
  // Loading, failures
  // ---------------------------------------------------------------------------------------------------------------
  testWidgets('a skeleton while the figures load, then the page (never the old page first)', (t) async {
    final gate = Completer<void>();
    await pumpDashboard(t, _heather(), api: salesApi(kpisGate: gate), size: const Size(1280, 600), body: () async {
      expect(find.text('HEATHER VERA'), findsOneWidget);
      expect(find.bySemanticsLabel('Loading figures'), findsOneWidget);
      expect(find.textContaining('Current Morale'), findsNothing);
      await saveDashShot(t, 'sales_heather_loading');
      gate.complete();
      await settleDashboard(t);
      expect(find.bySemanticsLabel('Loading figures'), findsNothing);
      expect(find.text(r'$703,107'), findsWidgets);
    });
  });

  testWidgets('a failed load says so in words, with Try again that works', (t) async {
    var status = 500;
    await pumpDashboard(t, _zac(), api: salesApi(kpisStatus: () => status), size: const Size(1280, 600), body: () async {
      expect(find.text("Couldn't load Zac's figures"), findsOneWidget);
      await saveDashShot(t, 'sales_zac_error');
      status = 200;
      await t.tap(find.text('Try again'));
      await settleDashboard(t);
      expect(find.text(r'$43,371'), findsWidgets);
    });
  });

  testWidgets('a signed-out answer signs out', (t) async {
    await pumpDashboard(t, _zac(), api: salesApi(kpisStatus: () => 401), size: const Size(1280, 600), body: () async {
      expect(AuthSession.instance.isLoggedIn, isFalse);
    });
  });

  testWidgets('nothing open, nothing late, no deal: plain words, not zeros', (t) async {
    final errors = await pumpDashboard(
      t,
      _heather(),
      api: salesApi(mutate: (s) {
        s
          ..['pipeline'] = {'requested': {'count': 0, 'value': 0}, 'provided': {'count': 0, 'value': 0}, 'staleValue': 0}
          ..['strikes'] = {'staleEstimates': 0, 'agingEstimates': 0, 'openEstimates': 0, 'slowEstimates': 0}
          ..['largestDeal'] = null
          ..['reviews'] = <Object>[]
          ..['satisfaction'] = null;
      }),
      size: const Size(1500, 800),
      body: () async {
        expect(find.text('No open estimates today'), findsOneWidget);
        expect(find.textContaining('LARGEST DEAL'), findsNothing);
        await saveDashShot(t, 'sales_heather_empty');
      },
    );
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  // ---------------------------------------------------------------------------------------------------------------
  // Narrow windows scroll in one column, like the dashboards
  // ---------------------------------------------------------------------------------------------------------------
  for (final size in const [Size(1000, 700), Size(800, 900), Size(480, 900)]) {
    testWidgets('below desktop width: one scrolling column (${size.width.round()}x${size.height.round()})', (t) async {
      final errors = await pumpDashboard(t, _zac(), api: salesApi(), size: size, body: () async {
        await saveDashShot(t, 'sales_zac_${size.width.round()}x${size.height.round()}');
      });
      expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
    });
  }
}
