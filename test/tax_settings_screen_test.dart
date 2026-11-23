// Inventory > Tax, Discounts & Fees (2026-11-20): loads, edits and saves the panel's presets; an older server or a
// person without the Update switch gets a read-only page that says why.
//   flutter test test/tax_settings_screen_test.dart

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/config/auth_session.dart';
import 'package:iohd_desktop/services/tax_settings_api.dart';
import 'package:iohd_desktop/tax_settings_screen.dart';
import 'package:iohd_desktop/utils/charge_presets.dart';
import 'package:iohd_desktop/widgets/dashboard_data.dart';

class _Server {
  bool missing = false; // an older server: no /api/tax-settings
  bool admin = true;
  List<String> denied = const [];
  Map<String, dynamic>? saved;
  final puts = <Map<String, dynamic>>[];

  Future<http.Response> handle(http.Request req) async {
    if (req.url.path == '/login') {
      final exp = DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch;
      final token = '${base64Url.encode(utf8.encode(json.encode({'exp': exp})))}.sig';
      return http.Response(json.encode({'token': token, 'name': 'Bella', 'role': 'Office', 'is_admin': admin, 'denied': denied}), 200);
    }
    if (req.url.path == '/api/tax-settings') {
      if (missing) return http.Response('Cannot GET', 404);
      if (req.method == 'GET') {
        return http.Response(json.encode({'settings': saved, 'version': saved == null ? null : 1, 'updatedBy': null, 'updatedAt': null}), 200);
      }
      final body = json.decode(req.body) as Map<String, dynamic>;
      puts.add(body);
      saved = body['settings'] as Map<String, dynamic>;
      return http.Response(json.encode({'settings': saved, 'version': (body['version'] as int? ?? 0) + 1, 'updatedBy': 'Bella', 'updatedAt': '2026-11-20T16:00:00Z'}), 200);
    }
    return http.Response('{}', 200);
  }
}

Future<void> _show(WidgetTester t, _Server s, Future<void> Function() body) async {
  t.view.physicalSize = const Size(1440, 1400);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  DashClock.debugOverride = () => DateTime(2026, 11, 20, 10);
  addTearDown(() => DashClock.debugOverride = null);
  TaxSettingsStore.instance.debugReset();
  await http.runWithClient(() async {
    AuthSession.instance.logout();
    await AuthSession.instance.login('bella', '1234');
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
        home: const Scaffold(body: TaxSettingsScreen()),
      ),
    );
    await t.pumpAndSettle();
    await body();
  }, () => MockClient(s.handle));
}

void main() {
  tearDown(() {
    AuthSession.instance.logout();
    TaxSettingsStore.instance.debugReset();
  });

  testWidgets('nothing saved yet: the built-in discounts and fees, editable; Save sends them and the panel uses them', (t) async {
    final s = _Server();
    await _show(t, s, () async {
      expect(find.text('TAX, DISCOUNTS & FEES'), findsOneWidget, reason: 'the standard ribbon with the page\'s title');
      expect(find.text('Discounts  8', findRichText: true), findsOneWidget, reason: 'its heading counts them');
      expect(find.text('Fees  1', findRichText: true), findsOneWidget);
      expect(find.text('Out-of-state tax'), findsOneWidget);
      expect(find.text('Arkansas sales tax'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Clopay Master Authorized Dealer Discount'), findsOneWidget);
      expect(find.text('Save'), findsNothing, reason: 'nothing changed yet');
      // The Clopay discount starts at 20%.
      final clopay = find.byKey(const ValueKey('preset-d-clopay'));
      await t.enterText(find.descendant(of: clopay, matching: find.byType(TextField)).at(1), '20');
      await t.pumpAndSettle();
      expect(find.text('Save'), findsOneWidget);
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(s.puts, hasLength(1));
      expect(s.puts.single['version'], isNull, reason: 'the first save');
      final sent = (s.puts.single['settings']['presets'] as List).firstWhere((p) => p['id'] == 'd-clopay');
      expect(sent['value'], 20);
      expect(find.textContaining('Saved.'), findsOneWidget);
      expect(TaxSettingsStore.instance.value.presets.firstWhere((p) => p.id == 'd-clopay').value, 20, reason: 'the panel reads it from now on');
    });
  });

  testWidgets('add a fee; a fee with no name is refused before anything is sent', (t) async {
    final s = _Server();
    await _show(t, s, () async {
      await t.tap(find.byKey(const ValueKey('add-fee')));
      await t.pumpAndSettle();
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(find.text('Every fee needs a name.'), findsOneWidget);
      expect(s.puts, isEmpty);
    });
  });

  testWidgets('an older server: the built-in list, read-only, and why', (t) async {
    final s = _Server()..missing = true;
    await _show(t, s, () async {
      expect(find.textContaining('Showing the built-in list'), findsOneWidget);
      expect(find.byKey(const ValueKey('add-discount')), findsNothing);
      expect(find.text('Save'), findsNothing);
      expect(TaxSettingsStore.instance.value.presets, kBuiltInPresets);
    });
  });

  testWidgets('without the Update switch: read-only, and it says which switch', (t) async {
    final s = _Server()
      ..admin = false
      ..denied = const ['tax_settings.update'];
    await _show(t, s, () async {
      expect(find.textContaining('Tax, Discounts & Fees > Update'), findsOneWidget);
      expect(find.byKey(const ValueKey('add-discount')), findsNothing);
    });
  });

  testWidgets('look up a rate: a city\'s own rate, its total with state and county, since when', (t) async {
    final s = _Server();
    await _show(t, s, () async {
      await t.enterText(find.descendant(of: find.byKey(const ValueKey('tax-lookup')), matching: find.byType(TextField)), 'Rogers');
      await t.pumpAndSettle();
      expect(find.text('Rogers (city)'), findsOneWidget);
      expect(find.text('9.5% total'), findsOneWidget);
      expect(find.textContaining('2% own · since Apr 1, 2012'), findsOneWidget);
    });
  });
}
