// Renders the Team screen in the states an audit needs (real window sizes, dirty draft, dialogs, history).
// Run:  flutter test test/team_audit_render_test.dart --update-goldens

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/team_admin_screen.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    final bytes = File(p).readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
  }
  await loader.load();
}

const _dashOff = ['dash_financial.view', 'dash_commissions.view', 'dash_technicians.view', 'dash_inventory.view', 'dash_jobs.view', 'dash_estimates.view', 'dash_sales.view', 'dash_collections.view'];

// Shapes and values copied from the live users table (2026-10-16), including its odd casing.
Map<String, dynamic> _u(int id, String name, String user, String role, String status,
        {num w = 0, bool ce = false, bool cb = false, bool lead = false, int? year, int tier = 0, bool pin = true, bool needs = false, List<String>? denied, int days = 0}) =>
    {
      'id': id, 'name': name, 'username': user, 'email': null, 'role': role, 'status': status,
      'year_joined': year, 'tenure_tier': tier, 'tool_allowance': '0.00', 'tech_weight': w.toStringAsFixed(2),
      'is_commission_eligible': ce, 'is_callback_eligible': cb, 'is_lead': lead, 'can_collect_payment': false,
      'five_star': false, 'no_recalls': false, 'access_denied': denied, 'inventory_strikes': 0, 'warehouse_strikes': 0,
      'tech_id': null, 'avatar_url': null, 'has_pin': pin, 'needs_pin_change': needs, 'version': '2026-10-16 12:00:00.$id',
      'work_days_90': days, 'last_work_date': null,
    };

final _users = [
  _u(39, 'Aaron Pendergrass', 'apendergrass', 'Technician', 'inactive', w: 1, year: 2026),
  // Andrew is intentionally not on commission (eligible off), and has real work days, so no warnings.
  _u(38, 'Andrew Johnson', 'AndrewJohnson', 'Technician', 'ACTIVE', w: 1, cb: true, year: 2026, days: 131),
  _u(37, 'Bella Hansberger', 'bhansberger', 'Office', 'ACTIVE', year: 2024, tier: 2, denied: _dashOff),
  _u(32, 'Brett Miller', 'bmiller', 'Technician', 'ACTIVE', w: 1, ce: true, cb: true, year: 2025, tier: 1, days: 41),
  _u(1028, 'Charlotte Miller', 'cmiller', 'Office', 'INACTIVE', w: 1, pin: false, needs: true),
  _u(33, 'Daniel Baty', 'gbaty', 'Lead Technician', 'ACTIVE', w: 1.5, ce: true, cb: true, lead: true, year: 2024, tier: 2, days: 52),
  _u(31, 'Dennis Gray', 'dgray', 'warehouse', 'ACTIVE', cb: true, year: 2024, tier: 2, denied: _dashOff.where((k) => k != 'dash_inventory.view').toList()),
  _u(34, 'Heather Vera', 'hvera', 'Office Manager', 'ACTIVE', year: 2022, tier: 3, denied: _dashOff),
  _u(29, 'John Eccleston', 'jeccleston', 'ADMIN', 'ACTIVE', year: 2025, tier: 1),
  _u(35, 'Nick Smith', 'nsmith', 'Lead Technician', 'ACTIVE', w: 1.5, ce: true, cb: true, lead: true, year: 2024, tier: 2, days: 48),
  _u(30, 'Ryan Schwartz', 'ryan', 'ADMIN', 'ACTIVE', lead: true, year: 2018, tier: 5),
  _u(40, 'Warehouse', 'warehouse1', 'Warehouse', 'ACTIVE', year: 2026),
  _u(36, 'Zac Clemens', 'zclemens', 'Sales Rep', 'ACTIVE', cb: true, year: 2024, tier: 2, denied: _dashOff),
];

final _history = [
  {'field': 'avatar_url', 'label': 'Photo', 'old_value': null, 'new_value': 'https://example.test/api/avatars/12', 'note': null, 'changed_by_name': 'John Eccleston', 'changed_at': '2026-10-15T15:00:00Z'},
  {'field': 'access_denied', 'label': 'Access', 'old_value': null, 'new_value': 'dash_collections.view,dash_commissions.view,dash_financial.view', 'note': null, 'changed_by_name': 'John Eccleston', 'changed_at': '2026-10-14T15:00:00Z'},
  {'field': 'status', 'label': 'Status', 'old_value': 'ACTIVE', 'new_value': 'Active', 'note': null, 'changed_by_name': 'John Eccleston', 'changed_at': '2026-10-12T15:00:00Z'},
  {'field': 'tech_weight', 'label': 'Commission weight', 'old_value': '1.00', 'new_value': '1.5', 'note': null, 'changed_by_name': 'Ryan Schwartz', 'changed_at': '2026-10-10T15:00:00Z'},
  {'field': 'name', 'label': 'Name', 'old_value': 'Danny Baty', 'new_value': 'Daniel Baty', 'note': 'Renamed on 214 work-day and ledger rows', 'changed_by_name': 'John Eccleston', 'changed_at': '2026-10-01T15:00:00Z'},
  {'field': 'pin', 'label': 'PIN', 'old_value': null, 'new_value': 'reset', 'note': 'Temporary PIN issued', 'changed_by_name': 'John Eccleston', 'changed_at': '2026-09-30T15:00:00Z'},
];

bool _failList = false;

http.Response _handle(http.Request r) {
  final p = r.url.path;
  if (p.endsWith('/history')) return http.Response(jsonEncode({'success': true, 'history': _history}), 200);
  if (p.endsWith('/reset-pin')) {
    return http.Response(jsonEncode({'success': true, 'tempPin': '048213', 'user': _users[5]}), 200);
  }
  if (_failList) return http.Response('<html>502 Bad Gateway</html>', 502);
  return http.Response(
    jsonEncode({
      'success': true,
      'roles': [
        for (final n in ['Technician', 'Lead Technician', 'Sales Rep', 'Warehouse', 'Office', 'Office Manager', 'Admin', 'Owner'])
          {'name': n, 'grantsAdmin': const {'Admin', 'Owner'}.contains(n)},
      ],
      'users': _users,
    }),
    200,
  );
}

Future<void> _pumpN(WidgetTester t, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _shot(WidgetTester tester, String name,
    {Size size = const Size(1440, 900), List<String> taps = const [], bool fail = false}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  _failList = fail;

  await http.runWithClient(() async {
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
        home: const TeamAdminScreen(),
      ),
    );
    await _pumpN(tester);
    for (final t in taps) {
      // "~Standard" means "the text that contains Standard" (avoids spelling out the × sign).
      final target = (t.startsWith('~')
              ? find.textContaining(t.substring(1), skipOffstage: false)
              : find.text(t, skipOffstage: false))
          .last;
      // Scroll it into view first, as a person would; the profile header is tall enough to push it below the fold.
      await tester.ensureVisible(target);
      await tester.pump();
      await tester.tap(target);
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

  testWidgets('first load 1440x900', (t) async => _shot(t, 'teamaudit_first'));
  testWidgets('daniel 1440x900', (t) async => _shot(t, 'teamaudit_daniel', taps: ['Daniel Baty']));
  testWidgets('daniel 1024x700', (t) async => _shot(t, 'teamaudit_1024', size: const Size(1024, 700), taps: ['Daniel Baty']));
  testWidgets('heather permissions', (t) async => _shot(t, 'teamaudit_heather', size: const Size(1440, 1600), taps: ['Heather Vera']));
  testWidgets('dirty + save bar', (t) async => _shot(t, 'teamaudit_dirty', taps: ['Daniel Baty', 'Commission settings', '~Standard']));
  testWidgets('review dialog', (t) async =>
      _shot(t, 'teamaudit_review', taps: ['Daniel Baty', 'Commission settings', '~Standard', 'Deactivate…', 'Save changes']));
  testWidgets('add employee dialog', (t) async => _shot(t, 'teamaudit_add', taps: ['Add employee']));
  testWidgets('pin dialog', (t) async => _shot(t, 'teamaudit_pin', taps: ['Daniel Baty', 'Reset PIN', 'Reset PIN']));
  testWidgets('history', (t) async => _shot(t, 'teamaudit_history', size: const Size(1440, 2000), taps: ['Daniel Baty', 'Change history']));
  testWidgets('change history starts collapsed with a count, and opens on tap', (t) async {
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1440, 2000);
    addTearDown(t.view.reset);
    await http.runWithClient(() async {
      await t.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
        home: const TeamAdminScreen(),
      ));
      await _pumpN(t);
      await t.tap(find.text('Daniel Baty').last);
      await _pumpN(t);
      expect(find.text('Change history'), findsOneWidget);
      expect(find.text('6'), findsOneWidget, reason: 'the number of recorded changes sits next to the title');
      expect(find.text('Permissions changed'), findsNothing, reason: 'the entries are hidden until it is opened');
      expect(find.text('Renamed on 214 work-day and ledger rows'), findsNothing);

      await t.tap(find.text('Change history'));
      await _pumpN(t);
      expect(find.text('Permissions changed'), findsOneWidget);
      expect(find.text('Renamed on 214 work-day and ledger rows'), findsOneWidget);
      expect(find.text('Photo added'), findsOneWidget, reason: 'a photo change is described in words, never as a link');
      expect(find.textContaining('example.test'), findsNothing);

      // Choosing someone else starts collapsed again.
      await t.tap(find.text('Heather Vera').last);
      await _pumpN(t);
      expect(find.text('Permissions changed'), findsNothing);
    }, () => MockClient((r) async => _handle(r)));
  });
  testWidgets('the photo is uploaded from the avatar, not typed as a URL', (t) async {
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1440, 1000);
    addTearDown(t.view.reset);
    await http.runWithClient(() async {
      await t.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
        home: const TeamAdminScreen(),
      ));
      await _pumpN(t);
      await t.tap(find.text('Daniel Baty').last);
      await _pumpN(t);
      expect(find.text('Photo URL'), findsNothing);
      expect(find.byTooltip('Upload a photo'), findsOneWidget, reason: 'a person with no photo gets a direct upload');
      expect(find.byIcon(Icons.photo_camera_outlined), findsOneWidget);
    }, () => MockClient((r) async => _handle(r)));
  });

  testWidgets('load error (502 html)', (t) async => _shot(t, 'teamaudit_error', fail: true));
}


