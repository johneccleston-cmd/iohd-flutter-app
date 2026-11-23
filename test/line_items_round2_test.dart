// Round 2 of the Products & Services block (2026-11-13): the bugs the second bug hunt found, the block's own menus
// (keyboard, focus, rapid clicks, the window's edge) and the motion that has to stay out of the way.
//   flutter test test/line_items_round2_test.dart

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/utils/line_item_math.dart';
import 'package:iohd_desktop/widgets/line_items_editor.dart';
import 'package:iohd_desktop/widgets/ps_menu.dart';

Future<void> _pump(WidgetTester t, Widget editor, {Size size = const Size(1500, 1000), bool still = false}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MediaQuery(
      data: MediaQueryData(size: size, disableAnimations: still),
      child: MaterialApp(
        theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
        home: Scaffold(body: SingleChildScrollView(child: editor)),
      ),
    ),
  );
  await t.pumpAndSettle();
}

LineItemsEditor _editor(List<LineDraft> lines, {double? taxRate, bool editable = true}) =>
    LineItemsEditor(lines: lines, taxRate: taxRate, editable: editable, showCost: true, onPreviewSave: () {});

/// The primary focus's debug label ("line 1 name"), or null.
String? get _focused => FocusManager.instance.primaryFocus?.debugLabel;

void main() {
  group('bugs found in round 2', () {
    testWidgets('a tax rate outside 0 to 30% is marked and not charged; the last good rate stays', (t) async {
      // Since the Tax, discounts & fees redesign (2026-11-20) the set's own rate is changed in that panel, not in a
      // field in the totals: the same rule, the same keys.
      await _pump(t, _editor(const [LineDraft(name: 'Door', rate: 1000, quantity: 1, taxable: true)], taxRate: 10));
      expect(find.text(r'$100.00'), findsOneWidget, reason: '10% of \$1,000');
      Future<void> openOwnRate() async {
        await t.tap(find.text('Tax, discounts & fees'));
        await t.pumpAndSettle();
        await t.tap(find.byKey(const ValueKey('charge-choice-own')));
        await t.pumpAndSettle();
      }

      await openOwnRate();
      await t.enterText(find.byKey(const ValueKey('tax-rate')), '105');
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('tax-rate-invalid')), findsOneWidget, reason: 'the field is marked');
      expect(t.widget<FilledButton>(find.byKey(const ValueKey('save-own-rate'))).onPressed, isNull, reason: 'a 105% rate is not saved');
      await t.sendKeyEvent(LogicalKeyboardKey.escape); // back to the list
      await t.pumpAndSettle();
      await t.sendKeyEvent(LogicalKeyboardKey.escape); // closed
      await t.pumpAndSettle();
      expect(find.text(r'$1,050.00'), findsNothing, reason: 'a 105% tax was charged');
      expect(find.text(r'$100.00'), findsOneWidget, reason: 'the last good rate stays in the totals');

      await openOwnRate();
      await t.enterText(find.byKey(const ValueKey('tax-rate')), '8.25');
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('tax-rate-invalid')), findsNothing);
      await t.tap(find.byKey(const ValueKey('save-own-rate')));
      await t.pumpAndSettle();
      expect(find.text(r'$82.50'), findsOneWidget);

      await openOwnRate();
      await t.enterText(find.byKey(const ValueKey('tax-rate')), '');
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('tax-rate-invalid')), findsNothing, reason: 'empty is no tax, and fine');
      await t.tap(find.byKey(const ValueKey('save-own-rate')));
      await t.pumpAndSettle();
      expect(find.text(r'$82.50'), findsNothing);
      expect(find.text(r'$0.00'), findsWidgets, reason: 'no tax once the rate is gone');
    });

    testWidgets('a discount typed with a minus is the same discount, and reads the same when its line is reopened', (t) async {
      await _pump(
        t,
        _editor(const [
          LineDraft(name: 'Door', rate: 1000, quantity: 1),
          LineDraft(kind: LineKind.discount, name: 'Builder discount', rate: 50, quantity: 1),
        ]),
      );
      await t.tap(find.text('Builder discount'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('line-1-rate')), '-75');
      await t.pumpAndSettle();
      expect(find.text(r'$925.00'), findsWidgets);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      await t.tap(find.text('Builder discount'));
      await t.pumpAndSettle();
      final field = t.widget<TextField>(find.descendant(of: find.byKey(const ValueKey('line-1-rate')), matching: find.byType(TextField), matchRoot: true));
      expect(field.controller!.text, '75.00', reason: 'money off is kept as an amount, never a negative one');
    });

    testWidgets('the quantity arrows stop where the line\'s amount would pass the limit, open or closed, with no red mark', (t) async {
      // $999,999.99 x 10 = $9,999,999.90, just under the $9,999,999.99 a line may come to; one more would pass it.
      await _pump(t, _editor(const [LineDraft(name: 'Big job', rate: 999999.99, quantity: 10)]));
      await t.tap(find.byTooltip('One more'));
      await t.pumpAndSettle();
      expect(find.text('10.00'), findsOneWidget, reason: 'closed: nothing happened, and that is right');
      final semantics = t.ensureSemantics();
      expect(
        t.getSemantics(find.bySemanticsLabel('One more')),
        isSemantics(hasEnabledState: true, isEnabled: false),
        reason: 'so the arrow says it can\'t go up',
      );
      semantics.dispose();
      // Open, with the keyboard's Up and the arrow.
      await t.tap(find.text('Big job'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('line-0-qty')));
      await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('One more'));
      await t.pumpAndSettle();
      final field = t.widget<TextField>(find.descendant(of: find.byKey(const ValueKey('line-0-qty')), matching: find.byType(TextField), matchRoot: true));
      expect(field.controller!.text, '10.00');
      expect(find.byIcon(Icons.error_outline_rounded), findsNothing);
    });

    // Services Catalog Phase 2 (2026-11-18) changed this rule: the gross profit is only worked out while every line with a
    // quantity has a cost, money-off lines included (the shared formula, lineItemMath.js, and its cases: "half cents
    // round away from zero" has a -\$10 line with no cost and no profit). So these lines no longer drop out of the count;
    // the profit panel shows no profit and says how many lines have no cost.
    testWidgets('a money-off line with no cost (Service Fusion\'s "10% Discount" item at -\$0.10) leaves the profit unknown too', (t) async {
      await _pump(
        t,
        _editor(const [
          LineDraft(name: 'Door', rate: 1000, cost: 400, quantity: 1),
          LineDraft(name: '10% Discount (Doors & Openers)', rate: -0.1, quantity: 35125.3),
          LineDraft(name: 'Return: opener', rate: 389, quantity: -1),
        ], editable: false),
      );
      expect(find.text('2 lines have no cost'), findsOneWidget);
      expect(find.byKey(const ValueKey('gross-profit-unknown')), findsOneWidget);
      await _pump(
        t,
        _editor(const [
          LineDraft(name: 'Door', rate: 1000, cost: 400, quantity: 1),
          LineDraft(name: 'Keyless Entry Pad', rate: 79, quantity: 1),
        ], editable: false),
      );
      expect(find.text('1 line has no cost'), findsOneWidget, reason: 'a priced item with no cost counts');
      expect(find.byKey(const ValueKey('gross-profit-unknown')), findsOneWidget);
      await _pump(
        t,
        _editor(const [
          LineDraft(name: 'Door', rate: 1000, cost: 400, quantity: 1),
          LineDraft(name: 'Return: opener', rate: 389, cost: 210, quantity: -1),
        ], editable: false),
      );
      expect(find.textContaining('no cost'), findsNothing, reason: 'every cost known');
      expect(find.byKey(const ValueKey('gross-profit-unknown')), findsNothing);
    });

    testWidgets('a line just added keeps its fields when its highlight ends (focus stayed where it was put)', (t) async {
      await _pump(
        t,
        LineItemsEditor(
          lines: const [LineDraft(name: 'Door', rate: 900, quantity: 1)],
          taxRate: null,
          editable: true,
          showCost: true,
          onPreviewSave: () {},
          search: (q) async => const [],
        ),
      );
      final search = find.byWidgetPredicate((w) => w is TextField && (w.decoration?.hintText ?? '').startsWith('Add a line'));
      await t.enterText(search, 'Gate repair');
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();
      await t.tap(find.textContaining('Add a custom line'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(_focused, 'line 2 rate', reason: 'a custom line opens on its price');
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(_focused, 'line 2 cost');
      await t.enterText(find.byKey(const ValueKey('line-1-cost')), '40');
      // The new line's highlight ends at 1.4 s: before round 2 that rebuilt the line, put focus back on its price and
      // selected it all, so the next key typed there replaced the price.
      await t.pump(const Duration(milliseconds: 1600));
      await t.pumpAndSettle();
      expect(_focused, 'line 2 cost', reason: 'focus is where it was');
      final cost = t.widget<TextField>(find.descendant(of: find.byKey(const ValueKey('line-1-cost')), matching: find.byType(TextField), matchRoot: true));
      expect(cost.controller!.selection.isCollapsed, isTrue, reason: 'nothing was selected behind the typist\'s back');
    });

    testWidgets('a line dragged by its grip moves (each line keeps one key of its own, even while dragged)', (t) async {
      await _pump(
        t,
        _editor(const [
          LineDraft(name: 'Door', rate: 900, quantity: 1),
          LineDraft(name: 'Opener', rate: 600, quantity: 1),
          LineDraft(name: 'Install', rate: 300, quantity: 1),
        ]),
      );
      final g = await t.startGesture(t.getCenter(find.byIcon(Icons.drag_indicator_rounded).first), kind: PointerDeviceKind.mouse);
      for (var i = 0; i < 8; i++) {
        await g.moveBy(const Offset(0, 10));
        await t.pump(const Duration(milliseconds: 16));
      }
      expect(t.takeException(), isNull, reason: 'mid-drag');
      await g.up();
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(t.getTopLeft(find.text('Opener')).dy, lessThan(t.getTopLeft(find.text('Door')).dy), reason: 'the door went below the opener');
    });

    testWidgets('Alt+Down moves the open line and keeps it open, its field still focused', (t) async {
      await _pump(
        t,
        _editor(const [
          LineDraft(name: 'Door', rate: 900, quantity: 1),
          LineDraft(name: 'Opener', rate: 600, quantity: 1),
          LineDraft(name: 'Install', rate: 300, quantity: 1),
        ]),
      );
      await t.tap(find.text('Door'));
      await t.pumpAndSettle();
      expect(_focused, 'line 1 name');
      for (var i = 0; i < 2; i++) {
        await t.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await t.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
        await t.pumpAndSettle();
      }
      expect(_focused, 'line 1 name', reason: 'the moved line kept its focus, so a second Alt+Down moved it again');
      final ys = ['Opener', 'Install'].map((n) => t.getTopLeft(find.text(n)).dy).toList();
      final door = t.getTopLeft(find.byKey(const ValueKey('line-2-name'))).dy;
      expect(door, greaterThan(ys.last), reason: 'the door went to the bottom');
    });
  });

  group('the block\'s menus', () {
    const lines = [
      LineDraft(name: 'Door', rate: 1000, quantity: 1, taxable: true),
      LineDraft(name: 'Opener', rate: 600, quantity: 1, taxable: true),
    ];

    testWidgets('keyboard: the arrows move, Enter picks, Esc closes, and focus comes back to the select', (t) async {
      await _pump(t, _editor(lines, taxRate: 10));
      await t.tap(find.text('Taxable 10%').first);
      await t.pumpAndSettle();
      expect(find.text('No tax'), findsOneWidget, reason: 'the menu is open');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.text('No tax'), findsNothing, reason: 'Esc closed it');
      final select = _focused;
      expect(select, 'line value', reason: 'focus came back to the select');
      // Open from the keyboard, Down twice (the current choice, then the next), Enter.
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      expect(find.text('No tax'), findsOneWidget, reason: 'the door is now No tax');
      expect(find.text(r'$60.00'), findsOneWidget, reason: 'tax on the opener alone');
      expect(_focused, select);
    });

    testWidgets('a double click opens one menu, and a click outside closes it', (t) async {
      await _pump(t, _editor(lines, taxRate: 10));
      final cell = find.text('Taxable 10%').first;
      await t.tap(cell);
      await t.pump(const Duration(milliseconds: 40));
      await t.tap(cell, warnIfMissed: false); // lands on the menu's barrier: closes it, never opens a second
      await t.pumpAndSettle();
      expect(find.byType(PsMenuButton<String>), findsWidgets);
      expect(find.text('No tax'), findsNothing);
      await t.tap(cell);
      await t.pumpAndSettle();
      expect(find.text('No tax'), findsOneWidget);
      await t.tapAt(const Offset(5, 5));
      await t.pumpAndSettle();
      expect(find.text('No tax'), findsNothing);
    });

    testWidgets('it opens over its trigger near the bottom edge of the window, and stays inside it', (t) async {
      // Ten lines in a short window, the last one's select scrolled to the window's bottom edge.
      final many = [for (var i = 0; i < 10; i++) LineDraft(name: 'Part $i', rate: 10.0 + i, quantity: 1, taxable: true)];
      await _pump(t, _editor(many, taxRate: 10), size: const Size(1500, 420));
      final cell = find.text('Taxable 10%').last;
      await Scrollable.ensureVisible(t.element(cell), alignment: 1);
      await t.pumpAndSettle();
      final trigger = t.getRect(cell);
      expect(trigger.bottom, greaterThan(420 - 60), reason: 'the select is at the bottom edge');
      await t.tap(cell);
      await t.pumpAndSettle();
      final menu = t.getRect(find.text('No tax').last);
      expect(menu.bottom, lessThan(trigger.top), reason: 'over the trigger: there is no room under it');
      expect(menu.bottom, lessThanOrEqualTo(420 - 8));
      expect(t.getRect(find.text('Taxable').last).top, greaterThanOrEqualTo(8));
    });

    testWidgets('the motion: quick in (part-way at 48 ms, there by ${kPsMenuOpen.inMilliseconds} ms), quicker out', (t) async {
      await _pump(t, _editor(lines, taxRate: 10));
      await t.tap(find.text('Taxable 10%').first);
      await t.pump(); // the first frame
      FadeTransition fade() => t.widget<FadeTransition>(find.ancestor(of: find.text('No tax'), matching: find.byType(FadeTransition)).first);
      await t.pump(const Duration(milliseconds: 48));
      expect(fade().opacity.value, inExclusiveRange(0.2, 1), reason: 'on its way in, not popped');
      await t.pump(kPsMenuOpen - const Duration(milliseconds: 48));
      expect(fade().opacity.value, 1, reason: 'fully there');
      await t.pump(const Duration(milliseconds: 16)); // (the route's own clock starts a frame late)
      expect((fade().opacity as CurvedAnimation).parent.status, AnimationStatus.completed);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      await t.pump(const Duration(milliseconds: 40));
      expect(fade().opacity.value, lessThan(0.75), reason: 'the fade leads the close');
      await t.pump(kPsMenuClose - const Duration(milliseconds: 40));
      await t.pump(const Duration(milliseconds: 16)); // (a ticker's first frame is its start)
      expect(find.text('No tax'), findsNothing, reason: 'closed within ${kPsMenuClose.inMilliseconds} ms and a frame');
    });

    testWidgets('a close that starts while the menu is still opening reverses from where it is, without a jump', (t) async {
      await _pump(t, _editor(lines, taxRate: 10));
      await t.tap(find.text('Taxable 10%').first);
      await t.pump();
      await t.pump(const Duration(milliseconds: 40));
      Matrix4 transform() => t.widget<Transform>(find.ancestor(of: find.text('No tax'), matching: find.byType(Transform)).last).transform;
      final before = transform().getMaxScaleOnAxis();
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      final after = transform().getMaxScaleOnAxis();
      expect((after - before).abs(), lessThan(0.01), reason: 'the scale carries on from where it was');
      await t.pumpAndSettle();
      expect(find.text('No tax'), findsNothing);
    });

    testWidgets('reduce motion: the menu is there on the first frame', (t) async {
      await _pump(t, _editor(lines, taxRate: 10), still: true);
      await t.tap(find.text('Taxable 10%').first);
      await t.pump();
      await t.pump();
      expect(find.text('No tax'), findsOneWidget);
      final fade = t.widget<FadeTransition>(find.ancestor(of: find.text('No tax'), matching: find.byType(FadeTransition)).first);
      expect(fade.opacity.value, 1);
    });
  });
}
