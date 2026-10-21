// The Role select and Date joined box must be exactly as tall as the text fields beside them, whatever the font.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/team_admin_screen.dart';
import 'package:iohd_desktop/widgets/animated_select.dart';

http.Response _handle(http.Request r) {
  if (r.url.path.endsWith('/history')) return http.Response(jsonEncode({'success': true, 'history': []}), 200);
  return http.Response(
    jsonEncode({
      'success': true,
      'roles': [
        {'name': 'Lead Technician', 'grantsAdmin': false},
      ],
      'users': [
        {
          'id': 1, 'name': 'Daniel Baty', 'username': 'gbaty', 'role': 'Lead Technician', 'status': 'ACTIVE',
          'tech_weight': 1.0, 'hire_date': '2024-02-05', 'access_denied': <String>[], 'has_pin': true,
          'work_days_90': 10, 'version': '1',
        },
      ],
    }),
    200,
  );
}

void main() {
  for (final family in [null, 'Roboto', 'Segoe UI']) {
    testWidgets('role, date and text fields share one height (font: $family)', (t) async {
      t.view.devicePixelRatio = 1.0;
      t.view.physicalSize = const Size(1440, 900);
      addTearDown(t.view.reset);
      await http.runWithClient(() async {
        await t.pumpWidget(MaterialApp(
          theme: ThemeData(fontFamily: family, useMaterial3: true),
          home: const TeamAdminScreen(),
        ));
        for (var i = 0; i < 10; i++) {
          await t.pump(const Duration(milliseconds: 100));
        }
        await t.tap(find.text('Daniel Baty').first);
        for (var i = 0; i < 10; i++) {
          await t.pump(const Duration(milliseconds: 100));
        }
        final text = t.getSize(find.widgetWithText(TextField, 'Daniel').first).height;
        final role = t.getSize(find.byType(AnimatedSelect<String>).first).height;
        final date = t.getSize(find.widgetWithText(TextFormField, 'Feb 5, 2024').first).height;
        expect(role, text);
        expect(date, text);
      }, () => MockClient((r) async => _handle(r)));
    });
  }
}
