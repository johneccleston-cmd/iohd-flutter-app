// The top bar's search dropdown: what it lists, how it opens a record, keyboard use, permissions, and what it does
// when the server is slow, empty or failing. Renders to test/shots/nav/ as well, and a RenderFlex overflow fails.
// Run:  flutter test test/global_search_test.dart --update-goldens

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/config/auth_session.dart';

import 'nav_fixture.dart';

const _wide = Size(1440, 720);
const _settle = Duration(milliseconds: 300);

Map<String, dynamic> _job(String id, String name, {String status = 'Scheduled', String location = '12 Oak St, Naperville'}) =>
    {'job_id': id, 'customer_name': name, 'location': location, 'status': status};

Map<String, dynamic> _customer(int id, String name) => {
      'id': id,
      'customer_name': name,
      'primary_contact': 'Dana Smith',
      'phone': '630-555-0142',
      'city': 'Naperville',
      'state': 'IL',
    };

Map<String, dynamic> _invoice(String number, String name, {bool paid = false, bool overdue = false}) => {
      'id': 9000,
      'number': number,
      'customer': name,
      'total': '1250.00', // Postgres numerics arrive as strings
      'is_paid': paid,
      'overdue': overdue,
      'po_number': null,
    };

Map<String, dynamic> _order(int id, String number, String vendor) =>
    {'id': id, 'poNumber': number, 'vendor': vendor, 'status': 'Open', 'total': 840.5};

http.Response _orders(List<Map<String, dynamic>> orders) => http.Response(json.encode({'success': true, 'purchaseOrders': orders}), 200);

http.Response _list(List<Map<String, dynamic>> data, {int? total}) =>
    http.Response(json.encode({'data': data, 'total': total ?? data.length}), 200);

/// A fake API that remembers what it was asked.
class _Api {
  final requests = <Uri>[];
  Future<http.Response> Function(http.Request req) answer = _matches;

  late final http.Client client = MockClient((req) async {
    if (req.url.path == '/users') return http.Response('[]', 200);
    requests.add(req.url);
    return answer(req);
  });

  int searchesFor(String path) => requests.where((u) => u.path == path).length;
}

Future<http.Response> _matches(http.Request req) async => switch (req.url.path) {
      '/api/customers' => _list([_customer(19000123, 'Smith Family Dental'), _customer(19000124, 'Smithson Homes')]),
      '/api/jobs' => _list(
          [_job('1099000137', 'Smith Family Dental'), _job('1099000138', 'Smithson Homes', status: 'Final Invoice Sent')],
          total: 23,
        ),
      '/api/estimates' => _list([_job('1099000200', 'Smith, Robert', status: 'Estimate Sent')]),
      '/api/invoices' => _list([_invoice('48213', 'Smith Family Dental', overdue: true)], total: 7),
      '/api/purchase-orders' => _orders([
          _order(1, 'PO-2026-1001', 'Smith Hardware'),
          _order(2, 'PO-2026-1002', 'Smith Hardware'),
          _order(3, 'PO-2026-1003', 'Clopay'),
        ]),
      _ => http.Response('{}', 200),
    };

/// Runs [body] with the fake API, so requests started by the search's own timers use it too.
void _test(String name, Future<void> Function(WidgetTester t, _Api api) body) {
  testWidgets(name, (t) async {
    final api = _Api();
    await http.runWithClient(() => body(t, api), () => api.client);
  });
}

/// Types and lets the search start, without waiting for its answer.
Future<void> _start(WidgetTester t, String text) async {
  await t.tap(find.byType(TextField));
  await t.pump();
  await t.enterText(find.byType(TextField), text);
  await t.pump(_settle);
}

Future<void> _type(WidgetTester t, String text) async {
  await _start(t, text);
  await t.pumpAndSettle();
}

Future<void> _key(WidgetTester t, LogicalKeyboardKey key) async {
  await t.sendKeyEvent(key);
  await t.pump();
}

Future<void> _enter(WidgetTester t) async {
  await t.testTextInput.receiveAction(TextInputAction.search);
  await t.pumpAndSettle();
}

/// Clicks a row, scrolling the dropdown to it first: the lower sections start below the fold.
Future<void> _pick(WidgetTester t, Finder row) async {
  await t.ensureVisible(row);
  await t.pumpAndSettle();
  await t.tap(row);
  await t.pumpAndSettle();
}

Future<void> _shot(String name) => expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/nav/$name.png'));

void main() {
  setUpAll(loadNavFonts);
  setUp(() => navSignIn());

  _test('the field just says Search', (t, api) async {
    await pumpNav(t, _wide);
    expect(t.widget<TextField>(find.byType(TextField)).decoration!.hintText, 'Search');
  });

  _test('typing lists customers, jobs and estimates; clicking one opens it', (t, api) async {
    final router = await pumpNav(t, _wide);
    await _type(t, 'smith');
    expect(find.text('Customers'), findsOneWidget);
    expect(find.text('Estimates'), findsOneWidget);
    expect(find.text('See all 23 jobs'), findsOneWidget);

    await t.tap(find.textContaining('#1099000138'));
    await t.pumpAndSettle();
    expect(router.state.uri.toString(), '/jobs/1099000138');
    expect(find.text('See all 23 jobs'), findsNothing);
    expect(t.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
  });

  _test('a customer goes to their own page, and an estimate to its own', (t, api) async {
    final router = await pumpNav(t, _wide);
    await _type(t, 'smith');
    await t.tap(find.textContaining('Smithson Homes').first);
    await t.pumpAndSettle();
    expect(router.state.uri.toString(), '/customers/19000124');

    await _type(t, 'smith');
    await _pick(t, find.textContaining('#1099000200'));
    expect(router.state.uri.toString(), '/estimates/1099000200');
  });

  _test('an invoice opens the Invoices list narrowed to its number', (t, api) async {
    final router = await pumpNav(t, _wide);
    await _type(t, 'smith');
    expect(find.text('Invoices'), findsOneWidget);
    expect(find.text('Overdue'), findsOneWidget);
    expect(find.text('See all 7 invoices'), findsOneWidget);
    await _pick(t, find.textContaining('#48213'));
    expect(router.state.uri.toString(), '/invoices?q=48213');
  });

  _test('an exact invoice number comes first', (t, api) async {
    api.answer = (req) async => switch (req.url.path) {
          '/api/jobs' => _list([_job('1048213', 'Near Miss')]),
          '/api/invoices' => _list([_invoice('148213', 'Other'), _invoice('48213', 'The One')]),
          '/api/purchase-orders' => _orders([]),
          _ => _list([]),
        };
    final router = await pumpNav(t, _wide);
    await _type(t, '48213');
    await _enter(t);
    expect(router.state.uri.toString(), '/invoices?q=48213');
  });

  _test('a purchase order opens its list narrowed to it, found by number or vendor', (t, api) async {
    final router = await pumpNav(t, _wide);
    await _type(t, 'smith');
    expect(find.text('Purchase Orders'), findsOneWidget);
    expect(find.textContaining('PO-2026-1003'), findsNothing);
    await _pick(t, find.textContaining('PO-2026-1002'));
    expect(router.state.uri.toString(), '/inventory/purchase-orders?q=PO-2026-1002');

    await _type(t, 'PO-2026-1003');
    await _enter(t);
    expect(router.state.uri.toString(), '/inventory/purchase-orders?q=PO-2026-1003');
  });

  _test('a vendor is listed once, with its order count, and opens its orders', (t, api) async {
    final router = await pumpNav(t, _wide);
    await _type(t, 'smith');
    expect(find.text('Vendors'), findsOneWidget);
    expect(find.text('2 purchase orders'), findsOneWidget);
    await _pick(t, find.text('2 purchase orders'));
    expect(router.state.uri.toString(), '/inventory/purchase-orders?q=Smith+Hardware');
  });

  _test('purchase orders and vendors share one request, reused while typing', (t, api) async {
    await pumpNav(t, _wide);
    await _type(t, 'smith');
    await t.enterText(find.byType(TextField), 'smithy');
    await t.pump(_settle);
    await t.pumpAndSettle();
    expect(api.searchesFor('/api/purchase-orders'), 1);
    expect(api.searchesFor('/api/jobs'), 2);
  });

  _test('a failed purchase order list is asked for again by Try again', (t, api) async {
    api.answer = (req) async => req.url.path == '/api/purchase-orders' ? http.Response('nope', 500) : _matches(req);
    await pumpNav(t, _wide);
    await _type(t, 'smith');
    expect(find.text("Some results didn't load."), findsOneWidget);
    api.answer = _matches;
    await t.tap(find.text('Try again'));
    await t.pumpAndSettle();
    expect(find.text('2 purchase orders'), findsOneWidget);
  });

  _test('vendors need purchase orders too, since that is where they open', (t, api) async {
    await navSignIn(admin: false, denied: denyViews(['purchase_orders']));
    await pumpNav(t, _wide);
    await _type(t, 'smith');
    expect(api.searchesFor('/api/purchase-orders'), 0);
    expect(find.text('2 purchase orders'), findsNothing);
  });

  _test('See all opens the filtered list', (t, api) async {
    final router = await pumpNav(t, _wide);
    await _type(t, 'smith');
    await t.tap(find.text('See all 23 jobs'));
    await t.pumpAndSettle();
    expect(router.state.uri.toString(), '/jobs?q=smith');
  });

  _test('the exact number comes first, even from a later list and below a near match', (t, api) async {
    api.answer = (req) async => switch (req.url.path) {
          '/api/jobs' => _list([_job('10990001370', 'Near Miss')]),
          '/api/estimates' => _list([_job('21099000137', 'Other'), _job('1099000137', 'The One')]),
          _ => _list([]),
        };
    final router = await pumpNav(t, _wide);
    await _type(t, '1099000137');
    await _enter(t);
    expect(router.state.uri.toString(), '/estimates/1099000137');
  });

  _test('Enter straight after typing still opens the match, and searches once', (t, api) async {
    final router = await pumpNav(t, _wide);
    await t.tap(find.byType(TextField));
    await t.pump();
    await t.enterText(find.byType(TextField), 'smith');
    await _enter(t);
    expect(router.state.uri.toString(), '/customers/19000123');
    await t.pump(_settle);
    expect(api.searchesFor('/api/customers'), 1);
  });

  _test('arrow keys move the highlight, wrap, and Enter opens it', (t, api) async {
    final router = await pumpNav(t, _wide);
    await _type(t, 'smith');
    await _key(t, LogicalKeyboardKey.arrowDown);
    await _key(t, LogicalKeyboardKey.arrowDown);
    await _enter(t);
    expect(router.state.uri.toString(), '/jobs/1099000137');

    await _type(t, 'smith');
    await _key(t, LogicalKeyboardKey.arrowUp); // from the first row round to the last
    await _enter(t);
    expect(router.state.uri.toString(), '/inventory/purchase-orders?q=Smith+Hardware');
  });

  _test('Escape closes it and keeps the text; typing brings it back', (t, api) async {
    await pumpNav(t, _wide);
    await _type(t, 'smith');
    await _key(t, LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(find.text('See all 23 jobs'), findsNothing);
    expect(t.widget<TextField>(find.byType(TextField)).controller!.text, 'smith');
    await t.enterText(find.byType(TextField), 'smithy');
    await t.pump(_settle);
    await t.pumpAndSettle();
    expect(find.text('See all 23 jobs'), findsOneWidget);
  });

  _test('clicking away closes it', (t, api) async {
    await pumpNav(t, _wide);
    await _type(t, 'smith');
    await t.tapAt(const Offset(40, 680));
    await t.pumpAndSettle();
    expect(find.text('See all 23 jobs'), findsNothing);
  });

  _test('one letter does not search, and fast typing searches once', (t, api) async {
    await pumpNav(t, _wide);
    await _start(t, 's');
    expect(api.requests, isEmpty);
    for (final text in ['sm', 'smi', 'smit', 'smith']) {
      await t.enterText(find.byType(TextField), text);
      await t.pump(const Duration(milliseconds: 60));
    }
    await t.pump(_settle);
    await t.pumpAndSettle();
    expect(api.searchesFor('/api/customers'), 1);
    expect(api.requests.first.queryParameters['q'], 'smith');
  });

  _test('a slow answer to old text is dropped', (t, api) async {
    final held = Completer<http.Response>();
    api.answer = (req) => req.url.queryParameters['q'] == 'old'
        ? held.future
        : Future.value(req.url.path == '/api/customers' ? _list([_customer(1, 'New Customer')]) : _list([]));
    await pumpNav(t, _wide);
    await _start(t, 'old');
    await t.enterText(find.byType(TextField), 'new');
    await t.pump(_settle);
    held.complete(_list([_customer(2, 'Old Customer')]));
    await t.pumpAndSettle();
    expect(find.textContaining('New Customer'), findsOneWidget);
    expect(find.textContaining('Old Customer'), findsNothing);
  });

  _test('nothing found says so, and Enter falls back to the list', (t, api) async {
    api.answer = (req) async => _list([]);
    final router = await pumpNav(t, _wide);
    await _type(t, 'zzz');
    expect(find.text('No matches for "zzz"'), findsOneWidget);
    await _enter(t);
    expect(router.state.uri.toString(), '/customers?q=zzz');
  });

  _test('a failed search offers Try again, which works', (t, api) async {
    api.answer = (req) async => http.Response('nope', 500);
    await pumpNav(t, _wide);
    await _type(t, 'smith');
    expect(find.text("Search isn't responding."), findsOneWidget);
    api.answer = _matches;
    await t.tap(find.text('Try again'));
    await t.pumpAndSettle();
    expect(find.text('See all 23 jobs'), findsOneWidget);
    expect(find.text("Search isn't responding."), findsNothing);
  });

  _test('when one list fails the others still show', (t, api) async {
    api.answer = (req) async => req.url.path == '/api/estimates' ? http.Response('nope', 500) : _matches(req);
    await pumpNav(t, _wide);
    await _type(t, 'smith');
    expect(find.text('See all 23 jobs'), findsOneWidget);
    expect(find.text("Some results didn't load."), findsOneWidget);
  });

  _test('lists the account cannot open are not asked, and a 403 just leaves that list out', (t, api) async {
    await navSignIn(admin: false, denied: denyViews(['estimates']));
    api.answer = (req) async => req.url.path == '/api/customers' ? http.Response('{}', 403) : _matches(req);
    await pumpNav(t, _wide);
    await _type(t, 'smith');
    expect(api.searchesFor('/api/estimates'), 0);
    expect(find.text('See all 23 jobs'), findsOneWidget);
    expect(find.text("Some results didn't load."), findsNothing);
  });

  _test('a 401 signs out', (t, api) async {
    api.answer = (req) async => http.Response('{}', 401);
    await pumpNav(t, _wide);
    await _type(t, 'smith');
    expect(AuthSession.instance.isLoggedIn, isFalse);
  });

  _test('the search box on a narrow window lists matches too', (t, api) async {
    final router = await pumpNav(t, const Size(390, 700));
    await t.tap(find.byTooltip('Search'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'smith');
    await t.pump(_settle);
    await t.pumpAndSettle();
    await _shot('search_dialog_390');
    await t.tap(find.textContaining('#1099000137'));
    await t.pumpAndSettle();
    expect(router.state.uri.toString(), '/jobs/1099000137');
  });

  group('renders', () {
    for (final (name, size) in const [
      ('1920', Size(1920, 940)),
      ('1440', Size(1440, 720)),
      ('1100', Size(1100, 700)),
      ('short', Size(1440, 320)),
      ('720', Size(720, 600)),
    ]) {
      _test('results $name', (t, api) async {
        await pumpNav(t, size);
        if (find.byType(TextField).evaluate().isEmpty) {
          await t.tap(find.byTooltip('Search'));
          await t.pumpAndSettle();
        }
        await _type(t, 'smith');
        await _shot('search_results_$name');
      });
    }

    _test('long names and a number', (t, api) async {
      api.answer = (req) async => req.url.path == '/api/jobs'
          ? _list([
              _job(
                '1099000137',
                'The Very Long Named Property Management Company of Greater Naperville LLC',
                status: 'Final Invoice Sent - Awaiting Customer Reply',
                location: '12345 South Extremely Long Boulevard Name, Naperville, IL 60540',
              ),
            ])
          : _list([]);
      await pumpNav(t, _wide);
      await _type(t, '1099000137');
      await _shot('search_long_1440');
    });

    _test('empty', (t, api) async {
      api.answer = (req) async => _list([]);
      await pumpNav(t, _wide);
      await _type(t, 'zzz');
      await _shot('search_empty_1440');
    });

    _test('failed', (t, api) async {
      api.answer = (req) async => http.Response('nope', 500);
      await pumpNav(t, _wide);
      await _type(t, 'smith');
      await _shot('search_failed_1440');
    });

    _test('large text', (t, api) async {
      await pumpNav(t, _wide, textScale: 1.5);
      await _type(t, 'smith');
      await _shot('search_results_text150');
    });
  });
}
