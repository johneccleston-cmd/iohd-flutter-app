// The line-item table on its own (lib/widgets/line_items_editor.dart): the rules that live in the widget rather than in
// line_item_math.dart. Undo only puts a line back into the draft it came from; profit under a source's own figures
// counts its discounts and charges but never its tax or what it doesn't itemize; a line's tax label is the tax the
// totals charge it at; each line's margin.
//   flutter test test/line_items_editor_test.dart

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/utils/line_item_math.dart';
import 'package:iohd_desktop/widgets/line_items_editor.dart';

import 'dashboard_harness.dart';

const _rogers = 'Sales Tax (State, County, & Local Use Tax, Rogers)';

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

/// An editor whose Edit / Cancel the test drives, as the page does with the ribbon's Edit Job and the strip's Cancel.
class _Host extends StatefulWidget {
  final List<LineDraft> lines;
  final double? taxRate;
  const _Host(this.lines, {this.taxRate});

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  bool editing = true;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      TextButton(onPressed: () => setState(() => editing = !editing), child: Text(editing ? 'Stop editing' : 'Start editing')),
      LineItemsEditor(lines: widget.lines, taxRate: widget.taxRate, editable: editing, showCost: false, onPreviewSave: () {}),
    ],
  );
}

/// The page's Service Fusion table: its lines are made afresh on every build (equal lines, a new list), and anything on
/// the page can rebuild it. [swap] gives it different lines, as a Refresh that found a change would.
class _Rebuilder extends StatefulWidget {
  final bool editable;
  const _Rebuilder({this.editable = false});

  @override
  State<_Rebuilder> createState() => _RebuilderState();
}

class _RebuilderState extends State<_Rebuilder> {
  int builds = 0;
  bool swapped = false;

  List<LineDraft> get _lines => [
    LineDraft(name: 'Door', description: 'SIZE : 16x7\nMODEL : 4300', rate: 900, quantity: 1, source: 'service_fusion'),
    LineDraft(name: swapped ? 'Opener (changed in Service Fusion)' : 'Opener', rate: 600, quantity: 1, source: 'service_fusion'),
  ];

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text('Builds $builds'),
      TextButton(onPressed: () => setState(() => builds++), child: const Text('Rebuild the page')),
      TextButton(onPressed: () => setState(() => swapped = true), child: const Text('New lines')),
      LineItemsEditor(lines: _lines, taxRate: null, editable: widget.editable, showCost: false, onPreviewSave: () {}),
    ],
  );
}

void main() {
  setUpAll(loadDashFonts);

  testWidgets('a page rebuild with the same lines leaves the table as it is: an open description stays open', (t) async {
    await _pump(t, const _Rebuilder());
    await t.tap(find.text('Description'));
    await t.pumpAndSettle();
    expect(find.textContaining('MODEL : 4300'), findsOneWidget);
    await t.tap(find.text('Rebuild the page'));
    await t.pumpAndSettle();
    expect(find.text('Builds 1'), findsOneWidget);
    expect(find.textContaining('MODEL : 4300'), findsOneWidget, reason: 'equal lines are not new lines');
    // Lines that really changed still replace the table.
    await t.tap(find.text('New lines'));
    await t.pumpAndSettle();
    expect(find.text('Opener (changed in Service Fusion)'), findsOneWidget);
  });

  testWidgets('a page rebuild while editing keeps the open line open and what was typed', (t) async {
    await _pump(t, const _Rebuilder(editable: true));
    await t.tap(find.text('Opener'));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('line-1-rate')), '650');
    await t.pump();
    // The draft differs from the lines now; a rebuild with the same (saved) lines must not touch it.
    await t.tap(find.text('Rebuild the page'));
    await t.pumpAndSettle();
    expect(find.text(r'$650.00'), findsWidgets, reason: 'the draft survived');
  });

  group('quantities always show two decimals', () {
    const lines = [
      LineDraft(name: 'Door', rate: 1000, quantity: 1),
      LineDraft(name: 'Stop mold', rate: 0.61, quantity: 68.57),
      LineDraft(name: 'Tek screws', rate: 0.21, quantity: 2400),
      LineDraft(name: 'Spring', rate: 89, quantity: 1.5),
      LineDraft(name: 'Info line', rate: 10, quantity: 0),
    ];

    testWidgets('read-only', (t) async {
      await _pump(t, const LineItemsEditor(lines: lines, taxRate: null, editable: false, showCost: false));
      for (final q in ['1.00', '68.57', '2,400.00', '1.50', '0.00']) {
        expect(find.text(q), findsOneWidget, reason: q);
      }
      // Fractional quantities keep their exact amount: 68.57 x 0.61 = 41.8277 -> $41.83, 2,400 x 0.21 = $504.00.
      expect(find.text(r'$41.83'), findsOneWidget);
      expect(find.text(r'$504.00'), findsOneWidget);
      expect(find.text(r'$133.50'), findsOneWidget, reason: '1.5 x 89');
    });

    testWidgets('editing: the boxes, the open field, the arrows, and at most two decimals typed', (t) async {
      await _pump(t, const _Host(lines));
      for (final q in ['1.00', '68.57', '2,400.00', '1.50', '0.00']) {
        expect(find.text(q), findsOneWidget, reason: 'closed box $q');
      }
      await t.tap(find.text('1.50'));
      await t.pumpAndSettle();
      final field = find.byKey(const ValueKey('line-3-qty'));
      expect(t.widget<TextField>(field).controller!.text, '1.50', reason: 'the open field starts as the box showed it');
      await t.tap(find.descendant(of: find.byType(LineItemsEditor), matching: find.byTooltip('One more')).at(3));
      await t.pump();
      expect(t.widget<TextField>(field).controller!.text, '2.50');
      // A third decimal can't be typed: what is shown is what is charged.
      await t.enterText(field, '2.125');
      await t.pump();
      expect(t.widget<TextField>(field).controller!.text, '2.12');
      expect(find.text(r'$188.68'), findsWidgets, reason: '2.12 x 89');
      // Leaving the field tidies it to two decimals.
      await t.enterText(field, '3.5');
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(t.widget<TextField>(field).controller!.text, '3.50');
      // Closed again, the box shows it the same way.
      await t.testTextInput.receiveAction(TextInputAction.done); // Enter keeps; Esc cancels since decision A1 (2026-11-23)
      await t.pumpAndSettle();
      expect(find.text('3.50'), findsOneWidget);
    });
  });

  testWidgets('the keyboard reaches every value: Tab onto a closed line\'s name opens that line there', (t) async {
    await _pump(
      t,
      const _Host([
        LineDraft(name: 'Door', rate: 900, quantity: 1),
        LineDraft(name: 'Opener', rate: 600, quantity: 1),
      ]),
    );
    // From the first line's eye, the next stop is its name: the line opens with the name field focused.
    final eye = find.bySemanticsLabel('Show to the customer').first;
    await t.tap(eye);
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pumpAndSettle();
    final name = find.byKey(const ValueKey('line-0-name'));
    expect(name, findsOneWidget, reason: 'the line opened');
    expect(t.widget<TextField>(name).focusNode!.hasFocus, isTrue);
  });

  // Found by the second-pass review (2026-11-13).
  group('closed lines while editing', () {
    const lines = [
      LineDraft(name: 'Door', description: 'SIZE : 16x7', rate: 900, quantity: 1),
      LineDraft(name: 'Opener', rate: 600, quantity: 1),
    ];
    Finder field(int i, String f) => find.byKey(ValueKey('line-$i-$f'));

    testWidgets('Description and the arrows inside a closed box do their own thing, not open the line', (t) async {
      await _pump(t, const _Host(lines));
      await t.tap(find.byKey(const ValueKey('line-0-more')));
      await t.pumpAndSettle();
      expect(find.textContaining('SIZE : 16x7'), findsOneWidget, reason: 'the description shows');
      expect(field(0, 'name'), findsNothing, reason: 'the line stays closed');
      await t.tap(find.byTooltip('One more').first);
      await t.pumpAndSettle();
      expect(find.text('2.00'), findsOneWidget, reason: 'stepped');
      expect(field(0, 'qty'), findsNothing, reason: 'still closed');
      // A line with no description: Description opens the line at an empty description, ready to type in.
      await t.tap(find.byKey(const ValueKey('line-1-more')));
      await t.pumpAndSettle();
      expect(field(1, 'description'), findsOneWidget);
      expect(t.widget<TextField>(field(1, 'description')).focusNode!.hasFocus, isTrue, reason: 'not the name');
    });

    testWidgets('a line closed with a bad number keeps its good figure and says so; reopened, it starts clean', (t) async {
      await _pump(t, const _Host(lines));
      await t.tap(find.text('Opener'));
      await t.pumpAndSettle();
      await t.enterText(field(1, 'qty'), '2..5');
      await t.pump();
      await t.testTextInput.receiveAction(TextInputAction.done); // Enter keeps; Esc cancels since decision A1 (2026-11-23)
      await t.pumpAndSettle();
      // Audit round 2 (2026-11-20): nothing half-typed is ever charged, so the closed line has nothing bad left on it.
      expect(find.byIcon(Icons.error_outline_rounded), findsNothing, reason: 'the line kept its good figure');
      expect(find.textContaining("Line 2: that wasn't a number, so it keeps its quantity 1.00"), findsOneWidget);
      await t.tap(find.text('Opener'));
      await t.pumpAndSettle();
      expect(t.widget<TextField>(field(1, 'qty')).controller!.text, '1.00');
      expect(find.byIcon(Icons.error_outline_rounded), findsNothing, reason: 'no good figure in a red box');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.byIcon(Icons.error_outline_rounded), findsNothing, reason: 'and no mark once it closes clean');
      expect(find.text(r'$1,500.00'), findsWidgets, reason: 'the total never moved');
    });

    testWidgets('a quantity that really has a third decimal keeps it while another digit is changed', (t) async {
      await _pump(t, const _Host([LineDraft(name: 'Seal', rate: 100, quantity: 2.125)]));
      await t.tap(find.text('2.125'));
      await t.pumpAndSettle();
      await t.enterText(field(0, 'qty'), '3.125');
      await t.pump();
      expect(t.widget<TextField>(field(0, 'qty')).controller!.text, '3.125');
      expect(find.text(r'$312.50'), findsWidgets);
    });

    // Was "kept and flagged" while the server refused negative quantities. Service Fusion keeps returns and credits as
    // -1 x the price (11 lines on prod, one on an open 2026 job), so a copy of its lines has them: now a minus is read as
    // one, and still never dropped (which would flip the sign).
    testWidgets('a minus typed into a quantity is kept and read as minus (a return), never dropped (which would flip the sign)', (t) async {
      await _pump(t, const _Host([LineDraft(name: 'Seal', rate: 100, quantity: 1)]));
      await t.tap(find.text('Seal'));
      await t.pumpAndSettle();
      await t.enterText(field(0, 'qty'), '-2');
      await t.pump();
      expect(t.widget<TextField>(field(0, 'qty')).controller!.text, '-2');
      expect(find.text(r'$200.00'), findsNothing, reason: 'not read as 2');
      expect(find.text(r'-$200.00'), findsWidgets, reason: 'read as minus two');
      await t.testTextInput.receiveAction(TextInputAction.done); // Enter keeps; Esc cancels since decision A1 (2026-11-23)
      await t.pumpAndSettle();
      expect(find.text('-2.00'), findsOneWidget, reason: 'closed, it reads as every quantity does');
      expect(find.byIcon(Icons.error_outline_rounded), findsNothing, reason: 'not marked as a bad number');
    });

    testWidgets('the tax select in an open line keeps the line open, and its pick lands', (t) async {
      await _pump(t, const _Host([LineDraft(name: 'Seal', rate: 100, quantity: 1, taxable: true)], taxRate: 10));
      await t.tap(find.text('Seal'));
      await t.pumpAndSettle();
      await t.tap(find.text('Taxable'));
      await t.pumpAndSettle();
      await t.tap(find.text('No tax').last);
      await t.pumpAndSettle();
      expect(field(0, 'name'), findsOneWidget, reason: 'the line is still open');
      expect(find.text('No tax'), findsOneWidget);
    });
  });

  // The old 9,999.999 cap cut Service Fusion's percentage lines (35,125.3 x -$0.10 on estimate 1044450930; the largest on
  // prod is 49,376). Now the editor takes what the server takes: up to 999,999.999 either way.
  group('quantities above 9,999.999', () {
    Finder field(int i, String f) => find.byKey(ValueKey('line-$i-$f'));
    TextField qty(WidgetTester t) => t.widget<TextField>(field(0, 'qty'));

    testWidgets('35,125.3 can be typed, is worked to the cent and tidies to two decimals', (t) async {
      await _pump(t, const _Host([LineDraft(name: '10% Discount (Doors & Openers)', rate: -0.1, quantity: 1)]));
      await t.tap(find.text('10% Discount (Doors & Openers)'));
      await t.pumpAndSettle();
      await t.enterText(field(0, 'qty'), '35125.3');
      await t.pump();
      expect(find.text(r'-$3,512.53'), findsWidgets, reason: '35,125.3 x -\$0.10');
      await t.testTextInput.receiveAction(TextInputAction.done); // Enter keeps; Esc cancels since decision A1 (2026-11-23)
      await t.pumpAndSettle();
      expect(find.text('35,125.30'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline_rounded), findsNothing);
    });

    testWidgets('typed with grouping and a third decimal it had: "49,376.125" x -\$0.05 = -\$2,468.81', (t) async {
      await _pump(t, const _Host([LineDraft(name: '5% Discount', rate: -0.05, quantity: 49376.125)]));
      expect(find.text('49,376.125'), findsOneWidget, reason: 'a real third decimal is shown, not rounded away');
      expect(find.text(r'-$2,468.81'), findsWidgets, reason: '-\$2,468.80625 to the cent, half away from zero');
      await t.tap(find.text('5% Discount'));
      await t.pumpAndSettle();
      expect(qty(t).controller!.text, '49,376.125');
      await t.enterText(field(0, 'qty'), '49,376.12');
      await t.pump();
      expect(find.text(r'-$2,468.81'), findsWidgets, reason: '49,376.12 x -\$0.05 = -\$2,468.806');
    });

    testWidgets('the most a line holds is 999,999.999 either way; one more is marked and changes nothing', (t) async {
      await _pump(t, const _Host([LineDraft(name: 'Bulk screws', rate: 1, quantity: 1)]));
      await t.tap(find.text('Bulk screws'));
      await t.pumpAndSettle();
      await t.enterText(field(0, 'qty'), '999999.99');
      await t.pump();
      expect(find.text(r'$999,999.99'), findsWidgets);
      await t.enterText(field(0, 'qty'), '1000000');
      await t.pumpAndSettle(); // the totals count to their figure
      expect(find.text(r'$1,000,000.00'), findsNothing, reason: 'over the limit: not taken');
      // Audit round 2 (2026-11-20): while the box holds no good number the line is as it was before this edit (typed a
      // key at a time, "1000000" used to leave it at 100,000, the last keystroke that read as a number).
      expect(find.text(r'$999,999.99'), findsNothing);
      expect(find.text(r'$1.00'), findsWidgets, reason: 'the quantity from before this edit');
      await t.enterText(field(0, 'qty'), '-1000000');
      await t.pump();
      expect(find.text(r'-$1,000,000.00'), findsNothing);
      await t.testTextInput.receiveAction(TextInputAction.done); // Enter keeps; Esc cancels since decision A1 (2026-11-23)
      await t.pumpAndSettle();
      expect(find.byIcon(Icons.error_outline_rounded), findsNothing, reason: 'closed, the line kept its good figure');
      expect(find.textContaining("that wasn't a number, so it keeps its quantity 1.00"), findsOneWidget);
    });

    testWidgets('the arrows step past 9,999 (they used to stop there), and down through 0 into a return', (t) async {
      await _pump(t, const _Host([LineDraft(name: 'Wire', rate: 0.5, quantity: 9999.5)]));
      await t.tap(find.byTooltip('One more').first);
      await t.pumpAndSettle();
      expect(find.text('10,000.50'), findsOneWidget);
      expect(find.text(r'$5,000.25'), findsWidgets);
      await t.pumpWidget(const SizedBox());
      // Round 4 (user 2026-11-13): "stepping between positive, zero, and negative values". Down used to stop at 0.
      await _pump(t, const _Host([LineDraft(name: 'Wire', rate: 0.5, quantity: 0.5)]));
      await t.tap(find.byTooltip('One less').first);
      await t.pumpAndSettle();
      expect(find.text('-0.50'), findsOneWidget, reason: 'one less than 0.50 is -0.50, two decimals, sign kept');
      expect(find.text(r'-$0.25'), findsWidgets, reason: '-0.50 x \$0.50');
    });

    testWidgets('quantity x rate over \$9,999,999.99 (the server\'s line limit) is marked and not taken, either way round', (t) async {
      await _pump(t, const _Host([LineDraft(name: 'Wire rope', rate: 11, quantity: 1)]));
      await t.tap(find.text('Wire rope'));
      await t.pumpAndSettle();
      await t.enterText(field(0, 'qty'), '999999');
      await t.pump();
      expect(find.text(r'$10,999,989.00'), findsNothing, reason: '999,999 x \$11 is over the line limit');
      expect(find.text(r'$11.00'), findsWidgets, reason: 'the line keeps its last good quantity');
      await t.enterText(field(0, 'qty'), '909090.9');
      await t.pump();
      expect(find.text(r'$9,999,999.90'), findsWidgets, reason: 'just under the limit is fine');
      await t.enterText(field(0, 'rate'), '12');
      await t.pump();
      expect(find.text(r'$10,909,090.80'), findsNothing, reason: 'a rate that takes it over is not taken either');
      expect(find.text(r'$9,999,999.90'), findsWidgets);
    });

    // Found in a real browser (2026-11-13): with the limit at 999,999.999, "-999,999.99" was cut to "-999,999.9" in its box.
    testWidgets('a quantity is never cut short in its box, however wide', (t) async {
      await _pump(t, const _Host([LineDraft(name: 'Wire rope', rate: 0.01, quantity: -999999.99), LineDraft(name: 'Odd', rate: 0.01, quantity: -999999.999)]));
      for (final q in ['-999,999.99', '-999,999.999']) {
        final p = t.renderObject<RenderParagraph>(find.descendant(of: find.text(q), matching: find.byType(RichText)));
        // Cut short = laid out narrower than the text is (RenderParagraph then clips it).
        expect(p.size.width, greaterThanOrEqualTo(p.getMaxIntrinsicWidth(double.infinity) - 0.5), reason: '$q is drawn whole');
      }
    });

    // Found in a real browser (2026-11-13): up from a return did nothing although its arrow looked live.
    testWidgets('from a return (-3): up steps toward 0 and on past it, down further into the return, by arrow and by key', (t) async {
      await _pump(t, const _Host([LineDraft(name: 'Tek Screws', rate: 0.21, quantity: -3)]));
      await t.tap(find.byTooltip('One less').first);
      await t.pumpAndSettle();
      expect(find.text('-4.00'), findsOneWidget, reason: 'down from a negative: one more returned');
      expect(find.text(r'-$0.84'), findsWidgets);
      await t.tap(find.byTooltip('One more').first);
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('One more').first);
      await t.pumpAndSettle();
      expect(find.text('-2.00'), findsOneWidget, reason: 'up: toward 0');
      expect(find.text(r'-$0.42'), findsWidgets);
      await t.tap(find.text('Tek Screws'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('line-0-qty')));
      await t.pumpAndSettle();
      await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await t.pumpAndSettle();
      expect(qty(t).controller!.text, '1.00', reason: 'the Up key does what the arrow does, through 0');
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.pumpAndSettle();
      expect(qty(t).controller!.text, '0.00', reason: 'two decimals at 0 too');
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.pumpAndSettle();
      expect(qty(t).controller!.text, '-2.00', reason: 'and Down on below 0');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.text('-2.00'), findsOneWidget, reason: 'the closed line keeps the sign');
      expect(find.text(r'-$0.42'), findsWidgets);
    });

    testWidgets('a fractional quantity steps by whole ones and keeps its fraction either side of 0', (t) async {
      await _pump(t, const _Host([LineDraft(name: 'Chain', rate: 4, quantity: 1.25)]));
      for (final want in ['0.25', '-0.75', '-1.75']) {
        await t.tap(find.byTooltip('One less').first);
        await t.pumpAndSettle();
        expect(find.text(want), findsOneWidget, reason: 'one less: $want');
      }
      expect(find.text(r'-$7.00'), findsWidgets, reason: '-1.75 x \$4');
    });

    testWidgets('the arrows stop at the quantity limit either way, and at the line-amount limit', (t) async {
      await _pump(t, const _Host([LineDraft(name: 'Washers', rate: 0.01, quantity: -999999.5)]));
      await t.tap(find.byTooltip('One less').first);
      await t.pumpAndSettle();
      expect(find.text('-999,999.50'), findsOneWidget, reason: 'one less would pass -999,999.999');
      await t.pumpWidget(const SizedBox());
      // 9,999,999.99 / 11 = 909,090.9: one more than 909,090 would take quantity x rate past the line limit.
      await _pump(t, const _Host([LineDraft(name: 'Wire rope', rate: -11, quantity: -909090)]));
      await t.tap(find.byTooltip('One less').first);
      await t.pumpAndSettle();
      expect(find.text('-909,090.00'), findsOneWidget, reason: 'a negative x a negative is checked the same way');
      await t.tap(find.byTooltip('One more').first);
      await t.pumpAndSettle();
      expect(find.text('-909,089.00'), findsOneWidget);
      expect(find.text(r'$9,999,979.00'), findsWidgets, reason: '-909,089 x -\$11 is a positive amount');
    });
  });

  testWidgets('a negative amount (Service Fusion\'s "10% Discount" item at -\$0.10 each) reads as money off', (t) async {
    await _pump(
      t,
      const LineItemsEditor(
        lines: [LineDraft(name: '10% Discount (Doors & Openers)', rate: -0.1, quantity: 35125.3, source: 'service_fusion')],
        taxRate: null,
        editable: false,
        showCost: false,
        fixedAmounts: [-351253],
      ),
    );
    expect(find.text('35,125.30'), findsOneWidget);
    final amount = t.widget<Text>(find.text(r'-$3,512.53').first);
    expect(amount.style?.color, isNot(const Color(0xFF0F172A)), reason: 'not in plain ink');
  });

  test('SalesTax.resolve: the named tax, else the record\'s only tax, else none', () {
    const rogers = SalesTax(_rogers, 10, onRecord: true);
    const benton = SalesTax('Sales Tax (State & County, Benton)', 6.5, onRecord: true);
    expect(SalesTax.resolve(_rogers, [rogers]), rogers);
    expect(SalesTax.resolve('Sales Tax', [rogers]), rogers, reason: 'Service Fusion\'s lines often say just "Sales Tax"');
    expect(SalesTax.resolve(null, [rogers]), rogers);
    expect(SalesTax.resolve('Sales Tax', [rogers, benton]), isNull, reason: 'two taxes on the record: can\'t tell');
    expect(SalesTax.resolve(benton.name, [rogers, benton]), benton);
    expect(SalesTax.resolve(_rogers, const []), isNull);
  });

  testWidgets('Undo after the table went read-only (Cancel) puts nothing back', (t) async {
    await _pump(
      t,
      const _Host([
        LineDraft(name: 'Door', rate: 900, quantity: 1),
        LineDraft(name: 'Opener', rate: 600, quantity: 1),
      ]),
    );
    await t.tap(find.byKey(const ValueKey('line-1-actions')));
    await t.pumpAndSettle();
    await t.tap(find.text('Delete'));
    await t.pumpAndSettle(); // the snack bar is fully in
    expect(find.text('Opener'), findsNothing);
    expect(find.text('Undo'), findsOneWidget);
    // Cancel: the table is rebuilt from the original lines, the opener included.
    await t.tap(find.text('Stop editing'));
    await t.pump();
    expect(find.text('Opener'), findsOneWidget);
    // The snack bar is still up (the page hides it on Cancel; this checks the table's own guard).
    await t.tap(find.text('Undo'));
    await t.pumpAndSettle();
    expect(find.text('Opener'), findsOneWidget, reason: 'not twice');
    expect(find.text(r'$1,500.00'), findsWidgets, reason: 'the total is the original one');
  });

  testWidgets('Undo while still editing puts the line back where it was', (t) async {
    await _pump(
      t,
      const _Host([
        LineDraft(name: 'Door', rate: 900, quantity: 1),
        LineDraft(name: 'Opener', rate: 600, quantity: 1),
        LineDraft(name: 'Install', rate: 300, quantity: 1),
      ]),
    );
    await t.tap(find.byKey(const ValueKey('line-1-actions')));
    await t.pumpAndSettle();
    await t.tap(find.text('Delete'));
    await t.pumpAndSettle(); // the snack bar is fully in
    await t.tap(find.text('Undo'));
    await t.pumpAndSettle();
    final ys = ['Door', 'Opener', 'Install'].map((n) => t.getTopLeft(find.text(n)).dy).toList();
    expect(ys, orderedEquals([...ys]..sort()));
  });

  testWidgets('profit under a source\'s own figures: discounts and charges count, tax and the unitemized rest don\'t', (t) async {
    await _pump(
      t,
      const LineItemsEditor(
        lines: [
          LineDraft(name: 'Door', rate: 700, cost: 400, quantity: 1, taxable: true),
          LineDraft(name: 'Install', rate: 300, cost: 200, quantity: 1),
        ],
        taxRate: null,
        editable: false,
        showCost: true,
        summary: [
          LineSummaryRow('Items', 100000, kind: SummaryKind.items),
          LineSummaryRow('Sales tax 10%', 7000, kind: SummaryKind.tax),
          LineSummaryRow('Builder discount', -5000, kind: SummaryKind.discount),
          LineSummaryRow('Trip charge', 4000, kind: SummaryKind.charge),
          LineSummaryRow('Not itemized in Service Fusion', 2500, kind: SummaryKind.unitemized),
          LineSummaryRow('Total', 108500, kind: SummaryKind.total),
        ],
        totalLabel: 'Job total',
      ),
    );
    // Before tax: 1,000 - 50 + 40 = 990. Cost 600. Profit 390 = 39.4%.
    expect(find.text(r'$600.00'), findsOneWidget, reason: 'job cost');
    expect(find.text(r'$390.00'), findsOneWidget, reason: 'gross profit');
    expect(find.text('(39.4%)'), findsOneWidget);
    expect(find.text(r'$1,085.00'), findsOneWidget, reason: 'the source\'s own total, unchanged');
    expect(find.text('Job total'), findsOneWidget);
  });

  testWidgets('each line\'s tax says what the totals charge it at; no line has a margin of its own', (t) async {
    await _pump(
      t,
      const LineItemsEditor(
        lines: [
          LineDraft(name: 'Door', rate: 1000, cost: 600, quantity: 1, taxable: true, taxName: 'Sales Tax'),
          LineDraft(name: 'Paint touch-up', rate: 60, cost: 95, quantity: 1),
          LineDraft(name: 'Keypad', rate: 79, quantity: 1, taxable: true),
          LineDraft(kind: LineKind.discount, name: 'Loyal customer', rate: 50),
        ],
        taxRate: null,
        editable: false,
        showCost: true,
        taxOptions: [SalesTax(_rogers, 10, onRecord: true)],
      ),
    );
    expect(find.text('Rogers'), findsNWidgets(2), reason: 'a line saying "Sales Tax", and one with no name, on a record with one tax');
    expect(find.text('No tax'), findsOneWidget);
    // No margin per line (user 2026-11-13): not the door's 40.0%, not the touch-up's -58.3%. The summary keeps the gross
    // profit and its %.
    expect(find.text('40.0%'), findsNothing);
    expect(find.text('-58.3%'), findsNothing);
    expect(find.text('MARGIN'), findsNothing);
    expect(find.text('Gross profit'), findsOneWidget);
    // The keypad has no cost: the gross profit is still filled in, on the known costs (USER RULE 2026-11-24).
    expect(find.text('—'), findsNothing);
    expect(find.text('Discount'), findsNothing, reason: 'view mode: no Discount / Fee / Tax marks (user 2026-11-24)');
    // A line with no cost: nothing says how many have none, and the gross profit is still filled in, on the
    // known costs (USER RULE 2026-11-24; Services Catalog Phase 2 had left it a dash).
    expect(find.textContaining('no cost'), findsNothing); // USER RULE 2026-11-24: no note
    expect(find.byKey(const ValueKey('gross-profit-unknown')), findsNothing);
  });
}
