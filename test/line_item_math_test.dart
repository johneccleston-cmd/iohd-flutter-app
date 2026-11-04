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
      expect(t.profitCents, e['profitCents'], reason: 'profit');
      expect(t.marginPct, e['marginPct'] == null ? isNull : closeTo((e['marginPct'] as num).toDouble(), 1e-9), reason: 'margin');
      expect(t.unpricedLines, e['unpricedLines'], reason: 'unpriced');
      expect(t.missingCostLines, e['missingCostLines'], reason: 'missing cost');
    });
  }

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
    expect(qtyText(2), '2');
    expect(qtyText(1.5), '1.5');
    expect(qtyText(2.125), '2.125');
    expect(parseMoney(r'$1,250.5'), 1250.5);
    expect(parseMoney('89.999'), 90.0);
    expect(parseMoney('-10'), -10.0);
    expect(parseMoney(''), isNull);
    expect(parseMoney('abc'), isNull);
    expect(parseQty('2.1255'), 2.126);
    expect(parseQty('x'), isNull);
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
