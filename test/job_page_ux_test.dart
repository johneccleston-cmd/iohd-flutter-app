// UX behaviour of the job / estimate page: clickable contact links, copy number, balance wording, line-item totals,
// the loading skeleton and the narrow stacked layout.  Run:  flutter test test/job_page_ux_test.dart

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/job_detail_screen.dart';
import 'package:iohd_desktop/widgets/dashboard_kit.dart';

Map<String, dynamic> _record({bool estimate = false, double total = 1000, double due = 400, List<Map<String, dynamic>>? charges, double itemsTotal = 1000}) => {
      'job': {
        'job_id': '1096183137',
        'customer_name': 'Schuber Mitchell Homes',
        'contact_name': 'Dana Whitfield',
        'status': estimate ? 'Estimate Provided' : 'Final Invoice Sent',
        'is_estimate': estimate,
        'location': '1204 W Poplar St, Rogers, AR 72756',
        'total_revenue': '$total',
        'due_total': '$due',
        'raw_items': [
          {'name': 'Complete door', 'total': itemsTotal, 'rate': itemsTotal / 2, 'multiplier': 2, 'item_index': 1},
        ],
        'other_charges': charges ?? [],
      },
      'customer': {'primary_contact': 'Dana Whitfield', 'phone': '(479) 736-2125', 'email': 'dana@schubermitchell.com'},
      'visits': [],
      'payments': [],
      'history': [],
    };

http.Client _mock(Map<String, dynamic> record, {Completer<void>? hold}) => MockClient((req) async {
      final p = req.url.path;
      if (p.endsWith('/notes-tasks')) return http.Response(jsonEncode({'notes': [], 'tasks': []}), 200);
      if (p.endsWith('/files')) return http.Response(jsonEncode({'enabled': true, 'files': []}), 200);
      if (hold != null) await hold.future;
      return http.Response(jsonEncode(record), 200);
    });

GoRouter _router() => GoRouter(
      initialLocation: '/jobs/1096183137',
      routes: [
        GoRoute(path: '/jobs/:id', builder: (_, s) => JobDetailScreen(jobId: s.pathParameters['id']!)),
        GoRoute(path: '/estimates/:id', builder: (_, s) => JobDetailScreen(jobId: s.pathParameters['id']!)), // where an estimate lands
        GoRoute(path: '/customers', builder: (_, s) => Text('CUSTOMERS q=${s.uri.queryParameters['q']}')),
      ],
    );

Future<GoRouter> _pump(WidgetTester t, Map<String, dynamic> record, {Size size = const Size(1400, 1000), Completer<void>? hold}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  final router = _router();
  await http.runWithClient(() async {
    await t.pumpWidget(MaterialApp.router(routerConfig: router));
    if (hold == null) await t.pumpAndSettle();
  }, () => _mock(record, hold: hold));
  return router;
}

void main() {
  testWidgets('clicking the customer opens the Customers screen searched for them', (t) async {
    final r = _record();
    late GoRouter router;
    await http.runWithClient(() async {
      router = await _pump(t, r);
      await t.tap(find.text('Schuber Mitchell Homes').first); // the Customer row in Details
      await t.pumpAndSettle();
      expect(router.routerDelegate.currentConfiguration.uri.path, '/customers');
      expect(router.routerDelegate.currentConfiguration.uri.queryParameters['q'], 'Schuber Mitchell Homes');
    }, () => _mock(r));
  });

  testWidgets('phone, email and address are real links: each opens the right thing, and failing says so', (t) async {
    final r = _record();
    final opened = <String>[];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/url_launcher'), (call) async {
      if (call.method == 'launch') opened.add((call.arguments as Map)['url'] as String);
      return false; // pretend nothing could open it, so the "could not open" message shows
    });
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/url_launcher'), null));
    await http.runWithClient(() async {
      await _pump(t, r);
      await t.tap(find.text('(479) 736-2125').last); // the Details card
      await t.pumpAndSettle();
      expect(opened.last, 'tel:4797362125', reason: 'the number is cleaned to digits for the dialer');
      expect(find.text('Could not open the phone app.'), findsOneWidget);

      await t.tap(find.text('dana@schubermitchell.com'));
      await t.pumpAndSettle();
      expect(opened.last, 'mailto:dana@schubermitchell.com');
      expect(find.text('Could not open your email program.'), findsOneWidget);

      await t.tap(find.text('1204 W Poplar St, Rogers, AR 72756').last);
      await t.pumpAndSettle();
      expect(opened.last, startsWith('https://www.google.com/maps/search/?api=1&query='));
      expect(opened.last, contains('Poplar'));
      expect(find.text('Could not open that link.'), findsOneWidget);
    }, () => _mock(r));
  });

  testWidgets('the number can be copied', (t) async {
    final r = _record();
    String? copied;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await http.runWithClient(() async {
      await _pump(t, r);
      await t.tap(find.byTooltip('Copy job number'));
      await t.pumpAndSettle();
      expect(copied, '1096183137');
      expect(find.text('Copied 1096183137'), findsOneWidget);
    }, () => _mock(r));
  });

  testWidgets('balance: the amount while owed, "Paid in full" once settled, and no balance on an estimate', (t) async {
    await http.runWithClient(() async {
      await _pump(t, _record(due: 400));
      expect(find.text('Balance Due'), findsOneWidget);
      expect(find.text(r'$400.00'), findsOneWidget);
      expect(find.text('Paid in full'), findsNothing);

      await _pump(t, _record(due: 0));
      expect(find.text('Paid in full'), findsOneWidget);

      await _pump(t, _record(estimate: true, due: 1000));
      await t.tap(find.text('Payment'));
      await t.pumpAndSettle();
      expect(find.text('Estimate Total'), findsOneWidget);
      expect(find.text('Balance Due'), findsNothing, reason: 'an estimate has no balance');
    }, () => _mock(_record()));
  });

  testWidgets('line items are a table with a subtotal, the charges and the total', (t) async {
    final r = _record(
      total: 1087.75,
      itemsTotal: 1000,
      charges: [
        {'name': 'Sales Tax (Fayetteville)', 'total': 97.75, 'is_discount': false},
        {'name': 'Same Day Service Credit', 'total': 10, 'is_discount': true},
      ],
    );
    await http.runWithClient(() async {
      await _pump(t, r);
      await t.ensureVisible(find.text('Items subtotal'));
      for (final h in ['ITEM', 'QTY', 'RATE', 'AMOUNT']) {
        expect(find.text(h), findsOneWidget);
      }
      expect(find.text('Items subtotal'), findsOneWidget);
      expect(find.text('Sales Tax (Fayetteville)'), findsOneWidget);
      expect(find.text(r'-$10.00'), findsOneWidget, reason: 'a discount shows as a negative');
      expect(find.text('Job total'), findsOneWidget);
      expect(find.text('Other (not itemized above)'), findsNothing, reason: 'it all adds up');
    }, () => _mock(r));

    // Something in the total that is not an item or a listed charge is shown, not hidden.
    final gap = _record(total: 1100, itemsTotal: 1000);
    await http.runWithClient(() async {
      await _pump(t, gap);
      await t.ensureVisible(find.text('Items subtotal'));
      expect(find.text('Other (not itemized above)'), findsOneWidget);
    }, () => _mock(gap));

    // On an estimate the gap is the sales tax Service Fusion doesn't send, and is labelled that way.
    final est = _record(estimate: true, total: 1085, itemsTotal: 1000);
    await http.runWithClient(() async {
      await _pump(t, est);
      await t.ensureVisible(find.text('Items subtotal'));
      expect(find.text('Tax and other charges'), findsOneWidget);
      expect(find.text('Estimate total'), findsOneWidget);
    }, () => _mock(est));
  });

  testWidgets('opened by its address (no row to show yet) the page shows a skeleton, then the job', (t) async {
    final hold = Completer<void>();
    final r = _record();
    await http.runWithClient(() async {
      await _pump(t, r, hold: hold);
      await t.pump(const Duration(milliseconds: 100));
      expect(find.byType(SkeletonPulse), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Details'), findsNothing);

      hold.complete();
      await t.pumpAndSettle();
      expect(find.byType(SkeletonPulse), findsNothing);
      expect(find.text('Details'), findsOneWidget);
    }, () => _mock(r, hold: hold));
  });

  testWidgets('on a narrow window each row puts the value under its label', (t) async {
    final r = _record();
    await http.runWithClient(() async {
      await _pump(t, r, size: const Size(420, 900));
      final label = t.getTopLeft(find.text('Customer').first);
      final value = t.getTopLeft(find.text('Schuber Mitchell Homes').last);
      expect(value.dy, greaterThan(label.dy), reason: 'the value is below the label');
      expect(value.dx, lessThan(label.dx + 60), reason: 'and starts near the left, not pushed right');
      expect(t.takeException(), isNull);
    }, () => _mock(r));
  });

  testWidgets('tabs announce themselves: the open one is marked selected', (t) async {
    final r = _record();
    final handle = t.ensureSemantics();
    await http.runWithClient(() async {
      await _pump(t, r);
      expect(t.getSemantics(find.text('Scheduling')), isSemantics(label: 'Scheduling', isButton: true, isSelected: true, hasSelectedState: true));
      expect(t.getSemantics(find.text('Payment')), isSemantics(label: 'Payment', isButton: true, isSelected: false, hasSelectedState: true));
    }, () => _mock(r));
    handle.dispose();
  });
}

