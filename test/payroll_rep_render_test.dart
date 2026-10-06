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

Map<String, dynamic> _rep(String job, String customer, String basis, double labor, double pct) => {
      'jobId': job,
      'customer': customer,
      'wonOn': '2026-10-06',
      'closedOn': '2026-10-28',
      'basis': basis == 'Commercial Hard Bid' ? 'hard_bid' : 'account',
      'basisLabel': basis,
      'labor': labor,
      'ratePct': pct,
      'amount': labor * pct / 100,
    };

String _body() {
  final items = [
    _rep('1098030331', 'Beran Concrete Inc', 'Commercial Hard Bid', 18400, 2),
    _rep('1096788106', 'Trulove Construction', 'Assigned account', 6200, 1),
  ];
  final pay = items.fold<double>(0, (s, i) => s + (i['amount'] as double));
  return jsonEncode({
    'success': true,
    'range': {'start': '2026-11-02', 'end': '2026-11-08'},
    'rules': {
      'goLiveDate': '2026-10-05',
      'weeklyThreshold': 750,
      'dailyAdvance': 200,
      'callbackPay': 50,
      'companyPoolRate': 0.01,
      'retainageRate': 0.2,
    },
    'techs': [
      {
        'userId': 36,
        'name': 'Zac Clemens',
        'role': 'Sales Rep',
        'isSales': true,
        'isCallbackOnly': true,
        'totals': {'repPay': pay, 'weeklyGross': pay, 'cashPay': pay, 'totalDue': pay},
        'weeks': [
          {
            'weekStart': '2026-11-02',
            'weekEnd': '2026-11-08',
            'weeklyGross': pay,
            'cashPay': pay,
            'repPay': pay,
            'repCommissions': items,
          },
        ],
        'retainageReleases': [],
      },
    ],
  });
}

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', [r'C:\Windows\Fonts\segoeui.ttf', r'C:\Windows\Fonts\segoeuib.ttf', r'C:\Windows\Fonts\seguisb.ttf']);
    final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter';
    await _loadFont('MaterialIcons', ['$flutterRoot/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
  });

  testWidgets('sales rep week', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1500, 1500);
    addTearDown(tester.view.reset);
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
        home: const Scaffold(body: PayrollScreen()),
      ));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      final zac = find.text('Zac Clemens');
      if (zac.evaluate().isNotEmpty) {
        await tester.tap(zac.first);
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 150));
        }
      }
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/payroll_rep_week.png'));
    }, () => MockClient((r) async => http.Response(
          r.url.path.endsWith('/pending')
              ? jsonEncode({'success': true, 'totals': {'share': 0, 'retainage': 0, 'net': 0}, 'counts': {'techs': 0, 'jobs': 0}, 'techs': []})
              : _body(),
          200,
        )));
  });
}
