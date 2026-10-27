// Renders the Invoices screen with fake API data to test/shots/. Run:  flutter test test/invoices_render_test.dart --update-goldens

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/invoices_screen.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

final _requests = <Uri>[];

http.Client _mock({bool empty = false, int? failCode}) => MockClient((req) async {
      _requests.add(req.url);
      if (failCode != null) return http.Response('boom', failCode);
      const rows = [
        {'id': 1, 'number': 4011, 'customer': 'Walton Logistics', 'po_number': 'PO-77', 'is_paid': false, 'overdue': false, 'total': '8500.00', 'invoice_date': '2026-10-15T05:00:00Z', 'due_date': '2026-11-14T05:00:00Z'},
        {'id': 2, 'number': 4010, 'customer': 'Bob Vance With A Very Long Company Name Incorporated', 'is_paid': false, 'overdue': true, 'total': '1200.00', 'invoice_date': '2026-09-01T05:00:00Z', 'due_date': '2026-10-01T05:00:00Z'},
        {'id': 3, 'number': 4009, 'customer': 'Rogers Dental', 'is_paid': true, 'overdue': false, 'total': '640.50', 'invoice_date': '2026-09-20T05:00:00Z', 'due_date': null},
        {'id': 4, 'number': 4008, 'customer': '', 'is_paid': true, 'overdue': false, 'total': '99.00', 'invoice_date': null, 'due_date': null},
      ];
      return http.Response(
        jsonEncode({
          'data': empty ? [] : rows,
          'total': empty ? 0 : 812,
          'totalPages': empty ? 1 : 17,
          'stats': {'awaiting': 9700.0, 'awaitingCount': 2, 'overdue': 1200.0, 'overdueCount': 1, 'invoiced30d': 34500.0},
        }),
        200,
      );
    });

Future<void> _shot(WidgetTester t, Size size, String name, http.Client client) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  await http.runWithClient(() async {
    await t.pumpWidget(RepaintBoundary(
      key: const ValueKey('shot'),
      child: MaterialApp(theme: ThemeData(useMaterial3: true, fontFamily: 'Segoe UI'), home: const InvoicesScreen()),
    ));
    await t.pumpAndSettle();
  }, () => client);
  expect(t.takeException(), isNull);
  await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('shots/$name.png'));
}

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', ['C:/Windows/Fonts/segoeui.ttf', 'C:/Windows/Fonts/segoeuib.ttf']);
  });

  testWidgets('real rows, no sample data', (t) async {
    await _shot(t, const Size(1366, 720), 'invoices_data', _mock());
    expect(find.text('INV-4011'), findsNothing); // the old dummy ids
    expect(find.text('Walton Logistics'), findsOneWidget);
    expect(find.text('Overdue'), findsWidgets);
    expect(find.text('Page 1 of 17'), findsOneWidget);
  });

  testWidgets('empty', (t) async => _shot(t, const Size(1366, 720), 'invoices_empty', _mock(empty: true)));
  testWidgets('error shows retry', (t) async {
    await _shot(t, const Size(1366, 720), 'invoices_error', _mock(failCode: 500));
    expect(find.text('Try again'), findsOneWidget);
  });
  testWidgets('narrow', (t) async => _shot(t, const Size(520, 800), 'invoices_520', _mock()));

  testWidgets('filter and search go to the server', (t) async {
    t.view.physicalSize = const Size(1366, 720);
    t.view.devicePixelRatio = 1;
    _requests.clear();
    await http.runWithClient(() async {
      await t.pumpWidget(const MaterialApp(home: InvoicesScreen()));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(ChoiceChip, 'Overdue'));
      await t.pumpAndSettle();
      expect(_requests.last.queryParameters['status'], 'overdue');
      await t.enterText(find.byType(TextField), 'vance');
      await t.pump(const Duration(milliseconds: 500));
      await t.pumpAndSettle();
    }, () => _mock());
    expect(_requests.last.queryParameters['q'], 'vance');
    expect(_requests.last.queryParameters['status'], 'overdue');
    expect(_requests.last.queryParameters['page'], '1');
  });
}
