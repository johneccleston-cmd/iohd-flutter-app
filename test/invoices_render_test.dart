// Renders the Invoices screen with fake API data to test/shots/. Run:  flutter test test/invoices_render_test.dart --update-goldens

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/invoices_screen.dart';
import 'package:iohd_desktop/theme/app_theme.dart';
import 'package:iohd_desktop/widgets/dashboard_kit.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

final _requests = <Uri>[];

// Shapes as invoices.js sends them. Dates are Chicago days labelled UTC: midnight is that day, not the evening before.
const _rows = [
  // Tied to its job by a payment, by the invoice's total and by the PO; one with no sure match; one whose job is not in the app.
  {'id': 1, 'number': 4011, 'customer': 'Walton Logistics', 'po_number': 'PO-77', 'is_paid': false, 'overdue': false, 'total': '8500.00', 'balance': '2125.00', 'invoice_date': '2026-10-15T00:00:00Z', 'due_date': '2026-11-14T00:00:00Z', 'job_id': '1099563432', 'job_link': 'payment', 'job_on_file': true},
  {'id': 2, 'number': 4010, 'customer': 'Bob Vance With A Very Long Company Name Incorporated', 'po_number': null, 'is_paid': false, 'overdue': true, 'total': '1200.00', 'balance': '1200.00', 'invoice_date': '2026-09-01T11:51:00Z', 'due_date': '2026-10-01T11:51:00Z', 'job_id': '1096000001', 'job_link': 'amount', 'job_on_file': true},
  {'id': 3, 'number': 4009, 'customer': 'Rogers Dental', 'po_number': 'WO-000495255-1-LONG-REFERENCE', 'is_paid': true, 'overdue': false, 'total': '640.50', 'balance': '0', 'invoice_date': '2026-09-20T00:00:00Z', 'due_date': null, 'job_id': '1096000002', 'job_link': 'po', 'job_on_file': true},
  {'id': 4, 'number': 4008, 'customer': '', 'po_number': null, 'is_paid': false, 'overdue': true, 'total': '99.00', 'balance': '99.00', 'invoice_date': null, 'due_date': null, 'job_id': null, 'job_link': null, 'job_on_file': false},
  {'id': 5, 'number': 4007, 'customer': 'Hill Street Storage', 'po_number': null, 'is_paid': true, 'overdue': false, 'total': '47223.08', 'balance': '0', 'invoice_date': '2026-08-02T00:00:00Z', 'due_date': '2026-08-02T00:00:00Z', 'job_id': '1083818562', 'job_link': 'payment', 'job_on_file': false},
  {'id': 6, 'number': 4006, 'customer': 'Ridgeview HOA', 'po_number': null, 'is_paid': true, 'overdue': false, 'total': '-150.00', 'balance': '0', 'invoice_date': '2026-08-01T00:00:00Z', 'due_date': '2026-08-01T00:00:00Z', 'job_id': '1096961883', 'job_link': 'payment', 'job_on_file': true},
];

const _stats = {'awaiting': 237397.54, 'awaitingCount': 239, 'overdue': 227597.91, 'overdueCount': 238, 'invoiced30d': 34500.0};

http.Response _page(List<Map<String, Object?>> rows, {int total = 812, int totalPages = 17, bool current = true}) => http.Response(
      jsonEncode({
        'data': rows,
        'total': total,
        'totalPages': totalPages,
        if (current) 'jobLinks': true,
        if (current) 'sorts': ['issued', 'customer', 'amount', 'balance', 'due'],
        'stats': _stats,
      }),
      200,
    );

http.Client _mock({bool empty = false, int? failCode}) => MockClient((req) async {
      _requests.add(req.url);
      if (failCode != null) return http.Response('boom', failCode);
      return empty ? _page(const [], total: 0, totalPages: 1) : _page(_rows);
    });

// The app's own colours (main.dart), so buttons in the shots are the real ones.
final _theme = ThemeData(
  useMaterial3: true,
  fontFamily: 'Segoe UI',
  colorScheme: ColorScheme.fromSeed(seedColor: AppTheme.brandRed, primary: AppTheme.brandRed),
);

Widget _app(Widget home) => MaterialApp(debugShowCheckedModeBanner: false, theme: _theme, home: home);

Future<void> _shot(WidgetTester t, Size size, String name, http.Client client, {Future<void> Function()? then}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  await http.runWithClient(() async {
    await t.pumpWidget(RepaintBoundary(key: const ValueKey('shot'), child: _app(const InvoicesScreen())));
    await t.pumpAndSettle();
    if (then != null) await then();
  }, () => client);
  expect(t.takeException(), isNull);
  await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('shots/$name.png'));
}

/// Pumps the screen with [client] and runs [body] inside the fake-HTTP zone.
Future<void> _run(WidgetTester t, http.Client client, Future<void> Function() body, {Size size = const Size(1366, 900)}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  _requests.clear();
  await http.runWithClient(() async {
    await t.pumpWidget(_app(const InvoicesScreen()));
    await t.pumpAndSettle();
    await body();
  }, () => client);
}

Future<void> _search(WidgetTester t, String text) async {
  await t.enterText(find.byType(TextField), text);
  await t.pump(const Duration(milliseconds: 500));
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', ['C:/Windows/Fonts/segoeui.ttf', 'C:/Windows/Fonts/segoeuib.ttf']);
    await _loadFont('MaterialIcons', ['C:/src/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
  });

  testWidgets('real rows, no sample data', (t) async {
    await _shot(t, const Size(1366, 720), 'invoices_data', _mock());
    expect(find.text('INV-4011'), findsNothing); // the old dummy ids
    expect(find.text('Walton Logistics'), findsOneWidget);
    expect(find.text('Overdue'), findsWidgets);
    expect(find.text('Page 1 of 17'), findsOneWidget);
    expect(find.text('1–6 of 812'), findsOneWidget);
    expect(find.text('Awaiting payment (239)'), findsOneWidget);
    expect(find.text(r'$227,597.91'), findsOneWidget);
  });

  testWidgets('empty', (t) async {
    await _shot(t, const Size(1366, 720), 'invoices_empty', _mock(empty: true));
    expect(find.text('No invoices yet'), findsOneWidget);
    expect(find.text('0 invoices'), findsNothing); // the empty state already says so
  });
  testWidgets('error shows retry and no count', (t) async {
    await _shot(t, const Size(1366, 720), 'invoices_error', _mock(failCode: 500));
    expect(find.text('Try again'), findsOneWidget);
    expect(find.textContaining('Could not load invoices (server error 500)'), findsOneWidget);
    expect(find.text('0 invoices'), findsNothing);
  });
  testWidgets('narrow: stacked rows, with the amount, status and job in view', (t) async {
    await _shot(t, const Size(520, 800), 'invoices_520', _mock());
    expect(find.text('Awaiting (239)'), findsOneWidget); // the long label would cut off its count
    expect(find.text('Issued'), findsNothing); // no column headers: every row names its own parts
    expect(t.getRect(find.text(r'$8,500.00')).right, lessThanOrEqualTo(520));
    expect(t.getRect(find.text('Unpaid').first).right, lessThanOrEqualTo(520));
    expect(find.text('1099563432'), findsOneWidget);
    expect(find.text('Due Nov 14, 2026'), findsOneWidget);
    expect(find.text(r'Balance $2,125.00'), findsOneWidget); // part paid: the balance is not the amount above it
    expect(find.text(r'Balance $1,200.00'), findsNothing); // nothing paid: the amount says it already
  });
  testWidgets('phone width', (t) async => _shot(t, const Size(360, 780), 'invoices_360', _mock()));
  testWidgets('just too narrow for the columns', (t) async => _shot(t, const Size(980, 900), 'invoices_980', _mock()));
  testWidgets('narrowest with the columns', (t) async {
    await _shot(t, const Size(1020, 900), 'invoices_1020', _mock());
    for (final day in ['Oct 15, 2026', 'Sep 20, 2026']) {
      expect(t.getSize(find.text(day)).height, lessThan(26), reason: '$day wrapped onto a second line');
    }
  });
  testWidgets('very wide', (t) async => _shot(t, const Size(1920, 1000), 'invoices_1920', _mock()));
  testWidgets('text at 130%', (t) async {
    t.view.physicalSize = const Size(1366, 800);
    t.view.devicePixelRatio = 1;
    t.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    await http.runWithClient(() async {
      await t.pumpWidget(RepaintBoundary(key: const ValueKey('shot'), child: _app(const InvoicesScreen())));
      await t.pumpAndSettle();
    }, () => _mock());
    expect(t.takeException(), isNull);
    await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('shots/invoices_text130.png'));
  });

  testWidgets('dates read as the day stored, not the evening before', (t) async {
    await _run(t, _mock(), () async {
      expect(find.text('Oct 15, 2026'), findsOneWidget); // stored at midnight
      expect(find.text('Oct 14, 2026'), findsNothing);
      expect(find.text('Nov 14, 2026'), findsOneWidget);
    });
  });

  testWidgets('the Job # column: every kind of link says how it was tied', (t) async {
    await _run(t, _mock(), () async {
      expect(find.text('Job #'), findsOneWidget);
      expect(find.byTooltip('Open job 1099563432.'), findsOneWidget); // a payment records it: nothing to explain
      expect(find.byTooltip("Open job 1096000001. Matched on the customer and the invoice's total, not recorded in Service Fusion."), findsOneWidget);
      expect(find.byTooltip('Open job 1096000002. Matched on the customer and PO number, not recorded in Service Fusion.'), findsOneWidget);
      expect(find.byTooltip('No payment, total or PO number ties this invoice to one job.'), findsOneWidget);
      expect(find.byTooltip('Job 1083818562 is not in the app, so there is no job page to open.'), findsOneWidget);
    });
  });

  testWidgets('clicking the job number opens that job; a job not in the app is not a link', (t) async {
    t.view.physicalSize = const Size(1366, 900);
    t.view.devicePixelRatio = 1;
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => const InvoicesScreen()),
      GoRoute(path: '/jobs/:id', builder: (_, s) => Scaffold(body: Text('JOB PAGE ${s.pathParameters['id']}'))),
    ]);
    await http.runWithClient(() async {
      await t.pumpWidget(MaterialApp.router(routerConfig: router));
      await t.pumpAndSettle();
      await t.tap(find.text('1083818562'));
      await t.pumpAndSettle();
      expect(find.text('JOB PAGE 1083818562'), findsNothing);
      await t.tap(find.text('1096000001'));
      await t.pumpAndSettle();
    }, () => _mock());
    expect(find.text('JOB PAGE 1096000001'), findsOneWidget);
  });

  testWidgets('a server without job links gets no empty column, and no promise in the search box', (t) async {
    await _run(t, MockClient((req) async => _page(_rows, current: false)), () async {
      expect(find.text('Job #'), findsNothing);
      expect(find.text('Balance'), findsNothing);
      expect(find.text('Issued'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_downward_rounded), findsNothing); // no sorting either
      expect(find.text('Search customer, invoice # or PO...'), findsOneWidget);
    });
  });

  testWidgets('sorting: the server is asked, the arrow follows, and each column starts the useful way round', (t) async {
    await _run(t, _mock(), () async {
      expect(_requests.last.queryParameters.containsKey('sort'), isFalse); // newest first needs no asking
      expect(find.byIcon(Icons.arrow_downward_rounded), findsOneWidget);
      await t.tap(find.text('Amount'));
      await t.pumpAndSettle();
      expect(_requests.last.queryParameters['sort'], 'amount');
      expect(_requests.last.queryParameters['dir'], 'desc');
      await t.tap(find.text('Due'));
      await t.pumpAndSettle();
      expect(_requests.last.queryParameters['sort'], 'due');
      expect(_requests.last.queryParameters['dir'], 'asc'); // oldest due date first
      expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);
      await t.tap(find.text('Due'));
      await t.pumpAndSettle();
      expect(_requests.last.queryParameters['dir'], 'desc');
      await t.tap(find.text('Customer'));
      await t.pumpAndSettle();
      expect(_requests.last.queryParameters['sort'], 'customer');
      expect(_requests.last.queryParameters['dir'], 'asc');
      expect(_requests.last.queryParameters['page'], '1');
    });
  });

  testWidgets('filter and search go to the server', (t) async {
    await _run(t, _mock(), () async {
      await t.tap(find.widgetWithText(ChoiceChip, 'Overdue'));
      await t.pumpAndSettle();
      expect(_requests.last.queryParameters['status'], 'overdue');
      await _search(t, 'vance');
    });
    expect(_requests.last.queryParameters['q'], 'vance');
    expect(_requests.last.queryParameters['status'], 'overdue');
    expect(_requests.last.queryParameters['page'], '1');
  });

  testWidgets('search: the clear button, Enter, and an empty result that says what was searched', (t) async {
    final client = MockClient((req) async {
      _requests.add(req.url);
      return req.url.queryParameters['q'] == 'nobody' ? _page(const [], total: 0, totalPages: 1) : _page(_rows);
    });
    await _run(t, client, () async {
      expect(find.byTooltip('Clear search'), findsNothing);
      await t.enterText(find.byType(TextField), 'nobody');
      await t.testTextInput.receiveAction(TextInputAction.search); // Enter does not wait for the pause in typing
      await t.pump();
      expect(_requests.last.queryParameters['q'], 'nobody');
      await t.pumpAndSettle();
      expect(find.text('No matching invoices'), findsOneWidget);
      expect(find.textContaining('Nothing matches "nobody"'), findsOneWidget);
      await t.tap(find.text('Clear search'));
      await t.pumpAndSettle();
      expect(_requests.last.queryParameters['q'], '');
      expect(find.text('Walton Logistics'), findsOneWidget);
    });
  });

  testWidgets('a filter with nothing in it offers the way back', (t) async {
    final client = MockClient((req) async {
      _requests.add(req.url);
      return req.url.queryParameters['status'] == 'overdue' ? _page(const [], total: 0, totalPages: 1) : _page(_rows);
    });
    await _run(t, client, () async {
      await t.tap(find.widgetWithText(ChoiceChip, 'Overdue'));
      await t.pumpAndSettle();
      expect(find.text('No overdue invoices'), findsOneWidget);
      await t.tap(find.text('Show all invoices'));
      await t.pumpAndSettle();
      expect(_requests.last.queryParameters['status'], 'all');
    });
  });

  testWidgets('first load shows a skeleton, and a slow one says the server may be waking up', (t) async {
    final reply = Completer<http.Response>();
    t.view.physicalSize = const Size(1366, 720);
    t.view.devicePixelRatio = 1;
    await http.runWithClient(() async {
      await t.pumpWidget(_app(const InvoicesScreen()));
      await t.pump();
      expect(find.byType(SkeletonPulse), findsOneWidget);
      await t.pump(const Duration(seconds: 7));
      expect(find.textContaining('Waking up the server'), findsNothing);
      await t.pump(const Duration(seconds: 2));
      expect(find.textContaining('Waking up the server'), findsOneWidget);
      reply.complete(_page(_rows));
      await t.pumpAndSettle();
      expect(find.byType(SkeletonPulse), findsNothing);
      expect(find.textContaining('Waking up the server'), findsNothing);
      expect(find.text('Walton Logistics'), findsOneWidget);
    }, () => MockClient((_) => reply.future));
  });

  testWidgets('no access: says so and offers no retry', (t) async {
    await _run(t, _mock(failCode: 403), () async {
      expect(find.text("Your account doesn't have access to invoices."), findsOneWidget);
      expect(find.text('Try again'), findsNothing);
    });
  });

  testWidgets('a dropped connection is described in plain words, never the raw error', (t) async {
    await _run(t, MockClient((req) async => throw http.ClientException('Failed to fetch', req.url)), () async {
      expect(find.text("Couldn't reach the server. Check your connection and try again."), findsOneWidget);
      expect(find.textContaining('ClientException'), findsNothing);
      expect(find.textContaining('http'), findsNothing); // never the request URL
    });
  });

  testWidgets('a failed reload keeps the rows and says they may be old', (t) async {
    var fail = false;
    await _run(t, MockClient((req) async => fail ? http.Response('boom', 500) : _page(_rows)), () async {
      fail = true;
      await t.tap(find.byTooltip('Refresh'));
      await t.pumpAndSettle();
      expect(find.text('Walton Logistics'), findsOneWidget);
      expect(find.textContaining('Showing the last loaded invoices'), findsOneWidget);
      fail = false;
      await t.tap(find.text('Try again'));
      await t.pumpAndSettle();
      expect(find.textContaining('Showing the last loaded invoices'), findsNothing);
    });
  });

  testWidgets('a failed search does not leave the old rows passing for its answer', (t) async {
    final client = MockClient((req) async => req.url.queryParameters['q'] == 'bishop' ? http.Response('boom', 500) : _page(_rows));
    await _run(t, client, () async {
      await _search(t, 'bishop');
      expect(find.text("Invoices didn't load"), findsOneWidget);
      expect(find.text('Walton Logistics'), findsNothing);
    });
  });

  testWidgets('Try again asks for the page that failed, with the search that was typed', (t) async {
    var fail = true;
    final client = MockClient((req) async {
      _requests.add(req.url);
      if (req.url.queryParameters['q'] == 'vance' && fail) return http.Response('boom', 502);
      return _page(_rows);
    });
    await _run(t, client, () async {
      await t.tap(find.byTooltip('Next page'));
      await t.pumpAndSettle();
      await _search(t, 'vance');
      fail = false;
      await t.tap(find.text('Try again'));
      await t.pumpAndSettle();
    });
    expect(_requests.last.queryParameters['q'], 'vance');
    expect(_requests.last.queryParameters['page'], '1'); // a new search starts on page 1, not the page left behind
  });

  testWidgets('a page past the end (the list got shorter) shows the last page, not "no invoices"', (t) async {
    var pages = 3;
    final client = MockClient((req) async {
      _requests.add(req.url);
      final page = int.parse(req.url.queryParameters['page']!);
      if (page > pages) return _page(const [], total: pages * 50, totalPages: pages);
      return _page(_rows, total: pages * 50, totalPages: pages);
    });
    await _run(t, client, () async {
      await t.tap(find.byTooltip('Next page'));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('Next page'));
      await t.pumpAndSettle();
      pages = 2;
      await t.tap(find.byTooltip('Refresh'));
      await t.pumpAndSettle();
    });
    expect(find.text('No invoices yet'), findsNothing);
    expect(find.text('Page 2 of 2'), findsOneWidget);
    expect(_requests.last.queryParameters['page'], '2');
  });

  testWidgets('the column headers stay in view while the rows scroll, and the next page opens at its top', (t) async {
    final many = [for (var i = 0; i < 50; i++) {..._rows[0], 'id': i, 'customer': 'Customer $i'}];
    await _run(t, MockClient((req) async => _page(many)), () async {
      await t.drag(find.byType(CustomScrollView), const Offset(0, -900));
      await t.pumpAndSettle();
      expect(find.text('Customer 0'), findsNothing);
      expect(find.text('Customer'), findsOneWidget);
      expect(t.getTopLeft(find.text('Customer')).dy, greaterThanOrEqualTo(56)); // just under the ribbon
      await t.tap(find.byTooltip('Next page'));
      await t.pumpAndSettle();
      expect(find.text('51–100 of 812'), findsOneWidget);
      expect(find.text('Customer 0'), findsOneWidget);
    }, size: const Size(1366, 720));
  });

  testWidgets('rows per page asks for that many, from the first page', (t) async {
    await _run(t, _mock(), () async {
      await t.tap(find.byTooltip('Next page'));
      await t.pumpAndSettle();
      await t.tap(find.text('100'));
      await t.pumpAndSettle();
    });
    expect(_requests.last.queryParameters['limit'], '100');
    expect(_requests.last.queryParameters['page'], '1');
  });

  testWidgets('blank values are a dash, and one invoice is one invoice', (t) async {
    await _run(t, MockClient((req) async => _page([_rows[3]], total: 1, totalPages: 1)), () async {
      expect(find.text('1 invoice'), findsOneWidget);
      expect(find.text('No customer on file'), findsOneWidget);
      expect(find.text('—'), findsNWidgets(4)); // issued, job, PO, due
    });
  });

  testWidgets('an unpaid invoice on a written-off job says so, not Overdue or Unpaid', (t) async {
    final row = {..._rows[1], 'overdue': false, 'written_off': true};
    await _run(t, MockClient((req) async => _page([row, {..._rows[2], 'written_off': true}], total: 2, totalPages: 1)), () async {
      expect(find.text('Written off'), findsOneWidget);
      expect(find.text('Paid'), findsNWidgets(2)); // the filter and the row: paid before the job was written off is still paid
      expect(find.widgetWithText(ChoiceChip, 'Overdue'), findsOneWidget); // the filter, not a row
      expect(find.byTooltip('This job is written off, so its invoice is not counted as awaiting payment or overdue.'), findsOneWidget);
      expect(t.widget<Text>(find.text(r'$1,200.00').last).style?.fontWeight, isNot(FontWeight.w700)); // its balance is not being collected
    });
  });

  testWidgets('the Balance column shows what is left beside the invoice amount, and sorts', (t) async {
    await _run(t, _mock(), () async {
      expect(find.text(r'$8,500.00'), findsOneWidget);
      expect(find.text(r'$2,125.00'), findsOneWidget);
      await t.tap(find.text('Balance'));
      await t.pumpAndSettle();
      expect(_requests.last.queryParameters['sort'], 'balance');
      expect(_requests.last.queryParameters['dir'], 'desc');
    });
  });

  testWidgets('a credit is red', (t) async {
    await _run(t, MockClient((req) async => _page([_rows[5]], total: 1, totalPages: 1)), () async {
      expect(t.widget<Text>(find.text(r'-$150.00')).style?.color, DashUi.redText);
    });
  });

  testWidgets('reduced motion: the rows and figures are simply there', (t) async {
    t.view.physicalSize = const Size(1366, 720);
    t.view.devicePixelRatio = 1;
    await http.runWithClient(() async {
      await t.pumpWidget(MediaQuery(data: const MediaQueryData(disableAnimations: true), child: _app(const InvoicesScreen())));
      await t.pump();
      await t.pump();
      expect(find.text(r'$237,397.54'), findsOneWidget);
      final fade = t.widget<FadeTransition>(find.ancestor(of: find.text('Rogers Dental'), matching: find.byType(FadeTransition)).first);
      expect(fade.opacity.value, 1);
    }, () => _mock());
    await t.pumpAndSettle();
  });
}
