// Renders the Payments screen with fake API data to test/shots/. Run:  flutter test test/payments_render_test.dart --update-goldens

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/payments_screen.dart';

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
        {'id': 'a', 'job_id': '1099563432', 'customer': 'John Bishop', 'payment_type': 'Credit Card (Offline)', 'transaction_type': 'Payment', 'reference_number': '0000', 'amount': 380.0, 'via_stripe': true, 'received_on': '2026-10-16T00:00:00Z'},
        {'id': 'b', 'job_id': '1094424959', 'customer': '911 Restoration', 'payment_type': 'Check', 'transaction_type': 'Payment', 'reference_number': '2682', 'amount': 1593.87, 'received_on': '2026-10-16T00:00:00Z'},
        {'id': 'c', 'job_id': '1094865244', 'customer': 'JDW Construction With A Very Long Company Name Incorporated', 'payment_type': 'Credit Card (Offline)', 'transaction_type': 'Payment', 'reference_number': 'Job Payment Database', 'amount': 2940.87, 'received_on': '2026-10-16T00:00:00Z'},
        {'id': 'd', 'job_id': '1099563432', 'customer': 'John Bishop', 'payment_type': 'Credit Card (Offline)', 'transaction_type': 'VOID', 'reference_number': 'Job Payment Database', 'amount': 0.0, 'received_on': '2026-10-16T09:54:29Z'},
        {'id': 'e', 'job_id': '1096961883', 'customer': 'Rogers Dental', 'payment_type': 'Check', 'transaction_type': 'REFUND', 'reference_number': '3242', 'amount': -150.0, 'received_on': '2026-10-14T00:00:00Z'},
      ];
      return http.Response(
        jsonEncode({
          'data': empty ? [] : rows,
          'total': empty ? 0 : 10930,
          'totalPages': empty ? 1 : 219,
          'stats': {'today': 0, 'month': 78271.57, 'monthCount': 38},
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
      child: MaterialApp(theme: ThemeData(useMaterial3: true, fontFamily: 'Segoe UI'), home: const PaymentsScreen()),
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
    await _shot(t, const Size(1366, 720), 'payments_data', _mock());
    expect(find.text('Sarah Jenkins'), findsNothing); // the old dummy row
    expect(find.text('John Bishop'), findsWidgets);
    expect(find.byTooltip('Paid through Stripe'), findsOneWidget); // only the row flagged by the server
    expect(find.text('Refund'), findsOneWidget);
    expect(find.text('Void'), findsOneWidget);
    expect(find.text('Page 1 of 219'), findsOneWidget);
  });

  testWidgets('empty', (t) async => _shot(t, const Size(1366, 720), 'payments_empty', _mock(empty: true)));
  testWidgets('error shows retry', (t) async {
    await _shot(t, const Size(1366, 720), 'payments_error', _mock(failCode: 500));
    expect(find.text('Try again'), findsOneWidget);
  });
  testWidgets('narrow', (t) async => _shot(t, const Size(520, 800), 'payments_520', _mock()));

  testWidgets('search sends the text to the server', (t) async {
    t.view.physicalSize = const Size(1366, 720);
    t.view.devicePixelRatio = 1;
    _requests.clear();
    await http.runWithClient(() async {
      await t.pumpWidget(MaterialApp(home: const PaymentsScreen()));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), 'bishop');
      await t.pump(const Duration(milliseconds: 500));
      await t.pumpAndSettle();
    }, () => _mock());
    expect(_requests.last.queryParameters['q'], 'bishop');
    expect(_requests.last.queryParameters['page'], '1');
  });

  testWidgets('clicking the job number opens that job', (t) async {
    t.view.physicalSize = const Size(1366, 720);
    t.view.devicePixelRatio = 1;
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, __) => const PaymentsScreen()),
      GoRoute(path: '/jobs/:id', builder: (_, s) => Scaffold(body: Text('JOB PAGE ${s.pathParameters['id']}'))),
    ]);
    await http.runWithClient(() async {
      await t.pumpWidget(MaterialApp.router(routerConfig: router));
      await t.pumpAndSettle();
      expect(find.text('Oct 16, 2026'), findsWidgets); // the date column
      await t.tap(find.text('911 Restoration')); // the row itself is not a link
      await t.pumpAndSettle();
      expect(find.text('JOB PAGE 1094424959'), findsNothing);
      await t.tap(find.text('1094424959'));
      await t.pumpAndSettle();
    }, () => _mock());
    expect(find.text('JOB PAGE 1094424959'), findsOneWidget);
  });
}
