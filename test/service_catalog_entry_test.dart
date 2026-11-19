// A Services Catalog entry as the job / estimate picker reads it (Services Catalog Phase 2, 2026-11-18): every new field
// from the server (CONTRACT §1), an older server that sends none of them, and the line a pick becomes. A service's line
// takes the catalog's price only once it is settled (never $0), its cost only when known, no unit, and tax only when its
// billed lines were all taxed. Products are untouched.
//   flutter test test/service_catalog_entry_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/services/line_items_api.dart';
import 'package:iohd_desktop/utils/line_item_math.dart';

/// A service as GET /api/catalog/search sends it (src/serviceCatalog.js pickerEntry).
Map<String, dynamic> _service({String status = 'settled', double? rate = 285, double? cost = 96, String? tax = 'taxed', Map<String, dynamic> extra = const {}}) => {
  'key': 'sfr:4471',
  'name': 'Torsion Spring Replacement',
  'sku': null,
  'category': 'Residential Service',
  'kind': 'service',
  'inventoryItemId': null,
  'stock': null,
  'cost': cost,
  'costSource': cost == null ? null : 'service_fusion',
  'rate': rate,
  'rateUses': 14,
  'rateMin': 249,
  'rateMax': 325,
  'uses': 14,
  'lastUsed': '2026-11-10',
  'taxable': tax == 'taxed',
  'description': 'Two springs, balance and adjust',
  'group': 'Residential Service',
  'aliases': ['Spring Replacement', 'Torsion Springs (pair)'],
  'priceStatus': status,
  'medianPrice': 285,
  'lastBilled': {'date': '2026-11-10', 'price': 289},
  'quoteMedian': 299,
  'quoteCount': 6,
  'taxDefault': tax,
  'taxWarning': tax == 'mixed' ? 'Taxed on 9 of 14 billed jobs. Check the tax on this line.' : null,
  'rateId': '4471',
  'variantOf': null,
  'variants': [
    {'key': 'sfr:4471~torsion-spring-replacement-commercial', 'name': 'Torsion Spring Replacement - Commercial'},
  ],
  'recentPrices': [
    {'date': '2026-11-10', 'price': 289},
    {'date': '2026-11-02', 'price': 285},
    {'date': '2026-10-20', 'price': 279},
  ],
  'recentChange': null,
  ...extra,
};

void main() {
  group('fromJson', () {
    test('reads every Phase 2 field', () {
      final e = CatalogEntry.fromJson(
        _service(
          status: 'recent_change',
          rate: null,
          tax: 'mixed',
          extra: {
            'variantOf': {'key': 'sfr:9', 'name': 'Service Call'},
            'recentChange': {
              'median': 89,
              'prices': [
                {'date': '2026-11-12', 'price': 129},
                {'date': '2026-11-05', 'price': 125},
                {'date': '2026-10-30', 'price': 119},
              ],
              'direction': 'up',
              'since': '2026-10-30',
              'threshold': 0.05,
              'warning': 'Recent price change: the last 3 billed prices are each more than 5% from the 18-month median of \$89.00.',
            },
          },
        ),
      );
      expect(e.isService, isTrue);
      expect(e.priceStatus, 'recent_change');
      expect(e.rate, isNull);
      expect(e.medianPrice, 285);
      expect(e.lastBilled, (date: '2026-11-10', price: 289.0));
      expect(e.recentPrices.map((p) => p.price), [289, 285, 279]);
      expect(e.recentPrices.first.date, '2026-11-10');
      final c = e.recentChange!;
      expect(c.median, 89);
      expect(c.prices.map((p) => p.price), [129, 125, 119]);
      expect(c.direction, 'up');
      expect(c.since, '2026-10-30');
      expect(c.warning, startsWith('Recent price change'));
      expect(e.quoteMedian, 299);
      expect(e.quoteCount, 6);
      expect(e.taxDefault, 'mixed');
      expect(e.taxable, isFalse, reason: 'taxable only for taxed');
      expect(e.taxWarning, 'Taxed on 9 of 14 billed jobs. Check the tax on this line.');
      expect(e.group, 'Residential Service');
      expect(e.category, 'Residential Service');
      expect(e.aliases, ['Spring Replacement', 'Torsion Springs (pair)']);
      expect(e.rateId, '4471');
      expect(e.variantOf, (key: 'sfr:9', name: 'Service Call'));
      expect(e.variants, [(key: 'sfr:4471~torsion-spring-replacement-commercial', name: 'Torsion Spring Replacement - Commercial')]);
      expect(e.sku, '', reason: 'a null SKU reads as none');
    });

    test('an older server that sends none of them: empty, and nothing breaks', () {
      final e = CatalogEntry.fromJson({
        'key': 'sf:service call',
        'name': 'Service Call',
        'kind': 'service',
        'category': 'Service',
        'rate': 89,
        'rateMin': 69,
        'rateMax': 129,
        'uses': 412,
        'taxable': true,
      });
      expect(e.priceStatus, isNull);
      expect(e.medianPrice, isNull);
      expect(e.lastBilled, isNull);
      expect(e.recentPrices, isEmpty);
      expect(e.recentChange, isNull);
      expect(e.quoteMedian, isNull);
      expect(e.quoteCount, 0);
      expect(e.taxDefault, isNull);
      expect(e.taxWarning, isNull);
      expect(e.group, 'Service', reason: 'the group is the category');
      expect(e.aliases, isEmpty);
      expect(e.rateId, isNull);
      expect(e.variantOf, isNull);
      expect(e.variants, isEmpty);
      // Its line is what it always was: the usual price, the old taxable flag.
      final line = e.toLine();
      expect(line.rate, 89);
      expect(line.taxable, isTrue);
    });

    test('odd values are dropped, not thrown on', () {
      final e = CatalogEntry.fromJson(
        _service(
          extra: {
            'lastBilled': {'date': '2026-11-10'},
            'recentPrices': [
              {'date': '2026-11-10'},
              'x',
              {'date': '2026-11-01', 'price': 280},
            ],
            'recentChange': {'prices': []},
            'variantOf': 'sfr:9',
            'variants': [
              {'name': 'no key'},
              null,
            ],
            'aliases': ['', null, 'Springs'],
            'taxWarning': '  ',
          },
        ),
      );
      expect(e.lastBilled, isNull);
      expect(e.recentPrices.map((p) => p.price), [280]);
      expect(e.recentChange, isNull);
      expect(e.variantOf, isNull);
      expect(e.variants, isEmpty);
      expect(e.aliases, ['Springs']);
      expect(e.taxWarning, isNull);
    });

    test('withChange keeps the Phase 2 fields', () {
      final e = CatalogEntry.fromJson(_service(status: 'single', rate: null, tax: 'mixed')).withChange(category: 'Other');
      expect(e.category, 'Other');
      expect(e.priceStatus, 'single');
      expect(e.taxDefault, 'mixed');
      expect(e.lastBilled?.price, 289);
      expect(e.recentPrices, hasLength(3));
      expect(e.variants, hasLength(1));
      expect(e.rateId, '4471');
    });
  });

  group('a service becomes a line', () {
    test('settled: its price is filled in, and kept as what the catalog said', () {
      final l = CatalogEntry.fromJson(_service()).toLine();
      expect(l.name, 'Torsion Spring Replacement');
      expect(l.quantity, 1);
      expect(l.rate, 285);
      expect(l.catalogRate, 285);
      expect(l.cost, 96);
      expect(l.catalogCost, 96);
      expect(l.catalogKey, 'sfr:4471');
      expect(l.unit, '');
      expect(l.source, 'catalog');
      expect(l.taxable, isTrue);
      expect(l.zeroPriceConfirmed, isFalse);
    });

    for (final status in ['recent_change', 'varies', 'single', 'quote_only', 'none']) {
      test('$status: no price filled in (never \$0), even if one were sent', () {
        final l = CatalogEntry.fromJson(_service(status: status, rate: 285)).toLine();
        expect(l.rate, isNull);
        expect(l.catalogRate, isNull);
        expect(l.isZeroPrice, isFalse);
        expect(computeLineTotals([l], null).unpricedLines, 1);
      });
    }

    test('a rate of \$0 is never filled in: the line starts unpriced, not as a silent no-charge line', () {
      final l = CatalogEntry.fromJson(_service(rate: 0)).toLine();
      expect(l.rate, isNull);
      expect(l.catalogRate, isNull);
      expect(computeLineTotals([l], null).zeroUnconfirmedLines, 0);
    });

    test('an unknown cost stays unknown', () {
      final l = CatalogEntry.fromJson(_service(cost: null)).toLine();
      expect(l.cost, isNull);
      expect(l.catalogCost, isNull);
      expect(computeLineTotals([l], null).profitCents, isNull);
    });

    test('taxed only when its billed lines all were', () {
      expect(CatalogEntry.fromJson(_service(tax: 'taxed')).toLine().taxable, isTrue);
      expect(CatalogEntry.fromJson(_service(tax: 'untaxed')).toLine().taxable, isFalse);
      expect(CatalogEntry.fromJson(_service(tax: 'mixed')).toLine().taxable, isFalse);
      // No billed lines (null): the old flag, which the server sends false.
      expect(CatalogEntry.fromJson(_service(tax: null)).toLine().taxable, isFalse);
      expect(CatalogEntry.fromJson({..._service(), 'taxDefault': null, 'taxable': true}).toLine().taxable, isTrue);
      // A taxable flag that disagrees with the tax default: the default wins.
      expect(CatalogEntry.fromJson({..._service(tax: 'mixed'), 'taxable': true}).toLine().taxable, isFalse);
    });
  });

  test('a product becomes the same line it always did', () {
    const p = CatalogEntry(
      key: 'cat:812',
      name: 'Clopay | Classic Steel | 4300 | Complete Door',
      sku: 'CL-4300',
      category: 'Doors',
      kind: 'product',
      inventoryItemId: 77,
      stock: 3,
      rate: 0,
      cost: 0,
      taxable: true,
      description: '16x7, white',
    );
    final l = p.toLine();
    // Exactly what toLine() built before Phase 2: the catalog's price and cost as given, even $0, its unit blank.
    const before = LineDraft(
      name: 'Clopay | Classic Steel | 4300 | Complete Door',
      description: '16x7, white',
      sku: 'CL-4300',
      quantity: 1,
      rate: 0,
      cost: 0,
      taxable: true,
      inventoryItemId: 77,
      catalogKey: 'cat:812',
      catalogRate: 0,
      catalogCost: 0,
      source: 'catalog',
    );
    expect(l.sameAs(before), isTrue);
    expect(l.catalogKey, before.catalogKey);
    expect(l.catalogRate, before.catalogRate);
    expect(l.catalogCost, before.catalogCost);
    expect(l.source, before.source);
    expect(l.toJson(), before.toJson());
    // A product's fields from the server are read as before; the service-only ones stay empty.
    final fromServer = CatalogEntry.fromJson({'key': 'cat:812', 'name': 'Door', 'kind': 'product', 'rate': 1200, 'cost': 700, 'taxable': true, 'category': 'Doors'});
    expect(fromServer.toLine().rate, 1200);
    expect(fromServer.toLine().taxable, isTrue);
    expect(fromServer.priceStatus, isNull);
  });
}
