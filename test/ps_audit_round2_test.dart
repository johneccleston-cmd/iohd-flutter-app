// Products & Services audit, round 2 (2026-11-20): each defect found in real Chrome or in the logic review, pinned.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/services/line_items_api.dart';
import 'package:iohd_desktop/utils/line_item_math.dart';
import 'package:iohd_desktop/widgets/line_items_editor.dart';

import 'dashboard_harness.dart';

Future<void> _pump(WidgetTester t, Widget editor) async {
  t.view.physicalSize = const Size(1500, 1000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
      home: Scaffold(body: SingleChildScrollView(child: editor)),
    ),
  );
  await t.pumpAndSettle();
}

const _spring = CatalogEntry(key: 'cat:1', name: 'Torsion Spring', sku: 'TS-1', rate: 89, cost: 19.5);
const _seal = CatalogEntry(key: 'cat:2', name: 'Weather Seal', sku: 'WS-1', rate: 42, cost: 11.8);

Future<List<CatalogEntry>> _search(String q) async => const [_spring, _seal];

final _searchBox = find.byWidgetPredicate((w) => w is TextField && (w.decoration?.hintText ?? '').startsWith('Add a line'));

Future<void> _typeSearch(WidgetTester t, String q) async {
  await t.tap(_searchBox);
  await t.pump();
  await t.enterText(_searchBox, q);
  await t.pump(const Duration(milliseconds: 250)); // the search's pause
  await t.pumpAndSettle();
}

LineItemsEditor _editor(List<LineDraft> lines) =>
    LineItemsEditor(lines: lines, taxRate: null, editable: true, showCost: false, onPreviewSave: () {}, search: _search);

void main() {
  setUpAll(loadDashFonts);

  group('Add a line search', () {
    testWidgets('Enter adds the highlighted match and the search keeps the keyboard for the next one', (t) async {
      await _pump(t, _editor(const [LineDraft(name: 'Door', rate: 900, quantity: 1)]));
      await _typeSearch(t, 'spr');
      // Enter in the box: the field's "done" action. It used to unfocus the box right after the pick.
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pumpAndSettle();
      expect(find.text('Torsion Spring'), findsWidgets, reason: 'the first match went in');
      expect(t.widget<TextField>(_searchBox).focusNode!.hasFocus, isTrue, reason: 'the next one can be typed straight away');
    });

    testWidgets('the pointer moves the one highlight: Enter then adds the row under the pointer', (t) async {
      await _pump(t, _editor(const [LineDraft(name: 'Door', rate: 900, quantity: 1)]));
      await _typeSearch(t, 'se');
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(t.getCenter(find.text('Weather Seal').last));
      await t.pumpAndSettle();
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pumpAndSettle();
      expect(find.text('Weather Seal'), findsWidgets, reason: 'the row under the pointer went in');
      expect(find.text('Torsion Spring'), findsNothing, reason: 'not the first row, which used to stay lit as well');
    });

    testWidgets('the search box keeps its full height on desktop (standard density, like the button beside it)', (t) async {
      await _pump(t, _editor(const [LineDraft(name: 'Door', rate: 900, quantity: 1)]));
      expect(t.widget<TextField>(_searchBox).decoration!.visualDensity, VisualDensity.standard);
    });
  });

  group('a figure that is not a number', () {
    testWidgets('typed a key at a time, "12..5" never becomes the rate; leaving puts the good one back and says so', (t) async {
      await _pump(t, _editor(const [LineDraft(name: 'Opener', rate: 689, quantity: 1)]));
      await t.tap(find.text('689.00'));
      await t.pumpAndSettle();
      final rate = find.byKey(const ValueKey('line-0-rate'));
      for (final typed in ['1', '12', '12.', '12..', '12..5']) {
        await t.enterText(rate, typed);
        await t.pump();
      }
      await t.pumpAndSettle(); // the totals count to their figure
      expect(find.text(r'$12.00'), findsNothing, reason: 'the last keystroke that read as a number is not charged');
      expect(find.text(r'$689.00'), findsWidgets, reason: 'the line is as it was before this edit');
      await t.testTextInput.receiveAction(TextInputAction.done); // Enter keeps; Esc cancels since decision A1 (2026-11-23)
      await t.pumpAndSettle();
      expect(find.text('689.00'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline_rounded), findsNothing);
      expect(find.textContaining("Line 1: that wasn't a number, so it keeps its rate \$689.00"), findsOneWidget);
    });

    testWidgets('Tab out of a bad figure: the box shows the good one again', (t) async {
      await _pump(t, _editor(const [LineDraft(name: 'Opener', rate: 689, quantity: 2)]));
      await t.tap(find.text('2.00'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('line-0-qty')), '3..');
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pumpAndSettle();
      expect(t.widget<TextField>(find.byKey(const ValueKey('line-0-qty'))).controller!.text, '2.00');
      expect(find.text(r'$1,378.00'), findsWidgets);
    });
  });

  group('tax', () {
    test('a tax that was only added is never a line\'s by default (USER RULE 2026-11-20)', () {
      const rogers = SalesTax('Sales Tax (State, County, & Local Use Tax, Rogers)', 9.5);
      const bentonville = SalesTax('Sales Tax (State, County, & Local Use Tax, Bentonville)', 9.5, onRecord: true);
      expect(SalesTax.resolve('Sales Tax (State, County, & Local Use Tax, Bentonville)', [rogers]), isNull,
          reason: 'a record with no tax of its own: adding Rogers taxes nothing');
      expect(SalesTax.resolve(null, [rogers]), isNull);
      expect(SalesTax.resolve('Sales Tax', [bentonville, rogers]), bentonville, reason: 'the record\'s own tax still applies');
      expect(SalesTax.resolve(rogers.name, [bentonville, rogers]), rogers, reason: 'and a line that picked Rogers has it');
    });

    test('the totals agree: an added tax charges nothing until a line picks it', () {
      final t = computeLineTotals(
        const [LineDraft(name: 'Door', rate: 1000, quantity: 1, taxable: true, taxName: 'Sales Tax (State, County, & Local Use Tax, Bentonville)')],
        null,
        taxRates: {'Sales Tax (State, County, & Local Use Tax, Rogers)': 9.5},
      );
      expect(t.taxCents, 0);
    });

    test('Service Fusion\'s exempt code is not a tax', () {
      expect(sfTaxed('No Sales Tax Applied'), isFalse);
      expect(sfTaxed('  no sales tax applied '), isFalse);
      expect(sfTaxed(null), isFalse);
      expect(sfTaxed(''), isFalse);
      expect(sfTaxed('Sales Tax (State, County, & Local Use Tax, Rogers)'), isTrue);
      expect(sfTaxed('Sales Tax'), isTrue);
    });
  });

  group('service packages', () {
    test('the list reads a package\'s price as its page does: the sum at its starting quantities, not its first rate', () {
      final e = CatalogEntry.fromJson({
        'key': 'sf:residential service',
        'name': 'Residential Service',
        'kind': 'service',
        'rate': 250, // the server's old rule: the first rate's price
        'cost': 60,
        'rates': [
          {'name': 'Springs', 'qty': 0, 'rate': 250, 'cost': 60},
          {'name': 'Dispatch & Evaluation', 'qty': 1, 'rate': 89, 'cost': 25},
          {'name': 'Travel', 'qty': 2, 'rate': 15.5, 'cost': null},
        ],
      });
      expect(e.rate, 120, reason: '0 x 250 + 1 x 89 + 2 x 15.50');
      expect(e.cost, 25);
    });

    test('a service without rates and a product keep the server\'s price', () {
      expect(CatalogEntry.fromJson({'key': 'sf:x', 'name': 'X', 'kind': 'service', 'rate': 99}).rate, 99);
      expect(CatalogEntry.fromJson({'key': 'cat:1', 'name': 'P', 'rate': 5.25, 'cost': 1}).rate, 5.25);
    });
  });
}
