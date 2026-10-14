// Stress checks for the job / estimate page: big text and narrow windows must not overflow or throw.
// Run:  flutter test test/job_page_stress_test.dart
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/job_detail_screen.dart';

Map<String, dynamic> _record({required bool estimate}) => {
      'job': {
        'job_id': '1096183137',
        'customer_name': 'A Very Long Customer Name Construction And Development Company LLC',
        'contact_name': 'Dana Whitfield',
        'status': estimate ? 'Estimate Provided' : 'Final Invoice Sent',
        'sub_status': estimate ? '' : 'Scheduled - Full Day',
        'is_estimate': estimate,
        'category': 'Residential Install',
        'location': '12345 West Extraordinarily Long Poplar Street Name Boulevard, Rogers, AR 72756',
        'description': 'Replace two garage doors, torsion springs, new weather seal.',
        'notes': 'Gate code 4471. Dog in backyard. ' * 6,
        'po_number': 'PO-88231',
        'techs_assigned': 'Brett Hall, Marcus Lee',
        'opportunity_owner': 'Heather Vera',
        'start_date': '2026-10-06',
        'end_date': '2026-10-07',
        'total_revenue': '2450.00',
        'due_total': '950.00',
        'raw_items': [
          {'name': 'SMH | Gallery Steel | GD5S | Complete Door | White | 16x7 | Insulated | Windows | Long product name that wraps', 'total': 507.16, 'rate': 507.16, 'multiplier': 1, 'item_index': 1},
          {'name': 'Weather Seal | Stop Mold | 7\' White', 'total': 10.54, 'rate': 5.27, 'multiplier': 2, 'item_index': 2},
        ],
        'other_charges': [
          {'name': 'Sales Tax (State, County, & Local Use Tax, Fayetteville)', 'total': 87.75, 'is_discount': false},
        ],
        'sf_details': {
          'techs': [
            {'name': 'Office Admin', 'status': 'Scheduled - Full Day'},
          ],
          'visits': [
            {'start_date': '2026-09-02', 'duration': 5400, 'notes_for_techs': 'Bring the forklift', 'techs': [{'name': 'Daniel Baty', 'status': 'Scheduled - Full Day'}]},
          ],
          'priority': 'Normal',
          'duration': 3600,
        },
      },
      'customer': {'primary_contact': 'Dana Whitfield', 'phone': '(479) 736-2125', 'email': 'dana.whitfield@schubermitchellhomes-example.com'},
      'visits': [],
      'payments': [
        {'amount': '1500.00', 'received_on': '2026-10-09T15:00:00Z', 'payment_type': 'Check', 'transaction_type': 'Payment'},
      ],
      'history': [],
    };

http.Client _mock(bool estimate) => MockClient((req) async {
      final p = req.url.path;
      if (p.endsWith('/notes-tasks')) return http.Response(jsonEncode({'notes': [], 'tasks': []}), 200);
      if (p.endsWith('/files')) return http.Response(jsonEncode({'enabled': true, 'files': []}), 200);
      return http.Response(jsonEncode(_record(estimate: estimate)), 200);
    });

Future<void> _check(WidgetTester t, Size size, double textScale, bool estimate) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  final previous = FlutterError.onError;
  FlutterError.onError = (d) {
    // Say WHERE it overflowed (the widget creation location), not just by how much.
    debugPrint('OVERFLOW: ${d.exceptionAsString()} @ ${d.informationCollector?.call().map((n) => n.toString()).join(' | ')}');
    previous?.call(d);
  };
  addTearDown(() => FlutterError.onError = previous);
  await http.runWithClient(() async {
    await t.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)), child: child!),
      home: const JobDetailScreen(jobId: '1096183137'),
    ));
    await t.pumpAndSettle();
  }, () => _mock(estimate));
  expect(t.takeException(), isNull);
}

void main() {
  for (final estimate in [false, true]) {
    for (final size in const [Size(1920, 1000), Size(1280, 720), Size(800, 700), Size(420, 800)]) {
      for (final scale in const [1.0, 1.3]) {
        testWidgets('${estimate ? 'estimate' : 'job'} page ${size.width.toInt()}px, text x$scale', (t) async {
          await _check(t, size, scale, estimate);
        });
      }
    }
  }
}
