// Renders the real Jobs and Estimates list screens with fake API data at several window sizes and saves screenshots to
// test/shots/. Run:  flutter test test/lists_render_test.dart --update-goldens

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/estimates_screen.dart';
import 'package:iohd_desktop/jobs_screen.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

const _customers = [
  'Schuber Mitchell Homes',
  'Quality Building Systems Inc.',
  'Lennar',
  'Moser Construction LLC',
  'Trinitas',
  'OZ Homes, LLC',
  'Heather & Tom Whitfield',
];
const _jobStatuses = ['Final Invoice Sent', 'Scheduled - Full Day', 'Need To Schedule', 'Paid & Closed', 'Partially Complete', 'Complete', 'Need Deposit'];
const _estimateStatuses = ['Estimate Provided', 'Estimate Won', 'Lost', 'Estimate Requested', 'Estimate Follow Up'];

List<Map<String, dynamic>> _rows(bool estimates) => [
      for (var i = 0; i < 14; i++)
        {
          'job_id': '${1099000000 + i * 137}',
          'customer_name': _customers[i % _customers.length],
          'location': i % 5 == 2 ? '' : '${1200 + i * 17} W Poplar St, Rogers, AR 72756',
          'description': i % 3 == 0
              ? 'Replace two garage doors, torsion springs, new weather seal and the opener bracket on the north bay, customer wants gray not white.'
              : (i % 3 == 1 ? 'Service call: door off track' : ''),
          'start_date': '2026-10-${(12 - (i % 11)).toString().padLeft(2, '0')}',
          'total_revenue': (1200 + i * 837.5).toString(),
          'status': (estimates ? _estimateStatuses : _jobStatuses)[i % (estimates ? _estimateStatuses : _jobStatuses).length],
          'techs_assigned': estimates ? '' : (i % 4 == 3 ? '' : 'Brett Hall, Marcus Lee'),
          if (estimates) 'opportunity_owner': i % 2 == 0 ? 'Heather Vera' : 'Zac Clemens',
        },
    ];

http.Client _mock({bool empty = false, int? failCode}) => MockClient((req) async {
      final p = req.url.path;
      if (failCode != null) return http.Response('boom', failCode);
      final est = p.contains('estimates');
      if (p.endsWith('status-counts')) {
        final names = est ? _estimateStatuses : _jobStatuses;
        return http.Response(
          jsonEncode({
            'total': empty ? 0 : 2400,
            'counts': [for (var i = 0; i < names.length; i++) {'status': names[i], 'count': empty ? 0 : 900 - i * 140}],
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode({'data': empty ? [] : _rows(est), 'total': empty ? 0 : 2400, 'page': 1, 'totalPages': empty ? 1 : 48}),
        200,
      );
    });

Future<void> _shot(WidgetTester t, Widget screen, Size size, String name, http.Client client) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  await http.runWithClient(() async {
    await t.pumpWidget(RepaintBoundary(
      key: const ValueKey('shot'),
      child: MaterialApp(theme: ThemeData(useMaterial3: true, fontFamily: 'Segoe UI'), home: screen),
    ));
    await t.pumpAndSettle();
  }, () => client);
  expect(t.takeException(), isNull);
  await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('shots/$name.png'));
}

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', ['C:/Windows/Fonts/segoeui.ttf', 'C:/Windows/Fonts/segoeuib.ttf']);
  });

  for (final size in const [Size(1920, 940), Size(1280, 720), Size(800, 700)]) {
    testWidgets('jobs list ${size.width.toInt()}x${size.height.toInt()}', (t) async {
      await _shot(t, const JobsScreen(), size, 'jobs_list_${size.width.toInt()}', _mock());
    });
    testWidgets('estimates list ${size.width.toInt()}x${size.height.toInt()}', (t) async {
      await _shot(t, const EstimatesScreen(), size, 'estimates_list_${size.width.toInt()}', _mock());
    });
  }

  testWidgets('jobs list phone width', (t) async {
    await _shot(t, const JobsScreen(), const Size(420, 760), 'jobs_list_420', _mock());
  });

  testWidgets('jobs list empty', (t) async {
    await _shot(t, const JobsScreen(), const Size(1280, 720), 'jobs_list_empty', _mock(empty: true));
  });
  testWidgets('jobs list error', (t) async {
    await _shot(t, const JobsScreen(), const Size(1280, 720), 'jobs_list_error', _mock(failCode: 500));
  });
}
