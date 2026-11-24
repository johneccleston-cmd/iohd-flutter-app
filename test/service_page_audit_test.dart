// The service page audit (2026-11-24): each fix with the test that shows it.
//   - A problem found by Save stays with its row through Copy, Move and Delete (Copy left later rows' marks one row off).
//   - The page's read of the service landing while editing no longer replaces the version the edits started from, so a
//     save by someone else in that moment is caught at Save instead of written over.
//   - A save whose info went through and whose rates failed still tells the Services Catalog list.
//   - The quantity arrows count an empty box as 0 (up gave 2).
//   - Switching a commission's % / $ checks it again for the new unit (it used to clear the problem either way).
//   - At 50 products the search gives way to a note; deleting the product the keyboard was on moves it to the search.
//   flutter test test/service_page_audit_test.dart

import 'dart:async';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/service_detail_screen.dart';
import 'package:iohd_desktop/services/line_items_api.dart';
import 'package:iohd_desktop/widgets/line_table_style.dart';

import 'dashboard_harness.dart';

const _spring = CatalogEntry(key: 'inv:7', name: 'Torsion Spring 250', kind: 'product', rate: 60, cost: 22, taxable: true);

const _package = CatalogEntry(
  key: 'sf:residential service',
  name: 'Residential Service',
  kind: 'service',
  category: 'Service Packages',
  group: 'Service Packages',
  description: 'Diagnose and service a residential garage door.',
  rates: [
    ServiceRate(name: 'Visit', qty: 1, rate: 75, cost: 15),
    ServiceRate(name: 'Tune-Up', qty: 0, rate: 129, cost: 30),
    ServiceRate(name: 'Repair', qty: 0, rate: 185, cost: 45),
  ],
  products: [ServiceProduct(key: 'inv:7', name: 'Torsion Spring 250', qty: 2, entry: _spring)],
);

Future<void> _open(
  WidgetTester t, {
  CatalogEntry service = _package,
  CatalogEntry? initial,
  Future<({List<CatalogEntry> entries, bool canSeeCost, int historyDays})> Function()? loader,
  Future<CatalogEntry> Function(String, Map<String, dynamic>)? save,
  Future<CatalogEntry> Function(String, List<ServiceRate>)? saveRates,
  Future<CatalogEntry> Function(String, List<ServiceProduct>)? saveProducts,
  bool settle = true,
}) async {
  t.view.physicalSize = const Size(1366, 1400);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
      home: ServiceDetailScreen(
        key: UniqueKey(),
        serviceKey: service.key,
        initial: initial,
        loader: loader ?? () async => (entries: [service], canSeeCost: true, historyDays: 540),
        saver: save,
        ratesSaver: saveRates,
        productsSaver: saveProducts,
        productSearch: (q) async => const [_spring],
      ),
    ),
  );
  if (settle) {
    await t.pumpAndSettle();
  } else {
    await t.pump();
  }
}

Future<void> _edit(WidgetTester t) async {
  await t.tap(find.text('Edit'));
  await t.pumpAndSettle();
}

Future<void> _save(WidgetTester t) async {
  await t.tap(find.text('Save'));
  await t.pumpAndSettle();
}

Finder _field(String key) => find.byKey(ValueKey('field:$key'));

/// Whether the box around [key]'s field is drawn red (a problem found by Save).
bool _red(WidgetTester t, String key) {
  final box = find.ancestor(of: _field(key), matching: find.byWidgetPredicate((w) => w.runtimeType.toString() == '_RateBox'));
  return (t.widget(box.first) as dynamic).error as bool;
}

/// Drags the handle keyed [key] by [dy] px with the mouse, as a person does (an edited row is 45 px).
Future<void> _dragBy(WidgetTester t, String key, double dy) async {
  final handle = find.byKey(ValueKey(key));
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

/// The rate names in the order the table shows them.
List<String> _rateNames(WidgetTester t) {
  final rows = [
    for (var i = 0; _field('rate$i.name').evaluate().isNotEmpty; i++)
      (t.widget(_field('rate$i.name')) as TextField).controller!.text,
  ];
  return rows;
}

Future<void> _rateMenu(WidgetTester t, int i, String action) async {
  await t.ensureVisible(find.byKey(ValueKey('rate-menu:$i')));
  await t.tap(find.byKey(ValueKey('rate-menu:$i')));
  await t.pumpAndSettle();
  await t.tap(find.text(action).last);
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await loadDashFonts();
    await dashSignIn();
  });

  testWidgets('a problem found by Save stays with its row through Copy, Move and Delete', (t) async {
    await _open(t);
    await _edit(t);
    await t.enterText(_field('rate2.name'), '');
    await t.pump();
    await _save(t);
    expect(_red(t, 'rate2.name'), isTrue);

    // Copy the first rate: the copy goes in at row 1, so the unnamed rate is now row 3, and only it is red.
    await _rateMenu(t, 0, 'Copy');
    expect(_red(t, 'rate3.name'), isTrue, reason: 'the unnamed rate moved down one row');
    expect(_red(t, 'rate2.name'), isFalse, reason: 'Tune-Up has its name');
    expect(_red(t, 'rate1.name'), isFalse, reason: 'the copy of Visit has its name');

    // Drag it up one row: the mark goes with it (a move used to drop it).
    await _dragBy(t, 'rate-drag:3', -60);
    expect(_red(t, 'rate2.name'), isTrue);
    expect(_red(t, 'rate3.name'), isFalse);

    // Delete another row: the mark stays on the unnamed rate, now one row higher.
    await _rateMenu(t, 0, 'Delete');
    expect(_red(t, 'rate1.name'), isTrue);
    expect(find.text('Give the rate a name.'), findsOneWidget);

    // Delete the unnamed rate itself: its problem goes with it.
    await _rateMenu(t, 1, 'Delete');
    expect(find.text('Give the rate a name.'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets("someone else's save that lands while the page is being edited is caught at Save, not written over", (t) async {
    // The list's copy of the service opens the page at once; the page's own read comes back after Edit was pressed,
    // with a version someone else saved meanwhile.
    final theirs = CatalogEntry(
      key: _package.key,
      name: 'Residential Service (theirs)',
      kind: 'service',
      category: _package.category,
      group: _package.group,
      description: _package.description,
      rates: _package.rates,
      products: _package.products,
      editedFields: const ['name'],
      editedBy: 'Bella',
      editedAt: '2026-11-24T15:00:00Z',
    );
    final firstRead = Completer<({List<CatalogEntry> entries, bool canSeeCost, int historyDays})>();
    var reads = 0;
    final sent = <Map<String, dynamic>>[];
    await _open(
      t,
      initial: _package,
      loader: () => reads++ == 0 ? firstRead.future : Future.value((entries: [theirs], canSeeCost: true, historyDays: 540)),
      save: (key, fields) async {
        sent.add(fields);
        return _package;
      },
      settle: false,
    );
    await t.pump(const Duration(milliseconds: 300));
    await _edit(t);
    await t.enterText(_field('description'), 'Mine.');
    firstRead.complete((entries: [theirs], canSeeCost: true, historyDays: 540));
    await t.pumpAndSettle();
    await _save(t);
    expect(find.byKey(const ValueKey('conflict-notice')), findsOneWidget);
    expect(sent, isEmpty, reason: 'nothing is saved over their version until the person decides');
  });

  testWidgets('a save whose info went through and whose rates failed still updates the Services Catalog list', (t) async {
    final savedInfo = CatalogEntry(
      key: _package.key,
      name: 'Residential Service Plus',
      kind: 'service',
      category: _package.category,
      group: _package.group,
      rates: _package.rates,
      products: _package.products,
    );
    serviceChanged.value = null;
    await _open(
      t,
      save: (key, fields) async => savedInfo,
      saveRates: (key, rates) async => throw const LineItemsException('The server took too long to answer. Try again.'),
    );
    await _edit(t);
    await t.enterText(_field('name'), 'Residential Service Plus');
    await t.enterText(_field('rate0.rate'), '80');
    await t.pump();
    await _save(t);
    expect(find.textContaining('took too long'), findsOneWidget);
    expect(serviceChanged.value?.name, 'Residential Service Plus');
  });

  testWidgets('the up arrow on an empty quantity gives 1, not 2', (t) async {
    await _open(t);
    await _edit(t);
    for (final key in const ['rate0.qty', 'product0.qty']) {
      await t.ensureVisible(_field(key));
      await t.tap(_field(key));
      await t.enterText(_field(key), '');
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await t.pump();
      expect((t.widget(_field(key)) as TextField).controller!.text, '1', reason: key);
    }
  });

  testWidgets('switching a commission between % and \$ checks it again for the new unit', (t) async {
    await _open(t);
    await _edit(t);
    // 150 on the $75 visit: too much as a percentage, and too much as dollars too (more than the line's rate).
    await t.enterText(_field('rate0.commission'), '150');
    await t.pump();
    await _save(t);
    expect(find.textContaining('A percentage is 100 at most.'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('field:rate0.commissionType:fixed')));
    await t.pumpAndSettle();
    // Still wrong as $150 on a $75 line: the box stays red and now says why for dollars.
    expect(find.textContaining('A percentage is 100 at most.'), findsNothing);
    expect(find.textContaining("can't be more than the line's rate"), findsOneWidget);
    expect(_red(t, 'rate0.commission'), isTrue);
    // Back to %, and 15: fine, nothing red.
    await t.tap(find.byKey(const ValueKey('field:rate0.commissionType:percent')));
    await t.enterText(_field('rate0.commission'), '15');
    await t.pumpAndSettle();
    expect(_red(t, 'rate0.commission'), isFalse);
  });

  testWidgets('at 50 products the search gives way to a note', (t) async {
    final full = CatalogEntry(
      key: _package.key,
      name: _package.name,
      kind: 'service',
      category: _package.category,
      group: _package.group,
      rates: _package.rates,
      products: [for (var i = 0; i < kMaxServiceProducts; i++) ServiceProduct(key: 'inv:$i', name: 'Part $i', entry: CatalogEntry(key: 'inv:$i', name: 'Part $i', kind: 'product', rate: 1))],
    );
    await _open(t, service: full);
    await _edit(t);
    expect(find.byKey(const ValueKey('products-cap')), findsOneWidget);
    expect(find.byKey(const ValueKey('product-search')), findsNothing);
    await t.ensureVisible(find.byKey(const ValueKey('product-menu:0')));
    await t.tap(find.byKey(const ValueKey('product-menu:0')));
    await t.pumpAndSettle();
    await t.tap(find.text('Delete').last);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('products-cap')), findsNothing);
    expect(find.byKey(const ValueKey('product-search')), findsOneWidget);
  });

  testWidgets('deleting the product the keyboard was on moves the keyboard to the product search', (t) async {
    await _open(t);
    await _edit(t);
    await t.ensureVisible(find.byKey(const ValueKey('product-menu:0')));
    await t.tap(find.byKey(const ValueKey('product-menu:0')));
    await t.pumpAndSettle();
    await t.tap(find.text('Delete').last);
    await t.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'product search');
  });

  testWidgets('an emptied quantity box shows no total (it read as 1 x the price)', (t) async {
    await _open(t);
    await _edit(t);
    expect(find.text(r'$120.00'), findsWidgets, reason: r'the spring: 2 x $60.00');
    await t.enterText(_field('product0.qty'), '');
    await t.enterText(_field('rate0.qty'), '');
    await t.pump();
    expect(find.text(r'$60.00'), findsOneWidget, reason: r'only the PRICE box; TOTAL is not 1 x $60.00');
    // The RATE box holds "75.00" (its "$" is drawn beside it), so a "$75.00" anywhere would be the TOTAL.
    expect(find.text(r'$75.00'), findsNothing, reason: r'TOTAL is not 1 x $75.00');
    expect((t.widget(_field('rate0.rate')) as TextField).controller!.text, '75.00');
  });

  // The bug the user found (2026-11-24): the product search is the last thing on the page, so the page could not scroll
  // it up to make room under it, and the results were squeezed into the strip between the box and the window's bottom.
  for (final size in const [Size(1366, 768), Size(1280, 600), Size(1920, 940)]) {
    testWidgets('the product search results open in full under the box at ${size.width.toInt()}x${size.height.toInt()}', (t) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final many = [for (var i = 1; i <= 8; i++) CatalogEntry(key: 'inv:p$i', name: 'Opener Part $i', kind: 'product', rate: 10.0 * i, sku: 'SKU-$i')];
      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
          home: Column(
            children: [
              Container(height: 60, color: const Color(0xFF14213D)), // the app's nav bar
              Expanded(
                child: ServiceDetailScreen(
                  key: UniqueKey(),
                  serviceKey: _package.key,
                  loader: () async => (entries: [_package], canSeeCost: true, historyDays: 540),
                  productSearch: (q) async => many,
                ),
              ),
            ],
          ),
        ),
      );
      await t.pumpAndSettle();
      await _edit(t);
      final search = find.descendant(of: find.byKey(const ValueKey('product-search')), matching: find.byType(TextField));
      // Scrolled down to it, as a person does (the box at the bottom of the window), then clicked and typed in.
      await t.ensureVisible(search);
      await t.pumpAndSettle();
      await t.tap(search);
      await t.enterText(search, 'opener');
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();
      final list = find.ancestor(of: find.text('Opener Part 1'), matching: find.byType(ListView));
      expect(list, findsOneWidget);
      final rect = t.getRect(list);
      final box = t.getRect(search);
      expect(rect.top, greaterThanOrEqualTo(box.bottom - 1), reason: 'the list drops down under the box, not over it');
      expect(rect.bottom, lessThanOrEqualTo(size.height), reason: 'the list is inside the window');
      expect(rect.height, greaterThanOrEqualTo(300), reason: 'room for several results, not a strip (it was ${rect.height.round()} px)');
      // The first results are on screen, whole.
      for (final name in const ['Opener Part 1', 'Opener Part 2', 'Opener Part 3', 'Opener Part 4']) {
        final r = t.getRect(find.text(name));
        expect(r.top >= rect.top && r.bottom <= rect.bottom, isTrue, reason: '$name is in view');
      }
    });
  }

  testWidgets('Alt+Up / Alt+Down in a product\'s row moves it, and the keyboard stays in its qty box', (t) async {
    const two = CatalogEntry(
      key: 'sf:two',
      name: 'Two Package',
      kind: 'service',
      rates: [ServiceRate(name: 'Visit', qty: 1, rate: 75)],
      products: [
        ServiceProduct(key: 'inv:7', name: 'Torsion Spring 250', qty: 2, entry: _spring),
        ServiceProduct(key: 'inv:8', name: 'Lift Cable', qty: 1, entry: CatalogEntry(key: 'inv:8', name: 'Lift Cable', kind: 'product', rate: 18)),
      ],
    );
    await _open(t, service: two);
    await _edit(t);
    await t.ensureVisible(_field('product1.qty'));
    await t.tap(_field('product1.qty'));
    await t.pump();
    await t.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await t.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await t.pumpAndSettle();
    expect((t.widget(_field('product0.qty')) as TextField).controller!.text, '1', reason: 'Lift Cable (qty 1) is first now');
    expect(t.widget<Text>(find.byKey(const ValueKey('product-name:0'))).data, 'Lift Cable');
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'product quantity');
    final focused = find.byWidgetPredicate((w) => w is TextField && w.focusNode?.hasFocus == true);
    expect(t.widget<TextField>(focused).controller!.text, '1', reason: "the keyboard went with the cable's qty box");
  });

  testWidgets('rates move by dragging their handle (no Move up / Move down in the menu); Save sends the new order', (t) async {
    final sent = <List<ServiceRate>>[];
    await _open(t, saveRates: (key, rates) async {
      sent.add(rates);
      return _package;
    });
    await _edit(t);
    expect(_rateNames(t), ['Visit', 'Tune-Up', 'Repair']);
    await _dragBy(t, 'rate-drag:2', -105); // Repair up two rows
    expect(_rateNames(t), ['Repair', 'Visit', 'Tune-Up']);
    await _dragBy(t, 'rate-drag:0', 60); // and back down one
    expect(_rateNames(t), ['Visit', 'Repair', 'Tune-Up']);
    await t.tap(find.byKey(const ValueKey('rate-menu:0')));
    await t.pumpAndSettle();
    expect(find.text('Move up'), findsNothing);
    expect(find.text('Move down'), findsNothing);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    await _save(t);
    expect(sent.single.map((r) => r.name), ['Visit', 'Repair', 'Tune-Up']);
  });

  testWidgets("Alt+Up in a rate's row moves it, and the keyboard stays in the box it was in", (t) async {
    await _open(t);
    await _edit(t);
    await t.tap(_field('rate1.rate'));
    await t.pump();
    await t.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await t.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await t.pumpAndSettle();
    expect(_rateNames(t), ['Tune-Up', 'Visit', 'Repair']);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'rate rate');
    final focused = find.byWidgetPredicate((w) => w is TextField && w.focusNode?.hasFocus == true);
    expect(t.widget<TextField>(focused).key, const ValueKey('field:rate0.rate'), reason: "Tune-Up's rate box, now in row 0");
  });

  testWidgets('the handles sit in the rows\' left margin: no name box or name moves when Edit is pressed', (t) async {
    await _open(t);
    final readRate = t.getTopLeft(find.text('Visit')).dx;
    final readProduct = t.getTopLeft(find.byKey(const ValueKey('product-name:0'))).dx;
    await _edit(t);
    final box = t.getRect(find.ancestor(of: _field('rate0.name'), matching: find.byWidgetPredicate((w) => w.runtimeType.toString() == '_RateBox')).first);
    final handle = t.getRect(find.byKey(const ValueKey('rate-drag:0')));
    expect(handle.right, lessThanOrEqualTo(box.left + 0.5), reason: 'the rate handle is left of the name box');
    expect(box.left + LineTable.cellX, closeTo(readRate, 1.5), reason: 'the name text starts where it is read');
    expect(t.getTopLeft(find.byKey(const ValueKey('product-name:0'))).dx, closeTo(readProduct, 0.5));
    expect(t.getRect(find.byKey(const ValueKey('product-drag:0'))).right, lessThanOrEqualTo(readProduct));
  });

  testWidgets('a product at qty 0 reads a weight lighter, as a rate at 0 does', (t) async {
    const zero = CatalogEntry(
      key: 'sf:z',
      name: 'Z Package',
      kind: 'service',
      rates: [ServiceRate(name: 'Visit', qty: 1, rate: 75)],
      products: [ServiceProduct(key: 'inv:7', name: 'Torsion Spring 250', qty: 0, entry: _spring)],
    );
    await _open(t, service: zero);
    final name = t.widget<Text>(find.byKey(const ValueKey('product-name:0')));
    expect(name.style?.fontWeight, FontWeight.w500);
  });
}
