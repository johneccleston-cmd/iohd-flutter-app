// The Team screen's permissions card (2026-11-10): every page and action is a switch, nothing is held back for admins;
// a plain line per row says what its ticks allow; pay, profit, Team and Jarvis start off for someone never saved.
// Saves test/shots/team_permissions*.png.
// Run:  flutter test test/team_permissions_render_test.dart --update-goldens

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/config/access.dart';
import 'package:iohd_desktop/team_admin_screen.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

Map<String, dynamic> _user(int id, String name, String role, {List<String>? denied}) => {
      'id': id,
      'name': name,
      'username': name.split(' ').first.toLowerCase(),
      'role': role,
      'status': 'ACTIVE',
      'tech_weight': 0.0,
      'is_commission_eligible': false,
      'access_denied': denied,
      'has_pin': true,
      'work_days_90': 0,
      'version': '1',
    };

final List<http.Request> _sent = [];

http.Response _handle(http.Request r) {
  _sent.add(r);
  if (r.url.path.endsWith('/history')) return http.Response(jsonEncode({'success': true, 'history': []}), 200);
  if (r.method == 'PATCH') return http.Response(jsonEncode({'success': true, 'unchanged': true}), 200);
  return http.Response(
    jsonEncode({
      'success': true,
      'roles': [
        for (final n in ['Technician', 'Lead Technician', 'Sales Rep', 'Warehouse', 'Office', 'Office Manager', 'Admin', 'Owner'])
          {'name': n, 'grantsAdmin': const {'Admin', 'Owner'}.contains(n)},
      ],
      'users': [
        _user(2, 'Bella Hansberger', 'Office', denied: ['jobs.delete', 'statuses.create', 'statuses.update', 'statuses.delete', 'team.view', 'team.create', 'team.update']),
        _user(4, 'New Person', 'Office'), // never saved: the defaults
        _user(3, 'John Eccleston', 'ADMIN'),
      ],
    }),
    200,
  );
}

Future<void> _open(WidgetTester t, Size size, String who) async {
  t.view.devicePixelRatio = 1.0;
  t.view.physicalSize = size;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    RepaintBoundary(
      key: const ValueKey('shot'),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
        home: const TeamAdminScreen(),
      ),
    ),
  );
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
  await t.tap(find.text(who).first);
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Finder _checkbox(String semantics) => find.descendant(of: find.bySemanticsLabel(semantics), matching: find.byType(Checkbox));
bool _ticked(WidgetTester t, String semantics) => t.widget<Checkbox>(_checkbox(semantics)).value == true;

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', [r'C:\Windows\Fonts\segoeui.ttf', r'C:\Windows\Fonts\segoeuib.ttf', r'C:\Windows\Fonts\seguisb.ttf']);
    final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter';
    await _loadFont('MaterialIcons', ['$flutterRoot/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
  });
  setUp(_sent.clear);

  testWidgets('every switch is in the grid, nothing is locked, each row says what it allows', (t) async {
    await http.runWithClient(() async {
      await _open(t, const Size(1440, 5000), 'Bella Hansberger');
      expect(t.takeException(), isNull);

      expect(find.byType(Checkbox), findsNWidgets(kAllAccessKeys.length + 2), reason: 'plus the two tech-app switches');
      expect(find.text('Admins only'), findsNothing);
      expect(find.text('Only admins can'), findsNothing);
      for (final row in ['Team', 'Line Items & Costs', 'Ask Jarvis', 'Calls & Texts']) {
        expect(find.text(kAccessResources.values.firstWhere((r) => r.label == row).help), findsOneWidget, reason: row);
      }
      // Bella's saved switches read through.
      expect(_ticked(t, 'Jobs delete'), isFalse);
      expect(_ticked(t, 'Jobs update'), isTrue);
      expect(_ticked(t, 'Team view'), isFalse);
      expect(_ticked(t, 'Financial view'), isTrue, reason: 'saved lists keep what they say');

      await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('shots/team_permissions.png'));

      // Ticking Team > Update turns View on with it, and the save says this build knows every key.
      await t.tap(_checkbox('Team update'));
      await t.pump(const Duration(milliseconds: 300));
      expect(_ticked(t, 'Team update'), isTrue);
      expect(_ticked(t, 'Team view'), isTrue);
      Future<void> settle() async {
        for (var i = 0; i < 8; i++) {
          await t.pump(const Duration(milliseconds: 100));
        }
      }
      await settle(); // the save bar slides in
      await t.tap(find.text('Save changes').last);
      await settle();
      // Permissions are a sensitive change: a confirm step comes first.
      if (_sent.where((r) => r.method == 'PATCH').isEmpty) {
        await t.tap(find.text('Save changes').last);
        await settle();
      }
      final patch = _sent.where((r) => r.method == 'PATCH').single;
      final body = jsonDecode(patch.body) as Map<String, dynamic>;
      expect(body['accessVersion'], kAccessVersion);
      final denied = (body['changes']['access_denied'] as List).cast<String>();
      expect(denied, isNot(contains('team.update')));
      expect(denied, contains('jobs.delete'));
    }, () => MockClient((r) async => _handle(r)));
  });

  testWidgets('someone never saved starts with pay, profit, Team and Jarvis off', (t) async {
    await http.runWithClient(() async {
      await _open(t, const Size(1440, 5000), 'New Person');
      expect(t.takeException(), isNull);
      for (final off in ['Financial view', 'Payroll view', "KPI's view", 'Team view', 'Line Items & Costs view', 'Ask Jarvis view']) {
        expect(_ticked(t, off), isFalse, reason: off);
      }
      for (final on in ['Customers view', 'Jobs update', 'Sales view', 'Calls & Texts create']) {
        expect(_ticked(t, on), isTrue, reason: on);
      }
    }, () => MockClient((r) async => _handle(r)));
  });

  testWidgets('narrow window: the help lines wrap, nothing overflows', (t) async {
    await http.runWithClient(() async {
      await _open(t, const Size(900, 5600), 'Bella Hansberger');
      expect(t.takeException(), isNull);
      await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('shots/team_permissions_900.png'));
    }, () => MockClient((r) async => _handle(r)));
  });
}
