// Purchase orders: the list (lib/purchase_orders_screen.dart), the PO page (lib/purchase_order_detail_screen.dart) and
// the printed PO (lib/purchase_order_pdf.dart), against the fake backend in purchase_orders_fixture.dart.
//   flutter test test/purchase_orders_test.dart

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:iohd_desktop/main.dart' show officeTheme;
import 'package:iohd_desktop/purchase_order_detail_screen.dart';
import 'package:iohd_desktop/purchase_order_pdf.dart';
import 'package:iohd_desktop/purchase_orders_api.dart';
import 'package:iohd_desktop/purchase_orders_screen.dart';
import 'package:iohd_desktop/widgets/app_dialog.dart';
import 'package:iohd_desktop/widgets/flat_page.dart';

import 'nav_fixture.dart';
import 'purchase_orders_fixture.dart';

Future<void> _pump(WidgetTester t, Widget screen) async {
  await t.pumpWidget(MaterialApp(theme: officeTheme(), home: screen));
  await t.pumpAndSettle();
}

Finder _rich(String text) => find.text(text, findRichText: true);
Finder _inRows(String text) => find.descendant(of: find.byType(FlatTableRow), matching: find.text(text));
Finder _inDialog(Finder f) => find.descendant(of: find.byType(AppDialog), matching: f);

/// The text drawn on the pages: with compression off the pdf package draws each word as its own "[(word)]TJ".
String _printed(List<int> bytes) {
  final raw = latin1.decode(bytes);
  return [
    for (final m in RegExp(r'\[\(((?:\\.|[^\\)])*)\)\]TJ').allMatches(raw)) m.group(1)!.replaceAllMapped(RegExp(r'\\(.)'), (x) => x.group(1)!),
  ].join(' ');
}

void main() {
  setUp(() => navSignIn());

  group('the list', () {
    testWidgets('shows what is on order, what is late and what is partly in', (t) async {
      poView(t);
      final s = FakePoServer();
      await http.runWithClient(() => _pump(t, const PurchaseOrdersScreen()), () => s.client);

      for (final n in ['PO-2026-1001', 'PO-2026-1002', 'PO-2026-1003', 'PO-2026-1004', 'PO-2026-1005', 'PO-2026-1006']) {
        expect(find.text(n), findsOneWidget, reason: n);
      }
      expect(_inRows('Past due'), findsOneWidget);
      expect(_inRows('Partly received'), findsOneWidget);
      expect(_inRows('Draft'), findsOneWidget);
      expect(find.textContaining('5 days late', findRichText: true), findsOneWidget);
      expect(find.textContaining('In 3 days', findRichText: true), findsOneWidget);
      // On order: 172.50 + 755.00 + 860.00. Past due: PO-2026-1001 alone.
      expect(find.text('On order (3)'), findsOneWidget);
      expect(find.text('\$1,787.50'), findsOneWidget);
      expect(find.text('Past due (1)'), findsOneWidget);
      expect(find.text('Due this week (1)'), findsOneWidget);
      expect(find.text('Received (30 days)'), findsOneWidget);
      expect(find.text('6 purchase orders'), findsOneWidget);
    });

    testWidgets('a status chip narrows the list, and each chip says how many it holds', (t) async {
      poView(t);
      final s = FakePoServer();
      await http.runWithClient(() async {
        await _pump(t, const PurchaseOrdersScreen());
        final open = find.widgetWithText(ChoiceChip, 'Open');
        expect(find.descendant(of: open, matching: find.text('3')), findsOneWidget);
        await t.tap(find.widgetWithText(ChoiceChip, 'Past due'));
        await t.pumpAndSettle();
      }, () => s.client);
      expect(find.text('PO-2026-1001'), findsOneWidget);
      expect(find.text('PO-2026-1002'), findsNothing);
      expect(find.text('1 matching'), findsOneWidget);
    });

    testWidgets('search finds a PO by a part on it, and Clear brings the rest back', (t) async {
      poView(t);
      final s = FakePoServer();
      await http.runWithClient(() async {
        await _pump(t, const PurchaseOrdersScreen());
        await t.enterText(find.byType(TextField), 'remote');
        await t.pumpAndSettle();
        expect(find.text('PO-2026-1002'), findsOneWidget);
        expect(find.text('PO-2026-1001'), findsNothing);
        await t.tap(find.byTooltip('Clear search'));
        await t.pumpAndSettle();
      }, () => s.client);
      expect(find.text('PO-2026-1001'), findsOneWidget);
    });

    testWidgets('sorting by total puts the biggest order first', (t) async {
      poView(t);
      final s = FakePoServer();
      await http.runWithClient(() async {
        await _pump(t, const PurchaseOrdersScreen());
        await t.tap(find.text('Total'));
        await t.pumpAndSettle();
      }, () => s.client);
      final y = [for (final n in ['PO-2026-1005', 'PO-2026-1006', 'PO-2026-1002', 'PO-2026-1003']) t.getTopLeft(find.text(n)).dy];
      expect(y, orderedEquals([...y]..sort()));
    });

    testWidgets('a row opens the PO page', (t) async {
      poView(t);
      final s = FakePoServer();
      await http.runWithClient(() async {
        await _pump(t, const PurchaseOrdersScreen());
        await t.tap(find.text('PO-2026-1002'));
        await t.pumpAndSettle();
      }, () => s.client);
      expect(find.byType(PurchaseOrderDetailScreen), findsOneWidget);
      expect(_rich('Opener | 8500W Wall Mount'), findsOneWidget);
      expect(find.text('Receive'), findsOneWidget);
    });

    testWidgets('a failed load says so, and Try again recovers', (t) async {
      poView(t);
      final s = FakePoServer()..failWith = 500;
      await http.runWithClient(() async {
        await _pump(t, const PurchaseOrdersScreen());
        expect(find.text("Purchase orders didn't load"), findsOneWidget);
        s.failWith = null;
        await t.tap(find.text('Try again'));
        await t.pumpAndSettle();
      }, () => s.client);
      expect(find.text('PO-2026-1001'), findsOneWidget);
    });

    testWidgets('with no POs yet it offers to create one', (t) async {
      poView(t);
      final s = FakePoServer(seed: false);
      await http.runWithClient(() => _pump(t, const PurchaseOrdersScreen()), () => s.client);
      expect(find.text('No purchase orders yet'), findsOneWidget);
      expect(find.text('New purchase order'), findsOneWidget);
    });
  });

  group('the PO page', () {
    testWidgets('reads the order: where it stands, its parts, totals and facts', (t) async {
      poView(t);
      final s = FakePoServer();
      await http.runWithClient(() => _pump(t, const PurchaseOrderDetailScreen(orderId: 1)), () => s.client);
      expect(find.text('5 days past due'), findsOneWidget);
      expect(_rich('Torsion spring | 250 x 2 x 32'), findsOneWidget);
      expect(find.text('Part # TS-250'), findsOneWidget);
      expect(find.text('\$172.50'), findsWidgets); // 2 x 48.75 + 4 x 12.50 + 25.00 shipping
      expect(find.text('\$25.00'), findsOneWidget);
      expect(find.text('SO-88123'), findsWidgets);
      expect(find.text('Receive'), findsOneWidget);
      expect(find.text('Edit'), findsOneWidget);
    });

    testWidgets('receiving part of it keeps it open; receiving the rest closes it', (t) async {
      poView(t);
      final s = FakePoServer();
      await http.runWithClient(() async {
        await _pump(t, const PurchaseOrderDetailScreen(orderId: 1));
        await t.tap(find.text('Receive'));
        await t.pumpAndSettle();
        final boxes = _inDialog(find.byType(TextField));
        expect(boxes, findsNWidgets(2));
        // More than is due is refused.
        await t.enterText(boxes.first, '5');
        await t.pump();
        expect(find.text('Only 2 due'), findsOneWidget);
        await t.enterText(boxes.first, '2');
        await t.enterText(boxes.last, '1');
        await t.pump();
        await t.tap(find.text('Receive 3 units'));
        await t.pumpAndSettle();
        var body = s.lastBody;
        expect([for (final l in body['lines'] as List) l['received']], [2, 1]);
        expect(body['status'], 'Open');
        expect(find.text('Received 3 units. 3 still on order.'), findsOneWidget);

        await t.tap(find.text('Receive'));
        await t.pumpAndSettle();
        expect(_inDialog(find.text('All in')), findsOneWidget);
        await t.tap(find.text('Receive 3 units'));
        await t.pumpAndSettle();
        body = s.lastBody;
        expect(body['status'], 'Received');
        expect(body['receivedDate'], poIso(poToday()));
      }, () => s.client);
      expect(find.text('Everything is in. PO-2026-1001 is marked Received.'), findsOneWidget);
      expect(find.text('Receive'), findsNothing);
    });

    testWidgets('a draft is marked ordered today', (t) async {
      poView(t);
      final s = FakePoServer();
      await http.runWithClient(() async {
        await _pump(t, const PurchaseOrderDetailScreen(orderId: 4));
        expect(find.text('Draft, not ordered yet'), findsOneWidget);
        await t.tap(find.text('Mark ordered'));
        await t.pumpAndSettle();
      }, () => s.client);
      expect(s.lastBody['status'], 'Open');
      expect(s.lastBody['orderDate'], poIso(poToday()));
      expect(find.text('Ordered today'), findsOneWidget);
    });

    testWidgets("editing adds a catalog part at this vendor's price, and Save sends the new total", (t) async {
      poView(t);
      final s = FakePoServer();
      await http.runWithClient(() async {
        await _pump(t, const PurchaseOrderDetailScreen(orderId: 4, catalogSearch: fakeCatalogSearch));
        await t.tap(find.text('Edit'));
        await t.pumpAndSettle();
        await t.enterText(find.widgetWithText(TextField, 'Add another part'), 'spring');
        await t.pump(const Duration(milliseconds: 400));
        await t.pumpAndSettle();
        await t.tap(_rich('Torsion spring | 250 x 2 x 32').last);
        await t.pumpAndSettle();
        // Clopay is this PO's vendor, so its price (not iStore's, not the catalog cost) is filled in.
        expect(find.widgetWithText(TextField, '48.75'), findsOneWidget);
        expect(find.text('\$108.72'), findsNWidgets(2)); // parts and total: 3 x 19.99 + 48.75, no shipping
        await t.tap(find.text('Save'));
        await t.pumpAndSettle();
      }, () => s.client);
      final lines = s.lastBody['lines'] as List;
      expect(lines, hasLength(2));
      expect(lines[1], containsPair('unitCost', 48.75));
      expect(lines[1], containsPair('productId', 12));
      expect(s.lastBody['updatedAt'], isNotNull, reason: 'the copy it was made on goes with the edit');
      expect(s.orders[4]!['total'], 108.72);
      expect(find.text('PO-2026-1004 saved.'), findsOneWidget);
    });

    testWidgets('a new PO says what is missing, then is created and numbered', (t) async {
      poView(t);
      final s = FakePoServer();
      await http.runWithClient(() async {
        await _pump(t, const PurchaseOrderDetailScreen(catalogSearch: fakeCatalogSearch));
        expect(find.text('New purchase order'), findsOneWidget);
        await t.tap(find.text('Create PO'));
        await t.pumpAndSettle();
        expect(find.text('2 things need a fix before this can be saved.'), findsOneWidget);
        expect(find.text('Enter the vendor.'), findsOneWidget);
        expect(s.sent('POST'), isEmpty);

        await t.enterText(find.widgetWithText(TextField, 'Who the order is placed with'), 'Clopay');
        await t.enterText(find.widgetWithText(TextField, 'Add a part: search products by name or part number'), 'remote');
        await t.pump(const Duration(milliseconds: 400));
        await t.pumpAndSettle();
        await t.tap(_rich('Remote | 893MAX').last);
        await t.pumpAndSettle();
        await t.tap(find.text('Create PO'));
        await t.pumpAndSettle();
      }, () => s.client);
      final body = json.decode(s.sent('POST').single.body) as Map<String, dynamic>;
      expect(body['vendor'], 'Clopay');
      expect(body['status'], 'Open');
      expect((body['lines'] as List).single, containsPair('unitCost', 21.0)); // no vendor price: the catalog cost
      expect(find.text('PO-2026-1007'), findsWidgets);
      expect(find.text('PO-2026-1007 created.'), findsOneWidget);
    });

    testWidgets('an edit on a stale copy is refused, and Reload PO shows the saved one', (t) async {
      poView(t);
      final s = FakePoServer()..conflictNext = true;
      await http.runWithClient(() async {
        await _pump(t, const PurchaseOrderDetailScreen(orderId: 2));
        await t.tap(find.text('Edit'));
        await t.pumpAndSettle();
        await t.enterText(find.widgetWithText(TextField, 'Second opener is on backorder until next week.'), 'Changed');
        await t.pump();
        await t.tap(find.text('Save'));
        await t.pumpAndSettle();
        expect(find.textContaining('Someone else changed this PO'), findsOneWidget);
        await t.tap(find.text('Reload PO'));
        await t.pumpAndSettle();
        await t.tap(find.text('Discard changes'));
        await t.pumpAndSettle();
      }, () => s.client);
      expect(find.text('Second opener is on backorder until next week.'), findsOneWidget);
      expect(find.text('Save'), findsNothing);
    });

    testWidgets('an older server keeps the total only, and is not sent parts it would drop', (t) async {
      poView(t);
      final s = FakePoServer()..features = false;
      await http.runWithClient(() async {
        await _pump(t, const PurchaseOrderDetailScreen(orderId: 6));
        expect(find.text('PO-2026-1006'), findsWidgets);
        expect(find.textContaining('once the server is updated'), findsOneWidget);
        await t.tap(find.text('Edit'));
        await t.pumpAndSettle();
        await t.enterText(find.widgetWithText(TextField, '860.00'), '900');
        await t.pump();
        await t.tap(find.text('Save'));
        await t.pumpAndSettle();
      }, () => s.client);
      expect(s.lastBody.containsKey('lines'), isFalse);
      expect(s.lastBody['total'], 900);
    });

    testWidgets('Cancel PO asks first; leaving an edit with changes asks before dropping them', (t) async {
      poView(t);
      final s = FakePoServer();
      await http.runWithClient(() async {
        await _pump(t, const PurchaseOrderDetailScreen(orderId: 2));
        await t.tap(find.text('Edit'));
        await t.pumpAndSettle();
        await t.enterText(find.widgetWithText(TextField, 'Second opener is on backorder until next week.'), 'Changed');
        await t.pump();
        await t.tap(find.text('Cancel'));
        await t.pumpAndSettle();
        expect(find.text('Discard your changes?'), findsOneWidget);
        await t.tap(find.text('Keep editing'));
        await t.pumpAndSettle();
        expect(find.text('Save'), findsOneWidget);
        await t.tap(find.text('Cancel'));
        await t.pumpAndSettle();
        await t.tap(find.text('Discard changes'));
        await t.pumpAndSettle();
        expect(s.sent('PUT'), isEmpty);

        await t.tap(find.text('More'));
        await t.pumpAndSettle();
        await t.tap(find.text('Cancel PO'));
        await t.pumpAndSettle();
        expect(find.text('Cancel PO-2026-1002?'), findsOneWidget);
        await t.tap(_inDialog(find.text('Cancel PO')));
        await t.pumpAndSettle();
      }, () => s.client);
      expect(s.lastBody['status'], 'Canceled');
      expect(find.text('Canceled'), findsWidgets);
    });

    testWidgets('Delete asks, then removes the PO', (t) async {
      poView(t);
      final s = FakePoServer();
      await http.runWithClient(() async {
        await _pump(t, const PurchaseOrderDetailScreen(orderId: 5));
        await t.tap(find.text('More'));
        await t.pumpAndSettle();
        await t.tap(find.text('Delete PO'));
        await t.pumpAndSettle();
        expect(find.text('Delete PO-2026-1005?'), findsOneWidget);
        await t.tap(_inDialog(find.text('Delete PO')));
        await t.pumpAndSettle();
      }, () => s.client);
      expect(s.sent('DELETE'), hasLength(1));
      expect(s.orders.containsKey(5), isFalse);
    });

    testWidgets('a PO that is gone says so', (t) async {
      poView(t);
      final s = FakePoServer();
      await http.runWithClient(() => _pump(t, const PurchaseOrderDetailScreen(orderId: 99)), () => s.client);
      expect(find.text('That purchase order is not on file'), findsOneWidget);
    });

    testWidgets('fits a phone-width window', (t) async {
      poView(t, const Size(400, 900));
      final s = FakePoServer();
      await http.runWithClient(() => _pump(t, const PurchaseOrderDetailScreen(orderId: 2)), () => s.client);
      expect(t.takeException(), isNull);
      expect(_rich('Remote | 893MAX'), findsOneWidget);
    });
  });

  test('the printed PO lists the parts, totals and who ordered it', () async {
    final po = PurchaseOrder.fromJson({
      'id': 1, 'poNumber': 'PO-2026-1001', 'vendor': 'Clopay', 'status': 'Open', 'orderDate': '2026-11-13', //
      'expectedDate': '2026-11-20', 'shipping': 25, 'total': 172.5, 'vendorRef': 'SO-88123', 'jobNumber': '1096183137',
      'lines': [
        {'name': 'Torsion spring | 250 x 2 x 32', 'sku': 'TS-250', 'qty': 2, 'unitCost': 48.75},
        {'name': 'Lift cable | 8 ft', 'sku': 'LC-8', 'qty': 4, 'unitCost': 12.5},
      ],
    });
    final text = _printed(await buildPurchaseOrderPdf(po, preparedBy: 'Heather Vera', compress: false));
    for (final want in ['PO-2026-1001', 'Clopay', 'SO-88123', '1096183137', 'Torsion', 'TS-250', r'$97.50', r'$25.00', r'$172.50', 'Heather']) {
      expect(text, contains(want), reason: want);
    }
    expect(purchaseOrderPdfFileName(po), 'PO-2026-1001.pdf');
  });
}
