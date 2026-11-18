// The Financial dashboard's Commercial pool figure opens the commercial retainage log (GET /api/retainage/commercial-pool).
// Screenshots go to build/dash_shots/commercial_pool_*.png (not goldens).
//
// Run: flutter test test/commercial_pool_dialog_test.dart

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:iohd_desktop/reports_screen.dart';
import 'package:iohd_desktop/widgets/commercial_pool_dialog.dart';

import 'dashboard_harness.dart';

const _log = '/api/retainage/commercial-pool';

Map<String, dynamic> _entry(int id, String kind, double amount, String job, String customer, String tech, String date,
        {bool counted = true, bool released = false, String? releasedDate}) =>
    {
      'id': id, 'kind': kind, 'amount': amount, 'jobId': job, 'customer': customer, 'tech': tech, 'date': date,
      'unlockDate': released ? '2026-07-01' : '2027-04-01', 'releasedDate': releasedDate, 'released': released,
      'counted': counted,
    };

final _body = {
  'success': true,
  'balance': 405.55,
  'pending': 11.7,
  'readyToRelease': 0,
  'released': 150,
  'nextUnlock': '2027-04-01',
  'entries': [
    _entry(5, 'deposit', 11.7, '1100647606', 'Green Acres Airport', 'Nick Smith', '2026-10-21', counted: false),
    _entry(4, 'callback', -33.33, '1098208548', 'Ideal Structures LLC', 'Nick Smith', '2026-10-14'),
    _entry(3, 'deposit', 236.93, '1098208548', 'Ideal Structures LLC', 'Nick Smith', '2026-10-14'),
    _entry(2, 'deposit', 201.95, '1094565460', 'Quality Building Systems Inc.', 'Daniel Baty', '2026-10-08'),
    _entry(1, 'deposit', 150, '1085848855', 'Trulove Construction', 'Daniel Baty', '2026-05-02',
        released: true, releasedDate: '2026-07-01'),
  ],
};

DashFakeApi _api({int status = 200}) {
  final api = DashFakeApi();
  api.extra.add((req) async {
    if (req.url.path != _log) return null;
    if (status != 200) return http.Response(json.encode({'error': 'boom'}), status);
    return http.Response(json.encode(_body), 200);
  });
  return api;
}

Future<void> _openLog(WidgetTester tester) async {
  await tester.tap(find.text('Commercial pool').first);
  await settleDashboard(tester, frames: 15);
}

void main() {
  setUpAll(loadDashFonts);
  setUp(() async {
    pinDashClock();
    await dashSignIn();
  });
  tearDown(unpinDashClock);

  testWidgets('the Commercial pool figure opens its log: figures, entries, released and waiting rows', (tester) async {
    final api = _api();
    final errors = await pumpDashboard(
      tester,
      const ReportsScreen(),
      api: api,
      size: const Size(1440, 860),
      body: () async {
        await _openLog(tester);
        expect(find.byType(CommercialPoolDialog), findsOneWidget);
        expect(api.to(_log), hasLength(1));
        expect(find.text('All time · 5 entries · next release Apr 1, 2027'), findsOneWidget);
        expect(find.text('Locked'), findsOneWidget);
        expect(find.text('Ready to release'), findsOneWidget);
        expect(find.text('Waiting for payroll'), findsWidgets); // the figure and the tag on the unpaid job
        expect(find.text('Released'), findsWidgets); // the figure and the tag on the released row
        expect(find.text('Job #1100647606 · Green Acres Airport'), findsOneWidget);
        expect(find.text('-\$33.33'), findsOneWidget);
        expect(find.text('New transaction'), findsNothing); // read-only
        await saveDashShot(tester, 'commercial_pool_log_1440');

        // Filters: callbacks only, then a search by tech.
        await tester.tap(find.textContaining('Callbacks ('));
        await tester.pump();
        expect(find.text('Job #1094565460 · Quality Building Systems Inc.'), findsNothing);
        expect(find.text('Job #1098208548 · Ideal Structures LLC'), findsOneWidget);
        await tester.tap(find.textContaining('All ('));
        await tester.pump();
        await tester.enterText(find.byType(TextField), 'baty');
        await tester.pump();
        expect(find.text('Job #1094565460 · Quality Building Systems Inc.'), findsOneWidget);
        expect(find.text('Job #1100647606 · Green Acres Airport'), findsNothing);
      },
    );
    expect(errors.messages, isEmpty);
  });

  testWidgets('a failed load shows the error with Try again', (tester) async {
    final api = _api(status: 500);
    final errors = await pumpDashboard(
      tester,
      const ReportsScreen(),
      api: api,
      size: const Size(1280, 720),
      body: () async {
        await _openLog(tester);
        expect(find.text('Try again'), findsOneWidget);
        await saveDashShot(tester, 'commercial_pool_error_1280');
      },
    );
    expect(errors.messages, isEmpty);
  });
}
