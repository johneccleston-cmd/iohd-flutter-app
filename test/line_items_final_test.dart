// Final polish of the Products & Services block (2026-11-13), checked in real Chrome as well (build/ps_final):
//   flutter test test/line_items_final_test.dart
//
// 1. The open tab carries an ink cap on its top edge; the others have none.
// 2. Under the pointer an inactive tab goes a step DARKER with a firmer edge (it used to go lighter, toward the open
//    tab's white, so a hovered tab read as the open one); its width never changes.
// 3. A lone tab (an estimate with only Service Fusion's option, every estimate on prod today) has the cap too.
// 4. More options than fit: no tab that would fit is left in "+N more" (up to ~190 px stood empty before Accept at
//    1280); the strip still ends before Accept and the open one is shown whole.
// 5. A line's ⋮ has no outline at rest while editing; the ink outline is there while its menu is open.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/widgets/dashboard_kit.dart' show DashUi;

import 'job_page_fixture.dart';

Map<String, dynamic> _l(String name, {double qty = 1, double? rate, double? cost, bool taxable = true}) => {
  'kind': 'item',
  'name': name,
  'description': '',
  'sku': '',
  'quantity': qty,
  'rate': rate,
  'cost': cost,
  'taxable': taxable,
  'source': 'catalog',
};

void _seed(FakeJobServer s, {int extra = 0}) {
  s.addOption(kEstimateId, 'Builder grade', [_l("Weather Seal | Stop Mold | 7' Sandtone", qty: 2, rate: 4.46, cost: 4.46)], taxRate: 10.5);
  s.addOption(
    kEstimateId,
    'Insulated',
    [
      _l('Clopay | Classic Steel | 4300 | Complete Door | Almond', rate: 1489, cost: 912.4),
      _l('Return | Torsion Spring | 0.207 x 1.75" x 30"', qty: -1, rate: 89, cost: 19.5),
    ],
    taxRate: 10.5,
    recommended: true,
  );
  const names = ['Premium carriage house with full-view windows', 'Repair only', 'Good', 'Better', 'Best (insulated steel, 3-layer)', 'Opener swap'];
  for (var i = 0; i < extra; i++) {
    // With a cost, so each tab shows its margin (Services Catalog Phase 2 leaves the margin off while a line has no
    // cost, which made these tabs narrow enough that all of them fit at 1920 and nothing went into "+N more").
    s.addOption(kEstimateId, names[i % names.length], [_l('Spring Replacement | Labor', rate: 150 + i * 25.5, cost: 60, taxable: false)], taxRate: 10.5);
  }
}

Future<void> _toBlock(WidgetTester t) async {
  await t.ensureVisible(find.text('Products & Services'));
  await settle(t, frames: 6);
}

Finder _tab(String id) => find.byKey(ValueKey('option-tab-$id'));

/// The painter of a tab's surface (its first CustomPaint): fill, edge and cap.
dynamic _painter(WidgetTester t, Finder tab) => t.widget<CustomPaint>(find.descendant(of: tab, matching: find.byType(CustomPaint)).first).painter;

double _lum(Color c) => c.computeLuminance();

void main() {
  setUpAll(jobPageSetUp);

  testWidgets('1-2. the open tab has the ink cap; a hovered tab goes darker, not toward white, and keeps its width', (t) async {
    final s = FakeJobServer();
    _seed(s);
    await pumpJobPage(t, s, id: kEstimateId, size: const Size(1366, 1600), body: () async {
      await _toBlock(t);
      final ids = [for (final o in s.optionsOf(kEstimateId)) o.id];
      final open = _tab(ids[1]), shut = _tab(ids[0]);
      expect(_painter(t, open).cap, 1.0);
      expect(_painter(t, shut).cap, 0.0);
      final restFill = _painter(t, shut).fill as Color, restEdge = _painter(t, shut).edge as Color;
      final width = t.getSize(shut).width;
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(t.getCenter(shut));
      await settle(t, frames: 4);
      final hoverFill = _painter(t, shut).fill as Color, hoverEdge = _painter(t, shut).edge as Color;
      expect(_lum(hoverFill), lessThan(_lum(restFill)), reason: 'darker under the pointer');
      expect(_lum(hoverFill), lessThan(_lum(Colors.white)));
      expect(_lum(hoverEdge), lessThan(_lum(restEdge)), reason: 'a firmer edge');
      expect(_painter(t, shut).cap, 0.0, reason: 'only the open tab has the cap');
      expect(t.getSize(shut).width, width, reason: 'no width change on hover');
      // Its name turns ink, never blue.
      final name = t.widget<Text>(find.descendant(of: shut, matching: find.text('Builder grade')));
      expect(name.style?.color, DashUi.ink);
      await mouse.moveTo(const Offset(2, 2));
      await settle(t, frames: 4);
      expect(_painter(t, shut).fill, restFill);
    });
    // As desktop (and the browser): on Android, the tests' default, Flutter keeps hover highlights off.
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('3. a lone tab (only Service Fusion\'s option) has the cap too', (t) async {
    final s = FakeJobServer();
    await pumpJobPage(t, s, id: kEstimateId, size: const Size(1366, 1600), body: () async {
      await _toBlock(t);
      expect(_tab('sf'), findsOneWidget);
      expect(_painter(t, _tab('sf')).cap, 1.0);
    });
  });

  for (final width in [1280.0, 1366.0, 1920.0]) {
    testWidgets('4. ${width.toInt()} wide: no tab that would fit is left in "+N more"', (t) async {
      final s = FakeJobServer();
      _seed(s, extra: 9);
      await pumpJobPage(t, s, id: kEstimateId, size: Size(width, 1600), body: () async {
        await _toBlock(t);
        final more = find.byKey(const ValueKey('option-tab-more'));
        expect(more, findsOneWidget);
        final accept = t.getRect(find.text('Accept'));
        final end = t.getRect(more).right;
        expect(end, lessThan(accept.left), reason: 'the strip ends before Accept');
        // Every tab is at least 112 wide plus a 4 px gap: a gap that size or more would mean one was left out. The
        // 12 px before the actions and the button's own padding are not room for tabs.
        expect(accept.left - end, lessThan(112 + 4 + 12 + 16), reason: 'no tab-sized gap before Accept');
        final ids = [for (final o in s.optionsOf(kEstimateId)) o.id];
        final open = t.widget<Text>(find.descendant(of: _tab(ids[1]), matching: find.text('Insulated')));
        expect(open.overflow, TextOverflow.ellipsis);
        final rendered = t.renderObject<RenderParagraph>(find.descendant(of: _tab(ids[1]), matching: find.text('Insulated')));
        expect(rendered.didExceedMaxLines, isFalse, reason: 'the open one is never cut');
      });
    });
  }

  testWidgets('5. a line\'s ⋮ has no outline at rest while editing, the ink outline while its menu is open', (t) async {
    final s = FakeJobServer();
    _seed(s);
    await pumpJobPage(t, s, id: kEstimateId, size: const Size(1500, 1600), body: () async {
      await _toBlock(t);
      await t.tap(find.text('Edit Estimate'));
      await settle(t, frames: 8);
      await _toBlock(t);
      final button = find.byKey(const ValueKey('line-0-actions'));
      Border border() => (t.widget<AnimatedContainer>(find.descendant(of: button, matching: find.byType(AnimatedContainer)).first).decoration! as BoxDecoration).border! as Border;
      expect(border().top.color.a, 0, reason: 'no box at rest');
      await t.tap(button);
      await settle(t, frames: 6);
      expect(find.text('Copy'), findsOneWidget);
      expect(border().top.color, DashUi.ink, reason: 'outlined while its menu is open');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(t, frames: 6);
    });
  });
}
