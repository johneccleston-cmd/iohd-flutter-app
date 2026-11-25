import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/inventory_screen.dart';
import 'package:iohd_desktop/main.dart' show officeTheme;

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    if (File(p).existsSync()) loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

final _shot = GlobalKey();
late List<StockItem> real;

Future<void> _pump(WidgetTester t, Widget screen, Size size) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(RepaintBoundary(
    key: _shot,
    child: MaterialApp(debugShowCheckedModeBanner: false, theme: officeTheme(), home: SelectionArea(child: screen)),
  ));
  await t.pumpAndSettle();
}

Future<void> _save(WidgetTester t, String name) async {
  final boundary = _shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await t.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1.0);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('build/audit/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

bool _cut(WidgetTester t, String text) {
  for (final e in find.text(text).evaluate()) {
    final r = e.findRenderObject();
    if (r is RenderParagraph && r.didExceedMaxLines) return true;
  }
  return false;
}

void main() {
  setUpAll(() async {
    await _loadFont('IBM Plex Sans', [for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) 'assets/fonts/IBMPlexSans-$w.ttf']);
    await _loadFont('MaterialIcons', ['C:/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
    real = [for (final e in jsonDecode(File('build/stock_shots/data.json').readAsStringSync()) as List) StockItem.fromJson(Map<String, dynamic>.from(e as Map))];
  });

  for (final w in [1000.0, 1180.0, 1366.0]) {
    testWidgets('long names cut at $w', (t) async {
      await _pump(t, InventoryScreen(loader: () async => real), Size(w, 900));
      await t.enterText(find.byType(TextField), 'photo eye commercial reflective');
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();
      const n = 'Photo Eye | Commercial | Reflective Monitored Photo Eyes Commercial (Pair)| LiftMaster';
      // ignore: avoid_print
      print('AUDIT: at $w long name cut: ${_cut(t, n)}; tooltip present: ${find.byType(Tooltip).evaluate().where((e) => (e.widget as Tooltip).message == n).isNotEmpty}');
      await _save(t, 'longname_${w.toInt()}');
      // Categories cut, any tooltip?
      await t.enterText(find.byType(TextField), '');
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();
      var cut = 0, total = 0;
      for (final e in find.byType(Text).evaluate()) {
        final r = e.findRenderObject();
        if (r is RenderParagraph) {
          total++;
          if (r.didExceedMaxLines) cut++;
        }
      }
      // ignore: avoid_print
      print('AUDIT: at $w page 1, texts cut short: $cut of $total; Tooltips on page: ${find.byType(Tooltip).evaluate().length}');
    });
  }

  testWidgets('can a part number be selected and copied?', (t) async {
    await _pump(t, InventoryScreen(loader: () async => real), const Size(1366, 768));
    final at = t.getTopLeft(find.text('0110700'));
    final g = await t.startGesture(at + const Offset(-2, 8), kind: PointerDeviceKind.mouse);
    await t.pump();
    await g.moveTo(at + const Offset(60, 8));
    await t.pump();
    await g.up();
    await t.pumpAndSettle();
    String? copied;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (c) async {
      if (c.method == 'Clipboard.setData') copied = (c.arguments as Map)['text'] as String?;
      return null;
    });
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyC);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pumpAndSettle();
    // ignore: avoid_print
    print('AUDIT: drag over part # then Ctrl+C copied: ${copied == null ? 'nothing' : '"$copied"'}');
    // Control: the count label outside the rows.
    final at2 = t.getTopLeft(find.text('446 parts'));
    final g2 = await t.startGesture(at2 + const Offset(-2, 8), kind: PointerDeviceKind.mouse);
    await t.pump();
    await g2.moveTo(at2 + const Offset(70, 8));
    await t.pump();
    await g2.up();
    await t.pumpAndSettle();
    copied = null;
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyC);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pumpAndSettle();
    // ignore: avoid_print
    print('AUDIT: control (count label) copied: ${copied == null ? 'nothing' : '"$copied"'}');
  });

  testWidgets('two refreshes out of order: which data stays?', (t) async {
    var n = 0;
    final slow = Completer<List<StockItem>>();
    final fast = Completer<List<StockItem>>();
    final older = [real.first, real[1]]; // the slow (first-sent) answer
    await _pump(
      t,
      InventoryScreen(loader: () {
        n++;
        if (n == 1) return Future.value(real);
        if (n == 2) return slow.future;
        return fast.future;
      }),
      const Size(1366, 768),
    );
    await t.tap(find.byTooltip('Refresh'));
    await t.pump();
    await t.tap(find.byTooltip('Refresh'));
    await t.pump();
    fast.complete(real); // the newer request answers first
    await t.pump(const Duration(milliseconds: 50));
    slow.complete(older); // then the older one lands
    await t.pumpAndSettle();
    // ignore: avoid_print
    print('AUDIT: requests sent: ${n - 1} refreshes; list now shows: ${find.text('446 parts').evaluate().isNotEmpty ? 'newest (446)' : find.text('2 parts').evaluate().isNotEmpty ? 'OLDER answer (2 parts)' : 'other'}');
  });

  testWidgets('status counts with a category picked', (t) async {
    await _pump(t, InventoryScreen(loader: () async => real), const Size(1366, 900));
    await t.tap(find.text('Category'));
    await t.pumpAndSettle();
    await t.tap(find.bySemanticsLabel(RegExp(r'^Remote, ')));
    await t.pumpAndSettle();
    await t.tap(find.text('Stock status'));
    await t.pumpAndSettle();
    final labels = [for (final s in ['Out of stock', 'Low stock', 'In stock', 'Not kept in stock']) find.bySemanticsLabel(RegExp('^$s, ')).evaluate().map((e) => (e.widget as Semantics).properties.label).join()];
    // ignore: avoid_print
    print('AUDIT: with Category=Remote, status rows say: $labels');
    await _save(t, 'counts_with_category_1366');
  });
}
