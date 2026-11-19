// Product Catalog page with a fake price list. Shots go to test/shots/product_catalog_*.png. Run:
//   flutter test test/product_catalog_render_test.dart --update-goldens   (then look at the PNGs)

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/product_catalog_screen.dart';
import 'package:iohd_desktop/services/line_items_api.dart';
import 'package:iohd_desktop/theme/app_theme.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

final _theme = ThemeData(
  useMaterial3: true,
  fontFamily: 'Segoe UI',
  colorScheme: ColorScheme.fromSeed(seedColor: AppTheme.brandRed, primary: AppTheme.brandRed),
);

// Shapes as /api/catalog/list sends them once catalog_products is loaded.
final _entries = <CatalogEntry>[
  for (var i = 0; i < 60; i++)
    CatalogEntry(
      key: 'cat:${100 + i}',
      name: 'Torsion Spring RC | LW .2${(i % 9) + 1}5 x 2 x ${20 + i}.0',
      sku: '70300${10 + i}',
      category: 'Torsion Spring - RC',
      stock: i.isEven ? i : 0,
      rate: 100 + i * 2.5,
      cost: 18.3 + i,
      inventoryItem: true,
    ),
  const CatalogEntry(
    key: 'cat:1',
    name: 'Bearing RC | Steel | 1"',
    sku: '0140950',
    category: 'Bearing - RC',
    stock: 65,
    rate: 2.66,
    cost: 0.87,
    inventoryItem: true,
    purchaseNote: 'Specifications for Ordering | Door Thickness 1.75" and 2" - 161" to 208" of Vertical Track Length',
    vendors: [(name: 'iStore', price: 0.95), (name: 'Parts Store', price: 0)],
  ),
  const CatalogEntry(
    key: 'cat:2',
    name: "Chain Drive | 10' T501 L5 | LiftMaster",
    sku: '4007442',
    category: 'Commercial Operator Head',
    stock: 1,
    rate: 856.7,
    cost: 691.34,
    inventoryItem: true,
    description: 'Light Duty Trolley Operator - Logic 5.0 | For use on standard-lift sectional overhead doors',
    vendors: [(name: 'iStore', price: 1405.16)],
  ),
  const CatalogEntry(key: 'cat:3', name: 'Clopay Gallery Steel | GD5S | Complete Door', sku: 'GD5S', category: 'Overhead Door', stock: 3, cost: 755.68, inventoryItem: false),
  const CatalogEntry(key: 'cat:4', name: 'Materials & Consumables | per service call', category: 'Miscellaneous', rate: 25, cost: 15, inventoryItem: false),
  // Retired from the price list: hidden until the Status filter lets it in.
  const CatalogEntry(key: 'cat:5', name: 'Old Opener Remote', sku: 'OLD1', category: 'Bearing - RC', active: false, inventoryItem: false),
];

final _searchBox = find.widgetWithText(TextField, 'Search name, part # or category');

Widget _app(Widget home) => MaterialApp(debugShowCheckedModeBanner: false, theme: _theme, home: home);

ProductCatalogScreen _screen({bool canSeeCost = true, List<CatalogEntry>? entries, Object? error}) => ProductCatalogScreen(
  loader: () async {
    if (error != null) throw error;
    return (entries: entries ?? _entries, canSeeCost: canSeeCost, historyDays: 540);
  },
);

Future<void> _pump(WidgetTester t, Widget w, {Size size = const Size(1366, 768)}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(RepaintBoundary(key: const ValueKey('shot'), child: _app(w)));
  await t.pumpAndSettle();
}

Future<void> _shot(WidgetTester t, String name) async {
  expect(t.takeException(), isNull);
  await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('shots/$name.png'));
}

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', ['C:/Windows/Fonts/segoeui.ttf', 'C:/Windows/Fonts/segoeuib.ttf']);
    await _loadFont('MaterialIcons', ['C:/src/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
  });

  testWidgets('desktop, sorted by name', (t) async {
    await _pump(t, _screen());
    expect(find.text('64 products'), findsOneWidget); // a count line, no scorecards
    expect(find.text('In stock now'), findsNothing);
    expect(find.text('Priced per job'), findsNothing);
    expect(find.text('Bearing RC | Steel | 1"'), findsOneWidget);
    expect(find.text('UNIT COST'), findsOneWidget); // small-caps headers, as Products & Services has them
    expect(find.text('MARGIN'), findsNothing); // no margin column
    expect(find.text('IN STOCK'), findsNothing); // stock lives on the Stock Levels screen
    expect(find.text('Per job'), findsOneWidget); // the GD5S door has no list price
    await _shot(t, 'product_catalog_1366');
  });

  testWidgets('search and category filter, then the detail dialog', (t) async {
    await _pump(t, _screen());
    await t.enterText(_searchBox, '4007442');
    await t.pump(const Duration(milliseconds: 200));
    await t.pumpAndSettle();
    expect(find.text("Chain Drive | 10' T501 L5 | LiftMaster"), findsOneWidget);
    expect(find.text('Bearing RC | Steel | 1"'), findsNothing);
    await t.tap(find.text("Chain Drive | 10' T501 L5 | LiftMaster"));
    await t.pumpAndSettle();
    expect(find.text('Bought from'), findsOneWidget);
    await _shot(t, 'product_catalog_detail');
    await t.tap(find.text('Close'));
    await t.pumpAndSettle();

    await t.enterText(_searchBox, 'nothing like this');
    await t.pump(const Duration(milliseconds: 200));
    await t.pumpAndSettle();
    expect(find.text('No products match'), findsOneWidget);
    await t.tap(find.text('Clear search and filters'));
    await t.pumpAndSettle();
    expect(find.text('Bearing RC | Steel | 1"'), findsOneWidget);
  });

  testWidgets('without the cost switch: no cost column, no vendor prices', (t) async {
    await _pump(t, _screen(canSeeCost: false), size: const Size(1024, 700));
    expect(find.text('UNIT COST'), findsNothing);
    expect(find.text('MARGIN'), findsNothing);
    await t.tap(find.text('Bearing RC | Steel | 1"'));
    await t.pumpAndSettle();
    expect(find.text('Bought from'), findsNothing);
    await t.tap(find.text('Close'));
    await t.pumpAndSettle();
    await _shot(t, 'product_catalog_1024_nocost');
  });

  testWidgets('narrow window stacks the rows and sorts from a menu', (t) async {
    await _pump(t, _screen(), size: const Size(640, 760));
    expect(find.byType(SingleChildScrollView), findsNothing); // no sideways scrolling
    expect(find.text('PART #'), findsNothing); // no table header, rows are stacked
    expect(find.byTooltip('Sort'), findsOneWidget);
    await _shot(t, 'product_catalog_640');
    await t.tap(find.byTooltip('Sort'));
    await t.pumpAndSettle();
    await t.tap(find.text('Price').last);
    await t.pumpAndSettle();
  });

  testWidgets('clicking a header sorts and flips the arrow', (t) async {
    await _pump(t, _screen());
    await t.tap(find.text('PRICE'));
    await t.pumpAndSettle();
    expect(find.byIcon(Icons.arrow_downward_rounded), findsOneWidget); // numbers start biggest first
    await t.tap(find.text('PRICE'));
    await t.pumpAndSettle();
    expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);
  });

  testWidgets('sidebar filters stack: several categories, then status', (t) async {
    await _pump(t, _screen());
    for (final g in ['Filters', 'Part number', 'Status', 'Needs attention']) {
      expect(find.text(g), findsOneWidget, reason: g);
    }
    for (final g in ['Inventory', 'Stock', 'Not in inventory', 'In stock']) {
      expect(find.text(g), findsNothing, reason: '$g: stock lives on the Stock Levels screen');
    }
    expect(find.text('Product name'), findsNothing); // the top search already covers names
    // Part number sits above Status, and Category and Needs attention start closed.
    expect(t.getTopLeft(find.text('Part number')).dy, lessThan(t.getTopLeft(find.text('Status')).dy));
    expect(find.text('Torsion Spring - RC'), findsWidgets); // the table's cells...
    expect(find.text('Per-job price'), findsNothing);
    await t.tap(find.text('Category').first); // the group starts closed
    await t.pumpAndSettle();
    expect(find.text('Category'), findsWidgets); // the sidebar group and the table's column
    expect(find.byTooltip('Filter by category'), findsNothing); // the old drop-down is gone
    await t.tap(find.text('Bearing - RC').first); // the sidebar row comes before the table's cells
    await t.pumpAndSettle();
    expect(find.text('1 matching'), findsOneWidget); // the retired remote is hidden by Status: Active
    await t.tap(find.text('Overhead Door').first);
    await t.pumpAndSettle();
    expect(find.text('2 matching'), findsOneWidget); // two categories add up
    expect(find.text('Clopay Gallery Steel | GD5S | Complete Door'), findsOneWidget);
    await t.tap(find.text('Inactive'));
    await t.pumpAndSettle();
    expect(find.text('3 matching'), findsOneWidget); // Active and Inactive both on = no status filter: the remote joins
    expect(find.text('Old Opener Remote'), findsOneWidget);
    expect(find.text('Inactive'), findsNWidgets(2)); // the filter row and the row's own tag
    await _shot(t, 'product_catalog_filters');
    await t.tap(find.text('Clear all'));
    await t.pumpAndSettle();
    expect(find.text('64 products'), findsOneWidget);
  });

  testWidgets('part number filter, and the search box together', (t) async {
    await _pump(t, _screen());
    expect(find.widgetWithText(TextField, 'Part # contains'), findsNothing); // the group starts closed
    await t.tap(find.text('Part number'));
    await t.pumpAndSettle();
    await t.enterText(find.widgetWithText(TextField, 'Part # contains'), '7030010');
    await t.pump(const Duration(milliseconds: 300));
    await t.pumpAndSettle();
    expect(find.text('1 matching'), findsOneWidget);
    await t.enterText(_searchBox, 'bearing');
    await t.pump(const Duration(milliseconds: 300));
    await t.pumpAndSettle();
    expect(find.text('No products match'), findsOneWidget); // the spring has no "bearing" in its name
    await t.tap(find.text('Clear search and filters'));
    await t.pumpAndSettle();
    expect(find.text('64 products'), findsOneWidget);
  });

  testWidgets('narrow window: a Filters button opens the same filters in a dialog', (t) async {
    await _pump(t, _screen(), size: const Size(1024, 700));
    expect(find.text('Part number'), findsNothing); // no sidebar
    await t.tap(find.text('Filters'));
    await t.pumpAndSettle();
    expect(find.text('Part number'), findsOneWidget);
    await t.tap(find.text('Category').last); // the dialog's group, closed until opened
    await t.pumpAndSettle();
    await t.tap(find.text('Overhead Door').last);
    await t.pumpAndSettle();
    expect(find.text('1'), findsWidgets); // the Filters badge counts the set filter
    await t.tap(find.text('Done'));
    await t.pumpAndSettle();
    expect(find.text('1 matching'), findsOneWidget);
  });

  testWidgets('error with retry', (t) async {
    await _pump(t, _screen(error: const LineItemsException('Could not reach the server.')));
    expect(find.text('Could not load the catalog'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    await _shot(t, 'product_catalog_error');
  });

  testWidgets('empty list', (t) async {
    await _pump(t, _screen(entries: const []));
    expect(find.text('No products yet'), findsOneWidget);
  });

  testWidgets('a cost the server borrowed from inventory or Service Fusion is not shown; only the catalog\'s own cost is', (t) async {
    const list = [
      CatalogEntry(key: 'cat:1', name: 'Own Cost Spring', sku: 'A1', category: 'Springs', rate: 100, cost: 40.25, costSource: 'catalog'),
      CatalogEntry(key: 'cat:2', name: 'Clopay Borrowed Door', sku: 'GD5S', category: 'Overhead Door', rate: 900, cost: 755.68, costSource: 'inventory'),
      CatalogEntry(key: 'cat:3', name: 'SF Borrowed Opener', sku: 'B2', category: 'Openers', rate: 500, cost: 321.09, costSource: 'service_fusion'),
    ];
    await _pump(t, _screen(entries: list));
    expect(find.text('\$40.25'), findsOneWidget);
    expect(find.text('\$755.68'), findsNothing);
    expect(find.text('\$321.09'), findsNothing);
    await _pump(t, _screen(entries: list), size: const Size(820, 700)); // stacked rows too
    expect(find.text('\$40.25'), findsOneWidget);
    expect(find.text('\$755.68'), findsNothing);
  });
}
