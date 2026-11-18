// Leaving the job or estimate page while its Edit Job / Edit Estimate preview has changes asks first (user 2026-11-13):
// the top bar's tabs, the search, Back to another record in the same section, and the page's own links. Keep editing
// stays; Discard changes drops the draft and goes. A preview with no changes, or no preview, leaves without a question.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/job_detail_screen.dart';
import 'package:iohd_desktop/widgets/leave_guard.dart';
import 'package:iohd_desktop/widgets/main_navigation_shell.dart';
import 'package:iohd_desktop/widgets/page_selection.dart';

import 'job_page_fixture.dart';
import 'nav_fixture.dart';

GoRoute _stub(String p, {List<RouteBase> routes = const []}) =>
    GoRoute(path: p, builder: (_, s) => Center(child: Text('stub ${s.uri.path}')), routes: routes);

GoRouter _router(String initial) => GoRouter(initialLocation: initial, routes: [
      StatefulShellRoute.indexedStack(
        builder: (c, s, shell) => RouteSelection(child: MainNavigationShell(navigationShell: shell)),
        branches: [
          StatefulShellBranch(routes: [_stub('/office'), _stub('/invoices')]),
          StatefulShellBranch(routes: [_stub('/customers', routes: [_stub(':id')])]),
          StatefulShellBranch(routes: [_stub('/projects')]),
          StatefulShellBranch(routes: [_stub('/estimates', routes: [jobDetailRoute()])]),
          StatefulShellBranch(routes: [_stub('/jobs', routes: [jobDetailRoute()])]),
          StatefulShellBranch(routes: [_stub('/calendar')]),
          StatefulShellBranch(routes: [_stub('/inventory')]),
          StatefulShellBranch(routes: [_stub('/hr', routes: [_stub('payroll')])]),
          StatefulShellBranch(routes: [_stub('/dashboards', routes: [_stub('financial')])]),
          StatefulShellBranch(routes: [_stub('/profile')]),
        ],
      ),
    ]);

Future<void> _frames(WidgetTester t, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// The app with the real job page at `/jobs/<kJobId>`, then [body] inside the fake server's zone.
Future<GoRouter> _open(WidgetTester t, Future<void> Function(GoRouter r) body, {String at = '/jobs/$kJobId'}) async {
  t.view.physicalSize = const Size(1500, 2400);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final server = FakeJobServer();
  final client = MockClient((req) async {
    if (req.url.path == '/api/jobs' && (req.url.queryParameters['q'] ?? '').isNotEmpty) {
      return http.Response(json.encode({'data': [{'job_id': kOtherJobId, 'customer_name': 'Zed Co', 'status': 'Scheduled', 'location': 'x'}], 'total': 1}), 200);
    }
    if (const {'/api/jobs', '/api/estimates', '/api/customers', '/api/invoices'}.contains(req.url.path)) {
      return http.Response(json.encode({'data': [], 'total': 0}), 200);
    }
    return server.handle(req);
  });
  final router = _router(at);
  await http.runWithClient(() async {
    await t.pumpWidget(MaterialApp.router(routerConfig: router, builder: appSelectionBuilder, theme: navTestTheme()));
    await _frames(t, 20);
    await body(router);
  }, () => client);
  return router;
}

/// Edit Job, then change the quantity on Service Fusion's third line.
Future<void> _change(WidgetTester t) async {
  await t.tap(find.text('Edit Job'));
  await _frames(t, 6);
  await t.tap(find.text("Stop Mold | 7' Sandtone"));
  await _frames(t, 2);
  await t.enterText(find.byKey(const ValueKey('line-2-qty')), '6');
  await t.pump(const Duration(milliseconds: 50));
  await t.sendKeyEvent(LogicalKeyboardKey.escape);
  await _frames(t, 3);
  expect(find.text('Changed, not saved'), findsOneWidget);
}

Finder get _calendarTab => find.descendant(of: find.byType(MainNavigationShell), matching: find.text('Calendar')).first;
Finder get _dialog => find.text('Leave without saving?');

void main() {
  setUpAll(loadNavFonts);
  setUp(() => navSignIn());

  testWidgets('a top bar tab asks; Keep editing stays with the draft; Discard changes goes', (t) async {
    final r = await _open(t, (r) async {
      await _change(t);
      await t.tap(_calendarTab);
      await _frames(t, 4);
      expect(_dialog, findsOneWidget);
      expect(find.text('Keep editing'), findsOneWidget);
      expect(find.text('Discard changes'), findsOneWidget);

      await t.tap(find.text('Keep editing'));
      await _frames(t, 4);
      expect(_dialog, findsNothing);
      expect(r.state.uri.path, '/jobs/$kJobId');
      expect(find.text('Changed, not saved'), findsOneWidget, reason: 'the draft is still there');

      await t.tap(_calendarTab);
      await _frames(t, 4);
      await t.tap(find.text('Discard changes'));
      await _frames(t, 6);
    });
    expect(r.state.uri.path, '/calendar');
    expect(find.text('stub /calendar'), findsOneWidget);
  });

  testWidgets('the search: picking another job asks, then opens it', (t) async {
    final r = await _open(t, (r) async {
      await _change(t);
      final field = find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'Search');
      await t.tap(field);
      await t.pump();
      await t.enterText(field, '1097');
      await _frames(t, 10);
      await t.tap(find.textContaining('#$kOtherJobId').first);
      await _frames(t, 4);
      expect(_dialog, findsOneWidget);
      expect(r.state.uri.path, '/jobs/$kJobId');
      await t.tap(find.text('Discard changes'));
      await _frames(t, 10);
    });
    expect(r.state.uri.path, '/jobs/$kOtherJobId');
    expect(_dialog, findsNothing, reason: 'one question, not one from the bar and another from the route');
  });

  testWidgets('a go to another record in the same section (Back, links) asks through the route', (t) async {
    final r = await _open(t, (r) async {
      await _change(t);
      r.go('/jobs/$kOtherJobId');
      await _frames(t, 4);
      expect(_dialog, findsOneWidget);
      await t.tap(find.text('Keep editing'));
      await _frames(t, 4);
      expect(r.state.uri.path, '/jobs/$kJobId');
      expect(find.text('Changed, not saved'), findsOneWidget);
    });
    expect(r.state.uri.path, '/jobs/$kJobId');
  });

  testWidgets('editing with no changes, or not editing, leaves without a question', (t) async {
    final r = await _open(t, (r) async {
      await t.tap(find.text('Edit Job'));
      await _frames(t, 6);
      await t.tap(_calendarTab);
      await _frames(t, 6);
      expect(_dialog, findsNothing);
    });
    expect(r.state.uri.path, '/calendar');
  });

  testWidgets('the page drops its check when it closes', (t) async {
    await _open(t, (r) async {
      expect(LeaveGuard.count, 1);
      r.go('/jobs/$kOtherJobId');
      await _frames(t, 10);
      expect(LeaveGuard.count, 1, reason: 'the new page only');
    });
    await t.pumpWidget(const SizedBox());
    expect(LeaveGuard.count, 0);
  });
}

