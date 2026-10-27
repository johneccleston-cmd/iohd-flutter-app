// How the top navigation bar behaves: keyboard, mouse, screen reader, active page, permissions, narrow windows,
// search and the address bar. Stub pages on a router with the real paths (nav_fixture.dart).
// Run:  flutter test test/nav_behavior_test.dart

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/config/auth_session.dart';

import 'nav_fixture.dart';

const _wide = Size(1440, 760);

/// Whether keyboard focus is on the control that [f] finds (its own focus node, or a focus node inside it).
bool _hasFocus(WidgetTester t, Finder f) {
  final p = FocusManager.instance.primaryFocus;
  if (p == null || p.context == null) return false;
  final el = t.element(f.first);
  if (!p.skipTraversal && Focus.maybeOf(el) == p) return true;
  var inside = false;
  void visit(Element e) {
    if (e == p.context) {
      inside = true;
    } else if (!inside) {
      e.visitChildElements(visit);
    }
  }

  visit(el);
  return inside;
}

Future<void> _key(WidgetTester t, LogicalKeyboardKey k) async {
  await t.sendKeyEvent(k);
  await t.pumpAndSettle();
}

/// Presses Tab until [f] has focus (at most 16 times).
Future<void> _tabTo(WidgetTester t, Finder f) async {
  for (var i = 0; i < 16; i++) {
    await _key(t, LogicalKeyboardKey.tab);
    if (_hasFocus(t, f)) return;
  }
  fail('Tab never reached $f');
}

Future<TestGesture> _mouse(WidgetTester t) async {
  final m = await t.createGesture(kind: PointerDeviceKind.mouse);
  await m.addPointer(location: const Offset(700, 500));
  addTearDown(m.removePointer);
  return m;
}

Future<void> _click(WidgetTester t, TestGesture m, Offset at) async {
  await m.moveTo(at);
  await m.down(at);
  await m.up();
  await t.pumpAndSettle();
}

/// What the browser sends the app on Back/Forward or when the address is edited.
Future<void> _platformRoute(WidgetTester t, String location) async {
  await t.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/navigation',
    const JSONMethodCodec().encodeMethodCall(MethodCall('pushRouteInformation', {'location': location, 'state': null})),
    (_) {},
  );
  await t.pumpAndSettle();
}

Finder _inMenu(String label) => find.descendant(of: find.byType(MenuItemButton), matching: find.text(label));

/// Every destination, by module, exactly as the menus list them for an admin.
const _allPages = {
  'My Office': [
    ('Customers', '/customers'),
    ('Estimates', '/estimates'),
    ('Jobs', '/jobs'),
    ('Estimate & Job Statuses', '/statuses'),
    ('Documents', '/documents'),
    ('Payments', '/payments'),
    ('Invoices', '/invoices'),
    ('Site Checks', '/site-checks'),
    ('Takeoffs', '/takeoffs'),
  ],
  'Projects': [('Projects', '/projects')],
  'Calendar': [('Calendar', '/calendar')],
  'Inventory': [
    ('Stock Levels', '/inventory'),
    ('Product Catalog', '/inventory/catalog'),
    ('Purchase Orders', '/inventory/purchase-orders'),
    ('Vendors', '/inventory/vendors'),
  ],
  'HR': [("KPI's", '/hr/kpis'), ('Payroll', '/hr/payroll'), ('Team', '/hr/team')],
  'Dashboards': [
    ('Financial', '/dashboards/financial'),
    ('Commissions', '/dashboards/commissions'),
    ('Technicians', '/dashboards/technicians'),
    ('Inventory', '/dashboards/inventory'),
    ('Jobs', '/dashboards/jobs'),
    ('Estimates', '/dashboards/estimates'),
    ('Sales', '/dashboards/sales'),
    ('Collections', '/dashboards/collections'),
  ],
};

void main() {
  setUpAll(loadNavFonts);
  setUp(() => navSignIn());
  tearDown(() => AuthSession.instance.logout());

  group('keyboard', () {
    testWidgets('Tab goes from the page into the bar: modules, search, Ask Jarvis, account, and back', (t) async {
      await pumpNav(t, _wide);
      // Focus starts in the page (each branch is its own focus scope), so its controls come first.
      await _key(t, LogicalKeyboardKey.tab);
      expect(_hasFocus(t, find.text('Page action')), isTrue, reason: 'the page comes first');
      for (final label in ['My Office', 'Projects', 'Calendar', 'Inventory', 'HR', 'Dashboards']) {
        await _key(t, LogicalKeyboardKey.tab);
        expect(_hasFocus(t, find.text(label)), isTrue, reason: '$label should be the next Tab stop');
      }
      await _key(t, LogicalKeyboardKey.tab);
      expect(_hasFocus(t, find.byType(TextField)), isTrue, reason: 'search field');
      await _key(t, LogicalKeyboardKey.tab);
      expect(_hasFocus(t, find.text('Ask Jarvis')), isTrue, reason: 'Ask Jarvis');
      await _key(t, LogicalKeyboardKey.tab);
      expect(_hasFocus(t, find.byTooltip('Heather Vera')), isTrue, reason: 'account menu');
      await _key(t, LogicalKeyboardKey.tab);
      expect(_hasFocus(t, find.text('Page action')), isTrue, reason: 'Tab wraps back to the page');

      // Shift+Tab from the page's first control goes backwards into the bar.
      await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await _key(t, LogicalKeyboardKey.tab);
      await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await t.pumpAndSettle();
      expect(_hasFocus(t, find.byTooltip('Heather Vera')), isTrue, reason: 'Shift+Tab reaches the account menu');
    });

    testWidgets('Enter and Space on a page button go there', (t) async {
      final router = await pumpNav(t, _wide);
      await _tabTo(t, find.text('Projects'));
      await _key(t, LogicalKeyboardKey.enter);
      expect(router.state.uri.path, '/projects');
      await _tabTo(t, find.text('Calendar'));
      await _key(t, LogicalKeyboardKey.space);
      expect(router.state.uri.path, '/calendar');
    });

    testWidgets('a menu opens from the keyboard with focus on its first page; arrows move; Escape returns focus',
        (t) async {
      final router = await pumpNav(t, _wide);
      await _tabTo(t, find.text('Inventory'));
      await _key(t, LogicalKeyboardKey.enter);
      expect(_inMenu('Stock Levels'), findsOneWidget);
      expect(_hasFocus(t, _inMenu('Stock Levels')), isTrue);

      await _key(t, LogicalKeyboardKey.arrowDown);
      expect(_hasFocus(t, _inMenu('Product Catalog')), isTrue);

      await _key(t, LogicalKeyboardKey.escape);
      expect(_inMenu('Product Catalog'), findsNothing);
      expect(_hasFocus(t, find.text('Inventory')), isTrue, reason: 'focus goes back to the menu button');

      // Arrow Down opens it too; Enter on a page goes there and closes the menu.
      await _key(t, LogicalKeyboardKey.arrowDown);
      await _key(t, LogicalKeyboardKey.arrowDown);
      await _key(t, LogicalKeyboardKey.enter);
      expect(router.state.uri.path, '/inventory/catalog');
      expect(find.byType(MenuItemButton), findsNothing);
      // Like a page load, focus moves on into the page you chose: the next Tab is that page's first control.
      expect(_hasFocus(t, find.text('Inventory')), isFalse);
      await _key(t, LogicalKeyboardKey.tab);
      expect(_hasFocus(t, find.text('Page action')), isTrue);
    });

    testWidgets('opening a menu on the page you are on puts focus on that page', (t) async {
      await pumpNav(t, _wide, initial: '/dashboards/sales');
      await _tabTo(t, find.text('Dashboards'));
      await _key(t, LogicalKeyboardKey.space);
      expect(_hasFocus(t, _inMenu('Sales')), isTrue);
    });
  });

  group('mouse', () {
    testWidgets('hovering opens a menu, and clicking that button keeps it open', (t) async {
      await pumpNav(t, _wide);
      final m = await _mouse(t);
      final inventory = t.getCenter(find.text('Inventory'));
      await m.moveTo(inventory);
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      expect(_inMenu('Stock Levels'), findsOneWidget, reason: 'hover opens');

      await _click(t, m, inventory);
      expect(_inMenu('Stock Levels'), findsOneWidget, reason: 'a click on the hovered button must not close its menu');

      await _click(t, m, inventory);
      expect(_inMenu('Stock Levels'), findsNothing, reason: 'a second click closes it');
    });

    testWidgets('a quick pass over a button does not open its menu', (t) async {
      await pumpNav(t, _wide);
      final m = await _mouse(t);
      await m.moveTo(t.getCenter(find.text('Inventory')));
      await t.pump(const Duration(milliseconds: 40));
      await m.moveTo(const Offset(700, 500));
      await t.pump(const Duration(milliseconds: 600));
      await t.pumpAndSettle();
      expect(find.byType(MenuItemButton), findsNothing);
    });

    testWidgets('moving along the bar shows one menu at a time', (t) async {
      await pumpNav(t, _wide);
      final m = await _mouse(t);
      await m.moveTo(t.getCenter(find.text('Inventory')));
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      await m.moveTo(t.getCenter(find.text('HR')));
      for (var i = 0; i < 12; i++) {
        await t.pump(const Duration(milliseconds: 30));
        final both = _inMenu('Stock Levels').evaluate().isNotEmpty && _inMenu('Payroll').evaluate().isNotEmpty;
        expect(both, isFalse, reason: 'two menus open at once after ${i * 30} ms');
      }
      await t.pumpAndSettle();
      expect(_inMenu('Payroll'), findsOneWidget);
      expect(_inMenu('Stock Levels'), findsNothing);
    });

    testWidgets('Escape closes a menu that hover opened', (t) async {
      await pumpNav(t, _wide);
      final m = await _mouse(t);
      await m.moveTo(t.getCenter(find.text('HR')));
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      expect(_inMenu('Payroll'), findsOneWidget);
      await _key(t, LogicalKeyboardKey.escape);
      expect(_inMenu('Payroll'), findsNothing);
    });

    testWidgets('the account menu counts as a bar menu: a module menu replaces it, and Escape closes it', (t) async {
      await pumpNav(t, _wide);
      await t.tap(find.byTooltip('Heather Vera'));
      await t.pumpAndSettle();
      expect(find.text('Sign out'), findsOneWidget);
      final m = await _mouse(t);
      await m.moveTo(t.getCenter(find.text('Dashboards')));
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      expect(_inMenu('Sales'), findsOneWidget);
      expect(find.text('Sign out'), findsNothing, reason: 'never two menus at once');

      await m.moveTo(const Offset(700, 500));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('Heather Vera'));
      await t.pumpAndSettle();
      expect(find.text('Sign out'), findsOneWidget);
      await _key(t, LogicalKeyboardKey.escape);
      expect(find.text('Sign out'), findsNothing);
    });

    testWidgets('clicking the page closes an open menu without navigating', (t) async {
      final router = await pumpNav(t, _wide);
      await t.tap(find.text('Dashboards'));
      await t.pumpAndSettle();
      expect(_inMenu('Sales'), findsOneWidget);
      await t.tapAt(const Offset(1200, 600));
      await t.pumpAndSettle();
      expect(find.byType(MenuItemButton), findsNothing);
      expect(router.state.uri.path, '/calendar');
    });

    testWidgets('clicking a page in a menu goes there and closes the menu', (t) async {
      final router = await pumpNav(t, _wide);
      await t.tap(find.text('My Office'));
      await t.pumpAndSettle();
      await t.tap(_inMenu('Invoices'));
      await t.pumpAndSettle();
      expect(router.state.uri.path, '/invoices');
      expect(find.byType(MenuItemButton), findsNothing);
    });
  });

  group('where am I', () {
    for (final (loc, menu, item) in [
      ('/hr/kpis/12', 'HR', "KPI's"),
      ('/hr/corrections', 'HR', 'Payroll'),
      ('/jobs/1099000137', 'My Office', 'Jobs'),
      ('/estimates/88', 'My Office', 'Estimates'),
      ('/inventory', 'Inventory', 'Stock Levels'),
      ('/inventory/catalog', 'Inventory', 'Product Catalog'),
      ('/dashboards', 'Dashboards', 'Financial'),
      ('/dashboards/inventory', 'Dashboards', 'Inventory'),
    ]) {
      testWidgets('on $loc the $menu menu marks $item and only $item', (t) async {
        final sem = t.ensureSemantics();
        await pumpNav(t, _wide, initial: loc);
        expect(t.getSemantics(find.text(menu).first), isSemantics(isButton: true, isSelected: true));
        await t.tap(find.text(menu).first);
        await t.pumpAndSettle();
        expect(t.getSemantics(_inMenu(item)), isSemantics(isSelected: true));
        expect(find.byIcon(Icons.check_rounded), findsOneWidget);
        expect(
          find.ancestor(of: find.byIcon(Icons.check_rounded), matching: find.byType(MenuItemButton)).evaluate().single,
          find.ancestor(of: _inMenu(item), matching: find.byType(MenuItemButton)).evaluate().single,
          reason: 'the check sits on the $item row',
        );
        sem.dispose();
      });
    }

    testWidgets('screen readers hear the current module as selected and menus as expanded or collapsed', (t) async {
      final sem = t.ensureSemantics();
      await pumpNav(t, _wide, initial: '/calendar');
      expect(t.getSemantics(find.text('Calendar')), isSemantics(isButton: true, isSelected: true, label: 'Calendar'));
      expect(t.getSemantics(find.text('Projects')), isSemantics(isButton: true, isSelected: false));
      expect(t.getSemantics(find.text('HR')), isSemantics(isButton: true, hasExpandedState: true, isExpanded: false));
      await t.tap(find.text('HR'));
      await t.pumpAndSettle();
      expect(t.getSemantics(find.text('HR')), isSemantics(hasExpandedState: true, isExpanded: true));
      sem.dispose();
    });

    testWidgets('the bar follows the address: a deep link, then browser Back/Forward', (t) async {
      final sem = t.ensureSemantics();
      final router = await pumpNav(t, _wide, initial: '/hr/kpis/12');
      expect(t.getSemantics(find.text('HR')), isSemantics(isSelected: true));
      await _platformRoute(t, '/inventory/vendors');
      expect(router.state.uri.path, '/inventory/vendors');
      expect(t.getSemantics(find.text('Inventory')), isSemantics(isSelected: true));
      expect(t.getSemantics(find.text('HR')), isSemantics(isSelected: false));
      await _platformRoute(t, '/hr/kpis/12');
      expect(t.getSemantics(find.text('HR')), isSemantics(isSelected: true));
      sem.dispose();
    });
  });

  group('permissions', () {
    testWidgets('a restricted account sees only its pages; a menu with nothing left goes', (t) async {
      await navSignIn(
        admin: false,
        denied: denyViews(['stock', 'catalog', 'purchase_orders', 'vendors', 'hr_payroll', 'projects', 'payments']),
      );
      await pumpNav(t, _wide);
      expect(find.text('Inventory'), findsNothing);
      expect(find.text('Projects'), findsNothing);
      await t.tap(find.text('HR'));
      await t.pumpAndSettle();
      expect(_inMenu("KPI's"), findsOneWidget);
      expect(_inMenu('Payroll'), findsNothing);
      expect(_inMenu('Team'), findsNothing, reason: 'Team is for admins');
      await t.tapAt(const Offset(1200, 600));
      await t.pumpAndSettle();
      await t.tap(find.text('My Office'));
      await t.pumpAndSettle();
      expect(_inMenu('Payments'), findsNothing);
      expect(_inMenu('Invoices'), findsOneWidget);
    });

    testWidgets('HR does not show an empty menu when only Commission Corrections is allowed', (t) async {
      await navSignIn(admin: false, denied: denyViews(['hr_payroll', 'hr_kpis']));
      await pumpNav(t, _wide);
      expect(find.text('HR'), findsNothing);
    });

    testWidgets('search sends a name to Customers and a number to Jobs', (t) async {
      final router = await pumpNav(t, _wide);
      await t.enterText(find.byType(TextField), 'Smith');
      await t.testTextInput.receiveAction(TextInputAction.search);
      await t.pumpAndSettle();
      expect(router.state.uri.toString(), '/customers?q=Smith');
      await t.enterText(find.byType(TextField), '1099000137');
      await t.testTextInput.receiveAction(TextInputAction.search);
      await t.pumpAndSettle();
      expect(router.state.uri.toString(), '/jobs?q=1099000137');
    });

    testWidgets('search uses the list the account can open, and goes when it can open neither', (t) async {
      await navSignIn(admin: false, denied: denyViews(['customers']));
      final router = await pumpNav(t, _wide);
      await t.enterText(find.byType(TextField), 'Smith');
      await t.testTextInput.receiveAction(TextInputAction.search);
      await t.pumpAndSettle();
      expect(router.state.uri.toString(), '/jobs?q=Smith');

      await navSignIn(admin: false, denied: denyViews(['customers', 'jobs']));
      await pumpNav(t, _wide);
      expect(find.byType(TextField), findsNothing);
    });
  });

  group('narrow windows', () {
    for (final w in const <double>[360, 390, 520, 720, 860]) {
      testWidgets('at ${w.toInt()} px every page is reachable from the menu button', (t) async {
        final router = await pumpNav(t, Size(w, 900));
        final menu = find.byTooltip('All pages');
        expect(menu, findsOneWidget);
        for (final entry in _allPages.entries) {
          await t.tap(menu);
          await t.pumpAndSettle();
          final drawer = find.byType(Drawer);
          Finder inDrawer(String s) => find.descendant(of: drawer, matching: find.text(s));
          final pages = entry.value;
          final isMenu = !(pages.length == 1 && pages.first.$1 == entry.key);
          if (isMenu && inDrawer(pages.first.$1).evaluate().isEmpty) {
            await t.tap(inDrawer(entry.key).first);
            await t.pumpAndSettle();
          }
          for (final p in pages) {
            await t.ensureVisible(inDrawer(p.$1).last);
            expect(inDrawer(p.$1), findsWidgets, reason: '${entry.key} > ${p.$1}');
          }
          final last = pages.last;
          await t.ensureVisible(inDrawer(last.$1).last);
          await t.pumpAndSettle();
          await t.tap(inDrawer(last.$1).last);
          await t.pumpAndSettle();
          expect(router.state.uri.path, last.$2, reason: '${entry.key} > ${last.$1}');
          expect(drawer, findsNothing, reason: 'the drawer closes after choosing a page');
        }
      });
    }

    testWidgets('the menu button names where you are, and the drawer opens on that module', (t) async {
      final sem = t.ensureSemantics();
      await pumpNav(t, const Size(720, 900), initial: '/dashboards/sales');
      expect(find.text('Dashboards'), findsOneWidget);
      await t.tap(find.byTooltip('All pages'));
      await t.pumpAndSettle();
      final sales = find.descendant(of: find.byType(Drawer), matching: find.text('Sales'));
      expect(sales, findsOneWidget, reason: 'current module starts open');
      expect(t.getSemantics(sales), isSemantics(isSelected: true));
      sem.dispose();
    });

    testWidgets('Escape closes the drawer and focus returns to the menu button', (t) async {
      await pumpNav(t, const Size(720, 900));
      await _tabTo(t, find.byTooltip('All pages'));
      await _key(t, LogicalKeyboardKey.enter);
      expect(find.byType(Drawer), findsOneWidget);
      await _key(t, LogicalKeyboardKey.escape);
      expect(find.byType(Drawer), findsNothing);
      expect(_hasFocus(t, find.byTooltip('All pages')), isTrue);
    });

    testWidgets('the search icon opens the search box when the field is folded away', (t) async {
      final router = await pumpNav(t, const Size(390, 700));
      await t.tap(find.byTooltip('Search'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), '1099000137');
      await t.testTextInput.receiveAction(TextInputAction.search);
      await t.pumpAndSettle();
      expect(router.state.uri.toString(), '/jobs?q=1099000137');
    });
  });

  testWidgets('Sign out ends the session', (t) async {
    await pumpNav(t, _wide);
    await t.tap(find.byTooltip('Heather Vera'));
    await t.pumpAndSettle();
    await t.tap(find.text('Sign out'));
    await t.pumpAndSettle();
    expect(AuthSession.instance.isLoggedIn, isFalse);
  });

  testWidgets('every width and text size fits: labelled modules or the menu button, never half a bar', (t) async {
    for (final scale in const [1.0, 1.3, 1.6]) {
      for (var w = 320.0; w <= 2560; w += w < 1100 ? 20 : 80) {
        await pumpNav(t, Size(w, 300), textScale: scale);
        final collapsed = find.byTooltip('All pages').evaluate().isNotEmpty;
        if (!collapsed) {
          for (final label in ['My Office', 'Projects', 'Calendar', 'Inventory', 'HR', 'Dashboards']) {
            final r = t.getRect(find.text(label));
            expect(r.right <= w && r.left >= 0, isTrue, reason: '$label clipped at $w px x$scale');
          }
        }
        expect(t.getRect(find.byTooltip('Heather Vera')).right <= w, isTrue, reason: 'account cut off at $w x$scale');
      }
    }
  });
}

