// /customers?q=... (the nav bar search, a job page's customer link) starts the Customers list on that search, and a
// new search while the list is open replaces it.
// Run:  flutter test test/customers_query_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/customers_screen.dart';

void main() {
  testWidgets('Customers searches for ?q= on open and for each new ?q= after', (t) async {
    t.view.physicalSize = const Size(1400, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);

    final asked = <String>[];
    final router = GoRouter(
      initialLocation: '/customers?q=Smith',
      routes: [
        GoRoute(
          path: '/customers',
          builder: (context, state) => CustomersScreen(initialQuery: state.uri.queryParameters['q']),
        ),
      ],
    );
    await http.runWithClient(() async {
      await t.pumpWidget(MaterialApp.router(routerConfig: router));
      await t.pump(const Duration(milliseconds: 100));
      router.go('/customers?q=Jones%20Builders');
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 600)); // past the search debounce: nothing else may fire
    }, () => MockClient((req) async {
          if (req.url.path.endsWith('/api/customers')) asked.add(req.url.queryParameters['q'] ?? '');
          return http.Response('{"data": [], "total": 0, "totalPages": 1}', 200);
        }));

    expect(asked.first, 'Smith', reason: 'the first load is the search, not the whole list');
    expect(asked, contains('Jones Builders'));
    expect(asked.where((q) => q.isEmpty), isEmpty, reason: 'no unfiltered load slipped in');
    expect(find.widgetWithText(TextField, 'Jones Builders'), findsOneWidget);
  });
}
