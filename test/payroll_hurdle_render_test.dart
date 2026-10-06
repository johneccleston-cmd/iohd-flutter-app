// Renders the payroll screen with a sales rep's week (commission on estimates won) and saves screenshots.
// Run:  flutter test test/payroll_rep_render_test.dart --update-goldens

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/payroll_screen.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

Map<String, dynamic> _tech(int id, String name, double gross, {double rule = 750, bool sales = false}) => {
      'userId': id,
      'name': name,
      'role': sales ? 'Sales Rep' : 'Technician',
      'isSales': sales,
      'isCallbackOnly': false,
      'totals': {'weeklyGross': gross, 'cashPay': gross > rule ? gross - rule : 0, 'totalDue': gross > rule ? gross - rule : 0, 'hurdleApplied': gross > rule ? rule : gross},
      'weeks': [
        {'weekStart': '2026-11-02', 'weekEnd': '2026-11-08', 'weeklyGross': gross, 'hurdleRule': rule, 'cashPay': gross > rule ? gross - rule : 0, 'jobs': []},
      ],
      'retainageReleases': [],
    };

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', [r'C:\Windows\Fonts\segoeui.ttf', r'C:\Windows\Fonts\segoeuib.ttf', r'C:\Windows\Fonts\seguisb.ttf']);
    final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? r'C:\srclutter';
    await _loadFont('MaterialIcons', ['$flutterRoot/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
  });

  testWidgets('hurdle bars', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1500, 900);
    addTearDown(tester.view.reset);
    final body = jsonEncode({
      'success': true,
      'range': {'start': '2026-11-02', 'end': '2026-11-08'},
      'rules': {'weeklyThreshold': 750, 'companyPoolRate': 0.01},
      'techs': [_tech(1, 'Alex Rivera', 320), _tech(2, 'Sam Ortiz', 610), _tech(3, 'Dana Wu', 1180), _tech(4, 'Zac Clemens', 400, rule: 0, sales: true)],
    });
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
        home: const Scaffold(body: PayrollScreen()),
      ));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/payroll_hurdle_bars.png'));
    }, () => MockClient((r) async => http.Response(
          r.url.path.endsWith('/pending')
              ? jsonEncode({'success': true, 'totals': {'share': 0, 'retainage': 0, 'net': 0}, 'counts': {'techs': 0, 'jobs': 0}, 'techs': []})
              : body,
          200,
        )));
  });
}
