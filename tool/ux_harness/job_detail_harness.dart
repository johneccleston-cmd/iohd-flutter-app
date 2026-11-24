// Real-browser harness for the Job Details page (header + tab polish, 2026-11-24): the real JobDetailScreen with the
// app's theme, a fake admin session and a fake API. No request leaves the machine. LOCAL ONLY: never shipped.
//
//   flutter build web --profile -t tool/ux_harness/job_detail_harness.dart --output build/<new folder>
//
// Exposes window.uxText(text, index) -> [x, y, w, h] so a DevTools-protocol driver can hover and click real widgets.

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/config/auth_session.dart';
import 'package:iohd_desktop/job_detail_screen.dart';
import 'package:iohd_desktop/main.dart' show officeTheme;
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _job() => {
  'job': {
    'job_id': '1096183137',
    'customer_name': 'Schuber Mitchell Homes',
    'contact_name': 'Dana Whitfield',
    'status': 'Final Invoice Sent',
    'sub_status': 'Site Check',
    'is_estimate': false,
    'category': 'Residential Install',
    'location': '1204 W Poplar St, Rogers, AR 72756',
    'description': 'Replace two garage doors, torsion springs, new weather seal.',
    'notes': 'Gate code 4471. Dog in backyard.',
    'po_number': 'PO-88231',
    'techs_assigned': 'Brett Hall, Marcus Lee',
    'opportunity_owner': 'Heather Vera',
    'start_date': '2026-10-06',
    'end_date': '2026-10-07',
    'closed_at': '2026-10-09',
    'total_revenue': '2450.00',
    'due_total': '950.00',
    'sf_details': {
      'priority': 'Normal',
      'duration': 3600,
      'time_frame_promised_start': '08:00:00',
      'time_frame_promised_end': '10:00:00',
      'pictures': [
        for (var i = 0; i < 12; i++) {'name': 'site-$i.jpg', 'url': 'https://example.invalid/$i.jpg', 'type': 'Picture', 'comment': '', 'is_private': false},
      ],
      'documents': [
        {'name': 'Signed work order.pdf', 'url': 'https://example.invalid/wo.pdf', 'type': 'Work Order', 'comment': '', 'is_private': false, 'created_at': '2026-10-07T15:00:00Z'},
        {'name': 'Permit.pdf', 'url': 'https://example.invalid/p.pdf', 'type': 'Permit', 'comment': '', 'is_private': true, 'created_at': '2026-10-02T15:00:00Z'},
      ],
      'visits': [
        {'start_date': '2026-10-07', 'time_frame_promised_start': '13:00:00', 'time_frame_promised_end': '15:30:00', 'duration': 3600, 'notes_for_techs': '', 'techs': []},
      ],
    },
    'raw_items': [
      {'name': 'SMH | Gallery Steel | GD5S | Complete Door | White', 'total': 507.16, 'multiplier': 1, 'item_index': 3},
      {'name': 'SMH Installation | Gallery Steel | 16x7 | White', 'total': 300, 'multiplier': 1, 'item_index': 2},
    ],
  },
  'customer': {'primary_contact': 'Dana Whitfield', 'phone': '(479) 736-2125', 'email': 'dana@schubermitchell.com'},
  'fromEstimate': '1089344759',
  'visits': [],
  'payments': [
    {'amount': '1500.00', 'received_on': '2026-10-09T15:00:00Z', 'payment_type': 'Check', 'transaction_type': 'Payment'},
  ],
  'stripePayments': [],
  'history': [
    {'old_status': 'Created', 'new_status': 'Scheduled', 'changed_at': '2026-10-01T14:00:00Z'},
  ],
};

final _client = MockClient((req) async {
  await Future<void>.delayed(const Duration(milliseconds: 150));
  final p = req.url.path;
  if (p.endsWith('/files')) return http.Response(jsonEncode({'enabled': true, 'files': []}), 200);
  if (p.endsWith('/notes-tasks')) return http.Response(jsonEncode({'notes': [], 'tasks': []}), 200);
  if (p.contains('/jobs/')) return http.Response(jsonEncode(_job()), 200);
  return http.Response(jsonEncode({}), 200);
});

List<double>? _rectOf(Element e) {
  final r = e.renderObject;
  if (r is! RenderBox || !r.attached || !r.hasSize || r.size.isEmpty) return null;
  final o = r.localToGlobal(Offset.zero);
  return [o.dx, o.dy, r.size.width, r.size.height];
}

void _exposeFinders() {
  globalContext.setProperty(
    'uxText'.toJS,
    ((JSString text, JSNumber? index) {
      final hits = <List<double>>[];
      void visit(Element e) {
        final w = e.widget;
        if (w is RichText && w.text.toPlainText() == text.toDart) {
          final r = _rectOf(e);
          if (r != null) hits.add(r);
        }
        e.visitChildren(visit);
      }

      final root = WidgetsBinding.instance.rootElement;
      if (root != null) visit(root);
      final i = index?.toDartInt ?? 0;
      return i < hits.length ? [for (final v in hits[i]) v.toJS].toJS : null;
    }).toJS,
  );
}

Future<void> main() => http.runWithClient(() async {
  WidgetsFlutterBinding.ensureInitialized();
  final payload = base64Url.encode(utf8.encode(json.encode({'exp': DateTime(2100).millisecondsSinceEpoch})));
  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues({
    'iohd_auth_session': json.encode({'token': '$payload.sig', 'name': 'Harness Admin', 'role': 'Admin', 'is_admin': true, 'denied': <String>[]}),
  });
  await AuthSession.instance.restore();
  _exposeFinders();
  runApp(
    MaterialApp(
      title: 'UX harness: Job Details',
      debugShowCheckedModeBanner: false,
      theme: officeTheme(),
      home: Column(
        children: [
          // Stands in for the app's 60 px nav bar.
          Container(height: 60, color: const Color(0xFF14213D)),
          const Expanded(child: JobDetailScreen(jobId: '1096183137')),
        ],
      ),
    ),
  );
}, () => _client);
