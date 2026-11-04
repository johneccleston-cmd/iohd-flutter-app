// The Financial dashboard (redesigned like Collections): it fits the window with no scrolling at desktop sizes, the
// chart's three views and its keyboard reading, every expense category on screen, the period wording, and the
// loading, empty, error and reduced-motion states. Uses test/fixtures/dashboards/financial.json and the clock pinned
// to Oct 22, 2026 (dashboard_harness.dart). Screenshots go to build/dash_shots/financial_*.png (not goldens).
//
// Run: flutter test test/financial_dashboard_test.dart

import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Tristate;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:iohd_desktop/reports_screen.dart';
import 'package:iohd_desktop/widgets/dashboard_kit.dart';

import 'dashboard_fit.dart';
import 'dashboard_harness.dart';

const _path = '/api/financial_dashboard';
const _chartTitle = 'Revenue & profit · completed jobs, by start month';

/// The monthly chart's plot.
final _plot = find.byWidgetPredicate((w) => w is CustomPaint && w.painter.runtimeType.toString() == '_DashChartPainter');

void main() {
  setUpAll(loadDashFonts);
  setUp(() async {
    pinDashClock();
    await dashSignIn();
  });
  tearDown(unpinDashClock);

  group('fits the window, no scrolling', () {
    dashFitTests(
      'financial',
      () => const ReportsScreen(),
      DashFakeApi.new,
      mustShow: [
        'Revenue + deposits',
        'Commercial pool',
        'Company pool',
        'Revenue by segment',
        'Other', // the last segment
        'Operating expenses',
        'Payroll (office)',
        'Revenue & profit',
      ],
      extra: (t, size, scale) async {
        // In a short window or at 130% text the pools card and all eight categories can't both stay whole, so the
        // smallest categories share one row there (as the panel always does when rows run out).
        if (scale == 1 && size.height >= 720) {
          expect(find.textContaining('Other categories'), findsNothing, reason: 'every category has its own row');
          expect(find.text('Uncategorized'), findsOneWidget, reason: 'the smallest of the eight categories has a row');
        }
        expect(t.getRect(_plot).height, greaterThan(scale == 1 ? 140 : 100), reason: 'the chart has room to read'); // under its headline and callout
      },
    );

    for (final (size, tag) in const [(Size(1000, 700), '1000x700'), (Size(900, 800), '900x800')]) {
      testWidgets('$tag (narrower than a desktop window): one column with no overflow', (t) async {
        final errors = await pumpDashboard(t, const ReportsScreen(), api: DashFakeApi(), size: size, body: () async {
          await saveDashShot(t, 'financial_$tag');
        });
        expect(errors.overflowed, isFalse, reason: errors.messages.toSet().join('\n'));
      });
    }

    testWidgets('nothing cycles on its own: after the entrance the page stands still', (t) async {
      await pumpDashboard(t, const ReportsScreen(), api: DashFakeApi());
      expect(find.text(_chartTitle), findsOneWidget);
      await t.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 5));
      await t.pump(const Duration(seconds: 12));
      expect(find.text(_chartTitle), findsOneWidget, reason: 'the chart stays on the view that was picked');
    });

    testWidgets('trend lines show where the words still fit beside them', (t) async {
      await pumpDashboard(t, const ReportsScreen(), api: DashFakeApi(), size: const Size(1920, 940));
      final cards = t.widgetList<AnimatedMetricCard>(find.byType(AnimatedMetricCard)).toList();
      expect(cards.where((c) => c.trend != null), hasLength(5), reason: 'the five main cards have a line to show');
      final lines = find.descendant(of: find.byType(AnimatedMetricCard), matching: find.byType(CustomPaint));
      expect(lines, findsAtLeastNWidgets(5), reason: 'at 1920 px each main card has room for its line');
    });
  });

  group('chart', () {
    testWidgets('three views, picked by hand: revenue and profit, margin, net income', (t) async {
      // 1500x800: room for the change chip beside the title (a narrower window leaves it to the headline).
      await pumpDashboard(t, const ReportsScreen(), api: DashFakeApi(), size: const Size(1500, 800), body: () async {
        expect(find.text(_chartTitle), findsOneWidget);
        expect(find.text('14% Sep vs Aug'), findsOneWidget, reason: 'last two finished months, never October');
        // The story: the year's revenue and profit, and the best month.
        expect(find.text('revenue so far'), findsOneWidget);
        expect(find.textContaining('Best month: '), findsOneWidget);
        await t.tap(find.text('Margin'));
        await settleDashboard(t, frames: 10);
        expect(find.textContaining('Profit margin · '), findsOneWidget);
        await saveDashShot(t, 'financial_view_margin');
        await t.tap(find.text('Net income'));
        await settleDashboard(t, frames: 10);
        expect(find.textContaining('Net income · '), findsOneWidget);
        await saveDashShot(t, 'financial_view_net');
      });
    });

    testWidgets('hovering a month shows revenue, profit and margin beside it', (t) async {
      await pumpDashboard(t, const ReportsScreen(), api: DashFakeApi(), size: const Size(1500, 800), body: () async {
        final r = t.getRect(_plot);
        final slot = (r.width - 58) / 12;
        final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(Offset(r.left + 54 + slot * 3.5, r.center.dy)); // April
        await t.pump(const Duration(milliseconds: 100));
        final apr = (dashFixture('financial')['chartData'] as List)[3] as Map<String, dynamic>;
        expect(find.text('Apr 2026'), findsOneWidget);
        expect(find.text(_usd(apr['revenue'] as num)), findsOneWidget);
        expect(find.text(_usd(apr['profit'] as num)), findsOneWidget);
        await saveDashShot(t, 'financial_chart_hover');
        await mouse.moveTo(Offset(r.left + 54 + slot * 9.5, r.center.dy)); // October, in progress
        await t.pump(const Duration(milliseconds: 100));
        expect(find.text('Oct 2026 so far'), findsOneWidget);
        await mouse.moveTo(Offset(r.left + 54 + slot * 11.5, r.center.dy)); // December, still to come
        await t.pump(const Duration(milliseconds: 100));
        expect(find.text('Not here yet'), findsOneWidget);
        await mouse.removePointer();
      });
    });

    testWidgets('Tab reaches the view toggle and the chart; the arrow keys read it month by month', (t) async {
      final handle = t.ensureSemantics();
      await pumpDashboard(t, const ReportsScreen(), api: DashFakeApi(), body: () async {
        final chart = find.bySemanticsLabel(RegExp('^Revenue and profit of completed jobs by month, 2026'));
        expect(t.getSemantics(chart).value, startsWith('Revenue by month: Jan \$182.4k'));
        for (var i = 0; i < 40 && find.text('Oct 2026 so far').evaluate().isEmpty; i++) {
          await t.sendKeyEvent(LogicalKeyboardKey.tab);
          await t.pump();
        }
        expect(find.text('Oct 2026 so far'), findsOneWidget, reason: 'focus starts on the month in progress');
        await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await t.pump();
        expect(find.text('Sep 2026'), findsOneWidget);
        expect(t.getSemantics(chart).value, startsWith('Sep 2026. Revenue: \$'));
        await saveDashShot(t, 'financial_chart_keyboard');
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await t.pump();
        expect(find.text('Sep 2026'), findsNothing);
        // The view toggle is a group of buttons, the picked one marked.
        final picked = t.getSemantics(find.bySemanticsLabel('Chart view: Revenue & profit'));
        expect(picked.flagsCollection.isButton, isTrue);
        expect(picked.flagsCollection.isSelected, Tristate.isTrue);
      });
      handle.dispose();
    });
  });

  group('figures', () {
    testWidgets('every category with its amount and share; the segments read as shares of revenue + deposits', (t) async {
      final handle = t.ensureSemantics();
      await pumpDashboard(t, const ReportsScreen(), api: DashFakeApi(), size: const Size(1366, 768));
      final f = dashFixture('financial');
      final total = (f['operatingExpenses'] as List).fold<num>(0, (s, e) => s + (e['amount'] as num));
      expect(find.text('Operating expenses · ${_usd(total)} in 2026'), findsOneWidget);
      expect(find.text('8 categories'), findsNothing, reason: 'every category has a row, so the count adds nothing');
      for (final e in (f['operatingExpenses'] as List)) {
        expect(find.text(e['category'] as String), findsOneWidget);
        expect(find.text(_usd(e['amount'] as num)), findsWidgets);
      }
      expect(find.bySemanticsLabel(RegExp(r'^Payroll \(office\): \$353,073, 38% of operating expenses$')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Residential: \$1,052,228, 41% of revenue \+ deposits$')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('hovering a category row swells and glows its bar, with one sweep of light, and settles back', (t) async {
      await pumpDashboard(t, const ReportsScreen(), api: DashFakeApi(), size: const Size(1366, 768), body: () async {
        final fx = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_BarFx');
        final row = find.text('Payroll (office)');
        final bar = find.descendant(of: find.ancestor(of: row, matching: find.byType(MouseRegion)).first, matching: fx);
        double scaleY() {
          final tr = t.widget<Transform>(find.descendant(of: bar.first, matching: find.byType(Transform)).first);
          return tr.transform.getMaxScaleOnAxis();
        }

        expect(scaleY(), 1.0);
        final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(t.getCenter(row) + const Offset(120, 0));
        await t.pump(const Duration(milliseconds: 100));
        await t.pump(const Duration(milliseconds: 300));
        expect(scaleY(), greaterThan(1.4), reason: 'the bar swells past its track while the row is hovered');
        await saveDashShot(t, 'financial_expense_hover');
        await t.pump(const Duration(milliseconds: 700)); // the sweep has run its course
        await mouse.moveTo(const Offset(2, 2));
        await t.pump(const Duration(milliseconds: 50));
        await t.pump(const Duration(milliseconds: 400));
        expect(scaleY(), 1.0);
        await mouse.removePointer();
        await t.pumpAndSettle();
      });
    });

    testWidgets('more categories than rows: the smallest share one row that names them and adds up', (t) async {
      final api = DashFakeApi()
        ..extra.add((req) async {
          if (req.url.path != _path) return null;
          final f = dashFixture('financial');
          f['operatingExpenses'] = [
            for (var i = 0; i < 16; i++) {'category': 'Category ${i + 1}', 'amount': 20000 - i * 1000},
          ];
          return http.Response(json.encode(f), 200);
        });
      final handle = t.ensureSemantics();
      final errors = await pumpDashboard(t, const ReportsScreen(), api: api, body: () async {
        await saveDashShot(t, 'financial_many_categories');
      });
      expect(errors.overflowed, isFalse, reason: errors.messages.toSet().join('\n'));
      final other = find.textContaining('Other categories (');
      expect(other, findsOneWidget);
      final n = int.parse(RegExp(r'\((\d+)\)').firstMatch(t.widget<Text>(other).data!)!.group(1)!);
      final shown = 16 - n;
      // The shared row's amount is the sum of the ones it holds, and a screen reader hears each of them.
      final grouped = [for (var i = shown; i < 16; i++) 20000 - i * 1000].fold<int>(0, (s, v) => s + v);
      expect(find.text(_usd(grouped)), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Category ${shown + 1} .*Category 16 \\\$5,000\$')), findsOneWidget);
      expect(find.text('Category $shown'), findsOneWidget, reason: 'the bigger ones keep their own rows');
      handle.dispose();
    });

    testWidgets('a past year names its period, drops the projection (it would repeat the first card), has no month in progress', (t) async {
      await pumpDashboard(t, const ReportsScreen(), api: DashFakeApi(), body: () async {
        expect(find.text('Jan 1 – today'), findsOneWidget);
        expect(find.text('Completed · Jan 1 – today'), findsOneWidget);
        expect(find.text('Of revenue · Jan 1 – today'), findsOneWidget);
        expect(find.text('2026 jobs, finished or not'), findsOneWidget);
        expect(find.text('Yearly projection'), findsOneWidget);
        expect(find.byType(AnimatedMetricCard), findsNWidgets(5));
        await t.tap(dashYearArrow('Previous year'));
        await settleDashboard(t);
        expect(find.text('All of 2025'), findsOneWidget);
        expect(find.text('Completed · all of 2025'), findsOneWidget);
        expect(find.text('2025 jobs, finished or not'), findsOneWidget);
        expect(find.textContaining('today'), findsNothing, reason: 'a finished year never reads as running to today');
        expect(find.text('Yearly projection'), findsNothing);
        expect(find.byType(AnimatedMetricCard), findsNWidgets(4));
        expect(find.text('Oct so far'), findsNothing, reason: 'a past year has no month in progress');
      });
    });

    testWidgets('no pool history: no line, so nothing fills the space with a dashed placeholder', (t) async {
      await pumpDashboard(t, const ReportsScreen(), api: DashFakeApi(), size: const Size(1920, 940), body: () async {
        expect(find.byType(DashSparkline), findsNothing);
      });
    });

    testWidgets('a pool draws its line from real readings; all-zero readings have nothing to draw', (t) async {
      final api = DashFakeApi()
        ..extra.add((req) async {
          if (req.url.path != _path) return null;
          final f = dashFixture('financial');
          (f['history'] as Map<String, dynamic>)
            ..['companyPool'] = [10, 14, 17]
            ..['commercialPool'] = [0, 0, 0];
          return http.Response(json.encode(f), 200);
        });
      await pumpDashboard(t, const ReportsScreen(), api: api, size: const Size(1920, 940), body: () async {
        expect(find.byType(DashSparkline), findsOneWidget);
      });
    });
  });

  group('states', () {
    testWidgets('loading shows the skeleton in the same layout', (t) async {
      final held = Completer<http.Response>();
      final api = DashFakeApi()..extra.add((req) async => req.url.path == _path ? held.future : null);
      final errors = await pumpDashboard(t, const ReportsScreen(), api: api, body: () async {
        expect(find.byType(SkeletonPulse), findsOneWidget);
        expect(dashVerticalScrollers(t), isEmpty);
        await saveDashShot(t, 'financial_loading');
        held.complete(http.Response(json.encode(dashFixture('financial')), 200));
        await settleDashboard(t);
        expect(find.text('Revenue + deposits'), findsOneWidget);
      });
      expect(errors.overflowed, isFalse, reason: errors.messages.toSet().join('\n'));
    });

    testWidgets('an empty past year does not say "yet"', (t) async {
      final api = DashFakeApi()..yearFixture['$_path?year=2025'] = 'financial_empty';
      await pumpDashboard(t, const ReportsScreen(), api: api, body: () async {
        await t.tap(dashYearArrow('Previous year'));
        await settleDashboard(t);
        expect(find.text('Nothing recorded for 2025.'), findsOneWidget);
        expect(find.text('No operating expenses recorded for 2025.'), findsOneWidget);
      });
    });

    testWidgets('an empty year says so in every panel', (t) async {
      final api = DashFakeApi()..fixture[_path] = 'financial_empty';
      final errors = await pumpDashboard(t, const ReportsScreen(), api: api, body: () async {
        expect(find.text('Nothing recorded for 2026 yet.'), findsOneWidget);
        expect(find.text('No revenue recorded in 2026.'), findsOneWidget);
        expect(find.text('No operating expenses recorded yet.'), findsOneWidget);
        await saveDashShot(t, 'financial_empty');
      });
      expect(errors.overflowed, isFalse, reason: errors.messages.toSet().join('\n'));
    });

    testWidgets('a failed load, then a failed refresh that keeps the figures', (t) async {
      final api = DashFakeApi()..status[_path] = 500;
      await pumpDashboard(t, const ReportsScreen(), api: api, body: () async {
        expect(find.text("Couldn't load financials"), findsOneWidget);
        await saveDashShot(t, 'financial_error');
        api.status.remove(_path);
        await t.tap(find.text('Try again'));
        await settleDashboard(t);
        api.status[_path] = 500;
        await t.tap(dashRefreshButton);
        await settleDashboard(t, frames: 5);
        expect(find.text("Couldn't refresh"), findsOneWidget);
        expect(find.text('\$2,566,410'), findsOneWidget);
      });
    });

    testWidgets('reduced motion: the first frame after the data arrives is already final', (t) async {
      final held = Completer<http.Response>();
      final api = DashFakeApi()..extra.add((req) async => req.url.path == _path ? held.future : null);
      await pumpDashboard(t, const ReportsScreen(), api: api, reduceMotion: true, body: () async {
        held.complete(http.Response(json.encode(dashFixture('financial')), 200));
        await t.pump();
        await t.pump();
        expect(find.text('\$2,566,410'), findsOneWidget);
        await t.pump();
        expect(t.binding.hasScheduledFrame, isFalse);
      });
    });
  });
}

final _thousands = RegExp(r'(\d)(?=(\d{3})+$)');
String _usd(num v) =>
    '${v < 0 ? '-' : ''}\$${v.abs().round().toString().replaceAllMapped(_thousands, (m) => '${m[1]},')}';
