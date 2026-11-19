// The add-line search's service rows and what a service just added says under its line (Services Catalog Phase 2,
// 2026-11-18): each row shows its group and how often it was billed and how sure its price is (settled, a recent change
// with the 18-month median and the newest prices apart, varies, billed once, only quoted, none), a tax hint when its
// billed lines differ, and what a renamed variant was split from. Products are shown as they always were. Once added,
// a service that isn't settled starts unpriced, never at $0, and nothing is filled in for the person; only a price
// billed once can be picked with one tap.
//   flutter test test/service_picker_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/services/line_items_api.dart';
import 'package:iohd_desktop/widgets/line_items_editor.dart';

import 'dashboard_harness.dart';

CatalogEntry _service(String name, String status, {double? rate, Map<String, dynamic> extra = const {}}) => CatalogEntry.fromJson({
  'key': 'sfr:${name.hashCode}',
  'name': name,
  'kind': 'service',
  'category': 'Residential Service',
  'group': 'Residential Service',
  'rate': rate,
  'rateMin': 249,
  'rateMax': 325,
  'uses': 14,
  'rateUses': 14,
  'cost': null,
  'taxable': false,
  'taxDefault': 'untaxed',
  'priceStatus': status,
  'medianPrice': 285,
  'lastBilled': {'date': '2026-11-10', 'price': 289},
  'recentPrices': [
    {'date': '2026-11-10', 'price': 289},
  ],
  'quoteMedian': 299,
  'quoteCount': 2,
  ...extra,
});

final _entries = [
  _service('Spring Replacement', 'settled', rate: 285),
  _service(
    'Service Call',
    'recent_change',
    extra: {
      'medianPrice': 89,
      'recentChange': {
        'median': 89,
        'prices': [
          {'date': '2026-11-12', 'price': 129},
          {'date': '2026-11-05', 'price': 125},
          {'date': '2026-10-30', 'price': 119},
        ],
        'direction': 'up',
        'since': '2026-10-30',
        'warning': 'Recent price change: ...',
      },
    },
  ),
  _service('Install Residential Door', 'varies', extra: {'taxDefault': 'mixed', 'taxWarning': 'Taxed on 9 of 14 billed jobs. Check the tax on this line.'}),
  _service('Weather Seal Labor', 'single', extra: {'uses': 1, 'rateUses': 1}),
  _service('Commercial Survey', 'quote_only', extra: {'uses': 0, 'rateUses': 0, 'lastBilled': null, 'medianPrice': null}),
  _service('Warranty Visit', 'none', extra: {'uses': 0, 'rateUses': 0, 'lastBilled': null, 'medianPrice': null, 'quoteMedian': null}),
  _service('Spring Replacement - Commercial', 'settled', rate: 340, extra: {
    'variantOf': {'key': 'sfr:1', 'name': 'Spring Replacement'},
  }),
  const CatalogEntry(key: 'inv:7', name: 'Torsion Spring | 0.250 x 2" x 32"', sku: 'TS-25032', category: 'Springs', inventoryItemId: 7, stock: 14, rate: 89, uses: 40, taxable: true),
];

Future<void> _pump(WidgetTester t) async {
  t.view.physicalSize = const Size(1500, 1100);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
      home: Scaffold(
        body: SingleChildScrollView(
          child: LineItemsEditor(
            lines: const [],
            taxRate: null,
            editable: true,
            showCost: true,
            onPreviewSave: () {},
            search: (q) async => [for (final e in _entries) if (q == 'all' || e.name.toLowerCase().contains(q.toLowerCase())) e],
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

Finder get _search => find.byWidgetPredicate((w) => w is TextField && (w.decoration?.hintText ?? '').startsWith('Add a line'));

Future<void> _type(WidgetTester t, String q) async {
  await t.enterText(_search, q);
  await t.pump(const Duration(milliseconds: 300));
  await t.pumpAndSettle();
}

Future<void> _add(WidgetTester t, String q, String name) async {
  await _type(t, q);
  await t.tap(find.text(name).last);
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await loadDashFonts();
    await dashSignIn();
  });

  testWidgets('service rows say how sure their price is; product rows are as they were', (t) async {
    await _pump(t);
    await _type(t, 'all');
    expect(t.takeException(), isNull);
    expect(find.text(r'$285.00'), findsOneWidget, reason: 'settled: the price');
    expect(find.text('Recent price change'), findsOneWidget);
    expect(find.text(r'18-mo median $89.00 · recent $129.00, $125.00, $119.00'), findsOneWidget);
    expect(find.text(r'Price varies $249.00 – $325.00'), findsOneWidget);
    expect(find.text(r'Billed once · $289.00'), findsOneWidget);
    expect(find.text(r'No billed price · quoted $299.00'), findsOneWidget);
    expect(find.text('No price on file'), findsOneWidget);
    expect(find.text('Renamed line of Spring Replacement, with its own price'), findsOneWidget);
    expect(find.text('Residential Service · billed 14×'), findsWidgets);
    expect(find.text('Residential Service · never billed'), findsWidgets, reason: 'only quoted, or nothing on file');
    expect(find.textContaining('tax varies'), findsOneWidget, reason: 'only the mixed-tax service');
    // The product row: SKU, category, stock and Service Fusion uses, its price.
    await _type(t, 'torsion');
    expect(find.text('SKU TS-25032  ·  Springs  ·  14 in stock  ·  on 40 Service Fusion lines'), findsOneWidget);
    expect(find.text(r'$89.00'), findsOneWidget);
  });

  testWidgets('a recent price change: nothing filled in, the median and the newest prices shown apart, no one-tap price', (t) async {
    await _pump(t);
    await _add(t, 'service call', 'Service Call');
    expect(find.text('Not priced'), findsOneWidget, reason: 'the line starts unpriced, never at \$0');
    expect(find.byKey(const ValueKey('zero-chip')), findsNothing);
    final hint = find.byKey(const ValueKey('hint-recent-change'));
    expect(hint, findsOneWidget);
    expect(
      find.descendant(of: hint, matching: find.textContaining(r'18-month median $89.00 · recent $129.00, $125.00, $119.00')),
      findsOneWidget,
    );
    expect(find.textContaining('Use last billed'), findsNothing);
  });

  testWidgets('billed once: "Use last billed" is the person\'s pick, and the hint goes once the line is priced', (t) async {
    await _pump(t);
    await _add(t, 'weather', 'Weather Seal Labor');
    expect(find.text('Not priced'), findsOneWidget);
    expect(find.byKey(const ValueKey('hint-not-priced')), findsOneWidget);
    await t.tap(find.text(r'Use last billed $289.00'));
    await t.pumpAndSettle();
    expect(find.text('Not priced'), findsNothing);
    expect(find.byKey(const ValueKey('hint-not-priced')), findsNothing);
    expect(find.text(r'$289.00'), findsWidgets, reason: 'the rate and the amount');
  });

  testWidgets('mixed tax: the line starts untaxed and says to check it; a settled service fills its price in', (t) async {
    await _pump(t);
    await _add(t, 'install', 'Install Residential Door');
    expect(find.textContaining('Taxed on 9 of 14 billed jobs. Check the tax on this line.'), findsOneWidget);
    expect(find.textContaining(r'Billed $249.00 – $325.00'), findsOneWidget);
    expect(find.text('No tax'), findsOneWidget, reason: 'untaxed to start');
    await _add(t, 'spring replacement', 'Spring Replacement');
    expect(find.text(r'$285.00'), findsWidgets);
    // The settled one has nothing to say; the hints stay with their own line.
    expect(find.byKey(const ValueKey('hint-not-priced')), findsOneWidget);
  });
}
