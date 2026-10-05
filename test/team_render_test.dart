// Renders the real Team screen with fake API data and saves screenshots to test/shots/.
// Run:  flutter test test/team_render_test.dart --update-goldens

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

Map<String, dynamic> _user(int id, String name, String role, {bool pay = false, List<String>? denied}) => {
      'id': id,
      'name': name,
      'username': name.split(' ').first.toLowerCase(),
      'role': role,
      'status': 'ACTIVE',
      'tech_weight': 1.0,
      'is_commission_eligible': true,
      'is_callback_eligible': true,
      'can_collect_payment': pay,
      'access_denied': denied,
      'has_pin': true,
      'work_days_90': 10,
      'version': '1',
    };

http.Response _handle(http.Request r) {
  if (r.url.path.endsWith('/history')) return http.Response(jsonEncode({'success': true, 'history': []}), 200);
  return http.Response(
    jsonEncode({
      'success': true,
      'roles': [
        for (final n in ['Technician', 'Lead Technician', 'Sales Rep', 'Warehouse', 'Office', 'Office Manager', 'Admin', 'Owner'])
          {'name': n, 'grantsAdmin': const {'Office Manager', 'Admin', 'Owner'}.contains(n)},
      ],
      'users': [
        _user(1, 'Daniel Baty', 'Lead Technician', pay: true),
        _user(2, 'Heather Vera', 'Office Manager', denied: ['dash_financial.view', 'dash_commissions.view', 'payments.view', 'payments.create', 'payments.update', 'payments.delete', 'jobs.delete', 'customers.delete']),
        _user(3, 'John Eccleston', 'ADMIN'),
        _user(4, 'Ryan Schwartz', 'ADMIN'),
      ],
    }),
    200,
  );
}

Future<void> _shot(WidgetTester tester, String name, {String? select}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1440, 2100);
  addTearDown(tester.view.reset);

  await http.runWithClient(() async {
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
        home: const TeamAdminScreen(),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    if (select != null) {
      await tester.tap(find.text(select).first);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
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

  testWidgets('tech with some dashboards', (t) async => _shot(t, 'team_tech'));
  testWidgets('heather (office manager)', (t) async => _shot(t, 'team_heather', select: 'Heather Vera'));
  testWidgets('admin has no permissions card', (t) async => _shot(t, 'team_admin', select: 'John Eccleston'));
}
