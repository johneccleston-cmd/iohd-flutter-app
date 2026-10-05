// Renders the pending-commission panel with fake API data and saves screenshots to test/shots/.
// Run:  flutter test test/payroll_pending_render_test.dart --update-goldens

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/payroll_pending_panel.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

Map<String, dynamic> _job(String id, String customer, double pct, double share, {int unverified = 0}) => {
      'jobId': id,
      'customer': customer,
      'status': 'Scheduled - Full Day',
      'splitPct': pct,
      'share': share,
      'retainage': 0,
      'net': share,
      'unverifiedDays': unverified,
    };

Map<String, dynamic> _tech(String name, String role, List<Map<String, dynamic>> jobs) {
  final net = jobs.fold<double>(0, (s, j) => s + (j['net'] as double));
  return {
    'name': name,
    'role': role,
    'jobs': jobs,
    'totals': {'share': net, 'retainage': 0, 'net': net},
  };
}

String _body(bool empty) => jsonEncode(empty
    ? {'success': true, 'totals': {'share': 0, 'retainage': 0, 'net': 0}, 'counts': {'techs': 0, 'jobs': 0}, 'techs': []}
    : {
        'success': true,
        'totals': {'share': 1219.7, 'retainage': 0, 'net': 1219.7},
        'counts': {'techs': 3, 'jobs': 5},
        'techs': [
          _tech('Andrew Johnson', 'Technician', [
            _job('1093652699', 'Lennar', 50, 35.2),
            _job('1097884615', 'Lennar', 50, 17.95),
            _job('1098031292', 'Lennar', 50, 17.95),
            _job('1098147137', 'Lennar', 50, 17.95),
          ]),
          _tech('Brett Miller', 'Technician', [
            _job('1093652699', 'Lennar', 50, 35.2),
            _job('1097884615', 'Lennar', 50, 17.95),
          ]),
          _tech('Daniel Baty', 'Lead Technician', [_job('1095809012', 'Ideal Structures LLC', 100, 910.58, unverified: 1)]),
        ],
      });

Future<void> _shot(WidgetTester tester, String name, {bool empty = false, bool expand = false}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1100, 640);
  addTearDown(tester.view.reset);
  await http.runWithClient(() async {
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
      home: const Scaffold(
        backgroundColor: Color(0xFFF1F5F9),
        body: Padding(padding: EdgeInsets.all(20), child: SingleChildScrollView(child: PayrollPendingPanel())),
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    if (expand) {
      await tester.tap(find.text('Daniel Baty'));
      await tester.pump(const Duration(milliseconds: 200));
    }
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/$name.png'));
  }, () => MockClient((r) async => http.Response(_body(empty), 200)));
}

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', [r'C:\Windows\Fonts\segoeui.ttf', r'C:\Windows\Fonts\segoeuib.ttf', r'C:\Windows\Fonts\seguisb.ttf']);
    final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter';
    await _loadFont('MaterialIcons', ['$flutterRoot/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
  });

  testWidgets('with data', (t) async => _shot(t, 'pending_data', expand: true));
  testWidgets('empty', (t) async => _shot(t, 'pending_empty', empty: true));
}
