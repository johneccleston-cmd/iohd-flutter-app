// The line-item formula (lib/utils/line_item_math.dart) against the same cases the backend's copy is tested with
// (scripts/line_item_math_cases.json in integrity-backend; keep test/fixtures/line_item_math_cases.json identical).
//   flutter test test/line_item_math_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/utils/line_item_math.dart';

double? _d(dynamic v) => v == null ? null : (v as num).toDouble();

void main() {
  final cases = (jsonDecode(File('test/fixtures/line_item_math_cases.json').readAsStringSync())['cases'] as List).cast<Map>();

  for (final c in cases) {
    test(c['name'], () {
      final lines = [
        for (final i in (c['items'] as List).cast<Map>())
          LineDraft(
            kind: i['kind'] == 'discount' ? LineKind.discount : LineKind.item,
            name: 'line',
            quantity: _d(i['quantity']) ?? 1,
            rate: _d(i['rate']),
            cost: _d(i['cost']),
            taxable: i['taxable'] == true,
            zeroPriceConfirmed: i['zeroPriceConfirmed'] == true,
          ),
      ];
      final t = computeLineTotals(lines, _d(c['taxRate']));
      final e = (c['expect'] as Map).cast<String, dynamic>();
      expect(t.itemsCents, e['itemsCents'], reason: 'items');
      expect(t.discountCents, e['discountCents'], reason: 'discounts');
      expect(t.taxableCents, e['taxableCents'], reason: 'taxable');
      expect(t.taxCents, e['taxCents'], reason: 'tax');
      expect(t.totalCents, e['totalCents'], reason: 'total');
      expect(t.costCents, e['costCents'], reason: 'cost');
      // Null while a line's cost is unknown (Services Catalog Phase 2).
      expect(t.profitCents, e['profitCents'], reason: 'profit');
      expect(t.marginPct, e['marginPct'] == null ? isNull : closeTo((e['marginPct'] as num).toDouble(), 1e-9), reason: 'margin');
      expect(t.unpricedLines, e['unpricedLines'], reason: 'unpriced');
      expect(t.missingCostLines, e['missingCostLines'], reason: 'missing cost');
      expect(t.zeroUnconfirmedLines, e['zeroUnconfirmedLines'], reason: '\$0 lines not confirmed');
    });
  }

  test('every case says how many \$0 lines are unconfirmed, as the backend\'s copy does', () {
    for (final c in cases) {
      expect((c['expect'] as Map).containsKey('zeroUnconfirmedLines'), isTrue, reason: c['name'].toString());
    }
  });

  group('\$0.00 lines', () {
    test('a \$0 line is an item at \$0.00 with a quantity; quantity 0, unpriced and discounts are not', () {
      expect(const LineDraft(name: 'a', quantity: 1, rate: 0).isZeroPrice, isTrue);
      expect(const LineDraft(name: 'a', quantity: -1, rate: 0.004).isZeroPrice, isTrue, reason: 'rounds to \$0.00');
      expect(const LineDraft(name: 'a', quantity: 0, rate: 0).isZeroPrice, isFalse);
      expect(const LineDraft(name: 'a', quantity: 1).isZeroPrice, isFalse, reason: 'not priced yet');
      expect(const LineDraft(name: 'a', quantity: 1, rate: 0.01).isZeroPrice, isFalse);
      expect(const LineDraft(name: 'a', kind: LineKind.discount, rate: 0).isZeroPrice, isFalse);
    });

    test('a confirmation comes off when the name, quantity or price changes, and stays otherwise', () {
      final confirmed = const LineDraft(name: 'Haul away', quantity: 1, rate: 0).copyWith(zeroPriceConfirmed: true, zeroPriceConfirmedBy: 'Dana');
      expect(confirmed.zeroPriceConfirmed, isTrue);
      expect(confirmed.zeroPriceConfirmedBy, 'Dana');
      expect(confirmed.zeroUnconfirmed, isFalse);
      for (final kept in [
        confirmed.copyWith(taxable: true),
        confirmed.copyWith(description: 'Old door to the dump'),
        confirmed.copyWith(customerVisible: false),
        confirmed.copyWith(cost: 25),
        confirmed.copyWith(id: null),
        confirmed.copyWith(quantity: 1, rate: 0, name: ' Haul away '),
      ]) {
        expect(kept.zeroPriceConfirmed, isTrue);
        expect(kept.zeroPriceConfirmedBy, 'Dana');
      }
      for (final changed in [confirmed.copyWith(name: 'Haul away (2)'), confirmed.copyWith(quantity: 2), confirmed.copyWith(rate: 10), confirmed.copyWith(rate: null)]) {
        expect(changed.zeroPriceConfirmed, isFalse);
        expect(changed.zeroPriceConfirmedBy, isNull);
      }
      expect(confirmed.copyWith(zeroPriceConfirmed: false).zeroPriceConfirmedBy, isNull);
    });

    test('from the server: confirmed when it recorded who or when; sent back as zeroPriceConfirmed with the line id', () {
      final saved = LineDraft.fromJson({'id': '41', 'name': 'Haul away', 'quantity': 1, 'rate': '0.00', 'zeroPriceConfirmedBy': 'Dana Whitfield', 'zeroPriceConfirmedAt': '2026-11-18T15:00:00Z'});
      expect(saved.zeroPriceConfirmed, isTrue);
      expect(saved.zeroPriceConfirmedBy, 'Dana Whitfield');
      expect(saved.zeroPriceConfirmedAt, DateTime.utc(2026, 11, 18, 15));
      expect(saved.toJson()['zeroPriceConfirmed'], isTrue);
      expect(saved.toJson()['id'], '41');
      final open = LineDraft.fromJson({'name': 'Haul away', 'quantity': 1, 'rate': 0, 'zeroPriceConfirmedBy': null, 'zeroPriceConfirmedAt': null});
      expect(open.zeroPriceConfirmed, isFalse);
      expect(open.toJson()['zeroPriceConfirmed'], isFalse);
      expect(open.toJson().containsKey('id'), isFalse);
      expect(LineDraft.fromJson({'name': 'old server', 'quantity': 1, 'rate': 0}).zeroPriceConfirmed, isFalse);
      expect(saved.sameAs(open), isFalse, reason: 'a confirmation is a change');
      expect(computeLineTotals([saved, open], null).zeroUnconfirmedLines, 1);
    });
  });

  test('profit and margin are unknown while a line has no cost; never 100% on uncosted lines', () {
    final t = computeLineTotals(const [LineDraft(name: 'Install', quantity: 1, rate: 300), LineDraft(name: 'Door', quantity: 1, rate: 700, cost: 400)], null);
    expect(t.missingCostLines, 1);
    expect(t.costCents, 40000, reason: 'the known costs');
    expect(t.profitCents, isNull);
    expect(t.marginPct, isNull);
    final costed = computeLineTotals(const [LineDraft(name: 'Install', quantity: 1, rate: 300, cost: 0), LineDraft(name: 'Door', quantity: 1, rate: 700, cost: 400)], null);
    expect(costed.profitCents, 60000, reason: 'a cost of \$0 entered on our own line is a cost');
    expect(costed.marginPct, 60);
  });

  test('per-line figures line up with the lines', () {
    final t = computeLineTotals(const [
      LineDraft(name: 'a', quantity: 2, rate: 4.46, cost: 4.46),
      LineDraft(name: 'b', kind: LineKind.discount, rate: 10),
      LineDraft(name: 'c', quantity: 1, rate: null),
    ], null);
    expect(t.lines.map((l) => l.amountCents), [892, -1000, 0]);
    expect(t.lines.map((l) => l.extCostCents), [892, null, null]);
  });

  test('formatting and parsing', () {
    expect(centsMoney(123456789), r'$1,234,567.89');
    expect(centsMoney(-3000), r'-$30.00');
    expect(centsMoney(5), r'$0.05');
    expect(parseMoney(r'$1,250.5'), 1250.5);
    expect(parseMoney('89.999'), 90.0);
    expect(parseMoney('-10'), -10.0);
    expect(parseMoney(''), isNull);
    expect(parseMoney('abc'), isNull);
    expect(parseQty('2.1255'), 2.126);
    expect(parseQty('x'), isNull);
  });

  // User rule 2026-11-13: a quantity always shows two decimals, everywhere it is shown.
  group('quantity display', () {
    test('always two decimals', () {
      expect(qtyText(1), '1.00');
      expect(qtyText(2), '2.00');
      expect(qtyText(1.5), '1.50');
      expect(qtyText(0.25), '0.25');
      expect(qtyText(10), '10.00');
      expect(qtyText(0), '0.00');
    });

    test('large quantities are grouped like money (Service Fusion has 2,400 screws and 35,125.3 on prod)', () {
      expect(qtyText(2400), '2,400.00');
      expect(qtyText(35125.3), '35,125.30');
      expect(qtyText(9999.99), '9,999.99');
      expect(qtyText(1234567), '1,234,567.00');
    });

    test('no floating-point slips: worked in whole thousandths, never toStringAsFixed on the double', () {
      expect(qtyText(0.1 + 0.2), '0.30'); // 0.30000000000000004
      expect(qtyText(1.15), '1.15'); // 1.15 is 1.149999... in binary
      expect(qtyText(68.57), '68.57');
      expect(qtyText(-2), '-2.00');
      expect(qtyText(-0.5), '-0.50');
    });

    test('a third decimal the value really has is kept, so the figure never misstates the amount', () {
      // The server stores thousandths (NUMERIC(12,3)); none on prod have a third decimal (checked 2026-11-13), and the
      // editor no longer lets one be typed, but one that arrives is shown, not rounded away.
      expect(qtyText(2.125), '2.125');
      expect(qtyText(1.005), '1.005');
    });

    test('what is shown parses back to the same value', () {
      for (final q in [0.0, 0.25, 1.0, 1.5, 2.125, 68.57, 2400.0, 9999.99, 35125.3]) {
        expect(parseQty(qtyText(q)), q, reason: qtyText(q));
      }
    });
  });

  test('a line keeps its catalog price and cost when edited, and "unsaved" ignores ids', () {
    const added = LineDraft(name: 'Torsion Spring', quantity: 1, rate: 89, cost: 19.5, catalogRate: 89, catalogCost: 19.5, catalogKey: 'inv:7', source: 'catalog');
    final edited = added.copyWith(quantity: 2, rate: 95);
    expect(edited.catalogRate, 89);
    expect(edited.catalogCost, 19.5);
    expect(edited.rate, 95);
    expect(edited.copyWith(rate: null).rate, isNull, reason: 'a rate can be cleared');
    expect(added.copyWith(id: '12').sameAs(added), isTrue);
    expect(edited.sameAs(added), isFalse);
    final json = edited.toJson();
    expect(json['catalogRate'], 89);
    expect(json['quantity'], 2);
    expect(const LineDraft(name: 'd', kind: LineKind.discount, rate: 5, quantity: 3).toJson()['quantity'], 1);
  });
}
