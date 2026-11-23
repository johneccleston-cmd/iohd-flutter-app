// The "Add a line" search lists its matches in sections, Services and Products, each under a heading with its count
// and "Price" over the price column (user 2026-11-20). Each section keeps the server's best-first order, and the
// section holding the best match comes first. Headings are not options: the arrow keys step over them.
//   flutter test test/catalog_search_sections_test.dart   (also saves build/dash_shots/catalog_search_sections.png)

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/services/line_items_api.dart';
import 'package:iohd_desktop/widgets/catalog_search_field.dart';

import 'dashboard_harness.dart';

// In the server's order: best match first, products and services mixed.
const _ranked = [
  CatalogEntry(key: 'p1', name: 'Torsion Spring 250 x 2 x 32', sku: 'TS-250', category: 'Springs', rate: 95, uses: 120, stock: 14),
  CatalogEntry(key: 's1', name: 'Torsion Spring Replacement', kind: 'service', group: 'Repair', rate: 185, uses: 300, rateUses: 300, priceStatus: 'settled'),
  CatalogEntry(key: 'p2', name: 'Torsion Spring 225 x 1.75 x 30', sku: 'TS-225', category: 'Springs', rate: 85, uses: 60, stock: 3),
  CatalogEntry(
    key: 's2',
    name: 'Torsion Spring Conversion',
    kind: 'service',
    group: 'Repair',
    rateMin: 250,
    rateMax: 420,
    uses: 12,
    rateUses: 12,
    priceStatus: 'varies',
  ),
  CatalogEntry(key: 'p3', name: 'Torsion Spring Winding Bars (pair)', sku: 'WB-2', category: 'Tools', rate: 24, uses: 4),
];

void main() {
  setUpAll(loadDashFonts);

  test('sections keep the server order within each, best section first', () {
    expect(groupCatalogMatches(_ranked).map((e) => e.key), ['p1', 'p2', 'p3', 's1', 's2']);
    expect(groupCatalogMatches([_ranked[1], _ranked[0], _ranked[3]]).map((e) => e.key), ['s1', 's2', 'p1']);
  });

  testWidgets('the list shows a heading per section and the arrow keys skip them', (t) async {
    t.view.physicalSize = const Size(900, 560);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final shot = GlobalKey();
    final picked = <CatalogChoice>[];
    await t.pumpWidget(
      RepaintBoundary(
        key: shot,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 640,
                  child: CatalogSearchField(onPick: picked.add, showCost: true, search: (q) async => _ranked),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await t.enterText(find.byType(TextField), 'torsion');
    await t.pump(const Duration(milliseconds: 300));
    await t.pumpAndSettle();

    expect(find.text('Price'), findsNothing);
    expect(find.text(r'$95.00'), findsNothing, reason: 'no price on the results');
    expect(find.textContaining('Springs'), findsNothing, reason: 'no category on the results');
    final products = t.getTopLeft(find.textContaining('Products', findRichText: true)).dy;
    final services = t.getTopLeft(find.textContaining('Services', findRichText: true)).dy;
    expect(products, lessThan(services), reason: 'the best match is a product, so Products comes first');
    expect(t.getTopLeft(find.text('Torsion Spring Winding Bars (pair)')).dy, lessThan(services));
    expect(t.getTopLeft(find.text('Torsion Spring Replacement')).dy, greaterThan(services));

    await t.runAsync(() async {
      final image = await (shot.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final dir = Directory('build/dash_shots')..createSync(recursive: true);
      File('${dir.path}/catalog_search_sections.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });

    // Option 0 is highlighted; three Downs land on the fourth option, the first service, past the Services heading.
    for (var i = 0; i < 3; i++) {
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    }
    await t.pump();
    await t.testTextInput.receiveAction(TextInputAction.done); // Enter
    await t.pumpAndSettle();
    expect(picked.single.entry?.key, 's1');
  });

  testWidgets('low on the page, the list still drops down under the field (the page scrolls up), with no icons', (t) async {
    t.view.physicalSize = const Size(900, 600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final shot = GlobalKey();
    await t.pumpWidget(
      RepaintBoundary(
        key: shot,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 520), // the lines above the search
                  SizedBox(
                    width: 640,
                    child: CatalogSearchField(onPick: (_) {}, showCost: true, search: (q) async => _ranked),
                  ),
                  const SizedBox(height: 600), // the rest of the job page
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await t.enterText(find.byType(TextField), 'torsion');
    await t.pump(const Duration(milliseconds: 300));
    await t.pumpAndSettle();

    final field = t.getRect(find.byType(TextField));
    final heading = t.getRect(find.textContaining('Products', findRichText: true));
    expect(heading.top, greaterThan(field.bottom), reason: 'the list opens under the field, never over it');
    expect(field.bottom, lessThan(600 - 300), reason: 'the page scrolled the field up to make room');
    expect(t.getRect(find.text('Torsion Spring 250 x 2 x 32')).bottom, lessThan(600));
    for (final icon in [Icons.inventory_2_outlined, Icons.handyman_outlined, Icons.edit_note_rounded]) {
      expect(find.byIcon(icon), findsNothing);
    }

    await t.runAsync(() async {
      final image = await (shot.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('build/dash_shots/catalog_search_low.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  });
}
