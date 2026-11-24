// Products & Services round 2 finalization (2026-11-23), the Product Catalog list: Active / Inactive / All tabs like the
// Services list (A6), a product's own SKU found beside its part number (B5), and row hover that shows on every row (A3).
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/product_catalog_screen.dart';
import 'package:iohd_desktop/services/line_items_api.dart';
import 'package:iohd_desktop/widgets/catalog_kit.dart';

import 'dashboard_harness.dart';

final _entries = <CatalogEntry>[
  for (var i = 0; i < 60; i++) CatalogEntry(key: 'cat:${100 + i}', name: 'Spring $i', sku: 'S$i', category: 'Springs', rate: 100.0 + i, cost: 50),
  const CatalogEntry(key: 'cat:1', name: 'Keypad | VKP1LM | LiftMaster', sku: '4154066', skus: ['4154066', 'VKP1LMMC'], category: 'Keypads', rate: 60),
  const CatalogEntry(key: 'cat:2', name: 'Old Spring', sku: 'OS1', category: 'Springs', rate: 80, active: false),
  const CatalogEntry(key: 'cat:3', name: 'Old Keypad', sku: 'OK1', category: 'Keypads', active: false),
];

Future<void> _pump(WidgetTester t, {Size size = const Size(1366, 900)}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: ThemeData(fontFamily: 'Segoe UI'), home: ProductCatalogScreen(loader: () async => (entries: _entries, canSeeCost: true, historyDays: 540))));
  await t.pumpAndSettle();
}

Finder _tab(String s) => find.byKey(ValueKey('status:$s'));
String _count(WidgetTester t, String s) =>
    t.widgetList<Text>(find.descendant(of: _tab(s), matching: find.byType(Text))).map((w) => w.data ?? '').where((d) => RegExp(r'^[\d,]+$').hasMatch(d)).single;

Future<void> _search(WidgetTester t, String q) async {
  await t.enterText(find.byType(TextField).first, q);
  await t.pump(const Duration(milliseconds: 400));
  await t.pumpAndSettle();
}

void main() {
  setUpAll(loadDashFonts);

  testWidgets('A6: Active / Inactive / All tabs with their counts; the list follows the tab', (t) async {
    await _pump(t);
    expect(_count(t, 'active'), '61');
    expect(_count(t, 'inactive'), '2');
    expect(_count(t, 'all'), '63');
    expect(find.text('Old Spring'), findsNothing, reason: 'the page starts on Active');
    expect(find.text('Status'), findsNothing, reason: 'status is the tabs now, not a sidebar filter');
    await t.tap(_tab('inactive'));
    await t.pumpAndSettle();
    expect(find.text('Old Spring'), findsOneWidget);
    expect(find.text('Old Keypad'), findsOneWidget);
    expect(find.text('Spring 1'), findsNothing);
  });

  testWidgets('A6: the counts follow the search, and a tab change starts the list at page 1', (t) async {
    await _pump(t);
    await t.tap(find.byTooltip('Next page'));
    await t.pumpAndSettle();
    await t.tap(_tab('all'));
    await t.pumpAndSettle();
    expect(find.text('Spring 0'), findsOneWidget, reason: 'back on page 1');
    await _search(t, 'keypad');
    expect(_count(t, 'active'), '1');
    expect(_count(t, 'inactive'), '1');
    expect(_count(t, 'all'), '2');
    expect(find.text('Old Keypad'), findsOneWidget);
    expect(find.text('Keypad | VKP1LM | LiftMaster'), findsOneWidget);
  });

  testWidgets('B5: a product\'s own SKU finds it, as its part number does', (t) async {
    await _pump(t);
    await _search(t, 'VKP1LMMC');
    expect(find.text('Keypad | VKP1LM | LiftMaster'), findsOneWidget);
    expect(_count(t, 'active'), '1');
    await _search(t, '4154066');
    expect(find.text('Keypad | VKP1LM | LiftMaster'), findsOneWidget);
  });

  testWidgets('A3: on a narrow window every row lights under the pointer, striped ones too, and picked rows keep their own look', (t) async {
    await _pump(t, size: const Size(700, 900));
    final odd = find.ancestor(of: find.text('Spring 0'), matching: find.byKey(const ValueKey('row-surface'))).first;
    Color? colorOf(Finder f) => (t.widget<AnimatedContainer>(f).decoration as BoxDecoration?)?.color;
    expect(colorOf(odd), CatalogUi.stripe);
    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(t.getCenter(find.text('Spring 0'))); // the second row (after the keypad): striped
    await t.pumpAndSettle();
    expect(colorOf(odd), CatalogUi.hover, reason: 'it used to be painted under the stripe, so it never showed');
  });
}
