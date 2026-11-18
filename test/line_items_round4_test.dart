// Round 4 of the Products & Services block (2026-11-13): the estimate's options as tabs on the table, negative
// quantities through the whole life of a line, the tax column with real long names, quieter quantity-0 lines and eyes.
//   flutter test test/line_items_round4_test.dart
//
// 1. Negative, zero, fractional and large quantities: shown, parsed, loaded, copied and sent with their sign, and the
//    money worked from them (amount, cost, tax, discounts) keeps the right sign.
// 2. The option tabs stand on the table: no gap, the open one joined to it, lined up with its first column, one baseline.
// 3. More options than fit: "+N more", the open one always shown.
// 4. A changed option's tab follows its draft's total.
// 5. A long tax name ("Springdale, Washington", the commonest on prod) in two lines, never cut short.
// 6. A line at quantity 0 reads quieter; the eye is quiet in both states and has no box at rest.
// 7. Switching options fades the table in (not with reduce motion).

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/utils/line_item_math.dart';
import 'package:iohd_desktop/widgets/dashboard_kit.dart' show DashUi;
import 'package:iohd_desktop/widgets/line_items_editor.dart';

import 'job_page_fixture.dart';

Map<String, dynamic> _l(String name, {double qty = 1, double? rate, double? cost, bool taxable = true, String sku = ''}) => {
  'kind': 'item',
  'name': name,
  'description': '',
  'sku': sku,
  'quantity': qty,
  'rate': rate,
  'cost': cost,
  'taxable': taxable,
  'source': 'catalog',
};

const _longTax = 'Sales Tax (State, County, & Local Use Tax, Springdale, Washington)';

/// Service Fusion's estimate with the long tax name on its taxed lines, a return and a catalog entry at 0. Its total
/// still adds up, so the tax is worked out from it (10.5%).
void _sfEstimate(FakeJobServer s) {
  final job = s.records[kEstimateId]!['job'] as Map<String, dynamic>;
  final items = [for (final it in job['raw_items'] as List) Map<String, dynamic>.from(it as Map)];
  for (final it in items) {
    if (it['tax'] != null) it['tax'] = _longTax;
  }
  items.addAll([
    {'item_index': 7, 'name': "Return | Stop Mold | 16' Sandtone", 'product': 'Return', 'multiplier': -1, 'rate': 10.2, 'total': -10.2, 'cost': -10.2, 'tax': _longTax},
    {'item_index': 9, 'name': 'Keypad | LiftMaster 877MAX (optional)', 'product': 'Keypad', 'multiplier': 0, 'rate': 59, 'total': 0, 'cost': 0, 'tax': _longTax},
  ]);
  job['raw_items'] = items;
  // 850.00 - 10.20 = 839.80 of items; 539.80 taxed at 10.5% = 56.68.
  job['total_revenue'] = '896.48';
  job['due_total'] = '896.48';
}

void _seed(FakeJobServer s, {int extra = 0}) {
  s.addOption(kEstimateId, 'Builder grade', [_l("Weather Seal | Stop Mold | 7' Sandtone", qty: 2, rate: 4.46, cost: 4.46)], taxRate: 10.5);
  s.addOption(
    kEstimateId,
    'Insulated',
    [
      _l('Clopay | Classic Steel | 4300 | Complete Door | Almond', rate: 1489, cost: 912.4, sku: 'CL-4300-1607'),
      _l('Return | Torsion Spring | 0.207 x 1.75" x 30"', qty: -1, rate: 89, cost: 19.5),
      _l('Keypad | LiftMaster 877MAX (optional)', qty: 0, rate: 59, cost: 31.2),
    ],
    taxRate: 10.5,
    recommended: true,
  );
  for (var i = 0; i < extra; i++) {
    s.addOption(kEstimateId, 'Alternative number ${i + 1} with a longer name', [_l('Spring Replacement | Labor', rate: 150, taxable: false)], taxRate: 10.5);
  }
}

Future<void> _toBlock(WidgetTester t) async {
  await t.ensureVisible(find.text('Products & Services'));
  await settle(t, frames: 6);
}

Future<void> _edit(WidgetTester t) async {
  await t.tap(find.text('Edit Estimate'));
  await settle(t, frames: 8);
  await _toBlock(t);
}

Finder _tab(String id) => find.byKey(ValueKey('option-tab-$id'));
Finder get _editor => find.byType(LineItemsEditor); // the one on show (hidden ones are offstage)
Finder _inTable(Finder f) => find.descendant(of: _editor, matching: f);

/// The colour a Text (plain or rich) is drawn in.
Color? _colorOf(WidgetTester t, Finder text) {
  final w = t.widget<Text>(text);
  return w.style?.color ?? w.textSpan?.style?.color;
}

void main() {
  group('1. negative, zero, fractional and large quantities', () {
    test('shown with two decimals and their sign; a real third decimal kept', () {
      expect(qtyText(0), '0.00');
      expect(qtyText(-0.5), '-0.50');
      expect(qtyText(-1), '-1.00');
      expect(qtyText(2.5), '2.50');
      expect(qtyText(-36), '-36.00');
      expect(qtyText(1234.5), '1,234.50');
      expect(qtyText(-999999.999), '-999,999.999');
      expect(qtyText(999999.99), '999,999.99');
      expect(qtyText(-0.001), '-0.001');
    });

    test('parsed as typed, sign and all, never clamped', () {
      expect(parseQty('-1'), -1);
      expect(parseQty('-1,234.50'), -1234.5);
      expect(parseQty(' -0.25 '), -0.25);
      expect(parseQty('0'), 0);
      expect(parseQty('-999,999.999'), -999999.999);
      expect(parseQty('1,000,000'), 1000000, reason: 'parsed as it is; the limit is checked where it is typed (marked, not clamped)');
    });

    test('loaded, copied and sent with the sign: the server\'s NUMERIC text, a duplicate, the PUT body', () {
      for (final q in ['-1.000', '0.000', '2.500', '-0.250', '-999999.999', '999999.999']) {
        final l = LineDraft.fromJson({'name': 'x', 'quantity': q, 'rate': '89.00', 'cost': '19.50', 'taxable': true});
        expect(l.quantity, double.parse(q), reason: 'loaded $q');
        expect(l.toJson()['quantity'], double.parse(q), reason: 'sent $q');
        final copy = l.copyWith(id: null);
        expect(copy.quantity, l.quantity, reason: 'Copy keeps $q');
        expect(LineDraft.fromJson(l.toJson()).sameAs(l), isTrue, reason: '$q round-trips');
      }
      expect(LineDraft.fromJson({'name': 'x', 'quantity': 0}).quantity, 0, reason: '0 is a quantity, not "missing" (that is 1)');
      expect(LineDraft.fromJson({'name': 'x'}).quantity, 1);
    });

    test('a return: its amount and its cost both come off; the unit cost stays positive', () {
      const lines = [
        LineDraft(name: 'Torsion Spring', quantity: 2, rate: 89, cost: 19.5, taxable: true),
        LineDraft(name: 'Return | Torsion Spring', quantity: -1, rate: 89, cost: 19.5, taxable: true),
      ];
      final t = computeLineTotals(lines, 10);
      expect(t.lines[1].amountCents, -8900);
      expect(t.lines[1].extCostCents, -1950, reason: '-1 x \$19.50: the cost comes back with the part, not doubled');
      expect(t.itemsCents, 8900);
      expect(t.costCents, 1950);
      expect(t.profitCents, 6950);
      expect(t.taxCents, 890, reason: 'tax on the net taxed amount, \$89.00');
      expect(t.totalCents, 9790);
      expect(t.missingCostLines, 0);
    });

    test('a negative quantity at a negative rate is a positive amount (reversing a credit)', () {
      final t = computeLineTotals(const [LineDraft(name: 'Reverse credit', quantity: -1, rate: -50, cost: null)], null);
      expect(t.lines.single.amountCents, 5000);
      expect(t.itemsCents, 5000);
    });

    test('fractional negatives round half away from zero, as the server does', () {
      final t = computeLineTotals(const [LineDraft(name: 'Chain', quantity: -2.5, rate: 12.34, cost: 3.33)], null);
      expect(t.lines.single.amountCents, -3085);
      expect(t.lines.single.extCostCents, -833, reason: '-2.5 x 3.33 = -8.325, half away from zero');
    });

    test('tax: a taxed return lowers it; it never goes below 0', () {
      final mixed = computeLineTotals(const [
        LineDraft(name: 'Door', quantity: 1, rate: 100, taxable: true),
        LineDraft(name: 'Return', quantity: -1, rate: 30, taxable: true),
      ], 10);
      expect(mixed.taxCents, 700);
      final onlyReturns = computeLineTotals(const [LineDraft(name: 'Return', quantity: -3, rate: 30, taxable: true)], 10);
      expect(onlyReturns.taxCents, 0, reason: 'no negative tax');
      expect(onlyReturns.totalCents, -9000, reason: 'a credit note: the total itself can be negative');
    });

    test('a discount beside a return comes off what is left', () {
      final t = computeLineTotals(const [
        LineDraft(name: 'Door', quantity: 1, rate: 100, taxable: true),
        LineDraft(name: 'Return', quantity: -1, rate: 30, taxable: true),
        LineDraft(kind: LineKind.discount, name: 'Discount', quantity: 1, rate: 10, taxable: true),
      ], 10);
      expect(t.itemsCents, 7000);
      expect(t.discountCents, 1000);
      expect(t.netCents, 6000);
      expect(t.taxCents, 600, reason: '10% of (100 - 30 - 10)');
    });

    test('the limits are the server\'s, either way (LIMITS in lineItemMath.js), not the old 9,999.999', () {
      expect(kMaxLineQuantity, 999999.999);
      expect(lineAmountFits(-999999.999, 0.01), isTrue);
      expect(lineAmountFits(-909090, -11), isTrue);
      expect(lineAmountFits(-909091, 11), isFalse);
      expect(lineAmountFits(-909091, -11), isFalse, reason: 'the size of the amount counts, not its sign');
      final big = computeLineTotals(const [LineDraft(name: 'Washers', quantity: 999999.999, rate: 0.01)], null);
      expect(big.lines.single.amountCents, 1000000);
    });
  });

  group('page', () {
    setUpAll(jobPageSetUp);

    testWidgets('2. the tabs stand on the table: no gap, the open one joined to it, on its edge and one baseline', (t) async {
      final s = FakeJobServer();
      _sfEstimate(s);
      _seed(s);
      await pumpJobPage(t, s, id: kEstimateId, size: const Size(1366, 1600), body: () async {
        await _toBlock(t);
        final ids = [for (final o in s.optionsOf(kEstimateId)) o.id];
        final open = _tab(ids[1]); // Insulated: recommended, so it opens first
        final shut = _tab(ids[0]);
        expect(open, findsOneWidget);
        expect(t.widget<Semantics>(find.descendant(of: open, matching: find.byType(Semantics)).first).properties.selected, isTrue);
        // The table starts where the tabs end: the column headings right under them.
        final strip = t.getRect(open);
        expect(t.getRect(_editor).top, moreOrLessEquals(strip.bottom, epsilon: 0.01), reason: 'no gap, no header row between');
        // The open tab's surface reaches the strip's foot (it covers the rule there); the others stop 1 px above it,
        // on the rule, and stand lower.
        Rect surface(Finder tab) => t.getRect(find.descendant(of: tab, matching: find.byType(CustomPaint)).first);
        expect(surface(open).bottom, moreOrLessEquals(strip.bottom, epsilon: 0.01));
        expect(surface(shut).bottom, moreOrLessEquals(strip.bottom - 1, epsilon: 0.01));
        expect(surface(shut).top, greaterThan(surface(open).top), reason: 'the open one stands higher');
        // The first tab starts on the table's edge (where the eye column starts).
        final eye = t.getRect(_inTable(find.byKey(const ValueKey('col-eye'))).first);
        expect(t.getRect(_tab('sf')).left, moreOrLessEquals(eye.left, epsilon: 0.01));
        // Every tab's name on one line, the open one's included.
        final a = t.getTopLeft(find.descendant(of: open, matching: find.text('Insulated'))).dy;
        final b = t.getTopLeft(find.descendant(of: shut, matching: find.text('Builder grade'))).dy;
        expect(a, moreOrLessEquals(b, epsilon: 0.01));
        // No header row: the old option header (name, Recommended badge, "Saved by") is gone; the star is on the tab.
        expect(find.text('Recommended'), findsNothing);
        expect(find.descendant(of: open, matching: find.byIcon(Icons.star_rounded)), findsOneWidget);
        expect(find.textContaining('Saved'), findsNothing);
        // Accept and the option menu sit at the strip's end, on the tabs' line.
        final accept = t.getRect(find.text('Accept'));
        expect(accept.center.dy, inInclusiveRange(strip.top, strip.bottom));
        expect(t.getRect(find.byKey(const ValueKey('option-actions'))).center.dy, inInclusiveRange(strip.top, strip.bottom));
        // Switching: the other option's lines and totals, the tab now open, the strip unmoved.
        await t.tap(shut);
        await settle(t, frames: 4);
        expect(find.text("Weather Seal | Stop Mold | 7' Sandtone"), findsOneWidget);
        expect(_inTable(find.text('Clopay | Classic Steel | 4300 | Complete Door | Almond')), findsNothing);
        expect(t.getRect(_editor).top, moreOrLessEquals(strip.bottom, epsilon: 0.01));
        expect(surface(shut).bottom, moreOrLessEquals(strip.bottom, epsilon: 0.01));
      });
    });

    testWidgets('2b. where an option stands heads its menu (it used to be a line over the table)', (t) async {
      final s = FakeJobServer();
      _seed(s);
      await pumpJobPage(t, s, id: kEstimateId, size: const Size(1366, 1600), body: () async {
        await _toBlock(t);
        await t.tap(find.byKey(const ValueKey('option-actions')));
        await settle(t, frames: 4);
        expect(find.textContaining('Saved'), findsOneWidget);
        expect(find.text('Rename'), findsOneWidget);
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(t, frames: 4);
      });
    });

    testWidgets('2c. a narrow block keeps only the menu at the strip\'s end, with Accept in it', (t) async {
      final s = FakeJobServer();
      _seed(s);
      await pumpJobPage(t, s, id: kEstimateId, size: const Size(600, 2400), body: () async {
        await _toBlock(t);
        expect(find.widgetWithText(OutlinedButton, 'Accept'), findsNothing);
        await t.tap(find.byKey(const ValueKey('option-actions')));
        await settle(t, frames: 4);
        expect(find.text('Accept'), findsOneWidget, reason: 'in the menu');
        await t.tap(find.text('Accept'));
        await settle(t, frames: 4);
        expect(find.textContaining('Accept Insulated for'), findsOneWidget, reason: 'the same confirmation as the button');
        await t.tap(find.text('Cancel'));
        await settle(t, frames: 4);
      });
    });

    testWidgets('3. more options than fit: "+N more" at the end, the open one always shown, any one a click away', (t) async {
      final s = FakeJobServer();
      _sfEstimate(s);
      _seed(s, extra: 6);
      await pumpJobPage(t, s, id: kEstimateId, size: const Size(1280, 1600), body: () async {
        await _toBlock(t);
        final more = find.byKey(const ValueKey('option-tab-more'));
        expect(more, findsOneWidget);
        final ids = [for (final o in s.optionsOf(kEstimateId)) o.id];
        expect(_tab(ids[1]), findsOneWidget, reason: 'the open one');
        final hidden = [for (final id in ids) if (_tab(id).evaluate().isEmpty) id];
        expect(hidden, isNotEmpty);
        expect(find.descendant(of: more, matching: find.text('+${hidden.length} more')), findsOneWidget);
        // Nothing runs past the strip: the tabs end before Accept.
        expect(t.getRect(more).right, lessThan(t.getRect(find.text('Accept')).left));
        // Open the last one from the menu: it is shown (in place of others), open, with its lines.
        await t.tap(more);
        await settle(t, frames: 4);
        final last = s.optionsOf(kEstimateId).last;
        await t.tap(find.text(last.name).last);
        await settle(t, frames: 6);
        expect(_tab(last.id), findsOneWidget);
        expect(t.widget<Semantics>(find.descendant(of: _tab(last.id), matching: find.byType(Semantics)).first).properties.selected, isTrue);
        expect(_inTable(find.text('Spring Replacement | Labor')), findsOneWidget);
        expect(_tab('sf'), findsOneWidget, reason: 'the estimate\'s own stays first');
      });
    });

    testWidgets('4. a changed option\'s tab follows its draft, and goes back with Exit preview', (t) async {
      final s = FakeJobServer();
      _seed(s);
      await pumpJobPage(t, s, id: kEstimateId, size: const Size(1500, 1600), body: () async {
        await _toBlock(t);
        final open = _tab(s.optionsOf(kEstimateId)[1].id);
        final saved = s.optionsOf(kEstimateId)[1];
        final was = t.widget<Text>(find.descendant(of: open, matching: find.textContaining(r'$')).first).data!;
        await _edit(t);
        // One more door: the tab's total follows the table's.
        await t.tap(_inTable(find.text('1.00')).first);
        await settle(t, frames: 3);
        await t.enterText(find.byKey(const ValueKey('line-0-qty')), '2');
        await settle(t, frames: 4);
        final total = t.widget<Text>(find.descendant(of: open, matching: find.textContaining(r'$')).first).data!;
        expect(total, isNot(was));
        expect(total, r'$3,192.35', reason: '2 doors, the return and the keypad at 0: \$2,889.00 + 10.5% tax');
        expect(_inTable(find.text(total)), findsWidgets, reason: 'the tab and the summary agree');
        await t.tap(find.text('Exit preview'));
        await settle(t, frames: 6);
        expect(t.widget<Text>(find.descendant(of: open, matching: find.textContaining(r'$')).first).data, was);
        expect(saved.items.first['quantity'], 1, reason: 'nothing saved');
      });
    });

    testWidgets('5. a long tax name in two lines, never cut short; the full name for screen readers; the box keeps the rate', (t) async {
      final s = FakeJobServer();
      _sfEstimate(s);
      await pumpJobPage(t, s, id: kEstimateId, size: const Size(1366, 1600), body: () async {
        await _toBlock(t);
        expect(_inTable(find.text('Springdale, Washington 10.5%')), findsNothing, reason: 'too long for one line of its column');
        expect(_inTable(find.text('Springdale')), findsWidgets);
        expect(_inTable(find.text('Washington · 10.5%')), findsWidgets);
        for (final text in ['Springdale', 'Washington · 10.5%']) {
          for (final e in _inTable(find.text(text)).evaluate()) {
            final para = t.renderObject<RenderParagraph>(find.descendant(of: find.byWidget(e.widget), matching: find.byType(RichText)).first);
            expect(para.didExceedMaxLines, isFalse, reason: '"$text" drawn whole');
          }
        }
        expect(find.bySemanticsLabel(RegExp(r'^Tax: Sales Tax \(State, County, & Local Use Tax, Springdale, Washington\), 10\.5%$')), findsWidgets);
        // Rows stay one even height, the tax's second line inside it (a line with no tax and no SKU included).
        Finder row(String name) => find.ancestor(
          of: _inTable(find.text(name)),
          matching: find.byWidgetPredicate((w) => w is Semantics && (w.properties.label?.startsWith('Line ') ?? false)),
        );
        final hs = [for (final n in ['SMH Installation | Gallery Steel | 16x7 | Sandtone', "Stop Mold | 16' Sandtone"]) t.getRect(row(n).first).height];
        expect(hs[0], moreOrLessEquals(hs[1], epsilon: 0.5));
        // Editing: the select's box keeps the place and the rate; its menu has the place in full.
        await _edit(t);
        expect(_inTable(find.text('Springdale 10.5%')), findsWidgets);
        await t.tap(_inTable(find.text('Springdale 10.5%')).first);
        await settle(t, frames: 4);
        expect(find.text('Springdale, Washington'), findsOneWidget, reason: 'the menu');
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(t, frames: 4);
      });
    });

    testWidgets('6. a line at quantity 0 reads quieter but plain; returns keep ink; the eyes are quiet with no box at rest', (t) async {
      final s = FakeJobServer();
      _seed(s);
      await pumpJobPage(t, s, id: kEstimateId, size: const Size(1500, 1600), body: () async {
        await _toBlock(t);
        final zero = _inTable(find.text('Keypad | LiftMaster 877MAX (optional)'));
        final ret = _inTable(find.text('Return | Torsion Spring | 0.207 x 1.75" x 30"'));
        expect(_colorOf(t, zero), DashUi.slate);
        expect(_colorOf(t, ret), DashUi.ink, reason: 'a return is a real line');
        expect(_colorOf(t, _inTable(find.text('0.00'))), DashUi.slate);
        expect(_colorOf(t, _inTable(find.text('-1.00'))), DashUi.ink);
        expect(_inTable(find.text(r'-$89.00')), findsOneWidget, reason: 'the return\'s amount, red, with its sign');
        // The "|" in a name is drawn lighter than its words; its text is the name exactly.
        final span = t.widget<Text>(ret).textSpan! as TextSpan;
        expect(span.toPlainText(), 'Return | Torsion Spring | 0.207 x 1.75" x 30"');
        expect(span.children!.whereType<TextSpan>().where((c) => c.text == '|').every((c) => c.style?.color == DashUi.muted), isTrue);
        // Eyes: shown and hidden differ by glyph, neither is ink at rest.
        final eyes = _inTable(find.byIcon(Icons.visibility_outlined));
        expect(eyes, findsWidgets);
        for (final e in eyes.evaluate()) {
          expect((e.widget as Icon).color, isNot(DashUi.ink));
          expect((e.widget as Icon).size, lessThanOrEqualTo(15));
        }
        await _edit(t);
        // While editing the eye is a control with no outline until the pointer or the keyboard comes to it.
        final toggle = find.byWidgetPredicate((w) => w is Semantics && w.properties.label == 'Show to the customer');
        expect(toggle, findsNWidgets(3), reason: 'one per line');
        final box = t.widget<AnimatedContainer>(find.descendant(of: toggle.first, matching: find.byType(AnimatedContainer)).first);
        final border = (box.decoration! as BoxDecoration).border! as Border;
        expect(border.top.color.a, 0, reason: 'no box at rest');
        // A typed return stays a return: closed, it reads -2.50; the amount follows.
        await t.tap(_inTable(find.text('1.00')).first);
        await settle(t, frames: 3);
        await t.enterText(find.byKey(const ValueKey('line-0-qty')), '-2.5');
        await settle(t, frames: 3);
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(t, frames: 4);
        expect(_inTable(find.text('-2.50')), findsOneWidget);
        expect(_inTable(find.text(r'-$3,722.50')), findsOneWidget);
        // Copy keeps it.
        await t.tap(find.byKey(const ValueKey('line-0-actions')));
        await settle(t, frames: 4);
        await t.tap(find.text('Copy'));
        await settle(t, frames: 6);
        expect(_inTable(find.text('-2.50')), findsNWidgets(2));
      });
    });

    testWidgets('7. switching options fades the table in; with reduce motion it is there at once', (t) async {
      for (final still in [false, true]) {
        final s = FakeJobServer();
        _seed(s);
        await pumpJobPage(t, s, id: kEstimateId, size: const Size(1500, 1600), reduceMotion: still, body: () async {
          await _toBlock(t);
          await t.tap(_tab(s.optionsOf(kEstimateId)[0].id));
          await t.pump();
          await t.pump(const Duration(milliseconds: 40));
          final fade = t.widget<Opacity>(find.ancestor(of: _editor, matching: find.byType(Opacity)).first);
          if (still) {
            expect(fade.opacity, 1);
          } else {
            expect(fade.opacity, inExclusiveRange(0.3, 1.0), reason: 'part way in');
          }
          await settle(t, frames: 3);
          expect(t.widget<Opacity>(find.ancestor(of: _editor, matching: find.byType(Opacity)).first).opacity, 1);
        });
      }
    });
  });
}
