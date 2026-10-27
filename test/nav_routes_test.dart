// Clicks every page in the top bar's menus on the real app (the router in lib/main.dart and the real screens, with a
// fake API) and checks each one opens its own screen, never GoRouter's "Page Not Found", with no exception.
// Signing in and out is in nav_session_test.dart.
// Run:  flutter test test/nav_routes_test.dart

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/main.dart' as app;
import 'package:iohd_desktop/widgets/main_navigation_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

// (module in the bar, page in its menu or null for a page of its own, where it must land)
const _pages = [
  ('My Office', 'Customers', '/customers'),
  ('My Office', 'Estimates', '/estimates'),
  ('My Office', 'Jobs', '/jobs'),
  ('My Office', 'Estimate & Job Statuses', '/statuses'),
  ('My Office', 'Documents', '/documents'),
  ('My Office', 'Payments', '/payments'),
  ('My Office', 'Invoices', '/invoices'),
  ('My Office', 'Site Checks', '/site-checks'),
  ('My Office', 'Takeoffs', '/takeoffs'),
  ('Projects', null, '/projects'),
  ('Calendar', null, '/calendar'),
  ('Inventory', 'Stock Levels', '/inventory'),
  ('Inventory', 'Product Catalog', '/inventory/catalog'),
  ('Inventory', 'Purchase Orders', '/inventory/purchase-orders'),
  ('Inventory', 'Vendors', '/inventory/vendors'),
  ('HR', 'Payroll', '/hr/payroll'),
  ('HR', "KPI's", '/hr/kpis'),
  ('HR', 'Team', '/hr/team'),
  ('Dashboards', 'Financial', '/dashboards/financial'),
  ('Dashboards', 'Commissions', '/dashboards/commissions'),
  ('Dashboards', 'Technicians', '/dashboards/technicians'),
  ('Dashboards', 'Inventory', '/dashboards/inventory'),
  ('Dashboards', 'Jobs', '/dashboards/jobs'),
  ('Dashboards', 'Estimates', '/dashboards/estimates'),
  ('Dashboards', 'Sales', '/dashboards/sales'),
  ('Dashboards', 'Collections', '/dashboards/collections'),
];

String _token() {
  final payload = base64Url.encode(utf8.encode(json.encode({'exp': DateTime(2100).millisecondsSinceEpoch})));
  return '$payload.sig';
}

/// The [label] that is in the top bar (y < 60), not one of the same words on the page below it.
Finder _inBar(WidgetTester t, String label) {
  final hits = find.text(label).evaluate().where((e) {
    final box = e.renderObject as RenderBox?;
    return box != null && box.hasSize && box.localToGlobal(Offset.zero).dy < 60;
  }).toList();
  return find.byElementPredicate((e) => hits.contains(e));
}

Finder _inMenu(String label) => find.descendant(of: find.byType(MenuItemButton), matching: find.text(label));

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 120));
  }
}

void main() {
  testWidgets('every menu page opens its screen on the real router', (t) async {
    t.view.physicalSize = const Size(1500, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);

    SharedPreferences.setMockInitialValues({
      'iohd_auth_session': json.encode(
        {'token': _token(), 'name': 'Heather Vera', 'role': 'Office Manager', 'is_admin': true, 'denied': []},
      ),
    });

    final errors = <String>[];
    final oldOnError = FlutterError.onError;
    FlutterError.onError = (d) => errors.add('${d.exceptionAsString()}\n${d.stack.toString().split('\n').take(8).join('\n')}');
    addTearDown(() => FlutterError.onError = oldOnError);

    final failures = <String>[];
    final done = Completer<void>();
    runZonedGuarded(
      () => http.runWithClient(() async {
        app.main();
        await t.pump(const Duration(milliseconds: 500));
        GoRouter router() => GoRouter.of(t.element(find.byType(MainNavigationShell)));

        // 1. Every page, the way a person gets there: open the module's menu, click the page.
        for (final (module, page, path) in _pages) {
          await t.tap(_inBar(t, module));
          await _settle(t);
          if (page != null) {
            await t.tap(_inMenu(page));
            await _settle(t);
          }
          final at = router().state.uri.path;
          if (at != path) failures.add('$module > ${page ?? module} went to $at, not $path');
          if (find.text('Page Not Found').evaluate().isNotEmpty) failures.add('$module > ${page ?? module}: Page Not Found');
          if (find.byType(MenuItemButton).evaluate().isNotEmpty) failures.add('$module > ${page ?? module}: menu left open');
        }

        // 2. A direct link (a refresh or a bookmark) to a page that only the menu used to know about.
        router().go('/site-checks');
        await _settle(t);
        expect(find.text('Page Not Found'), findsNothing);
        expect(find.text('No site checks yet'), findsOneWidget);

        await t.pump(const Duration(seconds: 2));
      }, () => MockClient((req) async {
            if (req.url.path == '/users') return http.Response('[]', 200);
            return http.Response(req.url.path.contains('list') ? '[]' : '{}', 200);
          })).whenComplete(done.complete),
      (e, s) => errors.add('ASYNC $e\n${s.toString().split('\n').take(8).join('\n')}'),
    );
    await done.future;
    FlutterError.onError = oldOnError;

    expect(failures, isEmpty, reason: failures.join('\n'));
    expect(errors, isEmpty, reason: errors.join('\n\n====\n\n'));
  });
}
