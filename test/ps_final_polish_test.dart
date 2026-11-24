// Products & Services final polish (2026-11-23): B9 (long names and SKUs while editing at 1280) and the row menu's
// keyboard focus after a click on a greyed-out item. The same checks run in real Chrome (build/ps_b9, b9.mjs).
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/services/line_items_api.dart';
import 'package:iohd_desktop/utils/line_item_math.dart';
import 'package:iohd_desktop/widgets/line_items_editor.dart';
import 'package:iohd_desktop/widgets/page_selection.dart';

import 'dashboard_harness.dart';

const _long = 'Clopay Canyon Ridge Collection Ultra-Grain Cladding | CR13 | 16x7 | Complete Door with Insulated Windows and Decorative Hardware';

/// The app's own setting: the page-wide text selection sits above the navigator ([appSelectionBuilder]), as in main.dart.
Future<void> _pump(WidgetTester t, Widget editor, {double width = 1500}) async {
  t.view.physicalSize = Size(width, 1000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
      builder: appSelectionBuilder,
      home: Scaffold(body: SingleChildScrollView(child: editor)),
    ),
  );
  await t.pumpAndSettle();
}

Future<List<CatalogEntry>> _noSearch(String q) async => const [];

LineItemsEditor _editor(List<LineDraft> lines) => LineItemsEditor(
  lines: lines,
  taxRate: null,
  editable: true,
  showCost: true,
  onPreviewSave: () {},
  search: _noSearch,
);

const _lines = [
  LineDraft(name: _long, sku: 'CL-CR13-1607', rate: 3895.4, cost: 2410.12, quantity: 1),
  LineDraft(name: 'Tek Screws | Retail Accessories', rate: 0.21, quantity: 2400),
  LineDraft(name: 'LiftMaster 87504 Smart Opener', sku: 'LIFTMASTER-87504-SMART-OPENER-BATTERY', rate: 689, quantity: 1),
];

ScrollController _nameScroll(WidgetTester t) =>
    t.widget<EditableText>(find.descendant(of: find.byKey(const ValueKey('line-0-name')), matching: find.byType(EditableText))).scrollController!;

double _rowY(WidgetTester t, int i) => t.getTopLeft(find.byKey(ValueKey('line-$i-actions'))).dy;

void main() {
  setUpAll(loadDashFonts);

  group('B9: long names and SKUs while editing', () {
    // 1240 px: columns, but each name box is about 350 px, too narrow to carry a SKU inside it (a 1280 window).
    testWidgets('a narrow name box: every SKU sits under its box, whole, and the rows stay one height', (t) async {
      await _pump(t, _editor(_lines), width: 1240);
      for (final sku in ['CL-CR13-1607', 'LIFTMASTER-87504-SMART-OPENER-BATTERY']) {
        expect(find.text(sku), findsOneWidget, reason: '$sku is shown while editing (it used to be left out below 460 px)');
        final r = t.renderObject<RenderParagraph>(find.descendant(of: find.text(sku), matching: find.byType(RichText)));
        expect(r.didExceedMaxLines, isFalse, reason: '$sku reads whole under its box');
      }
      final name = t.getRect(find.text(_long));
      expect(t.getTopLeft(find.text('CL-CR13-1607')).dy, greaterThan(name.bottom), reason: 'under the name box');
      final gaps = [_rowY(t, 1) - _rowY(t, 0), _rowY(t, 2) - _rowY(t, 1)];
      expect(gaps[0], moreOrLessEquals(gaps[1], epsilon: 0.5), reason: 'a line without a SKU keeps the same room');
      expect(t.takeException(), isNull);
    });

    testWidgets('opening a long-named line: its start is in view, the SKU stays, the boxes keep their height, nothing below moves', (t) async {
      await _pump(t, _editor(_lines), width: 1240);
      final below = [_rowY(t, 1), _rowY(t, 2)];
      await t.tap(find.text(_long));
      await t.pumpAndSettle();
      final scroll = _nameScroll(t);
      expect(scroll.position.maxScrollExtent, greaterThan(0), reason: 'the name is longer than its box');
      expect(scroll.offset, 0, reason: 'the whole name is selected, and the view shows its start, not its end');
      expect(find.text('CL-CR13-1607'), findsOneWidget, reason: 'the SKU is still there with the line open');
      // The boxes, not the fields inside them (a field's own height follows its text style).
      double box(String k) => t.getSize(find.ancestor(of: find.byKey(ValueKey(k)), matching: find.byType(AnimatedContainer)).first).height;
      expect(box('line-0-name'), box('line-0-qty'), reason: 'the name box is as tall as the figures\' boxes');
      expect(box('line-0-name'), box('line-0-rate'));
      expect([_rowY(t, 1), _rowY(t, 2)], below, reason: 'opening the line moved no other line');
      // It is still a field: End shows the name's end; leaving it for the quantity shows its start again.
      await t.sendKeyEvent(LogicalKeyboardKey.end);
      await t.pumpAndSettle();
      expect(_nameScroll(t).offset, greaterThan(0));
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pumpAndSettle();
      expect(_nameScroll(t).offset, 0, reason: 'left, the name reads by its start, as the closed box does');
      expect(t.takeException(), isNull);
    });

    // The web and desktop case (2026-11-23 root cause): there a field selects all of itself FORWARD as it takes focus
    // (EditableText.selectAllOnFocus defaults to true off mobile), then scrolls to that selection's end. The test
    // above runs as Android, where that default is false, so it passed while real Chrome showed the name's end.
    testWidgets('web/desktop: opening, leaving, coming back by keyboard, editing and reopening all show the name\'s start', (t) async {
      TextSelection sel() =>
          t.widget<EditableText>(find.descendant(of: find.byKey(const ValueKey('line-0-name')), matching: find.byType(EditableText))).controller.selection;
      void atStart(String when) {
        expect(sel().start, 0, reason: '$when: the whole name is selected');
        expect(sel().end, greaterThanOrEqualTo(_long.length), reason: '$when: the whole name is selected');
        expect(sel().extentOffset, 0, reason: '$when: the selection runs back to the start, the end a field reveals');
        expect(_nameScroll(t).offset, 0, reason: '$when: the view shows the name\'s start');
      }

      await _pump(t, _editor(_lines), width: 1240);
      await t.tap(find.text(_long));
      await t.pumpAndSettle();
      atStart('opened');
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pumpAndSettle();
      expect(_nameScroll(t).offset, 0, reason: 'left for the next box');
      await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await t.pumpAndSettle();
      atStart('back by Shift+Tab');
      // Editing at the end shows the end, as any field does; opening another line (this one closes) and then this one
      // again shows the start.
      await t.sendKeyEvent(LogicalKeyboardKey.end);
      await t.enterText(find.descendant(of: find.byKey(const ValueKey('line-0-name')), matching: find.byType(EditableText)), '$_long X');
      await t.pumpAndSettle();
      expect(_nameScroll(t).offset, greaterThan(0), reason: 'the caret at the end is in view while editing');
      await t.tap(find.text('Tek Screws | Retail Accessories'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('line-0-name')), findsNothing, reason: 'the long line closed');
      await t.tap(find.text('$_long X'));
      await t.pumpAndSettle();
      atStart('reopened');
      expect(t.takeException(), isNull);
    }, variant: TargetPlatformVariant.desktop());

    testWidgets('a wide name box carries the SKU inside it, with more room for a long one', (t) async {
      await _pump(t, _editor(_lines), width: 1900);
      final box = t.getRect(find.text(_long));
      final sku = t.getRect(find.text('CL-CR13-1607'));
      expect(sku.center.dy, moreOrLessEquals(box.center.dy, epsilon: 2), reason: 'in the box, on its line');
      final longSku = t.getSize(find.text('LIFTMASTER-87504-SMART-OPENER-BATTERY'));
      expect(longSku.width, greaterThan(104), reason: 'a wide box gives a long SKU more than the narrowest box\'s 104 px');
      expect(find.byTooltip('LIFTMASTER-87504-SMART-OPENER-BATTERY'), findsOneWidget, reason: 'and the whole SKU on hover');
      expect(t.takeException(), isNull);
    });
  });

  group('row menu keyboard focus', () {
    testWidgets('a click on a greyed-out item keeps the menu open with the keyboard; Esc then closes it', (t) async {
      await _pump(t, _editor(_lines));
      await t.tap(find.byKey(const ValueKey('line-0-actions')));
      await t.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'menu');
      await t.tap(find.text('Move up')); // the first line: greyed out
      await t.pumpAndSettle();
      expect(find.text('Copy'), findsOneWidget, reason: 'the menu is still open');
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'menu', reason: 'the page selection did not take the keyboard');
      expect(t.getTopLeft(find.text(_long)).dy, lessThan(t.getTopLeft(find.text('Tek Screws | Retail Accessories')).dy), reason: 'nothing moved');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.text('Copy'), findsNothing, reason: 'Esc closed the menu');
    });

    testWidgets('after a greyed-out click the arrows still move through the choices that work', (t) async {
      await _pump(t, _editor(_lines));
      await t.tap(find.byKey(const ValueKey('line-0-actions')));
      await t.pumpAndSettle();
      await t.tap(find.text('Move up'));
      await t.pumpAndSettle();
      // Copy, Move down, Delete: Down twice is Move down.
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      expect(find.text('Copy'), findsNothing);
      expect(t.getTopLeft(find.text('Tek Screws | Retail Accessories')).dy, lessThan(t.getTopLeft(find.text(_long)).dy), reason: 'Move down ran');
    });

    testWidgets('a click outside still closes the menu', (t) async {
      await _pump(t, _editor(_lines));
      await t.tap(find.byKey(const ValueKey('line-0-actions')));
      await t.pumpAndSettle();
      await t.tap(find.text('Move up'));
      await t.pumpAndSettle();
      await t.tapAt(const Offset(5, 990));
      await t.pumpAndSettle();
      expect(find.text('Copy'), findsNothing);
    });
  });
}
