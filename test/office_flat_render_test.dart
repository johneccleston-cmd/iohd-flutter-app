// Renders the My Office screens flat, to test/shots/. Run:  flutter test test/office_flat_render_test.dart --update-goldens

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/customers_screen.dart';
import 'package:iohd_desktop/estimates_screen.dart';
import 'package:iohd_desktop/invoices_screen.dart';
import 'package:iohd_desktop/jobs_screen.dart';
import 'package:iohd_desktop/site_checks_screen.dart';
import 'package:iohd_desktop/statuses_screen.dart';
import 'package:iohd_desktop/takeoffs_screen.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

const _statuses = ['Final Invoice Sent', 'Scheduled - Full Day', 'Need To Schedule', 'Paid & Closed', 'Complete'];

http.Client _mock({bool empty = false, int? failCode}) => MockClient((req) async {
      if (failCode != null) return http.Response('boom', failCode);
      final p = req.url.path;
      if (p.endsWith('status-counts')) {
        return http.Response(
          jsonEncode({
            'total': 400,
            'counts': [for (var i = 0; i < _statuses.length; i++) {'status': _statuses[i], 'count': 90 - i * 12}],
          }),
          200,
        );
      }
      if (p.contains('customers')) {
        return http.Response(
          jsonEncode({
            'data': empty
                ? []
                : [
                    for (var i = 0; i < 12; i++)
                      {
                        'customer_name': 'Customer number ${i + 1}',
                        'primary_contact': 'Pat Contact',
                        'phone': '(479) 555-01${10 + i}',
                        'email': 'c$i@example.com',
                        'service_location': '${100 + i} W Poplar St',
                        'city': 'Rogers',
                        'state': 'AR',
                        'total_jobs': i,
                      },
                  ],
            'total': empty ? 0 : 480,
            'totalPages': empty ? 1 : 20,
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode({
          'data': empty
              ? []
              : [
                  for (var i = 0; i < 12; i++)
                    {
                      'job_id': '${1099000000 + i * 137}',
                      'customer_name': 'Customer number ${i + 1}',
                      'location': '${1200 + i * 17} W Poplar St, Rogers, AR 72756',
                      'start_date': '2026-10-${(12 - (i % 11)).toString().padLeft(2, '0')}',
                      'total_revenue': (1200 + i * 837.5).toString(),
                      'status': _statuses[i % _statuses.length],
                      'techs_assigned': 'Brett Hall',
                    },
                ],
          'total': empty ? 0 : 400,
          'page': 1,
          'totalPages': 20,
        }),
        200,
      );
    });

Future<void> _shot(WidgetTester t, Widget screen, Size size, String name, http.Client client) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  await http.runWithClient(() async {
    await t.pumpWidget(RepaintBoundary(
      key: const ValueKey('shot'),
      child: MaterialApp(theme: ThemeData(useMaterial3: true, fontFamily: 'Segoe UI'), home: screen),
    ));
    await t.pumpAndSettle();
  }, () => client);
  expect(t.takeException(), isNull);
  await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('shots/$name.png'));
}

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', ['C:/Windows/Fonts/segoeui.ttf', 'C:/Windows/Fonts/segoeuib.ttf']);
  });

  for (final size in const [Size(1366, 720), Size(800, 700), Size(420, 760)]) {
    final w = size.width.toInt();
    testWidgets('customers $w', (t) async => _shot(t, const CustomersScreen(), size, 'office_customers_$w', _mock()));
    testWidgets('jobs $w', (t) async => _shot(t, const JobsScreen(), size, 'office_jobs_$w', _mock()));
    testWidgets('estimates $w', (t) async => _shot(t, const EstimatesScreen(), size, 'office_estimates_$w', _mock()));
    testWidgets('statuses $w', (t) async => _shot(t, const StatusesScreen(), size, 'office_statuses_$w', _mock()));
    testWidgets('invoices $w', (t) async => _shot(t, const InvoicesScreen(), size, 'office_invoices_$w', _mock()));
    testWidgets('site checks $w', (t) async => _shot(t, const SiteChecksScreen(), size, 'office_sitechecks_$w', _mock()));
    testWidgets('takeoffs $w', (t) async => _shot(t, const TakeoffsScreen(), size, 'office_takeoffs_$w', _mock()));
  }
  testWidgets('customers empty', (t) async => _shot(t, const CustomersScreen(), const Size(1366, 720), 'office_customers_empty', _mock(empty: true)));
  testWidgets('customers error', (t) async => _shot(t, const CustomersScreen(), const Size(1366, 720), 'office_customers_error', _mock(failCode: 500)));
  testWidgets('jobs empty', (t) async => _shot(t, const JobsScreen(), const Size(1366, 720), 'office_jobs_empty', _mock(empty: true)));
  testWidgets('jobs error', (t) async => _shot(t, const JobsScreen(), const Size(1366, 720), 'office_jobs_error', _mock(failCode: 500)));
}
