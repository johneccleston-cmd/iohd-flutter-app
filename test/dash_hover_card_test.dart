// Every scorecard explains itself in the same animated dark hover card (lib/widgets/dash_hover_card.dart): the
// dashboards' AnimatedMetricCard, the Inventory dashboard's date card and the KPI pages' tiles. Screenshots go to
// build/dash_shots/.
//   flutter test test/dash_hover_card_test.dart

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/inventory_dashboard_screen.dart';
import 'package:iohd_desktop/jobs_dashboard_screen.dart';
import 'package:iohd_desktop/widgets/dash_hover_card.dart';

import 'dashboard_harness.dart';

/// Hovers the scorecard titled [title] and returns its hover card once it has come in.
Future<Finder> _hover(WidgetTester t, TestGesture mouse, String title) async {
  await mouse.moveTo(t.getCenter(find.text(title).first));
  await t.pump(const Duration(milliseconds: 200));
  final card = find.descendant(of: find.byType(CompositedTransformFollower), matching: find.text(title));
  expect(card, findsNothing, reason: 'a short wait first, so sweeping across the row does nothing');
  await t.pump(const Duration(milliseconds: 250));
  await t.pump(const Duration(milliseconds: 80));
  final fade = t.widget<FadeTransition>(find.ancestor(of: card.last, matching: find.byType(FadeTransition)).first).opacity.value;
  expect(fade, inExclusiveRange(0, 1), reason: 'it fades in rather than popping up');
  await settleDashboard(t, frames: 5);
  return card;
}

void main() {
  setUpAll(loadDashFonts);
  setUp(() async {
    pinDashClock();
    await dashSignIn();
  });
  tearDown(unpinDashClock);

  for (final (name, screen, title) in [
    ('jobs', const JobsDashboardScreen() as Widget, 'Completed jobs'),
    ('inventory', const InventoryDashboardScreen() as Widget, 'Stock value'),
    ('inventory_date', const InventoryDashboardScreen() as Widget, 'Last cycle count'),
  ]) {
    testWidgets('$name: "$title" explains itself in the hover card, and it leaves with the pointer', (t) async {
      final errors = await pumpDashboard(t, screen, api: DashFakeApi(), size: const Size(1500, 800), body: () async {
        final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(1, 790));
        final card = await _hover(t, mouse, title);
        expect(card, findsOneWidget);
        // The card sits inside the window.
        final box = t.getRect(find.ancestor(of: card, matching: find.byType(ConstrainedBox)).first);
        expect(box.right, lessThanOrEqualTo(1500));
        expect(box.bottom, lessThanOrEqualTo(800));
        await saveDashShot(t, 'hover_card_$name');
        await mouse.moveTo(const Offset(1, 790));
        await settleDashboard(t, frames: 5);
        expect(card, findsNothing);
        await mouse.removePointer();
      });
      expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
    });
  }

  test('values stay readable on the dark card, whatever the figure colour', () {
    const bg = Color(0xFF1E293B);
    double contrast(Color c) {
      final a = c.computeLuminance(), b = bg.computeLuminance();
      return (a > b ? a + 0.05 : b + 0.05) / (a > b ? b + 0.05 : a + 0.05);
    }

    for (final c in const [Color(0xFF0F172A), Color(0xFFDC2626), Color(0xFF6366F1), Color(0xFF059669), Color(0xFFD97706), Color(0xFF475569)]) {
      expect(contrast(dashReadableOnDark(c)), greaterThanOrEqualTo(4.5), reason: '$c');
    }
  });
}
