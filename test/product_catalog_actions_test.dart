// Product Catalog: a click opens the product page, New product, Export, and the CSV file's contents.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:iohd_desktop/product_catalog_screen.dart';
import 'package:iohd_desktop/services/line_items_api.dart';
import 'package:iohd_desktop/theme/app_theme.dart';
import 'package:iohd_desktop/utils/product_csv.dart';

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

final _entries = <CatalogEntry>[
  const CatalogEntry(key: 'cat:1', name: 'Bearing RC | Steel | 1"', sku: '0140950', category: 'Bearing - RC', stock: 65, rate: 2.66, cost: 0.87, inventoryItem: true),
  const CatalogEntry(key: 'cat:2', name: "Chain Drive | 10' T501, LiftMaster", sku: '4007442', category: 'Operator', stock: 1, rate: 856.7, cost: 691.34, inventoryItem: true),
  const CatalogEntry(key: 'cat:3', name: 'Clopay Gallery Steel | Complete Door', sku: 'GD5S', category: 'Overhead Door', stock: 3, cost: 755.68, memberPrice: 700),
  const CatalogEntry(key: 'cat:4', name: '=SUM(A1) sneaky name', category: 'Miscellaneous', rate: 25, cost: 15),
  const CatalogEntry(key: 'cat:5', name: 'Old Opener Remote', sku: 'OLD1', category: 'Operator', active: false),
];

Widget _router(ProductCatalogScreen screen) {
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => screen),
      GoRoute(path: '/inventory/catalog/:id', builder: (_, s) => Scaffold(body: Text('product page ${s.pathParameters['id']} ?${s.uri.query}'))),
    ],
  );
  return MaterialApp.router(debugShowCheckedModeBanner: false, theme: _theme, routerConfig: router);
}

Future<void> _pump(WidgetTester t, Widget w, {Size size = const Size(1366, 768)}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(w);
  await t.pumpAndSettle();
}

ProductCatalogScreen _screen({bool canSeeCost = true, Future<bool> Function(String, Uint8List)? exporter}) =>
    ProductCatalogScreen(loader: () async => (entries: _entries, canSeeCost: canSeeCost, historyDays: 540), exporter: exporter);

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', ['C:/Windows/Fonts/segoeui.ttf', 'C:/Windows/Fonts/segoeuib.ttf']);
    await _loadFont('MaterialIcons', ['C:/src/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
  });

  testWidgets('product lines have no row buttons: a click opens the product page, a new product opens a blank one', (t) async {
    await _pump(t, _router(_screen()));
    for (final tip in ['View product', 'Edit product', 'Delete product']) {
      expect(find.byTooltip(tip), findsNothing, reason: tip);
    }
    expect(find.text('Actions'), findsNothing);
    await t.tap(find.text('Clopay Gallery Steel | Complete Door'));
    await t.pumpAndSettle();
    expect(find.text('product page 3 ?'), findsOneWidget);

    await _pump(t, _router(_screen()));
    await t.tap(find.text('New product'));
    await t.pumpAndSettle();
    expect(find.text('product page new ?'), findsOneWidget);
  });

  testWidgets('Export saves what the filters show as a CSV, formulas defanged, costs only with the switch', (t) async {
    String? name;
    String? csv;
    await _pump(
      t,
      _router(
        _screen(
          exporter: (n, bytes) async {
            name = n;
            expect(bytes.take(3), [0xEF, 0xBB, 0xBF]); // byte order mark for Excel
            csv = utf8.decode(bytes.sublist(3));
            return true;
          },
        ),
      ),
    );
    await t.tap(find.text('Inactive')); // Status: Active + Inactive, so the retired remote is exported too
    await t.pumpAndSettle();
    await t.tap(find.text('Export'));
    await t.pumpAndSettle();
    expect(name, matches(RegExp(r'^product-catalog-\d{4}-\d{2}-\d{2}\.csv$')));
    final lines = const LineSplitter().convert(csv!);
    expect(lines.first, 'Product,Part #,Category,Model,In stock,Unit cost,Price,Member price,Status,Inventory item');
    expect(lines, hasLength(6)); // header + 5 products
    expect(lines, contains('"Chain Drive | 10\' T501, LiftMaster",4007442,Operator,,1,691.34,856.70,,Active,Yes'));
    expect(csv, contains("'=SUM(A1) sneaky name")); // would be a formula otherwise
    expect(lines.last, startsWith('Old Opener Remote'));
    expect(lines.last, endsWith('Inactive,No'));
    expect(find.text('Exported 5 products'), findsOneWidget);
  });

  testWidgets('Export follows the filters and leaves the cost column out without the costs switch', (t) async {
    String? csv;
    await _pump(
      t,
      _router(
        _screen(
          canSeeCost: false,
          exporter: (n, bytes) async {
            csv = utf8.decode(bytes.sublist(3));
            return true;
          },
        ),
      ),
    );
    await t.tap(find.text('Overhead Door').first); // the sidebar's category row
    await t.pumpAndSettle();
    await t.tap(find.text('Export'));
    await t.pumpAndSettle();
    final lines = const LineSplitter().convert(csv!);
    expect(lines.first, 'Product,Part #,Category,Model,In stock,Price,Member price,Status,Inventory item');
    expect(lines, hasLength(2));
    expect(lines.last, 'Clopay Gallery Steel | Complete Door,GD5S,Overhead Door,,3,,700.00,Active,No');
  });

  test('the CSV escapes quotes, commas and line breaks', () {
    const e = CatalogEntry(key: 'cat:9', name: 'Door "Deluxe", 8\' wide\nwith glass', category: 'Doors', rate: 10);
    final csv = productCatalogCsv([e], canSeeCost: false);
    expect(csv, contains('"Door ""Deluxe"", 8\' wide\nwith glass"'));
    expect(csv.split('\r\n').first, 'Product,Part #,Category,Model,In stock,Price,Member price,Status,Inventory item');
  });
}
