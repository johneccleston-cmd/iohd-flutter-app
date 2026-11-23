// The Financial dashboard's Company pool figure opens the pool's log, and the log's New transaction form saves an
// entry by hand (POST /api/retainage/company-pool/entries), then the log and the dashboard figure reload.
// Screenshots go to build/dash_shots/company_pool_*.png (not goldens).
//
// Run: flutter test test/company_pool_dialog_test.dart

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:iohd_desktop/config/auth_session.dart';
import 'package:iohd_desktop/reports_screen.dart';
import 'package:iohd_desktop/widgets/company_pool_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dashboard_harness.dart';

const _log = '/api/retainage/company-pool';
const _entries = '/api/retainage/company-pool/entries';

Map<String, dynamic> _logBody({bool withManual = false}) => {
      'success': true,
      'balance': withManual ? -42.5 : 32.5,
      'pending': 12.5,
      'moneyIn': 52.5,
      'moneyOut': withManual ? -95.0 : -20.0,
      'entries': [
        if (withManual)
          {
            'id': 42, 'kind': 'manual', 'amount': -75, 'jobId': null, 'customer': null, 'date': '2026-10-22',
            'note': 'Spring replaced under warranty', 'createdBy': 'Test Admin', 'counted': true,
            'category': 'warranty', 'categoryLabel': 'Warranty repair or part',
          },
        {
          'id': 9, 'kind': 'deposit', 'amount': 12.5, 'jobId': '1101296053', 'customer': 'Maria Lopez', 'date': '2026-10-21',
          'note': '', 'createdBy': '', 'counted': false,
        },
        {
          'id': 8, 'kind': 'manual', 'amount': 25, 'jobId': null, 'customer': null, 'date': '2026-10-15',
          'note': 'Owner top-up', 'createdBy': 'Test Admin', 'counted': true,
          'category': 'top_up', 'categoryLabel': 'Company top-up',
        },
        {
          'id': 5, 'kind': 'deposit', 'amount': 27.5, 'jobId': '1101295120', 'customer': 'Northside Storage LLC',
          'date': '2026-10-09', 'note': '', 'createdBy': '', 'counted': true,
        },
        {
          'id': 4, 'kind': 'callback', 'amount': -20, 'jobId': '1101295120', 'customer': 'Northside Storage LLC',
          'date': '2026-10-09', 'note': '', 'createdBy': '', 'counted': true,
        },
      ],
    };

/// Answers the pool's log and records what the form posts. After a POST the log includes the new entry.
DashFakeApi _api({int logStatus = 200, int postStatus = 201, String? postError}) {
  final api = DashFakeApi();
  var saved = false;
  api.extra.add((req) async {
    if (req.url.path == _log) {
      if (logStatus != 200) return http.Response(json.encode({'error': 'boom'}), logStatus);
      return http.Response(json.encode(_logBody(withManual: saved)), 200);
    }
    if (req.url.path == _entries && req.method == 'POST') {
      if (postStatus != 201) return http.Response(json.encode({'success': false, 'error': postError ?? 'nope'}), postStatus);
      saved = true;
      return http.Response(json.encode({'success': true, 'entry': {'id': 42, 'amount': -75, 'date': '2026-10-22'}}), 201);
    }
    return null;
  });
  return api;
}

final _companyFigure = find.text('Company pool');

Future<void> _openLog(WidgetTester tester) async {
  await tester.tap(_companyFigure.first);
  await settleDashboard(tester, frames: 15);
}

/// Opens the form's Category menu and picks [label].
Future<void> _pickCategory(WidgetTester tester, String label) async {
  await tester.tap(find.byType(DropdownButtonFormField<String>));
  await settleDashboard(tester, frames: 4);
  await tester.tap(find.text(label).last);
  await settleDashboard(tester, frames: 4);
}

void main() {
  setUpAll(loadDashFonts);
  setUp(() async {
    pinDashClock();
    await dashSignIn();
  });
  tearDown(unpinDashClock);

  testWidgets('the Company pool figure opens its log: figures, entries, and which ones wait for payroll', (tester) async {
    final api = _api();
    final errors = await pumpDashboard(
      tester,
      const ReportsScreen(),
      api: api,
      size: const Size(1440, 860),
      body: () async {
        await _openLog(tester);
        expect(find.byType(CompanyPoolDialog), findsOneWidget);
        expect(api.to(_log), hasLength(1));
        expect(find.text('All time · 4 entries'), findsOneWidget);
        expect(find.text('Balance'), findsOneWidget);
        expect(find.text('Waiting for payroll'), findsWidgets); // the figure and the tag on the unpaid job
        expect(find.text('Job #1101296053 · Maria Lopez'), findsOneWidget);
        expect(find.text('Owner top-up'), findsOneWidget);
        expect(find.text('-\$20.00'), findsWidgets);
        expect(find.text('New transaction'), findsOneWidget);
        await saveDashShot(tester, 'company_pool_log_1440');

        // Filters: money out only, then a search.
        await tester.tap(find.textContaining('Out ('));
        await tester.pump();
        expect(find.text('Owner top-up'), findsNothing);
        expect(find.text('Job #1101295120 · Northside Storage LLC'), findsOneWidget);
        await tester.tap(find.textContaining('All ('));
        await tester.pump();
        await tester.enterText(find.byType(TextField), 'top-up');
        await tester.pump();
        expect(find.text('Owner top-up'), findsOneWidget);
        expect(find.text('Job #1101296053 · Maria Lopez'), findsNothing);
      },
    );
    expect(errors.messages, isEmpty);
  });

  testWidgets('New transaction saves money out with the note, job and date, then the log and dashboard reload', (tester) async {
    final api = _api();
    final errors = await pumpDashboard(
      tester,
      const ReportsScreen(),
      api: api,
      size: const Size(1280, 720),
      body: () async {
        final dashboardLoads = api.to('/api/financial_dashboard').length;
        await _openLog(tester);
        await tester.tap(find.text('New transaction'));
        await settleDashboard(tester, frames: 6);
        expect(find.byType(CompanyPoolEntryForm), findsOneWidget);

        // Nothing typed: the form says what is missing and posts nothing.
        await tester.tap(find.text('Save transaction'));
        await tester.pump();
        expect(find.text('Enter an amount.'), findsOneWidget);
        expect(find.text('Say what this is for.'), findsOneWidget);
        expect(find.text('Choose a category.'), findsOneWidget);
        expect(api.to(_entries), isEmpty);

        // Money out offers the money-out categories (and the two that fit either way), not the money-in ones.
        await tester.tap(find.byType(DropdownButtonFormField<String>));
        await settleDashboard(tester, frames: 4);
        expect(find.text('Damage to customer property'), findsWidgets);
        expect(find.text('Company top-up'), findsNothing);
        await tester.tap(find.text('Damage to customer property').last);
        await settleDashboard(tester, frames: 4);

        final fields = find.descendant(of: find.byType(CompanyPoolEntryForm), matching: find.byType(TextField));
        await tester.enterText(fields.at(0), '75');
        await tester.enterText(fields.at(1), 'Spring replaced under warranty');
        await tester.enterText(fields.at(2), '#1101295120');
        await settleDashboard(tester, frames: 4); // the error borders fade out
        expect(find.textContaining('Takes \$75.00 from the company pool'), findsOneWidget);
        expect(find.text('Thu, Oct 22, 2026'), findsOneWidget); // today by default
        await saveDashShot(tester, 'company_pool_new_1280');

        await tester.tap(find.text('Save transaction'));
        await settleDashboard(tester, frames: 15);

        final post = api.to(_entries).single;
        expect(json.decode(post.body), {
          'direction': 'out',
          'amount': 75.0,
          'category': 'property_damage',
          'note': 'Spring replaced under warranty',
          'jobId': '1101295120',
          'date': '2026-10-22',
        });
        expect(post.headers['content-type'], contains('application/json'));
        expect(find.byType(CompanyPoolEntryForm), findsNothing);
        expect(api.to(_log), hasLength(2)); // reloaded
        expect(find.text('Spring replaced under warranty'), findsOneWidget);
        expect(find.textContaining('Paid out · Warranty repair or part'), findsOneWidget);
        expect(find.text('All time · 5 entries'), findsOneWidget);
        await saveDashShot(tester, 'company_pool_after_save_1280');

        // Closing the log reloads the dashboard, skipping the server cache.
        await tester.tap(find.byTooltip('Close'));
        await settleDashboard(tester, frames: 10);
        final reloads = api.to('/api/financial_dashboard').skip(dashboardLoads);
        expect(reloads, isNotEmpty);
        expect(reloads.last.url.queryParameters['fresh'], '1');
      },
    );
    expect(errors.messages, isEmpty);
  });

  testWidgets("a refused entry shows the server's reason and keeps the form open", (tester) async {
    final api = _api(postStatus: 400, postError: 'Job #555 was not found.');
    await pumpDashboard(
      tester,
      const ReportsScreen(),
      api: api,
      size: const Size(1280, 720),
      body: () async {
        await _openLog(tester);
        await tester.tap(find.text('New transaction'));
        await settleDashboard(tester, frames: 6);
        final fields = find.descendant(of: find.byType(CompanyPoolEntryForm), matching: find.byType(TextField));
        await tester.tap(find.descendant(of: find.byType(CompanyPoolEntryForm), matching: find.text('Money in')));
        await tester.pump();
        await _pickCategory(tester, 'Company top-up');
        await tester.enterText(fields.at(0), '40');
        await tester.enterText(fields.at(1), 'Top-up');
        await tester.enterText(fields.at(2), '555');
        await tester.tap(find.text('Save transaction'));
        await settleDashboard(tester, frames: 6);
        expect(json.decode(api.to(_entries).single.body)['direction'], 'in');
        expect(find.text('Job #555 was not found.'), findsOneWidget);
        expect(find.byType(CompanyPoolEntryForm), findsOneWidget);
      },
    );
  });

  testWidgets('Spread over weeks: pick the weeks and each week\'s percent; the total must be 100%', (tester) async {
    final api = _api();
    final errors = await pumpDashboard(
      tester,
      const ReportsScreen(),
      api: api,
      size: const Size(1280, 860),
      body: () async {
        await _openLog(tester);
        await tester.tap(find.text('New transaction'));
        await settleDashboard(tester, frames: 6);
        final form = find.byType(CompanyPoolEntryForm);
        Finder inForm(Finder f) => find.descendant(of: form, matching: f);
        final fields = inForm(find.byType(TextField));
        await tester.enterText(fields.at(0), '1000');
        await tester.enterText(fields.at(1), 'Backed into the customer fence; paid to replace it');
        await _pickCategory(tester, 'Damage to customer property');
        await tester.ensureVisible(inForm(find.text('Spread over weeks')));
        await tester.tap(inForm(find.text('Spread over weeks')));
        await settleDashboard(tester, frames: 4);

        // Four even weeks to start, a week apart from the first week (today, Thu Oct 22).
        expect(inForm(find.text('Week 4')), findsOneWidget);
        expect(inForm(find.text(r'$250.00')), findsNWidgets(4));
        expect(inForm(find.text('Thu, Oct 29')), findsOneWidget);
        expect(inForm(find.text('First week')), findsOneWidget);

        // Down to three weeks: 33.3333 / 33.3333 / 33.3334%, which is $333.33 / $333.33 / $333.34.
        await tester.ensureVisible(find.byTooltip('One week fewer'));
        await tester.pump();
        await tester.tap(find.byTooltip('One week fewer'));
        await tester.pump();
        expect(inForm(find.text('Week 4')), findsNothing);
        expect(inForm(find.text(r'$333.33')), findsNWidgets(2));
        expect(inForm(find.text(r'$333.34')), findsOneWidget);

        // 50 / 30 / 20.
        final pct = inForm(find.byWidgetPredicate((w) => w is TextField && w.decoration?.suffixText == '%'));
        expect(pct, findsNWidgets(3));
        await tester.enterText(pct.at(0), '50');
        await tester.enterText(pct.at(1), '30');
        await tester.pump();
        expect(find.text('The weeks add up to 113.3334%. They need to add up to 100%.'), findsOneWidget);
        await tester.tap(inForm(find.text('Save transaction')));
        await tester.pump();
        expect(api.to(_entries), isEmpty, reason: 'nothing is saved while the weeks are off');

        await tester.enterText(pct.at(2), '20');
        await settleDashboard(tester, frames: 4);
        expect(find.textContaining('They need to add up to 100%'), findsNothing);
        expect(inForm(find.text(r'$500.00')), findsOneWidget);
        expect(inForm(find.text(r'$300.00')), findsOneWidget);
        expect(inForm(find.text(r'$200.00')), findsOneWidget);
        expect(find.textContaining('over 3 weeks, Thu, Oct 22 to Thu, Nov 5'), findsOneWidget);
        await saveDashShot(tester, 'company_pool_spread_1280');

        await tester.tap(inForm(find.text('Save transaction')));
        await settleDashboard(tester, frames: 15);
        expect(json.decode(api.to(_entries).single.body), {
          'direction': 'out',
          'amount': 1000.0,
          'category': 'property_damage',
          'note': 'Backed into the customer fence; paid to replace it',
          'date': '2026-10-22',
          'weeklyPercents': [50.0, 30.0, 20.0],
        });
        expect(find.text(r'$1,000.00 paid out of the company pool, spread over 3 weeks.'), findsOneWidget);
      },
    );
    expect(errors.messages, isEmpty);
  });

  testWidgets('the log shows a spread payment\'s weeks still to come as Scheduled', (tester) async {
    final api = DashFakeApi();
    api.extra.add((req) async {
      if (req.url.path != _log) return null;
      final body = _logBody();
      body['scheduled'] = -500.0;
      body['entries'] = <Object?>[
        for (final w in [(3, '2026-11-05', -200, true), (2, '2026-10-29', -300, true), (1, '2026-10-22', -500, false)])
          <String, Object?>{
            'id': 60 + w.$1, 'kind': 'manual', 'amount': w.$3, 'jobId': null, 'customer': null, 'date': w.$2,
            'note': 'Backed into the customer fence', 'createdBy': 'Test Admin', 'counted': !w.$4, 'scheduled': w.$4,
            'category': 'property_damage', 'categoryLabel': 'Damage to customer property',
            'plan': {'id': 'p1', 'part': w.$1, 'parts': 3},
          },
        ...(body['entries'] as List),
      ];
      return http.Response(json.encode(body), 200);
    });
    final errors = await pumpDashboard(
      tester,
      const ReportsScreen(),
      api: api,
      size: const Size(1440, 860),
      body: () async {
        await _openLog(tester);
        await saveDashShot(tester, 'company_pool_log_scheduled_1440');
        expect(find.text('Scheduled'), findsNWidgets(3)); // the figure and two weeks
        expect(find.text('Weeks still to come'), findsOneWidget);
        expect(find.textContaining('Paid out · Damage to customer property · Week 2 of 3'), findsOneWidget);
        expect(find.textContaining('Week 1 of 3'), findsOneWidget);
        await saveDashShot(tester, 'company_pool_log_scheduled_1440');
      },
    );
    expect(errors.messages, isEmpty);
  });

  testWidgets('the log handles a failed load with Try again', (tester) async {
    final api = _api(logStatus: 500);
    await pumpDashboard(
      tester,
      const ReportsScreen(),
      api: api,
      size: const Size(1280, 720),
      body: () async {
        await _openLog(tester);
        expect(find.text('Try again'), findsOneWidget);
        expect(find.text('New transaction'), findsNothing);
        await saveDashShot(tester, 'company_pool_error_1280');
      },
    );
  });

  testWidgets('without the pools switch the figure is a plain number', (tester) async {
    AuthSession.instance.logout();
    final payload = base64Url.encode(utf8.encode(json.encode({'exp': DateTime(2100).millisecondsSinceEpoch})));
    SharedPreferences.setMockInitialValues({
      'iohd_auth_session': json.encode({
        'token': '$payload.sig', 'name': 'Test Office', 'role': 'Office', 'is_admin': false,
        'denied': <String>['company_pool.view'],
      }),
    });
    await AuthSession.instance.restore();
    final api = _api();
    await pumpDashboard(
      tester,
      const ReportsScreen(),
      api: api,
      size: const Size(1280, 720),
      body: () async {
        await tester.tap(_companyFigure.first, warnIfMissed: false);
        await settleDashboard(tester, frames: 6);
        expect(find.byType(CompanyPoolDialog), findsNothing);
        expect(api.to(_log), isEmpty);
      },
    );
  });
}
