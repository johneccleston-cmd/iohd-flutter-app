// $0.00 lines and unknown costs in the line-item table (Services Catalog Phase 2, 2026-11-18). A line at $0.00 with a
// quantity carries an amber "Confirm no charge" until someone confirms it, explicitly, one line at a time: in the
// preview for the draft only (and taken off again when the line's name, quantity or price changes), on a saved option
// through the server. Accept is held back while one isn't confirmed, as the server refuses it. A line with no cost
// leaves the gross profit unknown ("—", and how many lines have none), never a 100% margin.
//   flutter test test/line_items_zero_price_test.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/utils/line_item_math.dart';
import 'package:iohd_desktop/widgets/line_items_editor.dart';

import 'dashboard_harness.dart';
import 'job_page_fixture.dart';

const _confirm = r'$0.00 · Confirm no charge';
const _notConfirmed = r'$0.00 · Not confirmed as no charge';

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

LineItemsEditor _preview(List<LineDraft> lines, {bool showCost = false}) =>
    LineItemsEditor(lines: lines, taxRate: null, editable: true, showCost: showCost, onPreviewSave: () {}, search: (q) async => const []);

const _lines = [
  LineDraft(name: 'Haul away old door', quantity: 1, rate: 0, cost: 0),
  LineDraft(name: 'Spare rollers (next visit)', quantity: 0, rate: 0, cost: 0),
  LineDraft(name: 'Gate repair', quantity: 1, cost: 0),
  LineDraft(name: 'Door', quantity: 1, rate: 900, cost: 400),
];

Future<void> _confirmFirst(WidgetTester t) async {
  await t.tap(find.text(_confirm));
  await t.pumpAndSettle();
  await t.tap(find.text('Confirm no charge'));
  await t.pumpAndSettle();
}

Future<void> _type(WidgetTester t, String field, String text) async {
  await t.enterText(find.byKey(ValueKey('line-0-$field')), text);
  await t.pump(const Duration(milliseconds: 50));
}

void main() {
  setUpAll(() async {
    await loadDashFonts();
    await dashSignIn();
  });

  group('the chip', () {
    testWidgets('only on a \$0.00 line with a quantity: not at quantity 0, not on a line not priced yet', (t) async {
      await _pump(t, _preview(_lines));
      expect(find.text(_confirm), findsOneWidget);
      final chip = t.getRect(find.byKey(const ValueKey('zero-chip')));
      final name = t.getRect(find.text('Haul away old door'));
      final next = t.getRect(find.text('Spare rollers (next visit)'));
      expect(chip.top, greaterThan(name.bottom), reason: 'under the \$0 line');
      expect(chip.bottom, lessThan(next.top), reason: 'and above the next line');
      expect(find.textContaining('1 line at \$0.00 not confirmed'), findsOneWidget);

      // A saved option read-only, where it can't be confirmed from here: it still says so, without the action.
      await _pump(t, const LineItemsEditor(lines: _lines, taxRate: null, editable: false, showCost: false));
      expect(find.text(_notConfirmed), findsOneWidget);
      expect(find.text(_confirm), findsNothing);
      expect(find.textContaining('1 line at \$0.00 not confirmed'), findsOneWidget);

      // Service Fusion's own lines, read-only, are shown as Service Fusion has them.
      await _pump(
        t,
        const LineItemsEditor(lines: _lines, taxRate: null, editable: false, showCost: false, summary: [LineSummaryRow('Total', 90000, kind: SummaryKind.total)]),
      );
      expect(find.byKey(const ValueKey('zero-chip')), findsNothing);
      expect(find.textContaining('not confirmed'), findsNothing);
    });

    testWidgets('the dialog: "Confirm no charge" confirms it for the draft, with who; "Enter a price" opens the price', (t) async {
      await _pump(t, _preview(_lines));
      await t.tap(find.text(_confirm));
      await t.pumpAndSettle();
      expect(find.text("Charge nothing for 'Haul away old door'?"), findsOneWidget);
      expect(find.text('It will show \$0.00 to the customer.'), findsOneWidget);
      expect(find.text('Enter a price'), findsOneWidget);
      await t.tap(find.text('Enter a price'));
      await t.pumpAndSettle();
      final rate = find.descendant(of: find.byKey(const ValueKey('line-0-rate')), matching: find.byType(EditableText), matchRoot: true);
      expect(t.widget<EditableText>(rate).focusNode.hasFocus, isTrue, reason: 'ready to type the price');
      expect(find.text(_confirm), findsOneWidget, reason: 'nothing confirmed');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();

      await _confirmFirst(t);
      expect(find.text(_confirm), findsNothing);
      expect(find.text('No charge · confirmed by Test Admin'), findsOneWidget);
      expect(find.textContaining('not confirmed'), findsNothing);
    });

    testWidgets('changing the quantity, the price or the name takes the confirmation off; other changes keep it', (t) async {
      await _pump(t, _preview(_lines, showCost: true));
      Future<void> open() async {
        await t.tap(find.text('Haul away old door'));
        await t.pumpAndSettle();
      }

      await _confirmFirst(t);
      // Its cost is not what was confirmed.
      await open();
      await _type(t, 'cost', '25');
      await t.testTextInput.receiveAction(TextInputAction.done); // Enter keeps; Esc cancels since decision A1 (2026-11-23)
      await t.pumpAndSettle();
      expect(find.text('No charge · confirmed by Test Admin'), findsOneWidget);

      await open();
      await _type(t, 'qty', '2');
      await t.testTextInput.receiveAction(TextInputAction.done); // Enter keeps; Esc cancels since decision A1 (2026-11-23)
      await t.pumpAndSettle();
      expect(find.text(_confirm), findsOneWidget, reason: 'quantity changed');

      await _confirmFirst(t);
      await open();
      await _type(t, 'rate', '5');
      await _type(t, 'rate', '0');
      await t.testTextInput.receiveAction(TextInputAction.done); // Enter keeps; Esc cancels since decision A1 (2026-11-23)
      await t.pumpAndSettle();
      expect(find.text(_confirm), findsOneWidget, reason: 'price changed (and back)');

      await _confirmFirst(t);
      await open();
      await _type(t, 'name', 'Haul away both doors');
      await t.testTextInput.receiveAction(TextInputAction.done); // Enter keeps; Esc cancels since decision A1 (2026-11-23)
      await t.pumpAndSettle();
      expect(find.text(_confirm), findsOneWidget, reason: 'name changed');
      expect(find.textContaining('confirmed by'), findsNothing);
    });

    testWidgets('saved lines outside the preview: confirming asks the page with the line', (t) async {
      final asked = <LineDraft>[];
      await _pump(
        t,
        LineItemsEditor(
          lines: const [LineDraft(id: 'li7', name: 'Haul away old door', quantity: 1, rate: 0), LineDraft(name: 'Unsaved \$0 line', quantity: 1, rate: 0)],
          taxRate: null,
          editable: false,
          showCost: false,
          onConfirmZero: (l) async => asked.add(l),
        ),
      );
      expect(find.text(_confirm), findsOneWidget, reason: 'only a line with an id can be confirmed on the server');
      expect(find.text(_notConfirmed), findsOneWidget);
      await t.tap(find.text(_confirm));
      await t.pumpAndSettle();
      await t.tap(find.text('Enter a price'));
      await t.pumpAndSettle();
      expect(asked, isEmpty);
      await _confirmFirst(t);
      expect(asked.single.id, 'li7');
    });
  });

  group('unknown cost', () {
    // USER RULE 2026-11-24 ("Gross profit needs to be filled in too"): the summary's profit and margin are worked out on
    // the known costs while a line has none (Services Catalog Phase 2 had made it a dash); Job cost's tooltip says how
    // many lines have no cost. The option tabs still show no margin then (next test).
    testWidgets('profit is filled in on the known costs, with how many lines have no cost', (t) async {
      for (final editable in [false, true]) {
        await _pump(
          t,
          LineItemsEditor(
            lines: const [LineDraft(name: 'Install', quantity: 1, rate: 300), LineDraft(name: 'Door', quantity: 1, rate: 700, cost: 400)],
            taxRate: null,
            editable: editable,
            showCost: true,
            onPreviewSave: editable ? () {} : null,
          ),
        );
        expect(find.byKey(const ValueKey('gross-profit-unknown')), findsNothing, reason: 'editable: $editable');
        expect(find.textContaining('no cost'), findsNothing); // USER RULE 2026-11-24: no note
        // $1,000 less the door's $400: $600, 60.0%.
        expect(find.text('(60.0%)'), findsOneWidget, reason: 'editable: $editable');
      }
      // Nothing costed at all: the whole price is profit on what is known (the tooltip says no line has a cost).
      await _pump(t, const LineItemsEditor(lines: [LineDraft(name: 'Install', quantity: 1, rate: 300), LineDraft(name: 'Haul away', quantity: 2, rate: 50)], taxRate: null, editable: false, showCost: true));
      expect(find.textContaining('no cost'), findsNothing); // USER RULE 2026-11-24: no note
      expect(find.text('(100.0%)'), findsOneWidget);
      expect(find.byKey(const ValueKey('gross-profit-unknown')), findsNothing);
      // Every cost known: the profit and its margin are back.
      await _pump(t, const LineItemsEditor(lines: [LineDraft(name: 'Install', quantity: 1, rate: 300, cost: 0), LineDraft(name: 'Door', quantity: 1, rate: 700, cost: 400)], taxRate: null, editable: false, showCost: true));
      expect(find.byKey(const ValueKey('gross-profit-unknown')), findsNothing);
      expect(find.text('(60.0%)'), findsOneWidget);
      expect(find.textContaining('no cost'), findsNothing);
    });

    testWidgets('the margin the table reports to the page is unknown too', (t) async {
      final heard = <double?>[];
      await _pump(
        t,
        LineItemsEditor(
          lines: const [LineDraft(name: 'Install', quantity: 1, rate: 300), LineDraft(name: 'Door', quantity: 1, rate: 700, cost: 400)],
          taxRate: null,
          editable: false,
          showCost: true,
          onFigures: (total, margin) => heard.add(margin),
        ),
      );
      expect(heard, isNotEmpty);
      expect(heard.last, isNull);
    });
  });

  group('on the estimate page', () {
    List<Map<String, dynamic>> option() => [
      {'id': 'z1', 'kind': 'item', 'name': 'Haul away old door', 'quantity': 1, 'rate': 0, 'cost': 0, 'taxable': false, 'source': 'manual'},
      {'id': 'z2', 'kind': 'item', 'name': 'Torsion Spring', 'quantity': 1, 'rate': 89, 'cost': 19.5, 'taxable': true, 'source': 'catalog'},
    ];

    testWidgets('Accept is held back, with the reason, until the \$0 line is confirmed; confirming it saves through the server', (t) async {
      final s = FakeJobServer();
      s.addOption(kEstimateId, 'Ready', option());
      await pumpJobPage(t, s, id: kEstimateId, body: () async {
        expect(find.textContaining('1 line at \$0.00 not confirmed'), findsOneWidget);
        await t.tap(find.widgetWithText(OutlinedButton, 'Accept'));
        await settle(t, frames: 4);
        expect(find.text('Line 1 ("Haul away old door") is \$0.00 and not confirmed as no charge. Confirm it or enter a price before accepting.'), findsOneWidget);
        expect(find.text('Accept option'), findsNothing, reason: 'no confirm dialog');

        // Outside the preview, on the saved option: the server records it.
        await t.tap(find.text(_confirm));
        await settle(t, frames: 4);
        await t.tap(find.text('Confirm no charge'));
        await settle(t);
        expect(s.requests.where((r) => r.endsWith('/items/z1/confirm-zero')), hasLength(1));
        expect(find.text('No charge · confirmed by Dana Whitfield'), findsOneWidget);
        expect(find.textContaining('not confirmed'), findsNothing);

        await t.tap(find.widgetWithText(OutlinedButton, 'Accept'));
        await settle(t, frames: 4);
        expect(find.text('Accept option'), findsOneWidget, reason: 'now it can be accepted');
      });
      expect(s.requests.where((r) => r.endsWith('/accept')), isEmpty);
      expect(s.requests.where((r) => r.endsWith('/items')), isEmpty, reason: 'line items are never saved from here');
    });

    testWidgets('in the preview a confirmation is the draft\'s only: nothing is sent, and Exit preview drops it', (t) async {
      final s = FakeJobServer();
      s.addOption(kEstimateId, 'Ready', option());
      await pumpJobPage(t, s, id: kEstimateId, body: () async {
        await t.tap(find.text('Edit Estimate'));
        await settle(t, frames: 6);
        await t.tap(find.text(_confirm));
        await settle(t, frames: 4);
        await t.tap(find.text('Confirm no charge'));
        await settle(t, frames: 6);
        expect(find.text('No charge · confirmed by Test Admin'), findsOneWidget);
        await t.tap(find.text('Exit preview'));
        await settle(t, frames: 6);
        expect(find.text(_confirm), findsOneWidget, reason: 'back to the saved option');
      });
      expect(s.requests.where((r) => r.contains('confirm-zero')), isEmpty);
      expect(s.requests.where((r) => r.endsWith('/items')), isEmpty);
    });

    testWidgets('the Service Fusion option: a cost of \$0 is no cost, so its tab shows no margin', (t) async {
      final s = FakeJobServer(); // estimate 1093839956: its install line has a Service Fusion cost of 0
      await pumpJobPage(t, s, id: kEstimateId, body: () async {
        final tab = find.byKey(const ValueKey('option-tab-sf'));
        expect(find.descendant(of: tab, matching: find.textContaining('margin')), findsNothing);
        // The summary's gross profit is filled in all the same, on the known costs (USER RULE 2026-11-24).
        expect(find.byKey(const ValueKey('gross-profit-unknown')), findsNothing);
        expect(find.textContaining('no cost'), findsNothing); // USER RULE 2026-11-24: no note
        expect(find.text('(100.0%)'), findsNothing);
      });
    });
  });
}
