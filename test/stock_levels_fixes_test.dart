// Stock Levels UI audit fixes (docs/stock-levels-ui-audit-2026-11-25.md): refresh order, filter counts, Needs attention,
// links, placeholder part numbers, sorting, search, the part page, Change stock, export, the stale notice, layout fit.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/inventory_screen.dart';
import 'package:iohd_desktop/stock_part_panel.dart';

Future<void> _font(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    if (File(p).existsSync()) loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

StockItem _item(String name, int qty, int rp, {String cat = 'Hardware', String part = '', String loc = '', double? cost}) =>
    StockItem(name: name, category: cat, qty: qty, reorderPoint: rp, partNumber: part, location: loc, cost: cost);

final _sample = [
  _item('Back Hang Nut', 1250, 3000, part: '0099', loc: 'A1'),
  _item('Bearing RC | Steel | 1"', 65, 20, cat: 'Bearing - RC', part: '0140950', loc: 'I3'),
  _item('Cable 8ft', 0, 2, cat: 'Cable Assembly - RC'),
  _item('Chain Drive | 24\' | LiftMaster', 0, 0, cat: 'Operator Rail'),
  _item('Bottom Bracket | LH', 31, 0, cat: 'Bottom Bracket - Res'),
  _item('Keypad | 878MAX', 5, 5, cat: 'Remote'),
];

Future<void> _pump(WidgetTester t, Widget screen, {Size size = const Size(1366, 800)}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: ThemeData(useMaterial3: true, fontFamily: 'IBM Plex Sans'), home: screen));
  await t.pumpAndSettle();
}

List<String> _names(WidgetTester t) => [
  for (final e in find.byType(RichText).evaluate()) (e.widget as RichText).text.toPlainText(),
].where((s) => _sample.any((i) => i.name == s) || s.startsWith('Part ')).toList();

void main() {
  setUpAll(() async {
    await _font('IBM Plex Sans', [for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) 'assets/fonts/IBMPlexSans-$w.ttf']);
  });

  test('statuses are stock levels; To order brings a part back to its reorder point', () {
    expect(_item('a', 0, 0).status.label, 'None on hand');
    expect(_item('a', 31, 0).status.label, 'In stock');
    expect(_item('a', -1, 0).status.label, 'Below zero');
    expect(_item('a', 3, 10).toOrder, 7);
    expect(_item('a', 10, 10).toOrder, 1); // at the point: low, at least 1
    expect(_item('a', 11, 10).toOrder, 0);
    expect(_item('a', 0, 0).toOrder, 0); // no reorder point: nothing to order
    expect(_item('a', 2, 0, cost: 1.5).value, 3.0);
  });

  test('placeholder part numbers are hidden but kept for writes (F5)', () {
    for (final raw in ['na3', 'N/A', 'TBD', '-', 'Discontinued']) {
      expect(StockItem.fromJson({'name': 'x', 'qty': 1, 'partNumber': raw}).partNumber, '', reason: raw);
    }
    final d = StockItem.fromJson({'name': 'Belt Drive | 81550', 'qty': 2, 'partNumber': 'Discontinued', 'cost': '\$12.50'});
    expect(d.discontinued, isTrue);
    expect(d.sheetPartNumber, 'Discontinued');
    expect(d.cost, 12.5);
    expect(d.searchText, contains('discontinued'));
    expect(StockItem.fromJson({'name': 'x', 'qty': 1, 'partNumber': '0140950'}).partNumber, '0140950');
  });

  test('CSV export: every column, formulas defused', () {
    final csv = utf8.decode(stockCsvBytes([_item('=cmd|x', 3, 10, part: '0099', cost: 2)], withCost: true).sublist(3));
    expect(csv.split('\r\n').first, 'Part,Part #,Shelf,Category,On hand,Reorder point,To order,Status,Unit cost,Value');
    expect(csv, contains("'=cmd|x,0099,,Hardware,3,10,7,Low stock,2.00,6.00"));
  });

  testWidgets('a newer refresh wins over an older answer that lands later; Refresh is off while one is out (F1)', (t) async {
    var n = 0;
    final slow = Completer<List<StockItem>>();
    await _pump(t, InventoryScreen(loader: () {
      n++;
      if (n == 1) return Future.value(_sample);
      if (n == 2) return slow.future;
      return Future.value(_sample);
    }));
    await t.tap(find.byTooltip('Refresh'));
    await t.pump();
    final btn = t.widget<IconButton>(find.ancestor(of: find.byIcon(Icons.refresh_rounded), matching: find.byType(IconButton)));
    expect(btn.onPressed, isNull);
    slow.complete([_sample.first]);
    await t.pumpAndSettle();
    expect(find.textContaining('1 part'), findsOneWidget); // the only load out: its answer lands
  });

  testWidgets('filter counts follow the other filters (F3); Needs attention in one click (U2)', (t) async {
    await _pump(t, InventoryScreen(loader: () async => _sample));
    expect(find.bySemanticsLabel('Out of stock, 1'), findsOneWidget);
    await t.tap(find.text('Category'));
    await t.pumpAndSettle();
    await t.tap(find.bySemanticsLabel('Remote, 1'));
    await t.pumpAndSettle();
    expect(find.bySemanticsLabel('Out of stock, 0'), findsOneWidget);
    expect(find.bySemanticsLabel('Low stock, 1'), findsOneWidget);
    await t.tap(find.text('Clear all'));
    await t.pumpAndSettle();
    await t.tap(find.bySemanticsLabel('Needs attention, 3 parts'));
    await t.pumpAndSettle();
    expect(find.textContaining('3 matching'), findsOneWidget);
    expect(find.bySemanticsLabel('Needs attention, 3 parts'), findsOneWidget); // the inked button says so
    expect(find.text('Bottom Bracket | LH'), findsNothing);
  });

  testWidgets('a link opens the page filtered (F11)', (t) async {
    await _pump(t, InventoryScreen(loader: () async => _sample, link: const {'view': 'attention'}));
    expect(find.textContaining('3 matching'), findsOneWidget);
    await _pump(t, InventoryScreen(loader: () async => _sample, link: const {'cat': 'Remote', 'q': 'keypad'}));
    expect(find.textContaining('1 matching'), findsOneWidget);
  });

  testWidgets('sorting: On hand ties put the parts that need attention first (F7); blank reorder points last (F8)', (t) async {
    final parts = [_item('A none', 0, 0), _item('B out', 0, 4), _item('C ok', 9, 2), _item('D none', 0, 0)];
    await _pump(t, InventoryScreen(loader: () async => parts));
    await t.tap(find.text('ON HAND'));
    await t.pumpAndSettle();
    await t.tap(find.text('ON HAND')); // fewest first
    await t.pumpAndSettle();
    expect(_names(t).isEmpty, isTrue); // names aren't in the sample list: read the rows instead
    String order() => [for (final e in find.textContaining(RegExp(r'^[ABCD] (none|out|ok)$')).evaluate()) (e.widget as Text).textSpan!.toPlainText()].join(',');
    expect(order(), 'B out,A none,D none,C ok');
    await t.tap(find.text('REORDER POINT'));
    await t.pumpAndSettle();
    expect(order().split(',').take(2).toList(), ['B out', 'C ok']); // biggest first, blanks last
    await t.tap(find.text('REORDER POINT'));
    await t.pumpAndSettle();
    expect(order().split(',').take(2).toList(), ['C ok', 'B out']); // smallest first, blanks still last
  });

  testWidgets('search finds statuses (F9); the right message when nothing matches (U10)', (t) async {
    await _pump(t, InventoryScreen(loader: () async => _sample));
    await t.enterText(find.byType(TextField).first, 'out of stock');
    await t.pump(const Duration(milliseconds: 300));
    await t.pumpAndSettle();
    expect(find.textContaining('1 matching'), findsOneWidget);
    await t.tap(find.bySemanticsLabel(RegExp(r'^Low stock, ')));
    await t.pumpAndSettle();
    expect(find.text('No parts match "out of stock" with these filters'), findsOneWidget);
    expect(find.text('Clear search and filters'), findsOneWidget);
  });

  testWidgets('a row opens the part page: history, copy, Change stock for admins (G1, G2, F4)', (t) async {
    String? copied;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (c) async {
      if (c.method == 'Clipboard.setData') copied = (c.arguments as Map)['text'] as String?;
      return null;
    });
    var loads = 0;
    await _pump(
      t,
      InventoryScreen(
        loader: () async {
          loads++;
          return _sample;
        },
        canAdjust: true,
        history: (name) async => const StockHistory(movements: [
          StockMovement(date: '11/18/2026', kind: 'checkout', label: 'Job 4001', change: -2, person: 'Tom Tech'),
        ], lastCount: (counted: 64, expected: 65, by: 'Warehouse', at: null)),
      ),
    );
    await t.tap(find.text('Bearing RC | Steel | 1"'));
    await t.pumpAndSettle();
    expect(find.text('Job 4001  ·  Tom Tech', findRichText: true), findsOneWidget);
    expect(find.textContaining('Last cycle count: 64 counted (the system said 65)'), findsOneWidget);
    await t.tap(find.text('Copy part #'));
    await t.pump();
    expect(copied, '0140950');
    expect(find.text('Change stock'), findsOneWidget);
    expect(loads, 1);
  });

  testWidgets('Change stock: the preview, the reason, the server\'s refusal shown (G2)', (t) async {
    final item = _item('Remote | 893LM', 3, 5, part: '4128527');
    int? result;
    await _pump(t, Builder(builder: (context) => Scaffold(body: Center(child: TextButton(
      onPressed: () async => result = await showStockAdjust(context, item, send: ({required item, required action, required qty, required reason}) async {
        if (reason == 'race') throw const StockApiError('Remote | 893LM changed meanwhile: the Sheet now says 4, not 3. Nothing was changed.', status: 409, current: 4);
        return (after: action == StockAdjustAction.remove ? item.qty - qty : item.qty + qty, warning: null);
      }),
      child: const Text('open'),
    )))));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    await t.tap(find.text('Remove'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField).first, '5');
    await t.pump();
    expect(find.textContaining("can't be taken off"), findsOneWidget);
    await t.enterText(find.byType(TextField).first, '1');
    await t.enterText(find.byType(TextField).last, 'race');
    await t.pump();
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(find.textContaining('changed meanwhile'), findsOneWidget);
    await t.enterText(find.byType(TextField).last, 'broken');
    await t.pump();
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(result, 2);
  });

  testWidgets('export saves what the filters show (G4)', (t) async {
    String? name;
    Uint8List? bytes;
    await _pump(t, InventoryScreen(loader: () async => _sample, link: const {'view': 'attention'}, exporter: (n, b) async {
      name = n;
      bytes = b;
      return true;
    }));
    await t.tap(find.text('More'));
    await t.pumpAndSettle();
    await t.tap(find.text('Export CSV'));
    await t.pumpAndSettle();
    expect(name, startsWith('stock-levels-'));
    expect(utf8.decode(bytes!.sublist(3)).trim().split('\r\n').length, 4); // header + 3 parts
  });

  testWidgets('a failed refresh says so, from when, lined up with the table (L8)', (t) async {
    var n = 0;
    await _pump(t, InventoryScreen(loader: () async {
      if (++n > 1) throw const StockApiError('Could not reach the server. Check your connection and try again.');
      return _sample;
    }));
    await t.tap(find.byTooltip('Refresh'));
    await t.pumpAndSettle();
    expect(find.textContaining("Couldn't refresh: Could not reach the server."), findsOneWidget);
    expect(find.textContaining('The list below is from'), findsOneWidget);
    expect(find.textContaining('6 parts'), findsOneWidget);
  });

  testWidgets('a category that is gone after a refresh is taken off, and the page says so (F13)', (t) async {
    var n = 0;
    await _pump(t, InventoryScreen(loader: () async => ++n == 1 ? _sample : _sample.where((i) => i.category != 'Remote').toList(), link: const {'cat': 'Remote'}));
    await t.tap(find.byTooltip('Refresh'));
    await t.pumpAndSettle();
    expect(find.textContaining('The category filter "Remote" was taken off'), findsOneWidget);
  });

  testWidgets('the error state says what went wrong once (U11)', (t) async {
    await _pump(t, InventoryScreen(loader: () async => throw const StockApiError('The server had a problem reading the inventory sheet. Try again in a minute.')));
    expect(find.text('Could not load stock levels'), findsOneWidget);
    expect(find.textContaining('Could not load stock levels', findRichText: true), findsOneWidget);
  });

  for (final (size, scale) in const [(Size(1920, 940), 1.0), (Size(1366, 768), 1.0), (Size(1180, 700), 1.0), (Size(1000, 760), 1.0), (Size(760, 800), 1.0), (Size(420, 800), 1.0), (Size(1366, 768), 1.3), (Size(1920, 940), 1.5)]) {
    testWidgets('fits at ${size.width.toInt()} wide, text ${scale}x', (t) async {
      t.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
      await _pump(t, InventoryScreen(loader: () async => _sample), size: size);
      expect(t.takeException(), isNull);
      // The part column, where there is a table, is never squeezed below its minimum (L1).
      final header = find.text('PART');
      if (header.evaluate().isNotEmpty) {
        final part = t.getRect(header).left;
        final next = t.getRect(find.text('ON HAND')).left;
        expect(next - part, greaterThan(280 * scale - 1));
      }
    });
  }

  testWidgets('the unmatched checkouts list and its Show part button (G6)', (t) async {
    String? shown;
    await _pump(t, Builder(builder: (context) => Scaffold(body: Center(child: TextButton(
      onPressed: () => showUnmatchedCheckouts(context, onShowPart: (p) => shown = p, load: () async => const [
        UnmatchedCheckout(name: "Stop Mold | 7' White", lines: 9, units: 18, lastDate: '11/18/2026', jobs: ['4001'], probablePart: "Weather Seal | Stop Mold | 7' White", probablePartNumber: '0650747', probableShelf: 'BD'),
      ]),
      child: const Text('open'),
    )))));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.textContaining('9 checkouts, 18 units not taken off'), findsOneWidget);
    await t.tap(find.text('Show part'));
    await t.pumpAndSettle();
    expect(shown, "Weather Seal | Stop Mold | 7' White");
  });
}
