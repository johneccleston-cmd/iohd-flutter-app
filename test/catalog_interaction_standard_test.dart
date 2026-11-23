// The catalog's interaction standard (UX audit 2026-11-19), checked as the office sees it: the app's own theme
// (officeTheme) on Windows, where desktop density applies. The audit found boxes 25-30 px tall in the app that the old
// pictures (stand-in theme, Android density) showed at 33-38 px, a bright red text cursor, and three menus that each
// moved differently. These tests keep the fixes:
//   * every one-line box is at least 40 px as drawn (its outline, not just the space it sits in), at 100% and 130% text;
//   * the text cursor is ink, never the brand red, with the plain blink (a fading one costs 27% CPU while focused);
//   * menus open under (or over) their trigger without covering it, as wide as a select field, with the current choice
//     ticked and the keyboard on it; arrows move, Enter picks, Esc closes and gives the keyboard back; a click outside
//     closes; the open is a short fade (partial part-way through, done by 160 ms), instant with reduced motion.
// The real-browser check of the same things is tool/ux_harness/ (see its header).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/main.dart' show officeTheme;
import 'package:iohd_desktop/service_detail_screen.dart';
import 'package:iohd_desktop/services_catalog_screen.dart';
import 'package:iohd_desktop/widgets/catalog_kit.dart';
import 'package:iohd_desktop/widgets/dashboard_kit.dart';
import 'package:iohd_desktop/widgets/line_table_style.dart';

import 'dashboard_harness.dart';
import 'services_catalog_fixture.dart';

final _windows = TargetPlatformVariant.only(TargetPlatform.windows);

Future<void> _pump(WidgetTester t, Widget page, {double text = 1, bool reduceMotion = false}) async {
  t.view.physicalSize = const Size(1366, 768);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: officeTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(text), disableAnimations: reduceMotion),
        child: child!,
      ),
      home: page,
    ),
  );
  await t.pump(const Duration(milliseconds: 50));
  await t.pumpAndSettle();
}

Widget _detail() => ServiceDetailScreen(
  serviceKey: kServiceWithRates.key,
  initial: kServiceWithRates,
  loader: () async => (entries: [kServiceWithRates, ...kProdLikeServices.where((e) => e.key != kServiceWithRates.key)], canSeeCost: true, historyDays: 540),
);

Widget _list() => ServicesCatalogScreen(load: () async => prodLikeCatalog(), canEdit: true);

/// The drawn box of a field: its InputDecorator (the outline is painted at the decorator's size).
Size _drawn(WidgetTester t, Finder field) => t.getSize(find.descendant(of: field, matching: find.byType(InputDecorator)).first);

Future<void> _edit(WidgetTester t) async {
  await t.tap(find.text('Edit'));
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await loadDashFonts();
    await dashSignIn();
  });

  group('boxes', () {
    for (final text in const [1.0, 1.3]) {
      testWidgets('the service page form boxes are 40 px and the rates table boxes the Products & Services box, at ${(text * 100).round()}% text', (t) async {
        await _pump(t, _detail(), text: text);
        await _edit(t);
        // The form (name, category, description): the catalog's 40 px box.
        for (final k in ['name', 'category', 'description']) {
          final h = _drawn(t, find.byKey(ValueKey('field:$k'))).height;
          expect(h, greaterThanOrEqualTo(CatalogUi.fieldHeight - 0.5), reason: '$k is ${h.toStringAsFixed(1)} px');
          if (text > 1) expect(h, greaterThan(CatalogUi.fieldHeight), reason: '$k does not grow with the text');
        }
        // The rates table: the Products & Services table's box (USER RULE 2026-11-20 "match the Products & Services table";
        // redesign 2026-11-20 evening: its own height too, from line_table_style.dart), drawn by the table round the
        // field. The commission's % / $ switch is exactly as tall as the boxes beside it.
        final boxH = LineTable.boxHeight(t.element(find.byKey(const ValueKey('field:rate0.name'))));
        expect(boxH, text == 1 ? 31 : greaterThan(31));
        for (final k in ['rate0.name', 'rate0.qty', 'rate0.rate', 'rate0.cost', 'rate0.commission']) {
          final box = find.ancestor(of: find.byKey(ValueKey('field:$k')), matching: find.byType(AnimatedContainer)).first;
          expect(t.getSize(box).height, boxH, reason: k);
        }
        expect(t.getSize(find.byKey(const ValueKey('field:rate0.commissionType'))).height, boxH);
        expect(t.takeException(), isNull);
      }, variant: _windows);
    }

    testWidgets('the search box draws its outline at its full 40 px', (t) async {
      await _pump(t, _list());
      expect(_drawn(t, find.byType(CatalogSearchField)).height, greaterThanOrEqualTo(CatalogUi.fieldHeight - 0.5));
    }, variant: _windows);

    testWidgets('the text cursor is ink, not the brand red, with the plain blink (no every-frame fade)', (t) async {
      await _pump(t, _detail());
      await _edit(t);
      final editable = t.widget<EditableText>(find.descendant(of: find.byKey(const ValueKey('field:description')), matching: find.byType(EditableText)));
      expect(editable.cursorColor, DashUi.ink);
      // A fading cursor redraws every frame while a box has the keyboard (27% of the browser's main thread).
      expect(editable.cursorOpacityAnimates, isFalse);
      await _pump(t, _list());
      final search = t.widget<EditableText>(find.descendant(of: find.byType(CatalogSearchField), matching: find.byType(EditableText)));
      expect(search.cursorColor, DashUi.ink);
    }, variant: _windows);

    testWidgets("a rate's commission says what it pays, and an impossible one says so as it is typed", (t) async {
      await _pump(t, _detail());
      await _edit(t);
      String pays(int i) => t.widget<Text>(find.byKey(ValueKey('commission-pays:$i'))).data!;
      expect(pays(0), r'$19.75', reason: r'5% of $395.00');
      expect(find.bySemanticsLabel(RegExp(r'Rate 1 commission pays \$19\.75, 5% of \$395\.00')), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('field:rate0.commission')), '150');
      await t.pump();
      expect(pays(0), 'Over 100%', reason: 'not only on Save');
      expect(pays(1), r'$10.00', reason: 'the other rate is unaffected');
    }, variant: _windows);

    // The bug the user sent on 2026-11-20 evening: switching % and $ shifted the "None" next to it. The unit was the box's
    // Material prefix / suffix text, which keeps its room while hidden; and the "Pays ..." note under the box could wrap.
    testWidgets('switching a commission between % and \$ moves nothing in its row or under it', (t) async {
      await _pump(t, _detail());
      await _edit(t);
      Rect at(Finder f) => t.getRect(f);
      final watched = <String, Finder>{
        'switch': find.byKey(const ValueKey('field:rate2.commissionType')),
        'box': find.ancestor(of: find.byKey(const ValueKey('field:rate2.commission')), matching: find.byType(AnimatedContainer)).first,
        'pays': find.byKey(const ValueKey('commission-pays:2')),
        'cost': find.byKey(const ValueKey('field:rate2.cost')),
        'menu': find.byKey(const ValueKey('rate-menu:2')),
        'add': find.byKey(const ValueKey('add-rate')),
      };
      Map<String, Rect> snap() => {for (final e in watched.entries) e.key: at(e.value)};
      Future<void> unit(String side) async {
        await t.tap(find.byKey(ValueKey('field:rate2.commissionType:$side')));
        await t.pumpAndSettle();
      }

      // Empty ("None"): the placeholder stays put too.
      Rect none() => at(find.descendant(of: find.byKey(const ValueKey('field:rate2.commission')), matching: find.text('None')));
      final start = snap();
      final hint = none();
      for (final side in const ['fixed', 'percent', 'fixed']) {
        await unit(side);
        expect(snap(), start, reason: 'after $side');
        expect(none(), hint, reason: '"None" after $side');
      }
      // With an amount: the typed figure stays put as the unit changes.
      await t.enterText(find.byKey(const ValueKey('field:rate2.commission')), '5');
      await t.pumpAndSettle();
      Rect typed() => at(find.descendant(of: find.byKey(const ValueKey('field:rate2.commission')), matching: find.byType(EditableText)));
      final withValue = snap();
      final figure = typed();
      for (final side in const ['percent', 'fixed', 'percent']) {
        await unit(side);
        expect(snap(), withValue, reason: 'after $side, with 5 typed');
        expect(typed(), figure, reason: 'the figure after $side');
      }
      expect(t.takeException(), isNull);
    }, variant: _windows);

    testWidgets('a whole quantity reads 2, not 2.00, while editing', (t) async {
      await _pump(t, _detail());
      await _edit(t);
      expect(t.widget<TextField>(find.byKey(const ValueKey('field:rate1.qty'))).controller!.text, '2');
    }, variant: _windows);
  });

  group('menus', () {
    testWidgets('the category list opens under its field, as wide as it, the current choice ticked and focused', (t) async {
      await _pump(t, _detail());
      await _edit(t);
      final field = t.getRect(find.byKey(const ValueKey('field:category')));
      await t.tap(find.byKey(const ValueKey('field:category')));
      await t.pumpAndSettle();
      final menu = t.getRect(find.ancestor(of: find.byKey(const ValueKey('option:Service Packages')), matching: find.byType(SingleChildScrollView)).first);
      expect(menu.top, greaterThanOrEqualTo(field.bottom), reason: 'the list must not cover its field');
      expect(menu.width, closeTo(field.width - 2, 2.5), reason: 'as wide as the field (inside its 1 px edge)');
      final current = find.byKey(const ValueKey('option:Operator Installations'));
      expect(find.descendant(of: current, matching: find.byIcon(Icons.check_rounded)), findsOneWidget);
      expect(Focus.of(t.element(find.descendant(of: current, matching: find.byType(Text)).first)).hasFocus, isTrue, reason: 'the keyboard starts on the current choice');
      // Down then Enter picks the next one; the list closes and the keyboard is back on the field.
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('option:Service Packages')), findsNothing);
      expect(find.descendant(of: find.byKey(const ValueKey('field:category')), matching: find.text('Residential Installations')), findsOneWidget);
      expect(find.text('Unsaved changes'), findsOneWidget);
    }, variant: _windows);

    testWidgets('Esc in the category list closes only the list: the page stays in edit mode, nothing is asked', (t) async {
      await _pump(t, _detail());
      await _edit(t);
      await t.enterText(find.byKey(const ValueKey('field:description')), 'Changed');
      await t.pump();
      await t.tap(find.byKey(const ValueKey('field:category')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('option:Service Packages')), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('option:Service Packages')), findsNothing);
      expect(find.text('Discard your changes?'), findsNothing, reason: "the page's own Esc (Cancel) must not fire");
      expect(find.byKey(const ValueKey('field:category')), findsOneWidget, reason: 'still editing');
      // A second Esc is the page's: Cancel, which asks about the typed change.
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.text('Discard your changes?'), findsOneWidget);
    }, variant: _windows);

    testWidgets('Esc and a click outside both close a menu; Esc gives the keyboard back to its trigger', (t) async {
      await _pump(t, _list());
      await t.tap(find.byKey(const ValueKey('sort-menu')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('sort:Highest price')), findsOneWidget);
      final trigger = t.getRect(find.byKey(const ValueKey('sort-menu')));
      final menu = t.getRect(find.ancestor(of: find.byKey(const ValueKey('sort:Highest price')), matching: find.byType(SingleChildScrollView)).first);
      expect(menu.top, greaterThanOrEqualTo(trigger.bottom), reason: 'under its trigger, not over it');
      expect(menu.right, closeTo(trigger.right, 2), reason: 'lined up with the trigger at the right of the bar');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('sort:Highest price')), findsNothing);
      final triggerFocus = Focus.of(t.element(find.descendant(of: find.byKey(const ValueKey('sort-menu')), matching: find.byType(Row)).first));
      expect(triggerFocus.hasFocus, isTrue, reason: 'focus returns to the trigger');
      await t.tap(find.byKey(const ValueKey('sort-menu')));
      await t.pumpAndSettle();
      // A click outside (on a row) closes the menu and does nothing else: the row does not open.
      await t.tapAt(const Offset(600, 600));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('sort:Highest price')), findsNothing);
      expect(find.byType(ServiceDetailScreen), findsNothing, reason: 'the closing click must not open the row under it');
      // Picking a sort closes the menu and sorts.
      await t.tap(find.byKey(const ValueKey('sort-menu')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('sort:Highest price')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('sort:Highest price')), findsNothing);
      expect(find.descendant(of: find.byKey(const ValueKey('sort-menu')), matching: find.text('Highest price')), findsOneWidget);
    }, variant: _windows);

    double opacityOf(WidgetTester t, Finder inMenu) => t.widgetList<Opacity>(find.ancestor(of: inMenu, matching: find.byType(Opacity))).first.opacity;

    testWidgets('a menu fades in over about 150 ms and out faster; no delay, no stagger', (t) async {
      await _pump(t, _list());
      await t.tap(find.byKey(const ValueKey('sort-menu')));
      await t.pump(); // the first frame: the menu is there at once
      final first = find.byKey(const ValueKey('sort:Name A–Z'));
      final last = find.byKey(const ValueKey('sort:Lowest cost'));
      expect(first, findsOneWidget);
      await t.pump(const Duration(milliseconds: 70));
      final mid = opacityOf(t, first);
      expect(mid, inExclusiveRange(0.2, 1.0), reason: 'part-way through, not popped in');
      expect(opacityOf(t, last), mid, reason: 'every row together, no stagger');
      await t.pump(const Duration(milliseconds: 90));
      expect(opacityOf(t, first), 1.0, reason: 'fully open by 160 ms');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      await t.pump(const Duration(milliseconds: 110));
      await t.pump();
      expect(first, findsNothing, reason: 'closed within about 100 ms');
    }, variant: _windows);

    testWidgets('with reduced motion a menu opens and closes at once', (t) async {
      await _pump(t, _list(), reduceMotion: true);
      await t.tap(find.byKey(const ValueKey('sort-menu')));
      await t.pump();
      await t.pump();
      expect(opacityOf(t, find.byKey(const ValueKey('sort:Name A–Z'))), 1.0);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      await t.pump();
      expect(find.byKey(const ValueKey('sort:Name A–Z')), findsNothing);
    }, variant: _windows);

    testWidgets('a filter chip can be reached with Tab and removed with Enter or Delete', (t) async {
      var removed = 0;
      await _pump(
        t,
        Scaffold(
          body: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(width: 60, child: TextField()),
                CatalogFilterChip(group: 'Category', value: 'Operator Installations', onRemove: () => removed++),
              ],
            ),
          ),
        ),
      );
      await t.tap(find.byType(TextField));
      await t.sendKeyEvent(LogicalKeyboardKey.tab); // from the box to the chip
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump();
      expect(removed, 1);
      await t.sendKeyEvent(LogicalKeyboardKey.delete);
      await t.pump();
      expect(removed, 2);
    }, variant: _windows);
  });
}
