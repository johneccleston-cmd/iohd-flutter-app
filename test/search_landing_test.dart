// Where the top bar's search lands for records with no page of their own: Invoices and Purchase Orders read ?q=, both
// on first open and when the screen is already open behind another filter.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/invoices_screen.dart';
import 'package:iohd_desktop/purchase_orders_screen.dart';

import 'nav_fixture.dart';

final _orders = json.encode({
  'success': true,
  'purchaseOrders': [
    {'id': 1, 'poNumber': 'PO-2026-1001', 'vendor': 'Clopay', 'status': 'Open', 'total': 100, 'orderDate': '2026-10-01'},
    {'id': 2, 'poNumber': 'PO-2026-1002', 'vendor': 'Amarr', 'status': 'Received', 'total': 200, 'orderDate': '2026-10-02'},
  ],
});

Widget _app(Widget child) => MaterialApp(home: child);

void main() {
  setUp(() => navSignIn());

  group('Invoices', () {
    late List<Uri> asked;
    late http.Client client;

    setUp(() {
      asked = [];
      client = MockClient((req) async {
        asked.add(req.url);
        return http.Response(json.encode({'data': [], 'total': 0, 'totalPages': 1, 'stats': {}}), 200);
      });
    });

    testWidgets('opens already searching', (t) async {
      await http.runWithClient(() async {
        await t.pumpWidget(_app(const InvoicesScreen(initialQuery: '48213')));
        await t.pumpAndSettle();
      }, () => client);
      expect(asked.last.queryParameters['q'], '48213');
    });

    testWidgets('a new search while open replaces the old one and clears the filter', (t) async {
      await http.runWithClient(() async {
        await t.pumpWidget(_app(const InvoicesScreen(initialQuery: '48213')));
        await t.pumpAndSettle();
        await t.pumpWidget(_app(const InvoicesScreen(initialQuery: '50000')));
        await t.pumpAndSettle();
      }, () => client);
      expect(asked.last.queryParameters['q'], '50000');
      expect(asked.last.queryParameters['status'], 'all');
    });
  });

  group('Purchase Orders', () {
    final client = MockClient((req) async => http.Response(_orders, 200));

    testWidgets('opens narrowed to the search, with it in the box', (t) async {
      t.view.physicalSize = const Size(1400, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await http.runWithClient(() async {
        await t.pumpWidget(_app(const PurchaseOrdersScreen(initialQuery: 'PO-2026-1002')));
        await t.pumpAndSettle();
      }, () => client);
      expect(find.text('PO-2026-1002'), findsWidgets);
      expect(find.text('PO-2026-1001'), findsNothing);
    });

    testWidgets('a new search while open replaces the old one and clears the status', (t) async {
      t.view.physicalSize = const Size(1400, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await http.runWithClient(() async {
        await t.pumpWidget(_app(const PurchaseOrdersScreen(initialQuery: 'Clopay')));
        await t.pumpAndSettle();
        await t.tap(find.widgetWithText(ChoiceChip, 'Open'));
        await t.pumpAndSettle();
        await t.pumpWidget(_app(const PurchaseOrdersScreen(initialQuery: 'Amarr')));
        await t.pumpAndSettle();
      }, () => client);
      expect(find.text('PO-2026-1002'), findsOneWidget);
      expect(find.text('PO-2026-1001'), findsNothing);
    });
  });
}
