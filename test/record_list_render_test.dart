// Renders the Jobs and Estimates lists with fake API data to test/shots/. Run:
//   flutter test test/record_list_render_test.dart --update-goldens

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/estimates_screen.dart';
import 'package:iohd_desktop/jobs_screen.dart';
import 'package:iohd_desktop/theme/app_theme.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

// Shaped like prod on 2026-11-04: Lennar jobs at $960 sharing one date, a long tech list, an unassigned job, a negative total.
const _jobs = [
  {'job_id': '1096189117', 'customer_name': 'Lennar', 'location': '542 Claverie St., Lowell, AR 72745', 'start_date': '2027-01-03T00:00:00Z', 'total_revenue': '960.00', 'status': 'Need To Schedule', 'techs_assigned': 'Bella Hansberger'},
  {'job_id': '1096250049', 'customer_name': 'Lennar', 'location': '820 Albarossa St, Lowell, AR 72745', 'start_date': '2027-01-03T00:00:00Z', 'total_revenue': '960.00', 'status': 'Need To Schedule', 'techs_assigned': 'Bella Hansberger'},
  {'job_id': '1099563432', 'customer_name': 'Walton Logistics Distribution Center With A Long Name', 'location': '4100 SW Regional Airport Blvd, Bentonville, AR 72712', 'start_date': '2026-11-03T00:00:00Z', 'total_revenue': '103382.40', 'status': 'Need To Order', 'techs_assigned': 'Brett Miller, Daniel Baty, Dennis Ray, Cody Smith'},
  {'job_id': '1099001122', 'customer_name': 'Smith Residence', 'location': '', 'start_date': '2026-11-02T00:00:00Z', 'total_revenue': '0', 'status': 'Scheduled - Full Day', 'techs_assigned': ''},
  {'job_id': '1098877665', 'customer_name': 'Rogers Dental', 'location': '12 Walnut St, Rogers, AR 72756', 'start_date': '2026-10-30T00:00:00Z', 'total_revenue': '-150.00', 'status': 'Final Invoice Sent', 'techs_assigned': 'Brett Miller'},
  {'job_id': '1098000001', 'customer_name': 'Hill Street Storage', 'location': '9 Hill St, Fayetteville, AR 72701', 'start_date': '2026-10-28T00:00:00Z', 'total_revenue': '4539.36', 'status': 'Paid & Closed', 'techs_assigned': 'Daniel Baty'},
  {'job_id': '1097000002', 'customer_name': 'Ridgeview HOA', 'location': '300 Ridgeview Dr, Springdale, AR 72762', 'start_date': '2026-10-27T00:00:00Z', 'total_revenue': '1225.00', 'status': 'Partially Complete', 'techs_assigned': 'Dennis Ray'},
  {'job_id': '1097000003', 'customer_name': 'JN3C Consulting', 'location': '77 Main St, Bentonville, AR 72712', 'start_date': '2026-10-27T00:00:00Z', 'total_revenue': '612.50', 'status': 'Delayed', 'techs_assigned': 'Brett Miller'},
];

const _counts = {
  'total': 11763,
  'counts': [
    {'status': 'Paid & Closed', 'count': 9977},
    {'status': 'Close Job', 'count': 776},
    {'status': 'Final Invoice Sent', 'count': 338},
    {'status': 'Cancelled', 'count': 249},
    {'status': 'Google Review Sent', 'count': 112},
    {'status': 'Write-Off', 'count': 106},
    {'status': 'Need To Schedule', 'count': 77},
    {'status': 'Scheduled - Full Day', 'count': 47},
    {'status': 'Complete', 'count': 18},
    {'status': 'Need Deposit', 'count': 14},
    {'status': 'Delayed', 'count': 10},
  ],
};

http.Client _mock({bool empty = false, int? failCode}) => MockClient((req) async {
      if (failCode != null) return http.Response('boom', failCode);
      if (req.url.path.endsWith('status-counts')) return http.Response(jsonEncode(_counts), 200);
      final estimates = req.url.path.contains('estimates');
      final rows = empty
          ? const <Map<String, Object?>>[]
          : [
              for (final r in _jobs)
                {...r, if (estimates) 'opportunity_owner': r['techs_assigned'] == '' ? null : 'Heather Vera', if (estimates) 'status': 'Estimate Provided'},
            ];
      return http.Response(
        jsonEncode({'data': rows, 'total': empty ? 0 : 11763, 'totalPages': empty ? 1 : 236, 'sorts': ['date', 'id', 'customer', 'amount', 'status']}),
        200,
      );
    });

final _theme = ThemeData(
  useMaterial3: true,
  fontFamily: 'Segoe UI',
  colorScheme: ColorScheme.fromSeed(seedColor: AppTheme.brandRed, primary: AppTheme.brandRed),
);

Future<void> _shot(WidgetTester t, Size size, String name, http.Client client, {bool estimates = false, double text = 1}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  if (text != 1) {
    t.platformDispatcher.textScaleFactorTestValue = text;
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
  }
  await http.runWithClient(() async {
    await t.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('shot'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _theme,
          home: estimates ? const EstimatesScreen() : const JobsScreen(),
        ),
      ),
    );
    await t.pumpAndSettle();
  }, () => client);
  expect(t.takeException(), isNull);
  await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('shots/$name.png'));
}

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', ['C:/Windows/Fonts/segoeui.ttf', 'C:/Windows/Fonts/segoeuib.ttf']);
    await _loadFont('MaterialIcons', ['C:/src/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
  });

  testWidgets('jobs at the window in the user\'s screenshot', (t) async {
    await _shot(t, const Size(1920, 860), 'records_jobs_1920', _mock());
    expect(find.text('Search customer, job # or address...'), findsOneWidget);
    expect(find.text('11,763 jobs'), findsOneWidget);
    expect(find.text(r'$103,382.40'), findsOneWidget);
    expect(find.text(r'-$150.00'), findsOneWidget);
    expect(find.text('Unassigned'), findsOneWidget);
    expect(find.text('No address'), findsOneWidget);
  });
  testWidgets('jobs on a laptop', (t) async => _shot(t, const Size(1366, 768), 'records_jobs_1366', _mock()));
  testWidgets('just too narrow for the sidebar', (t) async {
    await _shot(t, const Size(1100, 768), 'records_jobs_1100', _mock());
    expect(find.text('All statuses'), findsOneWidget);
    expect(find.text('Customer'), findsOneWidget); // still a table
  });
  testWidgets('stacked rows', (t) async {
    await _shot(t, const Size(700, 900), 'records_jobs_700', _mock());
    expect(find.text('Customer'), findsNothing);
    expect(find.text('Techs: Unassigned'), findsOneWidget);
  });
  testWidgets('phone width', (t) async => _shot(t, const Size(360, 780), 'records_jobs_360', _mock()));
  testWidgets('text at 130%', (t) async => _shot(t, const Size(1366, 800), 'records_jobs_text130', _mock(), text: 1.3));
  testWidgets('estimates', (t) async {
    await _shot(t, const Size(1500, 800), 'records_estimates', _mock(), estimates: true);
    expect(find.text('Sales owner'), findsOneWidget);
    expect(find.text('Value'), findsOneWidget);
  });
  testWidgets('empty', (t) async {
    await _shot(t, const Size(1366, 700), 'records_jobs_empty', _mock(empty: true));
    expect(find.text('No jobs yet'), findsOneWidget);
  });
  testWidgets('error', (t) async {
    await _shot(t, const Size(1366, 700), 'records_jobs_error', _mock(failCode: 500));
    expect(find.text('Try again'), findsOneWidget);
  });
}
