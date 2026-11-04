// The Customers list: behaviour, plus screenshots to test/shots/. Run:
//   flutter test test/customers_render_test.dart --update-goldens

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/customers_screen.dart';
import 'package:iohd_desktop/theme/app_theme.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

// Shapes as customers.js sends them: '--' and blanks for missing values, contact often the same as the name.
const _rows = [
  {'id': 19000001, 'customer_name': 'Lennar', 'primary_contact': 'Bella Hansberger', 'phone': '(479) 555-0101', 'email': 'nwa.warranty@lennar.com', 'service_location': '542 Claverie St.', 'city': 'Lowell', 'state': 'AR', 'total_jobs': 1284},
  {'id': 19000002, 'customer_name': 'Smith Residence', 'primary_contact': 'Smith Residence', 'phone': '--', 'email': '', 'service_location': '', 'city': '', 'state': '', 'total_jobs': 0},
  {'id': 19000003, 'customer_name': 'Walton Logistics Distribution Center With A Very Long Company Name', 'primary_contact': 'Facilities Desk', 'phone': '4795550199', 'email': 'facilities-and-maintenance-requests@waltonlogistics.example.com', 'service_location': '4100 SW Regional Airport Blvd, Building 7, Dock Doors 1-24', 'city': 'Bentonville', 'state': 'AR', 'total_jobs': 37},
  {'id': 19000004, 'customer_name': 'Rogers Dental', 'primary_contact': 'Dr. Amy Cole', 'phone': '479-555-0123', 'email': 'office@rogersdental.example.com', 'service_location': '12 Walnut St', 'city': 'Rogers', 'state': 'AR', 'total_jobs': 1},
  {'id': 19000005, 'customer_name': 'Hill Street Storage', 'primary_contact': null, 'phone': '(479) 555-0177', 'email': null, 'service_location': '9 Hill St', 'city': 'Fayetteville', 'state': 'AR', 'total_jobs': 6},
];

class _Server {
  final List<Uri> urls = [];
  bool empty = false;
  int? failCode;

  http.Client client() => MockClient((req) async {
        urls.add(req.url);
        if (failCode != null) return http.Response('boom', failCode!);
        final q = req.url.queryParameters['q'] ?? '';
        final rows = empty || q == 'nothing' ? const <Map<String, Object?>>[] : _rows;
        return http.Response(jsonEncode({'data': rows, 'total': rows.isEmpty ? 0 : 2597, 'totalPages': rows.isEmpty ? 1 : 52}), 200);
      });

  List<Uri> firstPages() => urls.where((u) => u.queryParameters['page'] == '1').toList();
}

final _theme = ThemeData(
  useMaterial3: true,
  fontFamily: 'Segoe UI',
  colorScheme: ColorScheme.fromSeed(seedColor: AppTheme.brandRed, primary: AppTheme.brandRed),
);

Future<GoRouter> _pump(WidgetTester t, _Server s, {Size size = const Size(1366, 860), double text = 1}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  if (text != 1) {
    t.platformDispatcher.textScaleFactorTestValue = text;
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
  }
  final router = GoRouter(
    initialLocation: '/customers',
    routes: [
      GoRoute(
        path: '/customers',
        builder: (_, st) => CustomersScreen(initialQuery: st.uri.queryParameters['q']),
        routes: [GoRoute(path: ':id', builder: (_, st) => Text('CUSTOMER PAGE ${st.pathParameters['id']}'))],
      ),
    ],
  );
  await http.runWithClient(() async {
    await t.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('shot'),
        child: MaterialApp.router(debugShowCheckedModeBanner: false, theme: _theme, routerConfig: router),
      ),
    );
    await t.pumpAndSettle();
  }, () => s.client());
  return router;
}

Future<void> _shot(WidgetTester t, String name, {_Server? server, Size size = const Size(1366, 860), double text = 1}) async {
  await _pump(t, server ?? _Server(), size: size, text: text);
  expect(t.takeException(), isNull);
  await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('shots/$name.png'));
}

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', ['C:/Windows/Fonts/segoeui.ttf', 'C:/Windows/Fonts/segoeuib.ttf']);
    await _loadFont('MaterialIcons', ['C:/src/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
  });

  testWidgets('wide', (t) async {
    await _shot(t, 'customers_1366');
    expect(find.text('2,597 customers'), findsOneWidget);
    expect(find.text('1,284'), findsOneWidget); // jobs, as a number
    expect(find.text('No phone'), findsOneWidget); // '--' is not a phone number
    expect(find.text('No email'), findsWidgets);
    expect(find.text('No address'), findsOneWidget);
    expect(find.text('Smith Residence'), findsOneWidget, reason: 'a contact that repeats the name is not shown twice');
    expect(find.text('1–5 of 2,597'), findsOneWidget);
    expect(find.text('(479) 555-0199'), findsOneWidget); // typed as 4795550199
    expect(find.text('(479) 555-0123'), findsOneWidget); // typed as 479-555-0123
  });
  testWidgets('very wide', (t) async => _shot(t, 'customers_1920', size: const Size(1920, 900)));
  testWidgets('stacked', (t) async {
    await _shot(t, 'customers_700', size: const Size(700, 900));
    expect(find.text('Contact info'), findsNothing);
    expect(find.text('1,284 jobs'), findsOneWidget);
    expect(find.text('Name'), findsOneWidget); // the sort menu stands in for the headers
  });
  testWidgets('phone width', (t) async => _shot(t, 'customers_360', size: const Size(360, 780)));
  testWidgets('text at 130%', (t) async => _shot(t, 'customers_text130', text: 1.3));
  testWidgets('empty', (t) async {
    await _shot(t, 'customers_empty', server: _Server()..empty = true);
    expect(find.text('No customers yet'), findsOneWidget);
    expect(find.textContaining('0 customers'), findsNothing);
  });
  testWidgets('error', (t) async {
    await _shot(t, 'customers_error', server: _Server()..failCode = 500);
    expect(find.text("Customers didn't load"), findsOneWidget);
    expect(find.text('Could not load customers (server error 500).'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('no access: no Try again', (t) async {
    await _pump(t, _Server()..failCode = 403);
    expect(find.text('No access to customers'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
  });

  testWidgets('headers sort on the server; jobs start biggest first', (t) async {
    final s = _Server();
    await http.runWithClient(() async {
      await _pump(t, s);
      expect(s.urls.first.queryParameters, containsPair('sort', 'name'));
      expect(s.urls.first.queryParameters, containsPair('dir', 'asc'));
      await t.tap(find.text('Jobs'));
      await t.pumpAndSettle();
      expect(s.firstPages().last.queryParameters, containsPair('sort', 'jobs'));
      expect(s.firstPages().last.queryParameters, containsPair('dir', 'desc'));
      await t.tap(find.text('Jobs'));
      await t.pumpAndSettle();
      expect(s.firstPages().last.queryParameters, containsPair('dir', 'asc'));
    }, () => s.client());
  });

  testWidgets('search with no match offers to clear it', (t) async {
    final s = _Server();
    await http.runWithClient(() async {
      await _pump(t, s);
      await t.enterText(find.byType(TextField), 'nothing');
      await t.pump(const Duration(milliseconds: 500));
      await t.pumpAndSettle();
      expect(find.text('No matching customers'), findsOneWidget);
      await t.tap(find.text('Clear search'));
      await t.pumpAndSettle();
      expect(find.text('Lennar'), findsOneWidget);
    }, () => s.client());
  });

  testWidgets('a failed refresh keeps the rows', (t) async {
    final s = _Server();
    await http.runWithClient(() async {
      await _pump(t, s);
      s.failCode = 500;
      await t.tap(find.byTooltip('Refresh'));
      await t.pumpAndSettle();
      expect(find.text('Lennar'), findsOneWidget);
      expect(find.textContaining('Showing the last loaded customers.'), findsOneWidget);
    }, () => s.client());
  });

  testWidgets('clicking a row opens the customer; clicking the phone copies it instead', (t) async {
    final s = _Server();
    final copied = <String>[];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await http.runWithClient(() async {
      final router = await _pump(t, s);
      await t.tap(find.text('(479) 555-0101'));
      await t.pumpAndSettle();
      expect(copied, ['(479) 555-0101']);
      expect(router.routerDelegate.currentConfiguration.uri.path, '/customers');
      await t.tap(find.text('Rogers Dental'));
      await t.pumpAndSettle();
      expect(router.routerDelegate.currentConfiguration.uri.path, '/customers/19000004');
    }, () => s.client());
  });
}
