// Stock Levels (lib/inventory_screen.dart): status rules, parsing, filters, and states. With build/stock_shots/data.json
// present (real sheet rows run through the backend's stockLevels.js), it also writes PNGs to build/stock_shots.

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/inventory_screen.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    if (!File(p).existsSync()) continue;
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

StockItem _item(String name, int qty, int rp, {String cat = 'Hardware', String part = '', String loc = ''}) =>
    StockItem(name: name, category: cat, qty: qty, reorderPoint: rp, partNumber: part, location: loc);

final _sample = [
  _item('Back Hang Nut', 1250, 3000, part: '0099', loc: 'A1'),
  _item('Bearing RC | Steel | 1"', 65, 20, cat: 'Bearing - RC', part: '0140950', loc: 'I3'),
  _item('Cable 8ft', 0, 2, cat: 'Cable Assembly - RC'),
  _item('Chain Drive | 24\' | LiftMaster', 0, 0, cat: 'Operator Rail'),
  _item('Bottom Bracket | LH', 31, 0, cat: 'Bottom Bracket - Res'),
  _item('Keypad | 878MAX', 5, 5, cat: 'Remote'),
];

final _shot = GlobalKey();

Future<void> _pump(WidgetTester t, Widget screen, Size size) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(RepaintBoundary(
    key: _shot,
    child: MaterialApp(debugShowCheckedModeBanner: false, theme: ThemeData(useMaterial3: true, fontFamily: 'Segoe UI'), home: screen),
  ));
  await t.pumpAndSettle();
  expect(t.takeException(), isNull);
}

Future<void> _save(WidgetTester t, String name) async {
  final boundary = _shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await t.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1.0);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory('build/stock_shots')..createSync(recursive: true);
    File('${dir.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

void main() {
  setUpAll(() => _loadFont('Segoe UI', ['C:/Windows/Fonts/segoeui.ttf', 'C:/Windows/Fonts/segoeuib.ttf']));

  test('status follows the reorder point, the same rule as the Inventory dashboard', () {
    expect(_item('a', 0, 2).status, StockStatus.out);
    expect(_item('a', -1, 2).status, StockStatus.out);
    expect(_item('a', 2, 2).status, StockStatus.low); // at the reorder point is low
    expect(_item('a', 3, 2).status, StockStatus.ok);
    expect(_item('a', 1250, 3000).status, StockStatus.low);
    expect(_item('a', 0, 0).status, StockStatus.notStocked); // no reorder point: none on hand is not "out"
    expect(_item('a', 31, 0).status, StockStatus.ok); // no reorder point, units on hand: in stock, never low
  });

  test('parsing: formatted numbers, N/A part numbers, blank categories, older servers', () {
    final i = StockItem.fromJson({'name': ' Back Hang Nut ', 'category': '', 'qty': '1,250.00', 'partNumber': 'N/A', 'location': 'A1', 'reorderPoint': '3,000'});
    expect(i.name, 'Back Hang Nut');
    expect(i.category, 'Uncategorized');
    expect(i.qty, 1250);
    expect(i.reorderPoint, 3000);
    expect(i.partNumber, '');
    final old = StockItem.fromJson({'name': 'Cable', 'category': 'Cable', 'qty': 0});
    expect(old.reorderPoint, isNull); // an older server: no reorder points to go by
  });

  testWidgets('wide: sidebar counts, needs-attention first, status filter narrows', (t) async {
    await _pump(t, InventoryScreen(loader: () async => _sample), const Size(1366, 760));
    expect(find.text('6 parts  ·  1,351 units on hand'), findsOneWidget);
    // Out of stock first, then low (fewest first).
    final names = [for (final w in t.widgetList<Text>(find.byType(Text))) w.data ?? ''];
    expect(names.indexOf('Cable 8ft'), lessThan(names.indexOf('Keypad | 878MAX')));
    expect(names.indexOf('Keypad | 878MAX'), lessThan(names.indexOf('Back Hang Nut')));
    expect(find.text('Not kept in stock'), findsWidgets);

    await t.tap(find.bySemanticsLabel('Low stock, 2'));
    await t.pumpAndSettle();
    expect(find.text('2 matching  ·  1,255 units on hand'), findsOneWidget);
    expect(find.text('Bearing RC | Steel | 1"'), findsNothing);
  });

  testWidgets('search covers part number and shelf; no match offers a way back', (t) async {
    await _pump(t, InventoryScreen(loader: () async => _sample), const Size(1366, 760));
    await t.enterText(find.byType(TextField), 'i3');
    await t.pump(const Duration(milliseconds: 300));
    await t.pumpAndSettle();
    expect(find.text('Bearing RC | Steel | 1"'), findsOneWidget);
    expect(find.text('Back Hang Nut'), findsNothing);
    await t.enterText(find.byType(TextField), 'zzz');
    await t.pump(const Duration(milliseconds: 300));
    await t.pumpAndSettle();
    expect(find.text('No parts match "zzz"'), findsOneWidget);
    await t.tap(find.text('Clear search and filters'));
    await t.pumpAndSettle();
    expect(find.text('6 parts  ·  1,351 units on hand'), findsOneWidget);
  });

  testWidgets('error with nothing loaded, then retry works', (t) async {
    var fail = true;
    await _pump(
      t,
      InventoryScreen(loader: () async {
        if (fail) throw Exception('Could not reach the server.');
        return _sample;
      }),
      const Size(1366, 760),
    );
    expect(find.text('Could not load stock levels'), findsOneWidget);
    await _save(t, 'error_1366');
    fail = false;
    await t.tap(find.text('Try again'));
    await t.pumpAndSettle();
    expect(find.text('Cable 8ft'), findsOneWidget);
  });

  testWidgets('empty sheet', (t) async {
    await _pump(t, InventoryScreen(loader: () async => const []), const Size(1366, 760));
    expect(find.text('No parts on the inventory sheet'), findsOneWidget);
    await _save(t, 'empty_1366');
  });

  // Real data shots at several sizes (no overflow), only when the data file is there.
  final data = File('build/stock_shots/data.json');
  if (data.existsSync()) {
    final real = [for (final e in jsonDecode(data.readAsStringSync()) as List) StockItem.fromJson(Map<String, dynamic>.from(e as Map))];
    for (final size in const [Size(1920, 940), Size(1366, 768), Size(1280, 600), Size(1000, 760), Size(420, 760)]) {
      final w = size.width.toInt();
      testWidgets('real data $w', (t) async {
        await _pump(t, InventoryScreen(loader: () async => real), size);
        await _save(t, 'real_${w}x${size.height.toInt()}');
      });
    }
    testWidgets('real data, low filter, 1366', (t) async {
      await _pump(t, InventoryScreen(loader: () async => real), const Size(1366, 768));
      await t.tap(find.bySemanticsLabel(RegExp(r'^Low stock, ')));
      await t.pumpAndSettle();
      await _save(t, 'real_low_1366');
    });
    testWidgets('real data, larger text, 1366', (t) async {
      t.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
      await _pump(t, InventoryScreen(loader: () async => real), const Size(1366, 768));
      await _save(t, 'real_text130_1366');
    });
  }
}
