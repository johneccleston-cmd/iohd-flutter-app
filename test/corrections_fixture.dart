// Fake API for the Commission corrections screen, shaped like the backend: GET/POST /api/admin/commission/...
// (src/commission_corrections.js, loadJob) and GET /api/payroll/runs (src/payroll_runs.js). Shared by
// corrections_render_test.dart and corrections_behavior_test.dart.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/commission_corrections_screen.dart';

const farmId = '1099544037'; // locked, closing status, office fixes with history
const lennarId = '1094982451'; // started before go-live and commission paid: everything frozen
const smithId = '1094810505'; // locked but no longer closing, its close week already paid: Unlock is enabled
const multiId = '1096000111'; // worked across two pay weeks, the first of them already paid

Map<String, dynamic> corrDay(
  int id,
  String tech,
  String date, {
  num weight = 1,
  bool v = true,
  bool cb = false,
  String? status = 'Completed',
  Object? ov,
  Object? oc,
  Object? ow,
  bool before = false,
  String? payWeek,
  bool paid = false,
}) => {
  'id': id,
  'tech_name': tech,
  'work_date': date,
  'day_weight': weight.toString(),
  'is_verified': v,
  'is_callback': cb,
  'tech_status': status,
  'override_verified': ov,
  'override_callback': oc,
  'override_weight': ow,
  // loadJob replaces the visit's own week with the lock's (null when the job isn't locked).
  'pay_week': payWeek,
  'week_paid': paid,
  'beforeGoLive': before,
};

final corrJobs = [
  {'job_id': farmId, 'customer_name': 'Farmington Fire Department', 'status': 'Final Invoice Sent', 'start_date': '2026-10-13', 'is_commission_paid': false, 'locked': true},
  {'job_id': lennarId, 'customer_name': 'Lennar Homes of Missouri - Wentzville Meadows Phase 2 Lot 114', 'status': 'Close Job', 'start_date': '2026-08-17', 'is_commission_paid': true, 'locked': true},
  {'job_id': smithId, 'customer_name': 'Smith, Robert', 'status': 'On Hold', 'start_date': '2026-10-08', 'is_commission_paid': false, 'locked': true},
  {'job_id': multiId, 'customer_name': 'Trulove Construction', 'status': 'Close Job', 'start_date': '2026-10-08', 'is_commission_paid': false, 'locked': true},
];

/// The history the server keeps for Farmington: Christopher's day was re-weighted and un-verified by the office.
final farmHistory = <Map<String, dynamic>>[
  {'action': 'set_weight', 'target': 'Christopher Montgomery-Alvarez · 2026-10-15', 'old_value': '0.00', 'new_value': '1.5', 'reason': 'Visit type was blank in SF; he was there all day', 'changed_by_name': 'John Eccleston', 'changed_at': '2026-10-16T13:40:00Z'},
  {'action': 'set_verified', 'target': 'Christopher Montgomery-Alvarez · 2026-10-15', 'old_value': 'true', 'new_value': 'false', 'reason': 'Tapped completed by mistake', 'changed_by_name': 'John Eccleston', 'changed_at': '2026-10-16T13:39:00Z'},
];

Map<String, dynamic> corrDetail(String id, {List<Map<String, dynamic>>? history}) {
  if (id == lennarId) {
    return {
      'success': true,
      'goLiveDate': '2026-10-05',
      'job': {'job_id': id, 'customer_name': corrJobs[1]['customer_name'], 'status': 'Close Job', 'start_date': '2026-08-17', 'is_commission_paid': true, 'inScope': false, 'statusIsClosing': true, 'total_revenue': '18450.00', 'commission_projected': '0.00', 'commission_earned': '0.00'},
      'lock': {'locked_at': '2026-08-20T15:10:00Z', 'locked_status': 'Close Job', 'pay_week': '2026-08-17', 'week_paid': false},
      'days': [
        corrDay(11, 'Daniel Baty', '2026-08-17', before: true, payWeek: '2026-08-17'),
        corrDay(12, 'Ryan Schwartz', '2026-08-18', weight: 0.5, before: true, payWeek: '2026-08-17'),
      ],
      'corrections': <Map<String, dynamic>>[],
    };
  }
  if (id == smithId) {
    return {
      'success': true,
      'goLiveDate': '2026-10-05',
      'job': {'job_id': id, 'customer_name': 'Smith, Robert', 'status': 'On Hold', 'start_date': '2026-10-08', 'is_commission_paid': false, 'inScope': true, 'statusIsClosing': false, 'total_revenue': '1840.00', 'commission_projected': '210.00', 'commission_earned': '210.00'},
      'lock': {'locked_at': '2026-10-09T15:00:00Z', 'locked_status': 'Close Job', 'pay_week': '2026-10-05', 'week_paid': true},
      'days': [corrDay(31, 'Daniel Baty', '2026-10-08', payWeek: '2026-10-05', paid: true)],
      'corrections': <Map<String, dynamic>>[],
    };
  }
  if (id == multiId) {
    return {
      'success': true,
      'goLiveDate': '2026-10-05',
      'job': {'job_id': id, 'customer_name': 'Trulove Construction', 'status': 'Close Job', 'start_date': '2026-10-08', 'is_commission_paid': false, 'inScope': true, 'statusIsClosing': true, 'total_revenue': '9612.40', 'commission_projected': '1153.49', 'commission_earned': '1153.49'},
      'lock': {'locked_at': '2026-10-15T21:00:00Z', 'locked_status': 'Close Job', 'pay_week': '2026-10-12', 'week_paid': false},
      'days': [
        corrDay(41, 'Brett Miller', '2026-10-08', payWeek: '2026-10-12'),
        corrDay(42, 'Nick Smith', '2026-10-09', payWeek: '2026-10-12'),
        corrDay(43, 'Brett Miller', '2026-10-14', weight: 0.5, status: 'Partially Completed', payWeek: '2026-10-12'),
      ],
      'corrections': <Map<String, dynamic>>[],
    };
  }
  return {
    'success': true,
    'goLiveDate': '2026-10-05',
    'job': {'job_id': id, 'customer_name': 'Farmington Fire Department', 'status': 'Final Invoice Sent', 'start_date': '2026-10-13', 'is_commission_paid': false, 'inScope': true, 'statusIsClosing': true, 'total_revenue': '271.92', 'commission_projected': '52.80', 'commission_earned': '52.80'},
    'lock': {'locked_at': '2026-10-15T14:02:00Z', 'locked_status': 'Final Invoice Sent', 'pay_week': '2026-10-12', 'week_paid': false},
    'days': [
      corrDay(27879767, 'Daniel Baty', '2026-10-14', weight: 0, payWeek: '2026-10-12'),
      corrDay(27879768, 'Christopher Montgomery-Alvarez', '2026-10-15', weight: 1.5, v: false, status: 'Partially Completed', ov: false, ow: '1.5', payWeek: '2026-10-12'),
      corrDay(27879769, 'Ryan Schwartz', '2026-10-16', weight: 0, cb: true, status: null, oc: true, payWeek: '2026-10-12'),
    ],
    'corrections': history ?? farmHistory,
  };
}

final corrRecent = [
  {'job_id': farmId, 'customer_name': 'Farmington Fire Department', 'action': 'set_weight', 'target': 'Christopher Montgomery-Alvarez · 2026-10-15', 'old_value': '0.00', 'new_value': '1.5', 'reason': 'Visit type was blank in SF; he was there all day', 'changed_by_name': 'John Eccleston', 'changed_at': '2026-10-16T13:40:00Z'},
  {'job_id': farmId, 'customer_name': 'Farmington Fire Department', 'action': 'set_verified', 'target': 'Christopher Montgomery-Alvarez · 2026-10-15', 'old_value': 'true', 'new_value': 'false', 'reason': 'Tapped completed by mistake', 'changed_by_name': 'John Eccleston', 'changed_at': '2026-10-16T13:39:00Z'},
  {'job_id': '1093000001', 'customer_name': 'Jones', 'action': 'unlock_job', 'target': 'locked 2026-10-08 as "Close Job"', 'old_value': 'locked, earned \$96.00', 'new_value': 'unlocked (status now "Check on Payment")', 'reason': 'Closed by accident, should have been Check on Payment while waiting on the second half of the deposit', 'changed_by_name': 'Heather Vera', 'changed_at': '2026-10-09T09:15:00Z'},
];

/// One finalized run (the week of Oct 5, as in production on 2026-10-21) and one voided run, which pays nothing.
final corrRuns = [
  {'id': 9, 'week_start': '2026-10-05', 'week_end': '2026-10-11', 'run_type': 'regular', 'status': 'finalized', 'run_by_name': 'Heather Vera', 'created_at': '2026-10-13T15:00:00Z'},
  {'id': 7, 'week_start': '2026-10-12', 'week_end': '2026-10-18', 'run_type': 'regular', 'status': 'voided', 'run_by_name': 'Heather Vera', 'created_at': '2026-10-20T15:00:00Z'},
];

/// A fake backend. Override a piece of it per test; [posts] records every POST body.
class FakeCorrApi {
  int runsStatus = 200;
  int detailStatus = 200;
  List<Map<String, dynamic>>? farmHistoryOverride;

  /// When set, GET /jobs/:id waits for it (used to hold a reload in flight).
  Completer<void>? detailGate;

  /// When set, POSTs wait for it.
  Completer<void>? postGate;
  int postStatus = 200;
  String postError = 'Failed to save the correction.';

  final posts = <Map<String, dynamic>>[];
  final paths = <String>[];

  Future<http.Response> handle(http.Request r) async {
    final p = r.url.path;
    paths.add('${r.method} $p${r.url.hasQuery ? '?${r.url.query}' : ''}');
    if (p.endsWith('/api/payroll/runs')) {
      return runsStatus == 200
          ? http.Response(jsonEncode({'success': true, 'runs': corrRuns}), 200)
          : http.Response(jsonEncode({'success': false, 'error': 'Payroll run history failed.'}), runsStatus);
    }
    if (p.endsWith('/corrections')) return http.Response(jsonEncode({'success': true, 'corrections': corrRecent}), 200);
    if (p.endsWith('/jobs')) {
      final q = (r.url.queryParameters['q'] ?? '').toLowerCase();
      final jobs = q == 'zzz' ? [] : corrJobs;
      return http.Response(jsonEncode({'success': true, 'jobs': jobs}), 200);
    }
    if (r.method == 'POST') {
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      posts.add(body);
      if (postGate != null) await postGate!.future;
      if (postStatus != 200) return http.Response(jsonEncode({'success': false, 'error': postError}), postStatus);
      final id = p.split('/')[p.split('/').length - 2];
      return http.Response(jsonEncode(_afterSave(id, body)), 200);
    }
    final gate = detailGate;
    if (gate != null) await gate.future;
    if (detailStatus != 200) {
      return http.Response(jsonEncode({'success': false, 'error': 'Failed to load the job.'}), detailStatus);
    }
    final id = p.split('/').last;
    return http.Response(
      jsonEncode(corrDetail(id, history: id == farmId ? farmHistoryOverride : null)),
      200,
    );
  }

  /// What the server sends back after a day fix: the job reloaded with the new values (the real route calls loadJob).
  Map<String, dynamic> _afterSave(String id, Map<String, dynamic> body) {
    final d = corrDetail(id);
    final days = List<Map<String, dynamic>>.from(d['days'] as List);
    for (final day in days) {
      if (day['id'] != body['dayId']) continue;
      if (body.containsKey('verified')) {
        day['override_verified'] = body['verified'];
        if (body['verified'] != null) day['is_verified'] = body['verified'];
      }
      if (body.containsKey('callback')) {
        day['override_callback'] = body['callback'];
        if (body['callback'] != null) day['is_callback'] = body['callback'];
      }
      if (body.containsKey('weight')) {
        day['override_weight'] = body['weight']?.toString();
        if (body['weight'] != null) day['day_weight'] = body['weight'].toString();
      }
    }
    return {...d, 'days': days};
  }
}

Future<void> loadCorrFonts() async {
  Future<void> load(String family, List<String> paths) async {
    final loader = FontLoader(family);
    for (final p in paths) {
      final bytes = File(p).readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
    }
    await loader.load();
  }

  await load('Segoe UI', [r'C:\Windows\Fonts\segoeui.ttf', r'C:\Windows\Fonts\segoeuib.ttf', r'C:\Windows\Fonts\seguisb.ttf']);
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter';
  await load('MaterialIcons', ['$flutterRoot/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
}

Future<void> pumpN(WidgetTester t, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// Pumps the real screen at [size] with [api] behind every request. Run the rest of the test inside [body].
Future<void> withCorrections(
  WidgetTester t,
  FakeCorrApi api,
  Future<void> Function() body, {
  Size size = const Size(1440, 900),
  double textScale = 1,
  bool reduceMotion = false,
}) async {
  t.view.devicePixelRatio = 1.0;
  t.view.physicalSize = size;
  addTearDown(t.view.reset);
  await http.runWithClient(() async {
    await t.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale), disableAnimations: reduceMotion),
          child: child!,
        ),
        home: const Scaffold(body: CommissionCorrectionsScreen()),
      ),
    );
    await pumpN(t);
    await body();
  }, () => MockClient(api.handle));
}

/// Types [q] in the search box and opens the job named [customer].
Future<void> openJob(WidgetTester t, String customer, {String q = 'farm'}) async {
  await t.enterText(find.byType(TextField).first, q);
  await pumpN(t);
  await t.tap(find.text(customer).first);
  await pumpN(t);
}
