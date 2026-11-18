// Product Catalog Phase 1 redesign (2026-11-16): the behaviour the new layout adds. No golden images here; the real-Chrome
// pictures are in build/catalog_redesign.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/product_catalog_screen.dart';
import 'package:iohd_desktop/product_detail_screen.dart';
import 'package:iohd_desktop/services/line_items_api.dart';
import 'package:iohd_desktop/widgets/catalog_kit.dart';

final _entries = <CatalogEntry>[
  for (var i = 0; i < 12; i++)
    CatalogEntry(key: 'cat:${100 + i}', name: 'Spring $i', sku: 'S$i', category: 'Category $i', stock: i, rate: 100.0 + i, cost: 50, inventoryItem: true),
  const CatalogEntry(
    key: 'cat:1',
    name: 'Bearing RC | Steel | 1"',
    sku: '0140950',
    category: 'Bearing - RC',
    stock: 65,
    rate: 2.66,
    cost: 0.87,
    inventoryItem: true,
  ),
  const CatalogEntry(key: 'cat:2', name: 'Chain Tensioner', category: 'Operator Parts', stock: 0, rate: 48.18, cost: 48.18, inventoryItem: true),
  const CatalogEntry(key: 'cat:3', name: 'Complete Door', sku: 'GD5S', category: 'Overhead Door', cost: 755.68, inventoryItem: false),
  const CatalogEntry(key: 'cat:4', name: 'Tek Screws', sku: 'GD5S', category: 'Overhead Door', rate: 0.21, inventoryItem: false),
  const CatalogEntry(key: 'cat:16', name: 'Sure-Stop LH', category: 'Bottom Bracket - Com', rate: 471.55, inventoryConflict: 'duplicate_name'),
];

Future<void> _pump(WidgetTester t, {bool canSeeCost = true, Size size = const Size(1366, 768)}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(home: ProductCatalogScreen(loader: () async => (entries: _entries, canSeeCost: canSeeCost, historyDays: 540))));
  await t.pumpAndSettle();
}

Finder _row(String key) => find.byKey(ValueKey('row:$key'));

void main() {
  testWidgets('a filter that is on shows as a chip in the command row; its x takes it off', (t) async {
    await _pump(t);
    expect(find.text('17 products'), findsOneWidget);
    await t.tap(find.text('Overhead Door').first);
    await t.pumpAndSettle();
    expect(find.text('2 matching'), findsOneWidget);
    expect(find.text(' of 17'), findsOneWidget);
    final chip = find.bySemanticsLabel('Remove filter Category Overhead Door');
    expect(chip, findsOneWidget);
    await t.tap(chip);
    await t.pumpAndSettle();
    expect(find.text('17 products'), findsOneWidget);
    expect(chip, findsNothing);
  });

  testWidgets('categories: the biggest first, "Show all", and a search that narrows the list', (t) async {
    await _pump(t);
    expect(find.text('Show all 16'), findsOneWidget); // 16 categories, the 8 biggest (then A to Z) listed first
    expect(find.text('Category 9'), findsNothing);
    await t.tap(find.text('Show all 16'));
    await t.pumpAndSettle();
    expect(find.text('Category 9'), findsOneWidget);
    await t.enterText(find.widgetWithText(TextField, 'Find a category'), 'bottom');
    await t.pumpAndSettle();
    expect(find.text('Bottom Bracket - Com'), findsWidgets);
    expect(find.text('Category 9'), findsNothing);
    await t.enterText(find.widgetWithText(TextField, 'Find a category'), 'zzz');
    await t.pumpAndSettle();
    expect(find.text('No category matches'), findsOneWidget);
  });

  testWidgets('Stock: in stock and needs review; Needs attention: cost at or above price, no cost, per-job price, shared part #', (t) async {
    await _pump(t);
    Future<void> only(String label, String count) async {
      await t.ensureVisible(find.text(label)); // the sidebar scrolls as one
      await t.pumpAndSettle();
      await t.tap(find.text(label));
      await t.pumpAndSettle();
      expect(find.text(count), findsOneWidget, reason: label);
      await t.tap(find.text(label));
      await t.pumpAndSettle();
    }

    await only('In stock', '12 matching'); // springs 1-11 and the bearing; the tensioner has 0, the bracket needs review
    await only('Stock needs review', '1 matching');
    await only('Cost at or above price', '1 matching'); // the tensioner: cost equals price
    await only('No cost entered', '2 matching'); // the screws and the bracket
    await only('Per-job price', '1 matching'); // the door
    // Phase 3 split "Same name or part #" into the data-quality checks: the door and the screws share GD5S.
    await only('Same part #', '2 matching');
    expect(find.text('Same name'), findsNothing, reason: 'a check that finds nothing takes no room in the sidebar');
  });

  testWidgets('without the costs switch the cost-based attention filters and the Margin column are not offered', (t) async {
    await _pump(t, canSeeCost: false);
    expect(find.text('Cost at or above price'), findsNothing);
    expect(find.text('No cost entered'), findsNothing);
    expect(find.text('MARGIN'), findsNothing);
    expect(find.text('Per-job price'), findsOneWidget);
  });

  testWidgets('the Margin column reads from a real price and cost and sorts, biggest first', (t) async {
    await _pump(t);
    expect(find.descendant(of: _row('cat:1'), matching: find.text('67%')), findsOneWidget);
    expect(find.descendant(of: _row('cat:2'), matching: find.text('0%')), findsOneWidget);
    expect(find.descendant(of: _row('cat:3'), matching: find.text('—')), findsWidgets); // per job: no margin made up
    await t.tap(find.text('MARGIN'));
    await t.pumpAndSettle();
    final first = t.getTopLeft(_row('cat:1')).dy;
    expect(first, lessThan(t.getTopLeft(_row('cat:100')).dy)); // 67% before the springs' ~50%
  });

  testWidgets('stock reads a dash for a product that is not kept in inventory, a number otherwise', (t) async {
    await _pump(t);
    expect(find.descendant(of: _row('cat:2'), matching: find.text('0')), findsOneWidget); // an inventory item that ran out
    expect(find.descendant(of: _row('cat:4'), matching: find.text('0')), findsNothing); // the screws are not stocked
  });

  testWidgets('the filter sidebar can be put away and brought back from the command row', (t) async {
    await _pump(t);
    expect(find.text('Product name'), findsOneWidget);
    await t.tap(find.byTooltip('Hide filters'));
    await t.pumpAndSettle();
    expect(find.text('Product name'), findsNothing);
    await t.tap(find.text('Filters'));
    await t.pumpAndSettle();
    expect(find.text('Product name'), findsOneWidget);
  });

  testWidgets('"/" jumps to the search box; Escape clears it', (t) async {
    await _pump(t);
    final search = find.widgetWithText(TextField, 'Search name, part #, category or description');
    await t.sendKeyEvent(LogicalKeyboardKey.slash);
    await t.pumpAndSettle();
    expect(t.widget<TextField>(search).focusNode!.hasFocus, isTrue);
    await t.enterText(search, 'bearing');
    await t.pump(const Duration(milliseconds: 300));
    await t.pumpAndSettle();
    expect(find.text('1 matching'), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(find.text('17 products'), findsOneWidget);
  });

  testWidgets('the search also finds words in descriptions', (t) async {
    t.view.physicalSize = const Size(1366, 768);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final list = [..._entries, const CatalogEntry(key: 'cat:9', name: 'Keypad | L979U', description: 'Security 3.0 keypad for openers', rate: 57.24)];
    await t.pumpWidget(MaterialApp(home: ProductCatalogScreen(loader: () async => (entries: list, canSeeCost: true, historyDays: 540))));
    await t.pumpAndSettle();
    await t.enterText(find.widgetWithText(TextField, 'Search name, part #, category or description'), 'security');
    await t.pump(const Duration(milliseconds: 300));
    await t.pumpAndSettle();
    expect(find.text('1 matching'), findsOneWidget);
  });

  testWidgets('the pager numbers pages around the current one', (t) async {
    expect(CatalogPager.numbers(1, 17), [1, 2, 3, 4, null, 17]);
    expect(CatalogPager.numbers(9, 17), [1, null, 8, 9, 10, null, 17]);
    expect(CatalogPager.numbers(17, 17), [1, null, 14, 15, 16, 17]);
    expect(CatalogPager.numbers(3, 5), [1, 2, 3, 4, 5]);
  });

  // ---- the product page ----

  const bearing = ProductRecord(
    id: 1,
    name: 'Bearing RC | Steel | 1"',
    category: 'Bearing - RC',
    unitPrice: 2.66,
    avgUnitCost: 0.87,
    updatedAt: '2026-11-16T15:00:00.000Z',
  );

  Future<void> pumpPage(
    WidgetTester t, {
    Future<ProductRecord> Function(int? id, Map<String, dynamic> f, String? at, {bool confirmDuplicate})? saver,
    Future<Map<String, int?>> Function()? categoriesLoader,
  }) async {
    t.view.physicalSize = const Size(1366, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        home: ProductDetailScreen(
          productId: 1,
          loader: (_) async => (product: bearing, stock: 65, canSeeCost: true, canEdit: true, inventoryConflict: null),
          saver: saver,
          categoriesLoader: categoriesLoader,
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  testWidgets('the margin follows the price while it is typed, and warns before a price under the cost is saved', (t) async {
    await pumpPage(t);
    await t.tap(find.text('Edit'));
    await t.pumpAndSettle();
    expect(find.text('67%'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('field:unitPrice')), '0.50');
    await t.pumpAndSettle();
    expect(find.text('-74%'), findsOneWidget);
    expect(find.text('Cost is above the price'), findsOneWidget);
    expect(find.text('Unsaved changes'), findsOneWidget);
  });

  testWidgets('Ctrl+S saves while editing, only once something changed', (t) async {
    Map<String, dynamic>? sent;
    await pumpPage(
      t,
      saver: (id, f, at, {confirmDuplicate = false}) async {
        sent = f;
        return bearing;
      },
    );
    await t.tap(find.text('Edit'));
    await t.pumpAndSettle();
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyS);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pumpAndSettle();
    expect(sent, isNull); // nothing changed yet
    await t.enterText(find.byKey(const ValueKey('field:description')), 'Steel bearing');
    await t.pumpAndSettle();
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyS);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pumpAndSettle();
    expect(sent, {'description': 'Steel bearing'});
  });

  testWidgets('the category picker lists the catalog\'s categories and narrows as you type', (t) async {
    await pumpPage(t, categoriesLoader: () async => const {'Bearing - RC': 4, 'Keypad': 14, 'Overhead Door': 9});
    await t.tap(find.text('Edit'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('field:category')));
    await t.pumpAndSettle();
    await t.enterText(find.widgetWithText(TextField, 'Find a category, or type a new one'), 'key');
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('pick-category:Overhead Door')), findsNothing);
    await t.tap(find.byKey(const ValueKey('pick-category:Keypad')));
    await t.pumpAndSettle();
    await t.tap(find.text('Use this category'));
    await t.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const ValueKey('field:category')), matching: find.text('Keypad')), findsOneWidget);
  });
}
