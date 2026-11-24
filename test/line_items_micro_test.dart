// Products & Services, last micro-polish (2026-11-16):
//   flutter test test/line_items_micro_test.dart
//
// 1. Opening a line from its Description (a line with none opens into its fields) moved the Rate and Cost figures: in
//    real Chrome they dropped a pixel row (up), Qty and Amount did not. Cause: the open money fields' "$" (13 px) and
//    placeholder (13 px) sat on their own font's line inside the field, which a text field lines up on the figure's
//    baseline (13.5 px) and grows to hold, then re-centres; the closed box centred each text on its own. Every text in a
//    figure box is measured here to a hundredth of a pixel, closed and open, on both pages.
// 2. No eye in the column headings; every line keeps its own, and a click still hides or shows the line.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/widgets/line_items_editor.dart';

import 'job_page_fixture.dart';

Map<String, dynamic> _l(String name, {double qty = 1, double? rate, double? cost, bool taxable = true, String description = '', String sku = ''}) => {
  'kind': 'item',
  'name': name,
  'description': description,
  'sku': sku,
  'quantity': qty,
  'rate': rate,
  'cost': cost,
  'taxable': taxable,
  'source': 'catalog',
};

/// Short and long names, with and without a description, with and without a cost.
void _seed(FakeJobServer s) => s.addOption(
  kEstimateId,
  'Insulated',
  [
    _l('Clopay | Classic Steel | 4300 | Complete Door | Almond', rate: 1489, cost: 912.4, description: 'SIZE : 16x7\nMODEL : 4300', sku: 'CL-4300-1607'),
    _l('Spring', qty: 2, rate: 89, cost: 19.5),
    _l('Keyless Entry Pad', rate: 79),
    _l('Stop Mold | Install New Standard Color | Residential garage door perimeter, both sides and header', qty: 68.57, rate: 0.61, cost: 0.2),
  ],
  taxRate: 10.5,
);

final _platforms = TargetPlatformVariant({TargetPlatform.android, TargetPlatform.windows});
Finder get _editor => find.byType(LineItemsEditor);
Finder _inTable(Finder f) => find.descendant(of: _editor, matching: f);

/// Every text drawn in [slot] (a column's cell of one row): its letters' left and right edges and its baseline (as a
/// zero-height rect at the baseline). Closed values, an open field's typed
/// text, its "$" and its placeholder, whatever shows. Text hidden at opacity 0 (a field's hint once it has text, its "$"
/// while it is empty) is left out. Trailing spaces are left off ("$ " is the "$").
Map<String, Rect> _ink(Element slot) {
  final out = <String, Rect>{};
  void add(RenderBox box, String raw) {
    final text = raw.trimRight();
    if (text.isEmpty || !box.hasSize) return;
    final sel = TextSelection(baseOffset: 0, extentOffset: text.length);
    final boxes = box is RenderEditable ? box.getBoxesForSelection(sel) : (box as RenderParagraph).getBoxesForSelection(sel);
    if (boxes.isEmpty) return;
    var r = boxes.first.toRect();
    for (final b in boxes) {
      r = r.expandToInclude(b.toRect());
    }
    // Across: where the letters start and end. Up and down: the baseline they sit on (a field's selection box is its
    // forced line, taller than a Text's run box, so box tops and bottoms differ where the letters don't).
    final base = box.getDryBaseline(box.constraints, TextBaseline.alphabetic) ?? 0;
    final o = box.localToGlobal(Offset(r.left, base));
    out[text] = Rect.fromLTWH(o.dx, o.dy, r.width, 0);
  }

  void visit(Element e) {
    final w = e.widget;
    if ((w is Opacity && w.opacity == 0) || (w is AnimatedOpacity && w.opacity == 0)) return;
    final ro = e.renderObject;
    if (w is EditableText && ro is RenderBox) {
      // The editable's own render object is under it; find it.
      void editable(Element x) {
        final r = x.renderObject;
        if (r is RenderEditable) {
          add(r, r.text?.toPlainText() ?? '');
          return;
        }
        x.visitChildren(editable);
      }

      editable(e);
      return;
    }
    if (w is RichText && ro is RenderParagraph) {
      add(ro, ro.text.toPlainText());
      return;
    }
    e.visitChildren(visit);
  }

  visit(slot);
  return out;
}

/// Row [row]'s figure cells (0 = the first line), every text in each.
Map<String, Rect> _row(int row) {
  final out = <String, Rect>{};
  for (final col in ['qty', 'rate', 'amount', 'cost', 'tax']) {
    final slots = _inTable(find.byKey(ValueKey('col-$col'))).evaluate().toList();
    if (slots.length <= row + 1) continue;
    for (final e in _ink(slots[row + 1]).entries) {
      out['$col "${e.key}"'] = e.value;
    }
  }
  return out;
}

void _same(Map<String, Rect> closed, Map<String, Rect> open, String what) {
  expect(open.keys.toSet(), closed.keys.toSet(), reason: '$what: the same texts show closed and open');
  final misses = <String>[];
  for (final k in closed.keys) {
    final a = closed[k]!, b = open[k]!;
    for (final (side, x, y) in [('left', a.left, b.left), ('right', a.right, b.right), ('baseline', a.top, b.top)]) {
      if ((y - x).abs() > 0.01) misses.add('$k: its $side ${x.toStringAsFixed(3)} -> ${y.toStringAsFixed(3)}');
    }
  }
  expect(misses, isEmpty, reason: '$what: texts moved as the line opened');
}

Future<void> _toBlock(WidgetTester t) async {
  await t.ensureVisible(find.text('PRODUCTS & SERVICES'));
  await settle(t, frames: 6);
}

void main() {
  setUpAll(jobPageSetUp);

  group('1. opening a line from Description moves no figure, no "\$", no placeholder', () {
    for (final (w, h, scale) in [(1280.0, 1600.0, 1.0), (1500.0, 1600.0, 1.0), (1500.0, 1800.0, 1.3)]) {
      testWidgets('estimate option, $w wide, text x$scale: short name, long name, no cost; then close again', (t) async {
        final s = FakeJobServer();
        _seed(s);
        await pumpJobPage(t, s, id: kEstimateId, size: Size(w, h), textScale: scale, body: () async {
          await _toBlock(t);
          await t.tap(find.text('Edit Estimate'));
          await settle(t, frames: 8);
          // Line 2 ("Spring", rate and cost), line 3 (no cost: its "$ 0.00"), line 4 (a long name).
          for (final i in [1, 2, 3]) {
            final closed = _row(i);
            expect(closed.keys.where((k) => k.startsWith('rate')), isNotEmpty, reason: 'line ${i + 1} shows its rate');
            await t.tap(find.byKey(ValueKey('line-$i-more')));
            await settle(t, frames: 5);
            expect(find.byKey(ValueKey('line-$i-rate')), findsOneWidget, reason: 'line ${i + 1} is open, into its fields');
            expect(find.byKey(ValueKey('line-$i-description')), findsOneWidget, reason: 'with its empty description box');
            _same(closed, _row(i), 'line ${i + 1}');
            // Closed again (Esc): back where it was.
            await t.sendKeyEvent(LogicalKeyboardKey.escape);
            await settle(t, frames: 5);
            expect(find.byKey(ValueKey('line-$i-rate')), findsNothing);
            _same(closed, _row(i), 'line ${i + 1} closed again');
          }
          // A line WITH a description: Description shows it under the box and the line stays closed; nothing moves.
          final first = _row(0);
          await t.tap(find.byKey(const ValueKey('line-0-more')));
          await settle(t, frames: 5);
          expect(find.byKey(const ValueKey('line-0-rate')), findsNothing);
          _same(first, _row(0), 'line 1 (has a description)');
          // And opened from its rate: the same.
          await t.tap(_inTable(find.byKey(const ValueKey('col-rate'))).at(1));
          await settle(t, frames: 5);
          expect(find.byKey(const ValueKey('line-0-rate')), findsOneWidget);
          _same(first, _row(0), 'line 1 opened from its rate');
        });
      }, variant: _platforms);
    }

    testWidgets('without the cost column (someone who can\'t see costs)', (t) async {
      final s = FakeJobServer(canSeeCost: false);
      _seed(s);
      await pumpJobPage(t, s, id: kEstimateId, size: const Size(1280, 1600), body: () async {
        await _toBlock(t);
        await t.tap(find.text('Edit Estimate'));
        await settle(t, frames: 8);
        expect(_inTable(find.byKey(const ValueKey('col-cost'))), findsNothing);
        final closed = _row(1);
        await t.tap(find.byKey(const ValueKey('line-1-more')));
        await settle(t, frames: 5);
        expect(find.byKey(const ValueKey('line-1-rate')), findsOneWidget);
        _same(closed, _row(1), 'line 2');
      });
    }, variant: _platforms);

    testWidgets('the job page: Service Fusion\'s lines', (t) async {
      final s = FakeJobServer();
      await pumpJobPage(t, s, id: kJobId, size: const Size(1500, 1600), body: () async {
        await _toBlock(t);
        await t.tap(find.text('Edit Job'));
        await settle(t, frames: 8);
        var tried = 0;
        for (var i = 0; i < 6 && tried < 2; i++) {
          final more = find.byKey(ValueKey('line-$i-more'));
          if (more.evaluate().isEmpty) continue;
          final closed = _row(i);
          if (!closed.keys.any((k) => k.startsWith('rate'))) continue;
          await t.tap(more);
          await settle(t, frames: 5);
          if (find.byKey(ValueKey('line-$i-rate')).evaluate().isEmpty) {
            // It had a description: it showed it and stayed closed. Close it again and try the next.
            await t.tap(more);
            await settle(t, frames: 5);
            continue;
          }
          tried++;
          _same(closed, _row(i), 'job line ${i + 1}');
          await t.sendKeyEvent(LogicalKeyboardKey.escape);
          await settle(t, frames: 5);
        }
        expect(tried, greaterThan(0), reason: 'the job has a line without a description');
      });
    }, variant: _platforms);
  });

  group('2. no eye in the column headings; each line keeps its own', () {
    Finder headEye() => find.descendant(of: _inTable(find.byKey(const ValueKey('col-eye'))).first, matching: find.byType(Icon));
    int lineEyes() => _inTable(find.byKey(const ValueKey('col-eye'))).evaluate().skip(1).where((e) {
      return find.descendant(of: find.byElementPredicate((x) => x == e), matching: find.byType(Icon)).evaluate().isNotEmpty;
    }).length;

    testWidgets('read-only and editing; a click on a line\'s eye still hides and shows it', (t) async {
      final s = FakeJobServer();
      _seed(s);
      await pumpJobPage(t, s, id: kEstimateId, size: const Size(1500, 1600), body: () async {
        await _toBlock(t);
        expect(headEye(), findsNothing, reason: 'read-only headings');
        expect(lineEyes(), 4, reason: 'every read-only line has its eye');
        await t.tap(find.text('Edit Estimate'));
        await settle(t, frames: 8);
        expect(headEye(), findsNothing, reason: 'editing headings');
        expect(lineEyes(), 4, reason: 'every editable line has its eye');
        // Our own lines start shown to the customer; one click hides line 2, another shows it again.
        final eye2 = _inTable(find.byKey(const ValueKey('col-eye'))).at(2);
        Icon icon() => t.widget<Icon>(find.descendant(of: eye2, matching: find.byType(Icon)).last);
        expect(icon().icon, Icons.visibility_outlined);
        await t.tap(eye2);
        await settle(t, frames: 4);
        expect(icon().icon, Icons.visibility_off_outlined, reason: 'hidden from the customer');
        await t.tap(eye2);
        await settle(t, frames: 4);
        expect(icon().icon, Icons.visibility_outlined, reason: 'shown again');
      });
    });
  });
}
