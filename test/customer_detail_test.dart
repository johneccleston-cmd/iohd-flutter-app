import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:iohd_desktop/customer_detail_screen.dart';

import 'dashboard_harness.dart';

const _customer = {
  'id': 19000001, 'account_number': '40276',
  'customer_name': 'Lisa Swaim',
  'primary_contact': 'Lisa Swaim',
  'phone': '(267) 319-3444',
  'email': 'lisreneet@gmail.com',
  'service_location': '12 Maple Ln',
  'city': 'Philadelphia',
  'state': 'PA',
  'first_seen_at': '2022-07-14T16:27:00Z',
};

const _jobs = [
  {'job_id': 11960, 'status': 'Complete', 'category': 'Residential', 'start_date': '2022-09-12T00:00:00Z', 'is_estimate': false, 'total_revenue': 100.0, 'due_total': 0.0},
  {'job_id': 3878, 'status': 'Final Invoice Sent', 'category': 'Residential', 'start_date': '2022-07-14T00:00:00Z', 'is_estimate': false, 'total_revenue': 450.5, 'due_total': 450.5},
  {'job_id': 3801, 'status': 'Won', 'category': 'Residential', 'start_date': '2022-06-01T00:00:00Z', 'is_estimate': true, 'total_revenue': 900.0, 'due_total': 900.0},
];

void main() {
  testWidgets('customer page shows account info, financials and jobs', (tester) async {
    final api = DashFakeApi()
      ..extra.add((req) async => req.url.path == '/api/customers/40276'
          ? http.Response(json.encode({'success': true, 'customer': _customer, 'jobs': _jobs}), 200)
          : null);
    final errors = await pumpDashboard(
      tester,
      const CustomerDetailScreen(customerId: '40276'),
      api: api,
      size: const Size(1280, 700),
      body: () async {
        expect(find.text('Account Info'), findsOneWidget);
        expect(find.text('(267) 319-3444'), findsOneWidget);
        expect(find.text('Swaim'), findsWidgets);
        await saveDashShot(tester, 'customer_account');

        await tester.tap(find.text('Financial Data'));
        await settleDashboard(tester, frames: 3);
        expect(find.text(r'$550.50'), findsOneWidget);
        await saveDashShot(tester, 'customer_financial');

        await tester.tap(find.textContaining('Jobs & Estimates'));
        await settleDashboard(tester, frames: 3);
        expect(find.text('Est 3801'), findsOneWidget);
        await saveDashShot(tester, 'customer_jobs');
      },
    );
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('a missing customer shows an error with retry', (tester) async {
    final api = DashFakeApi()..status['/api/customers/1'] = 404;
    await pumpDashboard(tester, const CustomerDetailScreen(customerId: '1'), api: api, body: () async {
      expect(find.text("Couldn't load this customer"), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });
  });
}
