// The summary under the lines (USER RULES 2026-11-24): every discount, fee and tax is its own line of the table, under
// a rule below the products and services; the summary has them as one "Taxes, fees & discounts" figure, first, with no
// subtotal; then the total and, on a job, a green Payments/Deposits line and the balance due.
//   flutter test test/line_items_summary_payments_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/utils/line_item_math.dart';
import 'package:iohd_desktop/widgets/dashboard_kit.dart';
import 'package:iohd_desktop/widgets/line_items_editor.dart';

Future<void> _pump(WidgetTester t, Widget editor) async {
  const size = Size(1500, 1200);
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MediaQuery(
      data: const MediaQueryData(size: size),
      child: MaterialApp(
        theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
        home: Scaffold(body: SingleChildScrollView(child: editor)),
      ),
    ),
  );
  await t.pumpAndSettle();
}

// Door $1,000 (taxed 10%: $100), a $100 discount between the door and the opener, opener $500, a $50 trip charge.
// Taxes, fees & discounts: 100 - 100 + 50 = $50; total $1,550.
const _lines = [
  LineDraft(name: 'Door', rate: 1000, quantity: 1, taxable: true),
  LineDraft(name: 'Loyal customer discount', rate: 100, quantity: 1, kind: LineKind.discount),
  LineDraft(name: 'Opener', rate: 500, quantity: 1),
  LineDraft(name: 'Trip charge', rate: 50, quantity: 1, kind: LineKind.fee),
];

LineItemsEditor _editor({int? paid, bool editable = false}) => LineItemsEditor(
  lines: _lines,
  taxRate: 10,
  editable: editable,
  showCost: false,
  totalLabel: 'Job total',
  paidCents: paid,
  onPreviewSave: () {},
);

double _top(WidgetTester t, String text) => t.getTopLeft(find.text(text).first).dy;

void main() {
  testWidgets('products and services, a rule, then the discounts, fees and taxes; the summary in one figure', (t) async {
    await _pump(t, _editor(paid: 50000));
    final rule = t.getTopLeft(find.byKey(const ValueKey('charges-rule'))).dy;
    // The opener comes before the discount, which was between it and the door: each part keeps its own order.
    expect(_top(t, 'Door'), lessThan(_top(t, 'Opener')));
    expect(_top(t, 'Opener'), lessThan(rule));
    expect(rule, lessThan(_top(t, 'Loyal customer discount')));
    expect(_top(t, 'Loyal customer discount'), lessThan(_top(t, 'Trip charge')));
    // The tax is a line of the table too, under the discounts and fees, and above the summary.
    expect(_top(t, 'Trip charge'), lessThan(_top(t, 'Sales tax')));
    expect(_top(t, 'Sales tax'), lessThan(_top(t, 'Taxes, fees & discounts')));
    expect(find.text('Sales tax'), findsOneWidget, reason: 'listed once, in the table');
    expect(find.text(r'$100.00'), findsOneWidget, reason: 'the tax: its line only, the summary has the combined figure');

    // The summary: no Items, Discounts, Fees or Subtotal lines.
    for (final gone in ['Items', 'Subtotal', 'Discounts', 'Fees']) {
      expect(find.text(gone), findsNothing, reason: gone);
    }
    expect(find.text(r'$50.00'), findsNWidgets(2), reason: 'the trip charge, and Taxes, fees & discounts (100 - 100 + 50)');
    expect(_top(t, 'Taxes, fees & discounts'), lessThan(_top(t, 'Job total')));
    expect(find.text(r'$1,550.00'), findsOneWidget);

    // Payments/Deposits, green, then the balance due: a mini block of its own to the right of the main one.
    double left(String s) => t.getTopLeft(find.text(s).first).dx;
    expect(left('Payments/Deposits'), greaterThan(t.getTopRight(find.text(r'$1,550.00')).dx), reason: 'right of the main block');
    expect(_top(t, 'Payments/Deposits'), lessThan(_top(t, 'Job total')), reason: 'level with the top of the main block');
    expect(_top(t, 'Payments/Deposits'), lessThan(_top(t, 'Balance due')));
    expect(left('Balance due'), left('Payments/Deposits'));
    expect(t.widget<Text>(find.text('Payments/Deposits')).style?.color, DashUi.emeraldText);
    expect(t.widget<Text>(find.text(r'-$500.00')).style?.color, DashUi.emeraldText);
    expect(find.text(r'$1,050.00'), findsOneWidget, reason: r'$1,550 less $500 paid');
    // Only Payments/Deposits (green) and Balance due (red) are coloured; the rest is black (user 2026-11-24).
    // Balance due reads red, the name and the amount (user 2026-11-24).
    for (final s in ['Balance due', r'$1,050.00']) {
      expect(t.widget<Text>(find.text(s).last).style?.color, DashUi.redText, reason: s);
    }
    for (final s in ['Taxes, fees & discounts', 'Job total', r'$1,550.00']) {
      expect(t.widget<Text>(find.text(s).last).style?.color, DashUi.ink, reason: s);
    }
  });

  testWidgets('the gross profit is filled in while a line has no cost, on the known costs', (t) async {
    await _pump(
      t,
      const LineItemsEditor(
        lines: [LineDraft(name: 'Door', rate: 1000, cost: 400, quantity: 1), LineDraft(name: 'Keypad', rate: 100, quantity: 1)],
        taxRate: null,
        editable: false,
        showCost: true,
      ),
    );
    // $1,100 less the door's $400 (the keypad has no cost): $700, 63.6%, in black.
    expect(find.text(r'$700.00'), findsOneWidget);
    expect(find.text('(63.6%)'), findsOneWidget);
    expect(t.widget<Text>(find.text(r'$700.00')).style?.color, DashUi.ink);
    expect(find.byKey(const ValueKey('gross-profit-unknown')), findsNothing);
  });

  testWidgets('the profit, the total (middle) and the payments (furthest right) are mini blocks in one row', (t) async {
    await _pump(
      t,
      const LineItemsEditor(
        lines: [LineDraft(name: 'Door', rate: 1000, cost: 400, quantity: 1)],
        taxRate: null,
        editable: false,
        showCost: true,
        totalLabel: 'Job total',
        paidCents: 50000,
      ),
    );
    double left(String s) => t.getTopLeft(find.text(s).first).dx;
    double top(String s) => _top(t, s);
    // The profit on the left, the total in the middle, the payments furthest right (user 2026-11-24).
    expect(left('Job cost'), lessThan(left('Job total')));
    expect(left('Job total'), lessThan(left('Payments/Deposits')));
    expect(top('Taxes, fees & discounts'), top('Payments/Deposits'));
    expect(top('Payments/Deposits'), top('Job cost'));
  });

  testWidgets('an estimate (no payments) ends at its total', (t) async {
    await _pump(t, _editor());
    expect(find.text('Taxes, fees & discounts'), findsOneWidget);
    expect(find.text('Payments/Deposits'), findsNothing);
    expect(find.text('Balance due'), findsNothing);
  });

  testWidgets('while editing, a line moves only within its part', (t) async {
    await _pump(t, _editor(paid: 0, editable: true));
    final rule = t.getTopLeft(find.byKey(const ValueKey('charges-rule'))).dy;
    expect(_top(t, 'Opener'), lessThan(rule));
    expect(rule, lessThan(_top(t, 'Loyal customer discount')));
    // The opener is the last product: Move down is a no-op, it never goes under the rule.
    await t.tap(find.bySemanticsLabel('Line 2 actions'));
    await t.pumpAndSettle();
    await t.tap(find.text('Move down'));
    await t.pumpAndSettle();
    expect(_top(t, 'Opener'), lessThan(t.getTopLeft(find.byKey(const ValueKey('charges-rule'))).dy));
    expect(find.text('Changed, not saved'), findsNothing);
  });
}
