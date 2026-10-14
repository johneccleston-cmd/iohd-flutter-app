// Behaviour of the shared Jobs / Estimates list: search (debounced, from the route, clearable), status filter, row click,
// empty state, paging and error retry.  Run:  flutter test test/record_list_test.dart

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/estimates_screen.dart';
import 'package:iohd_desktop/jobs_screen.dart';

List<Map<String, dynamic>> _rows(String prefix, int n) => [
      for (var i = 0; i < n; i++)
        {
          'job_id': '${1000 + i}',
          'customer_name': '$prefix customer $i',
          'location': '$i Main St',
          'description': '',
          'start_date': '2026-10-01',
          'total_revenue': '${100 * (i + 1)}',
          'status': 'Scheduled - Full Day',
          'techs_assigned': 'Brett Hall',
          'opportunity_owner': 'Heather Vera',
        },
    ];

/// A fake server that records every request URL.
class _Server {
  final List<Uri> urls = [];
  bool empty = false;
  int? failCode;

  http.Client client() => MockClient((req) async {
        urls.add(req.url);
        if (failCode != null) return http.Response('boom', failCode!);
        final p = req.url.path;
        if (p.endsWith('status-counts')) {
          return http.Response(
            jsonEncode({'total': 30, 'counts': [{'status': 'Need To Schedule', 'count': 10}, {'status': 'Scheduled - Full Day', 'count': 20}]}),
            200,
          );
        }
        final q = req.url.queryParameters['q'] ?? '';
        final rows = (empty || q == 'nothing') ? <Map<String, dynamic>>[] : _rows(q.isEmpty ? 'Row' : q, 3);
        return http.Response(jsonEncode({'data': rows, 'total': rows.isEmpty ? 0 : 130, 'page': 1, 'totalPages': rows.isEmpty ? 1 : 3}), 200);
      });

  List<Uri> lists() => urls.where((u) => !u.path.endsWith('status-counts')).toList();

  /// Requests for page 1 only: the list also fetches the NEXT page ahead of time, which would muddy a count.
  List<Uri> firstPages() => lists().where((u) => u.queryParameters['page'] == '1').toList();
}

GoRouter _router(Widget Function(String? q) screen) => GoRouter(
      initialLocation: '/jobs',
      routes: [
        GoRoute(path: '/jobs', builder: (_, s) => screen(s.uri.queryParameters['q']), routes: [GoRoute(path: ':id', builder: (_, s) => Text('JOB PAGE ${s.pathParameters['id']}'))]),
        GoRoute(path: '/estimates', builder: (_, s) => screen(s.uri.queryParameters['q']), routes: [GoRoute(path: ':id', builder: (_, s) => Text('ESTIMATE PAGE ${s.pathParameters['id']}'))]),
      ],
    );

Future<GoRouter> _pump(WidgetTester t, _Server server, {String start = '/jobs', bool estimates = false, Size size = const Size(1400, 800)}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  final router = _router((q) => estimates ? EstimatesScreen(initialQuery: q) : JobsScreen(initialQuery: q));
  router.go(start);
  await http.runWithClient(() async {
    await t.pumpWidget(MaterialApp.router(routerConfig: router));
    await t.pumpAndSettle();
  }, () => server.client());
  return router;
}

void main() {
  testWidgets('loads page 1 with the default page size, newest first, and fills the status filter', (t) async {
    final s = _Server();
    await http.runWithClient(() async {
      await _pump(t, s);
      expect(s.lists().first.queryParameters, {'status': 'All', 'q': '', 'page': '1', 'limit': '50'});
      expect(find.text('Row customer 0'), findsOneWidget);
      expect(find.text('Need To Schedule'), findsOneWidget); // sidebar entry
      expect(find.text('3 jobs'), findsNothing); // header shows the real total, not the page count
      expect(find.text('30 jobs'), findsOneWidget);
    }, () => s.client());
  });

  testWidgets('the nav bar search (?q=) is applied on open, and again if you search while the list is already open', (t) async {
    final s = _Server();
    late GoRouter router;
    await http.runWithClient(() async {
      router = await _pump(t, s, start: '/jobs?q=Whitfield');
      expect(s.lists().first.queryParameters['q'], 'Whitfield');
      expect(find.widgetWithText(TextField, 'Whitfield'), findsOneWidget);
      expect(find.text('Whitfield customer 0'), findsOneWidget);

      router.go('/jobs?q=Moser'); // the nav bar search again, same screen kept alive
      await t.pumpAndSettle();
      expect(s.lists().last.queryParameters['q'], 'Moser');
      expect(find.widgetWithText(TextField, 'Moser'), findsOneWidget);
      expect(find.text('Moser customer 0'), findsOneWidget);
    }, () => s.client());
  });

  testWidgets('typing searches once after a short pause (debounced), and the clear button resets it', (t) async {
    final s = _Server();
    await http.runWithClient(() async {
      await _pump(t, s);
      final before = s.firstPages().length;
      await t.enterText(find.byType(TextField), 'sch');
      await t.pump(const Duration(milliseconds: 100));
      await t.enterText(find.byType(TextField), 'schu');
      await t.pump(const Duration(milliseconds: 100));
      await t.enterText(find.byType(TextField), 'schuber');
      expect(s.firstPages().length, before, reason: 'no request while still typing');
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      expect(s.firstPages().length, before + 1, reason: 'one request after the pause');
      expect(s.firstPages().last.queryParameters['q'], 'schuber');
      expect(find.text('30 jobs'), findsNothing);
      expect(find.textContaining('matching "schuber"'), findsOneWidget);

      await t.tap(find.byTooltip('Clear search'));
      await t.pumpAndSettle();
      expect(find.byTooltip('Clear search'), findsNothing);
      expect(find.text('Row customer 0'), findsOneWidget); // back to the unfiltered list (served from the page cache)
      expect(find.textContaining('matching'), findsNothing);
    }, () => s.client());
  });

  testWidgets('picking a status filters, and a search with no matches offers to clear it', (t) async {
    final s = _Server();
    await http.runWithClient(() async {
      await _pump(t, s);
      await t.tap(find.text('Need To Schedule'));
      await t.pumpAndSettle();
      expect(s.lists().last.queryParameters['status'], 'Need To Schedule');
      expect(find.textContaining('Need To Schedule'), findsWidgets);

      await t.enterText(find.byType(TextField), 'nothing');
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      expect(find.text('No jobs found'), findsOneWidget);
      expect(find.textContaining('Nothing matches "nothing" in Need To Schedule'), findsOneWidget);

      await t.tap(find.text('Clear search and filter'));
      await t.pumpAndSettle();
      expect(find.text('Row customer 0'), findsOneWidget); // the unfiltered list is back
      expect(find.text('30 jobs'), findsOneWidget);
      expect(find.text('No jobs found'), findsNothing);
    }, () => s.client());
  });

  testWidgets('clicking a row opens that job, or that estimate on the Estimates list', (t) async {
    final s = _Server();
    await http.runWithClient(() async {
      var router = await _pump(t, s);
      await t.tap(find.text('Row customer 1'));
      await t.pumpAndSettle();
      expect(router.routerDelegate.currentConfiguration.uri.path, '/jobs/1001');

      router = await _pump(t, _Server(), start: '/estimates', estimates: true);
      await t.tap(find.text('Row customer 2'));
      await t.pumpAndSettle();
      expect(router.routerDelegate.currentConfiguration.uri.path, '/estimates/1002');
    }, () => s.client());
  });

  testWidgets('Next moves to page 2 and Rows changes the page size', (t) async {
    final s = _Server();
    await http.runWithClient(() async {
      await _pump(t, s);
      await t.tap(find.byTooltip('Next page'));
      await t.pumpAndSettle();
      expect(s.lists().any((u) => u.queryParameters['page'] == '2'), isTrue);
      expect(find.text('Page 2 of 3'), findsOneWidget);

      await t.tap(find.text('100'));
      await t.pumpAndSettle();
      expect(s.firstPages().last.queryParameters['limit'], '100');
      expect(find.text('Page 1 of 3'), findsOneWidget);
    }, () => s.client());
  });

  testWidgets('a failed load shows the reason with Try again, and it recovers', (t) async {
    final s = _Server()..failCode = 500;
    await http.runWithClient(() async {
      await _pump(t, s);
      expect(find.text('Could not load jobs'), findsOneWidget);
      expect(find.text('The server returned status 500.'), findsOneWidget);
      expect(find.textContaining('Page 1 of'), findsNothing); // no paging controls on an error

      s.failCode = null;
      await t.tap(find.text('Try again'));
      await t.pumpAndSettle();
      expect(find.text('Row customer 0'), findsOneWidget);
    }, () => s.client());
  });

  testWidgets('narrow window: no overflow, the status filter becomes a menu, and the people column is dropped', (t) async {
    final s = _Server();
    await http.runWithClient(() async {
      await _pump(t, s, size: const Size(700, 700));
      expect(find.text('All statuses'), findsOneWidget);
      expect(find.text('TECHS'), findsNothing);
      await t.tap(find.text('All statuses'));
      await t.pumpAndSettle();
      await t.tap(find.text('Need To Schedule').last);
      await t.pumpAndSettle();
      expect(s.lists().last.queryParameters['status'], 'Need To Schedule');
      expect(t.takeException(), isNull);

      await _pump(t, s, size: const Size(420, 700)); // phone-ish: rows become two lines
      expect(t.takeException(), isNull);
    }, () => s.client());
  });
}
