// Renders the real Collections dashboard with fake API data (numbers taken from the live DB on 2026-10-05)
// and saves screenshots to test/shots/.
// Run:  flutter test test/collections_render_test.dart --update-goldens

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/collections_dashboard_screen.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    final bytes = File(p).readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
  }
  await loader.load();
}

Map<String, dynamic> _payload({bool empty = false}) {
  const cur = [230676, 195153, 269204, 395785, 326921, 207158, 292252, 362004, 137737, 23769];
  const pri = [159188, 236958, 241508, 280098, 337189, 227778, 378541, 273155, 226395, 326806, 249551, 268718];
  List<Map<String, dynamic>> m(List<num> v) => [for (var i = 0; i < v.length; i++) {'month_num': i + 1, 'collected': empty ? 0 : v[i], 'payment_count': 150}];
  return {
    'success': true,
    'year': 2026,
    'summary': {
      'collected': empty ? 0 : 2440659.0,
      'paymentCount': empty ? 0 : 1574,
      'largestPayment': 64358.0,
      'priorCollected': empty ? 0 : 2310000.0,
      'outstanding': empty ? 0 : 238132.83,
      'outstandingJobs': empty ? 0 : 209,
      'over90': empty ? 0 : 22577.47,
      'over90Jobs': empty ? 0 : 40,
      'writeOffJobs': empty ? 0 : 4,
      'writeOffBalance': empty ? 0 : 333.35,
    },
    'writeOffMonthly': empty
        ? []
        : [
            {'month_num': 2, 'job_count': 1, 'balance': 50.47},
            {'month_num': 3, 'job_count': 1, 'balance': 202.91},
            {'month_num': 4, 'job_count': 2, 'balance': 79.97},
          ],
    // Daily snapshots; the real line starts as soon as there are two days of them.
    'history': empty
        ? []
        : [
            for (var i = 0; i < 30; i++)
              {'day': '2026-09-${(i + 1).toString().padLeft(2, '0')}', 'outstanding': 200000 + i * 1300 + (i % 4) * 4000, 'over90': 15000 + i * 250},
          ],
    'overdue': empty
        ? []
        : [
            for (var i = 0; i < 24; i++)
              {
                'jobId': '10672684${44 + i}',
                'customer': const ['Schuber Mitchell Homes', 'Lennar', 'Moser Construction LLC', 'Trinitas', 'Axis Electric', 'OZ Homes, LLC'][i % 6],
                'amount': 1200.0 + i * 835,
                'status': 'Final Invoice Sent',
                'daysOverdue': 1500 - i * 62,
              },
          ],
    'monthly': m(cur),
    'priorMonthly': m(pri),
    'methods': empty
        ? []
        : [
            {'method': 'Check', 'amount': 1674580.39, 'paymentCount': 1177},
            {'method': 'Card', 'amount': 724348.62, 'paymentCount': 378},
            {'method': 'ACH', 'amount': 40673.75, 'paymentCount': 12},
            {'method': 'Cash', 'amount': 908.30, 'paymentCount': 5},
            {'method': 'Other', 'amount': 148.20, 'paymentCount': 2},
          ],
    'stages': [
      for (final r in const [
        ('none', 'Final Invoice Sent', 68389.63, 105),
        ('14', '14 Day Notice', 44494.11, 33),
        ('30', '30 Day Notice', 10492.39, 11),
        ('60', '60 Day Notice', 8604.67, 8),
        ('90', '90 Day Notice', 22577.47, 40),
        ('check', 'Check on Payment', 83574.56, 12),
      ])
        {'stage': r.$1, 'label': r.$2, 'amount': empty ? 0 : r.$3, 'jobCount': empty ? 0 : r.$4},
    ],
    'topOwing': empty
        ? []
        : [
            for (final r in const [
              ('Trinitas', 64358.0, 1, 80),
              ('Moser Construction LLC', 36531.25, 5, 143),
              ('Schuber Mitchell Homes', 21610.17, 46, 1091),
              ('Axis Electric', 20857.33, 1, 4),
              ('Nabholz Construction Corporation', 20679.62, 1, 108),
            ])
              {'customer': r.$1, 'amount': r.$2, 'jobCount': r.$3, 'oldestDays': r.$4},
          ],
  };
}

http.Response _jobsList() {
  const subs = ['', 'Callback', 'Manage Project', 'Scheduled - Full Day', '', ''];
  final items = [
    for (var i = 0; i < 14; i++)
      {
        'jobId': '10672684${44 + i}',
        'customerName': const ['Lennar', 'Moser Construction LLC', 'Josh Howerton', 'Schuber Mitchell Homes'][i % 4],
        'status': subs[i % subs.length].isEmpty ? 'Final Invoice Sent' : subs[i % subs.length],
        'location': '123 Main St, Bentonville AR',
        'description': '',
        'startDate': '2026-0${1 + i % 8}-1${i % 9}',
        'value': 90.0 + i * 410,
        'outcome': i < 6 ? 'lost' : 'open',
        'daysOld': 300 - i * 20,
      },
  ];
  return http.Response(jsonEncode({'success': true, 'count': items.length, 'totalValue': 30000, 'items': items}), 200);
}

Future<void> _shot(WidgetTester tester, Size size, String name,
    {int status = 200, bool empty = false, bool hover = false, String? tapText}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);

  await http.runWithClient(() async {
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
        home: const CollectionsDashboardScreen(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    if (hover) {
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(Offset(size.width * 0.3, size.height * 0.45));
      await tester.pump(const Duration(milliseconds: 200));
    }
    if (tapText != null) {
      await tester.tap(find.text(tapText).first);
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/$name.png'));
  }, () => MockClient((r) async {
        if (r.url.path.endsWith('/collections/jobs')) return _jobsList();
        return status == 200 ? http.Response(jsonEncode(_payload(empty: empty)), 200) : http.Response('boom', status);
      }));
}

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', [
      r'C:\Windows\Fonts\segoeui.ttf',
      r'C:\Windows\Fonts\segoeuib.ttf',
      r'C:\Windows\Fonts\seguisb.ttf',
    ]);
    final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter';
    await _loadFont('Ahem', ['$flutterRoot/bin/cache/artifacts/material_fonts/roboto-regular.ttf']);
    await _loadFont('Roboto', [
      '$flutterRoot/bin/cache/artifacts/material_fonts/roboto-regular.ttf',
      '$flutterRoot/bin/cache/artifacts/material_fonts/roboto-medium.ttf',
      '$flutterRoot/bin/cache/artifacts/material_fonts/roboto-bold.ttf',
    ]);
    await _loadFont('MaterialIcons', ['$flutterRoot/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
  });

  for (final s in const [
    (Size(1280, 600), 'collections_1280x600'),
    (Size(1500, 720), 'collections_1500x720'),
    (Size(1920, 940), 'collections_1920x940'),
  ]) {
    testWidgets('renders ${s.$2}', (tester) async => _shot(tester, s.$1, s.$2));
  }

  testWidgets('hover tooltip', (tester) async => _shot(tester, const Size(1500, 800), 'collections_hover', hover: true));
  testWidgets('stage click-through', (tester) async => _shot(tester, const Size(1500, 800), 'collections_drill', tapText: 'Final Invoice Sent'));
  testWidgets('empty year', (tester) async => _shot(tester, const Size(1500, 800), 'collections_empty', empty: true));
  testWidgets('server error', (tester) async => _shot(tester, const Size(1500, 800), 'collections_error', status: 500));
}
