// Audit renders of Stock Levels with the real 446-part snapshot. Scratch copy only; writes PNGs to build/audit/.
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
    if (!File(p).existsSync()) continue;
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

final _shot = GlobalKey();
late List<StockItem> real;
final log = StringBuffer();

Future<void> _pump(WidgetTester t, Widget screen, Size size, {bool settle = true}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(RepaintBoundary(
    key: _shot,
    child: MaterialApp(debugShowCheckedModeBanner: false, theme: officeTheme(), home: SelectionArea(child: screen)),
  ));
  if (settle) await t.pumpAndSettle();
}

Future<void> _save(WidgetTester t, String name) async {
  final boundary = _shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await t.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1.0);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory('build/audit')..createSync(recursive: true);
    File('${dir.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

void _note(String s) {
  log.writeln(s);
  // ignore: avoid_print
  print('AUDIT: $s');
}

void _measure(WidgetTester t, String label) {
  final lv = find.byType(ListView);
  if (lv.evaluate().isEmpty) {
    _note('$label: no list');
    return;
  }
  final box = t.getRect(lv.first);
  // Rows fully inside the list's viewport.
  final rows = find.descendant(of: lv.first, matching: find.byType(FadeTransition));
  var full = 0, part = 0;
  final heights = <double>[];
  for (final e in rows.evaluate()) {
    final r = t.getRect(find.byWidget(e.widget).first);
    heights.add(r.height);
    if (r.top >= box.top && r.bottom <= box.bottom) {
      full++;
    } else if (r.top < box.bottom) {
      part++;
    }
  }
  heights.sort();
  _note('$label: list ${box.width.toStringAsFixed(0)}x${box.height.toStringAsFixed(0)} at y=${box.top.toStringAsFixed(0)}, '
      'rows fully visible $full (+$part cut), row heights min ${heights.isEmpty ? 0 : heights.first} max ${heights.isEmpty ? 0 : heights.last}');
}

void main() {
  setUpAll(() async {
    await _loadFont('IBM Plex Sans', [for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) 'assets/fonts/IBMPlexSans-$w.ttf']);
    await _loadFont('Segoe UI', ['C:/Windows/Fonts/segoeui.ttf', 'C:/Windows/Fonts/segoeuib.ttf']);
    await _loadFont('MaterialIcons', ['C:/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
    real = [for (final e in jsonDecode(File('build/stock_shots/data.json').readAsStringSync()) as List) StockItem.fromJson(Map<String, dynamic>.from(e as Map))];
  });
  tearDownAll(() => File('build/audit/notes.txt').writeAsStringSync(log.toString()));

  for (final size in const [Size(1920, 940), Size(1500, 800), Size(1366, 768), Size(1280, 600), Size(1180, 700), Size(1000, 760), Size(760, 800), Size(420, 800)]) {
    final w = size.width.toInt(), h = size.height.toInt();
    testWidgets('default $w', (t) async {
      await _pump(t, InventoryScreen(loader: () async => real), size);
      expect(t.takeException(), isNull);
      _measure(t, 'default ${w}x$h');
      await _save(t, 'default_${w}x$h');
    });
  }

  testWidgets('sidebar groups open 1366', (t) async {
    await _pump(t, InventoryScreen(loader: () async => real), const Size(1366, 768));
    await t.tap(find.text('Category'));
    await t.pumpAndSettle();
    await _save(t, 'sidebar_open_1366');
  });

  testWidgets('filters on: low + 4 categories 1366 and chips', (t) async {
    await _pump(t, InventoryScreen(loader: () async => real), const Size(1366, 768));
    await t.tap(find.bySemanticsLabel(RegExp(r'^Low stock, ')));
    await t.pumpAndSettle();
    await t.tap(find.bySemanticsLabel(RegExp(r'^Out of stock, ')));
    await t.pumpAndSettle();
    await t.tap(find.text('Category'));
    await t.pumpAndSettle();
    for (final c in ['Bearing - RC', 'Decorative Hardware - Res', 'Hardware', 'Remote']) {
      final f = find.bySemanticsLabel(RegExp('^${RegExp.escape(c)}, '));
      if (f.evaluate().isNotEmpty) {
        await t.ensureVisible(f.first);
        await t.tap(f.first);
        await t.pumpAndSettle();
      }
    }
    _measure(t, 'filtered 1366');
    await _save(t, 'filtered_1366');
    await t.binding.setSurfaceSize(null);
  });

  testWidgets('sidebar hidden 1366', (t) async {
    await _pump(t, InventoryScreen(loader: () async => real), const Size(1366, 768));
    await t.tap(find.byTooltip('Hide filters'));
    await t.pumpAndSettle();
    await _save(t, 'sidebar_hidden_1366');
  });

  testWidgets('filters dialog 1000', (t) async {
    await _pump(t, InventoryScreen(loader: () async => real), const Size(1000, 760));
    await t.tap(find.text('Filters').first);
    await t.pumpAndSettle();
    await _save(t, 'filters_dialog_1000');
    await t.tap(find.bySemanticsLabel(RegExp(r'^Low stock, ')).last);
    await t.pumpAndSettle();
    await _save(t, 'filters_dialog_low_1000');
    await t.tap(find.text('Done'));
    await t.pumpAndSettle();
    await _save(t, 'filters_dialog_after_1000');
  });

  testWidgets('sort menu 420', (t) async {
    await _pump(t, InventoryScreen(loader: () async => real), const Size(420, 800));
    await t.tap(find.byTooltip('Sort (pick the same one again to reverse it)'));
    await t.pumpAndSettle();
    await _save(t, 'sort_menu_420');
  });

  testWidgets('narrow 420 with a filter', (t) async {
    await _pump(t, InventoryScreen(loader: () async => real), const Size(420, 800));
    await t.tap(find.text('Filters').first);
    await t.pumpAndSettle();
    await t.tap(find.bySemanticsLabel(RegExp(r'^Low stock, ')).last);
    await t.pumpAndSettle();
    await t.tap(find.text('Done'));
    await t.pumpAndSettle();
    await _save(t, 'narrow_filtered_420');
    // Scroll to the bottom to see the pager.
    await t.drag(find.byType(ListView), const Offset(0, -6000));
    await t.pumpAndSettle();
    await _save(t, 'narrow_bottom_420');
  });

  testWidgets('refresh fails: stale notice 1366', (t) async {
    var n = 0;
    await _pump(
      t,
      InventoryScreen(loader: () async {
        n++;
        if (n > 1) throw Exception('Could not reach the server. Check your connection and try again.');
        return real;
      }),
      const Size(1366, 768),
    );
    await t.tap(find.byTooltip('Refresh'));
    await t.pumpAndSettle();
    await _save(t, 'stale_1366');
    await t.tap(find.text('Try again'));
    await t.pump();
    await _save(t, 'stale_retrying_1366');
    await t.pumpAndSettle();
  });

  testWidgets('refresh in flight 1366', (t) async {
    var n = 0;
    final gate = Completer<List<StockItem>>();
    await _pump(
      t,
      InventoryScreen(loader: () async {
        n++;
        if (n == 1) return real;
        return gate.future;
      }),
      const Size(1366, 768),
    );
    await t.tap(find.byTooltip('Refresh'));
    await t.pump(const Duration(milliseconds: 300));
    await _save(t, 'refreshing_1366');
    // Can Refresh be pressed again while one is out?
    final btn = t.widget<IconButton>(find.ancestor(of: find.byIcon(Icons.refresh_rounded), matching: find.byType(IconButton)).first);
    _note('refresh button enabled while refreshing: ${btn.onPressed != null}');
    gate.complete(real);
    await t.pumpAndSettle();
  });

  testWidgets('first load and slow load 1366', (t) async {
    final gate = Completer<List<StockItem>>();
    await _pump(t, InventoryScreen(loader: () => gate.future), const Size(1366, 768), settle: false);
    await t.pump(const Duration(milliseconds: 500));
    await _save(t, 'loading_1366');
    await t.pump(const Duration(seconds: 9));
    await _save(t, 'loading_slow_1366');
    gate.complete(real);
    await t.pumpAndSettle();
  });

  testWidgets('loading 420', (t) async {
    final gate = Completer<List<StockItem>>();
    await _pump(t, InventoryScreen(loader: () => gate.future), const Size(420, 800), settle: false);
    await t.pump(const Duration(milliseconds: 500));
    await _save(t, 'loading_420');
    gate.complete(real);
    await t.pumpAndSettle();
  });

  testWidgets('error first load 1366', (t) async {
    await _pump(t, InventoryScreen(loader: () async => throw Exception('Could not load stock levels (server error 500).')), const Size(1366, 768));
    await _save(t, 'error_1366');
  });

  testWidgets('older server, no reorder points 1366', (t) async {
    final old = [for (final i in real) StockItem(name: i.name, category: i.category, partNumber: i.partNumber, location: i.location, qty: i.qty, reorderPoint: null)];
    await _pump(t, InventoryScreen(loader: () async => old), const Size(1366, 768));
    await _save(t, 'old_server_1366');
  });

  testWidgets('search 1366', (t) async {
    await _pump(t, InventoryScreen(loader: () async => real), const Size(1366, 768));
    await t.enterText(find.byType(TextField).first, "stop mold 7' white");
    await t.pump(const Duration(milliseconds: 300));
    await t.pumpAndSettle();
    await _save(t, 'search_stopmold_1366');
    await t.enterText(find.byType(TextField).first, 'discontinued');
    await t.pump(const Duration(milliseconds: 300));
    await t.pumpAndSettle();
    await _save(t, 'search_discontinued_1366');
    await t.enterText(find.byType(TextField).first, 'zzzz');
    await t.pump(const Duration(milliseconds: 300));
    await t.pumpAndSettle();
    await _save(t, 'search_none_1366');
  });

  testWidgets('sorted by on hand, page 9, 1366', (t) async {
    await _pump(t, InventoryScreen(loader: () async => real), const Size(1366, 768));
    await t.tap(find.text('ON HAND'));
    await t.pumpAndSettle();
    await _save(t, 'sort_onhand_1366');
    await t.tap(find.bySemanticsLabel('Page 9'));
    await t.pumpAndSettle();
    await _save(t, 'page9_1366');
    await t.tap(find.text('PART #'));
    await t.pumpAndSettle();
    await _save(t, 'sort_partnum_1366');
    await t.tap(find.text('SHELF'));
    await t.pumpAndSettle();
    await _save(t, 'sort_location_1366');
  });

  testWidgets('page size 100 then scroll to end 1366', (t) async {
    await _pump(t, InventoryScreen(loader: () async => real), const Size(1366, 768));
    await t.tap(find.bySemanticsLabel('100 rows per page'));
    await t.pumpAndSettle();
    await t.drag(find.byType(ListView), const Offset(0, -20000));
    await t.pumpAndSettle();
    await _save(t, 'rows100_end_1366');
  });

  testWidgets('hover a row 1366', (t) async {
    await _pump(t, InventoryScreen(loader: () async => real), const Size(1366, 768));
    final g = await t.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: const Offset(700, 300));
    await g.moveTo(const Offset(700, 300));
    await t.pumpAndSettle();
    await _save(t, 'hover_row_1366');
    // Mouse cursor over a row.
    final cursor = RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1);
    _note('cursor over a row: $cursor');
    await g.moveTo(const Offset(1250, 300));
    await t.pumpAndSettle();
    _note('cursor over status cell: ${RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1)}');
    await g.removePointer();
  });

  testWidgets('keyboard tab order 1366', (t) async {
    await _pump(t, InventoryScreen(loader: () async => real), const Size(1366, 768));
    final seen = <String>[];
    for (var i = 0; i < 24; i++) {
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pumpAndSettle();
      final f = FocusManager.instance.primaryFocus;
      final ctx = f?.context;
      String desc = '${f?.debugLabel}';
      if (ctx != null) {
        final sem = (ctx.findRenderObject())?.debugSemantics;
        final r = ctx.findRenderObject();
        if (r is RenderBox && r.hasSize) {
          final o = r.localToGlobal(Offset.zero);
          desc += ' @(${o.dx.toStringAsFixed(0)},${o.dy.toStringAsFixed(0)} ${r.size.width.toStringAsFixed(0)}x${r.size.height.toStringAsFixed(0)})';
        }
        if (sem != null) desc += ' "${sem.label}"';
      }
      seen.add(desc);
    }
    _note('tab order:\n  ${seen.join('\n  ')}');
    await _save(t, 'keyboard_after_tabs_1366');
  });

  testWidgets('larger text 1.3 at 1366 and 1.5 at 1920', (t) async {
    t.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    await _pump(t, InventoryScreen(loader: () async => real), const Size(1366, 768));
    expect(t.takeException(), isNull);
    _measure(t, 'text130 1366');
    await _save(t, 'text130_1366');
    t.platformDispatcher.textScaleFactorTestValue = 1.5;
    await _pump(t, InventoryScreen(loader: () async => real), const Size(1920, 940));
    expect(t.takeException(), isNull);
    await _save(t, 'text150_1920');
  });

  testWidgets('part page and change stock 1366', (t) async {
    await _pump(t, InventoryScreen(loader: () async => real, canAdjust: true, history: (n) async => const StockHistory(movements: [
      StockMovement(date: '11/19/2026', kind: 'office_receive', label: 'Received (office)', qty: 6, change: 6, person: 'Owen Owner', note: 'PO-1001'),
      StockMovement(date: '11/18/2026', kind: 'checkout', label: 'Job 40213', qty: 2, change: -2, person: 'Tom Tech'),
      StockMovement(date: '11/18/2026', kind: 'count', label: 'Cycle count', qty: 64, change: -1, person: 'Warehouse'),
      StockMovement(date: '11/17/2026', kind: 'scan_add', label: 'Scanned in', qty: 10, change: 10, person: 'Warehouse'),
    ], lastCount: (counted: 64, expected: 65, by: 'Warehouse', at: null), catalogProductId: 12)), const Size(1366, 768));
    await t.enterText(find.byType(TextField).first, 'bearing steel');
    await t.pump(const Duration(milliseconds: 300));
    await t.pumpAndSettle();
    await t.tap(find.textContaining('Bearing RC').first);
    await t.pumpAndSettle();
    await _save(t, 'part_page_1366');
    await t.tap(find.text('Change stock'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField).at(1), '6');
    await t.enterText(find.byType(TextField).at(2), 'PO-1001 delivery');
    await t.pumpAndSettle();
    await _save(t, 'change_stock_1366');
  });

  testWidgets('attention view and more menu 1366', (t) async {
    await _pump(t, InventoryScreen(loader: () async => real, link: const {'view': 'attention'}, canOrder: true), const Size(1366, 768));
    await _save(t, 'attention_1366');
    await t.tap(find.text('More'));
    await t.pumpAndSettle();
    await _save(t, 'more_menu_1366');
  });

  testWidgets('search highlight 1366', (t) async {
    await _pump(t, InventoryScreen(loader: () async => real), const Size(1366, 768));
    await t.enterText(find.byType(TextField).first, 'stop mold white');
    await t.pump(const Duration(milliseconds: 300));
    await t.pumpAndSettle();
    await _save(t, 'search_highlight_1366');
  });

  testWidgets('semantics of a row 1366', (t) async {
    final h = t.ensureSemantics();
    await _pump(t, InventoryScreen(loader: () async => real), const Size(1366, 768));
    final labels = <String>[];
    void walk(SemanticsNode n) {
      if (n.label.isNotEmpty) labels.add(n.label.replaceAll('\n', ' / '));
      n.visitChildren((c) {
        walk(c);
        return true;
      });
    }

    walk(t.getSemantics(find.byType(InventoryScreen)));
    _note('semantics labels (first 40):\n  ${labels.take(40).join('\n  ')}');
    h.dispose();
  });
}
