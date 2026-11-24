// Products & Services, round 2 finalization (2026-11-23): the approved decisions and the remaining defects, pinned.
// The backend's half of each rule is in integrity-backend test/ps_round2_final.test.js.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/services/line_items_api.dart';
import 'package:iohd_desktop/utils/line_item_math.dart';
import 'package:iohd_desktop/widgets/line_items_editor.dart';
import 'package:iohd_desktop/widgets/line_table_style.dart';

import 'dashboard_harness.dart';

Future<void> _pump(WidgetTester t, Widget editor, {Size size = const Size(1500, 1000)}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
      home: Scaffold(body: SingleChildScrollView(child: editor)),
    ),
  );
  await t.pumpAndSettle();
}

Future<List<CatalogEntry>> _noSearch(String q) async => const [];

LineItemsEditor _editor(List<LineDraft> lines, {ValueChanged<bool>? onDirty, int Function(int)? recordDiscounts, bool showCost = false}) => LineItemsEditor(
  lines: lines,
  taxRate: null,
  editable: true,
  showCost: showCost,
  onPreviewSave: () {},
  search: _noSearch,
  onDirtyChanged: onDirty,
  recordDiscounts: recordDiscounts,
);

/// The surface behind the line showing [name] (as text, or typed in its open name box).
Color? _shellColor(WidgetTester t, String name) {
  final w = t.widget<AnimatedContainer>(find.ancestor(of: find.text(name).first, matching: find.byKey(const ValueKey('line-shell'))).first);
  return (w.decoration as BoxDecoration?)?.color;
}

void main() {
  setUpAll(loadDashFonts);

  group('A1: Esc cancels what is typed in a box; Enter and Tab keep', () {
    testWidgets('Esc puts the box back as it was when it took the keyboard, closes the line, and leaves nothing changed', (t) async {
      final dirty = <bool>[];
      await _pump(t, _editor(const [LineDraft(name: 'Opener', rate: 689, quantity: 1)], onDirty: dirty.add));
      await t.tap(find.text('689.00'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('line-0-rate')), '750');
      await t.pump();
      expect(dirty.last, isTrue, reason: 'the typing changed the draft');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('line-0-rate')), findsNothing, reason: 'the line closed');
      expect(find.text('689.00'), findsOneWidget, reason: 'the rate it had when its box took the keyboard');
      expect(find.text(r'$750.00'), findsNothing);
      expect(dirty.last, isFalse, reason: 'nothing is left changed');
    });

    testWidgets('moving to another box keeps what was typed; Esc then undoes only the box being edited', (t) async {
      await _pump(t, _editor(const [LineDraft(name: 'Opener', rate: 689, quantity: 1)]));
      await t.tap(find.text('689.00'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('line-0-rate')), '750');
      await t.pump();
      await t.enterText(find.byKey(const ValueKey('line-0-name')), 'Opener XL'); // a click into the name box
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.text('Opener'), findsOneWidget, reason: 'the name typed is undone');
      expect(find.text('Opener XL'), findsNothing);
      expect(find.text('750.00'), findsOneWidget, reason: 'the rate was kept when the keyboard moved on');
    });

    testWidgets('reopened, Enter keeps the new figure and closes; Tab keeps it and moves on', (t) async {
      await _pump(t, _editor(const [LineDraft(name: 'Opener', rate: 689, quantity: 1)]));
      await t.tap(find.text('689.00'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('line-0-rate')), '750');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('line-0-rate')), findsNothing, reason: 'Enter closed the line');
      expect(find.text('750.00'), findsOneWidget);
      await t.tap(find.text('1.00'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('line-0-qty')), '2');
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('line-0-qty')), findsOneWidget, reason: 'Tab moves on within the line');
      await t.sendKeyEvent(LogicalKeyboardKey.escape); // Esc in the next box: nothing typed there to undo
      await t.pumpAndSettle();
      expect(find.text('2.00'), findsOneWidget, reason: 'Tab kept the quantity');
      expect(find.text('750.00'), findsOneWidget);
    });

    testWidgets('Esc on a half-typed figure puts the line back quietly (no "that wasn\'t a number" note)', (t) async {
      await _pump(t, _editor(const [LineDraft(name: 'Opener', rate: 689, quantity: 1)]));
      await t.tap(find.text('689.00'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('line-0-rate')), '12..5');
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.text('689.00'), findsOneWidget);
      expect(find.textContaining("that wasn't a number"), findsNothing);
      expect(find.byIcon(Icons.error_outline_rounded), findsNothing);
    });
  });

  group('A2: one row menu: Copy / Move up / Move down / Delete', () {
    testWidgets('the words, no dead item, and Move up / Move down move the line (not past either end)', (t) async {
      await _pump(t, _editor(const [LineDraft(name: 'Alpha', rate: 10), LineDraft(name: 'Bravo', rate: 20)]));
      await t.tap(find.byKey(const ValueKey('line-1-actions')));
      await t.pumpAndSettle();
      for (final w in ['Copy', 'Move up', 'Move down', 'Delete']) {
        expect(find.text(w), findsOneWidget, reason: w);
      }
      expect(find.text('Remove from group'), findsNothing, reason: 'a menu item that could never be used is gone');
      await t.tap(find.text('Move up'));
      await t.pumpAndSettle();
      expect(t.getTopLeft(find.text('Bravo')).dy, lessThan(t.getTopLeft(find.text('Alpha')).dy));
      // Now first: its Move up does nothing.
      await t.tap(find.byKey(const ValueKey('line-0-actions')));
      await t.pumpAndSettle();
      await t.tap(find.text('Move up'));
      await t.pumpAndSettle();
      expect(t.getTopLeft(find.text('Bravo')).dy, lessThan(t.getTopLeft(find.text('Alpha')).dy));
    });
  });

  group('A3: row hover', () {
    testWidgets('a line lights under the pointer; the open line keeps a deeper tint of its own', (t) async {
      await _pump(t, _editor(const [LineDraft(name: 'Alpha', rate: 10), LineDraft(name: 'Bravo', rate: 20)]));
      expect(_shellColor(t, 'Bravo'), Colors.white);
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(t.getCenter(find.text('Bravo')));
      await t.pumpAndSettle();
      expect(_shellColor(t, 'Bravo'), LineTable.rowHover);
      expect(_shellColor(t, 'Alpha'), Colors.white);
      await t.tap(find.text('Bravo'));
      await t.pumpAndSettle();
      expect(_shellColor(t, 'Bravo'), LineTable.rowActive, reason: 'open (and still under the pointer): the open tint, not the hover one');
      expect(LineTable.rowActive, isNot(LineTable.rowHover));
    });
  });

  group('A4: the inventory mark', () {
    testWidgets('services keep their "S"; an inventory item has a stock-box mark, no letter and nothing to click', (t) async {
      await _pump(t, _editor(const [LineDraft(name: 'Spring', rate: 89, service: false), LineDraft(name: 'Tune-Up', rate: 129, service: true)]));
      expect(find.descendant(of: find.byKey(const ValueKey('service-mark')), matching: find.text('S')), findsOneWidget);
      final item = find.byKey(const ValueKey('item-mark'));
      expect(item, findsOneWidget);
      expect(find.descendant(of: item, matching: find.byType(Text)), findsNothing, reason: 'no "I", which read as an information button');
      expect(find.descendant(of: item, matching: find.byIcon(Icons.inventory_2_outlined)), findsOneWidget);
      expect(find.ancestor(of: item, matching: find.byType(InkWell)), findsNothing, reason: 'not a button');
      expect(find.ancestor(of: item, matching: find.byWidgetPredicate((w) => w is Semantics && w.properties.label == 'Inventory item')), findsOneWidget);
    });
  });

  group('B1 in the editor', () {
    testWidgets('a 3% fee in the preview is worked out after the record\'s own \$100 discount: \$27', (t) async {
      await _pump(
        t,
        _editor(
          const [LineDraft(name: 'Door', rate: 1000, quantity: 1), LineDraft(name: 'Card fee', kind: LineKind.fee, percent: 3)],
          recordDiscounts: (items) => items == 100000 ? 10000 : 0,
        ),
      );
      expect(find.text(r'$27.00'), findsWidgets);
      expect(find.text(r'$30.00'), findsNothing);
    });
  });

  group('B7: which Service Fusion charges are a sales tax (the backend\'s sfChargeIsTax)', () {
    test('a charge named after its lines\' tax code is a tax, though it never says "tax" (prod job 1086732743)', () {
      final lines = [
        {'tax': 'AR-Carroll-Eureka Springs', 'total': 552.49},
        {'tax': null, 'total': 3600},
      ];
      final c = {'name': 'AR-Carroll-Eureka Springs', 'other_charge': 'AR-Carroll-Eureka Springs', 'is_discount': false, 'is_percentage': true, 'rate': 9.375};
      expect(sfChargeIsTax(c, lines), isTrue);
      expect(sfChargeTaxName(c, lines), 'AR-Carroll-Eureka Springs');
    });

    test('a renamed tax charge is found by its Service Fusion charge type, and named as its lines name it (prod job 1083198614)', () {
      final lines = [
        {'tax': '- Sales Tax Applied (Out Of State)'},
      ];
      final c = {'name': ' - Warranty', 'other_charge': '- Sales Tax Applied (Out Of State)', 'is_discount': false, 'is_percentage': true, 'rate': 9.5};
      expect(sfChargeIsTax(c, lines), isTrue);
      expect(sfChargeTaxName(c, lines), '- Sales Tax Applied (Out Of State)');
    });

    test('fees, adjustments and discounts are never taxes; a jurisdiction code and "Sales Tax (...)" are', () {
      expect(sfChargeIsTax({'name': 'Credit Card Convenience Fee - 3% discount for debit, ACH, check, or cash payment', 'is_discount': false}, const []), isFalse);
      expect(sfChargeIsTax({'name': 'Invoice Adjustment', 'other_charge': 'Invoice Adjustment', 'is_discount': false}, const []), isFalse);
      expect(sfChargeIsTax({'name': 'Sales Tax (State, County, & Local Use Tax, Rogers)', 'is_discount': true}, const []), isFalse);
      expect(sfChargeIsTax({'name': 'AR-Benton-Rogers', 'is_discount': false}, const []), isTrue);
      expect(sfChargeIsTax({'name': 'Sales Tax (State, County, & Local Use Tax, Rogers)', 'is_discount': false}, const []), isTrue);
    });
  });

  group('B1: a percentage fee follows the established base, items less every discount', () {
    test('3% on \$1,000 of items with Service Fusion\'s \$100 discount charge is \$27', () {
      final t = computeLineTotals(
        const [
          LineDraft(name: 'Door', rate: 1000, quantity: 1, cost: 400),
          LineDraft(name: 'Card fee', kind: LineKind.fee, percent: 3),
        ],
        null,
        outsideDiscountCents: 10000,
      );
      expect(t.feeCents, 2700);
      expect(t.lines[1].amountCents, 2700);
      expect(t.feeBaseCents, 90000);
    });

    test('without outside discounts the base is the draft\'s own items less its discounts, as before', () {
      final t = computeLineTotals(
        const [
          LineDraft(name: 'Door', rate: 1000, quantity: 1),
          LineDraft(name: 'Builder', kind: LineKind.discount, rate: 100),
          LineDraft(name: 'Card fee', kind: LineKind.fee, percent: 3),
        ],
        null,
      );
      expect(t.feeCents, 2700);
    });
  });

  group('B4: returns and sales on different taxes', () {
    const rogers = 'Sales Tax (State, County, & Local Use Tax, Rogers)';
    const bentonville = 'Sales Tax (State, County, & Local Use Tax, Bentonville)';

    test('a return on one tax offsets a sale on another: no tax is charged on \$0 of items', () {
      final t = computeLineTotals(
        const [
          LineDraft(name: 'Opener (returned)', rate: 100, quantity: -1, taxable: true, taxName: rogers),
          LineDraft(name: 'Opener', rate: 100, quantity: 1, taxable: true, taxName: bentonville),
        ],
        null,
        taxRates: {rogers: 9.5, bentonville: 9.5},
      );
      expect(t.itemsCents, 0);
      expect(t.taxCents, 0, reason: 'each tax floored on its own used to charge \$9.50 here');
      final by = {for (final f in t.taxes) f.name: f.taxCents};
      expect(by[rogers], -950, reason: 'the return gives back its own tax');
      expect(by[bentonville], 950);
    });

    test('tax is never below \$0 overall: a larger credit is cut back to what is charged, and the rows still add up', () {
      final t = computeLineTotals(
        const [
          LineDraft(name: 'Return', rate: 100, quantity: -1, taxable: true, taxName: rogers),
          LineDraft(name: 'Sale', rate: 100, quantity: 1, taxable: true, taxName: bentonville),
        ],
        null,
        taxRates: {rogers: 9.75, bentonville: 9.5},
      );
      expect(t.taxCents, 0, reason: 'never below \$0, as the server\'s one-rate rule');
      expect(t.taxes.fold<int>(0, (s, f) => s + f.taxCents), t.taxCents, reason: 'what the rows show adds up to the tax charged');
      expect({for (final f in t.taxes) f.name: f.taxCents}[rogers], -950);
    });

    test('one tax only: unchanged (a net return taxes nothing, as on the server)', () {
      final t = computeLineTotals(const [LineDraft(name: 'Return', rate: 100, quantity: -1, taxable: true)], 9.5);
      expect(t.taxCents, 0);
      expect(t.taxableCents, 0);
    });
  });

  group('decision 8: card processing fees are not profit', () {
    test('a card fee is charged and totalled but left out of profit and its margin; another fee still counts', () {
      final t = computeLineTotals(
        const [
          LineDraft(name: 'Door', rate: 1000, quantity: 1, cost: 600),
          LineDraft(name: 'Credit Card Convenience Fee - 3% discount for debit, ACH, check, or cash payment', kind: LineKind.fee, percent: 3),
          LineDraft(name: 'Trip charge', kind: LineKind.fee, rate: 50),
        ],
        null,
      );
      expect(t.feeCents, 8000, reason: 'the customer still pays both fees');
      expect(t.totalCents, 108000);
      expect(t.processingFeeCents, 3000);
      expect(t.profitCents, 45000, reason: '\$1,000 + \$50 trip charge - \$600 cost; the \$30 card fee goes to the processor');
      expect(t.marginPct, closeTo(42.9, 1e-9), reason: '450 / 1,050');
    });

    test('isCardProcessingFee knows the card fee by its words, not every fee', () {
      expect(isCardProcessingFee('Credit Card Convenience Fee - 3% discount for debit, ACH, check, or cash payment'), isTrue);
      expect(isCardProcessingFee('Card processing fee'), isTrue);
      expect(isCardProcessingFee('Monthly Late Invoice Interest Fee 3'), isFalse);
      expect(isCardProcessingFee('Trip charge'), isFalse);
      expect(isCardProcessingFee('Invoice Adjustment'), isFalse);
    });
  });
}
