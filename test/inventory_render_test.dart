// Renders the four Inventory menu screens flat, to test/shots/. Run:  flutter test test/inventory_render_test.dart --update-goldens

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/inventory_screen.dart';
import 'package:iohd_desktop/product_catalog_screen.dart';
import 'package:iohd_desktop/purchase_orders_screen.dart';
import 'package:iohd_desktop/vendors_screen.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

const _cats = ['Doors', 'Operators', 'Hardware', 'Springs'];

http.Client _mock({bool empty = false, int? failCode}) => MockClient((req) async {
      if (failCode != null) return http.Response('boom', failCode);
      return http.Response(
        jsonEncode(empty
            ? []
            : [
                for (var i = 0; i < 12; i++)
                  {
                    'item_name': 'Item number ${i + 1} ${_cats[i % 4]}',
                    'name': 'Item number ${i + 1} ${_cats[i % 4]}',
                    'sku': 'SKU-${100 + i}',
                    'category': _cats[i % 4],
                    'stock': i % 5 == 0 ? 0 : (i % 3 == 0 ? 3 : 20 + i),
                    'qty': i % 5 == 0 ? 0 : (i % 3 == 0 ? 3 : 20 + i),
                  },
              ]),
        200,
      );
    });

Future<void> _shot(WidgetTester t, Widget screen, Size size, String name, http.Client client) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  await http.runWithClient(() async {
    await t.pumpWidget(RepaintBoundary(
      key: const ValueKey('shot'),
      child: MaterialApp(theme: ThemeData(useMaterial3: true, fontFamily: 'Segoe UI'), home: screen),
    ));
    await t.pumpAndSettle();
  }, () => client);
  expect(t.takeException(), isNull);
  await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('shots/$name.png'));
}

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', ['C:/Windows/Fonts/segoeui.ttf', 'C:/Windows/Fonts/segoeuib.ttf']);
  });

  for (final size in const [Size(1366, 720), Size(800, 700), Size(420, 760)]) {
    final w = size.width.toInt();
    testWidgets('stock levels $w', (t) async => _shot(t, const InventoryScreen(), size, 'inv_stock_$w', _mock()));
    testWidgets('catalog $w', (t) async => _shot(t, const ProductCatalogScreen(), size, 'inv_catalog_$w', _mock()));
    testWidgets('purchase orders $w', (t) async => _shot(t, const PurchaseOrdersScreen(), size, 'inv_po_$w', _mock()));
    testWidgets('vendors $w', (t) async => _shot(t, const VendorsScreen(), size, 'inv_vendors_$w', _mock()));
  }
  testWidgets('stock empty', (t) async => _shot(t, const InventoryScreen(), const Size(1366, 720), 'inv_stock_empty', _mock(empty: true)));
  testWidgets('stock error', (t) async => _shot(t, const InventoryScreen(), const Size(1366, 720), 'inv_stock_error', _mock(failCode: 500)));
}
