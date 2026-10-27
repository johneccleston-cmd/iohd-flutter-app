// Renders the top navigation bar, its menus and the narrow-window drawer to test/shots/nav/ at the widths people use,
// plus keyboard focus, a short window, larger text and a restricted account. A RenderFlex overflow fails the test,
// so it doubles as an overflow check.
// Run:  flutter test test/nav_render_test.dart --update-goldens

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nav_fixture.dart';

Future<void> _shot(WidgetTester t, String name) =>
    expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/nav/$name.png'));

Future<void> _open(WidgetTester t, String label) async {
  final byText = find.text(label);
  await t.tap(byText.evaluate().isNotEmpty ? byText.first : find.byTooltip(label).first);
  await t.pumpAndSettle();
}

Future<void> _tabs(WidgetTester t, int n) async {
  for (var i = 0; i < n; i++) {
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pumpAndSettle();
  }
}

void main() {
  setUpAll(loadNavFonts);
  setUp(() => navSignIn());

  for (final w in const <double>[1920, 1440, 1366, 1280, 1100, 1024, 960, 860, 720, 520, 390, 360]) {
    testWidgets('bar ${w.toInt()}', (t) async {
      await pumpNav(t, Size(w, 220), initial: '/jobs');
      await _shot(t, 'bar_${w.toInt()}');
    });
  }

  for (final (label, initial) in [
    ('My Office', '/jobs/1099000137'),
    ('Inventory', '/inventory/catalog'),
    ('HR', '/hr/kpis/12'),
    ('Dashboards', '/dashboards/sales'),
  ]) {
    testWidgets('menu $label', (t) async {
      await pumpNav(t, const Size(1440, 720), initial: initial);
      await _open(t, label);
      await _shot(t, 'menu_${label.replaceAll(' ', '').toLowerCase()}_1440');
    });
  }

  testWidgets('menu hover state', (t) async {
    await pumpNav(t, const Size(1440, 720), initial: '/calendar');
    await _open(t, 'Inventory');
    final m = await t.createGesture(kind: PointerDeviceKind.mouse);
    await m.addPointer(location: t.getCenter(find.text('Purchase Orders')));
    addTearDown(m.removePointer);
    await t.pumpAndSettle();
    await _shot(t, 'menu_inventory_hover_1440');
  });

  testWidgets('account menu', (t) async {
    await pumpNav(t, const Size(1440, 400));
    await t.tap(find.byTooltip('Heather Vera'));
    await t.pumpAndSettle();
    await _shot(t, 'menu_account_1440');
  });

  testWidgets('keyboard focus on a module', (t) async {
    await pumpNav(t, const Size(1440, 220), initial: '/calendar');
    await _tabs(t, 2); // the page's button, then My Office
    await _shot(t, 'focus_tab_1440');
  });

  testWidgets('menu opened from the keyboard', (t) async {
    await pumpNav(t, const Size(1440, 720), initial: '/dashboards/sales');
    await _tabs(t, 7); // page button, then six modules
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pumpAndSettle();
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.pumpAndSettle();
    await _shot(t, 'focus_menu_1440');
  });

  testWidgets('short window: the longest menu scrolls', (t) async {
    await pumpNav(t, const Size(1440, 420), initial: '/invoices');
    await _open(t, 'My Office');
    await _shot(t, 'menu_myoffice_short_1440');
  });

  for (final (w, initial) in const [(860.0, '/statuses'), (520.0, '/dashboards/sales'), (390.0, '/hr/kpis/12')]) {
    testWidgets('drawer ${w.toInt()}', (t) async {
      await pumpNav(t, Size(w, 760), initial: initial);
      await _shot(t, 'collapsed_${w.toInt()}');
      await t.tap(find.byTooltip('All pages'));
      await t.pumpAndSettle();
      await _shot(t, 'drawer_${w.toInt()}');
    });
  }

  testWidgets('drawer with every module open', (t) async {
    await pumpNav(t, const Size(390, 760), initial: '/calendar');
    await t.tap(find.byTooltip('All pages'));
    await t.pumpAndSettle();
    final list = find.descendant(of: find.byType(Drawer), matching: find.byType(Scrollable));
    // Rows below the fold aren't built until scrolled to.
    for (final m in ['My Office', 'Inventory', 'HR', 'Dashboards']) {
      final row = find.descendant(of: find.byType(Drawer), matching: find.text(m));
      await t.scrollUntilVisible(row, 120, scrollable: list);
      await t.ensureVisible(row.first);
      await t.pumpAndSettle();
      await t.tap(row.first);
      await t.pumpAndSettle();
    }
    await t.scrollUntilVisible(
      find.descendant(of: find.byType(Drawer), matching: find.text('Collections')),
      120,
      scrollable: list,
    );
    await t.pumpAndSettle();
    await _shot(t, 'drawer_all_open_390');
  });

  testWidgets('restricted account', (t) async {
    await navSignIn(
      admin: false,
      name: 'Bella Ortiz',
      role: 'Office Manager',
      denied: denyViews(['dash_financial', 'dash_commissions', 'hr_payroll', 'stock', 'catalog', 'projects', 'payments']),
    );
    await pumpNav(t, const Size(1440, 220), initial: '/calendar');
    await _shot(t, 'bar_restricted_1440');
  });

  testWidgets('text 130%', (t) async {
    await pumpNav(t, const Size(1440, 640), initial: '/dashboards/sales', textScale: 1.3);
    await _shot(t, 'bar_text130_1440');
    await _open(t, 'Dashboards');
    await _shot(t, 'menu_dashboards_text130_1440');
  });

  testWidgets('text 160%', (t) async {
    await pumpNav(t, const Size(1440, 220), initial: '/dashboards/sales', textScale: 1.6);
    await _shot(t, 'bar_text160_1440');
  });
}
