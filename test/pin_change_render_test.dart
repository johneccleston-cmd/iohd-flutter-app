// Drives the real sign-in screen against a fake server that answers "needs_pin_change", and checks
// that a temporary PIN never signs anyone in: it opens the "Choose your PIN" step, saves via /update_pin,
// then signs in with the new PIN.
// Run:  flutter test test/pin_change_render_test.dart --update-goldens

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/config/auth_session.dart';
import 'package:iohd_desktop/login_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    final bytes = File(p).readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
  }
  await loader.load();
}

final _calls = <String>[];
String _currentPin = '0482'; // what the fake server thinks the PIN is
bool _needsChange = true;
int _updateStatus = 200;

http.Response _handle(http.Request r) {
  _calls.add('${r.method} ${r.url.path} pin=${r.headers['x-pin']} ${r.body}');
  if (r.url.path.endsWith('/update_pin')) {
    if (_updateStatus != 200) {
      return http.Response(jsonEncode({'error': 'PIN must be 4 to 8 digits.'}), _updateStatus);
    }
    _currentPin = (jsonDecode(r.body) as Map)['newPin'] as String;
    _needsChange = false;
    return http.Response(jsonEncode({'status': 'success'}), 200);
  }
  if (r.headers['x-pin'] != _currentPin) return http.Response(jsonEncode({'error': 'Invalid'}), 401);
  final exp = DateTime.now().add(const Duration(days: 7)).millisecondsSinceEpoch;
  final payload = base64Url.encode(utf8.encode(jsonEncode({'exp': exp})));
  return http.Response(
    jsonEncode({
      'status': 'success',
      'token': '$payload.sig',
      'name': 'Pat Office',
      'role': 'Office',
      'is_admin': false,
      'needs_pin_change': _needsChange,
      'access_denied': [],
    }),
    200,
  );
}

Future<void> _pumpN(WidgetTester t, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
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

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AuthSession.instance.logout();
    _calls.clear();
    _currentPin = '0482';
    _needsChange = true;
    _updateStatus = 200;
  });

  Future<void> open(WidgetTester t) async {
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1280, 800);
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
      home: const LoginScreen(),
    ));
    await _pumpN(t);
    await t.enterText(find.byType(TextField).at(0), 'pat');
    await t.enterText(find.byType(TextField).at(1), '0482');
    await t.tap(find.text('Sign in'));
    await _pumpN(t, 15);
  }

  testWidgets('temporary PIN opens the choose-a-PIN step and does not sign in', (t) async {
    await http.runWithClient(() async {
      await open(t);
      expect(find.text('Choose your PIN'), findsOneWidget);
      expect(AuthSession.instance.isLoggedIn, isFalse, reason: 'a temporary PIN must not sign anyone in');
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/pinchange_dialog.png'));
    }, () => MockClient((r) async => _handle(r)));
  });

  testWidgets('mismatch and short PINs are blocked, then saving signs in with the new PIN', (t) async {
    await http.runWithClient(() async {
      await open(t);
      final fields = find.descendant(of: find.byType(Dialog), matching: find.byType(TextField));

      await t.enterText(fields.at(0), '12');
      await _pumpN(t, 3);
      expect(find.text('Use exactly 4 digits.'), findsOneWidget);

      await t.enterText(fields.at(0), '1357');
      await t.enterText(fields.at(1), '1358');
      await _pumpN(t, 3);
      expect(find.text("The PINs don't match yet."), findsOneWidget);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/pinchange_mismatch.png'));

      await t.enterText(fields.at(1), '1357');
      await _pumpN(t, 3);
      await t.tap(find.text('Save PIN and sign in'));
      await _pumpN(t, 20);

      expect(_calls.any((c) => c.startsWith('POST /update_pin pin=0482') && c.contains('1357')), isTrue);
      expect(AuthSession.instance.isLoggedIn, isTrue, reason: 'signs in once the new PIN is saved');
    }, () => MockClient((r) async => _handle(r)));
  });

  testWidgets('a server error keeps the dialog open and shows the message', (t) async {
    await http.runWithClient(() async {
      await open(t);
      _updateStatus = 400;
      final fields = find.descendant(of: find.byType(Dialog), matching: find.byType(TextField));
      await t.enterText(fields.at(0), '1357');
      await t.enterText(fields.at(1), '1357');
      await _pumpN(t, 3);
      await t.tap(find.text('Save PIN and sign in'));
      await _pumpN(t, 15);
      expect(find.text('PIN must be 4 to 8 digits.'), findsOneWidget);
      expect(find.text('Choose your PIN'), findsOneWidget);
      expect(AuthSession.instance.isLoggedIn, isFalse);
    }, () => MockClient((r) async => _handle(r)));
  });

  testWidgets('cancelling leaves them signed out with a hint', (t) async {
    await http.runWithClient(() async {
      await open(t);
      await t.tap(find.text('Cancel'));
      await _pumpN(t, 10);
      expect(find.text('Choose a new PIN to finish signing in.'), findsOneWidget);
      expect(AuthSession.instance.isLoggedIn, isFalse);
    }, () => MockClient((r) async => _handle(r)));
  });
}
