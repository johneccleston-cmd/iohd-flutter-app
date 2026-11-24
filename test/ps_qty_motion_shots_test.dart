// Review pictures for the P&S qty box, its arrows, and the popups' motion (2026-11-23). Not goldens: the PNGs go to
// build/ps_qty_shots/ for a look.
//   flutter test test/ps_qty_motion_shots_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/main.dart' show officeTheme;
import 'package:iohd_desktop/services/line_items_api.dart';
import 'package:iohd_desktop/utils/line_item_math.dart';
import 'package:iohd_desktop/widgets/line_items_editor.dart';
import 'package:iohd_desktop/widgets/page_selection.dart';

import 'dashboard_harness.dart';

final _shot = GlobalKey();

Future<void> pumpForProbe(WidgetTester t, {bool editable = true}) => _pump(t, editable: editable);

Future<void> saveForProbe(WidgetTester t, String n, Rect? crop) => _save(t, n, crop: crop, ratio: crop == null ? 1 : 4);

Future<void> _pump(WidgetTester t, {double width = 1500, bool editable = true}) async {
  t.view.physicalSize = Size(width, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    RepaintBoundary(
      key: _shot,
      child: MaterialApp(
        theme: officeTheme().copyWith(visualDensity: VisualDensity.compact),
        builder: appSelectionBuilder,
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: LineItemsEditor(
                lines: [
                  LineDraft(name: 'Clopay | Classic Steel | 4300 | Complete Door | Almond', sku: 'CL-4300-1607', rate: 1489, cost: 912.4, quantity: 1),
                  LineDraft(name: 'Tek Screws | Retail Accessories', rate: 0.21, quantity: 2400),
                  LineDraft(name: 'Widest figures', rate: 999000, cost: 999000, quantity: 1),
                  LineDraft(name: 'Torsion Spring | 0.250 x 2" x 32"', rate: 89, cost: 19.5, quantity: -99999.99),
                  if (const bool.fromEnvironment('more')) ...const [
                    LineDraft(name: 'Spring replacement | Labor', rate: 185, cost: 60, quantity: 1, packageId: 'p1', packageName: 'Spring service package', service: true),
                    LineDraft(name: 'Trip charge', rate: 49, cost: 0, quantity: 1, packageId: 'p1', packageName: 'Spring service package', service: true),
                    LineDraft(kind: LineKind.discount, name: 'Builder Relationship Discount', rate: 150, quantity: 1),
                    LineDraft(kind: LineKind.fee, name: 'Card processing fee', percent: 3, quantity: 1),
                  ],
                ],
                taxRate: 10.5,
                editable: editable,
                showCost: true,
                onPreviewSave: () {},
                search: (q) async => const <CatalogEntry>[],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

Future<void> _save(WidgetTester t, String name, {Rect? crop, double ratio = 1}) async {
  final boundary = _shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await t.runAsync(() async {
    var image = await boundary.toImage(pixelRatio: ratio);
    if (crop != null) {
      final rec = ui.PictureRecorder();
      final c = Canvas(rec);
      final src = Rect.fromLTRB(crop.left * ratio, crop.top * ratio, crop.right * ratio, crop.bottom * ratio);
      c.drawImageRect(image, src, Offset.zero & src.size, Paint()..filterQuality = FilterQuality.none);
      image = await rec.endRecording().toImage(src.width.round(), src.height.round());
    }
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory('build/ps_qty_shots')..createSync(recursive: true);
    File('${dir.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

Future<void> _frames(WidgetTester t, String name, Future<void> Function() open, Future<void> Function() close) async {
  await open();
  await t.pump();
  for (final ms in [0, 25, 50, 75, 100, 150, 250]) {
    await _save(t, '${name}_open_${ms.toString().padLeft(3, '0')}');
    await t.pump(const Duration(milliseconds: 25));
  }
  await t.pumpAndSettle();
  await close();
  await t.pump();
  for (final ms in [0, 25, 50, 75, 100, 150]) {
    await _save(t, '${name}_close_${ms.toString().padLeft(3, '0')}');
    await t.pump(const Duration(milliseconds: 25));
  }
  await t.pumpAndSettle();
}

void main() {
  setUpAll(loadDashFonts);

  testWidgets('qty boxes and arrows, close up', (t) async {
    await _pump(t);
    await _save(t, 'table');
    await _save(t, 'row0_x4', crop: const Rect.fromLTRB(700, 58, 1260, 97), ratio: 4);
    final qty = t.getRect(find.byKey(const ValueKey('col-qty')).first);
    await _save(t, 'qty_header_rows_x3', crop: Rect.fromLTRB(qty.left - 10, qty.top - 4, qty.right + 40, qty.top + 300).intersect(const Offset(0, 0) & const Size(1500, 900)), ratio: 3);
    // Hover the first line's up arrow.
    final up = find.byTooltip('One more').first;
    final g = await t.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: t.getCenter(up));
    await t.pumpAndSettle();
    await _save(t, 'qty_hover_up_x4', crop: t.getRect(up).inflate(30), ratio: 4);
    await g.moveTo(t.getCenter(find.byTooltip('One less').first));
    await t.pumpAndSettle();
    await _save(t, 'qty_hover_down_x4', crop: t.getRect(up).inflate(30), ratio: 4);
    await g.removePointer();
    expect(t.takeException(), isNull);
  });

  testWidgets('row menu motion', (t) async {
    await _pump(t);
    await _frames(
      t,
      'menu',
      () => t.tap(find.byKey(const ValueKey('line-0-actions'))),
      () => t.tapAt(const Offset(5, 880)),
    );
    expect(t.takeException(), isNull);
  });

  testWidgets('tax, discounts & fees motion', (t) async {
    await _pump(t);
    await _frames(
      t,
      'charges',
      () => t.tap(find.text('Tax, discounts & fees')),
      () => t.tapAt(const Offset(1490, 880)),
    );
    expect(t.takeException(), isNull);
  });
}
