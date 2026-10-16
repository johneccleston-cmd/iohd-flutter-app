// Renders the real Commission corrections screen with fake API data and saves screenshots to test/shots/.
// Run:  flutter test test/corrections_render_test.dart --update-goldens

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/commission_corrections_screen.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    final bytes = File(p).readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
  }
  await loader.load();
}

Map<String, dynamic> _day(int id, String tech, String date,
        {num weight = 1, bool v = true, bool cb = false, String? status = 'Completed', Object? ov, Object? oc, Object? ow, bool before = false, bool paid = false}) =>
    {
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
      'pay_week': date,
      'week_paid': paid,
      'beforeGoLive': before,
    };

final _jobs = [
  {'job_id': '1099544037', 'customer_name': 'Farmington Fire Department', 'status': 'Final Invoice Sent', 'start_date': '2026-10-13', 'is_commission_paid': false, 'locked': true},
  {'job_id': '1094982451', 'customer_name': 'Lennar Homes of Missouri - Wentzville Meadows Phase 2 Lot 114', 'status': 'Close Job', 'start_date': '2026-08-17', 'is_commission_paid': true, 'locked': true},
  {'job_id': '1094810505', 'customer_name': 'Smith, Robert', 'status': 'Cancelled', 'start_date': '2026-08-13', 'is_commission_paid': false, 'locked': false},
];

Map<String, dynamic> _detail(String id) {
  if (id == '1094982451') {
    return {
      'success': true,
      'goLiveDate': '2026-10-05',
      'job': {'job_id': id, 'customer_name': _jobs[1]['customer_name'], 'status': 'Close Job', 'start_date': '2026-08-17', 'is_commission_paid': true, 'inScope': false, 'statusIsClosing': true},
      'lock': {'locked_at': '2026-08-20T15:10:00Z', 'locked_status': 'Close Job', 'pay_week': '2026-08-17', 'week_paid': true},
      'days': [
        _day(11, 'Daniel Baty', '2026-08-17', before: true, paid: true),
        _day(12, 'Ryan Schwartz', '2026-08-18', weight: 0.5, before: true, paid: true),
      ],
      'corrections': [],
    };
  }
  if (id == '1094810505') {
    // Locked but no longer in a closing status, so Unlock is enabled.
    return {
      'success': true,
      'goLiveDate': '2026-10-05',
      'job': {'job_id': id, 'customer_name': 'Smith, Robert', 'status': 'On Hold', 'start_date': '2026-10-08', 'is_commission_paid': false, 'inScope': true, 'statusIsClosing': false, 'total_revenue': '1840.00', 'commission_projected': '210.00', 'commission_earned': '210.00'},
      'lock': {'locked_at': '2026-10-09T15:00:00Z', 'locked_status': 'Close Job', 'pay_week': '2026-10-05', 'week_paid': true},
      'days': [_day(31, 'Daniel Baty', '2026-10-08')],
      'corrections': [],
    };
  }
  return {
    'success': true,
    'goLiveDate': '2026-10-05',
    'job': {'job_id': id, 'customer_name': 'Farmington Fire Department', 'status': 'Final Invoice Sent', 'start_date': '2026-10-13', 'is_commission_paid': false, 'inScope': true, 'statusIsClosing': true, 'total_revenue': '271.92', 'commission_projected': '52.80', 'commission_earned': '52.80'},
    'lock': {'locked_at': '2026-10-15T14:02:00Z', 'locked_status': 'Final Invoice Sent', 'pay_week': '2026-10-12', 'week_paid': false},
    'days': [
      _day(27879767, 'Daniel Baty', '2026-10-14', weight: 0),
      _day(27879768, 'Christopher Montgomery-Alvarez', '2026-10-15', weight: 1.5, v: false, status: 'Partially Completed', ov: false, ow: '1.5'),
      _day(27879769, 'Ryan Schwartz', '2026-10-16', weight: 0, cb: true, status: null, oc: true),
    ],
    'corrections': [
      {'action': 'set_weight', 'target': 'Christopher Montgomery-Alvarez · 2026-10-15', 'old_value': '0.00', 'new_value': '1.5', 'reason': 'Visit type was blank in SF; he was there all day', 'changed_by_name': 'John Eccleston', 'changed_at': '2026-10-16T13:40:00Z'},
      {'action': 'set_verified', 'target': 'Christopher Montgomery-Alvarez · 2026-10-15', 'old_value': 'true', 'new_value': 'false', 'reason': 'Tapped completed by mistake', 'changed_by_name': 'John Eccleston', 'changed_at': '2026-10-16T13:39:00Z'},
    ],
  };
}

http.Response _handle(http.Request r) {
  final p = r.url.path;
  if (p.endsWith('/corrections')) {
    return http.Response(jsonEncode({
      'success': true,
      'corrections': [
        {'job_id': '1099544037', 'customer_name': 'Farmington Fire Department', 'action': 'set_weight', 'reason': 'Visit type was blank in SF; he was there all day', 'changed_by_name': 'John Eccleston', 'changed_at': '2026-10-16T13:40:00Z'},
        {'job_id': '1099544037', 'customer_name': 'Farmington Fire Department', 'action': 'set_verified', 'reason': 'Tapped completed by mistake', 'changed_by_name': 'John Eccleston', 'changed_at': '2026-10-16T13:39:00Z'},
        {'job_id': '1093000001', 'customer_name': 'Jones', 'action': 'unlock_job', 'reason': 'Closed by accident, should have been Check on Payment while waiting on the second half of the deposit', 'changed_by_name': 'Heather Vera', 'changed_at': '2026-10-09T09:15:00Z'},
      ],
    }), 200);
  }
  if (p.endsWith('/jobs')) {
    final q = r.url.queryParameters['q'] ?? '';
    return http.Response(jsonEncode({'success': true, 'jobs': q == 'zzz' ? [] : _jobs}), 200);
  }
  final id = p.split('/').last;
  return http.Response(jsonEncode(_detail(id)), 200);
}

Future<void> _pumpN(WidgetTester t, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _shot(WidgetTester tester, String name,
    {Size size = const Size(1440, 900), String? search, String? open, String? tap, String? tapLast, String? then}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);

  await http.runWithClient(() async {
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
        home: const Scaffold(body: CommissionCorrectionsScreen()),
      ),
    );
    await _pumpN(tester);
    if (search != null) {
      await tester.enterText(find.byType(TextField).first, search);
      await _pumpN(tester);
    }
    if (open != null) {
      await tester.tap(find.text(open).first);
      await _pumpN(tester);
    }
    if (tap != null) {
      await tester.tap(find.text(tap).first);
      await _pumpN(tester);
    }
    if (tapLast != null) {
      await tester.tap(find.text(tapLast).last);
      await _pumpN(tester);
    }
    if (then != null) {
      await tester.tap(find.text(then).last);
      await _pumpN(tester);
    }
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/$name.png'));
  }, () => MockClient((r) async => _handle(r)));
}

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', [
      r'C:\Windows\Fonts\segoeui.ttf',
      r'C:\Windows\Fonts\segoeuib.ttf',
      r'C:\Windows\Fonts\seguisb.ttf',
    ]);
    final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter';
    await _loadFont('MaterialIcons', ['$flutterRoot/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
  });

  testWidgets('empty + recent', (t) async => _shot(t, 'corr_empty'));
  testWidgets('search results', (t) async => _shot(t, 'corr_search', search: 'farm'));
  testWidgets('locked job detail', (t) async => _shot(t, 'corr_detail', search: 'farm', open: 'Farmington Fire Department'));
  testWidgets('paid job detail', (t) async =>
      _shot(t, 'corr_paid', search: 'len', open: 'Lennar Homes of Missouri - Wentzville Meadows Phase 2 Lot 114'));
  testWidgets('detail 1280x600', (t) async =>
      _shot(t, 'corr_detail_1280', size: const Size(1280, 600), search: 'farm', open: 'Farmington Fire Department'));
  testWidgets('detail 1024', (t) async =>
      _shot(t, 'corr_detail_1024', size: const Size(1024, 700), search: 'farm', open: 'Farmington Fire Department'));
  testWidgets('fix dialog', (t) async =>
      _shot(t, 'corr_fix', search: 'farm', open: 'Farmington Fire Department', tap: 'Fix'));
  testWidgets('unlock dialog (job not closing)', (t) async =>
      _shot(t, 'corr_unlock', search: 'farm', open: 'Smith, Robert', tap: 'Unlock'));
  testWidgets('fix dialog: un-flag a callback', (t) async => _shot(t, 'corr_fix_callback',
      search: 'farm', open: 'Farmington Fire Department', tapLast: 'Fix', then: 'Not callback'));
  testWidgets('no matches', (t) async => _shot(t, 'corr_nomatch', search: 'zzz'));
  testWidgets('narrow detail', (t) async =>
      _shot(t, 'corr_narrow', size: const Size(700, 800), search: 'farm', open: 'Farmington Fire Department'));
  testWidgets('narrow search', (t) async => _shot(t, 'corr_narrow_search', size: const Size(700, 800), search: 'farm'));
  _reasonTests();
}

// The fix dialog asks for a reason from a list; "Other" also needs a note. Both end up in the one `reason` the
// server stores.
void _reasonTests() {
  testWidgets('fix dialog: a reason is required, Other also needs a note, and both reach the server', (t) async {
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1440, 1100);
    addTearDown(t.view.reset);
    Map<String, dynamic>? saved;

    await http.runWithClient(() async {
      await t.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
        home: const Scaffold(body: CommissionCorrectionsScreen()),
      ));
      await _pumpN(t);
      await t.enterText(find.byType(TextField).first, 'farm');
      await _pumpN(t);
      await t.tap(find.text('Farmington Fire Department').first);
      await _pumpN(t);
      await t.tap(find.text('Fix').first);
      await _pumpN(t);

      FilledButton saveButton() => t.widget<FilledButton>(
        find.ancestor(of: find.text('Save correction'), matching: find.bySubtype<FilledButton>()).first,
      );
      await t.tap(find.text('Not verified').last); // a real change, so only the reason is missing
      await _pumpN(t, 3);
      expect(saveButton().onPressed, isNull, reason: 'no reason picked yet');
      expect(find.text('Tech did not mark complete'), findsOneWidget);
      expect(find.text('Tech marked complete by mistake'), findsOneWidget);
      expect(find.text('Office error'), findsOneWidget);
      expect(find.text('Other (note required)'), findsOneWidget);

      await t.tap(find.text('Office error'));
      await _pumpN(t, 3);
      expect(saveButton().onPressed, isNotNull, reason: 'a listed reason needs no note');

      await t.tap(find.text('Other (note required)'));
      await _pumpN(t, 3);
      expect(saveButton().onPressed, isNull, reason: 'Other without a note');
      await t.enterText(find.byWidgetPredicate((w) => w is TextField && w.maxLength == 900), 'abc');
      await _pumpN(t, 3);
      expect(saveButton().onPressed, isNull, reason: 'a note under 5 characters is not a note');
      await t.enterText(find.byWidgetPredicate((w) => w is TextField && w.maxLength == 900), 'Gate was locked');
      await _pumpN(t, 3);
      expect(saveButton().onPressed, isNotNull);

      await t.tap(find.text('Save correction'));
      await _pumpN(t);
    }, () => MockClient((r) async {
      if (r.method == 'POST' && r.url.path.endsWith('/day')) {
        saved = jsonDecode(r.body) as Map<String, dynamic>;
        return http.Response(jsonEncode(_detail('1099544037')), 200);
      }
      return _handle(r);
    }));

    expect(saved, isNotNull, reason: 'the correction was posted');
    expect(saved!['reason'], 'Other: Gate was locked');
    expect(saved!['verified'], false);
  });

  testWidgets('fix dialog: a listed reason with no note is sent as just the reason', (t) async {
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1440, 1100);
    addTearDown(t.view.reset);
    Map<String, dynamic>? saved;

    await http.runWithClient(() async {
      await t.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
        home: const Scaffold(body: CommissionCorrectionsScreen()),
      ));
      await _pumpN(t);
      await t.enterText(find.byType(TextField).first, 'farm');
      await _pumpN(t);
      await t.tap(find.text('Farmington Fire Department').first);
      await _pumpN(t);
      await t.tap(find.text('Fix').first);
      await _pumpN(t);
      await t.tap(find.text('Not verified').last);
      await t.tap(find.text('Tech did not mark complete'));
      await _pumpN(t, 3);
      await t.tap(find.text('Save correction'));
      await _pumpN(t);
    }, () => MockClient((r) async {
      if (r.method == 'POST' && r.url.path.endsWith('/day')) {
        saved = jsonDecode(r.body) as Map<String, dynamic>;
        return http.Response(jsonEncode(_detail('1099544037')), 200);
      }
      return _handle(r);
    }));

    expect(saved!['reason'], 'Tech did not mark complete');
  });
}
