// The top bar across sign-in changes on the real app (the router in lib/main.dart, real screens, fake API): sign out
// from an admin session, sign in as a restricted account, then as an admin again. The bar must show only what the
// account may open from its very first frame, and the router must refuse typed addresses for the rest.
// Run:  flutter test test/nav_session_test.dart

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/config/auth_session.dart';
import 'package:iohd_desktop/main.dart' as app;
import 'package:iohd_desktop/widgets/main_navigation_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _restrictedDenied = [
  'stock.view', 'catalog.view', 'purchase_orders.view', 'vendors.view', //
  'hr_payroll.view', 'projects.view', 'payments.view',
];

String _token() {
  final payload = base64Url.encode(utf8.encode(json.encode({'exp': DateTime(2100).millisecondsSinceEpoch})));
  return '$payload.sig';
}

/// The [label] that is in the top bar (y < 60), not one of the same words on the page below it.
Finder _inBar(String label) {
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
  testWidgets('the bar follows whoever is signed in, from the first frame', (t) async {
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

    var nextLogin = 'bella';
    final done = Completer<void>();
    runZonedGuarded(
      () => http.runWithClient(() async {
        app.main();
        await t.pump(const Duration(milliseconds: 500));
        GoRouter router() => GoRouter.of(t.element(find.byType(MainNavigationShell)));

        // An admin uses a few pages through the menus.
        for (final (module, page) in [('HR', 'Payroll'), ('Dashboards', 'Sales'), ('My Office', 'Customers')]) {
          await t.tap(_inBar(module));
          await _settle(t);
          await t.tap(_inMenu(page));
          await _settle(t);
        }
        expect(router().state.uri.path, '/customers');

        // Signing out leaves the shell for the sign-in screen.
        AuthSession.instance.logout();
        await _settle(t);
        expect(find.byType(MainNavigationShell), findsNothing);
        expect(find.text('Sign in with your username and PIN.'), findsOneWidget);

        // A restricted account: the first frame of the bar already leaves out what it can't open.
        await AuthSession.instance.login('bella', '1234');
        await t.pump();
        await t.pump();
        expect(find.byType(MainNavigationShell), findsOneWidget);
        expect(_inBar('Inventory'), findsNothing, reason: 'every Inventory page is switched off');
        expect(_inBar('Projects'), findsNothing);
        await _settle(t);
        await t.tap(_inBar('HR'));
        await _settle(t);
        expect(_inMenu("KPI's"), findsOneWidget);
        expect(_inMenu('Payroll'), findsNothing);
        expect(_inMenu('Team'), findsNothing, reason: 'Team is for admins');
        await t.tapAt(const Offset(1300, 700));
        await _settle(t);
        await t.tap(_inBar('My Office'));
        await _settle(t);
        expect(_inMenu('Payments'), findsNothing);
        expect(_inMenu('Invoices'), findsOneWidget);
        await t.tapAt(const Offset(1300, 700));
        await _settle(t);

        // Typing the address of a page it can't open still lands somewhere it can.
        for (final blocked in ['/hr/payroll', '/hr/team', '/inventory/vendors', '/projects', '/payments']) {
          router().go(blocked);
          await _settle(t);
          expect(router().state.uri.path, '/calendar', reason: '$blocked should be refused');
        }

        // Back to an admin: everything returns.
        AuthSession.instance.logout();
        await _settle(t);
        nextLogin = 'admin';
        await AuthSession.instance.login('admin', '1234');
        await t.pump();
        await t.pump();
        expect(_inBar('Inventory'), findsOneWidget);
        expect(_inBar('Projects'), findsOneWidget);
        await _settle(t);
        await t.tap(_inBar('HR'));
        await _settle(t);
        expect(_inMenu('Payroll'), findsOneWidget);
        expect(_inMenu('Team'), findsOneWidget);
        await t.tapAt(const Offset(1300, 700));
        await t.pump(const Duration(seconds: 2));
      }, () => MockClient((req) async {
            if (req.url.path == '/login') {
              final admin = nextLogin == 'admin';
              return http.Response(
                json.encode({
                  'token': _token(),
                  'name': admin ? 'Ryan Schwartz' : 'Bella Ortiz',
                  'role': 'Office Manager',
                  'is_admin': admin,
                  'access_denied': admin ? <String>[] : _restrictedDenied,
                }),
                200,
              );
            }
            if (req.url.path == '/users') return http.Response('[]', 200);
            return http.Response(req.url.path.contains('list') ? '[]' : '{}', 200);
          })).whenComplete(done.complete),
      (e, s) => errors.add('ASYNC $e\n${s.toString().split('\n').take(8).join('\n')}'),
    );
    await done.future;
    FlutterError.onError = oldOnError;

    expect(errors, isEmpty, reason: errors.join('\n\n====\n\n'));
  });
}
