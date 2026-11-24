// Keyboard focus on the Services Catalog, as the office sees it (UX audit 2026-11-20, second pass): the app's own theme
// on Windows. Tabbing through the real screen in Chrome found that the status tabs, the column headers, the pick boxes,
// the service page's Status / Sales tax toggles and the dialogs showed no focus at all (their Material ink was painted
// under the screens' white panels), that the headers could not be reached with Tab, that Tab zig-zagged between the
// filter sidebar and the table, that Add rate left the keyboard on the page, and that the Make inactive / Discard
// questions opened with nothing focused. These tests keep the fixes:
//   * keyboard focus is the shared ring (lib/widgets/focus_ring.dart), shown after a key press, never after a click
//     (the service page's Active / Taxable are switch rows since the 2026-11-20 redesign);
//   * Tab finishes the list's command row and table before the sidebar's filters come up (no interleaving);
//   * a column header is a Tab stop and Enter sorts by it;
//   * Add rate puts the keyboard in the new line's name; removing the focused line moves it to Add rate;
//   * the two questions open on a button, so Enter answers them.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/main.dart' show officeTheme;
import 'package:iohd_desktop/service_detail_screen.dart';
import 'package:iohd_desktop/services_catalog_screen.dart';
import 'package:iohd_desktop/widgets/catalog_kit.dart';
import 'package:iohd_desktop/widgets/focus_ring.dart';

import 'dashboard_harness.dart';
import 'services_catalog_fixture.dart';

final _windows = TargetPlatformVariant.only(TargetPlatform.windows);

Future<void> _pump(WidgetTester t, Widget page) async {
  t.view.physicalSize = const Size(1366, 768);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: officeTheme(), home: page));
  await t.pump(const Duration(milliseconds: 50));
  await t.pumpAndSettle();
}

Widget _list() => ServicesCatalogScreen(load: () async => prodLikeCatalog(), canEdit: true, saver: (key, fields) async => kProdLikeServices.firstWhere((e) => e.key == key));

Widget _detail() => ServiceDetailScreen(
  serviceKey: kServiceWithRates.key,
  initial: kServiceWithRates,
  loader: () async => (entries: [kServiceWithRates, ...kProdLikeServices.where((e) => e.key != kServiceWithRates.key)], canSeeCost: true, historyDays: 540),
);

/// Whether the shared ring round [target] is showing (its fade at full).
bool _ring(WidgetTester t, Finder target) {
  // The key sits inside the ring (a status tab's InkWell) or round it (a pick box, a toggle segment).
  final inside = find.descendant(of: target, matching: find.byType(FocusRing));
  final ring = inside.evaluate().isNotEmpty ? inside.first : find.ancestor(of: target, matching: find.byType(FocusRing)).first;
  final fades = t.widgetList<AnimatedOpacity>(find.descendant(of: ring, matching: find.byType(AnimatedOpacity))).where((a) => a.child is DecoratedBox);
  return fades.last.opacity == 1;
}

Future<void> _tab(WidgetTester t, {bool shift = false}) async {
  if (shift) await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await t.sendKeyEvent(LogicalKeyboardKey.tab);
  if (shift) await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await t.pumpAndSettle();
}

Rect _focusRect() => FocusManager.instance.primaryFocus!.rect;

String? _focusKey() {
  String? key;
  FocusManager.instance.primaryFocus?.context?.visitAncestorElements((a) {
    final k = a.widget.key;
    if (k is ValueKey<String>) {
      key = k.value;
      return false;
    }
    return true;
  });
  return key;
}

void main() {
  setUpAll(() async {
    await loadDashFonts();
    await dashSignIn();
  });

  testWidgets('the sidebar status rows, pick boxes and column headers show the ring on Tab, and a click leaves none', (t) async {
    await _pump(t, _list());
    await t.tap(find.byType(TextField).first);
    await t.pumpAndSettle();
    final seen = <String>{};
    for (var i = 0; i < 12; i++) {
      await _tab(t);
      final k = _focusKey() ?? '';
      if (k.startsWith('status:')) {
        expect(_ring(t, find.byKey(ValueKey(k))), isTrue, reason: '$k shows no focus');
        seen.add('tab');
      }
      if (k == 'pick-page') {
        expect(_ring(t, find.byKey(const ValueKey('pick-page'))), isTrue, reason: 'the select-all box shows no focus');
        seen.add('pick');
      }
    }
    expect(seen, contains('pick'));
    // The status rows moved into the filter sidebar (2026-11-23): Tab gets there after the table, and they show the ring.
    for (var i = 0; i < 150 && !seen.contains('tab'); i++) {
      await _tab(t);
      final k = _focusKey() ?? '';
      if (k.startsWith('status:')) {
        expect(_ring(t, find.byKey(ValueKey(k))), isTrue, reason: '$k shows no focus');
        seen.add('tab');
      }
    }
    expect(seen, containsAll(['tab', 'pick']));

    // A click puts the ring away even where the keyboard stays (FocusRing follows the last input, like :focus-visible).
    await t.tapAt(const Offset(700, 400));
    await t.pumpAndSettle();
    expect(t.widgetList<AnimatedOpacity>(find.descendant(of: find.byType(FocusRing), matching: find.byType(AnimatedOpacity))).where((a) => a.child is DecoratedBox && a.opacity > 0), isEmpty);
  }, variant: _windows);

  testWidgets('Tab goes through the command row and the table without jumping into the filter sidebar', (t) async {
    await _pump(t, _list());
    await t.tap(find.byType(TextField).first);
    await t.pumpAndSettle();
    final sidebarRight = CatalogUi.sidebarWidth;
    var reachedRows = false;
    for (var i = 0; i < 14; i++) {
      await _tab(t);
      final r = _focusRect();
      if ((_focusKey() ?? '').startsWith('row:')) reachedRows = true;
      expect(r.left, greaterThanOrEqualTo(sidebarRight - 1), reason: 'stop $i (${_focusKey()}) jumped into the sidebar at $r');
    }
    expect(reachedRows, isTrue);
  }, variant: _windows);

  testWidgets('a column header is a Tab stop, shows the ring, and Enter sorts by it', (t) async {
    await _pump(t, _list());
    await t.tap(find.byType(TextField).first);
    await t.pumpAndSettle();
    Finder price() => find.text('PRICE');
    for (var i = 0; i < 12 && !(FocusManager.instance.primaryFocus!.rect.overlaps(t.getRect(price()))); i++) {
      await _tab(t);
    }
    expect(FocusManager.instance.primaryFocus!.rect.overlaps(t.getRect(price())), isTrue, reason: 'PRICE is not a Tab stop');
    expect(_ring(t, price()), isTrue);
    expect(find.descendant(of: find.ancestor(of: price(), matching: find.byType(Row)).first, matching: find.byIcon(Icons.arrow_upward_rounded)).evaluate().isNotEmpty ||
        find.descendant(of: find.ancestor(of: price(), matching: find.byType(Row)).first, matching: find.byIcon(Icons.arrow_downward_rounded)).evaluate().isNotEmpty, isFalse);
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pumpAndSettle();
    final row = find.ancestor(of: price(), matching: find.byType(Row)).first;
    final arrows = find.descendant(of: row, matching: find.byWidgetPredicate((w) => w is Icon && (w.icon == Icons.arrow_upward_rounded || w.icon == Icons.arrow_downward_rounded)));
    expect(arrows, findsOneWidget, reason: 'Enter did not sort by PRICE');
  }, variant: _windows);

  testWidgets('the Make inactive question opens on its button: Enter answers it', (t) async {
    await _pump(t, _list());
    await t.tap(find.byType(CatalogSelectBox).at(1));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('bulk-status')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('bulk-inactive')));
    await t.pumpAndSettle();
    expect(find.textContaining('inactive?'), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<FilledButton>(), isNotNull, reason: 'nothing has the keyboard');
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pumpAndSettle();
    expect(find.textContaining('inactive?'), findsNothing);
  }, variant: _windows);

  testWidgets('service page: the switch rows show the ring; Add rate takes the keyboard into the new name; Discard opens on Keep editing', (t) async {
    await _pump(t, _detail());
    await t.tap(find.text('Edit'));
    await t.pumpAndSettle();

    // Active and Taxable (switch rows since the 2026-11-20 redesign): Tab onto each row shows the ring.
    await t.tap(find.byKey(const ValueKey('field:name')));
    await t.pumpAndSettle();
    var toggles = 0;
    for (var i = 0; i < 8; i++) {
      await _tab(t);
      final k = _focusKey() ?? '';
      if (k == 'switch:active' || k == 'switch:taxable') {
        expect(_ring(t, find.byKey(ValueKey(k))), isTrue, reason: '$k shows no focus');
        toggles++;
      }
    }
    expect(toggles, 2);

    // Add rate from the keyboard: the new line's name box has it.
    final before = find.byType(TextField).evaluate().length;
    final add = find.byKey(const ValueKey('add-rate'));
    await t.ensureVisible(add);
    Focus.of(t.element(find.descendant(of: add, matching: find.byType(Container)).first)).requestFocus();
    await t.pumpAndSettle();
    expect(_ring(t, add), isTrue);
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pumpAndSettle();
    expect(find.byType(TextField).evaluate().length, greaterThan(before));
    final n = kServiceWithRates.rates.length;
    expect(_focusKey(), 'field:rate$n.name');

    // Remove the focused line from its remove button: the keyboard lands on Add rate, not the page.
    // The row's menu by keyboard: Enter opens it, End then Enter on Delete removes the line.
    final menuButton = find.byKey(ValueKey('rate-menu:${kServiceWithRates.rates.length}'));
    await t.ensureVisible(menuButton);
    Focus.of(t.element(find.descendant(of: menuButton, matching: find.byType(Icon)).first)).requestFocus();
    await t.pumpAndSettle();
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pumpAndSettle();
    // Delete is the menu's last row (after Copy): End goes straight to it.
    await t.sendKeyEvent(LogicalKeyboardKey.end);
    await t.pumpAndSettle();
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pumpAndSettle();
    expect(_focusKey(), 'add-rate');

    // Leaving with changes asks, on the safe answer.
    await t.enterText(find.byKey(const ValueKey('field:name')), 'Changed name');
    await t.pumpAndSettle();
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(find.text('Discard your changes?'), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TextButton>(), isNotNull);
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pumpAndSettle();
    expect(find.text('Discard your changes?'), findsNothing);
    expect(find.text('Cancel'), findsOneWidget, reason: 'Enter should keep editing');
    expect(t.takeException(), isNull);
  }, variant: _windows);
}
