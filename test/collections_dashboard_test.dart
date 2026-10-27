// The Collections dashboard (redesign pilot): it fits the window with no scrolling at desktop sizes, which figures
// follow the year and which are as of today, the drill-downs (mouse and keyboard), the chart's keyboard reading, and
// the loading, empty, error and reduced-motion states. Uses the saved response in
// test/fixtures/dashboards/collections.json and the clock pinned to Oct 22, 2026 (dashboard_harness.dart).
//
// Screenshots go to build/dash_shots/collections_*.png for review. They are not goldens.
//
// Run: flutter test test/collections_dashboard_test.dart

import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:iohd_desktop/collections_dashboard_screen.dart';
import 'package:iohd_desktop/widgets/dashboard_kit.dart';

import 'dashboard_harness.dart';

const _path = '/api/dashboards/collections';
const _jobsPath = '/api/dashboards/collections/jobs';

/// The jobs behind the balances: three for Oakridge Property Co (adding up to $6,000) and two for other customers.
http.Response _jobs(http.Request req) {
  final items = [
    for (final (id, customer, value, days) in const [
      ('9200001', 'Oakridge Property Co', 1000.0, 400),
      ('9200002', 'Summit Builders', 64358.0, 80),
      ('9200003', 'Oakridge Property Co', 2000.0, 300),
      ('9200004', 'Oakridge Property Co ', 3000.0, 143), // trailing space: grouped as the same customer
      ('9200005', 'Oakridge Property Company', 500.0, 20), // a different customer whose name contains it
    ])
      {
        'jobId': id,
        'customerName': customer,
        'status': '90 Day Notice',
        'location': '1 Main St',
        'description': '',
        'startDate': '2026-01-0${id.substring(6)}',
        'value': value,
        'outcome': days > 90 ? 'lost' : 'open',
        'daysOld': days,
      },
  ];
  return http.Response(json.encode({'success': true, 'count': items.length, 'items': items}), 200);
}

DashFakeApi _api() => DashFakeApi()..extra.add((req) async => req.url.path == _jobsPath ? _jobs(req) : null);

/// The monthly chart's plot.
final _plot = find.byWidgetPredicate((w) => w is CustomPaint && w.painter.runtimeType.toString() == '_ChartPainter');

/// The panel (white box) a piece of text sits in.
Rect _panelOf(WidgetTester t, String text) => t.getRect(
  find.ancestor(of: find.text(text), matching: find.byType(Container)).last,
);

void main() {
  setUpAll(loadDashFonts);
  setUp(() async {
    pinDashClock();
    await dashSignIn();
  });
  tearDown(unpinDashClock);

  group('fits the window, no scrolling', () {
    for (final (size, scale, tag) in const [
      (Size(1280, 600), 1.0, '1280x600'),
      (Size(1280, 720), 1.0, '1280x720'),
      (Size(1366, 768), 1.0, '1366x768'),
      (Size(1500, 800), 1.0, '1500x800'),
      (Size(1920, 940), 1.0, '1920x940'),
      (Size(1280, 600), 1.3, '1280x600_text130'),
      (Size(1500, 800), 1.3, '1500x800_text130'),
    ]) {
      testWidgets('$tag: everything on screen, nothing scrolls, no overflow', (t) async {
        final errors = await pumpDashboard(t, const CollectionsDashboardScreen(), api: _api(), size: size, textScale: scale,
            body: () async => saveDashShot(t, 'collections_$tag'));
        expect(errors.overflowed, isFalse, reason: errors.messages.toSet().join('\n'));
        expect(t.takeException(), isNull);
        expect(find.byType(SingleChildScrollView), findsNothing, reason: 'the dashboard never scrolls at $tag');
        final screen = Offset.zero & size;
        for (final text in [
          'Collected 2026',
          'Written off 2026',
          'Outstanding balance',
          'Over 90 days',
          'How customers paid',
          'Check on Payment',
          'Northwind Homes LLC', // the third biggest balance: the list gives up rows to make room for the ticker
          'Cash', // the last payment method
        ]) {
          final r = t.getRect(find.text(text).first);
          expect(screen.contains(r.topLeft) && screen.contains(r.bottomRight), isTrue, reason: '$text is on screen');
        }
        // Larger text takes some of the chart's height, never the page's.
        expect(t.getRect(_plot).height, greaterThan(scale == 1 ? 200 : 150), reason: 'the chart has room to read');
      });
    }

    testWidgets('a short window puts stages and balances side by side; a taller one stacks them', (t) async {
      await pumpDashboard(t, const CollectionsDashboardScreen(), api: _api());
      var stages = _panelOf(t, 'Unpaid by stage · today');
      var owing = _panelOf(t, 'Biggest balances · today');
      expect(owing.top, stages.top, reason: '1280x600: side by side');
      expect(owing.left, greaterThan(stages.right));

      await pumpDashboard(t, const CollectionsDashboardScreen(), api: _api(), size: const Size(1500, 800));
      stages = _panelOf(t, 'Unpaid by stage · today');
      owing = _panelOf(t, 'Biggest balances · today');
      expect(owing.top, greaterThan(stages.bottom), reason: '1500x800: stacked');
      expect(owing.left, stages.left);
    });

    for (final (size, tag) in const [(Size(1000, 700), '1000x700'), (Size(900, 800), '900x800')]) {
      testWidgets('$tag (narrower than a desktop window): one column with no overflow', (t) async {
        final errors = await pumpDashboard(t, const CollectionsDashboardScreen(), api: _api(), size: size,
            body: () async {
          await saveDashShot(t, 'collections_$tag');
          await t.drag(find.byType(SingleChildScrollView), const Offset(0, -2000));
          await settleDashboard(t, frames: 5);
          await saveDashShot(t, 'collections_${tag}_end');
        });
        expect(errors.overflowed, isFalse, reason: errors.messages.toSet().join('\n'));
      });
    }

    testWidgets('no ticker or other endless animation on the page', (t) async {
      await pumpDashboard(t, const CollectionsDashboardScreen(), api: _api());
      expect(find.byType(AutoScrollTicker), findsNothing);
      // After the entrance everything stands still (pumpAndSettle would time out on a looping animation).
      await t.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 5));
    });
  });

  group('periods', () {
    testWidgets('year figures say their dates, today figures say today, and only the year ones follow the selector',
        (t) async {
      final api = _api()..yearFixture['$_path?year=2025'] = 'collections_empty';
      await pumpDashboard(t, const CollectionsDashboardScreen(), api: api, size: const Size(1500, 800), body: () async {
        expect(find.text('2026 to date'), findsNothing, reason: 'no group labels');
        expect(find.text('Net of refunds · Jan 1 – today'), findsOneWidget);
        expect(find.text('Invoiced, not yet paid · today'), findsOneWidget);
        expect(find.text('At 90 Day Notice · today'), findsOneWidget);
        expect(find.text('Unpaid by stage · today'), findsOneWidget);
        expect(find.text('Biggest balances · today'), findsOneWidget);
        expect(find.text('Oct so far'), findsOneWidget, reason: 'the month in progress is marked as a part month');
        expect(find.text('6% vs 2025 to date'), findsOneWidget);

        await t.tap(find.byTooltip('Previous year'));
        await settleDashboard(t);
        expect(api.to(_path).last.url.queryParameters['year'], '2025');
        expect(find.text('Collected 2025'), findsOneWidget);
        expect(find.text('Net of refunds · all of 2025'), findsOneWidget);
        expect(find.text('Invoiced, not yet paid · today'), findsOneWidget);
        expect(find.text('Oct so far'), findsNothing, reason: 'a past year has no month in progress');
      });
    });

    testWidgets('payment methods show their amounts and shares, and read out their payment counts', (t) async {
      final handle = t.ensureSemantics();
      await pumpDashboard(t, const CollectionsDashboardScreen(), api: _api());
      final f = dashFixture('collections');
      // Methods that net to zero or less (refunds) are left out, as before the redesign.
      for (final m in (f['methods'] as List)) {
        expect(find.text('${m['method']}'), (m['amount'] as num) > 0 ? findsWidgets : findsNothing);
      }
      expect(find.text('\$1,674,292'), findsOneWidget); // Check
      expect(find.bySemanticsLabel(RegExp(r'^Check: \$1,674,292, 69% of cash collected, 1,177 payments$')), findsOneWidget);
      handle.dispose();
    });
  });

  group('drill-downs', () {
    Future<Uri> openedUri(DashFakeApi api) async => api.to(_jobsPath).last.url;

    testWidgets('scorecards: Outstanding opens every unpaid job, Over 90 days the 90 Day Notice jobs', (t) async {
      final api = _api();
      await pumpDashboard(t, const CollectionsDashboardScreen(), api: api, body: () async {
        await t.tap(find.text('Outstanding balance'));
        await settleDashboard(t, frames: 5);
        expect((await openedUri(api)).queryParameters['stage'], 'all');
        expect(find.text('All unpaid balances'), findsOneWidget);
        await saveDashShot(t, 'collections_drill_outstanding');
        await t.tap(find.byTooltip('Close'));
        await settleDashboard(t, frames: 5);

        await t.tap(find.text('Over 90 days'));
        await settleDashboard(t, frames: 5);
        expect((await openedUri(api)).queryParameters['stage'], '90');
        expect(find.text('90 Day Notice · unpaid balances'), findsOneWidget);
      });
    });

    testWidgets('a stage row opens its jobs with Enter after tabbing to it', (t) async {
      final api = _api();
      await pumpDashboard(t, const CollectionsDashboardScreen(), api: api, body: () async {
        State card() => t.state(find.ancestor(of: find.text('Outstanding balance'), matching: find.byType(AnimatedMetricCard)));
        final cardBefore = card();
        // Tab until the 30 Day Notice row has focus (the ring is drawn), then Enter.
        final row = find.ancestor(of: find.text('30 Day Notice'), matching: find.byType(FocusableActionDetector));
        for (var i = 0; i < 40; i++) {
          await t.sendKeyEvent(LogicalKeyboardKey.tab);
          await t.pump();
          final focus = Focus.of(t.element(find.descendant(of: row, matching: find.byType(GestureDetector)).first));
          if (focus.hasPrimaryFocus || focus.hasFocus) break;
        }
        await saveDashShot(t, 'collections_keyboard_focus');
        // Focus passed over the Outstanding card on the way: drawing its ring must not rebuild it from scratch
        // (which would replay its entrance and leave it invisible for half a second).
        expect(identical(card(), cardBefore), isTrue);
        await t.sendKeyEvent(LogicalKeyboardKey.enter);
        await settleDashboard(t, frames: 5);
        expect((await openedUri(api)).queryParameters['stage'], '30');
        expect(find.text('30 Day Notice · unpaid balances'), findsOneWidget);
      });
    });

    testWidgets('"All 209 jobs" opens every unpaid job, oldest first', (t) async {
      final api = _api();
      await pumpDashboard(t, const CollectionsDashboardScreen(), api: api, body: () async {
        await t.tap(find.text('All 209 jobs'));
        await settleDashboard(t, frames: 5);
        expect((await openedUri(api)).queryParameters['stage'], 'all');
        expect(find.text('All unpaid balances'), findsOneWidget);
      });
    });

    testWidgets("a customer opens only that customer's unpaid jobs, adding up to their balance", (t) async {
      final api = _api();
      await pumpDashboard(t, const CollectionsDashboardScreen(), api: api, body: () async {
        await t.tap(find.text('Oakridge Property Co'));
        await settleDashboard(t, frames: 5);
        expect((await openedUri(api)).queryParameters['stage'], 'all');
        expect(find.text('Oakridge Property Co · unpaid balances'), findsOneWidget);
        expect(find.text('As of today · 3 jobs · \$6,000 unpaid'), findsOneWidget);
        await saveDashShot(t, 'collections_drill_customer');
      });
    });

    testWidgets('screen readers hear the stage rows and drill cards as buttons with their figures', (t) async {
      final handle = t.ensureSemantics();
      await pumpDashboard(t, const CollectionsDashboardScreen(), api: _api());
      final stage = t.getSemantics(find.bySemanticsLabel(RegExp(r'^90 Day Notice: \$22,577 unpaid on 40 jobs$')));
      expect(stage.flagsCollection.isButton, isTrue);
      expect(stage.hint, 'Opens the list of jobs');
      final card = t.getSemantics(find.bySemanticsLabel(RegExp(r'^Outstanding balance: \$238,133\. Unpaid balance')));
      expect(card.flagsCollection.isButton, isTrue);
      expect(card.hint, 'Opens the list of 209 jobs');
      expect(find.bySemanticsLabel('Unpaid by stage, today'), findsOneWidget);
      handle.dispose();
    });
  });

  group('chart', () {
    testWidgets('hovering a month shows it against the same month last year', (t) async {
      await pumpDashboard(t, const CollectionsDashboardScreen(), api: _api(), size: const Size(1500, 800), body: () async {
        final r = t.getRect(_plot);
        final slot = (r.width - 58) / 12;
        final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(Offset(r.left + 54 + slot * 3.5, r.center.dy)); // April
        await t.pump(const Duration(milliseconds: 100));
        expect(find.text('Apr 2026'), findsOneWidget);
        expect(find.text('\$395,785'), findsOneWidget);
        expect(find.text('2025: \$280,098'), findsOneWidget);
        expect(find.text('+41% on 2025'), findsOneWidget);
        await saveDashShot(t, 'collections_chart_hover');

        await mouse.moveTo(Offset(r.left + 54 + slot * 9.5, r.center.dy)); // October, in progress
        await t.pump(const Duration(milliseconds: 100));
        expect(find.text('Oct 2026 so far'), findsOneWidget);
        expect(find.text('2025 (whole month): \$326,806'), findsOneWidget);
        expect(find.textContaining('% on 2025'), findsNothing, reason: 'a part month is never compared with a whole one');
        await mouse.removePointer();
      });
    });

    testWidgets('the arrow keys read the chart month by month', (t) async {
      final handle = t.ensureSemantics();
      await pumpDashboard(t, const CollectionsDashboardScreen(), api: _api(), body: () async {
        final chart = find.bySemanticsLabel(RegExp('^Cash collected by month, 2026'));
        expect(t.getSemantics(chart).value, startsWith('Jan \$230.7k, Feb \$195.2k'));
        // Tab to the chart: focus starts on the month in progress.
        for (var i = 0; i < 40 && find.text('Oct 2026 so far').evaluate().isEmpty; i++) {
          await t.sendKeyEvent(LogicalKeyboardKey.tab);
          await t.pump();
        }
        expect(find.text('Oct 2026 so far'), findsOneWidget);
        await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await t.pump();
        expect(find.text('Sep 2026'), findsOneWidget);
        expect(t.getSemantics(chart).value, 'Sep 2026: \$137,737. 2025: \$226,395');
        await saveDashShot(t, 'collections_chart_keyboard');
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await t.pump();
        expect(find.text('Sep 2026'), findsNothing);
      });
      handle.dispose();
    });
  });

  group('states', () {
    testWidgets('loading shows the skeleton in the same layout', (t) async {
      final held = Completer<http.Response>();
      final api = _api()..extra.add((req) async => req.url.path == _path ? held.future : null);
      final errors = await pumpDashboard(t, const CollectionsDashboardScreen(), api: api, body: () async {
        expect(find.byType(SkeletonPulse), findsOneWidget);
        expect(find.byType(SingleChildScrollView), findsNothing);
        await saveDashShot(t, 'collections_loading');
        held.complete(http.Response(json.encode(dashFixture('collections')), 200));
        await settleDashboard(t);
        expect(find.text('Outstanding balance'), findsOneWidget);
      });
      expect(errors.overflowed, isFalse, reason: errors.messages.toSet().join('\n'));
    });

    testWidgets('an empty year says so in every panel', (t) async {
      final api = _api()..fixture[_path] = 'collections_empty';
      final errors = await pumpDashboard(t, const CollectionsDashboardScreen(), api: api, body: () async {
        expect(find.text('No payments recorded in 2026.'), findsNWidgets(2));
        expect(find.text('Nothing is owed today.'), findsOneWidget);
        expect(find.text('No customer owes a balance today.'), findsOneWidget);
        expect(find.textContaining('All 0'), findsNothing, reason: 'no link to an empty list');
        await saveDashShot(t, 'collections_empty');
      });
      expect(errors.overflowed, isFalse, reason: errors.messages.toSet().join('\n'));
    });

    testWidgets('a failed load and a failed refresh, for a look', (t) async {
      final api = _api()..status[_path] = 500;
      await pumpDashboard(t, const CollectionsDashboardScreen(), api: api, body: () async {
        await saveDashShot(t, 'collections_error');
        api.status.remove(_path);
        await t.tap(find.text('Try again'));
        await settleDashboard(t);
        api.status[_path] = 500;
        await t.tap(find.byTooltip('Refresh now'));
        await settleDashboard(t, frames: 5);
        expect(find.text("Couldn't refresh"), findsOneWidget);
        expect(find.text('\$238,133'), findsOneWidget);
        await saveDashShot(t, 'collections_refresh_failed');
      });
    });

    testWidgets('reduced motion: the first frame after the data arrives is already final', (t) async {
      final held = Completer<http.Response>();
      final api = _api()..extra.add((req) async => req.url.path == _path ? held.future : null);
      await pumpDashboard(t, const CollectionsDashboardScreen(), api: api, reduceMotion: true, body: () async {
        held.complete(http.Response(json.encode(dashFixture('collections')), 200));
        await t.pump(); // the answer arrives
        await t.pump(); // one frame
        // The figures are whole (no count-up in progress) and nothing is left moving: no entrance, no bar growth.
        expect(find.text('\$2,440,659'), findsWidgets);
        expect(find.text('\$238,133'), findsOneWidget);
        await t.pump();
        expect(t.binding.hasScheduledFrame, isFalse);
        await saveDashShot(t, 'collections_reduced_motion');
      });
    });
  });
}
