// PRODUCTS USED on a service package's page (2026-11-24): the products the package uses, in order, each with its qty;
// the price is the product's catalog price (read-only) and the total qty x price. Editing adds products from a search
// (products only), reorders them (drag by the handle, or Alt+Up / Alt+Down) and removes them (Delete); Save sends the whole set in order.
// One no longer in the catalog reads "Not in the catalog".
//   flutter test test/service_products_test.dart

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/service_detail_screen.dart';
import 'package:iohd_desktop/services/line_items_api.dart';

import 'dashboard_harness.dart';

const _spring = CatalogEntry(key: 'inv:7', name: 'Torsion Spring 250', kind: 'product', rate: 60, cost: 22, taxable: true);
const _remote = CatalogEntry(key: 'inv:8', name: 'LiftMaster Remote', kind: 'product', rate: 35, cost: 12, taxable: true);
const _cable = CatalogEntry(key: 'inv:9', name: 'Lift Cable', kind: 'product', rate: 18, cost: 5, taxable: true);
const _aService = CatalogEntry(key: 'sf:tune', name: 'Spring Tune-Up', kind: 'service', rate: 90);

const _package = CatalogEntry(
  key: 'sf:residential service',
  name: 'Residential Service',
  kind: 'service',
  category: 'Service Packages',
  group: 'Service Packages',
  rate: 435,
  cost: 119,
  taxable: false,
  description: 'Diagnose and service a residential garage door.',
  rates: [
    ServiceRate(name: 'Visit', qty: 1, rate: 75, cost: 15),
    ServiceRate(name: 'After hours', qty: 2, rate: 120, cost: 30),
  ],
  products: [
    ServiceProduct(key: 'inv:7', name: 'Torsion Spring 250', qty: 2, entry: _spring),
    ServiceProduct(key: 'inv:5', name: 'Discontinued Opener', qty: 1),
  ],
);

Future<List<List<ServiceProduct>>> _open(
  WidgetTester t, {
  CatalogEntry service = _package,
  Size size = const Size(1366, 1000),
  CatalogEntry Function(int read)? reads,
}) async {
  var read = 0;
  final sent = <List<ServiceProduct>>[];
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
      home: RepaintBoundary(
        key: _shotKey,
        child: ServiceDetailScreen(
        key: UniqueKey(),
        serviceKey: service.key,
        loader: () async => (entries: [reads?.call(read++) ?? service], canSeeCost: true, historyDays: 540),
        productsSaver: (key, products) async {
          sent.add(products);
          return CatalogEntry(key: service.key, name: service.name, kind: 'service', category: service.category, group: service.group, rates: service.rates, products: products);
        },
        productSearch: (q) async => [
          for (final e in const [_spring, _remote, _cable, _aService])
            if (e.name.toLowerCase().contains(q.toLowerCase())) e,
        ],
      ),
      ),
    ),
  );
  await t.pumpAndSettle();
  return sent;
}

final _shotKey = GlobalKey();

/// A review picture to `build/services_shots/products/NAME.png` (not a golden).
Future<void> _shot(WidgetTester t, String name) async {
  final boundary = _shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await t.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory('build/services_shots/products')..createSync(recursive: true);
    File('${dir.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

Future<void> _edit(WidgetTester t) async {
  await t.tap(find.text('Edit'));
  await t.pumpAndSettle();
}

Finder get _productSearch => find.byWidgetPredicate((w) => w is TextField && (w.decoration?.hintText ?? '').startsWith('Add a product'));

Future<void> _addProduct(WidgetTester t, String query, String name) async {
  await t.ensureVisible(_productSearch);
  await t.enterText(_productSearch, query);
  await t.pump(const Duration(milliseconds: 300));
  await t.pumpAndSettle();
  await t.tap(find.text(name).last);
  await t.pumpAndSettle();
}

Future<void> _menu(WidgetTester t, int i, String action) async {
  await t.ensureVisible(find.byKey(ValueKey('product-menu:$i')));
  await t.tap(find.byKey(ValueKey('product-menu:$i')));
  await t.pumpAndSettle();
  await t.tap(find.text(action).last);
  await t.pumpAndSettle();
}

/// Drags product [i] by its handle [dy] px (a row is 45 px), with the mouse, as a person does.
Future<void> _drag(WidgetTester t, int i, double dy) async {
  final handle = find.byKey(ValueKey('product-drag:$i'));
  await t.ensureVisible(handle);
  await t.pumpAndSettle();
  final g = await t.startGesture(t.getCenter(handle), kind: PointerDeviceKind.mouse);
  for (var k = 0; k < 10; k++) {
    await g.moveBy(Offset(0, dy / 10));
    await t.pump(const Duration(milliseconds: 16));
  }
  await g.up();
  await t.pumpAndSettle();
}

/// The product names as the table lists them, top to bottom.
List<String> _names(WidgetTester t) {
  final found = find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('product-name:'));
  final rows = [for (final e in found.evaluate()) (t.getTopLeft(find.byWidget(e.widget)).dy, ((e.widget as Text).data ?? (e.widget as Text).textSpan!.toPlainText()))];
  rows.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final r in rows) r.$2];
}

void main() {
  setUpAll(() async {
    await loadDashFonts();
    await dashSignIn();
  });

  testWidgets('reads: PRODUCTS USED under the rates, in order, catalog price and qty x price; a gone one says so', (t) async {
    await _open(t);
    expect(find.text('PRODUCTS USED'), findsOneWidget);
    expect(find.text('PRODUCT NAME'), findsOneWidget);
    expect(t.getTopLeft(find.text('PRODUCTS USED')).dy, greaterThan(t.getTopLeft(find.text('SERVICE RATES')).dy));
    expect(_names(t), ['Torsion Spring 250', 'Discontinued Opener']);
    expect(find.text(r'$60.00'), findsOneWidget, reason: 'the catalog price');
    expect(find.text(r'$120.00'), findsWidgets, reason: r'2 x $60');
    expect(find.text('Not in the catalog'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('reads: Starts at includes the products', (t) async {
    await _open(t);
    expect(find.text(r'$435.00'), findsOneWidget, reason: r'1 x $75 + 2 x $120 + 2 x $60');
  });

  testWidgets('reads: no products yet says so', (t) async {
    await _open(t, service: const CatalogEntry(key: 'sf:x', name: 'X Package', kind: 'service', rates: [ServiceRate(name: 'Visit', qty: 1, rate: 75)]));
    expect(find.textContaining('No products yet', findRichText: true), findsOneWidget);
  });

  testWidgets('edit: the search offers products only; a pick adds a line at qty 1 at the end', (t) async {
    final sent = await _open(t);
    await _edit(t);
    await t.ensureVisible(_productSearch);
    await t.enterText(_productSearch, 'spring');
    await t.pump(const Duration(milliseconds: 300));
    await t.pumpAndSettle();
    expect(find.text('Spring Tune-Up'), findsNothing, reason: 'services are not offered');
    expect(find.textContaining('custom line'), findsNothing, reason: 'no custom lines on a package');
    await t.enterText(_productSearch, '');
    await t.pumpAndSettle();
    await _addProduct(t, 'remote', 'LiftMaster Remote');
    expect(_names(t), ['Torsion Spring 250', 'Discontinued Opener', 'LiftMaster Remote']);
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(sent.single.map((p) => (p.key, p.qty)), [('inv:7', 2.0), ('inv:5', 1.0), ('inv:8', 1.0)]);
  });

  testWidgets('edit: picking a product already listed raises its qty instead of adding a line', (t) async {
    final sent = await _open(t);
    await _edit(t);
    await _addProduct(t, 'torsion', 'Torsion Spring 250');
    expect(_names(t), ['Torsion Spring 250', 'Discontinued Opener']);
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(sent.single.first.qty, 3);
  });

  testWidgets('edit: drag a product by its handle to move it, and Delete; Save sends the new order', (t) async {
    final sent = await _open(t);
    await _edit(t);
    await _addProduct(t, 'cable', 'Lift Cable');
    // Products move by dragging (the user 2026-11-24), not from the ⋮ menu.
    await t.tap(find.byKey(const ValueKey('product-menu:0')));
    await t.pumpAndSettle();
    expect(find.text('Move up'), findsNothing);
    expect(find.text('Move down'), findsNothing);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    await _drag(t, 2, -60);
    expect(_names(t), ['Torsion Spring 250', 'Lift Cable', 'Discontinued Opener']);
    await _drag(t, 0, 60);
    expect(_names(t), ['Lift Cable', 'Torsion Spring 250', 'Discontinued Opener']);
    await _menu(t, 2, 'Delete');
    expect(_names(t), ['Lift Cable', 'Torsion Spring 250']);
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(sent.single.map((p) => p.key), ['inv:9', 'inv:7']);
  });

  testWidgets('edit: a qty that is not a number is refused and nothing is sent', (t) async {
    final sent = await _open(t);
    await _edit(t);
    await t.enterText(find.byKey(const ValueKey('field:product0.qty')), '');
    await t.pump();
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(find.textContaining('Enter a quantity.'), findsOneWidget);
    expect(sent, isEmpty);
  });

  testWidgets('edit: nothing changed in the products sends nothing for them; Cancel puts them back', (t) async {
    final sent = await _open(t);
    await _edit(t);
    await _menu(t, 0, 'Delete');
    expect(_names(t), ['Discontinued Opener']);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    if (find.text('Discard changes').evaluate().isNotEmpty) {
      await t.tap(find.text('Discard changes'));
      await t.pumpAndSettle();
    }
    expect(_names(t), ['Torsion Spring 250', 'Discontinued Opener']);
    await _edit(t);
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(sent, isEmpty);
  });

  for (final (name, size) in const [('page_edit_1366', Size(1366, 1500)), ('page_edit_narrow_700', Size(700, 2000))]) {
    testWidgets('review picture: $name', (t) async {
      await _open(t, size: size);
      await _edit(t);
      await t.enterText(_productSearch, 'li');
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await _shot(t, name);
    });
  }

  // Final review fixes (2026-11-24).
  testWidgets('a plain service (no rates) has no PRODUCTS USED: products would replace its own price', (t) async {
    await _open(t, service: const CatalogEntry(key: 'sf:spring', name: 'Spring Replacement', kind: 'service', rate: 250));
    expect(find.text('PRODUCTS USED'), findsNothing);
    await _edit(t);
    expect(find.text('PRODUCTS USED'), findsNothing);
    expect(_productSearch, findsNothing);
  });

  testWidgets('deleting every rate while products are listed is refused on Save, and nothing is sent', (t) async {
    final sent = await _open(t);
    await _edit(t);
    for (var i = 0; i < 2; i++) {
      await t.ensureVisible(find.byKey(const ValueKey('rate-menu:0')));
      await t.tap(find.byKey(const ValueKey('rate-menu:0')));
      await t.pumpAndSettle();
      await t.tap(find.text('Delete').last);
      await t.pumpAndSettle();
    }
    expect(find.text('PRODUCTS USED'), findsOneWidget, reason: 'still shown while it holds products');
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(find.textContaining('Add a rate before listing products'), findsOneWidget);
    expect(sent, isEmpty);
  });

  testWidgets('a product renamed in the catalog while editing is not "someone else saved this"', (t) async {
    const renamed = CatalogEntry(key: 'inv:7', name: 'Torsion Spring 250 (new name)', kind: 'product', rate: 60, cost: 22, taxable: true);
    final later = CatalogEntry(
      key: _package.key,
      name: _package.name,
      kind: 'service',
      category: _package.category,
      group: _package.group,
      description: _package.description,
      rates: _package.rates,
      products: const [
        ServiceProduct(key: 'inv:7', name: 'Torsion Spring 250 (new name)', qty: 2, entry: renamed),
        ServiceProduct(key: 'inv:5', name: 'Discontinued Opener', qty: 1),
      ],
    );
    final sent = await _open(t, reads: (n) => n == 0 ? _package : later);
    await _edit(t);
    await _addProduct(t, 'remote', 'LiftMaster Remote');
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('conflict-notice')), findsNothing);
    expect(sent, hasLength(1));
  });
}
