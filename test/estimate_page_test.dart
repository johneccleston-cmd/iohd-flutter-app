// The estimate page: same screen as a job's, at /estimates/<id> inside the nav shell. Checks the Estimates list and the
// dashboard estimate lists open it, jobs and estimates always land in their own section, and the page reads as an estimate.
// Run:  flutter test test/estimate_page_test.dart --update-goldens

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/estimates_screen.dart';
import 'package:iohd_desktop/job_detail_screen.dart';
import 'package:iohd_desktop/widgets/estimate_list_dialog.dart';
import 'package:iohd_desktop/widgets/main_navigation_shell.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

const _estimateId = '1092982173';
const _jobId = '1094565460';

Map<String, dynamic> _estimate() => {
      'job': {
        'job_id': _estimateId,
        'customer_name': 'Quality Building Systems Inc.',
        'contact_name': 'Chris Unruh',
        'status': 'Estimate Provided',
        'is_estimate': true,
        'category': 'Commercial Hard Bid',
        'location': '19378 AR-12, Gentry, AR 72734',
        'description': 'Four sectional doors and two rolling doors.',
        'opportunity_owner': 'Zac Clemens',
        'start_date': '2026-08-14',
        'total_revenue': '38250.00',
        'due_total': '38250.00',
        'raw_items': [
          {'name': 'Clopay Classic Steel | T42L | Complete Door', 'total': 4120.5, 'multiplier': 4, 'item_index': 1},
        ],
      },
      'customer': {'primary_contact': 'Chris Unruh', 'phone': '(479) 736-2125', 'email': 'chris@qualitymetalinc.com'},
      'becameJob': _jobId,
      'visits': [],
      'payments': [],
      'history': [
        {'old_status': 'Created', 'new_status': 'Estimate Requested', 'changed_at': '2026-08-14T14:00:00Z'},
      ],
    };

Map<String, dynamic> _job() => {
      'job': {
        'job_id': _jobId,
        'customer_name': 'Quality Building Systems Inc.',
        'status': 'Scheduled - Full Day',
        'is_estimate': false,
        'location': '19378 AR-12, Gentry, AR 72734',
        'start_date': '2026-10-07',
        'total_revenue': '38250.00',
        'due_total': '38250.00',
      },
      'fromEstimate': _estimateId,
      'visits': [],
      'payments': [],
      'history': [],
    };

/// Fake server: the list endpoints, plus a record per id (estimate / job). Everything else is empty.
http.Client _mock(List<String> log) => MockClient((req) async {
      final path = req.url.path;
      log.add('${req.method} $path');
      if (path == '/api/estimates/status-counts') {
        return http.Response(jsonEncode({'total': 1, 'counts': [{'status': 'Estimate Provided', 'count': 1}]}), 200);
      }
      if (path == '/api/estimates') {
        return http.Response(
          jsonEncode({
            'data': [
              {
                'job_id': _estimateId,
                'customer_name': 'Quality Building Systems Inc.',
                'location': '19378 AR-12, Gentry, AR 72734',
                'description': 'Four sectional doors',
                'start_date': '2026-08-14',
                'total_revenue': '38250.00',
                'status': 'Estimate Provided',
                'techs_assigned': '',
              },
            ],
            'total': 1,
            'page': 1,
            'totalPages': 1,
          }),
          200,
        );
      }
      if (path == '/api/dash/estimates-list') {
        return http.Response(
          jsonEncode({
            'items': [
              {'jobId': _estimateId, 'customerName': 'Quality Building Systems Inc.', 'status': 'Estimate Provided', 'location': '19378 AR-12', 'description': 'Doors', 'startDate': '2026-08-14', 'value': 38250, 'outcome': 'open'},
            ],
          }),
          200,
        );
      }
      if (path.endsWith('/notes-tasks')) return http.Response(jsonEncode({'notes': [], 'tasks': []}), 200);
      if (path.endsWith('/files')) return http.Response(jsonEncode({'enabled': true, 'files': []}), 200);
      if (path == '/api/jobs/$_estimateId') return http.Response(jsonEncode(_estimate()), 200);
      if (path == '/api/jobs/$_jobId') return http.Response(jsonEncode(_job()), 200);
      return http.Response('{}', 404);
    });

GoRouter _router({Widget? estimatesList, Widget? calendar}) => GoRouter(
      initialLocation: '/calendar',
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (context, state, shell) => MainNavigationShell(navigationShell: shell),
          branches: [
            for (var i = 0; i < 9; i++)
              StatefulShellBranch(routes: [
                if (i == 3)
                  GoRoute(path: '/estimates', builder: (_, _) => estimatesList ?? const SizedBox(), routes: [jobDetailRoute()])
                else if (i == 4)
                  GoRoute(path: '/jobs', builder: (_, _) => const SizedBox(), routes: [jobDetailRoute()])
                else if (i == 5)
                  GoRoute(path: '/calendar', builder: (_, _) => calendar ?? const SizedBox())
                else
                  GoRoute(path: '/other$i', builder: (_, _) => const SizedBox()),
              ]),
          ],
        ),
      ],
    );

String _where(GoRouter r) => r.routerDelegate.currentConfiguration.uri.path;

Future<void> _pump(WidgetTester t, GoRouter router, http.Client client) async {
  t.view.physicalSize = const Size(1500, 1000);
  t.view.devicePixelRatio = 1;
  await http.runWithClient(() async {
    await t.pumpWidget(RepaintBoundary(
      key: const ValueKey('shot'),
      child: MaterialApp.router(theme: ThemeData(useMaterial3: true, fontFamily: 'Segoe UI'), routerConfig: router),
    ));
    await t.pumpAndSettle();
  }, () => client);
}

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', ['C:/Windows/Fonts/segoeui.ttf', 'C:/Windows/Fonts/segoeuib.ttf']);
  });

  testWidgets('an estimate is shown in the estimates section even if it was opened from a /jobs link, and the pair links both ways', (t) async {
    final log = <String>[];
    final router = _router();
    await http.runWithClient(() async {
      await _pump(t, router, _mock(log));

      router.go('/jobs/$_estimateId'); // e.g. a calendar click: it doesn't know this number is an estimate
      await t.pumpAndSettle();
      expect(_where(router), '/estimates/$_estimateId', reason: 'moved to the Estimates section once loaded');
      expect(find.text('Estimate # $_estimateId'), findsOneWidget);
      expect(find.text('Estimate Info'), findsOneWidget);
      expect(find.text('Sales Data'), findsOneWidget); // an estimate's first tab mirrors Service Fusion's Sales Data block
      expect(find.text('Opportunity Owner'), findsOneWidget);
      expect(find.text('Start & End Dates'), findsNothing);
      expect(find.textContaining('Site Visits'), findsNothing); // an estimate has no visits to list
      expect(find.text('Zac Clemens'), findsWidgets); // sales owner (Details and Sales Data)
      await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('shots/estimate_page.png'));

      // "(Became job #...)" opens the job, which links back with "(Matching estimate #...)".
      await t.tap(find.text('#$_jobId'));
      await t.pumpAndSettle();
      expect(_where(router), '/jobs/$_jobId');
      expect(find.text('Job # $_jobId'), findsOneWidget);
      await t.tap(find.text('#$_estimateId'));
      await t.pumpAndSettle();
      expect(_where(router), '/estimates/$_estimateId');

      // And a job opened under /estimates/ is moved to /jobs/.
      router.go('/estimates/$_jobId');
      await t.pumpAndSettle();
      expect(_where(router), '/jobs/$_jobId');
      expect(t.takeException(), isNull);
    }, () => _mock(log));
  });

  testWidgets('an estimate gets estimate statuses in the status dropdown, not job statuses', (t) async {
    final router = _router();
    await _pump(t, router, _mock([]));
    await http.runWithClient(() async {
      router.go('/estimates/$_estimateId');
      await t.pumpAndSettle();
      await t.tap(find.text('Estimate Provided').first);
      await t.pumpAndSettle();
      expect(find.text('Estimate Won'), findsOneWidget);
      expect(find.text('Lost'), findsOneWidget);
      expect(find.text('Final Invoice Sent'), findsNothing);
      expect(find.text('Paid & Closed'), findsNothing);
    }, () => _mock([]));
  });

  testWidgets('clicking a row on the Estimates list opens that estimate at /estimates/<id>', (t) async {
    final log = <String>[];
    final router = _router(estimatesList: const EstimatesScreen());
    await _pump(t, router, _mock(log));
    await http.runWithClient(() async {
      router.go('/estimates');
      await t.pumpAndSettle();
      expect(find.text('Quality Building Systems Inc.'), findsWidgets);
      await t.tap(find.text('Quality Building Systems Inc.').first);
      await t.pumpAndSettle();
      expect(_where(router), '/estimates/$_estimateId');
      expect(find.text('Estimate # $_estimateId'), findsOneWidget);
      expect(t.takeException(), isNull);
    }, () => _mock(log));
  });

  testWidgets('clicking a row in a dashboard estimate list closes it and opens the estimate', (t) async {
    final router = _router(
      calendar: Builder(
        builder: (context) => TextButton(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => EstimateListDialog(
              year: 2026,
              heading: 'Open estimates',
              color: Colors.blue,
              icon: Icons.description_outlined,
              uri: Uri.parse('http://example.invalid/api/dash/estimates-list'),
            ),
          ),
          child: const Text('OPEN LIST'),
        ),
      ),
    );
    await _pump(t, router, _mock([]));
    await http.runWithClient(() async {
      await t.tap(find.text('OPEN LIST'));
      await t.pumpAndSettle();
      expect(find.text('Open estimates'), findsOneWidget);
      await t.tap(find.text('Quality Building Systems Inc.'));
      await t.pumpAndSettle();
      expect(find.text('Open estimates'), findsNothing, reason: 'the list closed');
      expect(_where(router), '/estimates/$_estimateId');
      expect(t.takeException(), isNull);
    }, () => _mock([]));
  });
}
