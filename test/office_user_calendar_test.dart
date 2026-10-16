// Signs in as a non-admin office user in the real app shell and checks the calendar paints (no build exceptions).

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/config/auth_session.dart';
import 'package:iohd_desktop/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    final bytes = File(p).readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
  }
  await loader.load();
}

String _role = 'Office';
bool _needsChange = false;
String _pin = '0482';
bool _admin = false;
List<String> _denied = [];

http.Response _handle(http.Request r) {
  final p = r.url.path;
  if (p.endsWith('/update_pin')) {
    _pin = (jsonDecode(r.body) as Map)['newPin'] as String;
    _needsChange = false;
    return http.Response(jsonEncode({'status': 'success'}), 200);
  }
  if (p.endsWith('/login') && _needsChange && r.headers['x-pin'] != _pin) {
    return http.Response(jsonEncode({'error': 'Invalid'}), 401);
  }
  if (p.endsWith('/login')) {
    final exp = DateTime.now().add(const Duration(days: 7)).millisecondsSinceEpoch;
    final payload = base64Url.encode(utf8.encode(jsonEncode({'exp': exp})));
    return http.Response(
      jsonEncode({
        'status': 'success', 'token': '$payload.sig', 'name': 'Pat Office', 'role': _role,
        'is_admin': _admin, 'needs_pin_change': _needsChange, 'access_denied': _denied,
      }),
      200,
    );
  }
  if (p.contains('/calendar/sync')) {
    final d = DateTime.now();
    final day = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return http.Response(
      jsonEncode({
        'events': [
          {'id': '1', 'customer': 'Farmington Fire Department', 'date': day, 'start_date': day, 'status': 'Scheduled', 'techs_assigned': 'Daniel Baty'}
        ]
      }),
      200,
    );
  }
  return http.Response(jsonEncode({'success': true}), 200);
}

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', [r'C:\Windows\Fonts\segoeui.ttf', r'C:\Windows\Fonts\segoeuib.ttf']);
    final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter';
    await _loadFont('MaterialIcons', ['$flutterRoot/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
  });

  Future<List<String>> signInAndSnap(WidgetTester t, String name) async {
    SharedPreferences.setMockInitialValues({});
    AuthSession.instance.logout();
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1440, 900);
    addTearDown(t.view.reset);
    final errs = <String>[];
    await http.runWithClient(() async {
      await t.pumpWidget(const IohdHubApp());
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      await t.enterText(find.byType(TextField).at(0), 'pat');
      await t.enterText(find.byType(TextField).at(1), '1234');
      await t.tap(find.text('Sign in'));
      for (var i = 0; i < 30; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      Object? e;
      while ((e = t.takeException()) != null) {
        errs.add(e.toString().split('\n').take(8).join('\n'));
      }
      await expectLater(find.byType(IohdHubApp), matchesGoldenFile('shots/$name.png'));
    }, () => MockClient((r) async => _handle(r)));
    return errs;
  }

  testWidgets('office user, no restrictions', (t) async {
    _role = 'Office';
    _admin = false;
    _denied = [];
    final errs = await signInAndSnap(t, 'officeuser_calendar');
    // ignore: avoid_print
    print('EXCEPTIONS(office): ${errs.length}\n${errs.join('\n---\n')}');
  });

  testWidgets('office user with dashboards switched off (like Heather)', (t) async {
    _role = 'Office Manager';
    _admin = false;
    _denied = ['dash_financial.view', 'dash_commissions.view', 'dash_technicians.view', 'dash_inventory.view', 'dash_jobs.view', 'dash_estimates.view', 'dash_sales.view', 'dash_collections.view'];
    final errs = await signInAndSnap(t, 'officeuser_restricted_calendar');
    // ignore: avoid_print
    print('EXCEPTIONS(restricted): ${errs.length}\n${errs.join('\n---\n')}');
  });

  testWidgets('temp PIN -> choose PIN -> calendar (the exact path)', (t) async {
    _role = 'Office';
    _admin = false;
    _denied = [];
    _needsChange = true;
    SharedPreferences.setMockInitialValues({});
    AuthSession.instance.logout();
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1440, 900);
    addTearDown(t.view.reset);
    final errs = <String>[];
    await http.runWithClient(() async {
      await t.pumpWidget(const IohdHubApp());
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      await t.enterText(find.byType(TextField).at(0), 'pat');
      await t.enterText(find.byType(TextField).at(1), '0482');
      await t.tap(find.text('Sign in'));
      for (var i = 0; i < 20; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Choose your PIN'), findsOneWidget);
      final fields = find.descendant(of: find.byType(Dialog), matching: find.byType(TextField));
      await t.enterText(fields.at(0), '1357');
      await t.enterText(fields.at(1), '1357');
      await t.pump(const Duration(milliseconds: 200));
      await t.tap(find.text('Save PIN and sign in'));
      for (var i = 0; i < 40; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      Object? e;
      while ((e = t.takeException()) != null) {
        errs.add(e.toString().split('\n').take(10).join('\n'));
      }
      // ignore: avoid_print
      print('EXCEPTIONS(temp-pin path): ${errs.length}\n${errs.join('\n---\n')}\nloggedIn=${AuthSession.instance.isLoggedIn}');
      await expectLater(find.byType(IohdHubApp), matchesGoldenFile('shots/temp_pin_path_calendar.png'));
    }, () => MockClient((r) async => _handle(r)));
    _needsChange = false;
  });

  testWidgets('admin', (t) async {
    _role = 'Admin';
    _admin = true;
    _denied = [];
    final errs = await signInAndSnap(t, 'admin_calendar');
    // ignore: avoid_print
    print('EXCEPTIONS(admin): ${errs.length}\n${errs.join('\n---\n')}');
  });
}
