// The warehouse KPI page (lib/employee_kpi_warehouse.dart) for Dennis Gray, on production's headline figures
// (test/warehouse_kpi_fixture.dart): it fits the desktop sizes without scrolling, every metric and animation of the page
// before it is still there (plus the warehouse strikes it never showed), the figures and captions match the records,
// the year picker and Refresh ask the server again, and failures and an older server are handled. Screenshots go to
// build/dash_shots/.
//   flutter test test/warehouse_kpi_page_test.dart

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
import 'warehouse_kpi_fixture.dart';

/// Oct 30, 2026, 9:30 AM.
final _now = DateTime(2026, 10, 30, 9, 30);

/// A fake server for the warehouse page. [kpisStatus] forces an error; [kpisGate] holds the answer back; [mutate] changes
/// the KPI answer before it goes out.
DashFakeApi whApi({
  bool withWarehouse = true,
  int Function()? kpisStatus,
  Completer<void>? kpisGate,
  List<Map<String, dynamic>>? users,
  void Function(Map<String, dynamic> warehouse)? mutate,
  int callbacks = 1,
}) {
  final api = DashFakeApi();
  api.extra.add((req) async {
    final path = req.url.path;
    if (path == '/users') return whJson(users ?? whUsersBody());
    final kpis = RegExp(r'^/api/employees/([^/]+)/kpis$').firstMatch(path);
    if (kpis != null) {
      if (kpisGate != null) await kpisGate.future;
      final status = kpisStatus?.call() ?? 200;
      if (status != 200) return whJson({'error': 'simulated'}, status);
      if (Uri.decodeComponent(kpis[1]!) != dennis.username) return whJson({'success': false, 'error': 'Employee not found.'}, 404);
      final year = int.parse(req.url.queryParameters['year'] ?? '2026');
      final body = whKpisBody(year: year, withWarehouse: withWarehouse);
      if (withWarehouse && mutate != null) mutate(body['warehouse'] as Map<String, dynamic>);
      return whJson(body);
    }
    if (RegExp(r'^/api/employees/[^/]+/callbacks$').hasMatch(path)) return whJson(whCallbacksBody(callbacks));
    return null;
  });
  return api;
}

Widget _page() => EmployeeKpiScreen(employeeId: dennis.username);

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
    'warehouse_dennis',
    _page,
    () => whApi(),
    mustShow: [
      'DENNIS GRAY',
      'Inventory accuracy',
      '94.4%',
      'Cycle counts done',
      'Needs reorder',
      'Open POs',
      'Jobs completed',
      'Cycle count zones',
      'Zone 4',
      'Callback strikes',
      'Team inv. strikes',
    ],
  );

  // ---------------------------------------------------------------------------------------------------------------
  // Nothing the page showed before is gone (a rule for every KPI page)
  // ---------------------------------------------------------------------------------------------------------------
  testWidgets('every metric of the previous page is still on it', (t) async {
    await pumpDashboard(t, _page(), api: whApi(), size: const Size(1500, 800), body: () async {
      // Profile: rank, years badge, integrity score.
      expect(find.textContaining('Rank #'), findsOneWidget);
      expect(find.text('2 yrs'), findsOneWidget);
      expect(find.text('90%'), findsOneWidget);
      // Peer rating and morale sit in the title bar, empty because nothing records them yet.
      expect(find.text('Peer rating'), findsOneWidget);
      expect(find.text('Morale'), findsOneWidget);
      // The scorecards of the old page, the accuracy card and Open POs. Dennis's own inventory strikes are counted
      // into the team card (its caption names them).
      for (final label in ['Jobs completed', 'Team inv. strikes', 'Needs reorder', 'Cycle counts done', 'Callback strikes', 'Inventory accuracy', 'Open POs']) {
        expect(find.text(label), findsWidgets, reason: label);
      }
      // The chart's views, and the zones.
      for (final tab in ['Accuracy', 'Stock gaps', 'Stock levels', 'Cycles']) {
        expect(find.text(tab), findsOneWidget, reason: tab);
      }
      expect(find.text('Cycle count zones'), findsOneWidget);
      for (final z in ['Zone 1', 'Zone 2', 'Zone 3', 'Zone 4']) {
        expect(find.text(z), findsOneWidget, reason: z);
      }
      expect(find.text('Dennis 15 + techs 5, all time'), findsOneWidget);
      // Removed at the user's request (2026-10-30): his own strikes card and the warehouse strikes card.
      expect(find.text('Inv. strikes'), findsNothing);
      expect(find.text('Warehouse strikes'), findsNothing);
    });
  });

  // ---------------------------------------------------------------------------------------------------------------
  // The figures, against the records
  // ---------------------------------------------------------------------------------------------------------------
  testWidgets("every figure and caption matches the server's answer", (t) async {
    final api = whApi();
    final errors = await pumpDashboard(t, _page(), api: api, size: const Size(1500, 800), body: () async {
      expect(find.text('94.4%'), findsNWidgets(2)); // the scorecard and the chart's headline
      // "Item counts", not items: an item counted in two weeks counts twice, and zones in progress are in.
      expect(find.text('of 160 item counts matched the system · target 95%'), findsOneWidget);
      expect(find.text('On target in 2 of 7 weeks · latest week 0.9 points under target'), findsOneWidget);
      // The card says how the year compares in words, not only by its amber.
      expect(find.text('Under the 95% target'), findsOneWidget);
      expect(find.text('41'), findsOneWidget); // jobs completed
      expect(find.text('132'), findsOneWidget); // low stock
      expect(find.text('7'), findsOneWidget); // open POs
      expect(find.textContaining('159 item counts'), findsOneWidget); // in the finished zones
      // Low stock says how many are empty outright (the stock value too when the card is wide enough).
      expect(find.textContaining('86 empty'), findsOneWidget);
      // How much of the warehouse this year's counts reached, over the zones.
      expect(_rich('215 of 443 items on a count in 2026'), findsOneWidget);
      expect(find.text("They hold 99.8% of the stock's value"), findsOneWidget);
      // What makes the figure red comes first.
      expect(find.text(r'2 past due · $18,421 open'), findsOneWidget);
      expect(find.text('Jan 1 – today'), findsOneWidget);
      // Strikes: the team's 20 (his own 15 and the techs' 5), no callbacks.
      expect(find.text('20'), findsOneWidget);
      expect(find.text('Dennis 15 + techs 5, all time'), findsOneWidget);
      expect(find.text('0'), findsOneWidget);
      // Zones.
      expect(find.text('Overdue'), findsNWidgets(2));
      expect(find.text('Complete'), findsOneWidget);
      expect(find.text('Oct 16 · 82 items'), findsOneWidget);
      expect(find.text('31 items so far'), findsOneWidget);
      expect(find.text('Week of Oct 7'), findsOneWidget);
      // One request, for this year, by username.
      expect(api.to('/api/employees/dgray/kpis').single.url.queryParameters['year'], '2026');
      // The header: name, title, time with the company, and how old the figures are.
      expect(find.text('DENNIS GRAY'), findsOneWidget);
      expect(find.text('Warehouse Technician · 2 yrs at IOHD'), findsOneWidget);
      expect(find.text('Updated just now'), findsOneWidget);
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  // ---------------------------------------------------------------------------------------------------------------
  // Animations
  // ---------------------------------------------------------------------------------------------------------------
  testWidgets('the chart steps through its four views every 8 seconds, and holds while the pointer is on it', (t) async {
    await pumpDashboard(t, _page(), api: whApi(), size: const Size(1500, 800), body: () async {
      expect(_rich('Inventory accuracy · last 12 weeks'), findsOneWidget);
      await _seconds(t, 8);
      await settleDashboard(t, frames: 12);
      // Stock gaps, on production's Oct 23 count: all eight gaps were stock the system didn't have, $778 at cost.
      expect(_rich('Stock gaps · shelf vs system'), findsOneWidget);
      expect(find.text(r'+$778'), findsOneWidget);
      expect(find.text("of stock the system didn't know about"), findsOneWidget);
      expect(find.text('8 of 160'), findsOneWidget);
      expect(find.text('item counts off'), findsOneWidget);
      expect(find.text('All 8 gaps were extra stock: usually deliveries or returns not entered in the system'), findsOneWidget);
      expect(find.text('End Bearing Plate | Residential 12GA | LH 3-3/8" × 1"'), findsOneWidget);
      expect(find.text('+32'), findsOneWidget);
      expect(find.text(r'$190'), findsOneWidget); // 32 at $5.94
      expect(_rich('System 11  →  shelf 42'), findsOneWidget); // the right-hand drum
      // Nothing was short, so there is no "missing" side and no red key.
      expect(find.text('extra →'), findsOneWidget);
      expect(find.text('← missing'), findsNothing);
      expect(find.text('Missing from the shelf'), findsNothing);
      await saveDashShot(t, 'warehouse_dennis_gaps_view');
      // Pointer on the chart: it stays put.
      final title = _rich('Stock gaps · shelf vs system');
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: t.getCenter(title));
      await mouse.moveTo(t.getCenter(title) + const Offset(0, 120));
      await _seconds(t, 9);
      expect(_rich('Stock gaps · shelf vs system'), findsOneWidget);
      await mouse.removePointer();
      await _seconds(t, 9);
      await settleDashboard(t, frames: 12);
      // Stock levels, production's of Nov 2: 86 of the 194 items with a reorder point are empty.
      expect(_rich('Stock levels · today'), findsOneWidget);
      expect(find.text('86 of 194'), findsOneWidget);
      expect(find.text('Most empty: Operator Parts, all 19 of its items with a reorder point · 46 more items are low'), findsOneWidget);
      expect(find.text('Low = some on hand, at or below the reorder point'), findsOneWidget);
      for (final key in ['Empty 86', 'Low 46', 'Stocked 62']) {
        expect(find.text(key), findsOneWidget, reason: key);
      }
      expect(find.text('Miscellaneous'), findsOneWidget);
      expect(find.text('4 empty · 12 low'), findsOneWidget);
      expect(find.text('19 empty'), findsOneWidget);
      // The records to fix, as cards at this height: the count, what is missing, and what that does. Only items with stock
      // on hand count (catalog items nobody keeps in stock need none of these).
      for (final (n, what, why) in [
        ('29', 'stocked items with no reorder point', "Can't show as low"),
        ('53', 'stocked items with no shelf location', 'Harder to find and count'),
        ('4', 'stocked items with no cost', 'Missing from the stock value'),
      ]) {
        expect(find.text(n), findsOneWidget, reason: what);
        expect(find.text(what), findsOneWidget);
        expect(find.text(why), findsOneWidget);
      }
      await saveDashShot(t, 'warehouse_dennis_levels_view');
      await _seconds(t, 7);
      await settleDashboard(t, frames: 12);
      expect(_rich('Cycle counts · last 6 months'), findsOneWidget);
      expect(find.text('scheduled counts done'), findsOneWidget);
      // 15 weeks came due since counts were recorded (Jul-Oct for 4 zones, less Zone 4's open October); 3 were missed.
      expect(find.text('12 of 15'), findsOneWidget);
      expect(find.text('Zone 2 is furthest behind: 2 missed'), findsOneWidget);
      expect(find.text('Missed latest'), findsOneWidget); // Zone 2
      expect(find.text('3 in a row'), findsOneWidget); // Zone 4, its open week skipped
      await saveDashShot(t, 'warehouse_dennis_cycles_view');
      await _seconds(t, 7); // one more step (the timer ticks every 8 s), back to the first view
      await settleDashboard(t, frames: 12);
      expect(_rich('Inventory accuracy · last 12 weeks'), findsOneWidget);
    });
  });

  testWidgets('stock gaps both ways: the zero line moves in, the side that leads gets the headline', (t) async {
    final errors = await pumpDashboard(
      t,
      _page(),
      api: whApi(mutate: (w) {
        w
          ..['topMisses'] = [
            {'name': 'Torsion Spring | 0.234 x 2 | 32 in', 'systemQty': 14, 'countedQty': 6, 'cost': 38.5},
            {'name': 'Drum RC | SL | RH D400-96', 'systemQty': 11, 'countedQty': 17, 'cost': 4.91},
            {'name': 'Belt Drive | 6690L | LiftMaster', 'systemQty': 4, 'countedQty': 1, 'cost': null},
          ]
          ..['stockGaps'] = {'shortItems': 2, 'extraItems': 1, 'shortUnits': 11, 'extraUnits': 6, 'shortValue': 308, 'extraValue': 29};
      }),
      size: const Size(1500, 800),
      body: () async {
        await t.tap(find.text('Stock gaps'));
        await settleDashboard(t, frames: 25);
        expect(find.text(r'−$308'), findsOneWidget);
        expect(find.text('of stock missing from the shelves'), findsOneWidget);
        expect(find.text(r'+$29'), findsOneWidget);
        expect(find.text('2 of 3 gaps were missing stock: check material is being checked out'), findsOneWidget);
        expect(find.text('← missing'), findsOneWidget);
        expect(find.text('extra →'), findsOneWidget);
        expect(find.text('−8'), findsOneWidget);
        expect(find.text(r'$308'), findsOneWidget); // 8 at $38.50
        expect(find.text('no cost'), findsOneWidget); // the belt drive has none on record
        for (final key in ['Missing from the shelf', 'On the shelf, not in the system', 'Shelf matches the system']) {
          expect(find.text(key), findsOneWidget, reason: key);
        }
        await saveDashShot(t, 'warehouse_dennis_gaps_both_ways');
      },
    );
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('a server without the new stock figures: gaps add up the rows, the rest says what it needs', (t) async {
    final errors = await pumpDashboard(
      t,
      _page(),
      api: whApi(mutate: (w) {
        w
          ..remove('stockGaps')
          ..remove('coverage')
          ..remove('stockHealth')
          ..['topMisses'] = [
            {'name': 'Torsion Spring | 0.234 x 2 | 32 in', 'systemQty': 14, 'countedQty': 6},
            {'name': 'Hinge | Shim Kit | Up to 9" Wide', 'systemQty': 10, 'countedQty': 12},
          ];
      }),
      size: const Size(1500, 800),
      body: () async {
        expect(find.text('of 443 items'), findsOneWidget); // the old Low stock caption
        expect(_rich('items counted in'), findsNothing);
        await t.tap(find.text('Stock gaps'));
        await settleDashboard(t, frames: 25);
        expect(find.text('−8'), findsWidgets); // no costs: the headline is in units
        expect(find.text('units missing from the shelves'), findsOneWidget);
        expect(find.text('no cost'), findsNWidgets(2));
        await t.tap(find.text('Stock levels'));
        await settleDashboard(t, frames: 10);
        expect(find.text('Stock levels appear once the server is updated'), findsOneWidget);
      },
    );
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  for (final scale in const [1.0, 1.3]) {
    testWidgets('every chart view fits the smallest window (1280x600, text ${(scale * 100).round()}%)', (t) async {
      final errors = await pumpDashboard(t, _page(), api: whApi(), size: const Size(1280, 600), textScale: scale, body: () async {
        for (final view in ['Stock gaps', 'Stock levels', 'Cycles']) {
          await t.tap(find.text(view));
          await settleDashboard(t, frames: 25);
          await saveDashShot(t, 'warehouse_dennis_1280x600_${view.replaceAll(' ', '_').toLowerCase()}_${(scale * 100).round()}');
        }
      });
      expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
    });
  }

  testWidgets('hovering a scorecard brings its definition in as an animated card, inside the window', (t) async {
    final errors = await pumpDashboard(t, _page(), api: whApi(), size: const Size(1500, 800), body: () async {
      Finder card() => find.textContaining('whose shelf count matched the system quantity');
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(1, 400));
      await mouse.moveTo(t.getCenter(find.text('Inventory accuracy').first));
      await t.pump(const Duration(milliseconds: 200));
      expect(card(), findsNothing, reason: 'a short wait first, so passing over a card does nothing');
      await t.pump(const Duration(milliseconds: 200));
      await t.pump(const Duration(milliseconds: 80));
      expect(card(), findsOneWidget);
      final mid = t.widget<FadeTransition>(find.ancestor(of: card(), matching: find.byType(FadeTransition)).first).opacity.value;
      expect(mid, inExclusiveRange(0, 1), reason: 'it fades in rather than popping up');
      await settleDashboard(t, frames: 5);
      expect(find.text('94.4%'), findsWidgets); // the value repeated on the card
      await saveDashShot(t, 'warehouse_dennis_hover_card');
      // The last scorecard's card opens leftwards, so it stays inside the window.
      await mouse.moveTo(t.getCenter(find.text('Team inv. strikes')));
      await settleDashboard(t, frames: 8);
      final team = find.textContaining("every current tech's 5 added up");
      expect(team, findsOneWidget);
      expect(t.getRect(team).right, lessThanOrEqualTo(1500));
      await saveDashShot(t, 'warehouse_dennis_hover_card_right');
      // Open POs is red and Cycle counts done is ink: both values still read on the dark card.
      for (final (title, value) in [('Open POs', '7'), ('Cycle counts done', '2')]) {
        await mouse.moveTo(t.getCenter(find.text(title)));
        await settleDashboard(t, frames: 8);
        final shown = t.widget<Text>(find.descendant(of: find.byType(OverlayPortal), matching: find.text(value)).last);
        final fg = shown.style!.color!.computeLuminance(), bg = const Color(0xFF1E293B).computeLuminance();
        expect((fg + 0.05) / (bg + 0.05), greaterThanOrEqualTo(4.5), reason: '$title on the hover card');
        await saveDashShot(t, 'warehouse_dennis_hover_${title.replaceAll(' ', '_').toLowerCase()}');
      }
      await mouse.moveTo(const Offset(700, 700));
      await settleDashboard(t, frames: 5);
      expect(team, findsNothing, reason: 'it goes away when the pointer leaves');
      await mouse.removePointer();
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('a view picked by hand shows at once', (t) async {
    await pumpDashboard(t, _page(), api: whApi(), size: const Size(1500, 800), body: () async {
      await t.tap(find.text('Cycles'));
      await settleDashboard(t, frames: 12);
      expect(_rich('Cycle counts · last 6 months'), findsOneWidget);
      await t.tap(find.text('Stock levels'));
      await settleDashboard(t, frames: 12);
      expect(_rich('Stock levels · today'), findsOneWidget);
    });
  });

  Finder moraleBadge() => find.byWidgetPredicate((w) => w is Tooltip && (w.message ?? '').startsWith('Morale'));

  testWidgets('morale in the title bar previews sample scores, tries others, then hides', (t) async {
    final errors = await pumpDashboard(t, _page(), api: whApi(), size: const Size(1500, 800), body: () async {
      await t.tap(moraleBadge());
      await settleDashboard(t, frames: 12);
      expect(find.text('4.2'), findsOneWidget); // peer rating
      expect(find.text('3.6'), findsOneWidget); // morale
      expect(find.text('Morale · sample'), findsOneWidget);
      await t.tap(moraleBadge());
      await settleDashboard(t, frames: 4);
      expect(find.text('4.5'), findsOneWidget);
      for (var i = 0; i < 3; i++) {
        await t.tap(moraleBadge());
        await settleDashboard(t, frames: 4);
      }
      expect(find.text('4.2'), findsNothing); // back to nothing recorded
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('reduced motion: final figures at once, nothing left animating', (t) async {
    await pumpDashboard(t, _page(), api: whApi(), size: const Size(1280, 600), reduceMotion: true, body: () async {
      expect(find.text('94.4%'), findsWidgets);
      expect(t.binding.hasScheduledFrame, isFalse, reason: 'the heartbeat, the scorecards and the chart hold still');
    });
  });

  // ---------------------------------------------------------------------------------------------------------------
  // Filters, refresh and drill-downs
  // ---------------------------------------------------------------------------------------------------------------
  testWidgets("the year picker loads 2025 from the server; stock, POs, zones and the latest weeks say they are today's", (t) async {
    final api = whApi();
    final errors = await pumpDashboard(t, _page(), api: api, size: const Size(1500, 800), body: () async {
      await t.tap(dashYearArrow('Previous year'));
      await settleDashboard(t);
      expect(api.to('/api/employees/dgray/kpis').map((r) => r.url.queryParameters['year']), ['2026', '2025']);
      expect(find.text('63'), findsOneWidget); // jobs
      expect(find.text('11'), findsOneWidget); // cycle counts
      expect(find.text('all of 2025'), findsOneWidget);
      expect(find.textContaining('as of today'), findsWidgets); // the live cards say so
      expect(_rich('Cycle count zones · as of today'), findsOneWidget);
      // The weekly accuracy line is always the latest 12 weeks, whatever the year.
      expect(_rich('Inventory accuracy · last 12 weeks · as of today'), findsOneWidget);
      // Callback strikes are counted from Oct 5, 2026: 2025 has none to show, not a green zero.
      expect(find.text('Tracking began Oct 5, 2026'), findsOneWidget);
      await saveDashShot(t, 'warehouse_dennis_2025');
      await t.tap(find.text('Cycles'));
      await settleDashboard(t, frames: 12);
      expect(_rich('Cycle counts · last 6 months · as of today'), findsOneWidget);
      await t.tap(dashYearArrow('Next year'));
      await settleDashboard(t);
      expect(api.to('/api/employees/dgray/kpis').last.url.queryParameters['year'], '2026');
      expect(find.text('41'), findsOneWidget);
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('Refresh asks the server again past its cache and keeps the figures on screen', (t) async {
    final api = whApi();
    await pumpDashboard(t, _page(), api: api, size: const Size(1500, 800), body: () async {
      await t.tap(dashRefreshButton);
      await t.pump(const Duration(milliseconds: 10));
      expect(find.text('94.4%'), findsWidgets, reason: 'figures stay while it refreshes');
      await settleDashboard(t);
      expect(api.to('/api/employees/dgray/kpis').last.url.queryParameters['fresh'], '1');
    });
  });

  testWidgets('callback strikes open the callback visits behind them, for the year shown', (t) async {
    final api = whApi(mutate: (w) => w['callbackStrikes'] = 2);
    await pumpDashboard(t, _page(), api: api, size: const Size(1500, 800), body: () async {
      await t.tap(find.text('Callback strikes'));
      await settleDashboard(t, frames: 10);
      expect(find.text('Dennis Gray · Callback strikes'), findsOneWidget);
      expect(find.text('Sample customer 1'), findsOneWidget);
      await saveDashShot(t, 'warehouse_dennis_callbacks');
      expect(api.requests.where((r) => r.url.path.endsWith('/callbacks')).map((r) => r.url.queryParameters['year']), ['2026']);
    });
  });

  testWidgets('before callback tracking began there is no figure and nothing to open', (t) async {
    final api = whApi(mutate: (w) => w['callbackStrikes'] = 2);
    await pumpDashboard(t, _page(), api: api, size: const Size(1500, 800), body: () async {
      await t.tap(dashYearArrow('Previous year'));
      await settleDashboard(t);
      expect(find.text('Tracking began Oct 5, 2026'), findsOneWidget);
      await t.tap(find.text('Callback strikes'));
      await settleDashboard(t, frames: 5);
      expect(find.textContaining('Dennis Gray ·'), findsNothing);
      expect(api.requests.where((r) => r.url.path.endsWith('/callbacks')), isEmpty);
    });
  });

  testWidgets('with no callback strikes there is nothing to open', (t) async {
    final api = whApi();
    await pumpDashboard(t, _page(), api: api, size: const Size(1500, 800), body: () async {
      await t.tap(find.text('Callback strikes'));
      await settleDashboard(t, frames: 5);
      expect(find.textContaining('Dennis Gray ·'), findsNothing);
      expect(api.requests.where((r) => r.url.path.endsWith('/callbacks')), isEmpty);
    });
  });

  testWidgets('the back button returns to the list', (t) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(1500, 800);
    addTearDown(t.view.reset);
    final api = whApi();
    final router = GoRouter(
      initialLocation: '/hr/kpis/dgray',
      routes: [
        GoRoute(path: '/hr/kpis', builder: (_, _) => const Text('KPI list'), routes: [
          GoRoute(path: ':id', builder: (_, s) => EmployeeKpiScreen(employeeId: s.pathParameters['id']!)),
        ]),
      ],
    );
    await http.runWithClient(() async {
      await t.pumpWidget(MaterialApp.router(routerConfig: router, theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true)));
      await settleDashboard(t);
      expect(find.text('DENNIS GRAY'), findsOneWidget);
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
    await pumpDashboard(t, _page(), api: whApi(kpisGate: gate), size: const Size(1280, 600), body: () async {
      expect(find.bySemanticsLabel('Loading figures'), findsOneWidget);
      await saveDashShot(t, 'warehouse_dennis_loading');
      gate.complete();
      await settleDashboard(t);
      expect(find.bySemanticsLabel('Loading figures'), findsNothing);
      expect(find.text('94.4%'), findsWidgets);
    });
  });

  testWidgets('a failed load says so in words, with Try again that works', (t) async {
    var status = 500;
    final api = whApi(kpisStatus: () => status);
    await pumpDashboard(t, _page(), api: api, size: const Size(1280, 600), body: () async {
      expect(find.text("Couldn't load Dennis's figures"), findsOneWidget);
      expect(find.textContaining('error 500'), findsOneWidget);
      await saveDashShot(t, 'warehouse_dennis_error');
      status = 200;
      await t.tap(find.text('Try again'));
      await settleDashboard(t);
      expect(find.text('94.4%'), findsWidgets);
    });
  });

  testWidgets('a signed-out answer signs out', (t) async {
    await pumpDashboard(t, _page(), api: whApi(kpisStatus: () => 401), size: const Size(1280, 600), body: () async {
      expect(AuthSession.instance.isLoggedIn, isFalse);
      expect(find.text('Your session ended'), findsOneWidget);
    });
  });

  testWidgets("a server without the warehouse figures says so, and doesn't show a page of zeros", (t) async {
    final errors = await pumpDashboard(t, _page(), api: whApi(withWarehouse: false), size: const Size(1280, 600), body: () async {
      expect(find.text("Warehouse figures aren't available yet"), findsOneWidget);
      expect(find.text('Inventory accuracy'), findsNothing);
      await saveDashShot(t, 'warehouse_dennis_old_server');
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('nothing counted yet: dashes and plain empty states, not zeros or made-up percentages', (t) async {
    final errors = await pumpDashboard(
      t,
      _page(),
      api: whApi(mutate: (w) {
        w
          ..['inventoryAccuracy'] = null
          ..['accuracyTrend'] = <Object>[]
          ..['topMisses'] = <Object>[]
          ..['stockGaps'] = null
          ..['coverage'] = {'items': 0, 'value': 0}
          ..['cycleHistory'] = <Object>[]
          ..['cycleDone'] = 0
          ..['itemsCounted'] = 0
          ..['lastCycleCount'] = null
          ..['openPos'] = null
          ..['callbackStrikes'] = null
          ..['jobsCompleted'] = null
          ..['teamInventoryStrikes'] = null
          ..['zones'] = <Object>[]
          ..['history'] = {'lowStock': <Object>[], 'teamStrikes': <Object>[], 'teamStrikesWithMe': <Object>[]};
      }),
      size: const Size(1500, 800),
      body: () async {
        expect(find.text('No counts yet'), findsOneWidget); // "Starts with the next cycle count" where the card is wide enough
        expect(find.text('None counted in 2026'), findsOneWidget); // not "They hold 0% of the stock's value"
        expect(find.text('None completed yet'), findsOneWidget);
        expect(find.text('No cycle count zones are set up yet'), findsOneWidget);
        expect(find.text('No count with quantities recorded in 2026 yet'), findsOneWidget);
        expect(find.text('Not available yet'), findsNWidgets(4)); // open POs, jobs, callback strikes, team strikes
        await saveDashShot(t, 'warehouse_dennis_empty');
        await t.tap(find.text('Stock gaps'));
        await settleDashboard(t, frames: 10);
        expect(find.text('No counts with quantities recorded yet'), findsOneWidget);
        await t.tap(find.text('Cycles'));
        await settleDashboard(t, frames: 10);
        expect(find.text('No cycle counts scheduled yet'), findsOneWidget);
      },
    );
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  for (final (pcts, words) in [
    ([96.0], 'Week of Sep 21: 96%, on target'),
    ([92.0], 'Week of Sep 21: 92%, 3 points under target'),
    ([96.0, 97.0], 'On target in all 2 weeks'),
    ([90.0, 92.0], 'Under target in all 2 weeks · latest week 3 points under target'),
    ([90.0, 96.0], 'On target in 1 of 2 weeks, including the latest'),
  ]) {
    testWidgets('the accuracy callout: $words', (t) async {
      await pumpDashboard(
        t,
        _page(),
        api: whApi(mutate: (w) => w['accuracyTrend'] = [for (final p in pcts) {'week': '2026-09-21', 'counted': 20, 'pct': p}]),
        size: const Size(1500, 800),
        body: () async => expect(find.text(words), findsOneWidget),
      );
    });
  }

  testWidgets('a tall window sets the zones out as a board; a short one keeps the rows', (t) async {
    double gap(WidgetTester t) => t.getTopLeft(find.text('Zone 2')).dy - t.getTopLeft(find.text('Zone 1')).dy;
    await pumpDashboard(t, _page(), api: whApi(), size: const Size(1366, 768), body: () async {
      // Zone 2 sits beside Zone 1, and every figure is still there.
      expect(gap(t), 0);
      expect(t.getTopLeft(find.text('Zone 2')).dx, greaterThan(t.getTopLeft(find.text('Zone 1')).dx));
      expect(find.text('Overdue'), findsNWidgets(2));
      expect(find.text('31 items so far'), findsOneWidget);
      expect(find.text('Oct 16 · 82 items'), findsOneWidget);
    });
    await pumpDashboard(t, _page(), api: whApi(), size: const Size(1280, 600), body: () async {
      expect(gap(t), inInclusiveRange(48, 84));
    });
  });

  testWidgets('no strikes at all reads green; a nothing-past-due purchase order list says so', (t) async {
    final errors = await pumpDashboard(
      t,
      _page(),
      api: whApi(mutate: (w) {
        w
          ..['strikes'] = 0
          ..['teamInventoryStrikes'] = 0
          ..['openPos'] = {'count': 3, 'value': 900.0, 'overdue': 0, 'oldest': '2026-10-20', 'aging': <Object>[]};
      }),
      size: const Size(1500, 800),
      body: () async {
        expect(find.text(r'$900 open · none past due'), findsOneWidget);
      },
    );
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('a person whose role is tech keeps the technician page (Dennis is "warehouse" by role)', (t) async {
    final users = [
      {...whUsersBody()[0], 'jobTitle': 'Technician', 'displayTitle': 'Technician'},
    ];
    final api = whApi(users: users);
    await pumpDashboard(t, _page(), api: api, size: const Size(1500, 800), body: () async {
      expect(find.text('Cycle count zones'), findsNothing);
    });
  });

  // ---------------------------------------------------------------------------------------------------------------
  // Narrow windows scroll in one column, like the dashboards
  // ---------------------------------------------------------------------------------------------------------------
  for (final size in const [Size(1000, 700), Size(800, 900), Size(480, 900)]) {
    testWidgets('below desktop width: one scrolling column (${size.width.round()}x${size.height.round()})', (t) async {
      final errors = await pumpDashboard(t, _page(), api: whApi(), size: size, body: () async {
        await saveDashShot(t, 'warehouse_dennis_${size.width.round()}x${size.height.round()}');
      });
      expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
    });
  }
}
