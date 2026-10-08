// Renders the Commissions dashboard (month chart and the paid-by-technician card) with fake API data.
// Run:  flutter test test/commission_dash_render_test.dart --update-goldens

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/commission_dashboard_screen.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

Map<String, dynamic> _tech(String name, double ytd, {bool sales = false, double week = 0, int streak = 0}) => {
      'id': name.toLowerCase().replaceAll(' ', ''),
      'name': name,
      'jobTitle': sales ? 'Sales Rep' : 'Technician',
      'imageUrl': '',
      'isSales': sales,
      'ytdCommission': ytd,
      'weekGross': week,
      'hurdleStreak': streak,
      'hurdleWeeksHit': streak + 1,
      'lockedBalance': 0,
      'strikes': 0,
      'totalPenalties': 0,
    };

String _body({required bool paid, bool many = false}) => jsonEncode({
      'success': true,
      'history': {'retainagePool': []},
      'summary': {
        'totalPayoutsYtd': paid ? 4310.0 : 0,
        'companyRetainagePool': 50.51,
        'commercialRetainagePool': 116.35,
        'avgCommissionPerTech': paid ? 1077.5 : 0,
        'salesCommission': {'total': 0, 'estimates': 0, 'hardBid': 0, 'newAccount': 0, 'account': 0},
        'nextDisbursement': {'date': '2026-12-31', 'amount': 0, 'techCount': 0},
      },
      'meta': {'year': 2026, 'weeklyThreshold': 750},
      'technicians': [
        _tech('Nick Smith', paid ? 2410 : 0, week: 781.74, streak: 4),
        _tech('Daniel Baty', paid ? 1250 : 0, week: 520, streak: 2),
        _tech('Andrew Johnson', paid ? 650 : 0, week: 210.5, streak: 7),
        _tech('Brett Miller', 0),
        if (many) ...[_tech('Chris Doe', paid ? 300 : 0), _tech('Pat Lee', paid ? 120 : 0), _tech('Sam Roe', 0)],
        _tech('Zac Clemens', 0, sales: true),
      ],
      'monthlyData': [
        for (var m = 1; m <= 12; m++) {'month': 'M$m', 'payout': paid && m == 10 ? 4310 : 0, 'revenue': m == 10 ? 180000 : 0},
      ],
    });

Future<void> _shot(WidgetTester tester, String name, {required bool paid, bool byTech = false, bool many = false, String runs = 'none', int settleMs = 2400, Size size = const Size(1500, 720)}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await http.runWithClient(() async {
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
      home: const Scaffold(
        backgroundColor: Color(0xFFF1F5F9),
        body: Padding(padding: EdgeInsets.all(16), child: CommissionDashboardContent(selectedYear: 2026)),
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    for (var ms = 0; ms < settleMs; ms += 100) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    if (byTech) {
      await tester.tap(find.text('By tech'));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 150));
      }
    }
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/$name.png'));
  }, () => MockClient((r) async {
    if (r.url.path.contains('/payroll/runs')) {
      final list = runs == 'none'
          ? []
          : [
              {'id': 9, 'week_start': '2026-10-05', 'week_end': '2026-10-11', 'run_type': 'adjustment', 'status': 'finalized', 'run_by_name': 'John', 'total_amount_paid': 530.9},
              {'id': 8, 'week_start': '2026-10-05', 'week_end': '2026-10-11', 'run_type': 'regular', 'status': 'finalized', 'run_by_name': 'John', 'total_amount_paid': 770},
              {'id': 7, 'week_start': '2026-09-28', 'week_end': '2026-10-04', 'run_type': 'regular', 'status': 'voided', 'run_by_name': 'John', 'total_amount_paid': 100},
            ];
      return http.Response(jsonEncode({'success': true, 'runs': list}), 200);
    }
    return http.Response(_body(paid: paid, many: many), 200);
  }));
}

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', [r'C:\Windows\Fonts\segoeui.ttf', r'C:\Windows\Fonts\segoeuib.ttf', r'C:\Windows\Fonts\seguisb.ttf']);
    final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter';
    await _loadFont('MaterialIcons', ['$flutterRoot/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
  });

  testWidgets('paid 1900x800', (t) async => _shot(t, 'comm_dash_paid_1900', paid: true, runs: 'some', size: const Size(1900, 800)));
  testWidgets('meters mid-animation', (t) async => _shot(t, 'comm_dash_meters_mid', paid: true, runs: 'some', settleMs: 300, size: const Size(1500, 720)));
  testWidgets('paid 1500x720', (t) async => _shot(t, 'comm_dash_paid_1500', paid: true, runs: 'some'));
  testWidgets('many 1900x800', (t) async => _shot(t, 'comm_dash_many_1900', paid: true, many: true, size: const Size(1900, 800)));
  testWidgets('paid 1280x600', (t) async => _shot(t, 'comm_dash_paid_1280', paid: true, size: const Size(1280, 600)));
  testWidgets('nothing paid 1366x688', (t) async => _shot(t, 'comm_dash_zero_1366', paid: false, size: const Size(1366, 688)));
}
