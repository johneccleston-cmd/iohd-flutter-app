// Hops between every page of the real app (real router, shell and selection wrapper) while requests are still in
// flight, and fails on any exception. A build/layout exception there is what shows as a blank grey page in release.
// Run:  flutter test test/nav_stress_test.dart

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/main.dart' as app;
import 'package:iohd_desktop/widgets/main_navigation_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _routes = [
  '/calendar', '/customers', '/projects', '/estimates', '/jobs', '/statuses', '/payments', '/invoices', '/documents',
  '/inventory', '/inventory/catalog', '/inventory/purchase-orders', '/inventory/vendors',
  '/hr/payroll', '/hr/kpis', '/hr/team', '/hr/corrections',
  '/dashboards/financial', '/dashboards/commissions', '/dashboards/technicians', '/dashboards/inventory',
  '/dashboards/jobs', '/dashboards/estimates', '/dashboards/sales', '/dashboards/collections',
];

void main() {
  testWidgets('switching pages mid-load never throws', (t) async {
    t.view.physicalSize = const Size(1500, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);

    final payload = base64Url.encode(utf8.encode(json.encode({'exp': DateTime(2100).millisecondsSinceEpoch})));
    SharedPreferences.setMockInitialValues({
      'iohd_auth_session': json.encode({'token': '$payload.sig', 'name': 'Test', 'role': 'admin', 'is_admin': true, 'denied': []}),
    });

    final errors = <String>[];
    final oldOnError = FlutterError.onError;
    FlutterError.onError = (d) => errors.add('${d.exceptionAsString()}\n${d.stack.toString().split('\n').take(12).join('\n')}');
    addTearDown(() => FlutterError.onError = oldOnError);

    final rng = Random(7);
    final done = Completer<void>();
    runZonedGuarded(() => http.runWithClient(() async {
      app.main();
      await t.pump(const Duration(milliseconds: 500));
      final router = GoRouter.of(t.element(find.byType(MainNavigationShell)));
      for (var round = 0; round < 3; round++) {
        final order = [..._routes]..shuffle(rng);
        for (final r in order) {
          router.go(r);
          // Sometimes leave before the data lands, sometimes after.
          for (var i = 0; i < 1 + rng.nextInt(6); i++) {
            await t.pump(Duration(milliseconds: rng.nextInt(120)));
          }
        }
      }
      await t.pump(const Duration(seconds: 2));
    }, () => MockClient((req) async {
          await Future<void>.delayed(Duration(milliseconds: rng.nextInt(300)));
          return http.Response(req.url.path.contains('list') ? '[]' : '{}', 200);
        })).whenComplete(done.complete), (e, s) => errors.add('ASYNC $e\n${s.toString().split('\n').take(12).join('\n')}'));
    await done.future;
    FlutterError.onError = oldOnError;

    expect(errors, isEmpty, reason: errors.join('\n\n====\n\n'));
  });
}
