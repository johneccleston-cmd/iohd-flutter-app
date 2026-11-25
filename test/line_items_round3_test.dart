// Round 3 of the Products & Services block (2026-11-13): one test for each defect found, measured on the real job and
// estimate pages (glyph positions, not widget boxes, so a pixel off is caught).
//   flutter test test/line_items_round3_test.dart
//
// 1. A click on a qty arrow left a focus ring round the qty box (and a box round the arrow).
// 2. A line opening (Description on a line with none, or any click on a value) moved its figures 3 px left.
// 3. Read-only lines lit up grey under the pointer.
// 4. Headings and values: one column layout for both, checked to the pixel in every configuration.
// 5. Alternating read-only lines (white, then a barely-there cool off-white), no rules between them.
// 6. The estimate's own option is "Estimate Option", marked current, one tab, set apart from the alternatives.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/widgets/dashboard_kit.dart' show DashUi;
import 'package:iohd_desktop/widgets/line_items_editor.dart';

import 'job_page_fixture.dart';

Map<String, dynamic> _l(String name, {double qty = 1, double? rate, double? cost, bool taxable = true, String description = '', String sku = '', bool discount = false}) => {
  'kind': discount ? 'discount' : 'item',
  'name': name,
  'description': description,
  'sku': sku,
  'quantity': qty,
  'rate': rate,
  'cost': cost,
  'taxable': taxable,
  'source': 'catalog',
};

const _specs = 'SIZE : 16\' 0" X 7\' 0"\nMODEL : 4300 | R-Value 12.9 | 25 Ga Steel\nASSEMBLY TYPE : COMPLETE DOOR\nWINDOWS : 4 Stockton';

/// An option with every kind of line: a long description, a short one, none, a fraction, a big quantity, a discount.
void _seed(FakeJobServer s, {String name = 'Insulated', bool recommended = false}) => s.addOption(
  kEstimateId,
  name,
  [
    _l('Clopay | Classic Steel | 4300 | Complete Door | Almond', rate: 1489, cost: 912.4, description: _specs, sku: 'CL-4300-1607'),
    _l('LiftMaster 87504 Smart Opener', rate: 689, cost: 401.37, description: 'Wi-Fi belt drive opener', sku: 'LM-87504'),
    _l('Torsion Spring | 0.250 x 2" x 32"', qty: 2, rate: 89, cost: 19.5),
    _l('Stop Mold | Install New Standard Color', qty: 68.57, rate: 0.61, cost: 0.2),
    _l('Tek Screws | Retail Accessories', qty: 2400, rate: 0.21, cost: 0.04, taxable: false),
    _l('Loyal customer discount', rate: 250, taxable: false, discount: true),
  ],
  taxRate: 10.5,
  recommended: recommended,
);

Finder get _editor => find.byType(LineItemsEditor);

/// Android (the test default) and Windows: a desktop has compact visual density, which changes text fields (the real
/// app on Windows and in a desktop browser runs that way; found in the browser, round 3).
final _platforms = TargetPlatformVariant({TargetPlatform.android, TargetPlatform.windows});
Finder _inTable(Finder f) => find.descendant(of: _editor, matching: f);

Future<void> _toBlock(WidgetTester t) async {
  await t.ensureVisible(find.text('PRODUCTS & SERVICES'));
  await settle(t, frames: 6);
}

Future<void> _edit(WidgetTester t) async {
  await t.tap(find.text('Edit Estimate'));
  await settle(t, frames: 8);
}

/// The ink of every box drawn in the table (borders and fills), to see what changed.
List<String> _paint(WidgetTester t) {
  final out = <String>[];
  for (final e in _inTable(find.byWidgetPredicate((w) => w is AnimatedContainer || w is Container || w is DecoratedBox)).evaluate()) {
    final w = e.widget;
    final d = w is AnimatedContainer ? w.decoration : (w is Container ? w.decoration : (w as DecoratedBox).decoration);
    final color = w is Container ? w.color : null;
    if (d is BoxDecoration) {
      final b = d.border;
      out.add('${d.color}|${b is Border ? '${b.top.color}/${b.top.width}' : ''}|${d.boxShadow?.length ?? 0}');
    } else if (color != null) {
      out.add('$color||0');
    }
  }
  return out;
}

/// Boxes outlined in ink (a focus ring, or the outline of a focused field).
int _inkRings(WidgetTester t) => _inkBoxes(t).toSet().length;

/// Where those are: each one's size and place.
List<String> _inkBoxes(WidgetTester t) {
  final out = <String>[];
  for (final e in _inTable(find.byWidgetPredicate((w) => w is AnimatedContainer || w is Container || w is DecoratedBox)).evaluate()) {
    final w = e.widget;
    final d = w is AnimatedContainer ? w.decoration : (w is Container ? w.decoration : (w as DecoratedBox).decoration);
    if (d is BoxDecoration && d.border is Border && (d.border! as Border).top.color == DashUi.ink && (d.border! as Border).top.width > 0) {
      final box = e.renderObject as RenderBox?;
      out.add(box == null || !box.hasSize ? '?' : '${box.size} at ${box.localToGlobal(Offset.zero)}');
    }
  }
  return out;
}

/// The glyphs' rect of the text in [e] (a Text or an EditableText), in global coordinates.
Rect? _glyphs(Element e) {
  RenderBox? box;
  String text = '';
  void find(Element x) {
    if (box != null) return;
    final ro = x.renderObject;
    if (ro is RenderEditable) {
      box = ro;
      text = ro.text?.toPlainText() ?? '';
      return;
    }
    if (ro is RenderParagraph && x.widget is RichText) {
      box = ro;
      text = ro.text.toPlainText();
      return;
    }
    x.visitChildren(find);
  }

  find(e);
  final b = box;
  if (b == null || text.isEmpty || !b.hasSize) return null;
  final sel = TextSelection(baseOffset: 0, extentOffset: text.length);
  final boxes = b is RenderEditable ? b.getBoxesForSelection(sel) : (b as RenderParagraph).getBoxesForSelection(sel);
  if (boxes.isEmpty) return null;
  var r = boxes.first.toRect();
  for (final x in boxes) {
    r = r.expandToInclude(x.toRect());
  }
  return b.localToGlobal(r.topLeft) & r.size;
}

/// Every text in a column slot of a row, as glyph rects (empty-field placeholders and opacity-0 hints left out).
List<(String, Rect)> _textsIn(Element slot) {
  final out = <(String, Rect)>[];
  void visit(Element e) {
    final w = e.widget;
    if (w is Opacity && w.opacity == 0) return;
    // A line's "S" / "I" mark (USER RULE 2026-11-20) sits before its name, in the item column: the ITEM heading is
    // over the name, so the name is what lines up with it.
    if (w.key == const ValueKey('item-mark') || w.key == const ValueKey('service-mark')) return;
    if (w is InputDecorator) {
      // Only the typed text of a field, not its hint or prefix.
      for (final ed in find.descendant(of: find.byElementPredicate((x) => x == e), matching: find.byType(EditableText)).evaluate()) {
        final r = _glyphs(ed);
        if (r != null) out.add(((ed.widget as EditableText).controller.text, r));
      }
      return;
    }
    if (w is Text) {
      final r = _glyphs(e);
      if (r != null) out.add((w.data ?? w.textSpan?.toPlainText() ?? '', r));
      return;
    }
    e.visitChildren(visit);
  }

  visit(slot);
  return out;
}

/// Each column's heading against each value under it, every column left-aligned (user 2026-11-23): a heading starts
/// where its values start. In a box a figure follows its "$ ": the "$" starts at the heading, and a boxed figure starts
/// one "$ " further in, the same in every column, closed or open (an open field's "$" is its own prefix, not found as a
/// text here, so its figure is checked against that same offset). Returns the misses, each saying how far off it was.
List<String> _misaligned(WidgetTester t, {double tolerance = 0.75}) {
  final misses = <String>[];
  final cols = <String, (double, List<List<(String, Rect)>>)>{};
  for (final col in ['qty', 'rate', 'amount', 'cost', 'tax', 'item']) {
    final slots = _inTable(find.byKey(ValueKey('col-$col'))).evaluate().toList();
    if (slots.isEmpty) continue;
    final head = _textsIn(slots.first);
    expect(head, isNotEmpty, reason: 'the $col heading');
    cols[col] = (head.first.$2.left, [for (final slot in slots.skip(1)) _textsIn(slot)]);
  }
  // How far a boxed figure sits after its "$": measured where both are texts (a closed box).
  double? dollarGap;
  for (final (h, rows) in cols.values) {
    for (final texts in rows) {
      final d = texts.where((x) => x.$1.trim() == r'$').firstOrNull;
      final f = texts.where((x) => x.$1.trim() != r'$').firstOrNull;
      if (d != null && f != null) {
        dollarGap ??= f.$2.left - h;
      }
    }
  }
  String at(double x) => x.toStringAsFixed(2);
  cols.forEach((col, entry) {
    final (h, rows) = entry;
    for (final texts in rows) {
      // A discount's tax cell says "Off the total" (USER RULE 2026-11-20): text, measured like every other value.
      if (texts.isEmpty) continue;
      final d = texts.where((x) => x.$1.trim() == r'$').firstOrNull;
      final f = texts.where((x) => x.$1.trim() != r'$').firstOrNull;
      if (d != null && (d.$2.left - h).abs() > tolerance) misses.add('$col "\$" starts at ${at(d.$2.left)}, heading at ${at(h)}');
      if (f == null) continue;
      final x = f.$2.left;
      final plain = (x - h).abs() <= tolerance;
      final boxed = dollarGap != null && !f.$1.startsWith(r'$') && (x - (h + dollarGap)).abs() <= tolerance;
      if (d != null ? !boxed : !(plain || boxed)) {
        misses.add('$col "${f.$1}" starts at ${at(x)}, heading at ${at(h)}${dollarGap == null ? '' : ' (a boxed figure at ${at(h + dollarGap)})'}');
      }
    }
  });
  return misses;
}

/// The figures of every line: text -> glyph rect.
Map<String, Rect> _figures(WidgetTester t) {
  final out = <String, Rect>{};
  for (final col in ['qty', 'rate', 'amount', 'cost']) {
    final slots = _inTable(find.byKey(ValueKey('col-$col'))).evaluate().toList();
    for (var i = 1; i < slots.length; i++) {
      for (final (text, r) in _textsIn(slots[i])) {
        if (text.trim() == r'$') continue;
        out['$col $i $text'] = r;
      }
    }
  }
  return out;
}

Future<TestGesture> _mouse(WidgetTester t) async {
  final g = await t.createGesture(kind: PointerDeviceKind.mouse);
  await g.addPointer(location: Offset.zero);
  addTearDown(g.removePointer);
  return g;
}

void main() {
  setUpAll(jobPageSetUp);

  group('1. the qty arrows leave no outline behind', () {
    testWidgets('on a closed line: one more, one less, the box and the arrow stay unlit', (t) async {
      final s = FakeJobServer();
      _seed(s);
      await pumpJobPage(t, s, id: kEstimateId, size: const Size(1500, 1600), body: () async {
        await _toBlock(t);
        await _edit(t);
        final mouse = await _mouse(t);
        final before = _inkRings(t);
        expect(before, 0, reason: 'nothing is focused yet');
        for (final which in ['One more', 'One less', 'One less']) {
          final arrow = find.bySemanticsLabel(which).at(2); // the Torsion Spring line (qty 2)
          await mouse.moveTo(t.getCenter(arrow));
          await settle(t, frames: 2);
          await mouse.down(t.getCenter(arrow));
          await t.pump(const Duration(milliseconds: 60));
          await mouse.up();
          await settle(t, frames: 3);
          await mouse.moveTo(Offset.zero);
          await settle(t, frames: 3);
          expect(_inkRings(t), 0, reason: 'after $which: no ring round the qty box, no box round the arrow');
        }
        expect(_inTable(find.text('1.00')), findsWidgets);
        expect(find.text('Torsion Spring | 0.250 x 2" x 32"'), findsOneWidget, reason: 'the line stayed closed');
      });
    }, variant: _platforms);

    testWidgets('in an open line: the qty field keeps focus, its caret and its outline; quantities step through 0 either way', (t) async {
      final s = FakeJobServer();
      _seed(s);
      await pumpJobPage(t, s, id: kEstimateId, size: const Size(1500, 1600), body: () async {
        await _toBlock(t);
        await _edit(t);
        await t.tap(_inTable(find.text('2.00')).first);
        await settle(t, frames: 3);
        final qty = find.byKey(const ValueKey('line-2-qty'));
        expect(qty, findsOneWidget);
        String qtyNow() => t.widget<EditableText>(find.descendant(of: qty, matching: find.byType(EditableText))).controller.text;
        await t.enterText(qty, '-3');
        await settle(t, frames: 2);
        final up = find.descendant(of: find.byKey(const ValueKey('col-qty')).at(3), matching: find.bySemanticsLabel('One more'));
        await t.tap(up);
        await settle(t, frames: 3);
        expect(qtyNow(), '-2.00', reason: 'up from -3 goes toward 0');
        final focused = FocusManager.instance.primaryFocus;
        expect(focused?.debugLabel, contains('qty'), reason: 'the arrow left the typing in the qty field');
        expect(_inkRings(t), 1, reason: 'only the focused qty field is outlined in ink; the arrow has no box: ${_inkBoxes(t)}');
        await t.tap(up);
        await settle(t, frames: 2);
        await t.tap(up);
        await settle(t, frames: 3);
        expect(qtyNow(), '0.00');
        final down = find.descendant(of: find.byKey(const ValueKey('col-qty')).at(3), matching: find.bySemanticsLabel('One less'));
        await t.tap(down);
        await settle(t, frames: 3);
        expect(qtyNow(), '-1.00', reason: 'down goes on past 0 (round 4: it used to stop there)');
        expect(FocusManager.instance.primaryFocus?.debugLabel, contains('qty'));
        await t.tap(up);
        await settle(t, frames: 2);
        await t.tap(up);
        await settle(t, frames: 3);
        expect(qtyNow(), '1.00');
        expect(FocusManager.instance.primaryFocus?.debugLabel, contains('qty'));
        await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await settle(t, frames: 2);
        expect(qtyNow(), '2.00', reason: 'the keyboard\'s Up still steps');
      });
    }, variant: _platforms);

    testWidgets('a clicked control shows no ring; the keyboard still shows where focus is', (t) async {
      final s = FakeJobServer();
      _seed(s);
      await pumpJobPage(t, s, id: kEstimateId, size: const Size(1500, 1600), body: () async {
        await _toBlock(t);
        await _edit(t);
        final mouse = await _mouse(t);
        // The eye, a Description, the line's menu (opened and closed again): clicked, no ring.
        final eye = find.bySemanticsLabel('Show to the customer').at(2);
        await mouse.moveTo(t.getCenter(eye));
        await t.tap(eye);
        await settle(t, frames: 3);
        await mouse.moveTo(Offset.zero);
        await settle(t, frames: 3);
        expect(_inkRings(t), 0, reason: 'a clicked eye');
        await t.tap(find.byKey(const ValueKey('line-1-more')));
        await settle(t, frames: 4);
        await t.tap(find.byKey(const ValueKey('line-1-more')));
        await settle(t, frames: 4);
        expect(_inkRings(t), 0, reason: 'a clicked Description');
        await t.tap(find.byKey(const ValueKey('line-3-actions')));
        await settle(t, frames: 4);
        await t.tapAt(const Offset(4, 4)); // a click outside closes it
        await settle(t, frames: 4);
        expect(_inkRings(t), 0, reason: 'the line menu once it closes (focus comes back to it): ${_inkBoxes(t)}');
        // The keyboard: from the clicked eye, Shift+Tab goes back to the line above's menu, and it shows.
        await t.tap(eye);
        await settle(t, frames: 3);
        expect(_inkRings(t), 0);
        await t.sendKeyDownEvent(LogicalKeyboardKey.shift);
        await t.sendKeyEvent(LogicalKeyboardKey.tab);
        await t.sendKeyUpEvent(LogicalKeyboardKey.shift);
        await settle(t, frames: 4);
        expect(_inkRings(t), 1, reason: 'keyboard focus is visible: ${_inkBoxes(t)}; focus on ${FocusManager.instance.primaryFocus}');
        final menu = t.getRect(find.byKey(const ValueKey('line-1-actions')));
        expect(_inkBoxes(t).first, '${menu.size} at ${menu.topLeft}', reason: 'the ring is round the menu of the line above');
      });
    });
  });

  group('2. a description opening never moves the figures', () {
    for (final w in [1280.0, 1500.0, 1920.0]) {
      testWidgets('read-only and editing, $w wide: open, close, open again', (t) async {
        final s = FakeJobServer();
        _seed(s);
        await pumpJobPage(t, s, id: kEstimateId, size: Size(w, 2000), body: () async {
          await _toBlock(t);
          // Read-only: the long description (line 1), then the short one (line 2), each opened and closed twice.
          final ro = _figures(t);
          for (final i in [0, 1, 0, 1]) {
            final rows = _figures(t);
            await t.tap(find.byKey(ValueKey('line-$i-more')));
            await settle(t, frames: 5);
            final now = _figures(t);
            for (final k in rows.keys) {
              expect(now[k]!.left, closeTo(rows[k]!.left, 0.01), reason: 'read-only: $k moved sideways');
              final row = int.parse(k.split(' ')[1]);
              if (row <= i + 1) expect(now[k]!.top, closeTo(rows[k]!.top, 0.01), reason: 'read-only: $k moved up or down');
            }
          }
          expect(_figures(t).keys, ro.keys);
          // Editing: every line is boxes, and Description on a line with none (line 3) opens the line itself, into
          // its fields. Its figures stay exactly where they were (they jumped 3 px left).
          await _edit(t);
          final closed = _figures(t);
          await t.tap(find.byKey(const ValueKey('line-2-more')));
          await settle(t, frames: 5);
          expect(find.byKey(const ValueKey('line-2-qty')), findsOneWidget, reason: 'the line is open');
          final open = _figures(t);
          for (final k in closed.keys) {
            final match = open[k];
            expect(match, isNotNull, reason: '$k is still on show');
            expect(match!.right, closeTo(closed[k]!.right, 0.5), reason: 'editing: $k moved sideways as its line opened');
            // Not wider or taller either: the same letters at the same size (a field's text took the theme's wider
            // letter spacing, so the figures grew as the line opened; user 2026-11-13).
            expect(match.left, closeTo(closed[k]!.left, 0.5), reason: 'editing: $k grew as its line opened');
            expect(match.height, closeTo(closed[k]!.height, 0.5), reason: 'editing: $k changed size as its line opened');
            // The lines below make room for the opened description; the opened line and those above stay put.
            if (int.parse(k.split(' ')[1]) <= 3) expect(match.top, closeTo(closed[k]!.top, 0.5), reason: 'editing: $k moved up or down as its line opened');
          }
          // A line that has a description: Description opens it under the box; the line's figures stay put.
          await t.sendKeyEvent(LogicalKeyboardKey.escape);
          await settle(t, frames: 4);
          final again = _figures(t);
          await t.tap(find.byKey(const ValueKey('line-0-more')));
          await settle(t, frames: 5);
          final first = _figures(t).entries.where((e) => e.key.split(' ')[1] == '1');
          for (final e in first) {
            expect(e.value.left, closeTo(again[e.key]!.left, 0.01), reason: e.key);
            expect(e.value.top, closeTo(again[e.key]!.top, 0.01), reason: e.key);
          }
        });
      }, variant: _platforms);
    }
    testWidgets('editing: a click on an open description opens its line, and the text of the description stays exactly as it was', (t) async {
      // Run on Windows too (see _platforms): compact visual density there took 4 px off a field's padding top and
      // bottom, so the description's text jumped up as it became a field.
      final s = FakeJobServer();
      _seed(s);
      await pumpJobPage(t, s, id: kEstimateId, size: const Size(1500, 1600), body: () async {
        await _toBlock(t);
        await _edit(t);
        await t.tap(find.byKey(const ValueKey('line-1-more')));
        await settle(t, frames: 5);
        Rect desc() {
          final texts = [
            ..._inTable(find.text('Wi-Fi belt drive opener')).evaluate(),
            ..._inTable(find.byWidgetPredicate((w) => w is EditableText && w.controller.text == 'Wi-Fi belt drive opener')).evaluate(),
          ];
          return _glyphs(texts.first)!;
        }

        // A four-line description too: its lines as far apart in the field as they were shown, so nothing below moves.
        await t.tap(find.byKey(const ValueKey('line-0-more')));
        await settle(t, frames: 5);
        final specsLine = _l('', description: _specs)['description'] as String;
        Rect specs() {
          final e = [
            ..._inTable(find.text(specsLine)).evaluate(),
            ..._inTable(find.byWidgetPredicate((w) => w is EditableText && w.controller.text == specsLine)).evaluate(),
          ].first;
          return _glyphs(e)!;
        }

        final specsShown = specs();
        final below = t.getTopLeft(_inTable(find.text('Torsion Spring | 0.250 x 2" x 32"'))).dy;
        await t.tap(_inTable(find.text(specsLine)));
        await settle(t, frames: 4);
        expect(find.byKey(const ValueKey('line-0-description')), findsOneWidget);
        final specsTyped = specs();
        expect(specsTyped.top, closeTo(specsShown.top, 0.5));
        expect(specsTyped.left, closeTo(specsShown.left, 0.5));
        expect(specsTyped.bottom, closeTo(specsShown.bottom, 1.5), reason: 'its lines are spaced as they were shown');
        expect(t.getTopLeft(_inTable(find.text('Torsion Spring | 0.250 x 2" x 32"'))).dy, closeTo(below, 0.5), reason: 'nothing below moved');
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(t, frames: 4);

        final shown = desc();
        final figures = _figures(t);
        await t.tap(_inTable(find.text('Wi-Fi belt drive opener')));
        await settle(t, frames: 4);
        expect(find.byKey(const ValueKey('line-1-description')), findsOneWidget, reason: 'the line is open, its description a field');
        final typed = desc();
        expect(typed.left, closeTo(shown.left, 0.5));
        expect(typed.top, closeTo(shown.top, 0.5));
        expect(typed.width, closeTo(shown.width, 0.5), reason: 'the text of the description grew as its line opened');
        final now = _figures(t);
        for (final k in figures.keys.where((k) => k.split(' ')[1] == '2')) {
          expect(now[k]!.left, closeTo(figures[k]!.left, 0.5), reason: k);
          expect(now[k]!.right, closeTo(figures[k]!.right, 0.5), reason: k);
        }
      });
    }, variant: _platforms);
    // No cost reads 0.00, closed and open (user 2026-11-23; it was a "Cost" placeholder).
    testWidgets('an empty cost box: its "0.00" stays put as the line opens', (t) async {
      final s = FakeJobServer();
      s.addOption(kEstimateId, 'Option 1', [_l('Keyless Entry Pad', rate: 79), _l('Torsion Spring', qty: 2, rate: 89, cost: 19.5)], taxRate: 10.5);
      await pumpJobPage(t, s, id: kEstimateId, size: const Size(1500, 1400), body: () async {
        await _toBlock(t);
        await _edit(t);
        Rect costWord() {
          final slot = find.byKey(const ValueKey('col-cost')).at(1);
          final e = find.descendant(of: slot, matching: find.text('0.00')).evaluate().first;
          return _glyphs(e)!;
        }

        final closed = costWord();
        await t.tap(_inTable(find.text('Keyless Entry Pad')));
        await settle(t, frames: 3);
        expect(find.byKey(const ValueKey('line-0-cost')), findsOneWidget, reason: 'the line is open');
        final open = costWord();
        expect(open.right, closeTo(closed.right, 0.5));
        expect(open.left, closeTo(closed.left, 0.5), reason: 'the 0.00 grew as its line opened');
        expect(open.top, closeTo(closed.top, 0.5));
      });
    }, variant: _platforms);
  });

  group('3. no shading under the pointer on read-only lines', () {
    testWidgets('the pointer over a line, a description, and off the table again: nothing in the table changes', (t) async {
      final s = FakeJobServer();
      _seed(s);
      await pumpJobPage(t, s, id: kEstimateId, size: const Size(1500, 1600), body: () async {
        await _toBlock(t);
        final mouse = await _mouse(t);
        final before = _paint(t);
        for (final text in ['LiftMaster 87504 Smart Opener', 'Tek Screws | Retail Accessories', r'$1,489.00']) {
          await mouse.moveTo(t.getCenter(_inTable(find.text(text)).first));
          await settle(t, frames: 4);
          expect(_paint(t), before, reason: 'over "$text"');
        }
        await mouse.moveTo(Offset.zero);
        await settle(t, frames: 4);
        expect(_paint(t), before);
      });
    });
  });

  group('4. every heading over its values, to the pixel', () {
    final sizes = [1280.0, 1366.0, 1500.0, 1920.0];
    for (final w in sizes) {
      testWidgets('estimate option, $w wide: read-only, editing, a line open, a discount open', (t) async {
        final s = FakeJobServer();
        _seed(s);
        await pumpJobPage(t, s, id: kEstimateId, size: Size(w, 2000), body: () async {
          await _toBlock(t);
          expect(_misaligned(t), isEmpty, reason: 'read-only');
          await _edit(t);
          expect(_misaligned(t), isEmpty, reason: 'editing, every line closed');
          await t.tap(_inTable(find.text('68.57')));
          await settle(t, frames: 3);
          expect(_misaligned(t), isEmpty, reason: 'editing, a line open (its figures in fields)');
          await t.sendKeyEvent(LogicalKeyboardKey.escape);
          await settle(t, frames: 3);
          await t.tap(_inTable(find.text('250.00')));
          await settle(t, frames: 3);
          expect(_misaligned(t), isEmpty, reason: 'editing, the discount open (its amount in a field)');
        });
      }, variant: _platforms);
    }
    testWidgets('without the cost column (someone who can\'t see costs), read-only and editing', (t) async {
      final s = FakeJobServer(canSeeCost: false);
      _seed(s);
      await pumpJobPage(t, s, id: kEstimateId, size: const Size(1366, 2000), body: () async {
        await _toBlock(t);
        expect(_inTable(find.text('COST')), findsNothing);
        expect(_misaligned(t), isEmpty, reason: 'read-only');
        await _edit(t);
        expect(_misaligned(t), isEmpty, reason: 'editing');
      });
    }, variant: _platforms);
    testWidgets('the job page: Service Fusion\'s items (named taxes, a hidden line), read-only and editing', (t) async {
      final s = FakeJobServer();
      await pumpJobPage(t, s, id: kJobId, size: const Size(1500, 2400), body: () async {
        await _toBlock(t);
        expect(_misaligned(t), isEmpty, reason: 'read-only');
        await t.tap(find.text('Edit Job'));
        await settle(t, frames: 8);
        expect(_misaligned(t), isEmpty, reason: 'editing');
        await t.tap(_inTable(find.text('4.00')).first);
        await settle(t, frames: 3);
        expect(_misaligned(t), isEmpty, reason: 'editing, a line open');
      });
    }, variant: _platforms);
    testWidgets('large text (x1.3) at 1920', (t) async {
      final s = FakeJobServer();
      _seed(s);
      await pumpJobPage(t, s, id: kEstimateId, size: const Size(1920, 2400), textScale: 1.3, body: () async {
        await _toBlock(t);
        expect(_misaligned(t), isEmpty, reason: 'read-only');
        await _edit(t);
        expect(_misaligned(t), isEmpty, reason: 'editing');
      });
    });
  });

  group('5. read-only lines are all white (USER RULE 2026-11-24: no stripes, a black rule under each line)', () {
    Color? shellColor(WidgetTester t, String name) {
      // The line's own background: the first box with a fill above its name.
      for (final e in find.ancestor(of: _inTable(find.text(name)).first, matching: find.byType(AnimatedContainer)).evaluate()) {
        final d = (e.widget as AnimatedContainer).decoration;
        if (d is BoxDecoration && d.color != null && d.border == null) return d.color;
      }
      return null;
    }

    testWidgets('every line white, a black rule under each product and service; editing keeps its lines white', (t) async {
      final s = FakeJobServer();
      _seed(s);
      await pumpJobPage(t, s, id: kEstimateId, size: const Size(1500, 1800), body: () async {
        await _toBlock(t);
        final names = ['Clopay | Classic Steel | 4300 | Complete Door | Almond', 'LiftMaster 87504 Smart Opener', 'Torsion Spring | 0.250 x 2" x 32"', 'Stop Mold | Install New Standard Color'];
        final colors = [for (final n in names) shellColor(t, n)];
        expect(colors, everyElement(Colors.white), reason: 'no stripes');
        final inkRules = _inTable(find.byWidgetPredicate((w) => w is Container && w.color == DashUi.line && w.constraints?.maxHeight == 1));
        expect(inkRules.evaluate().length, greaterThanOrEqualTo(names.length), reason: 'a dark rule under each line');
        final firstTop = t.getTopLeft(_inTable(find.text(names.first))).dy;
        final lastBottom = t.getBottomLeft(_inTable(find.text('Loyal customer discount'))).dy;
        final rules = [for (final e in _inTable(find.byType(Divider)).evaluate()) t.getTopLeft(find.byWidget(e.widget)).dy];
        // One rule only: between the products and services and the discounts and fees (USER RULE 2026-11-24).
        final split = t.getTopLeft(_inTable(find.byKey(const ValueKey('charges-rule')))).dy;
        expect(split, lessThan(t.getTopLeft(_inTable(find.text('Loyal customer discount'))).dy));
        expect(split, greaterThan(t.getBottomLeft(_inTable(find.text(names.last))).dy));
        expect(rules.where((y) => y > firstTop && y < lastBottom && y != split), isEmpty, reason: 'no rules between the lines');
        // The table's last rows are now its taxes (under the discounts): the page's outline closes it, under them. No
        // Divider of its own (audit 2026-11-24, item 41: with the outline it drew a 2 px bottom line).
        expect(rules.where((y) => y > lastBottom), isEmpty, reason: 'the outline alone closes the table');
        await _edit(t);
        for (final n in names) {
          final c = shellColor(t, n);
          expect(c == null || c == Colors.white, isTrue, reason: 'editing: no stripes behind the boxes ($n)');
        }
      });
    });
  });

  group('6. the estimate\'s own option: "Estimate Option", the current one', () {
    // Round 4 (user 2026-11-13): the options are tabs on the table itself, so the estimate's own option is always a tab,
    // its only one when there are no options of ours (every estimate on prod today); there is no header row above the
    // table any more (it used to hold "Current option" and a line about Service Fusion).
    Finder sfTab() => find.byKey(const ValueKey('option-tab-sf'));

    testWidgets('with no options of ours (every estimate on prod today): its one tab names it and marks it current', (t) async {
      final s = FakeJobServer();
      await pumpJobPage(t, s, id: kEstimateId, size: const Size(1366, 1600), body: () async {
        await _toBlock(t);
        expect(sfTab(), findsOneWidget);
        expect(find.text('Estimate Option'), findsOneWidget, reason: 'named once, by its tab');
        expect(find.descendant(of: sfTab(), matching: find.text('Current')), findsOneWidget);
        expect(find.byKey(const ValueKey('option-header-sf')), findsNothing, reason: 'no header row between the tabs and the table');
        expect(find.descendant(of: sfTab(), matching: find.text(r'$907.75')), findsOneWidget, reason: 'Service Fusion\'s total, on its tab');
        expect(find.text(r'$907.75'), findsNWidgets(2), reason: 'its tab and its total');
        // Editing keeps it named and marked.
        await _edit(t);
        expect(find.text('Estimate Option'), findsOneWidget);
        expect(find.descendant(of: sfTab(), matching: find.text('Current')), findsOneWidget);
        await t.tap(find.text('Exit preview'));
        await settle(t, frames: 6);
        expect(find.descendant(of: sfTab(), matching: find.text('Current')), findsOneWidget);
      });
    });

    testWidgets('with alternatives: one first tab, set apart and marked; switching shows each option\'s own lines and totals', (t) async {
      final s = FakeJobServer();
      _seed(s, recommended: true);
      s.addOption(kEstimateId, 'Repair only', [_l('Spring Replacement | Labor', rate: 150, taxable: false)], taxRate: 10.5);
      await pumpJobPage(t, s, id: kEstimateId, size: const Size(1500, 1600), body: () async {
        await _toBlock(t);
        expect(sfTab(), findsOneWidget);
        expect(find.descendant(of: sfTab(), matching: find.text('Estimate Option')), findsOneWidget);
        expect(find.descendant(of: sfTab(), matching: find.text('Current')), findsOneWidget);
        expect(find.text('Estimate Option'), findsOneWidget, reason: 'not duplicated: only its tab names it');
        // It comes first, then the alternatives.
        final tabs = find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('option-tab-'));
        final xs = [for (final e in tabs.evaluate()) ((e.widget.key! as ValueKey<String>).value, t.getTopLeft(find.byWidget(e.widget)).dx)]..sort((a, b) => a.$2.compareTo(b.$2));
        expect(xs.first.$1, 'option-tab-sf');
        expect(xs.length, 3);
        // The recommended option opens first, as before (its tab carries the star); the estimate's own is one click away.
        expect(find.descendant(of: find.byKey(ValueKey(xs[1].$1)), matching: find.byIcon(Icons.star_rounded)), findsOneWidget);
        expect(find.text('Clopay | Classic Steel | 4300 | Complete Door | Almond'), findsOneWidget, reason: 'the recommended option is open');
        await t.tap(sfTab());
        await settle(t, frames: 4);
        expect(find.text('Estimate Option'), findsOneWidget, reason: 'its tab only: no header repeats it');
        expect(find.text('SMH Installation | Gallery Steel | 16x7 | Sandtone'), findsOneWidget, reason: 'Service Fusion\'s lines');
        expect(find.text('LiftMaster 87504 Smart Opener'), findsNothing);
        expect(find.text(r'$907.75'), findsNWidgets(2), reason: 'its tab and its total');
        // Editing keeps it open and named.
        await _edit(t);
        expect(find.text('SMH Installation | Gallery Steel | 16x7 | Sandtone'), findsOneWidget);
        await t.tap(find.text('Repair only'));
        await settle(t, frames: 4);
        expect(find.text('Spring Replacement | Labor'), findsOneWidget);
        expect(find.text('SMH Installation | Gallery Steel | 16x7 | Sandtone'), findsNothing);
        await t.tap(sfTab());
        await settle(t, frames: 4);
        expect(find.text('SMH Installation | Gallery Steel | 16x7 | Sandtone'), findsOneWidget);
        await t.tap(find.text('Exit preview'));
        await settle(t, frames: 6);
        expect(find.text('SMH Installation | Gallery Steel | 16x7 | Sandtone'), findsOneWidget, reason: 'still the one on show after the preview');
        // A Refresh keeps it on show (it used to fall back to an option of ours, with no way back).
        await t.tap(find.byIcon(Icons.refresh_rounded).first);
        await settle(t);
        expect(find.text('SMH Installation | Gallery Steel | 16x7 | Sandtone'), findsOneWidget);
      });
    });

    testWidgets('once an alternative is accepted, it is the one that opens and the estimate\'s own is no longer "Current"', (t) async {
      final s = FakeJobServer();
      _seed(s);
      await pumpJobPage(t, s, id: kEstimateId, size: const Size(1500, 1600), body: () async {
        await _toBlock(t);
        await t.tap(find.text('Accept'));
        await settle(t, frames: 4);
        await t.tap(find.text('Accept option'));
        await settle(t);
        expect(find.descendant(of: sfTab(), matching: find.text('Current')), findsNothing);
        expect(find.text('Accepted'), findsOneWidget, reason: 'the accepted one is marked on its tab: it is the current one now');
        await t.tap(sfTab());
        await settle(t, frames: 4);
        expect(find.text('Current'), findsNothing);
        expect(find.textContaining('Insulated was accepted instead'), findsOneWidget, reason: 'the strip says which');
      });
    });
  });

  testWidgets('the add-a-line search and the Tax, discounts & fees button are one height', (t) async {
    final s = FakeJobServer();
    _seed(s);
    await pumpJobPage(t, s, id: kEstimateId, size: const Size(1500, 1600), body: () async {
      await _toBlock(t);
      await _edit(t);
      // The drawn box: the field's decorator (the TextField itself can be laid out taller than it draws).
      final search = t.getRect(find.descendant(of: catalogSearch, matching: find.byType(InputDecorator)));
      final button = t.getRect(find.ancestor(of: find.text('Tax, discounts & fees'), matching: find.byType(TextButton)).first);
      expect(button.height, closeTo(search.height, 0.01));
      expect(button.top, closeTo(search.top, 0.01));
    });
  });
}
