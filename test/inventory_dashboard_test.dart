// The Inventory dashboard (redesigned like Collections): it fits the window with no scrolling at desktop sizes, every
// category on screen in both views, the strike ranking, the "not tracked yet" figures said plainly, the stock movement
// chart once movement is recorded, and the loading, empty, error and reduced-motion states. Uses
// test/fixtures/dashboards/inventory.json and the clock pinned to Oct 22, 2026.
// Screenshots go to build/dash_shots/inventory_*.png (not goldens).
//
// Run: flutter test test/inventory_dashboard_test.dart

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:iohd_desktop/inventory_dashboard_screen.dart';
import 'package:iohd_desktop/widgets/dashboard_kit.dart';
import 'package:iohd_desktop/widgets/dashboard_panels.dart';

import 'dashboard_fit.dart';
import 'dashboard_harness.dart';

const _path = '/api/dashboards/inventory';

DashFakeApi _changed(void Function(Map<String, dynamic> f) change) => DashFakeApi()
  ..extra.add((req) async {
    if (req.url.path != _path) return null;
    final f = dashFixture('inventory');
    change(f);
    return http.Response(json.encode(f), 200);
  });

void main() {
  setUpAll(loadDashFonts);
  setUp(() async {
    pinDashClock();
    await dashSignIn();
  });
  tearDown(unpinDashClock);

  final f = dashFixture('inventory');
  final cats = (f['categories'] as List).cast<Map<String, dynamic>>();

  group('fits the window, no scrolling', () {
    dashFitTests(
      'inventory',
      () => const InventoryDashboardScreen(),
      DashFakeApi.new,
      mustShow: [
        'Stock value',
        'Last cycle count',
        'Oct 16, 2026',
        for (final c in cats) c['category'] as String,
        'Stock health',
        for (final s in (f['topStrikeTechs'] as List)) s['name'] as String,
        'Stock movement',
      ],
    );

    testWidgets('once stock movement is recorded, its chart takes the note\'s place with no overflow', (t) async {
      final api = _changed((f) {
        f['movementTracked'] = true;
        f['monthly'] = [
          for (var m = 1; m <= 10; m++)
            {'month': 'M$m', 'received': 4000 + m * 300, 'used': 3500 + m * 250, 'onHand': 50000 + m * 500, 'hasData': true},
        ];
      });
      for (final (size, scale) in const [(Size(1280, 600), 1.0), (Size(1280, 600), 1.3), (Size(1920, 940), 1.0)]) {
        final errors = await pumpDashboard(t, const InventoryDashboardScreen(), api: api, size: size, textScale: scale,
            body: () async => saveDashShot(t, 'inventory_tracked_${size.width.toInt()}_${(scale * 100).round()}'));
        expect(errors.overflowed, isFalse, reason: errors.messages.toSet().join('\n'));
        expect(find.textContaining('Stock received · '), findsOneWidget);
        expect(dashVerticalScrollers(t), isEmpty);
      }
    });

    testWidgets('1000x700 (narrower than a desktop window): one column with no overflow', (t) async {
      final errors = await pumpDashboard(t, const InventoryDashboardScreen(), api: DashFakeApi(),
          size: const Size(1000, 700), body: () async => saveDashShot(t, 'inventory_1000x700'));
      expect(errors.overflowed, isFalse, reason: errors.messages.toSet().join('\n'));
    });

    testWidgets('nothing moves on its own once the entrance is over', (t) async {
      await pumpDashboard(t, const InventoryDashboardScreen(), api: DashFakeApi());
      await t.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 5));
    });
  });

  group('figures', () {
    testWidgets('each category with its value and share, and its stock health one click away', (t) async {
      final handle = t.ensureSemantics();
      await pumpDashboard(t, const InventoryDashboardScreen(), api: DashFakeApi(), body: () async {
        final total = (f['totalValuation'] as num).toDouble();
        // The finding: the category holding the most value, and its share of the whole.
        num value(Map<String, dynamic> c) => (c['activeValue'] as num) + (c['lowStockValue'] as num) + (c['deadValue'] as num);
        final top = cats.reduce((a, b) => value(b) > value(a) ? b : a);
        final share = (value(top) / total * 100).round();
        expect(find.text('${top['category']} holds $share% of the stock value · ${cats.length} categories'), findsOneWidget);
        for (final c in cats) {
          final v = (c['activeValue'] as num) + (c['lowStockValue'] as num) + (c['deadValue'] as num);
          expect(find.text(_usd(v)), findsOneWidget, reason: '${c['category']}');
        }
        expect(find.bySemanticsLabel(RegExp(r'^Hardware & Fasteners: \$6,530, 12% of stock value\. Not low \$6,120')),
            findsOneWidget);
        // Biggest category first, so the finding names the top row.
        final ys = [
          for (final c in [...cats]..sort((a, b) => value(b).compareTo(value(a))))
            t.getRect(find.text(c['category'] as String)).top,
        ];
        expect(ys, orderedEquals([...ys]..sort()), reason: 'categories run biggest value first');
        await t.tap(find.text('Stock health'));
        await settleDashboard(t, frames: 10);
        expect(find.text('Stock health by category · today'), findsOneWidget);
        expect(find.text('At or below reorder point'), findsWidgets);
        expect(find.text('6% low'), findsOneWidget, reason: r'Hardware: $410 of $6,530 is at or below its reorder point');
        expect(find.text('Dead'), findsNothing, reason: 'dead stock is not tracked yet, so it is not in the key');
        await saveDashShot(t, 'inventory_health');
      });
      handle.dispose();
    });

    testWidgets('strikes: fewest first, all time, with a plain count', (t) async {
      final handle = t.ensureSemantics();
      await pumpDashboard(t, const InventoryDashboardScreen(), api: DashFakeApi());
      final strikes = (f['topStrikeTechs'] as List).cast<Map<String, dynamic>>();
      expect(find.bySemanticsLabel('Number 1. ${strikes[0]['name']}: ${strikes[0]['strikeCount']} strikes'), findsOneWidget);
      expect(find.text('Fewest inventory strikes · all time'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('what is not tracked says so instead of a made-up figure; there is no year to pick', (t) async {
      final api = DashFakeApi();
      await pumpDashboard(t, const InventoryDashboardScreen(), api: api);
      expect(find.text('Not tracked yet'), findsOneWidget, reason: 'dead stock');
      expect(find.text('Starts with the next count'), findsOneWidget, reason: 'accuracy is tracked, just not counted yet');
      expect(find.textContaining("Not tracked yet. Stock received and parts used on jobs aren't recorded"), findsOneWidget);
      expect(find.text('Zone finished 6 days ago'), findsOneWidget);
      expect(dashYearArrow('Previous year'), findsNothing);
      expect(api.to(_path).single.url.queryParameters.containsKey('year'), isFalse);
    });
  });

  group('accuracy and fit', () {
    testWidgets('a real accuracy figure: the warehouse KPI page\'s words, whole at every size', (t) async {
      final api = _changed((f) {
        f['accuracyPct'] = 91.1;
        f['accuracy'] = {'counted': 45, 'matched': 41, 'pct': 91.1};
      });
      for (final (size, scale) in const [(Size(1280, 600), 1.0), (Size(1280, 600), 1.3), (Size(1500, 800), 1.3)]) {
        late List<String> cut;
        final errors = await pumpDashboard(t, const InventoryDashboardScreen(), api: api, size: size, textScale: scale,
            body: () async {
          expect(find.text('91.1%'), findsOneWidget);
          expect(find.text('41 of 45 counts matched · 2026'), findsOneWidget);
          cut = dashTruncatedTexts(t);
          await saveDashShot(t, 'inventory_accuracy_${size.width.toInt()}_${(scale * 100).round()}');
        });
        expect(errors.overflowed, isFalse, reason: errors.messages.toSet().join('\n'));
        expect(cut, isEmpty, reason: 'nothing is cut short at $size x$scale');
      }
    });

    testWidgets('the category rows fill their panel: no blank half-panel in a tall window', (t) async {
      for (final size in const [Size(1366, 768), Size(1920, 940)]) {
        await pumpDashboard(t, const InventoryDashboardScreen(), api: DashFakeApi(), size: size, body: () async {
          final panel = t.getRect(
            find.ancestor(of: find.text('Value by category · today'), matching: find.byType(DashPanel)).first,
          );
          final names = [for (final c in cats) t.getRect(find.text(c['category'] as String)).center.dy]..sort();
          final pitch = names[1] - names[0];
          expect(panel.bottom - names.last, lessThan(pitch), reason: 'the last row ends at the bottom of the panel at $size');
          for (var i = 2; i < names.length; i++) {
            expect(names[i] - names[i - 1], closeTo(pitch, 1), reason: 'rows are evenly spaced at $size');
          }
        });
      }
    });

    testWidgets('nothing at or below a reorder point is not painted as a warning', (t) async {
      await pumpDashboard(t, const InventoryDashboardScreen(), api: _changed((f) => f['lowStockCount'] = 0), body: () async {
        final card = t.widget<AnimatedMetricCard>(
          find.byWidgetPredicate((w) => w is AnimatedMetricCard && w.title == 'At or below reorder point'),
        );
        expect(card.valueColor, DashUi.ink);
      });
    });
  });

  group('states', () {
    testWidgets('loading shows the skeleton in the same layout', (t) async {
      final held = Completer<http.Response>();
      final api = DashFakeApi()..extra.add((req) async => req.url.path == _path ? held.future : null);
      final errors = await pumpDashboard(t, const InventoryDashboardScreen(), api: api, body: () async {
        expect(find.byType(SkeletonPulse), findsOneWidget);
        expect(dashVerticalScrollers(t), isEmpty);
        await saveDashShot(t, 'inventory_loading');
        held.complete(http.Response(json.encode(dashFixture('inventory')), 200));
        await settleDashboard(t);
        expect(find.text('Stock value'), findsOneWidget);
      });
      expect(errors.overflowed, isFalse, reason: errors.messages.toSet().join('\n'));
    });

    testWidgets('nothing recorded: every panel says so', (t) async {
      final api = DashFakeApi()..fixture[_path] = 'inventory_empty';
      final errors = await pumpDashboard(t, const InventoryDashboardScreen(), api: api, body: () async {
        expect(find.text('No categories recorded yet.'), findsOneWidget);
        expect(find.text('No active technicians to rank.'), findsOneWidget);
        await saveDashShot(t, 'inventory_empty');
      });
      expect(errors.overflowed, isFalse, reason: errors.messages.toSet().join('\n'));
    });

    testWidgets('reduced motion: the first frame after the data arrives is already final', (t) async {
      final held = Completer<http.Response>();
      final api = DashFakeApi()..extra.add((req) async => req.url.path == _path ? held.future : null);
      await pumpDashboard(t, const InventoryDashboardScreen(), api: api, reduceMotion: true, body: () async {
        held.complete(http.Response(json.encode(dashFixture('inventory')), 200));
        await t.pump();
        await t.pump();
        expect(find.text('\$55,199'), findsWidgets);
        await t.pump();
        expect(t.binding.hasScheduledFrame, isFalse);
      });
    });
  });
}

final _thousands = RegExp(r'(\d)(?=(\d{3})+$)');
String _usd(num v) => '\$${v.round().toString().replaceAllMapped(_thousands, (m) => '${m[1]},')}';
