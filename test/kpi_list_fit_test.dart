// The Team KPIs list (/hr/kpis, lib/kpi_dashboard_screen.dart): the four team scorecards over a row of employee cards
// that scrolls sideways. On production's /users shape it fits the desktop sizes without scrolling up and down, at 100%
// and 130% text, and the loading, error and empty states say what is going on. Screenshots go to
// build/dash_shots/kpi_list_*.png for review (not goldens; kpi_list_render_test.dart holds the old goldens).
//   flutter test test/kpi_list_fit_test.dart

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:iohd_desktop/kpi_dashboard_screen.dart';

import 'dashboard_fit.dart';
import 'dashboard_harness.dart';

final _now = DateTime(2026, 11, 4, 9, 30);

/// /users as production sends it: the stored role as `jobTitle`, the printed title as `displayTitle` (the role again
/// when no title is set), no photos, yearsWorked a Postgres numeric (so a string), and the integrity score after
/// missed completions (2 points each).
List<Map<String, dynamic>> kpiListUsers() => [
      for (final u in const [
        ('AndrewJohnson', 'Andrew Johnson', 'Technician', 'Technician', '0.3504', 1),
        ('bhansberger', 'Bella Hansberger', 'Office', 'Office', '2.4381', 0),
        ('bmiller', 'Brett Miller', 'Technician', 'Residential Technician', '1.7509', 2),
        ('gbaty', 'Daniel Baty', 'Lead Technician', 'Lead Technician', '2.8241', 0),
        ('dgray', 'Dennis Gray', 'warehouse', 'Warehouse Technician', '2.4353', 0),
        ('hvera', 'Heather Vera', 'Office Manager', 'Sales Account Manager', '4.2998', 0),
        ('jeccleston', 'John Eccleston', 'ADMIN', 'ADMIN', '1.2553', 0),
        ('nsmith', 'Nick Smith', 'Lead Technician', 'Lead Technician', '2.4709', 0),
        ('zclemens', 'Zac Clemens', 'Sales Rep', 'Commercial Estimator', '2.7365', 0),
      ])
        {
          'id': u.$1,
          'name': u.$2,
          'jobTitle': u.$3,
          'displayTitle': u.$4,
          'avatarUrl': '',
          'integrityScore': 100 - u.$6 * 2,
          'missedCompletions': u.$6,
          'yearsWorked': u.$5,
        },
    ];

http.Response _json(Object body, [int status = 200]) =>
    http.Response(json.encode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

DashFakeApi _api({int status = 200, List<Map<String, dynamic>>? users, Completer<void>? gate}) {
  final api = DashFakeApi();
  api.extra.add((req) async {
    if (req.url.path != '/users') return null;
    if (gate != null) await gate.future;
    return status == 200 ? _json(users ?? kpiListUsers()) : _json({'error': 'simulated'}, status);
  });
  return api;
}

Widget _page() => const KPIDashboardScreen();

void main() {
  setUpAll(loadDashFonts);
  setUp(() async {
    pinDashClock(_now);
    await dashSignIn();
  });
  tearDown(unpinDashClock);

  dashFitTests(
    'kpi_list',
    _page,
    () => _api(),
    mustShow: ['Team integrity', 'Employee morale', 'Employees', 'Average tenure', 'Heather Vera'],
    extra: (t, size, scale) async {
      // The first card is whole: its name, title, time with the company and score are all on screen.
      final window = Offset.zero & size;
      for (final text in ['Sales Account Manager', 'Company tenure', '4 yrs 4 mo', 'Integrity score']) {
        final r = dashTextRect(t, text);
        expect(window.contains(r.bottomRight - const Offset(0.01, 0.01)), isTrue, reason: '"$text" is on screen ($r)');
      }
    },
  );

  testWidgets('the team figures add up from /users', (t) async {
    await pumpDashboard(t, _page(), api: _api(), size: const Size(1500, 800), body: () async {
      // (98 + 100 + 96 + 6 x 100) / 9 = 99.3; ranks follow the score, ties share a rank.
      expect(find.text('99.3%'), findsOneWidget);
      expect(find.text('9'), findsOneWidget);
      expect(find.text('Not tracked yet'), findsOneWidget);
      // The average time with the company, written like each card's ("2 yrs 3 mo").
      expect(find.text('2 yrs 3 mo'), findsWidgets);
      expect(find.text('Rank #1'), findsWidgets);
      expect(find.text('9 employees'), findsNothing, reason: 'the cards run off the right edge, so the counter shows the range');
    });
  });

  testWidgets('a skeleton while the list loads', (t) async {
    final gate = Completer<void>();
    await pumpDashboard(t, _page(), api: _api(gate: gate), size: const Size(1366, 768), body: () async {
      await saveDashShot(t, 'kpi_list_loading');
      gate.complete();
      await settleDashboard(t);
      expect(find.text('Heather Vera'), findsOneWidget);
    });
  });

  testWidgets('a failed load says so, with Try again that works', (t) async {
    var status = 500;
    final api = DashFakeApi();
    api.extra.add((req) async => req.url.path == '/users' ? (status == 200 ? _json(kpiListUsers()) : _json({'error': 'x'}, status)) : null);
    final errors = await pumpDashboard(t, _page(), api: api, size: const Size(1366, 768), body: () async {
      expect(find.text("Couldn't load the team"), findsOneWidget);
      await saveDashShot(t, 'kpi_list_error');
      status = 200;
      await t.tap(find.text('Try again'));
      await settleDashboard(t);
      expect(find.text('Heather Vera'), findsOneWidget);
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('no active employees: a plain empty state with Refresh', (t) async {
    final errors = await pumpDashboard(t, _page(), api: _api(users: const []), size: const Size(1366, 768), body: () async {
      expect(find.text('No active employees yet'), findsOneWidget);
      expect(find.text('Refresh'), findsOneWidget);
      await saveDashShot(t, 'kpi_list_empty');
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });
}
